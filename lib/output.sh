#!/usr/bin/env bash
# lib/output.sh - File writing, path building, and slug generation

# Convert a title to a filesystem-safe slug
# Usage: output_slugify <title>
output_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//'
}

# Build the full output path for an item
# Usage: output_build_path <output_dir> <project_namespace> <content_type> <item_slug>
# content_type: wiki | issues | merge-requests
# Returns: <output_dir>/<project_namespace>/<content_type>/<item_slug>.md
output_build_path() {
  local out_dir="$1"
  local project_namespace="$2"
  local content_type="$3"
  local item_slug="$4"

  printf '%s/%s/%s/%s.md' "$out_dir" "$project_namespace" "$content_type" "$item_slug"
}

# Return a collision-free path: if the path exists, append --<item_id> before .md
# Usage: output_collision_path <path> <item_id>
output_collision_path() {
  local path="$1"
  local item_id="$2"

  if [ ! -e "$path" ]; then
    printf '%s' "$path"
    return 0
  fi

  local dir base
  dir=$(dirname "$path")
  base=$(basename "$path" .md)

  printf '%s/%s--%s.md' "$dir" "$base" "$item_id"
}

# Write content to a file, creating intermediate directories as needed.
# Respects GITLAB_FORCE=1 to allow overwriting.
# Usage: output_write_file <path> <content>
output_write_file() {
  local path="$1"
  local content="$2"

  if [ -e "$path" ] && [ "${GITLAB_FORCE:-0}" != "1" ]; then
    log_warn "Skipping existing file (use --force to overwrite): $path"
    return 0
  fi

  local dir
  dir=$(dirname "$path")
  mkdir -p "$dir" || { log_error "Could not create directory: $dir"; return 1; }

  local tmp
  tmp=$(mktemp "${dir}/.tmp_XXXXXX")
  printf '%s' "$content" > "$tmp" && mv "$tmp" "$path" || {
    rm -f "$tmp"
    log_error "Could not write file: $path"
    return 1
  }

  log_debug "Wrote: $path"
}
