#!/usr/bin/env bash
# Bootstrap Claude Code through Redpanda ADP AI Gateway using service-account authentication.
#
# This wrapper is meant to be the command you run instead of calling `claude` directly.
# It can create the Redpanda service account, create the working LLMProviderInvoker
# cluster-scope binding, mint a fresh OAuth token, set Claude Code env vars, and then
# exec Claude Code.
#
# First-time setup example:
#   export ADMIN_TOKEN='<redpanda-control-plane-token>'
#   export PROXY_URL='https://aigw.<cluster-id>.clusters.rdpa.co/llm/v1/providers/<provider-name>'
#   ./adp-claude-code-service-account-auth.sh \
#     --create-service-account \
#     --service-account-name claude-code-llm-invoker \
#     --ensure-rbac \
#     --smoke-test \
#     -- 'say hello'
#
# Existing service-account example:
#   export PROXY_URL='https://aigw.<cluster-id>.clusters.rdpa.co/llm/v1/providers/<provider-name>'
#   export SERVICE_ACCOUNT_ID='<redpanda-service-account-id>'
#   export CLIENT_ID='<redpanda-service-account-oauth-client-id>'
#   read -rsp 'CLIENT_SECRET: ' CLIENT_SECRET; export CLIENT_SECRET; echo
#   ./adp-claude-code-service-account-auth.sh --ensure-rbac -- 'say hello'
#
# Security:
#   - Access tokens and client secrets are never printed by this script.
#   - If credentials are persisted, they are written to .adp-claude-code.env with chmod 600
#     and the file is added to .gitignore.
#   - Rotate any credential that has been pasted into a chat, terminal log, or shared doc.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ROOT_DIR="${ADP_PROJECT_DIR:-$(pwd)}"
ENV_FILE="${ADP_CLAUDE_ENV_FILE:-${ROOT_DIR}/.adp-claude-code.env}"
ENV_EXAMPLE="${ROOT_DIR}/.adp-claude-code.env.example"
CLAUDE_DIR="${ROOT_DIR}/.claude"
SETTINGS_FILE="${ADP_CLAUDE_SETTINGS_FILE:-${CLAUDE_DIR}/settings.local.json}"
TOKEN_HELPER="${ADP_TOKEN_HELPER_FILE:-${CLAUDE_DIR}/adp-service-account-token-helper.sh}"
CONTROL_PLANE_URL="${CONTROL_PLANE_URL:-https://api.redpanda.com}"
AUTH_URL="${AUTH_URL:-https://auth.prd.cloud.redpanda.com/oauth/token}"
AUDIENCE="${AUDIENCE:-cloudv2-production.redpanda.cloud}"

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options] -- [claude arguments]

Core options:
  --proxy-url URL              AI Gateway provider proxy URL.
  --cluster-id ID              ADP cluster/dataplane ID; parsed from proxy URL if omitted.
  --provider-name NAME         ADP provider name; parsed from proxy URL if omitted.
  --service-account-id ID      Redpanda service account ID. Role bindings use this value.
  --client-id ID               OAuth client ID from the service account.
  --client-secret SECRET       OAuth client secret. Prefer prompt/env over CLI to avoid shell history.
  --admin-token TOKEN          Redpanda Control Plane token for create-service-account and RBAC.

Automation options:
  --create-service-account     Create a Redpanda service account when CLIENT_ID/CLIENT_SECRET are absent.
  --service-account-name NAME  Service account name. Default: claude-code-llm-invoker.
  --ensure-rbac                Create LLMProviderInvoker at Cluster or Serverless Cluster scope.
  --serverless                 Force SCOPE_RESOURCE_TYPE_SERVERLESS_CLUSTER for RBAC.
  --scope-resource-type TYPE   Force a role-binding scope resource type.
  --persist-credentials        Save service-account credentials to ${ENV_FILE}.
  --no-persist                 Do not save credentials, even after creating a service account.

