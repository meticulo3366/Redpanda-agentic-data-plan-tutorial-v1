# Redpanda Agentic Data Plane (ADP) — SE Setup Guide

A step-by-step walkthrough to stand up ADP: an LLM provider (Claude via **AWS Bedrock**), an MCP server, an OAuth client for Claude Code, a managed agent, cost/usage review, and a standalone service that triggers agent runs.

**Console:** [ai.redpanda.com](https://ai.redpanda.com) · **Docs:** [Quickstart](https://docs.redpanda.com/agentic-data-plane/get-started/adp-quickstart/) · [Claude Code + ADP](https://docs.redpanda.com/agentic-data-plane/connect/claude-code/)

## Prerequisites

- ADP access with **Admin** (provider setup) or **Writer** (build) role
- An **AWS account** with the AWS CLI configured — you'll set up Bedrock below (**do this first**)
- `curl`, `jq`, and Claude Code installed locally [Redpanda Cupboard](https://github.com/redpanda-data/cupboard)
- Your ADP `<cluster-id>` (from any provider's **Connection** card)

### ⚠️ Set up AWS Bedrock first — follow the guide exactly

**Before anything else, complete the AWS-side Bedrock setup: [AWS_BEDROCK_SETUP.md](./AWS_BEDROCK_SETUP.md).** Follow it **exactly** — the IAM policy (including the AWS Marketplace permissions for Bedrock Marketplace engines) and the inference-profile requirement are load-bearing; skipping or altering a step causes `AccessDenied` or invalid-model errors when you register the provider in [Step 1](#1-set-up-an-llm-provider-admin).

That guide takes you through enabling model access, creating the IAM policy and user, and generating the access keys you'll paste into ADP. Keep the access key ID and secret handy when you reach Step 1.

---

## 1. Set up an LLM Provider (Admin)

> Complete the [AWS Bedrock setup](./AWS_BEDROCK_SETUP.md) first — this step uses the IAM user's access keys you generated there. **Static keys** is the credential type that matches that setup.

1. In ADP, open **LLM Providers → Create provider**.
2. **Display name**: `bedrock-adp` · **Provider type**: `AWS Bedrock`.
3. **Region**: the AWS region where Bedrock is deployed, e.g. `us-east-1`.
4. Pick a **Credential type**:
   - **Static keys** — under each **secret reference → New**, create `AWS_ACCESS_KEY_ID` (**Access key ID reference**) and `AWS_SECRET_ACCESS_KEY` (**Secret access key reference**), paste the values, **Create secret**.
   - **Assume IAM role** — supply the **Role ARN** the AI Gateway assumes via AWS STS (no long-lived keys to manage).
   - **Default chain** — uses the AWS SDK default provider chain (environment variables, shared config, EKS Pod Identity, IRSA, or instance profile) when the gateway already runs with an AWS identity.
5. Select models by their **Bedrock inference profile ID** — Claude 4.6+ requires a geographic inference profile, not a bare foundation-model ID:
   - `global.anthropic.claude-opus-4-7` (any region, lowest cost — good default)
   - `us.anthropic.claude-sonnet-4-6` / `eu.anthropic.claude-sonnet-4-6` (cheaper/faster, region-scoped)
   - `us.anthropic.claude-haiku-4-5` / `eu.anthropic.claude-haiku-4-5` (fastest/cheapest)

   (Older 4.5-and-earlier models accept bare IDs like `anthropic.claude-sonnet-4-5`.) → **Create provider**.
6. Confirm the badge reads **Enabled / Active**.

> Bedrock model IDs differ from the first-party Claude API — always use the `<geo>.anthropic.<model>` inference-profile form for current models. If a model errors with an invalid-model or access-denied message, verify it's enabled under **Model access** in the Bedrock console for that region and that your IAM principal covers its ARN.

---

## 2. Set up an MCP Server + curate its tools (Builder)

1. Open **MCP Servers → Create server**, pick a connector from the marketplace (e.g. `OpenAPI`).
![openapi](https://docs.redpanda.com/agentic-data-plane/get-started/_images/create-mcp-server-picker.png)
2. **Name**: `petstore` · **Spec**: `https://petstore3.swagger.io/api/v3/openapi.json` · **Auth**: `None` → **Create**.
3. Open the **Inspector** tab to **enumerate every tool** the server exposes (e.g. `findpetsbystatus`, `getpetbyid`, `addpet`, `deletepet`, …).
4. **Curate the tool list** — verbose servers dump dozens of tools into the model's context, wasting tokens and inviting misuse. In the server's tool config, disable everything the agent doesn't need (keep read tools, drop writes/deletes). A tight, curated list = smaller context + safer agent.
5. Copy the server's **API URL** from the detail page for later.

---

## 3. Set up an OAuth Client for Claude Code (governance)

Route Claude Code through ADP so all traffic is governed (key management, spend tracking, transcript logging) and it can reach managed MCP servers.

### 3a. Create a service account (OAuth client)

**In the Redpanda Cloud UI:**

1. Go to **Organization IAM → Service account** tab → create a new service account (e.g. `llm-invoker`).
2. **Copy the Client ID and Client Secret shown at creation time.** The secret is shown **only once** and cannot be retrieved again — store it in your secret manager immediately.

**Or via the Control Plane API:**

```bash
curl -s --request POST \
  --url 'https://api.redpanda.com/v1/service-accounts' \
  --header 'content-type: application/json' \
  --header "authorization: Bearer <control-plane-token>" \
  --data '{
    "service_account": {
      "name": "llm-invoker",
      "description": "Service account for proxying LLM requests through AI Gateway"
    }
  }'
# Response includes auth0_client_credentials.client_id and auth0_client_credentials.client_secret
```

### 3b. Grant the `dataplane_adp_llmprovider_invoke` permission

`dataplane_adp_llmprovider_invoke` is bundled in the built-in **`LLMProviderInvoker`** role — the narrowest role for applications that only proxy LLM requests through the AI Gateway. Bind **`LLMProviderInvoker`** to your service account at the appropriate scope (dataplane or organization) via ADP IAM. This grants only `dataplane_adp_llmprovider_invoke` and nothing else, following least-privilege.

### 3c. Mint a token and point Claude Code at the ADP gateway

Using the client ID and secret from 3a:

```bash
export ANTHROPIC_AUTH_TOKEN=$(curl -s --request POST \
  --url 'https://auth.prd.cloud.redpanda.com/oauth/token' \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data grant_type=client_credentials \
  --data client_id=<client-id> \
  --data client_secret=<client-secret> \
  --data audience=cloudv2-production.redpanda.cloud | jq -r .access_token)

export ANTHROPIC_BASE_URL="https://aigw.<cluster-id>.clusters.rdpa.co/llm/v1/providers/bedrock-adp"
```

> **Where to find the proxy (base) URL:** open **LLM Providers** in the sidebar → click into your provider → copy the **Proxy URL** from the **Connection** card. It follows the format `https://aigw.<cluster-id>.clusters.rdpa.co/llm/v1/providers/<provider-name>` (here, `bedrock-adp`).

> Tokens expire quickly — wrap the `curl` above in a shell function and re-run before long sessions.

### 3d. Attach a managed MCP server and verify

1. Attach a managed MCP server to Claude Code (OAuth-protected servers trigger a one-time consent flow; tokens are cached in ADP's per-user vault):

```bash
claude mcp add petstore https://aigw.<cluster-id>.clusters.rdpa.co/mcp/v1/petstore
```

2. Verify: `claude "say hello"` — the request should appear in **Cost & Usage** within seconds.

---

## 4. Build an Agent (Builder)

1. Open **Agents → Create agent → Redpanda manages it**.
2. **Details**: name `pet-store-assistant`, add a description.
3. **Model**: provider `bedrock-adp`, model `us.anthropic.claude-sonnet-4-6`.
4. **Behavior** — system prompt:

```
You are a pet store inventory assistant with access to PetStore MCP tools.
- Always call a tool before answering.
- After each call, summarize and cite the tool name.
- Read operations only; if a tool fails, say so and stop.
```

5. **Tools**: attach the `petstore` MCP server (curated list from Step 2).
6. **Create agent**, wait for **Starting → Running**, then test in the **Inspector** tab (e.g. *"What pets are available right now?"*). Use **Clear context** between tests.

### Bonus — subagent to tame a verbose MCP server

Add a **subagent** whose only job is data extraction against the noisy MCP server. Give the subagent the full tool list; give the parent agent a curated set plus the subagent. The parent delegates a focused query, the subagent does the multi-tool digging and returns a compact result — keeping the raw tool sprawl out of the parent's context window.

---

## 5. Review Cost & Usage

- **Home dashboard**: request/spend activity and budget status.
- **Cost & Usage / Governance**: filter by provider on the **Requests over time** chart to attribute spend per agent/client.
- **Transcripts** (if logging enabled): full conversation history per provider for auditing.

---

## 6. Integrate a Standalone Service to Trigger an Agent Run

Call the ADP agent endpoint from any external service and capture the output. Reuse the OAuth token flow from Step 3.

```bash
#!/usr/bin/env bash
# run-agent.sh — trigger an ADP agent from a standalone service
set -euo pipefail

TOKEN=$(curl -s --request POST \
  --url 'https://auth.prd.cloud.redpanda.com/oauth/token' \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data grant_type=client_credentials \
  --data client_id="$ADP_CLIENT_ID" \
  --data client_secret="$ADP_CLIENT_SECRET" \
  --data audience=cloudv2-production.redpanda.cloud | jq -r .access_token)

curl -s --request POST \
  --url "https://aigw.${CLUSTER_ID}.clusters.rdpa.co/agents/v1/pet-store-assistant/runs" \
  --header "authorization: Bearer ${TOKEN}" \
  --header 'content-type: application/json' \
  --data '{"input": "What pets are available right now?"}' \
| tee agent-output.json | jq -r '.output'
```

- Set `ADP_CLIENT_ID`, `ADP_CLIENT_SECRET`, `CLUSTER_ID` as env vars in your service.
- The response is captured to `agent-output.json`; the run is also logged in Cost & Usage / Transcripts.
- Confirm the exact agent run path against your ADP console's agent **Connection** card — endpoints vary by ADP version.

---

## Cleanup

Delete in order: **Agent → MCP server → LLM provider**, then optionally remove the credential secrets (or, if you used an assumed IAM role, revoke/rotate it in AWS).
