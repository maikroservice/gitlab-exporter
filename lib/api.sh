#!/usr/bin/env bash
# lib/api.sh - GitLab REST API calls, pagination, and retry logic

# Build the base API URL
api_base_url() {
  printf '%s/api/v4' "${GITLAB_URL%/}"
}

# Core curl wrapper with retry logic
# Usage: api_curl <url> [extra_curl_args...]
# Writes response body to stdout; exports API_LAST_HTTP_CODE
api_curl() {
  local url="$1"; shift
  local auth_header
  auth_header=$(auth_build_header)

  local attempt=1
  local max_retries="${GITLAB_MAX_RETRIES:-3}"
  local retry_delay="${GITLAB_RETRY_DELAY:-5}"
  local tmp_body
  tmp_body=$(mktemp)

  while [ "$attempt" -le "$max_retries" ]; do
    log_debug "curl attempt ${attempt}/${max_retries}: $url"
    API_LAST_HTTP_CODE=$(curl -s -L --max-redirs 5 -w "%{http_code}" -o "$tmp_body" \
      -H "$auth_header" \
      -H "Accept: application/json" \
      "$@" \
      "$url" 2>/dev/null)

    case "$API_LAST_HTTP_CODE" in
      200|201)
        if [ "${GITLAB_DEBUG:-0}" = "1" ]; then
          local _size
          _size=$(wc -c < "$tmp_body" | tr -d ' ')
          log_debug "Response: HTTP ${API_LAST_HTTP_CODE}, ${_size} bytes"
        fi
        cat "$tmp_body"
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        return 0
        ;;
      401|403)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Authentication failed (HTTP ${API_LAST_HTTP_CODE}) for: $url"
        return 1
        ;;
      404)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Not found (HTTP 404): $url"
        return 1
        ;;
      429)
        local wait_time="$retry_delay"
        if [ "${HAS_JQ:-0}" = "1" ]; then
          local retry_after
          retry_after=$(cat "$tmp_body" | jq -r '.retry_after // empty' 2>/dev/null)
          [ -n "$retry_after" ] && wait_time="$retry_after"
        fi
        log_warn "Rate limited (HTTP 429). Waiting ${wait_time}s before retry ${attempt}/${max_retries}..."
        sleep "$wait_time"
        retry_delay=$((retry_delay * 2))
        attempt=$((attempt + 1))
        ;;
      000)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Network error: could not connect to ${GITLAB_URL}"
        return 2
        ;;
      *)
        log_warn "HTTP ${API_LAST_HTTP_CODE} from API (attempt ${attempt}/${max_retries})"
        attempt=$((attempt + 1))
        sleep "$retry_delay"
        ;;
    esac
  done

  rm -f "$tmp_body"
  log_error "API request failed after ${max_retries} attempts: $url"
  return 2
}

# Paginate through all results, appending compact JSON objects (one per line) to out_file.
# GitLab returns JSON arrays; iterates until a page returns fewer items than per_page.
# Usage: api_paginate_all <base_url> <out_file>
api_paginate_all() {
  local base_url="$1"
  local out_file="$2"
  local per_page="${GITLAB_PER_PAGE:-100}"
  local page=1

  while true; do
    local sep="&"
    printf '%s' "$base_url" | grep -q '?' || sep="?"
    local url="${base_url}${sep}per_page=${per_page}&page=${page}"

    log_debug "Paginating [page ${page}]: $url"
    local response
    response=$(api_curl "$url") || {
      log_error "Pagination failed at: $url"
      return 1
    }

    if [ "${HAS_JQ:-0}" = "1" ]; then
      local count
      count=$(printf '%s' "$response" | jq 'if type == "array" then length else 0 end' 2>/dev/null)
      count="${count:-0}"
      log_debug "Paginating [page ${page}]: got ${count} item(s)"

      printf '%s' "$response" | jq -c '.[]?' 2>/dev/null >> "$out_file"

      if [ "$count" -lt "$per_page" ]; then
        break
      fi
    else
      # No jq fallback: dump response and stop (no multi-page support without jq)
      printf '%s' "$response" >> "$out_file"
      break
    fi

    page=$((page + 1))
  done

  log_debug "Pagination complete: ${page} page(s) fetched"
}

