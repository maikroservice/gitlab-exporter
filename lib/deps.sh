#!/usr/bin/env bash
# lib/deps.sh - Dependency detection; sets HAS_* capability flags

deps_check() {
  if ! command -v curl >/dev/null 2>&1; then
    log_fatal "curl is required but not found. Install curl and retry."
  fi
  export HAS_CURL=1

  if command -v jq >/dev/null 2>&1; then
    export HAS_JQ=1
    log_debug "jq found: $(command -v jq)"
  else
    export HAS_JQ=0
    log_warn "jq not found — JSON parsing will use basic grep/sed fallbacks (less reliable). Install jq for best results."
  fi
}

# Extract a JSON field without jq - basic fallback
# Usage: json_get <field> <json_string>
json_get() {
  local field="$1"
  local json="$2"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r ".$field // empty" 2>/dev/null
  else
    printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}
