#!/usr/bin/env bats
# tests/unit/test_scope.bats
# Tests for credential scope / permission checks.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"

  deps_check

  export GITLAB_AUTH_TYPE=pat
  export GITLAB_TOKEN=testtoken
  export GITLAB_MAX_RETRIES=1
  export GITLAB_RETRY_DELAY=0

  _MAP=$(mktemp)
  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/api/v4/personal_access_tokens/self", "fixture": "pat_scopes_full.json", "status": 200},
  {"pattern": "/api/v4/user",                        "fixture": "current_user.json",     "status": 200},
  {"pattern": "/api/v4/projects?",                   "fixture": "projects_list.json",    "status": 200}
]
EOF

  _PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  FIXTURES_DIR="$FIXTURES_DIR" python3 "$HELPERS_DIR/fixture_server.py" "$_PORT" "$_MAP" >/dev/null 2>&1 &
  _SERVER_PID=$!

  local i=0
  until curl -s "http://127.0.0.1:${_PORT}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  export GITLAB_URL="http://127.0.0.1:${_PORT}"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
}

# --- auth_whoami ---

@test "auth_whoami: returns JSON response" {
  result=$(auth_whoami)
  [ -n "$result" ]
}

@test "auth_whoami: response contains username field" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  result=$(auth_whoami)
  username=$(printf '%s' "$result" | jq -r '.username')
  [ "$username" = "testuser" ]
}

@test "auth_whoami: response contains name field" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  result=$(auth_whoami)
  name=$(printf '%s' "$result" | jq -r '.name')
  [ "$name" = "Test User" ]
}

# --- auth_get_pat_scopes ---

@test "auth_get_pat_scopes: returns JSON response" {
  result=$(auth_get_pat_scopes)
  [ -n "$result" ]
}

@test "auth_get_pat_scopes: response contains scopes array" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  result=$(auth_get_pat_scopes)
  scopes=$(printf '%s' "$result" | jq -r '.scopes | type')
  [ "$scopes" = "array" ]
}

@test "auth_get_pat_scopes: response contains token name" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  result=$(auth_get_pat_scopes)
  name=$(printf '%s' "$result" | jq -r '.name')
  [ "$name" = "exporter-token" ]
}

# --- auth_scope_present ---

@test "auth_scope_present: returns true when scope is in the list" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  auth_scope_present '["api","read_repository"]' "api"
}

@test "auth_scope_present: returns true for read_repository" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  auth_scope_present '["read_api","read_repository"]' "read_repository"
}

@test "auth_scope_present: returns false when scope is absent" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  run auth_scope_present '["read_user"]' "read_api"
  [ "$status" -ne 0 ]
}

@test "auth_scope_present: returns false for empty scopes array" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  run auth_scope_present '[]' "api"
  [ "$status" -ne 0 ]
}

# --- auth_analyze_pat_scopes ---

@test "auth_analyze_pat_scopes: exits 0 when api scope present" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  run auth_analyze_pat_scopes "$pat_json"
  [ "$status" -eq 0 ]
}

@test "auth_analyze_pat_scopes: exits 0 when read_api + read_repository present" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_readonly.json")
  run auth_analyze_pat_scopes "$pat_json"
  [ "$status" -eq 0 ]
}

@test "auth_analyze_pat_scopes: exits non-zero when api and read_api both absent" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_limited.json")
  run auth_analyze_pat_scopes "$pat_json"
  [ "$status" -ne 0 ]
}

@test "auth_analyze_pat_scopes: output includes warning when read_repository absent" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_no_repo.json")
  run auth_analyze_pat_scopes "$pat_json"
  # Should exit 0 (read_api is present) but warn about missing read_repository
  [ "$status" -eq 0 ]
  [[ "$output" =~ "read_repository" ]]
}

@test "auth_analyze_pat_scopes: reports token name" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  run auth_analyze_pat_scopes "$pat_json"
  [[ "$output" =~ "exporter-token" ]]
}

# --- auth_check_scope ---

@test "auth_check_scope: exits 0 with valid user and full api scope" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  run auth_check_scope
  [ "$status" -eq 0 ]
}

@test "auth_check_scope: output includes authenticated username" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  run auth_check_scope
  [[ "$output" =~ "testuser" ]]
}

@test "auth_check_scope: output includes token scopes" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  run auth_check_scope
  [[ "$output" =~ "api" ]]
}
