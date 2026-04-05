#!/usr/bin/env bats
# tests/unit/test_output.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/output.sh"
  _TMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$_TMP_DIR"
}

# --- output_slugify ---

@test "output_slugify: lowercases input" {
  result=$(output_slugify "UPPER CASE")
  [[ "$result" =~ ^[a-z-]+$ ]]
}

@test "output_slugify: converts spaces to hyphens" {
  result=$(output_slugify "hello world")
  [ "$result" = "hello-world" ]
}

@test "output_slugify: strips non-alphanumeric characters except hyphens" {
  result=$(output_slugify "hello! world@2024")
  [ "$result" = "hello-world-2024" ]
}

@test "output_slugify: collapses consecutive hyphens" {
  result=$(output_slugify "hello---world")
  [ "$result" = "hello-world" ]
}

@test "output_slugify: trims leading hyphens" {
  result=$(output_slugify "---hello")
  [ "$result" = "hello" ]
}

@test "output_slugify: trims trailing hyphens" {
  result=$(output_slugify "hello---")
  [ "$result" = "hello" ]
}

@test "output_slugify: handles special characters in issue titles" {
  result=$(output_slugify "Fix: Login Bug (v2.0)")
  [ "$result" = "fix-login-bug-v2-0" ]
}

# --- output_build_path ---

@test "output_build_path: builds wiki page path" {
  result=$(output_build_path "./export" "test-group/my-project" "wiki" "home")
  [ "$result" = "./export/test-group/my-project/wiki/home.md" ]
}

@test "output_build_path: builds issue path" {
  result=$(output_build_path "./export" "test-group/my-project" "issues" "1-fix-login-bug")
  [ "$result" = "./export/test-group/my-project/issues/1-fix-login-bug.md" ]
}

@test "output_build_path: builds merge-request path" {
  result=$(output_build_path "./export" "test-group/my-project" "merge-requests" "1-add-feature-x")
  [ "$result" = "./export/test-group/my-project/merge-requests/1-add-feature-x.md" ]
}

@test "output_build_path: handles nested namespace (group/subgroup/project)" {
  result=$(output_build_path "./export" "parent/child/project" "wiki" "home")
  [ "$result" = "./export/parent/child/project/wiki/home.md" ]
}

# --- output_write_file ---

@test "output_write_file: creates file at given path" {
  output_write_file "$_TMP_DIR/test.md" "hello content"
  [ -f "$_TMP_DIR/test.md" ]
}

@test "output_write_file: writes correct content" {
  output_write_file "$_TMP_DIR/test.md" "hello content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "hello content" ]
}

@test "output_write_file: creates intermediate directories" {
  output_write_file "$_TMP_DIR/deep/nested/dir/test.md" "content"
  [ -f "$_TMP_DIR/deep/nested/dir/test.md" ]
}

@test "output_write_file: does not overwrite existing file by default" {
  printf 'original' > "$_TMP_DIR/test.md"
  output_write_file "$_TMP_DIR/test.md" "new content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "original" ]
}

@test "output_write_file: overwrites existing file when GITLAB_FORCE=1" {
  printf 'original' > "$_TMP_DIR/test.md"
  GITLAB_FORCE=1 output_write_file "$_TMP_DIR/test.md" "new content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "new content" ]
}

# --- output_collision_path ---

@test "output_collision_path: appends item ID when slug conflicts" {
  mkdir -p "$_TMP_DIR/test-group/my-project/issues"
  touch "$_TMP_DIR/test-group/my-project/issues/fix-login-bug.md"

  result=$(output_collision_path "$_TMP_DIR/test-group/my-project/issues/fix-login-bug.md" "1001")
  [ "$result" = "$_TMP_DIR/test-group/my-project/issues/fix-login-bug--1001.md" ]
}

@test "output_collision_path: returns original path when no collision" {
  result=$(output_collision_path "$_TMP_DIR/test-group/my-project/issues/new-issue.md" "1001")
  [ "$result" = "$_TMP_DIR/test-group/my-project/issues/new-issue.md" ]
}
