#!/usr/bin/env bash
# gitlab-exporter.sh - Export GitLab project content to Markdown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for _lib in log deps config auth api output convert discovery; do
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/${_lib}.sh"
done

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
_ITEMS_WRITTEN=0
_INTERRUPTED=0

_on_exit() {
  if [ -n "${GITLAB_OUTPUT_DIR:-}" ] && [ -d "${GITLAB_OUTPUT_DIR}" ]; then
    find "${GITLAB_OUTPUT_DIR}" -name '.tmp_*' -delete 2>/dev/null || true
  fi
  if [ "$_INTERRUPTED" = "1" ] && [ "${LIST_ONLY:-0}" != "1" ]; then
    if [ "$_ITEMS_WRITTEN" -gt 0 ]; then
      log_info "Interrupted — ${_ITEMS_WRITTEN} item(s) written to ${GITLAB_OUTPUT_DIR}"
    else
      log_warn "Interrupted — no items written yet"
    fi
  fi
}

trap '_INTERRUPTED=1; exit 130' INT TERM
trap '_on_exit' EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Export GitLab project content to Markdown.

Scope (one required unless set in config):
  --project <url|id|namespace/path>   Export from a single project
  --group   <url|id|namespace/path>   Export from all projects in a group

Content type (default: all):
  --wiki                Export wiki pages
  --issues              Export issues
  --merge-requests      Export merge requests
  --source              Export default branch source archive
  --commits             Export commit history to _commits.md per branch
  --branches <list>     Export named branches (comma-separated)
  --all-branches        Export all branches

Output:
  --output <dir>        Output directory (default: ./export)
  --force               Overwrite existing files

Options:
  --state opened|closed|all Issue/MR state filter (default: all)
  --list                    Dry run: print what would be exported
  --check-scope             Show authenticated user and token permissions, then exit
  --debug                   Enable verbose debug output
  --help                    Show this help

Authentication (via env vars or .gitlabrc):
  GITLAB_URL              Base URL (default: https://gitlab.com)
  GITLAB_AUTH_TYPE        pat (default) | bearer | basic | cookie
  GITLAB_TOKEN            Personal Access Token (pat / bearer)
  GITLAB_USERNAME         Username (basic auth)
  GITLAB_PASSWORD         Password (basic auth)
  GITLAB_SESSION_COOKIE   Value of _gitlab_session cookie (cookie auth)

See .env.example for all options.
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SCOPE=""
SCOPE_TARGET=""
EXPORT_WIKI=0
EXPORT_ISSUES=0
EXPORT_MRS=0
EXPORT_SOURCE=0
EXPORT_COMMITS=0
BRANCHES_LIST=""   # comma-separated branch names (--branches)
ALL_BRANCHES=0     # --all-branches
OUTPUT_DIR=""
STATE=""
LIST_ONLY=0
FORCE=0
CHECK_SCOPE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        SCOPE=project; SCOPE_TARGET="$2"; shift 2 ;;
    --group)          SCOPE=group;   SCOPE_TARGET="$2"; shift 2 ;;
    --wiki)           EXPORT_WIKI=1;   shift ;;
    --issues)         EXPORT_ISSUES=1; shift ;;
    --merge-requests) EXPORT_MRS=1;    shift ;;
    --source)         EXPORT_SOURCE=1; shift ;;
    --commits)        EXPORT_COMMITS=1; shift ;;
    --branches)       EXPORT_SOURCE=1; BRANCHES_LIST="$2"; shift 2 ;;
    --all-branches)   EXPORT_SOURCE=1; ALL_BRANCHES=1; shift ;;
    --output)         OUTPUT_DIR="$2"; shift 2 ;;
    --state)          STATE="$2";      shift 2 ;;
    --force)          FORCE=1;         shift ;;
    --list)           LIST_ONLY=1;     shift ;;
    --check-scope)    CHECK_SCOPE=1;   shift ;;
    --debug)          export GITLAB_DEBUG=1; shift ;;
    --help|-h)        usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# Default: export all content types when none specified
