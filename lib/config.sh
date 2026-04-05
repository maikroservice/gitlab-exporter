#!/usr/bin/env bash
# lib/config.sh - Configuration loading
# Precedence (highest to lowest): CLI flags > env vars > .gitlabrc > .env > defaults

config_load() {
  # 1. .gitlabrc (project dir or home dir) — highest file-based priority
  local rc_file=""
  if [ -f "./.gitlabrc" ]; then
    rc_file="./.gitlabrc"
  elif [ -f "${HOME}/.gitlabrc" ]; then
    rc_file="${HOME}/.gitlabrc"
  fi
  if [ -n "$rc_file" ]; then
    log_debug "Loading config from $rc_file"
    _config_parse_file "$rc_file"
  fi

  # 2. .env (project dir only) — lowest file-based priority
  if [ -f "./.env" ]; then
    log_debug "Loading config from .env"
    _config_parse_file "./.env"
  fi

  # Apply defaults for anything still unset
  : "${GITLAB_URL:=https://gitlab.com}"
  : "${GITLAB_OUTPUT_DIR:=./export}"
  : "${GITLAB_MAX_RETRIES:=3}"
  : "${GITLAB_RETRY_DELAY:=5}"
  : "${GITLAB_DEBUG:=0}"
  : "${GITLAB_PER_PAGE:=100}"
  : "${GITLAB_STATE:=all}"

  export GITLAB_URL GITLAB_TOKEN GITLAB_USERNAME GITLAB_PASSWORD GITLAB_SESSION_COOKIE
  export GITLAB_AUTH_TYPE GITLAB_OUTPUT_DIR GITLAB_MAX_RETRIES GITLAB_RETRY_DELAY
  export GITLAB_DEBUG GITLAB_PER_PAGE GITLAB_STATE

  log_debug "Config loaded: url=${GITLAB_URL} output=${GITLAB_OUTPUT_DIR}"
}

# Parse a KEY=VALUE file (supports comments, quoted values, inline comments).
# Only processes GITLAB_* keys. Does not overwrite vars already set in the environment.
_config_parse_file() {
  local file="$1"
  local line key value
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$line" in
      \#*|"") continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=$(printf '%s' "$key" | sed 's/[[:space:]]//g')
    case "$key" in
      GITLAB_*) ;;
      *) continue ;;
    esac
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed "s/^['\"]//;s/['\"]$//")
    if [ -z "${!key:-}" ]; then
      export "$key"="$value"
    fi
  done < "$file"
}

config_require() {
  local var="$1"
  local hint="${2:-Set $var in .gitlabrc or as an environment variable}"
  if [ -z "${!var:-}" ]; then
    log_fatal "$var is required but not set. $hint (see .env.example)"
  fi
}

config_require_auth() {
  local auth_type="${GITLAB_AUTH_TYPE:-}"

  # Auto-detect if not set
  if [ -z "$auth_type" ]; then
    if [ -n "${GITLAB_SESSION_COOKIE:-}" ]; then
      auth_type=cookie
    elif [ -n "${GITLAB_USERNAME:-}" ] && [ -n "${GITLAB_PASSWORD:-}" ]; then
      auth_type=basic
    else
      auth_type=pat
    fi
    export GITLAB_AUTH_TYPE="$auth_type"
  fi

  case "$auth_type" in
    pat|bearer)
      config_require GITLAB_TOKEN "Set GITLAB_TOKEN to your Personal Access Token"
      ;;
    basic)
      config_require GITLAB_USERNAME "Set GITLAB_USERNAME for basic auth"
      config_require GITLAB_PASSWORD "Set GITLAB_PASSWORD for basic auth"
      ;;
    cookie)
      config_require GITLAB_SESSION_COOKIE "Set GITLAB_SESSION_COOKIE to your _gitlab_session cookie value"
      ;;
    *)
      log_fatal "Unknown GITLAB_AUTH_TYPE: ${auth_type}. Use pat, bearer, basic, or cookie."
      ;;
  esac
}
