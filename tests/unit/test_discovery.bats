#!/usr/bin/env bats
# tests/unit/test_discovery.bats
# Tests for discovery mode: accessible resource crawl and report generation.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  source "$REPO_ROOT/lib/api.sh"
  source "$REPO_ROOT/lib/discovery.sh"

  deps_check

  export GITLAB_AUTH_TYPE=pat
  export GITLAB_TOKEN=testtoken
  export GITLAB_MAX_RETRIES=1
  export GITLAB_RETRY_DELAY=0
  export GITLAB_PER_PAGE=100

  _MAP=$(mktemp)
  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/api/v4/personal_access_tokens/self", "fixture": "pat_scopes_full.json",  "status": 200},
  {"pattern": "/api/v4/user",                        "fixture": "current_user.json",      "status": 200},
  {"pattern": "/api/v4/groups?",                     "fixture": "groups_list.json",       "status": 200},
  {"pattern": "/api/v4/projects?",                   "fixture": "projects_list.json",     "status": 200}
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
  _TMP_DIR=$(mktemp -d)
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
  rm -rf "$_TMP_DIR"
}

# --- api_get_accessible_groups ---

@test "api_get_accessible_groups: writes groups to output file" {
  out=$(mktemp)
  api_get_accessible_groups "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -ge 1 ]
}

@test "api_get_accessible_groups: each line is a valid JSON object with id field" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_accessible_groups "$out"
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)
    [ -n "$id" ]
  done < "$out"
  rm -f "$out"
}

@test "api_get_accessible_groups: returns two groups from fixture" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_accessible_groups "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

# --- api_get_accessible_projects ---

@test "api_get_accessible_projects: writes projects to output file" {
  out=$(mktemp)
  api_get_accessible_projects "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -ge 1 ]
}

@test "api_get_accessible_projects: each line has a path_with_namespace field" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_accessible_projects "$out"
  while IFS= read -r line; do
    ns=$(printf '%s' "$line" | jq -r '.path_with_namespace // empty' 2>/dev/null)
    [ -n "$ns" ]
  done < "$out"
  rm -f "$out"
}

# --- discovery_write_scope_report ---

@test "discovery_write_scope_report: produces non-empty output" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  result=$(discovery_write_scope_report "$user_json" "$pat_json")
  [ -n "$result" ]
}

@test "discovery_write_scope_report: output contains authenticated username" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  result=$(discovery_write_scope_report "$user_json" "$pat_json")
  [[ "$result" =~ "testuser" ]]
}

@test "discovery_write_scope_report: output contains token name" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  result=$(discovery_write_scope_report "$user_json" "$pat_json")
  [[ "$result" =~ "exporter-token" ]]
}

@test "discovery_write_scope_report: output contains scopes" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  result=$(discovery_write_scope_report "$user_json" "$pat_json")
  [[ "$result" =~ "api" ]]
}

@test "discovery_write_scope_report: marks wiki/issue/MR capability as yes when api scope present" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_full.json")
  result=$(discovery_write_scope_report "$user_json" "$pat_json")
  [[ "$result" =~ "yes" ]]
}

@test "discovery_write_scope_report: marks source capability as no when read_repository absent" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  pat_json=$(cat "$FIXTURES_DIR/pat_scopes_no_repo.json")
  result=$(discovery_write_scope_report "$user_json" "$pat_json")
  [[ "$result" =~ "no" ]]
}

@test "discovery_write_scope_report: works without pat_json (non-PAT auth)" {
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  result=$(discovery_write_scope_report "$user_json" "")
  [ -n "$result" ]
}

# --- discovery_write_index ---

@test "discovery_write_index: produces non-empty output" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  groups_file=$(mktemp)
  projects_file=$(mktemp)
  jq -c '.[]' "$FIXTURES_DIR/groups_list.json"   > "$groups_file"
  jq -c '.[]' "$FIXTURES_DIR/projects_list.json" > "$projects_file"
  result=$(discovery_write_index "$user_json" "$groups_file" "$projects_file")
  rm -f "$groups_file" "$projects_file"
  [ -n "$result" ]
}

@test "discovery_write_index: output contains group path" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  groups_file=$(mktemp)
  projects_file=$(mktemp)
  jq -c '.[]' "$FIXTURES_DIR/groups_list.json"   > "$groups_file"
  jq -c '.[]' "$FIXTURES_DIR/projects_list.json" > "$projects_file"
  result=$(discovery_write_index "$user_json" "$groups_file" "$projects_file")
  rm -f "$groups_file" "$projects_file"
  [[ "$result" =~ "test-group" ]]
}

@test "discovery_write_index: output contains project namespace" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  groups_file=$(mktemp)
  projects_file=$(mktemp)
  jq -c '.[]' "$FIXTURES_DIR/groups_list.json"   > "$groups_file"
  jq -c '.[]' "$FIXTURES_DIR/projects_list.json" > "$projects_file"
  result=$(discovery_write_index "$user_json" "$groups_file" "$projects_file")
  rm -f "$groups_file" "$projects_file"
  [[ "$result" =~ "my-test-project" ]]
}

@test "discovery_write_index: output contains group count" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  groups_file=$(mktemp)
  projects_file=$(mktemp)
  jq -c '.[]' "$FIXTURES_DIR/groups_list.json"   > "$groups_file"
  jq -c '.[]' "$FIXTURES_DIR/projects_list.json" > "$projects_file"
  result=$(discovery_write_index "$user_json" "$groups_file" "$projects_file")
  rm -f "$groups_file" "$projects_file"
  # 2 groups in groups_list.json
  [[ "$result" =~ "2" ]]
}

@test "discovery_write_index: output contains instance URL" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  user_json=$(cat "$FIXTURES_DIR/current_user.json")
  groups_file=$(mktemp)
  projects_file=$(mktemp)
  jq -c '.[]' "$FIXTURES_DIR/groups_list.json"   > "$groups_file"
  jq -c '.[]' "$FIXTURES_DIR/projects_list.json" > "$projects_file"
  result=$(discovery_write_index "$user_json" "$groups_file" "$projects_file")
  rm -f "$groups_file" "$projects_file"
  [[ "$result" =~ "${GITLAB_URL}" ]]
}