if [ "$EXPORT_WIKI" = "0" ] && [ "$EXPORT_ISSUES" = "0" ] && [ "$EXPORT_MRS" = "0" ] && [ "$EXPORT_SOURCE" = "0" ] && [ "$EXPORT_COMMITS" = "0" ]; then
  EXPORT_WIKI=1
  EXPORT_ISSUES=1
  EXPORT_MRS=1
  EXPORT_SOURCE=1
  EXPORT_COMMITS=1
fi

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
deps_check
config_load
config_require_auth

# CLI flags override config
[ -n "$OUTPUT_DIR" ] && export GITLAB_OUTPUT_DIR="$OUTPUT_DIR"
[ -n "$STATE" ]      && export GITLAB_STATE="$STATE"
[ "$FORCE" = "1" ]   && export GITLAB_FORCE=1

: "${GITLAB_OUTPUT_DIR:=./export}"
: "${GITLAB_STATE:=all}"

if [ -z "$SCOPE" ] && [ "$CHECK_SCOPE" = "0" ]; then
  # Fall back to config-provided scope, then discovery mode
  if [ -n "${GITLAB_PROJECT:-}" ]; then
    SCOPE=project; SCOPE_TARGET="$GITLAB_PROJECT"
  elif [ -n "${GITLAB_GROUP:-}" ]; then
    SCOPE=group; SCOPE_TARGET="$GITLAB_GROUP"
  else
    SCOPE=discovery
  fi
fi

if ! auth_test_connectivity; then
  exit 1
fi

if [ "$CHECK_SCOPE" = "1" ]; then
  auth_check_scope
  exit $?
fi

log_debug "scope=${SCOPE} target=${SCOPE_TARGET} wiki=${EXPORT_WIKI} issues=${EXPORT_ISSUES} mrs=${EXPORT_MRS} source=${EXPORT_SOURCE} all_branches=${ALL_BRANCHES} branches=${BRANCHES_LIST} state=${GITLAB_STATE} output=${GITLAB_OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Export helpers
# ---------------------------------------------------------------------------
_export_wiki() {
  local project_id="$1"
  local namespace="$2"

  log_debug "Fetching wiki pages for project: $project_id"
  local pages_file
  pages_file=$(mktemp)
  api_get_project_wikis "$project_id" "$pages_file" || { rm -f "$pages_file"; return 1; }

  while IFS= read -r page_json; do
    [ -z "$page_json" ] && continue
    local slug title
    slug=$(api_extract_wiki_slug "$page_json")
    title=$(api_extract_wiki_title "$page_json")
    if [ -z "$slug" ] || [ "$slug" = "null" ]; then continue; fi

    if [ "$LIST_ONLY" = "1" ]; then
      printf '[wiki] %s (%s)\n' "$title" "$slug"
      continue
    fi

    local content
    content=$(convert_wiki_page "$page_json")

    local path
    path=$(output_build_path "$GITLAB_OUTPUT_DIR" "$namespace" "wiki" "$slug")
    output_write_file "$path" "$content"
    _ITEMS_WRITTEN=$((_ITEMS_WRITTEN + 1))
    log_info "Exported wiki: $title → $path"
  done < "$pages_file"

  rm -f "$pages_file"
}

