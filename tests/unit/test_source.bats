#!/usr/bin/env bats
# tests/unit/test_source.bats
# Tests for source-code download: branch listing, archive download, extractors.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"

setup_file() {
  export FIXTURES_DIR
}

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  source "$REPO_ROOT/lib/api.sh"

  deps_check

  export GITLAB_AUTH_TYPE=pat
  export GITLAB_TOKEN=testtoken
  export GITLAB_MAX_RETRIES=1
  export GITLAB_RETRY_DELAY=0
  export GITLAB_PER_PAGE=100

  _MAP=$(mktemp)
  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/api/v4/projects/12345/repository/branches",              "fixture": "branches_list.json",   "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/archive?format=tar.gz&sha=missing-branch", "fixture": "error_404.json", "status": 404},
  {"pattern": "/api/v4/projects/12345/repository/archive",               "fixture": "source_archive.bin",   "status": 200},
  {"pattern": "/api/v4/projects/12345",                                  "fixture": "project_single.json",  "status": 200},
  {"pattern": "/api/v4/projects?",                                       "fixture": "projects_list.json",   "status": 200}
]
EOF

  _PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT" "$_MAP" >/dev/null 2>&1 &
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

# --- api_extract_default_branch ---

@test "api_extract_default_branch: returns default_branch from project JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/project_single.json")
  result=$(api_extract_default_branch "$json")
  [ "$result" = "main" ]
}

@test "api_extract_default_branch: returns empty when field absent" {
  result=$(api_extract_default_branch '{"id":1,"name":"no-branch"}')
  [ -z "$result" ]
}

# --- api_extract_branch_name ---

@test "api_extract_branch_name: returns name from branch JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/branches_list.json")
  result=$(api_extract_branch_name "$json")
  [ "$result" = "main" ]
}

@test "api_extract_branch_name: returns name of second branch" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[1]' "$FIXTURES_DIR/branches_list.json")
  result=$(api_extract_branch_name "$json")
  [ "$result" = "staging" ]
}

# --- api_get_project_branches ---

@test "api_get_project_branches: returns branch list for valid project" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_project_branches "12345" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

@test "api_get_project_branches: each line is a valid JSON object" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_project_branches "12345" "$out"
  # Every line should have a 'name' field
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | jq -r '.name // empty' 2>/dev/null)
    [ -n "$name" ]
  done < "$out"
  rm -f "$out"
}

# --- api_download_archive ---

@test "api_download_archive: creates output file for valid branch" {
  out="${_TMP_DIR}/main.tar.gz"
  api_download_archive "12345" "main" "$out"
  [ -f "$out" ]
}

@test "api_download_archive: output file is non-empty" {
  out="${_TMP_DIR}/main.tar.gz"
  api_download_archive "12345" "main" "$out"
  size=$(wc -c < "$out" | tr -d ' ')
  [ "$size" -gt 0 ]
}

@test "api_download_archive: returns non-zero for missing branch" {
  out="${_TMP_DIR}/missing.tar.gz"
  run api_download_archive "12345" "missing-branch" "$out"
  [ "$status" -ne 0 ]
}

@test "api_download_archive: does not create file for missing branch" {
  out="${_TMP_DIR}/missing.tar.gz"
  run api_download_archive "12345" "missing-branch" "$out"
  [ ! -f "$out" ]
}
