#!/usr/bin/env bash
# lib/auth.sh - Auth header construction for all credential schemes

# Returns the full "Header-Name: value" string for curl's -H flag.
# Auto-detects auth type from available env vars when GITLAB_AUTH_TYPE is unset.
auth_build_header() {
  local auth_type="${GITLAB_AUTH_TYPE:-}"

  # Auto-detect
  if [ -z "$auth_type" ]; then
    if [ -n "${GITLAB_SESSION_COOKIE:-}" ]; then
      auth_type=cookie
    elif [ -n "${GITLAB_USERNAME:-}" ] && [ -n "${GITLAB_PASSWORD:-}" ]; then
      auth_type=basic
    elif [ -n "${GITLAB_TOKEN:-}" ]; then
      auth_type=pat
    else
      auth_type=pat  # will fail validation below
    fi
  fi

  case "$auth_type" in
    pat)
      if [ -z "${GITLAB_TOKEN:-}" ]; then
        log_fatal "GITLAB_TOKEN is required for pat auth"
      fi
      printf 'PRIVATE-TOKEN: %s' "${GITLAB_TOKEN}"
      ;;
    bearer)
      if [ -z "${GITLAB_TOKEN:-}" ]; then
        log_fatal "GITLAB_TOKEN is required for bearer auth"
      fi
      printf 'Authorization: Bearer %s' "${GITLAB_TOKEN}"
      ;;
    basic)
      if [ -z "${GITLAB_USERNAME:-}" ]; then
        log_fatal "GITLAB_USERNAME is required for basic auth"
      fi
      if [ -z "${GITLAB_PASSWORD:-}" ]; then
        log_fatal "GITLAB_PASSWORD is required for basic auth"
      fi
      local encoded
      encoded=$(printf '%s:%s' "${GITLAB_USERNAME}" "${GITLAB_PASSWORD}" | base64 | tr -d '\n')
      printf 'Authorization: Basic %s' "$encoded"
      ;;
    cookie)
      if [ -z "${GITLAB_SESSION_COOKIE:-}" ]; then
        log_fatal "GITLAB_SESSION_COOKIE is required for cookie auth"
      fi
      printf 'Cookie: _gitlab_session=%s' "${GITLAB_SESSION_COOKIE}"
      ;;
    *)
      log_fatal "Unknown GITLAB_AUTH_TYPE: ${auth_type}. Use pat, bearer, basic, or cookie."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Scope / permission checks
# ---------------------------------------------------------------------------

# Fetch the current authenticated user's profile.
# Usage: auth_whoami
# Returns: JSON object on stdout; exits non-zero on failure.
auth_whoami() {
  local base="${GITLAB_URL%/}/api/v4"
  local auth_header
  auth_header=$(auth_build_header)

  local tmp
  tmp=$(mktemp)
  local http_code
  http_code=$(curl -s -L --max-redirs 5 -w "%{http_code}" -o "$tmp" \
    -H "$auth_header" \
    -H "Accept: application/json" \
    "${base}/user" 2>/dev/null)

  if [ "$http_code" = "200" ]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  else
    rm -f "$tmp"
    log_error "Could not fetch user info (HTTP ${http_code})"
    return 1
  fi
}

# Fetch current PAT metadata including scopes.
# Only meaningful when GITLAB_AUTH_TYPE=pat.
# Usage: auth_get_pat_scopes
# Returns: JSON object on stdout; exits non-zero on failure.
auth_get_pat_scopes() {
  local base="${GITLAB_URL%/}/api/v4"
  local auth_header
  auth_header=$(auth_build_header)

  local tmp
  tmp=$(mktemp)
  local http_code
  http_code=$(curl -s -L --max-redirs 5 -w "%{http_code}" -o "$tmp" \
    -H "$auth_header" \
    -H "Accept: application/json" \
    "${base}/personal_access_tokens/self" 2>/dev/null)

  if [ "$http_code" = "200" ]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  else
    rm -f "$tmp"
    log_debug "Could not fetch PAT metadata (HTTP ${http_code})"
    return 1
  fi
}

# Check whether a specific scope name is present in a JSON scopes array.
# Usage: auth_scope_present <scopes_json_array> <scope_name>
# Returns: 0 if present, 1 if absent.
# Example: auth_scope_present '["api","read_repository"]' "api"
auth_scope_present() {
  local scopes_json="$1"
  local scope="$2"

  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$scopes_json" \
      | jq -e --arg s "$scope" 'map(. == $s) | any' >/dev/null 2>&1
  else
    printf '%s' "$scopes_json" | grep -q "\"${scope}\""
  fi
}