_export_issues() {
  local project_id="$1"
  local namespace="$2"

  log_debug "Fetching issues for project: $project_id"
  local issues_file
  issues_file=$(mktemp)
  api_get_project_issues "$project_id" "$issues_file" || { rm -f "$issues_file"; return 1; }

  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    local iid title slug
    iid=$(api_extract_iid "$issue_json")
    title=$(api_extract_title "$issue_json")
    if [ -z "$iid" ] || [ "$iid" = "null" ]; then continue; fi
    slug=$(output_slugify "$title")

    if [ "$LIST_ONLY" = "1" ]; then
      printf '[issue] #%s %s\n' "$iid" "$title"
      continue
    fi

    local content
    content=$(convert_issue_to_markdown "$issue_json")

    local path
    path=$(output_build_path "$GITLAB_OUTPUT_DIR" "$namespace" "issues" "${iid}-${slug}")
    path=$(output_collision_path "$path" "$iid")
    output_write_file "$path" "$content"
    _ITEMS_WRITTEN=$((_ITEMS_WRITTEN + 1))
    log_info "Exported issue: #${iid} ${title} → $path"
  done < "$issues_file"

  rm -f "$issues_file"
}

_export_mrs() {
  local project_id="$1"
  local namespace="$2"

  log_debug "Fetching merge requests for project: $project_id"
  local mrs_file
  mrs_file=$(mktemp)
  api_get_project_mrs "$project_id" "$mrs_file" || { rm -f "$mrs_file"; return 1; }

  while IFS= read -r mr_json; do
    [ -z "$mr_json" ] && continue
    local iid title slug
    iid=$(api_extract_iid "$mr_json")
    title=$(api_extract_title "$mr_json")
    if [ -z "$iid" ] || [ "$iid" = "null" ]; then continue; fi
    slug=$(output_slugify "$title")

    if [ "$LIST_ONLY" = "1" ]; then
      printf '[mr] !%s %s\n' "$iid" "$title"
      continue
    fi

    local content
    content=$(convert_mr_to_markdown "$mr_json")

    local path
    path=$(output_build_path "$GITLAB_OUTPUT_DIR" "$namespace" "merge-requests" "${iid}-${slug}")
    path=$(output_collision_path "$path" "$iid")
    output_write_file "$path" "$content"
    _ITEMS_WRITTEN=$((_ITEMS_WRITTEN + 1))
    log_info "Exported MR: !${iid} ${title} → $path"
  done < "$mrs_file"

  rm -f "$mrs_file"
}

# Resolve the list of branches to download for a project.
# Outputs one "<name>\t<commit_sha>" pair per line.
# Priority: --branches list > --all-branches > default branch
_collect_branches() {
  local project_id="$1"
  local project_json="$2"

  if [ -n "$BRANCHES_LIST" ]; then
    # Comma-separated list provided by operator — use commits API to get latest SHA per branch
    local name sha
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      sha=$(api_get_latest_commit_sha "$project_id" "$name") || sha=""
      printf '%s\t%s\n' "$name" "${sha:-}"
    done <<EOF
$(printf '%s' "$BRANCHES_LIST" | tr ',' '\n')
EOF
    return 0
  fi

  if [ "$ALL_BRANCHES" = "1" ]; then
    local branches_file
    branches_file=$(mktemp)
    api_get_project_branches "$project_id" "$branches_file" || { rm -f "$branches_file"; return 1; }
    while IFS= read -r branch_json; do
      [ -z "$branch_json" ] && continue
      local name sha
      name=$(api_extract_branch_name "$branch_json")
      [ -n "$name" ] && [ "$name" != "null" ] || continue
      sha=$(api_get_latest_commit_sha "$project_id" "$name") || sha=""
      printf '%s\t%s\n' "$name" "${sha:-}"
    done < "$branches_file"
    rm -f "$branches_file"
    return 0
  fi

  # Default: download the project's default branch
  local default_branch sha
  default_branch=$(api_extract_default_branch "$project_json")
  if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
    default_branch="main"
  fi
  sha=$(api_get_latest_commit_sha "$project_id" "$default_branch") || sha=""
  printf '%s\t%s\n' "$default_branch" "${sha:-}"
}