Claude Code options:
  --write-settings             Write .claude/settings.local.json and token helper. Default.
  --no-settings                Do not write Claude Code settings/helper.
  --configure-only             Configure, authenticate, and exit without launching claude.
  --mcp-name NAME              MCP server name to add before launch.
  --mcp-url URL                MCP server URL to add before launch.

Validation options:
  --smoke-test                 Run Bedrock invoke smoke test before launching Claude Code.
  --bedrock-model-id MODEL     Smoke-test model. Default: us.anthropic.claude-sonnet-4-6.

Examples:
  First-time setup:
    export ADMIN_TOKEN='<control-plane-token>'
    export PROXY_URL='https://aigw.<cluster-id>.clusters.rdpa.co/llm/v1/providers/<provider-name>'
    ./${SCRIPT_NAME} --create-service-account --ensure-rbac --smoke-test -- 'say hello'

  Reuse persisted credentials later:
    ./${SCRIPT_NAME} -- 'say hello'
USAGE
}

# Source a previously persisted local env file before parsing args. CLI args below still win.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

PROXY_URL="${PROXY_URL:-${ANTHROPIC_BASE_URL:-}}"
ADP_CLUSTER_ID="${ADP_CLUSTER_ID:-}"
ADP_PROVIDER_NAME="${ADP_PROVIDER_NAME:-}"
SERVICE_ACCOUNT_ID="${SERVICE_ACCOUNT_ID:-}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-claude-code-llm-invoker}"
CLIENT_ID="${CLIENT_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
ADP_SCOPE_RESOURCE_TYPE="${ADP_SCOPE_RESOURCE_TYPE:-}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-4-6}"
MCP_NAME="${MCP_NAME:-}"
MCP_URL="${MCP_URL:-}"

CREATE_SERVICE_ACCOUNT=0
ENSURE_RBAC=0
PERSIST_CREDENTIALS=0
NO_PERSIST=0
WRITE_SETTINGS=1
CONFIGURE_ONLY=0
SMOKE_TEST=0
SERVERLESS=0
CLAUDE_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --proxy-url) PROXY_URL="${2:-}"; shift 2 ;;
    --cluster-id) ADP_CLUSTER_ID="${2:-}"; shift 2 ;;
    --provider-name|--provider) ADP_PROVIDER_NAME="${2:-}"; shift 2 ;;
    --service-account-id) SERVICE_ACCOUNT_ID="${2:-}"; shift 2 ;;
    --client-id) CLIENT_ID="${2:-}"; shift 2 ;;
    --client-secret) CLIENT_SECRET="${2:-}"; shift 2 ;;
    --admin-token) ADMIN_TOKEN="${2:-}"; shift 2 ;;
    --create-service-account) CREATE_SERVICE_ACCOUNT=1; PERSIST_CREDENTIALS=1; shift ;;
    --service-account-name) SERVICE_ACCOUNT_NAME="${2:-}"; shift 2 ;;
    --ensure-rbac) ENSURE_RBAC=1; shift ;;
    --serverless) SERVERLESS=1; shift ;;
    --scope-resource-type) ADP_SCOPE_RESOURCE_TYPE="${2:-}"; shift 2 ;;
    --persist-credentials) PERSIST_CREDENTIALS=1; shift ;;
    --no-persist) NO_PERSIST=1; PERSIST_CREDENTIALS=0; shift ;;
    --write-settings) WRITE_SETTINGS=1; shift ;;
    --no-settings) WRITE_SETTINGS=0; shift ;;
    --configure-only) CONFIGURE_ONLY=1; shift ;;
    --mcp-name) MCP_NAME="${2:-}"; shift 2 ;;
    --mcp-url) MCP_URL="${2:-}"; shift 2 ;;
    --smoke-test) SMOKE_TEST=1; shift ;;
    --bedrock-model-id|--model-id) BEDROCK_MODEL_ID="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; CLAUDE_ARGS=("$@"); break ;;
    *) CLAUDE_ARGS+=("$1"); shift ;;
  esac
