#!/usr/bin/env bats
# tests/integration/test_discovery_export.bats
# End-to-end discovery mode: no project/group arg — crawls accessible resources.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/gitlab-exporter.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
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
  export GITLAB_AUTH_TYPE=pat
  export GITLAB_TOKEN=testtoken
  export GITLAB_OUTPUT_DIR="$_OUT_DIR"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
  rm -rf "$_OUT_DIR"
}

# --- default (discovery) mode ---

@test "discovery mode: exits 0 with credentials only (no --project or --group)" {
  run "$EXPORT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "discovery mode: creates _scope.md in output directory" {
  "$EXPORT_SCRIPT"
  [ -f "$_OUT_DIR/_scope.md" ]
}

@test "discovery mode: creates _discovery.md in output directory" {
  "$EXPORT_SCRIPT"
  [ -f "$_OUT_DIR/_discovery.md" ]
}

@test "discovery mode: _scope.md is non-empty" {
  "$EXPORT_SCRIPT"
  size=$(wc -c < "$_OUT_DIR/_scope.md" | tr -d ' ')
  [ "$size" -gt 0 ]
}

@test "discovery mode: _scope.md contains authenticated username" {
  "$EXPORT_SCRIPT"
  grep -q "testuser" "$_OUT_DIR/_scope.md"
}

@test "discovery mode: _scope.md contains token name" {
  "$EXPORT_SCRIPT"
  grep -q "exporter-token" "$_OUT_DIR/_scope.md"
}

@test "discovery mode: _discovery.md is non-empty" {
  "$EXPORT_SCRIPT"
  size=$(wc -c < "$_OUT_DIR/_discovery.md" | tr -d ' ')
  [ "$size" -gt 0 ]
}

@test "discovery mode: _discovery.md lists accessible groups" {
  "$EXPORT_SCRIPT"
  grep -q "test-group" "$_OUT_DIR/_discovery.md"
}

@test "discovery mode: _discovery.md lists accessible projects" {
  "$EXPORT_SCRIPT"
  grep -q "my-test-project" "$_OUT_DIR/_discovery.md"
}

@test "discovery mode: _discovery.md contains GitLab instance URL" {
  "$EXPORT_SCRIPT"
  grep -q "127.0.0.1" "$_OUT_DIR/_discovery.md"
}

@test "discovery mode: output dir is created if it does not exist" {
  local new_dir="${_OUT_DIR}/nested/output"
  GITLAB_OUTPUT_DIR="$new_dir" run "$EXPORT_SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$new_dir" ]
}

# --- --check-scope still works standalone ---

@test "--check-scope: exits 0 without --project or --group" {
  run "$EXPORT_SCRIPT" --check-scope
  [ "$status" -eq 0 ]
}

@test "--check-scope: output contains username" {
  run "$EXPORT_SCRIPT" --check-scope
  [[ "$output" =~ "testuser" ]]
}
