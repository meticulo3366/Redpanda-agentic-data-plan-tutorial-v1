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

## 3. Set up an OAuth service account for Claude Code / AI Gateway (governance)

Route Claude Code and direct Bedrock calls through ADP so traffic is governed: upstream keys stay in ADP, usage shows up in Cost & Usage, and transcripts can be audited.

### 3a. Capture the provider proxy URL, provider name, and cluster ID

Open **LLM Providers** in ADP, click your Bedrock provider, and copy the **Proxy URL** from the provider's **Connection** card. It has this shape:

```text
https://aigw.<cluster-id>.clusters.rdpa.co/llm/v1/providers/<provider-name>
```

Set the values you will reuse below:

```bash
export ADP_CLUSTER_ID='<cluster-id>'          # From aigw.<cluster-id>.clusters.rdpa.co
export ADP_PROVIDER_NAME='bedrock-adp'        # Path segment after /providers/
export PROXY_URL="https://aigw.${ADP_CLUSTER_ID}.clusters.rdpa.co/llm/v1/providers/${ADP_PROVIDER_NAME}"
```

The provider name is the path segment after `/providers/`. Do not paste the full proxy URL into a role-binding resource field.

### 3b. Create a service account (OAuth client)

**In the Redpanda Cloud UI:**

1. Go to **Organization IAM -> Service account** tab -> create a new service account, for example `llm-invoker`.
2. Copy the **Service Account ID**, **Client ID**, and **Client Secret** shown at creation time. The secret is shown only once and cannot be retrieved again, so store it in a secret manager immediately.

**Or via the Control Plane API:**

```bash
curl -fsS --request POST \
  --url 'https://api.redpanda.com/v1/service-accounts' \
  --header 'content-type: application/json' \
  --header "authorization: Bearer <control-plane-token>" \
  --data '{
    "service_account": {
      "name": "llm-invoker",
      "description": "Service account for proxying LLM requests through AI Gateway"
    }
  }' | jq .
```

Save both identifiers:

```bash
export SERVICE_ACCOUNT_ID='<service-account-id>'  # Role bindings use this, not the OAuth Client ID.
export CLIENT_ID='<oauth-client-id>'
export CLIENT_SECRET='<oauth-client-secret>'
```

### 3c. Grant `dataplane_adp_llmprovider_invoke` at cluster scope

The runtime permission needed for AI Gateway calls is `dataplane_adp_llmprovider_invoke`. It is bundled in the built-in **`LLMProviderInvoker`** role, which is the narrow role for applications that only need to proxy LLM requests through AI Gateway.

For this tutorial, bind **`LLMProviderInvoker`** at the parent **Cluster** scope for the ADP cluster ID from the proxy URL:

```text
Role:      LLMProviderInvoker
Scope:     Cluster
Resource:  <cluster-id>
```

> Provider-level scope note: `AI Gateway Model Provider` looks like the narrowest possible scope, but this tutorial has been verified with `LLMProviderInvoker` at `SCOPE_RESOURCE_TYPE_CLUSTER`. If a provider-scoped binding is accepted but the gateway returns `403` with `lacks permission dataplane_adp_llmprovider_invoke on provider "<provider-name>"`, switch to the cluster-scope binding below.

Create the binding with the Control Plane API:

```bash
export ADMIN_TOKEN='<control-plane-token>'

export ROLE_BINDING_ID="$(curl -fsS -X POST 'https://api.redpanda.com/v1/role-bindings' \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data "$(jq -n \
    --arg account_id "${SERVICE_ACCOUNT_ID}" \
    --arg cluster_id "${ADP_CLUSTER_ID}" \
    '{role_binding:{account_id:$account_id,role_name:"LLMProviderInvoker",scope:{resource_type:"SCOPE_RESOURCE_TYPE_CLUSTER",resource_id:$cluster_id}}}')" \
  | jq -r '.role_binding.id')"

echo "Created role binding: ${ROLE_BINDING_ID}"
```

If your ADP gateway is on a serverless cluster, use `SCOPE_RESOURCE_TYPE_SERVERLESS_CLUSTER` instead of `SCOPE_RESOURCE_TYPE_CLUSTER`.

### 3d. Mint an access token

Exchange the service account's OAuth client credentials for a short-lived access token. Do not echo this token in normal usage.

```bash
export AUTH_TOKEN="$(curl -fsS --request POST \
  --url 'https://auth.prd.cloud.redpanda.com/oauth/token' \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data grant_type=client_credentials \
  --data client_id="${CLIENT_ID}" \
  --data client_secret="${CLIENT_SECRET}" \
  --data audience=cloudv2-production.redpanda.cloud | jq -r .access_token)"

test -n "${AUTH_TOKEN}" && test "${AUTH_TOKEN}" != 'null'
```

Tokens expire quickly. Re-run this step before long Claude Code sessions or wrap it in a shell function.

### 3e. Smoke test the Bedrock provider through AI Gateway

Before configuring Claude Code, verify the service account can invoke the Bedrock provider directly:

```bash
export BEDROCK_MODEL_ID='us.anthropic.claude-sonnet-4-6'

curl -i -X POST "${PROXY_URL}/model/${BEDROCK_MODEL_ID}/invoke" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "anthropic_version": "bedrock-2023-05-31",
    "messages": [{"role": "user", "content": "hello"}],
    "max_tokens": 64
  }'
```

Expected result: `HTTP/2 200` and an Anthropic-style message body. If you get `403` with `lacks permission dataplane_adp_llmprovider_invoke`, check that:

- `SERVICE_ACCOUNT_ID` is the service account ID, not the OAuth Client ID.
- The role binding uses `SCOPE_RESOURCE_TYPE_CLUSTER` and `resource_id` equals the `<cluster-id>` from the gateway hostname.
- You minted a fresh token after creating or changing the role binding.

### 3f. Point Claude Code at the ADP gateway

Claude Code reads Anthropic-style environment variables. Use the provider's **Connect** tab when available: choose **Claude Code** from the client dropdown and copy the generated environment variables or settings snippet. The proxy URL must match the provider URL exactly.

```bash
export ANTHROPIC_AUTH_TOKEN="${AUTH_TOKEN}"
export ANTHROPIC_BASE_URL="${PROXY_URL}"

claude "say hello"
```

If Claude Code fails after the Bedrock smoke test succeeds, check the provider type and the generated Connect-tab snippet. Claude Code is Anthropic-compatible, while a raw AWS Bedrock provider uses Bedrock paths such as `/model/<model-id>/invoke`; the smoke test above validates gateway authentication and RBAC for Bedrock.

### 3g. Attach a managed MCP server and verify

1. Attach a managed MCP server to Claude Code. OAuth-protected servers trigger a one-time consent flow, and tokens are cached in ADP's per-user vault.

```bash
claude mcp add petstore "https://aigw.${ADP_CLUSTER_ID}.clusters.rdpa.co/mcp/v1/petstore"
```

2. Verify with `claude "say hello"`. The request should appear in **Cost & Usage** within seconds.

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
