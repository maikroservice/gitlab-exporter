#!/usr/bin/env bash
# lib/discovery.sh - Report generation for discovery mode.
# Depends on: lib/log.sh, lib/auth.sh (auth_scope_present), lib/api.sh

# ---------------------------------------------------------------------------
# Scope report
# ---------------------------------------------------------------------------

# Write a Markdown credential scope report to stdout.
# Usage: discovery_write_scope_report <user_json> <pat_json_or_empty>
#
# Outputs structured Markdown. Redirect to a file:
#   discovery_write_scope_report "$user_json" "$pat_json" > _scope.md
discovery_write_scope_report() {
  local user_json="$1"
  local pat_json="$2"

  # --- parse user fields ---
  local username name email
  if [ "${HAS_JQ:-0}" = "1" ]; then
    username=$(printf '%s' "$user_json" | jq -r '.username  // "unknown"')
    name=$(    printf '%s' "$user_json" | jq -r '.name      // "unknown"')
    email=$(   printf '%s' "$user_json" | jq -r '.email     // ""')
  else
    username=$(printf '%s' "$user_json" | grep -o '"username":"[^"]*"' | head -1 | sed 's/"username":"//;s/"$//')
    name=$(    printf '%s' "$user_json" | grep -o '"name":"[^"]*"'     | head -1 | sed 's/"name":"//;s/"$//')
    email=$(   printf '%s' "$user_json" | grep -o '"email":"[^"]*"'    | head -1 | sed 's/"email":"//;s/"$//')
  fi

  local instance="${GITLAB_URL:-https://gitlab.com}"
  local generated
  generated=$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date '+%Y-%m-%d')

  printf '# GitLab Credential Scope Report\n\n'
  printf '**Instance:** %s  \n' "$instance"
  printf '**Generated:** %s\n\n' "$generated"

  printf '## Authenticated User\n\n'
  printf '| Field | Value |\n'
  printf '|-------|-------|\n'
  printf '| Username | @%s |\n' "$username"
  printf '| Name | %s |\n' "$name"
  [ -n "$email" ] && printf '| Email | %s |\n' "$email"
  printf '\n'

  # --- PAT section (only when pat_json provided) ---
  if [ -n "$pat_json" ]; then
    local token_name expires active scopes_json
    if [ "${HAS_JQ:-0}" = "1" ]; then
      token_name=$(printf '%s' "$pat_json" | jq -r '.name        // "unknown"')
      expires=$(   printf '%s' "$pat_json" | jq -r '.expires_at  // "never"')
      active=$(    printf '%s' "$pat_json" | jq -r '.active      // false')
      scopes_json=$(printf '%s' "$pat_json" | jq -c '.scopes     // []')
      # Comma-separated for display
      scopes_display=$(printf '%s' "$pat_json" | jq -r '(.scopes // []) | join(", ")')
    else
      token_name=$(printf '%s' "$pat_json" | grep -o '"name":"[^"]*"'       | head -1 | sed 's/"name":"//;s/"$//')
      expires=$(   printf '%s' "$pat_json" | grep -o '"expires_at":"[^"]*"' | head -1 | sed 's/"expires_at":"//;s/"$//')
      active=$(    printf '%s' "$pat_json" | grep -o '"active":[a-z]*'       | head -1 | sed 's/"active"://')
      scopes_json=$(printf '%s' "$pat_json" | grep -o '"scopes":\[[^]]*\]'   | head -1 | sed 's/"scopes"://')
      scopes_json="${scopes_json:-[]}"
      scopes_display=$(printf '%s' "$scopes_json" | tr -d '[]"' | tr ',' ', ')
    fi

    printf '## Token\n\n'
    printf '| Field | Value |\n'
    printf '|-------|-------|\n'
    printf '| Name | %s |\n' "$token_name"
    printf '| Active | %s |\n' "$active"
    printf '| Expires | %s |\n' "$expires"
    printf '| Scopes | `%s` |\n' "$scopes_display"
    printf '\n'

    # --- capabilities derived from scopes ---
    local has_api=0 has_read_api=0 has_read_repo=0
    auth_scope_present "$scopes_json" "api"              && has_api=1      || true
    auth_scope_present "$scopes_json" "read_api"         && has_read_api=1 || true
    auth_scope_present "$scopes_json" "read_repository"  && has_read_repo=1 || true

    local api_ok repo_ok
    [ "$has_api" = "1" ] || [ "$has_read_api" = "1" ] && api_ok=yes  || api_ok=no
    [ "$has_api" = "1" ] || [ "$has_read_repo" = "1" ] && repo_ok=yes || repo_ok=no

    printf '## Export Capabilities\n\n'
    printf '| Content Type | Available | Required Scope |\n'
    printf '|--------------|-----------|----------------|\n'
    printf '| Wiki pages | %s | `api` or `read_api` |\n'         "$api_ok"
    printf '| Issues | %s | `api` or `read_api` |\n'             "$api_ok"
    printf '| Merge requests | %s | `api` or `read_api` |\n'     "$api_ok"
    printf '| Source code | %s | `api` or `read_repository` |\n' "$repo_ok"
    printf '\n'
  fi
}