# ---------------------------------------------------------------------------
# URL / ID resolution
# ---------------------------------------------------------------------------

# Convert a project URL, namespace/path, or numeric ID to an API-ready identifier.
# Numeric IDs are returned as-is. Paths are URL-encoded (/ → %2F).
# Usage: api_url_to_id <url|path|id>
api_url_to_id() {
  local input="$1"

  # Already a bare numeric ID
  if printf '%s' "$input" | grep -qE '^[0-9]+$'; then
    printf '%s' "$input"
    return 0
  fi

  local path
  if printf '%s' "$input" | grep -qE '^https?://'; then
    # Strip scheme and host
    path=$(printf '%s' "$input" | sed 's|^https\?://[^/]*||')
    # Remove leading slash
    path="${path#/}"
    # Remove /-/ sections (e.g. /-/issues, /-/merge_requests)
    path=$(printf '%s' "$path" | sed 's|/-/.*||')
    # Strip trailing slash
    path="${path%/}"
  else
    path="$input"
  fi

  # URL-encode slashes
  if printf '%s' "$path" | grep -q '/'; then
    printf '%s' "$path" | sed 's|/|%2F|g'
  else
    printf '%s' "$path"
  fi
}

# Convert a group URL, path, or numeric ID to an API-ready identifier.
# Usage: api_group_url_to_id <url|path|id>
api_group_url_to_id() {
  local input="$1"

  # Already a bare numeric ID
  if printf '%s' "$input" | grep -qE '^[0-9]+$'; then
    printf '%s' "$input"
    return 0
  fi

  local path
  if printf '%s' "$input" | grep -qE '^https?://'; then
    # Strip scheme and host
    path=$(printf '%s' "$input" | sed 's|^https\?://[^/]*||')
    path="${path#/}"
    # Remove leading "groups/" if present (https://gitlab.com/groups/mygroup)
    path=$(printf '%s' "$path" | sed 's|^groups/||')
    path="${path%/}"
  else
    path="$input"
  fi

  # URL-encode slashes for nested groups
  if printf '%s' "$path" | grep -q '/'; then
    printf '%s' "$path" | sed 's|/|%2F|g'
  else
    printf '%s' "$path"
  fi
}

# ---------------------------------------------------------------------------
# Project endpoints
# ---------------------------------------------------------------------------

api_get_project() {
  local project_id="$1"
  local base; base=$(api_base_url)
  log_debug "Fetching project: $project_id"
  local _result
  _result=$(api_curl "${base}/projects/${project_id}") || return 1
  if [ "${GITLAB_DEBUG:-0}" = "1" ] && [ "${HAS_JQ:-0}" = "1" ]; then
    log_debug "Project: id=$(printf '%s' "$_result" | jq -r '.id') \
name=$(printf '%s' "$_result" | jq -r '.name') \
namespace=$(printf '%s' "$_result" | jq -r '.path_with_namespace') \
default_branch=$(printf '%s' "$_result" | jq -r '.default_branch')"
  fi
  printf '%s' "$_result"
}

api_get_project_wikis() {
  local project_id="$1"
  local out_file="$2"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/projects/${project_id}/wikis?with_content=1" "$out_file"
}

api_get_project_issues() {
  local project_id="$1"
  local out_file="$2"
  local state="${GITLAB_STATE:-all}"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/projects/${project_id}/issues?scope=all&state=${state}" "$out_file"
}

api_get_project_mrs() {
  local project_id="$1"
  local out_file="$2"
  local state="${GITLAB_STATE:-all}"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/projects/${project_id}/merge_requests?scope=all&state=${state}" "$out_file"
}

# ---------------------------------------------------------------------------
# Group endpoints
# ---------------------------------------------------------------------------

