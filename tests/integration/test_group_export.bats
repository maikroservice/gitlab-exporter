#!/usr/bin/env bats
# tests/integration/test_group_export.bats
# End-to-end group export flows using a real fixture server.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/gitlab-exporter.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/api/v4/projects/12345/wikis",          "fixture": "wiki_pages.json",           "status": 200},
  {"pattern": "/api/v4/projects/12345/issues",          "fixture": "issues_page1.json",         "status": 200},
  {"pattern": "/api/v4/projects/12345/merge_requests",  "fixture": "merge_requests_page1.json", "status": 200},
  {"pattern": "/api/v4/projects/12345",                 "fixture": "project_single.json",       "status": 200},
  {"pattern": "/api/v4/groups/42/projects",             "fixture": "group_projects.json",       "status": 200},
  {"pattern": "/api/v4/groups/test-group/projects",     "fixture": "group_projects.json",       "status": 200},
  {"pattern": "/api/v4/groups/42",                      "fixture": "group_single.json",         "status": 200},
  {"pattern": "/api/v4/groups/test-group",              "fixture": "group_single.json",         "status": 200},
  {"pattern": "/api/v4/projects?",                      "fixture": "projects_list.json",        "status": 200}
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

# --- group export ---

@test "group export: exits 0 for valid group ID" {
  run "$EXPORT_SCRIPT" --group 42 --wiki
  [ "$status" -eq 0 ]
}

@test "group export: creates wiki files for each project in the group" {
  "$EXPORT_SCRIPT" --group 42 --wiki
  count=$(find "$_OUT_DIR" -path "*/wiki/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "group export: exports wiki under project namespace directory" {
  "$EXPORT_SCRIPT" --group 42 --wiki
  [ -d "$_OUT_DIR/test-group/my-test-project/wiki" ]
}

@test "group export: exports issues for all group projects" {
  "$EXPORT_SCRIPT" --group 42 --issues
  count=$(find "$_OUT_DIR" -path "*/issues/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "group export: exports MRs for all group projects" {
  "$EXPORT_SCRIPT" --group 42 --merge-requests
  count=$(find "$_OUT_DIR" -path "*/merge-requests/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "group --list: prints project names without creating files" {
  run "$EXPORT_SCRIPT" --group 42 --wiki --list
  [ "$status" -eq 0 ]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

@test "group export: accepts group path instead of numeric ID" {
  run "$EXPORT_SCRIPT" --group "test-group" --wiki
  [ "$status" -eq 0 ]
}
