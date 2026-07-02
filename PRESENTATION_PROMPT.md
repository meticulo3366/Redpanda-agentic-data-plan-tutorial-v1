# Presentation Prompt — ADP + Claude on Bedrock, End to End

Paste the prompt below into Claude (Claude Code, claude.ai, or the API with the `pptx` skill enabled) to generate a presentation that walks an audience through this repo's end-to-end workflow. Everything the prompt needs is self-contained, but Claude will produce a sharper deck if it can also read `README.md`, `AWS_BEDROCK_SETUP.md`, `adp-claude-code-service-account-auth.sh`, and `TROUBLESHOOTING.md` from this repo.

Adjust the **audience**, **length**, and **format** lines at the top to fit your session.

---

## The prompt

> You are helping me build a technical presentation. Produce a clear, engaging slide deck that explains, end to end, how to stand up Redpanda's Agentic Data Plane (ADP) with Claude served through AWS Bedrock, and how developers then use it through Claude Code and their own services.
>
> **Audience:** solutions engineers and platform/developer teams who are comfortable with AWS and APIs but new to Redpanda ADP. *(Change this if your audience differs.)*
> **Length:** ~12–15 slides, roughly a 20-minute talk. *(Adjust as needed.)*
> **Format:** deliver as a `.pptx` file using the presentation skill. Use presenter notes on each slide with what to say out loud. Keep on-slide text terse (titles + a few bullets or one diagram per slide); put the detail in the notes. Prefer simple diagrams (boxes and arrows described in text) over dense paragraphs.
> **Tone:** practical and confident. This is a "here's how it works and why it's better" story, not a feature dump.
>
> ### What the deck must cover
>
> **1. The problem / why ADP.** Teams want to give developers and agents access to frontier models (Claude) without scattering raw API keys, losing track of spend, or giving up an audit trail. ADP is an **AI Gateway** that sits in front of the model provider: upstream credentials stay server-side, every request is authenticated and attributed, spend shows up in one dashboard, and conversations can be logged for audit.
>
> **2. The architecture, as one diagram.** Show the request path and where governance happens:
> `Developer / Claude Code / a service` → (OAuth bearer token) → `Redpanda ADP AI Gateway` → (holds the AWS creds, enforces RBAC, records usage) → `AWS Bedrock` → `Claude (inference profile, e.g. us.anthropic.claude-sonnet-4-6)`. Call out that MCP tool servers and managed agents also live behind the gateway.
>
> **3. The six-step build.** One slide per phase, in order:
>   1. **LLM Provider** — connect ADP to Claude on Bedrock. Credentials are stored in ADP (Static keys, an assumed IAM role, or the default AWS chain). Current Claude models must be selected by *inference profile ID* (`global.` / `us.` / `eu.` prefixes), not bare model IDs.
>   2. **MCP Server** — register a tool server (Petstore OpenAPI as the demo) and *curate the tool list* down to what the agent needs, so the model's context stays small and safe.
>   3. **OAuth service account (governance)** — the crux. Distinguish clearly between **authentication** (Client ID + Secret mint a short-lived token = *who you are*) and **authorization** (a Redpanda role binding = *what you're allowed to do*). The runtime permission is `dataplane_adp_llmprovider_invoke`, granted via the built-in `LLMProviderInvoker` role bound at **cluster scope**.
>   4. **Managed Agent** — Claude + the curated MCP tools, hosted by Redpanda, with a system prompt and an Inspector to test it.
>   5. **Cost & Usage** — the governance payoff: spend and requests per provider/agent/client, plus optional transcripts for audit.
>   6. **Standalone trigger** — kick off an agent run over plain HTTP from any service, reusing the same OAuth flow.
>
> **4. Authentication vs. authorization — a dedicated slide.** This is where people get stuck. Make the split explicit: the JWT proves identity and may only show broad scopes like `organization-info`; the gateway checks the *actual* invoke permission server-side from the role binding. Note the two IDs that look alike but aren't interchangeable — the **Service Account ID** (used in role bindings) vs. the **OAuth Client ID** (used to mint tokens) — and that mixing them up is the #1 cause of `403`s.
>
> **5. The automation.** Show that the `adp-claude-code-service-account-auth.sh` wrapper collapses all of Step 3 into one command — create service account, bind the role at cluster scope, mint a token, smoke-test Bedrock, write Claude Code's settings, and launch Claude Code — persisting credentials to a git-ignored env file for later runs. Contrast "the manual steps (to understand it)" with "the script (to actually do it)."
>
> **6. Troubleshooting / lessons learned.** One slide of hard-won gotchas: the `403 lacks permission dataplane_adp_llmprovider_invoke` trap and its usual causes (wrong ID bound, provider-scope binding not honored at runtime → use cluster scope, stale token minted before the binding), plus the AWS-side traps (inference profiles required for Claude 4.6+, and the AWS Marketplace IAM permissions needed for Bedrock Marketplace engines).
>
> **7. Wrap-up.** A "what you have now" summary (governed gateway, curated tools, a working agent, two ways to call it) and clear next steps.
>
> ### Guardrails
> - Use **placeholders** for every credential, cluster ID, provider name, account ID, and token (`<cluster-id>`, `<service-account-id>`, `<control-plane-token>`, etc.). Never invent or include anything that looks like a real secret or real infrastructure ID.
> - Keep model IDs accurate: current Claude on Bedrock uses inference-profile IDs like `global.anthropic.claude-opus-4-7`, `us.anthropic.claude-sonnet-4-6`, `us.anthropic.claude-haiku-4-5`.
> - Where a slide references a step, mirror the README's numbering (Steps 1–6, with Step 3 broken into 3a–3h) so the deck and the guide line up.
> - End with an appendix slide listing the repo files (`README.md`, `AWS_BEDROCK_SETUP.md`, `adp-claude-code-service-account-auth.sh`, `TROUBLESHOOTING.md`) so viewers know where to go next.
>
> Before you build the slides, give me a one-paragraph outline of the deck (slide titles only) so I can confirm the flow. Then generate the `.pptx`.

---

## Tips for using this prompt

- **Let it read the repo.** In Claude Code, run it from the repo root so Claude can open the actual files — the deck will match the guide exactly instead of paraphrasing.
- **Iterate on the outline first.** The prompt asks for a titles-only outline before the full deck; tweak the flow there before spending tokens on slide generation.
- **Re-skin for a different audience.** For an exec audience, shorten to ~6 slides and lean on slides 1, 2, 5, and 7 (value, architecture, cost governance, outcomes); drop most of the command-level detail.
- **Speaker-notes demo.** Ask for a companion "live demo script" if you plan to run the `adp-claude-code-service-account-auth.sh` flow on stage.