_export_source() {
  local project_id="$1"
  local namespace="$2"
  local project_json="$3"

  local branches
  branches=$(_collect_branches "$project_id" "$project_json") || return 1

  local source_dir="${GITLAB_OUTPUT_DIR}/${namespace}/source"

  while IFS='	' read -r branch sha; do
    [ -z "$branch" ] && continue

    if [ "$LIST_ONLY" = "1" ]; then
      printf '[source] %s\n' "$branch"
      continue
    fi

    # Use the explicit commit SHA when available. Fall back to refs/heads/<branch>
    # (not the bare branch name) so GitLab resolves the branch unambiguously even
    # when a tag with the same name exists and would otherwise take precedence.
    local ref
    if [ -n "$sha" ]; then
      ref="$sha"
    else
      ref="refs/heads/${branch}"
    fi

    mkdir -p "$source_dir"
    local tmp_archive
    tmp_archive=$(mktemp /tmp/gitlab-source-XXXXXX.tar.gz)
    api_download_archive "$project_id" "$ref" "$tmp_archive" || {
      log_warn "Failed to download source for branch: $branch"
      rm -f "$tmp_archive"
      continue
    }

    local branch_dir="${source_dir}/${branch}"
    mkdir -p "$branch_dir"
    if ! tar xzf "$tmp_archive" --strip-components=1 -C "$branch_dir" 2>/dev/null; then
      log_warn "Failed to extract source archive for branch: $branch"
      rm -f "$tmp_archive"
      rm -rf "$branch_dir"
      continue
    fi
    rm -f "$tmp_archive"

    _ITEMS_WRITTEN=$((_ITEMS_WRITTEN + 1))
    log_info "Exported source: $branch (${ref}) → $branch_dir"
  done <<EOF
$branches
EOF
}