# Analyze a PAT JSON object and check whether it has the scopes needed by
# gitlab-exporter. Prints a summary to stderr (via log_*). Pure function —
# makes no HTTP calls.
#
# Required for wikis / issues / MRs:  api  OR  read_api
# Required for source downloads:      api  OR  read_repository
#
# Returns: 0 if minimum scopes are present; 1 if critical scope missing.
auth_analyze_pat_scopes() {
  local pat_json="$1"

  local token_name expires active scopes_json
  if [ "${HAS_JQ:-0}" = "1" ]; then
    token_name=$(printf '%s' "$pat_json" | jq -r '.name       // "unknown"')
    expires=$(   printf '%s' "$pat_json" | jq -r '.expires_at // "never"')
    active=$(    printf '%s' "$pat_json" | jq -r '.active     // false')
    scopes_json=$(printf '%s' "$pat_json" | jq -c '.scopes    // []')
  else
    token_name=$(printf '%s' "$pat_json" | grep -o '"name":"[^"]*"'       | head -1 | sed 's/"name":"//;s/"$//')
    expires=$(   printf '%s' "$pat_json" | grep -o '"expires_at":"[^"]*"' | head -1 | sed 's/"expires_at":"//;s/"$//')
    active=$(    printf '%s' "$pat_json" | grep -o '"active":[a-z]*'       | head -1 | sed 's/"active"://')
    scopes_json=$(printf '%s' "$pat_json" | grep -o '"scopes":\[[^]]*\]'   | head -1 | sed 's/"scopes"://')
    scopes_json="${scopes_json:-[]}"
  fi

  log_info "  Token   : ${token_name}"
  log_info "  Expires : ${expires}"
  log_info "  Active  : ${active}"
  log_info "  Scopes  : ${scopes_json}"

  # Check for API read access (required for all content types)
  local has_api=0 has_read_api=0
  auth_scope_present "$scopes_json" "api"      && has_api=1      || true
  auth_scope_present "$scopes_json" "read_api" && has_read_api=1 || true

  if [ "$has_api" = "0" ] && [ "$has_read_api" = "0" ]; then
    log_error "  Missing required scope: 'api' or 'read_api'"
    log_error "  Cannot export wiki pages, issues, or merge requests without it."
    return 1
  fi

  # Warn about optional scope for source download
  local has_read_repo=0
  auth_scope_present "$scopes_json" "read_repository" && has_read_repo=1 || true

  if [ "$has_api" = "0" ] && [ "$has_read_repo" = "0" ]; then
    log_warn "  Missing scope: 'read_repository' (source code download will fail)"
    log_warn "  Add 'read_repository' to the token or use 'api' scope to enable --source/--branches."
  fi

  log_info "  Scope check: OK"
  return 0
}

# Perform a full scope / permission check and print a human-readable report.
# Fetches current user info and (for PAT auth) token metadata.
# Returns: 0 if sufficient permissions for basic export; 1 if critical issue found.
auth_check_scope() {
  local user_json
  user_json=$(auth_whoami) || return 1

  local username name is_admin
  if [ "${HAS_JQ:-0}" = "1" ]; then
    username=$(printf '%s' "$user_json" | jq -r '.username  // "unknown"')
    name=$(    printf '%s' "$user_json" | jq -r '.name      // "unknown"')
    is_admin=$(printf '%s' "$user_json" | jq -r '.is_admin  // false')
  else
    username=$(printf '%s' "$user_json" | grep -o '"username":"[^"]*"' | head -1 | sed 's/"username":"//;s/"$//')
    name=$(    printf '%s' "$user_json" | grep -o '"name":"[^"]*"'     | head -1 | sed 's/"name":"//;s/"$//')
    is_admin="unknown"
  fi

  log_info "Authenticated as: ${name} (@${username})"
  [ "$is_admin" = "true" ] && log_info "  Role: Administrator (all scopes implicitly available)"

  local auth_type="${GITLAB_AUTH_TYPE:-pat}"
  if [ "$auth_type" = "pat" ]; then
    local pat_json
    if pat_json=$(auth_get_pat_scopes); then
      auth_analyze_pat_scopes "$pat_json" || return 1
    else
      log_warn "Could not retrieve PAT metadata — add 'read_user' scope to enable scope checks."
    fi
  else
    log_info "Auth type '${auth_type}': scope inspection not available (PAT only)."
  fi

  return 0
}

# Test API connectivity with a lightweight request.
# Returns 0 on success, 1 on auth failure, 2 on other error.
auth_test_connectivity() {
  local base_url="${GITLAB_URL%/}"
  local test_url="${base_url}/api/v4/projects?per_page=1"
  local auth_header
  auth_header=$(auth_build_header)

  log_debug "Testing connectivity: $test_url"
  local http_code
  http_code=$(curl -s -L --max-redirs 5 -o /dev/null -w "%{http_code}" \
    -H "$auth_header" \
    -H "Accept: application/json" \
    "${test_url}" 2>/dev/null)

  case "$http_code" in
    200) log_debug "Connectivity test passed (HTTP 200)"; return 0 ;;
    401|403) log_error "Authentication failed (HTTP ${http_code}). Check your credentials."; return 1 ;;
    000) log_error "Could not connect to ${base_url}. Check GITLAB_URL."; return 2 ;;
    3*) log_error "Unexpected redirect (HTTP ${http_code}). Check GITLAB_URL."; return 2 ;;
    *) log_error "Unexpected HTTP ${http_code} from ${base_url}"; return 2 ;;
  esac
}