# ---------------------------------------------------------------------------
# Discovery index
# ---------------------------------------------------------------------------

# Write a Markdown discovery index to stdout.
# Usage: discovery_write_index <user_json> <groups_file> <projects_file>
#
# groups_file and projects_file each contain one compact JSON object per line
# (output of api_get_accessible_groups / api_get_accessible_projects).
discovery_write_index() {
  local user_json="$1"
  local groups_file="$2"
  local projects_file="$3"

  local username name
  if [ "${HAS_JQ:-0}" = "1" ]; then
    username=$(printf '%s' "$user_json" | jq -r '.username // "unknown"')
    name=$(    printf '%s' "$user_json" | jq -r '.name     // "unknown"')
  else
    username=$(printf '%s' "$user_json" | grep -o '"username":"[^"]*"' | head -1 | sed 's/"username":"//;s/"$//')
    name=$(    printf '%s' "$user_json" | grep -o '"name":"[^"]*"'     | head -1 | sed 's/"name":"//;s/"$//')
  fi

  local group_count project_count
  group_count=$(grep -c '.' "$groups_file"   2>/dev/null || printf '0')
  project_count=$(grep -c '.' "$projects_file" 2>/dev/null || printf '0')

  local instance="${GITLAB_URL:-https://gitlab.com}"
  local generated
  generated=$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date '+%Y-%m-%d')

  printf '# GitLab Access Discovery\n\n'
  printf '**Instance:** %s  \n' "$instance"
  printf '**User:** %s (@%s)  \n' "$name" "$username"
  printf '**Generated:** %s\n\n' "$generated"

  # --- groups table ---
  printf '## Accessible Groups (%s)\n\n' "$group_count"
  if [ "$group_count" -gt 0 ] 2>/dev/null; then
    printf '| ID | Path | Visibility | Description |\n'
    printf '|----|------|------------|-------------|\n'
    while IFS= read -r grp; do
      [ -z "$grp" ] && continue
      local gid gpath gvis gdesc
      if [ "${HAS_JQ:-0}" = "1" ]; then
        gid=$(   printf '%s' "$grp" | jq -r '.id          // ""')
        gpath=$( printf '%s' "$grp" | jq -r '.full_path   // .path // ""')
        gvis=$(  printf '%s' "$grp" | jq -r '.visibility  // ""')
        gdesc=$( printf '%s' "$grp" | jq -r '.description // ""')
      else
        gid=$(   printf '%s' "$grp" | grep -o '"id":[0-9]*'           | head -1 | sed 's/"id"://')
        gpath=$( printf '%s' "$grp" | grep -o '"full_path":"[^"]*"'   | head -1 | sed 's/"full_path":"//;s/"$//')
        gvis=$(  printf '%s' "$grp" | grep -o '"visibility":"[^"]*"'  | head -1 | sed 's/"visibility":"//;s/"$//')
        gdesc=$( printf '%s' "$grp" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//;s/"$//')
      fi
      printf '| %s | %s | %s | %s |\n' "$gid" "$gpath" "$gvis" "$gdesc"
    done < "$groups_file"
    printf '\n'
  else
    printf '_No accessible groups found._\n\n'
  fi

  # --- projects table ---
  printf '## Accessible Projects (%s)\n\n' "$project_count"
  if [ "$project_count" -gt 0 ] 2>/dev/null; then
    printf '| ID | Namespace / Path | Visibility | Default Branch |\n'
    printf '|----|------------------|------------|----------------|\n'
    while IFS= read -r proj; do
      [ -z "$proj" ] && continue
      local pid pns pvis pbranch
      if [ "${HAS_JQ:-0}" = "1" ]; then
        pid=$(     printf '%s' "$proj" | jq -r '.id                  // ""')
        pns=$(     printf '%s' "$proj" | jq -r '.path_with_namespace // ""')
        pvis=$(    printf '%s' "$proj" | jq -r '.visibility          // ""')
        pbranch=$( printf '%s' "$proj" | jq -r '.default_branch      // ""')
      else
        pid=$(     printf '%s' "$proj" | grep -o '"id":[0-9]*'                   | head -1 | sed 's/"id"://')
        pns=$(     printf '%s' "$proj" | grep -o '"path_with_namespace":"[^"]*"' | head -1 | sed 's/"path_with_namespace":"//;s/"$//')
        pvis=$(    printf '%s' "$proj" | grep -o '"visibility":"[^"]*"'          | head -1 | sed 's/"visibility":"//;s/"$//')
        pbranch=$( printf '%s' "$proj" | grep -o '"default_branch":"[^"]*"'      | head -1 | sed 's/"default_branch":"//;s/"$//')
      fi
      printf '| %s | %s | %s | %s |\n' "$pid" "$pns" "$pvis" "$pbranch"
    done < "$projects_file"
    printf '\n'
  else
    printf '_No accessible projects found._\n\n'
  fi
}
