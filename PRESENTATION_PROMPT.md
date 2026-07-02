# Presentation Prompt — Redpanda ADP Value Story + Live Onboarding

Paste the prompt below into Claude (Claude Code, claude.ai, or the API with the `pptx` skill enabled) to generate a presentation that leads with **Redpanda Agentic Data Plane's value drivers** and proves them by walking through the hands-on onboarding in this repo.

The deck is a value story first, a tutorial second: every build step maps back to a Redpanda pillar so the audience sees *why* each piece matters, not just *how* to click it.

Source of truth for the messaging: **[redpanda.com/agentic-data-plane](https://www.redpanda.com/agentic-data-plane)**. Claude will produce a sharper deck if it can also read `README.md`, `AWS_BEDROCK_SETUP.md`, `adp-claude-code-service-account-auth.sh`, and `TROUBLESHOOTING.md` from this repo.

Adjust the **audience**, **length**, and **format** lines at the top to fit your session.

---

## The prompt

> You are helping me build a technical value presentation about Redpanda's **Agentic Data Plane (ADP)**. The deck must lead with Redpanda's value drivers and then *prove* them by walking through a real onboarding: standing up ADP with Claude on AWS Bedrock, and using it from Claude Code and a standalone service. This is a "why ADP, shown live" story — not a feature list.
>
> **Audience:** solutions engineers and platform/developer teams evaluating ADP; comfortable with AWS and APIs, new to Redpanda ADP. *(Change if your audience differs.)*
> **Length:** ~14–16 slides, ~25-minute talk. *(Adjust as needed.)*
> **Format:** deliver as a `.pptx` using the presentation skill. Terse on-slide text (title + a few bullets or one diagram); put the talk track in presenter notes on every slide. Prefer simple box-and-arrow diagrams described in text over dense paragraphs.
> **Tone:** confident, outcome-oriented, credible with a technical crowd.
>
> ### Anchor everything on Redpanda's value drivers
>
> Use Redpanda's own framing from redpanda.com/agentic-data-plane. Build the narrative spine around the **three pillars ("3 Cs")**:
>
> 1. **Connect** — give agents secure, mediated access to models, apps, and data (300+ connectors; MCP, Kafka, Iceberg, SQL; open protocols like MCP/A2A/OTel).
> 2. **Control** — define agent roles, behaviors, and permissions with clear scopes and budgets (OIDC identity, on-behalf-of authorization, fine-grained data filtering/redaction, token budgets, spend limits, LLM routing with failover).
> 3. **Operate** — observe, control, and record every action for quality and cost (browse/debug agent behavior, session replay, immutable audit logs, transcript export, a "kill switch" to stop misbehaving agents).
>
> Weave in these headline messages where they land naturally: **"The backbone of the autonomous workforce,"** the problem framing **"Enterprise agents are stuck in single-player mode,"** the core promise **"See, control, and trust every AI agent you run,"** and the payoff of getting a team ready for **"multiplayer mode."** Also touch the deploy-anywhere story (VPC, airgapped, multitenant cloud) and that Redpanda is a data-infrastructure specialist, so this is fast and efficient by pedigree.
>
> ### Deck structure
>
> **Part 1 — The value story (why ADP):**
> 1. **Title** — ADP: the backbone of the autonomous workforce.
> 2. **The problem** — enterprise agents are stuck in single-player mode: no trusted access to operational data, no way to govern behavior in production, no audit trail, no cost visibility. Loose API keys and ungoverned agents don't scale.
> 3. **The promise** — see, control, and trust every AI agent you run. Introduce the 3 Cs (Connect / Control / Operate) as the through-line for the rest of the deck.
> 4. **One-slide architecture** — the request path and where governance happens: `Developer / Claude Code / a service` → (OIDC bearer token) → `Redpanda ADP AI Gateway` (holds provider creds, enforces RBAC, meters + records) → `AWS Bedrock` → `Claude (inference profile, e.g. us.anthropic.claude-sonnet-4-6)`. Show MCP tool servers and managed agents living behind the same gateway. Label each hop with the pillar it serves.
>
> **Part 2 — Prove it with the onboarding (map each step to a pillar):**
> 5. **Connect: the LLM provider** *(Connect)* — plug Claude-on-Bedrock into ADP once; upstream AWS credentials live in ADP, not in every developer's shell. Note current Claude models use Bedrock *inference profile IDs* (`global.`/`us.`/`eu.` prefixes), not bare IDs.
> 6. **Connect: MCP tools** *(Connect)* — register a tool server (Petstore OpenAPI demo) and *curate the tool list* so agents get exactly the tools they need — smaller context, safer behavior.
> 7. **Control: identity + least-privilege** *(Control)* — the OAuth service account. Make the authentication-vs-authorization split explicit: Client ID + Secret mint a short-lived token (*who you are*); a Redpanda role binding decides *what you can do*. Runtime permission `dataplane_adp_llmprovider_invoke` via the built-in `LLMProviderInvoker` role at **cluster scope**. Call out the two look-alike IDs (Service Account ID for bindings vs. OAuth Client ID for tokens) — mixing them up is the #1 cause of `403`s.
> 8. **Control: budgets & routing** *(Control)* — connect the hands-on RBAC to the broader Control story: token budgets, spend limits, LLM routing/failover, data redaction. (Conceptual — reinforces the pillar beyond what the tutorial configures.)
> 9. **Build the agent** *(Connect + Control)* — a Redpanda-managed agent = Claude + curated MCP tools + a system prompt, testable in the Inspector. Mention multi-agent/sub-agent orchestration as the scale story.
> 10. **Operate: cost & usage** *(Operate)* — the governance payoff made visible: spend and requests per provider/agent/client, transcripts for audit, and the "kill switch" concept for stopping a bad agent.
> 11. **Operate: call it from anywhere** *(Operate/Connect)* — trigger an agent run over plain HTTP from any service using the same OIDC flow; every call is still governed and recorded.
>
> **Part 3 — Make it real & land it:**
> 12. **From clicks to one command** — the `adp-claude-code-service-account-auth.sh` wrapper collapses the whole Control step into one command (create service account, bind the role at cluster scope, mint a token, smoke-test Bedrock, write Claude Code settings, launch Claude Code), persisting creds to a git-ignored env file. Frame it as "understand it manually once, then automate it."
> 13. **Lessons learned / gotchas** — the `403 lacks permission dataplane_adp_llmprovider_invoke` trap (wrong ID bound; provider-scope binding not honored at runtime → use cluster scope; stale token minted before the binding), and the AWS-side traps (inference profiles required for Claude 4.6+, AWS Marketplace IAM permissions for Bedrock Marketplace engines).
> 14. **Deploy anywhere + why Redpanda** — VPC, airgapped, multitenant cloud; open protocols (MCP, A2A, OTel, Copilot SDK); performance/efficiency from a data-infra specialist.
> 15. **Get to multiplayer mode** — recap the 3 Cs, "what you have now" (governed gateway, curated tools, a working agent, two ways to call it), and clear next steps.
> 16. **Appendix** — repo file map (`README.md`, `AWS_BEDROCK_SETUP.md`, `adp-claude-code-service-account-auth.sh`, `TROUBLESHOOTING.md`) and links.
>
> ### Guardrails
> - **Value drivers lead; the tutorial is the evidence.** Every onboarding slide should visibly tie back to Connect / Control / Operate — don't let it drift into a pure click-through.
> - Use **placeholders** for every credential, cluster ID, provider name, account ID, and token (`<cluster-id>`, `<service-account-id>`, `<control-plane-token>`, etc.). Never invent or include anything resembling a real secret or real infrastructure ID.
> - Keep model IDs accurate: current Claude on Bedrock uses inference-profile IDs like `global.anthropic.claude-opus-4-7`, `us.anthropic.claude-sonnet-4-6`, `us.anthropic.claude-haiku-4-5`.
> - Mirror the README's numbering when referencing steps (Steps 1–6; Step 3 is 3a–3h) so the deck and guide line up.
> - Attribute the value messaging to redpanda.com/agentic-data-plane; don't overclaim beyond what that page and this repo support.
>
> Before building slides, give me a titles-only outline so I can confirm the flow. Then generate the `.pptx`.

---

## Tips for using this prompt

- **Let it read the repo.** Run it from the repo root in Claude Code so Claude opens the real files — the onboarding slides will match the guide exactly.
- **Confirm the outline first.** The prompt asks for a titles-only outline before the deck; adjust the flow there before generating slides.
- **Exec cut.** For a leadership audience, drop to ~7 slides and keep 1–4, 7, 10, and 15 (problem, promise, 3 Cs, architecture, identity/governance, cost visibility, outcomes) — trim the command-level detail.
- **Live-demo companion.** Ask for a "live demo script" that runs `adp-claude-code-service-account-auth.sh` end to end, with talk-track tied to the Control and Operate pillars.