done

if [ "$NO_PERSIST" -eq 1 ]; then
  PERSIST_CREDENTIALS=0
fi

need_cmd curl
need_cmd jq
need_cmd sed
if [ "$CONFIGURE_ONLY" -eq 0 ]; then
  need_cmd claude
fi
if [ -n "$MCP_URL" ]; then
  need_cmd claude
fi

parse_proxy_url() {
  [ -n "$PROXY_URL" ] || fail "missing PROXY_URL; pass --proxy-url or set PROXY_URL"
  local parsed_cluster parsed_provider
  parsed_cluster="$(printf '%s' "$PROXY_URL" | sed -n 's#^https://aigw\.\([^./]*\)\.clusters\.rdpa\.co/llm/v1/providers/.*#\1#p')"
  parsed_provider="$(printf '%s' "$PROXY_URL" | sed -n 's#^https://aigw\.[^/]*\.clusters\.rdpa\.co/llm/v1/providers/\([^/?#]*\).*#\1#p')"
  [ -n "$ADP_CLUSTER_ID" ] || ADP_CLUSTER_ID="$parsed_cluster"
  [ -n "$ADP_PROVIDER_NAME" ] || ADP_PROVIDER_NAME="$parsed_provider"
  [ -n "$ADP_CLUSTER_ID" ] || fail "could not parse ADP_CLUSTER_ID from PROXY_URL; pass --cluster-id"
  [ -n "$ADP_PROVIDER_NAME" ] || fail "could not parse ADP_PROVIDER_NAME from PROXY_URL; pass --provider-name"
  PROXY_URL="https://aigw.${ADP_CLUSTER_ID}.clusters.rdpa.co/llm/v1/providers/${ADP_PROVIDER_NAME}"
}

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

append_gitignore() {
  local item="$1" gitignore="${ROOT_DIR}/.gitignore"
  touch "$gitignore"
  grep -qxF "$item" "$gitignore" || printf '\n%s\n' "$item" >> "$gitignore"
}

write_env_example() {
  cat > "$ENV_EXAMPLE" <<EOF_EXAMPLE
# Example local Redpanda ADP service-account auth env file.
# Copy to .adp-claude-code.env and chmod 600 it.
# Do not commit the real .adp-claude-code.env file.
PROXY_URL='${PROXY_URL}'
ADP_CLUSTER_ID='${ADP_CLUSTER_ID}'
ADP_PROVIDER_NAME='${ADP_PROVIDER_NAME}'
SERVICE_ACCOUNT_ID='<redpanda-service-account-id>'
CLIENT_ID='<redpanda-service-account-oauth-client-id>'
CLIENT_SECRET='<redpanda-service-account-oauth-client-secret>'
AUTH_URL='${AUTH_URL}'
AUDIENCE='${AUDIENCE}'
EOF_EXAMPLE
}

persist_env_file() {
  [ "$PERSIST_CREDENTIALS" -eq 1 ] || return 0
  [ -n "$CLIENT_ID" ] || fail "cannot persist credentials without CLIENT_ID"
  [ -n "$CLIENT_SECRET" ] || fail "cannot persist credentials without CLIENT_SECRET"
  umask 077
  cat > "$ENV_FILE" <<EOF_ENV
# Local Redpanda ADP service-account auth for Claude Code.
# Generated by ${SCRIPT_NAME}. Do not commit this file.
PROXY_URL=$(sq "$PROXY_URL")
ADP_CLUSTER_ID=$(sq "$ADP_CLUSTER_ID")
ADP_PROVIDER_NAME=$(sq "$ADP_PROVIDER_NAME")
SERVICE_ACCOUNT_ID=$(sq "$SERVICE_ACCOUNT_ID")
CLIENT_ID=$(sq "$CLIENT_ID")
CLIENT_SECRET=$(sq "$CLIENT_SECRET")
AUTH_URL=$(sq "$AUTH_URL")
AUDIENCE=$(sq "$AUDIENCE")
ANTHROPIC_BASE_URL=$(sq "$PROXY_URL")
EOF_ENV
  chmod 600 "$ENV_FILE"
  append_gitignore ".adp-claude-code.env"
  log "persisted service-account credentials to ${ENV_FILE}"
}