_export_commits() {
  local project_id="$1"
  local namespace="$2"
  local project_json="$3"

  local branches
  branches=$(_collect_branches "$project_id" "$project_json") || return 1

  while IFS='	' read -r branch sha; do
    [ -z "$branch" ] && continue

    if [ "$LIST_ONLY" = "1" ]; then
      printf '[commits] %s\n' "$branch"
      continue
    fi

    local commits_file
    commits_file=$(mktemp)
    api_get_project_commits "$project_id" "$branch" "$commits_file" || {
      log_warn "Failed to fetch commits for branch: $branch"
      rm -f "$commits_file"
      continue
    }

    local count
    count=$(wc -l < "$commits_file" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
      log_warn "No commits found for branch: $branch"
      rm -f "$commits_file"
      continue
    fi

    local path
    path=$(output_build_path "$GITLAB_OUTPUT_DIR" "$namespace" "commits" "$branch")

    local tmp_out
    tmp_out=$(mktemp)
    printf '# Commits: %s (%s commits)\n\n| SHA | Timestamp | Message | Author |\n|---|---|---|---|\n' \
      "$branch" "$count" > "$tmp_out"
    while IFS= read -r commit_json; do
      [ -z "$commit_json" ] && continue
      convert_commit_to_markdown "$commit_json" >> "$tmp_out"
    done < "$commits_file"
    rm -f "$commits_file"

    output_write_file "$path" "$(cat "$tmp_out")"
    rm -f "$tmp_out"
    _ITEMS_WRITTEN=$((_ITEMS_WRITTEN + 1))
    log_info "Exported commits: $branch (${count} commits) → $path"
  done <<EOF
$branches
EOF
}

_export_project() {
  local project_id="$1"
  local namespace="$2"
  local project_json="${3:-}"

  log_info "Exporting project: $namespace (id=${project_id})"
  log_info "Output directory : ${GITLAB_OUTPUT_DIR}/${namespace}"

  # Each content type is attempted independently. A failure (e.g. wiki
  # disabled → 404) is logged as a warning but does not stop the others.
  if [ "$EXPORT_WIKI" = "1" ]; then
    _export_wiki   "$project_id" "$namespace" \
      || log_warn "Wiki export skipped for $namespace (feature may be disabled)"
  fi
  if [ "$EXPORT_ISSUES" = "1" ]; then
    _export_issues "$project_id" "$namespace" \
      || log_warn "Issues export failed for $namespace"
  fi
  if [ "$EXPORT_MRS" = "1" ]; then
    _export_mrs    "$project_id" "$namespace" \
      || log_warn "Merge-request export failed for $namespace"
  fi
  if [ "$EXPORT_SOURCE" = "1" ]; then
    _export_source "$project_id" "$namespace" "$project_json" \
      || log_warn "Source export failed for $namespace"
  fi
  if [ "$EXPORT_COMMITS" = "1" ]; then
    _export_commits "$project_id" "$namespace" "$project_json" \
      || log_warn "Commits export failed for $namespace"
  fi
}

_run_discovery() {
  mkdir -p "$GITLAB_OUTPUT_DIR"
  log_info "Running in discovery mode — mapping accessible resources on ${GITLAB_URL:-https://gitlab.com}"

  # Fetch identity once; reuse for both console output and file reports
  local user_json
  user_json=$(auth_whoami) || { log_error "Cannot identify current user"; return 1; }

  local pat_json=""
  if [ "${GITLAB_AUTH_TYPE:-pat}" = "pat" ]; then
    pat_json=$(auth_get_pat_scopes 2>/dev/null) || true
  fi

  # Console scope summary (goes to stderr via log_*)
  if [ -n "$pat_json" ]; then
    auth_analyze_pat_scopes "$pat_json" || log_warn "Token has insufficient scopes for some export types"
  fi

  # Write scope report
  local scope_file="${GITLAB_OUTPUT_DIR}/_scope.md"
  discovery_write_scope_report "$user_json" "$pat_json" > "$scope_file"
  log_info "Scope report → ${scope_file}"

  # Crawl accessible groups and projects
  log_info "Fetching accessible groups..."
  local groups_file; groups_file=$(mktemp)
  api_get_accessible_groups "$groups_file" || true

  log_info "Fetching accessible projects..."
  local projects_file; projects_file=$(mktemp)
  api_get_accessible_projects "$projects_file" || true

  local group_count project_count
  group_count=$(grep -c '.' "$groups_file"   2>/dev/null || printf '0')
  project_count=$(grep -c '.' "$projects_file" 2>/dev/null || printf '0')
  log_info "Found ${group_count} group(s) and ${project_count} project(s)"

  # Write discovery index
  local discovery_file="${GITLAB_OUTPUT_DIR}/_discovery.md"
  discovery_write_index "$user_json" "$groups_file" "$projects_file" > "$discovery_file"
  log_info "Discovery index → ${discovery_file}"

  rm -f "$groups_file" "$projects_file"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
case "$SCOPE" in

  discovery)
    _run_discovery
    ;;

  project)
    project_id=$(api_url_to_id "$SCOPE_TARGET") || exit 1
    project_json=$(api_get_project "$project_id") || exit 1
    namespace=$(api_extract_namespace "$project_json")
    [ -z "$namespace" ] && namespace="$project_id"
    _export_project "$project_id" "$namespace" "$project_json"
    ;;

  group)
    group_id=$(api_group_url_to_id "$SCOPE_TARGET") || exit 1
    projects_file=$(mktemp)
    api_get_group_projects "$group_id" "$projects_file" || { rm -f "$projects_file"; exit 1; }

    if [ "$LIST_ONLY" = "1" ]; then
      log_info "Projects in group: $SCOPE_TARGET"
    fi

    while IFS= read -r proj_json; do
      [ -z "$proj_json" ] && continue
      pid=$(api_extract_id "$proj_json")
      ns=$(api_extract_namespace "$proj_json")
      [ -z "$pid" ] || [ "$pid" = "null" ] && continue
      [ -z "$ns" ] && ns="$pid"

      if [ "$LIST_ONLY" = "1" ]; then
        printf '[project] %s (id=%s)\n' "$ns" "$pid"
        continue
      fi

      _export_project "$pid" "$ns" "$proj_json"
    done < "$projects_file"

    rm -f "$projects_file"
    ;;

esac

exit 0
