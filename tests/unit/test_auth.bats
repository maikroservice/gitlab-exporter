#!/usr/bin/env bats
# tests/unit/test_auth.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  unset GITLAB_URL GITLAB_TOKEN GITLAB_USERNAME GITLAB_PASSWORD GITLAB_SESSION_COOKIE GITLAB_AUTH_TYPE
}

# --- PAT auth (default) ---

@test "auth_build_header: pat auth returns PRIVATE-TOKEN header" {
  export GITLAB_AUTH_TYPE=pat
  export GITLAB_TOKEN=my_pat_token

  result=$(auth_build_header)
  [ "$result" = "PRIVATE-TOKEN: my_pat_token" ]
}

@test "auth_build_header: pat auth is the default when GITLAB_AUTH_TYPE not set" {
  export GITLAB_TOKEN=my_pat_token
  unset GITLAB_AUTH_TYPE

  result=$(auth_build_header)
  [ "$result" = "PRIVATE-TOKEN: my_pat_token" ]
}

@test "auth_build_header: pat auth exits non-zero when TOKEN missing" {
  export GITLAB_AUTH_TYPE=pat
  unset GITLAB_TOKEN

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Bearer auth ---

@test "auth_build_header: bearer auth returns Authorization Bearer header" {
  export GITLAB_AUTH_TYPE=bearer
  export GITLAB_TOKEN=my_oauth_token

  result=$(auth_build_header)
  [ "$result" = "Authorization: Bearer my_oauth_token" ]
}

@test "auth_build_header: bearer auth exits non-zero when TOKEN missing" {
  export GITLAB_AUTH_TYPE=bearer
  unset GITLAB_TOKEN

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Basic auth (username + password) ---

@test "auth_build_header: basic auth encodes username:password as Base64" {
  export GITLAB_AUTH_TYPE=basic
  export GITLAB_USERNAME=admin
  export GITLAB_PASSWORD=secret

  result=$(auth_build_header)
  expected="Authorization: Basic $(printf 'admin:secret' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: basic auth header has no newlines" {
  export GITLAB_AUTH_TYPE=basic
  export GITLAB_USERNAME=admin
  export GITLAB_PASSWORD=secret

  result=$(auth_build_header)
  [[ "$result" != *$'\n'* ]]
}

@test "auth_build_header: basic auth exits non-zero when USERNAME missing" {
  export GITLAB_AUTH_TYPE=basic
  export GITLAB_PASSWORD=secret
  unset GITLAB_USERNAME

  run auth_build_header
  [ "$status" -ne 0 ]
}

@test "auth_build_header: basic auth exits non-zero when PASSWORD missing" {
  export GITLAB_AUTH_TYPE=basic
  export GITLAB_USERNAME=admin
  unset GITLAB_PASSWORD

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Cookie auth ---

@test "auth_build_header: cookie auth returns Cookie header" {
  export GITLAB_AUTH_TYPE=cookie
  export GITLAB_SESSION_COOKIE=abc123sessionvalue

  result=$(auth_build_header)
  [ "$result" = "Cookie: _gitlab_session=abc123sessionvalue" ]
}

@test "auth_build_header: cookie auth exits non-zero when SESSION_COOKIE missing" {
  export GITLAB_AUTH_TYPE=cookie
  unset GITLAB_SESSION_COOKIE

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Auto-detection ---

@test "auth_build_header: auto-detects pat when only TOKEN is set" {
  unset GITLAB_AUTH_TYPE GITLAB_USERNAME GITLAB_PASSWORD GITLAB_SESSION_COOKIE
  export GITLAB_TOKEN=auto_detect_token

  result=$(auth_build_header)
  [ "$result" = "PRIVATE-TOKEN: auto_detect_token" ]
}

@test "auth_build_header: auto-detects basic when USERNAME and PASSWORD set" {
  unset GITLAB_AUTH_TYPE GITLAB_TOKEN GITLAB_SESSION_COOKIE
  export GITLAB_USERNAME=user
  export GITLAB_PASSWORD=pass

  result=$(auth_build_header)
  expected="Authorization: Basic $(printf 'user:pass' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: auto-detects cookie when SESSION_COOKIE set" {
  unset GITLAB_AUTH_TYPE GITLAB_TOKEN GITLAB_USERNAME GITLAB_PASSWORD
  export GITLAB_SESSION_COOKIE=cookievalue

  result=$(auth_build_header)
  [ "$result" = "Cookie: _gitlab_session=cookievalue" ]
}

# --- Unknown auth type ---

@test "auth_build_header: exits non-zero for unknown auth type" {
  export GITLAB_AUTH_TYPE=oauth2
  export GITLAB_TOKEN=something

  run auth_build_header
  [ "$status" -ne 0 ]
}