create_service_account() {
  [ -n "$ADMIN_TOKEN" ] || fail "--create-service-account requires ADMIN_TOKEN"
  log "creating Redpanda service account: ${SERVICE_ACCOUNT_NAME}"
  local payload body status response
  payload="$(jq -n --arg name "$SERVICE_ACCOUNT_NAME" '{service_account:{name:$name,description:"Service account for Claude Code through ADP AI Gateway"}}')"
  response="$(curl -sS --request POST \
    --url "${CONTROL_PLANE_URL}/v1/service-accounts" \
    --header 'content-type: application/json' \
    --header "authorization: Bearer ${ADMIN_TOKEN}" \
    --data "$payload" \
    -w '\n%{http_code}')"
  body="${response%$'\n'*}"
  status="${response##*$'\n'}"
  case "$status" in
    200|201) ;;
    *) printf '%s\n' "$body" >&2; fail "service-account creation failed with HTTP ${status}" ;;
  esac
  SERVICE_ACCOUNT_ID="$(printf '%s' "$body" | jq -r '.service_account.id // .serviceAccount.id // .id // empty')"
  CLIENT_ID="$(printf '%s' "$body" | jq -r '.service_account.auth0_client_credentials.client_id // .serviceAccount.auth0ClientCredentials.clientId // .auth0_client_credentials.client_id // .client_id // empty')"
  CLIENT_SECRET="$(printf '%s' "$body" | jq -r '.service_account.auth0_client_credentials.client_secret // .serviceAccount.auth0ClientCredentials.clientSecret // .auth0_client_credentials.client_secret // .client_secret // empty')"
  [ -n "$SERVICE_ACCOUNT_ID" ] || fail "could not parse service account ID from create response"
  [ -n "$CLIENT_ID" ] || fail "could not parse OAuth client ID from create response"
  [ -n "$CLIENT_SECRET" ] || fail "could not parse OAuth client secret from create response"
  log "created service account ID: ${SERVICE_ACCOUNT_ID}"
  log "captured OAuth client ID and secret; secret was not printed"
}

prompt_client_secret_if_needed() {
  if [ -z "$CLIENT_SECRET" ]; then
    printf 'CLIENT_SECRET: ' >&2
    stty -echo 2>/dev/null || true
    IFS= read -r CLIENT_SECRET
    stty echo 2>/dev/null || true
    printf '\n' >&2
  fi
  [ -n "$CLIENT_SECRET" ] || fail "missing CLIENT_SECRET"
}

resolve_scope_resource_type() {
  if [ -n "$ADP_SCOPE_RESOURCE_TYPE" ]; then
    printf '%s' "$ADP_SCOPE_RESOURCE_TYPE"
    return 0
  fi
  if [ "$SERVERLESS" -eq 1 ]; then
    printf '%s' 'SCOPE_RESOURCE_TYPE_SERVERLESS_CLUSTER'
    return 0
  fi
  [ -n "$ADMIN_TOKEN" ] || { printf '%s' 'SCOPE_RESOURCE_TYPE_CLUSTER'; return 0; }
  local cluster_code serverless_code
  cluster_code="$(curl -sS -o /dev/null -w '%{http_code}' "${CONTROL_PLANE_URL}/v1/clusters/${ADP_CLUSTER_ID}" -H "Authorization: Bearer ${ADMIN_TOKEN}" || true)"
  if [ "$cluster_code" = '200' ]; then
    printf '%s' 'SCOPE_RESOURCE_TYPE_CLUSTER'
    return 0
  fi
  serverless_code="$(curl -sS -o /dev/null -w '%{http_code}' "${CONTROL_PLANE_URL}/v1/serverless/clusters/${ADP_CLUSTER_ID}" -H "Authorization: Bearer ${ADMIN_TOKEN}" || true)"
  if [ "$serverless_code" = '200' ]; then
    printf '%s' 'SCOPE_RESOURCE_TYPE_SERVERLESS_CLUSTER'
    return 0
  fi
  fail "could not resolve cluster scope type; cluster=${cluster_code}, serverless=${serverless_code}"
}

