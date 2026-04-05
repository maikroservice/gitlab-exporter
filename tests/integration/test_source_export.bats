#!/usr/bin/env bats
# tests/integration/test_source_export.bats
# End-to-end source code download flows using a real fixture server.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/gitlab-exporter.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/api/v4/projects/12345/repository/commits",          "fixture": "commits_latest.json", "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/branches/staging", "fixture": "branch_staging.json", "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/branches/main",    "fixture": "branch_main.json",    "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/branches",         "fixture": "branches_list.json",  "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/archive.tar.gz",   "fixture": "source_archive.bin",  "status": 200},
  {"pattern": "/api/v4/projects/12345/wikis",                       "fixture": "wiki_pages.json",     "status": 200},
  {"pattern": "/api/v4/projects/12345/issues",                      "fixture": "issues_page1.json",   "status": 200},
  {"pattern": "/api/v4/projects/12345/merge_requests",              "fixture": "merge_requests_page1.json", "status": 200},
  {"pattern": "/api/v4/projects/12345",                             "fixture": "project_single.json", "status": 200},
  {"pattern": "/api/v4/projects?",                                  "fixture": "projects_list.json",  "status": 200}
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

# --- --source (default branch) ---

@test "source export: exits 0 for valid project" {
  run "$EXPORT_SCRIPT" --project 12345 --source
  [ "$status" -eq 0 ]
}

@test "source export: creates source directory under project namespace" {
  "$EXPORT_SCRIPT" --project 12345 --source
  [ -d "$_OUT_DIR/test-group/my-test-project/source" ]
}

@test "source export: creates a directory named after the default branch" {
  "$EXPORT_SCRIPT" --project 12345 --source
  [ -d "$_OUT_DIR/test-group/my-test-project/source/main" ]
}

@test "source export: extracted directory contains files" {
  "$EXPORT_SCRIPT" --project 12345 --source
  count=$(find "$_OUT_DIR/test-group/my-test-project/source/main" -type f | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "source export: extracted files include README" {
  "$EXPORT_SCRIPT" --project 12345 --source
  [ -f "$_OUT_DIR/test-group/my-test-project/source/main/README.md" ]
}

@test "source export: no tar.gz left behind after extraction" {
  "$EXPORT_SCRIPT" --project 12345 --source
  count=$(find "$_OUT_DIR" -name "*.tar.gz" | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- --branches <list> ---

@test "branches export: exits 0 when named branches are specified" {
  run "$EXPORT_SCRIPT" --project 12345 --branches main,staging
  [ "$status" -eq 0 ]
}

@test "branches export: creates a directory for each named branch" {
  "$EXPORT_SCRIPT" --project 12345 --branches main,staging
  [ -d "$_OUT_DIR/test-group/my-test-project/source/main" ]
  [ -d "$_OUT_DIR/test-group/my-test-project/source/staging" ]
}

@test "branches export: creates two branch directories for two named branches" {
  "$EXPORT_SCRIPT" --project 12345 --branches main,staging
  count=$(find "$_OUT_DIR" -path "*/source/*" -type d | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

# --- --all-branches ---

@test "all-branches export: exits 0 for valid project" {
  run "$EXPORT_SCRIPT" --project 12345 --all-branches
  [ "$status" -eq 0 ]
}

@test "all-branches export: creates a directory for every branch returned by API" {
  "$EXPORT_SCRIPT" --project 12345 --all-branches
  count=$(find "$_OUT_DIR" -path "*/source/*" -type d | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "all-branches export: directories are named after branches" {
  "$EXPORT_SCRIPT" --project 12345 --all-branches
  [ -d "$_OUT_DIR/test-group/my-test-project/source/main" ]
  [ -d "$_OUT_DIR/test-group/my-test-project/source/staging" ]
}

# --- --list dry run ---

@test "source --list: prints branch names without creating files" {
  run "$EXPORT_SCRIPT" --project 12345 --source --list
  [ "$status" -eq 0 ]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- combined with other content types ---

@test "source + wiki: exports both extracted source and wiki files" {
  "$EXPORT_SCRIPT" --project 12345 --source --wiki
  source_count=$(find "$_OUT_DIR" -path "*/source/*" -type d | wc -l | tr -d ' ')
  wiki_count=$(find "$_OUT_DIR" -path "*/wiki/*.md" | wc -l | tr -d ' ')
  [ "$source_count" -ge 1 ]
  [ "$wiki_count" -ge 1 ]
}
