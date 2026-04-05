#!/usr/bin/env bats
# tests/integration/test_project_export.bats
# End-to-end project export flows using a real fixture server.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/gitlab-exporter.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"pattern": "/api/v4/projects/12345/repository/commits",          "fixture": "commits_page1.json",        "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/branches",         "fixture": "branches_list.json",        "status": 200},
  {"pattern": "/api/v4/projects/12345/repository/archive.tar.gz",   "fixture": "source_archive.bin",        "status": 200},
  {"pattern": "/api/v4/projects/12345/wikis",                       "fixture": "wiki_pages.json",           "status": 200},
  {"pattern": "/api/v4/projects/12345/issues",                      "fixture": "issues_page1.json",         "status": 200},
  {"pattern": "/api/v4/projects/12345/merge_requests",              "fixture": "merge_requests_page1.json", "status": 200},
  {"pattern": "/api/v4/projects/test-group%2Fmy-test-project/wiki", "fixture": "wiki_pages.json",           "status": 200},
  {"pattern": "/api/v4/projects/test-group%2Fmy-test-project",      "fixture": "project_single.json",       "status": 200},
  {"pattern": "/api/v4/projects/12345",                             "fixture": "project_single.json",       "status": 200},
  {"pattern": "/api/v4/projects?",                                  "fixture": "projects_list.json",        "status": 200},
  {"pattern": "/api/v4/projects/99999",                             "fixture": "error_404.json",            "status": 404},
  {"pattern": "/api/v4/projects/77777",                             "fixture": "error_401.json",            "status": 401}
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

# --- wiki export ---

@test "wiki export: exits 0 for valid project ID" {
  run "$EXPORT_SCRIPT" --project 12345 --wiki
  [ "$status" -eq 0 ]
}