ensure_rbac() {
  [ "$ENSURE_RBAC" -eq 1 ] || return 0
  [ -n "$ADMIN_TOKEN" ] || fail "--ensure-rbac requires ADMIN_TOKEN"
  [ -n "$SERVICE_ACCOUNT_ID" ] || fail "--ensure-rbac requires SERVICE_ACCOUNT_ID or --create-service-account"
  local scope_type payload response body status rb_id
  scope_type="$(resolve_scope_resource_type)"
  log "creating LLMProviderInvoker at ${scope_type} ${ADP_CLUSTER_ID} for service account ${SERVICE_ACCOUNT_ID}"
  payload="$(jq -n --arg account_id "$SERVICE_ACCOUNT_ID" --arg scope_type "$scope_type" --arg cluster_id "$ADP_CLUSTER_ID" '{role_binding:{account_id:$account_id,role_name:"LLMProviderInvoker",scope:{resource_type:$scope_type,resource_id:$cluster_id}}}')"
  response="$(curl -sS -X POST "${CONTROL_PLANE_URL}/v1/role-bindings" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -w '\n%{http_code}')"
  body="${response%$'\n'*}"
  status="${response##*$'\n'}"
  case "$status" in
    200|201)
      rb_id="$(printf '%s' "$body" | jq -r '.role_binding.id // .roleBinding.id // .id // empty')"
      log "created role binding: ${rb_id:-unknown}"
      ;;
    409)
      warn "role binding may already exist; continuing"
      ;;
    *)
      printf '%s\n' "$body" >&2
      fail "role-binding creation failed with HTTP ${status}"
      ;;
  esac
}

