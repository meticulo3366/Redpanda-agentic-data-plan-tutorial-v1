# Troubleshooting

Fixes for the most common snags when setting up the ADP AI Gateway with the AWS Bedrock provider. The variable names below (`SERVICE_ACCOUNT_ID`, `CLIENT_ID`, `ADP_CLUSTER_ID`, `AUTH_TOKEN`, `ADMIN_TOKEN`, `PROXY_URL`) are the ones you exported in [Step 3 of the README](./README.md#3-set-up-an-oauth-service-account-for-claude-code--ai-gateway-governance).

---

## `403 lacks permission dataplane_adp_llmprovider_invoke`

Good news first: a `403` here means your **token is valid** and the request reached the gateway. The problem is authorization — the service account's role binding doesn't cover what you're trying to call. Work through these in order; the first one catches most cases.

### 1. You bound the wrong ID (this is the usual culprit)

Role bindings key off the **Service Account ID**, not the OAuth **Client ID**. The two look almost identical, so they're easy to swap by accident.

```bash
# The role binding must use the service account ID, NOT $CLIENT_ID
echo "SERVICE_ACCOUNT_ID = ${SERVICE_ACCOUNT_ID}"
echo "CLIENT_ID          = ${CLIENT_ID}"   # different value — not the one to use here

# List the bindings for your service account and confirm one exists
curl -fsS 'https://api.redpanda.com/v1/role-bindings' \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  | jq --arg id "${SERVICE_ACCOUNT_ID}" \
      '.role_bindings[] | select(.account_id == $id) | {id, role_name, scope}'
```

If that prints nothing, the binding was made against the wrong ID. Recreate it (README 3d) with `account_id = ${SERVICE_ACCOUNT_ID}`.

### 2. The scope or resource ID is off

If the error names a provider — `lacks permission ... on provider "<provider-name>"` — you've hit the provider-scope trap: the binding was accepted but isn't honored at runtime. This guide is verified with **`LLMProviderInvoker` at *cluster* scope**. Confirm the binding uses `SCOPE_RESOURCE_TYPE_CLUSTER` and that its `resource_id` is the `<cluster-id>` from your gateway hostname (`aigw.<cluster-id>.clusters.rdpa.co`):

```bash
echo "ADP_CLUSTER_ID = ${ADP_CLUSTER_ID}"   # should match the host in PROXY_URL

curl -fsS 'https://api.redpanda.com/v1/role-bindings' \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  | jq --arg id "${SERVICE_ACCOUNT_ID}" \
      '.role_bindings[] | select(.account_id == $id) | .scope'
# Expect: { "resource_type": "SCOPE_RESOURCE_TYPE_CLUSTER", "resource_id": "<cluster-id>" }
```

Depending on what you find:

- **On a serverless cluster?** Use `SCOPE_RESOURCE_TYPE_SERVERLESS_CLUSTER` instead of `SCOPE_RESOURCE_TYPE_CLUSTER`.
- **`resource_id` doesn't match?** It must be the bare `<cluster-id>` — never the full proxy URL or the provider name.
- **Bound at provider scope?** Delete that binding and recreate it at cluster scope (README 3d).

### 3. Your token is stale

Permission changes don't apply retroactively to tokens you've already minted. So if you created or edited the binding *after* getting your token, the old token still carries the old (missing) permissions. Just **mint a fresh one** (README 3e) and retry:

```bash
# Re-run README 3e, then confirm the token isn't empty
test -n "${AUTH_TOKEN}" && test "${AUTH_TOKEN}" != 'null' && echo "token OK"
```

### 4. Everything looks right but it's still 403

- **Give it a moment.** New bindings can take ~30–60 seconds to propagate. Wait, then retry.
- **Check the org matches.** The `ADMIN_TOKEN` you used to create the binding has to belong to the same organization as the ADP cluster in your `PROXY_URL`.
- **A 403 naming the provider is still an RBAC problem, not a typo.** If the provider name were wrong, you'd generally get a `404`, not a `403`.

---

## Not a 403?

- **`401 Unauthorized`** — the token is missing, expired, or malformed. Re-mint it (README 3e).
- **`404 Not Found`** — the proxy URL, provider name, or model ID is wrong. Re-check README 3a and confirm you're using a valid Bedrock inference-profile ID (e.g. `us.anthropic.claude-sonnet-4-6`).