@test "wiki export: creates .md files in the wiki subdirectory" {
  "$EXPORT_SCRIPT" --project 12345 --wiki
  count=$(find "$_OUT_DIR" -path "*/wiki/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "wiki export: creates file for each wiki page" {
  "$EXPORT_SCRIPT" --project 12345 --wiki
  count=$(find "$_OUT_DIR" -path "*/wiki/*.md" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "wiki export: home page file contains expected content" {
  "$EXPORT_SCRIPT" --project 12345 --wiki
  file=$(find "$_OUT_DIR" -path "*/wiki/home.md")
  [ -f "$file" ]
  grep -q "Welcome to the wiki" "$file"
}

@test "wiki export: output files are under project namespace directory" {
  "$EXPORT_SCRIPT" --project 12345 --wiki
  [ -d "$_OUT_DIR/test-group/my-test-project/wiki" ]
}

# --- issues export ---

@test "issues export: exits 0 for valid project ID" {
  run "$EXPORT_SCRIPT" --project 12345 --issues
  [ "$status" -eq 0 ]
}

@test "issues export: creates .md files in the issues subdirectory" {
  "$EXPORT_SCRIPT" --project 12345 --issues
  count=$(find "$_OUT_DIR" -path "*/issues/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "issues export: issue file name includes iid and title slug" {
  "$EXPORT_SCRIPT" --project 12345 --issues
  file=$(find "$_OUT_DIR" -path "*/issues/1-*.md" | head -1)
  [ -f "$file" ]
}

@test "issues export: issue file contains title heading" {
  "$EXPORT_SCRIPT" --project 12345 --issues
  file=$(find "$_OUT_DIR" -path "*/issues/1-*.md" | head -1)
  grep -q "Fix login bug" "$file"
}

@test "issues export: issue file contains state" {
  "$EXPORT_SCRIPT" --project 12345 --issues
  file=$(find "$_OUT_DIR" -path "*/issues/1-*.md" | head -1)
  grep -q "opened" "$file"
}

@test "issues export: issue file contains description" {
  "$EXPORT_SCRIPT" --project 12345 --issues
  file=$(find "$_OUT_DIR" -path "*/issues/1-*.md" | head -1)
  grep -q "special characters" "$file"
}

# --- merge requests export ---

@test "merge-requests export: exits 0 for valid project ID" {
  run "$EXPORT_SCRIPT" --project 12345 --merge-requests
  [ "$status" -eq 0 ]
}

@test "merge-requests export: creates .md files in the merge-requests subdirectory" {
  "$EXPORT_SCRIPT" --project 12345 --merge-requests
  count=$(find "$_OUT_DIR" -path "*/merge-requests/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "merge-requests export: MR file contains title" {
  "$EXPORT_SCRIPT" --project 12345 --merge-requests
  file=$(find "$_OUT_DIR" -path "*/merge-requests/1-*.md" | head -1)
  [ -f "$file" ]
  grep -q "Add feature X" "$file"
}

@test "merge-requests export: MR file contains branch info" {
  "$EXPORT_SCRIPT" --project 12345 --merge-requests
  file=$(find "$_OUT_DIR" -path "*/merge-requests/1-*.md" | head -1)
  grep -q "feature-x" "$file"
}

# --- all content (default: no content flag) ---

@test "default export: exports wiki, issues, MRs, source, and commits when no content flag given" {
  "$EXPORT_SCRIPT" --project 12345
  wiki_count=$(find "$_OUT_DIR" -path "*/wiki/*.md" | wc -l | tr -d ' ')
  issue_count=$(find "$_OUT_DIR" -path "*/issues/*.md" | wc -l | tr -d ' ')
  mr_count=$(find "$_OUT_DIR" -path "*/merge-requests/*.md" | wc -l | tr -d ' ')
  source_count=$(find "$_OUT_DIR" -path "*/source/*" -type d | wc -l | tr -d ' ')
  commits_count=$(find "$_OUT_DIR" -path "*/commits/*.md" | wc -l | tr -d ' ')
  [ "$wiki_count" -ge 1 ]
  [ "$issue_count" -ge 1 ]
  [ "$mr_count" -ge 1 ]
  [ "$source_count" -ge 1 ]
  [ "$commits_count" -ge 1 ]
}

# --- commits export ---

@test "commits export: exits 0 for valid project" {
  run "$EXPORT_SCRIPT" --project 12345 --commits
  [ "$status" -eq 0 ]
}

@test "commits export: creates a .md file under commits directory" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  count=$(find "$_OUT_DIR" -path "*/commits/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "commits export: file is named after the branch" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  [ -f "$_OUT_DIR/test-group/my-test-project/commits/main.md" ]
}

@test "commits export: file contains commit short SHA" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  grep -q "dccfa6b3" "$_OUT_DIR/test-group/my-test-project/commits/main.md"
}

@test "commits export: file contains author name" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  grep -q "Jane Doe" "$_OUT_DIR/test-group/my-test-project/commits/main.md"
}

@test "commits export: file contains commit message" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  grep -q "Add new feature" "$_OUT_DIR/test-group/my-test-project/commits/main.md"
}

@test "commits export: file contains header with branch name and count" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  grep -q "Commits: main" "$_OUT_DIR/test-group/my-test-project/commits/main.md"
}

@test "commits export: file is formatted as a Markdown table" {
  "$EXPORT_SCRIPT" --project 12345 --commits
  grep -q "| SHA | Timestamp | Message | Author |" "$_OUT_DIR/test-group/my-test-project/commits/main.md"
  grep -q "| \`dccfa6b3\`" "$_OUT_DIR/test-group/my-test-project/commits/main.md"
}

@test "commits --list: prints branch names without creating files" {
  run "$EXPORT_SCRIPT" --project 12345 --commits --list
  [ "$status" -eq 0 ]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- --list dry run ---

@test "--list flag prints project content without creating files" {
  run "$EXPORT_SCRIPT" --project 12345 --wiki --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "home" ]] || [[ "$output" =~ "Home" ]]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- --force flag ---

@test "--force flag overwrites existing files" {
  "$EXPORT_SCRIPT" --project 12345 --wiki
  file=$(find "$_OUT_DIR" -path "*/wiki/home.md")
  printf 'old content' > "$file"
  "$EXPORT_SCRIPT" --project 12345 --wiki --force
  grep -q "Welcome to the wiki" "$file"
}

# --- --output flag ---

@test "--output flag overrides GITLAB_OUTPUT_DIR" {
  local custom_dir
  custom_dir=$(mktemp -d)
  run "$EXPORT_SCRIPT" --project 12345 --wiki --output "$custom_dir"
  count=$(find "$custom_dir" -name "*.md" | wc -l | tr -d ' ')
  rm -rf "$custom_dir"
  [ "$count" -ge 1 ]
}

# --- error handling ---

@test "exits non-zero for 404 project" {
  run "$EXPORT_SCRIPT" --project 99999 --wiki
  [ "$status" -ne 0 ]
}

@test "exits non-zero for 401 auth failure" {
  run "$EXPORT_SCRIPT" --project 77777 --wiki
  [ "$status" -ne 0 ]
}

# --- URL input ---

@test "accepts full GitLab project URL instead of bare ID" {
  run "$EXPORT_SCRIPT" \
    --project "http://127.0.0.1:${_PORT}/test-group/my-test-project" \
    --wiki
  [ "$status" -eq 0 ]
}

# --- partial failure: one content type unavailable ---

@test "issues are exported even when wiki returns 404 (wiki disabled)" {
  # Start a second server where wiki endpoint returns 404 but issues succeed
  local map2; map2=$(mktemp)
  cat > "$map2" <<'ROUTEMAP'
[
  {"pattern": "/api/v4/projects/12345/wikis",       "fixture": "error_404.json",            "status": 404},
  {"pattern": "/api/v4/projects/12345/issues",      "fixture": "issues_page1.json",         "status": 200},
  {"pattern": "/api/v4/projects/12345/merge_requests", "fixture": "merge_requests_page1.json", "status": 200},
  {"pattern": "/api/v4/projects/12345",             "fixture": "project_single.json",       "status": 200},
  {"pattern": "/api/v4/projects?",                  "fixture": "projects_list.json",        "status": 200}
]
ROUTEMAP

  local port2
  port2=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  FIXTURES_DIR="$FIXTURES_DIR" python3 "$HELPERS_DIR/fixture_server.py" "$port2" "$map2" >/dev/null 2>&1 &
  local pid2=$!

  local i=0
  until curl -s "http://127.0.0.1:${port2}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  GITLAB_URL="http://127.0.0.1:${port2}" run "$EXPORT_SCRIPT" --project 12345
  kill "$pid2" 2>/dev/null || true; wait "$pid2" 2>/dev/null || true
  rm -f "$map2"

  # Must exit 0 and must have written issue files
  [ "$status" -eq 0 ]
  count=$(find "$_OUT_DIR" -path "*/issues/*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "export output path is logged so user knows where files went" {
  run "$EXPORT_SCRIPT" --project 12345 --issues
  [[ "$output" =~ "$_OUT_DIR" ]]
}
