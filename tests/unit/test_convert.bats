#!/usr/bin/env bats
# tests/unit/test_convert.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/convert.sh"
  deps_check
}

# --- convert_issue_to_markdown ---

@test "convert_issue_to_markdown: includes issue number in heading" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "Issue #1" ]]
}

@test "convert_issue_to_markdown: includes issue title in heading" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "Fix login bug" ]]
}

@test "convert_issue_to_markdown: includes state" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "opened" ]]
}

@test "convert_issue_to_markdown: includes author username" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "alice" ]]
}

@test "convert_issue_to_markdown: includes labels" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "bug" ]]
}

@test "convert_issue_to_markdown: includes description body" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "special characters" ]]
}

@test "convert_issue_to_markdown: includes web URL" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "issues/1" ]]
}

@test "convert_issue_to_markdown: includes milestone title when set" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/issues_page1.json")
  result=$(convert_issue_to_markdown "$json")
  [[ "$result" =~ "v1.0" ]]
}

# --- convert_mr_to_markdown ---

@test "convert_mr_to_markdown: includes MR number in heading" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/merge_requests_page1.json")
  result=$(convert_mr_to_markdown "$json")
  [[ "$result" =~ "!1" ]]
}

@test "convert_mr_to_markdown: includes MR title in heading" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/merge_requests_page1.json")
  result=$(convert_mr_to_markdown "$json")
  [[ "$result" =~ "Add feature X" ]]
}

@test "convert_mr_to_markdown: includes source branch" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/merge_requests_page1.json")
  result=$(convert_mr_to_markdown "$json")
  [[ "$result" =~ "feature-x" ]]
}

@test "convert_mr_to_markdown: includes target branch" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/merge_requests_page1.json")
  result=$(convert_mr_to_markdown "$json")
  [[ "$result" =~ "main" ]]
}

@test "convert_mr_to_markdown: includes state" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/merge_requests_page1.json")
  result=$(convert_mr_to_markdown "$json")
  [[ "$result" =~ "merged" ]]
}

@test "convert_mr_to_markdown: includes description body" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/merge_requests_page1.json")
  result=$(convert_mr_to_markdown "$json")
  [[ "$result" =~ "feature X" ]]
}

# --- convert_wiki_page ---

@test "convert_wiki_page: returns wiki content unchanged" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/wiki_pages.json")
  result=$(convert_wiki_page "$json")
  [[ "$result" =~ "Welcome to the wiki" ]]
}

@test "convert_wiki_page: preserves Markdown headings" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(jq -c '.[0]' "$FIXTURES_DIR/wiki_pages.json")
  result=$(convert_wiki_page "$json")
  [[ "$result" =~ "# Home" ]]
}