api_get_group() {
  local group_id="$1"
  local base; base=$(api_base_url)
  log_debug "Fetching group: $group_id"
  local _result
  _result=$(api_curl "${base}/groups/${group_id}") || return 1
  if [ "${GITLAB_DEBUG:-0}" = "1" ] && [ "${HAS_JQ:-0}" = "1" ]; then
    log_debug "Group: id=$(printf '%s' "$_result" | jq -r '.id') \
name=$(printf '%s' "$_result" | jq -r '.name') \
path=$(printf '%s' "$_result" | jq -r '.full_path')"
  fi
  printf '%s' "$_result"
}

api_get_group_projects() {
  local group_id="$1"
  local out_file="$2"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/groups/${group_id}/projects?include_subgroups=true" "$out_file"
}

# Fetch all groups the authenticated user has at least Guest access to.
# Usage: api_get_accessible_groups <out_file>
api_get_accessible_groups() {
  local out_file="$1"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/groups?min_access_level=10" "$out_file"
}

# Fetch all projects the authenticated user is a member of.
# Usage: api_get_accessible_projects <out_file>
api_get_accessible_projects() {
  local out_file="$1"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/projects?membership=true" "$out_file"
}

# ---------------------------------------------------------------------------
# JSON field extractors
# ---------------------------------------------------------------------------

api_extract_id() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://'
  fi
}

api_extract_iid() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.iid // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"iid":[0-9]*' | head -1 | sed 's/"iid"://'
  fi
}

api_extract_title() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.title // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//'
  fi
}

api_extract_namespace() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.path_with_namespace // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"path_with_namespace":"[^"]*"' | head -1 \
      | sed 's/"path_with_namespace":"//;s/"$//'
  fi
}

api_extract_wiki_slug() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.slug // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"slug":"[^"]*"' | head -1 | sed 's/"slug":"//;s/"$//'
  fi
}

api_extract_wiki_title() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.title // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//'
  fi
}

# ---------------------------------------------------------------------------
# Source / branch endpoints
# ---------------------------------------------------------------------------

# Extract default_branch from a project JSON object.
# Usage: api_extract_default_branch <json>
api_extract_default_branch() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.default_branch // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"default_branch":"[^"]*"' | head -1 \
      | sed 's/"default_branch":"//;s/"$//'
  fi
}

# Extract the name field from a single branch JSON object.
# Usage: api_extract_branch_name <json>
api_extract_branch_name() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.name // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"$//'
  fi
}

# Extract the latest commit SHA (commit.id) from a single branch JSON object.
# Usage: api_extract_branch_commit_sha <json>
api_extract_branch_commit_sha() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.commit.id // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"id":"[a-f0-9]*"' | head -1 | sed 's/"id":"//;s/"$//'
  fi
}

# Fetch a single branch by name for a project.
# Usage: api_get_project_branch <project_id> <branch_name>
api_get_project_branch() {
  local project_id="$1"
  local branch_name="$2"
  local base; base=$(api_base_url)
  local encoded_branch
  encoded_branch=$(printf '%s' "$branch_name" | sed 's|/|%2F|g')
  local _result
  _result=$(api_curl "${base}/projects/${project_id}/repository/branches/${encoded_branch}") || return 1
  if [ "${GITLAB_DEBUG:-0}" = "1" ] && [ "${HAS_JQ:-0}" = "1" ]; then
    log_debug "Branch '${branch_name}': HEAD=$(printf '%s' "$_result" | jq -r '.commit.id') \
\"$(printf '%s' "$_result" | jq -r '.commit.title')\""
  fi
  printf '%s' "$_result"
}