write_token_helper() {
  [ "$WRITE_SETTINGS" -eq 1 ] || return 0
  mkdir -p "$CLAUDE_DIR"
  cat > "$TOKEN_HELPER" <<'EOF_HELPER'
#!/usr/bin/env bash
set -euo pipefail
helper_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(CDPATH= cd -- "${helper_dir}/.." && pwd)"
env_file="${ADP_CLAUDE_ENV_FILE:-${project_dir}/.adp-claude-code.env}"
if [ -f "$env_file" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
fi
: "${CLIENT_ID:?missing CLIENT_ID for Redpanda service-account auth}"
: "${CLIENT_SECRET:?missing CLIENT_SECRET for Redpanda service-account auth}"
AUTH_URL="${AUTH_URL:-https://auth.prd.cloud.redpanda.com/oauth/token}"
AUDIENCE="${AUDIENCE:-cloudv2-production.redpanda.cloud}"
token="$(curl -fsS --request POST \
  --url "$AUTH_URL" \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  --data-urlencode "audience=${AUDIENCE}" | jq -r '.access_token')"
[ -n "$token" ] && [ "$token" != 'null' ] || { printf 'failed to mint Redpanda ADP access token\n' >&2; exit 1; }
printf '%s\n' "$token"
EOF_HELPER
  chmod 700 "$TOKEN_HELPER"
  log "wrote token helper: ${TOKEN_HELPER}"
}

write_claude_settings() {
  [ "$WRITE_SETTINGS" -eq 1 ] || return 0
  mkdir -p "$CLAUDE_DIR"
  local tmp
  tmp="$(mktemp)"
  if [ -s "$SETTINGS_FILE" ]; then
    jq --arg helper "$TOKEN_HELPER" --arg base_url "$PROXY_URL" '
      .apiKeyHelper = $helper |
      .env = (.env // {}) |
      .env.ANTHROPIC_BASE_URL = $base_url |
      .env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = (.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS // "600000")
    ' "$SETTINGS_FILE" > "$tmp"
  else
    jq -n --arg helper "$TOKEN_HELPER" --arg base_url "$PROXY_URL" '{apiKeyHelper:$helper,env:{ANTHROPIC_BASE_URL:$base_url,CLAUDE_CODE_API_KEY_HELPER_TTL_MS:"600000"}}' > "$tmp"
  fi
  mv "$tmp" "$SETTINGS_FILE"
  chmod 600 "$SETTINGS_FILE" || true
  log "wrote Claude Code settings: ${SETTINGS_FILE}"
}

mint_token_now() {
  [ -n "$CLIENT_ID" ] || fail "missing CLIENT_ID; set it or use --create-service-account"
  prompt_client_secret_if_needed
  export CLIENT_ID CLIENT_SECRET AUTH_URL AUDIENCE
  local token
  if [ -x "$TOKEN_HELPER" ]; then
    token="$($TOKEN_HELPER)"
  else
    token="$(curl -fsS --request POST \
      --url "$AUTH_URL" \
      --header 'content-type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "client_secret=${CLIENT_SECRET}" \
      --data-urlencode "audience=${AUDIENCE}" | jq -r '.access_token')"
  fi
  [ -n "$token" ] && [ "$token" != 'null' ] || fail "token response did not include access_token"
  AUTH_TOKEN="$token"
  export AUTH_TOKEN
  export ANTHROPIC_AUTH_TOKEN="$token"
  export ANTHROPIC_BASE_URL="$PROXY_URL"
}

run_smoke_test() {
  [ "$SMOKE_TEST" -eq 1 ] || return 0
  log "running Bedrock smoke test for ${ADP_PROVIDER_NAME} using ${BEDROCK_MODEL_ID}"
  curl -i -X POST "${PROXY_URL}/model/${BEDROCK_MODEL_ID}/invoke" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{
      "anthropic_version": "bedrock-2023-05-31",
      "messages": [{"role": "user", "content": "hello"}],
      "max_tokens": 64
    }'
  printf '\n' >&2
}

add_mcp_if_requested() {
  [ -n "$MCP_URL" ] || return 0
  [ -n "$MCP_NAME" ] || MCP_NAME='adp-mcp'
  log "adding MCP server to Claude Code: ${MCP_NAME}"
  if claude mcp get "$MCP_NAME" >/dev/null 2>&1; then
    log "MCP server already configured: ${MCP_NAME}"
  else
    claude mcp add --transport http --scope local "$MCP_NAME" "$MCP_URL"
  fi
}

main() {
  parse_proxy_url
  write_env_example
  mkdir -p "$CLAUDE_DIR"

  if [ "$CREATE_SERVICE_ACCOUNT" -eq 1 ]; then
    create_service_account
  fi

  [ -n "$CLIENT_ID" ] || fail "missing CLIENT_ID; set it or use --create-service-account"
  prompt_client_secret_if_needed

  ensure_rbac
  persist_env_file
  write_token_helper
  write_claude_settings
  mint_token_now

  log "service-account authentication succeeded"
  log "ANTHROPIC_BASE_URL=${PROXY_URL}"
  log "ANTHROPIC_AUTH_TOKEN is set for the Claude Code process; token was not printed"

  run_smoke_test
  add_mcp_if_requested

  if [ "$CONFIGURE_ONLY" -eq 1 ]; then
    log "configure-only complete"
    exit 0
  fi

  log "starting Claude Code"
  exec claude "${CLAUDE_ARGS[@]}"
}

main
