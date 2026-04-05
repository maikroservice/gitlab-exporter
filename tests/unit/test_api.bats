#!/usr/bin/env bats
# tests/unit/test_api.bats
# Tests api.sh functions against a live fixture server (real curl, real HTTP).

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
  {"pattern": "/api/v4/projects/12345/wikis",          "fixture": "wiki_pages.json",            "status": 200},
  {"pattern": "/api/v4/projects/12345/issues",          "fixture": "issues_page1.json",          "status": 200},
  {"pattern": "/api/v4/projects/12345/merge_requests",  "fixture": "merge_requests_page1.json",  "status": 200},
  {"pattern": "/api/v4/projects/12345",                 "fixture": "project_single.json",        "status": 200},
  {"pattern": "/api/v4/groups/42/projects",             "fixture": "group_projects.json",        "status": 200},
  {"pattern": "/api/v4/groups/42",                      "fixture": "group_single.json",          "status": 200},
  {"pattern": "/api/v4/projects?",                      "fixture": "projects_list.json",         "status": 200},
  {"pattern": "/api/v4/projects/99999",                 "fixture": "error_404.json",             "status": 404},
  {"pattern": "/api/v4/projects/77777",                 "fixture": "error_401.json",             "status": 401}
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
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
}

# --- api_base_url ---

@test "api_base_url: returns /api/v4 path" {
  export GITLAB_URL=https://gitlab.com
  result=$(api_base_url)
  [ "$result" = "https://gitlab.com/api/v4" ]
}

@test "api_base_url: strips trailing slash from GITLAB_URL" {
  export GITLAB_URL=https://gitlab.example.com/
  result=$(api_base_url)
  [ "$result" = "https://gitlab.example.com/api/v4" ]
}

# --- api_url_to_id ---

@test "api_url_to_id: returns bare numeric ID unchanged" {
  result=$(api_url_to_id "12345")
  [ "$result" = "12345" ]
}

@test "api_url_to_id: URL-encodes namespace/project path" {
  result=$(api_url_to_id "test-group/my-project")
  [ "$result" = "test-group%2Fmy-project" ]
}

@test "api_url_to_id: extracts and encodes path from full GitLab URL" {
  result=$(api_url_to_id "https://gitlab.com/test-group/my-project")
  [ "$result" = "test-group%2Fmy-project" ]
}

@test "api_url_to_id: strips /-/ suffixes from GitLab URLs" {
  result=$(api_url_to_id "https://gitlab.com/test-group/my-project/-/issues")
  [ "$result" = "test-group%2Fmy-project" ]
}

# --- api_group_url_to_id ---

@test "api_group_url_to_id: returns bare numeric ID unchanged" {
  result=$(api_group_url_to_id "42")
  [ "$result" = "42" ]
}

@test "api_group_url_to_id: URL-encodes group path with subgroups" {
  result=$(api_group_url_to_id "parent-group/sub-group")
  [ "$result" = "parent-group%2Fsub-group" ]
}

@test "api_group_url_to_id: extracts path from full GitLab groups URL" {
  result=$(api_group_url_to_id "https://gitlab.com/groups/test-group")
  [ "$result" = "test-group" ]
}

# --- api_get_project ---

@test "api_get_project: returns project JSON for valid ID" {
  result=$(api_get_project "12345")
  [ "${HAS_JQ}" = "1" ] || skip "jq required for this assertion"
  name=$(printf '%s' "$result" | jq -r '.name')
  [ "$name" = "My Test Project" ]
}

@test "api_get_project: fails with exit code 1 for 404" {
  run api_get_project "99999"
  [ "$status" -eq 1 ]
}

@test "api_get_project: fails with exit code 1 for 401" {
  run api_get_project "77777"
  [ "$status" -eq 1 ]
}

# --- api_get_project_wikis ---

@test "api_get_project_wikis: returns wiki pages for valid project" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_project_wikis "12345" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

# --- api_get_project_issues ---

@test "api_get_project_issues: returns issues for valid project" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_project_issues "12345" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -ge 1 ]
}

# --- api_get_project_mrs ---

@test "api_get_project_mrs: returns MRs for valid project" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_project_mrs "12345" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -ge 1 ]
}

# --- api_get_group_projects ---

@test "api_get_group_projects: returns projects for valid group" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_group_projects "42" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -ge 1 ]
}

# --- api_paginate_all: pagination ---

@test "api_paginate_all: fetches multiple pages when first page is full" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"

  # Create a dedicated server with per_page=2 pagination fixture map
  local map2
  map2=$(mktemp)
  cat > "$map2" <<'PAGEMAP'
[
  {"pattern": "per_page=2&page=2", "fixture": "issues_page2.json", "status": 200},
  {"pattern": "per_page=2&page=1", "fixture": "issues_page1.json", "status": 200},
  {"pattern": "per_page=2",        "fixture": "issues_page1.json", "status": 200}
]
PAGEMAP

  local port2
  port2=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$port2" "$map2" >/dev/null 2>&1 &
  local srv2=$!
  local i=0
  until curl -s "http://127.0.0.1:${port2}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  local out
  out=$(mktemp)
  export GITLAB_PER_PAGE=2
  api_paginate_all "http://127.0.0.1:${port2}/api/v4/projects/12345/issues?scope=all&state=all" "$out"
  local count
  count=$(wc -l < "$out" | tr -d ' ')

  kill "$srv2" 2>/dev/null || true
  wait "$srv2" 2>/dev/null || true
  rm -f "$out" "$map2"
  export GITLAB_PER_PAGE=100

  [ "$count" -eq 3 ]
}

@test "api_paginate_all: stops after empty page" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"

  local map3
  map3=$(mktemp)
  cat > "$map3" <<'EMPTYMAP'
[
  {"pattern": "/api/v4/projects/12345/issues", "fixture": "issues_empty.json", "status": 200}
]
EMPTYMAP

  local port3
  port3=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$port3" "$map3" >/dev/null 2>&1 &
  local srv3=$!
  local i=0
  until curl -s "http://127.0.0.1:${port3}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  local out
  out=$(mktemp)
  api_paginate_all "http://127.0.0.1:${port3}/api/v4/projects/12345/issues?scope=all&state=all" "$out"
  local count
  count=$(wc -c < "$out" | tr -d ' ')

  kill "$srv3" 2>/dev/null || true
  wait "$srv3" 2>/dev/null || true
  rm -f "$out" "$map3"

  [ "$count" -eq 0 ]
}

# --- JSON extractors ---

@test "api_extract_id: returns id from project JSON" {
  json=$(cat "$FIXTURES_DIR/project_single.json")
  result=$(api_extract_id "$json")
  [ "$result" = "12345" ]
}

@test "api_extract_namespace: returns path_with_namespace from project JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/project_single.json")
  result=$(api_extract_namespace "$json")
  [ "$result" = "test-group/my-test-project" ]
}

@test "api_extract_iid: returns iid from issue JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(head -1 <(jq -c '.[]' "$FIXTURES_DIR/issues_page1.json"))
  result=$(api_extract_iid "$json")
  [ "$result" = "1" ]
}

@test "api_extract_title: returns title from issue JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(api_extract_title "$json")
  [ "$result" = "Fix login bug" ]
}

@test "api_extract_wiki_slug: returns slug from wiki page JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/wiki_pages.json")
  result=$(api_extract_wiki_slug "$json")
  [ "$result" = "home" ]
}