# Fetch the SHA of the most recent (last) commit on a branch.
# Uses refs/heads/<branch> as the ref to avoid ambiguity with tags of the same name.
# With jq: sorts by committed_date so the result is correct regardless of API ordering.
# Usage: api_get_latest_commit_sha <project_id> <branch_name>
api_get_latest_commit_sha() {
  local project_id="$1"
  local branch_name="$2"
  local base; base=$(api_base_url)
  local encoded_branch
  # Use refs/heads/ prefix to unambiguously target the branch, not any same-named tag
  encoded_branch="refs%2Fheads%2F$(printf '%s' "$branch_name" | sed 's|/|%2F|g')"

  local result
  result=$(api_curl "${base}/projects/${project_id}/repository/commits?ref_name=${encoded_branch}&per_page=100") || return 1

  if [ "${HAS_JQ:-0}" = "1" ]; then
    # Sort by committed_date ascending and take the last entry — correct regardless
    # of whether the API returns commits newest-first or oldest-first.
    local _latest_json
    _latest_json=$(printf '%s' "$result" | jq 'sort_by(.committed_date) | last' 2>/dev/null)
    local _sha _title _date
    _sha=$(printf '%s' "$_latest_json" | jq -r '.id // empty' 2>/dev/null)
    if [ "${GITLAB_DEBUG:-0}" = "1" ] && [ -n "$_sha" ]; then
      _title=$(printf '%s' "$_latest_json" | jq -r '.title // ""' 2>/dev/null)
      _date=$(printf '%s' "$_latest_json" | jq -r '.committed_date // ""' 2>/dev/null | cut -c1-10)
      log_debug "Latest commit on '${branch_name}': ${_sha} (${_date}) \"${_title}\""
    fi
    printf '%s' "$_sha"
  else
    # No jq: grep for all 40-char hex SHAs in "id" fields, take the last match.
    # GitLab commits JSON lists commit objects each with "id":"<40-char-sha>"; the
    # last such value is the most recent when the API returns oldest-first (common
    # in self-hosted instances), and a sort-by-date fallback is not feasible without jq.
    printf '%s' "$result" | grep -o '"id":"[a-f0-9]\{40\}"' | tail -1 | sed 's/"id":"//;s/"$//'
  fi
}

# Fetch all commits for a branch; writes one compact JSON object per line to out_file.
# Uses refs/heads/<branch> to avoid ambiguity with same-named tags.
# Usage: api_get_project_commits <project_id> <branch_name> <out_file>
api_get_project_commits() {
  local project_id="$1"
  local branch_name="$2"
  local out_file="$3"
  local base; base=$(api_base_url)
  local encoded_branch
  encoded_branch="refs%2Fheads%2F$(printf '%s' "$branch_name" | sed 's|/|%2F|g')"
  api_paginate_all "${base}/projects/${project_id}/repository/commits?ref_name=${encoded_branch}" "$out_file"
}

# Fetch all branches for a project; writes one compact JSON object per line to out_file.
# Usage: api_get_project_branches <project_id> <out_file>
api_get_project_branches() {
  local project_id="$1"
  local out_file="$2"
  local base; base=$(api_base_url)
  api_paginate_all "${base}/projects/${project_id}/repository/branches" "$out_file"
}

# Download a source archive for a specific branch to out_file.
# Uses format=tar.gz (GitLab default for archive endpoint).
# Returns non-zero and does NOT create out_file on HTTP error.
# Usage: api_download_archive <project_id> <branch> <out_file>
api_download_archive() {
  local project_id="$1"
  local branch="$2"
  local out_file="$3"
  local base; base=$(api_base_url)
  local url="${base}/projects/${project_id}/repository/archive.tar.gz?sha=${branch}"

  local auth_header
  auth_header=$(auth_build_header)

  local tmp_out
  tmp_out=$(mktemp)

  local http_code
  http_code=$(curl -s -L --max-redirs 5 -w "%{http_code}" -o "$tmp_out" \
    -H "$auth_header" \
    "$url" 2>/dev/null)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    mv "$tmp_out" "$out_file"
    return 0
  else
    rm -f "$tmp_out"
    log_error "Archive download failed (HTTP ${http_code}) for branch '${branch}' of project ${project_id}"
    return 1
  fi
}
