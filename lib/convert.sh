#!/usr/bin/env bash
# lib/convert.sh - Format GitLab content as Markdown

# Format a wiki page JSON object as Markdown.
# Wiki content is already Markdown — pass it through unchanged.
# Usage: convert_wiki_page <json>
convert_wiki_page() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.content // ""' 2>/dev/null
  else
    # Basic fallback: extract content field (may not handle multi-line well)
    printf '%s' "$json" | grep -o '"content":"[^"]*"' | head -1 \
      | sed 's/"content":"//;s/"$//' | sed 's/\\n/\n/g;s/\\"/"/g'
  fi
}

# Format an issue JSON object as Markdown.
# Usage: convert_issue_to_markdown <json>
convert_issue_to_markdown() {
  local json="$1"

  if [ "${HAS_JQ:-0}" = "1" ]; then
    local iid title state author assignees labels milestone created updated closed url description
    iid=$(printf '%s' "$json" | jq -r '.iid // empty' 2>/dev/null)
    title=$(printf '%s' "$json" | jq -r '.title // ""' 2>/dev/null)
    state=$(printf '%s' "$json" | jq -r '.state // ""' 2>/dev/null)
    author=$(printf '%s' "$json" | jq -r '.author.username // ""' 2>/dev/null)
    assignees=$(printf '%s' "$json" | jq -r '[.assignees[]?.username] | join(", ")' 2>/dev/null)
    labels=$(printf '%s' "$json" | jq -r '[.labels[]?] | join(", ")' 2>/dev/null)
    milestone=$(printf '%s' "$json" | jq -r '.milestone.title // ""' 2>/dev/null)
    created=$(printf '%s' "$json" | jq -r '(.created_at // "") | split("T") | .[0]' 2>/dev/null)
    updated=$(printf '%s' "$json" | jq -r '(.updated_at // "") | split("T") | .[0]' 2>/dev/null)
    closed=$(printf '%s' "$json" | jq -r '(.closed_at // "") | split("T") | .[0]' 2>/dev/null)
    url=$(printf '%s' "$json" | jq -r '.web_url // ""' 2>/dev/null)
    description=$(printf '%s' "$json" | jq -r '.description // ""' 2>/dev/null)

    printf '# Issue #%s: %s\n\n' "$iid" "$title"

    # Metadata line 1: state, author, assignees, labels
    printf '**State:** %s' "$state"
    [ -n "$author" ]    && printf ' | **Author:** %s' "$author"
    [ -n "$assignees" ] && printf ' | **Assignees:** %s' "$assignees"
    [ -n "$labels" ]    && printf ' | **Labels:** %s' "$labels"
    printf '\n'

    # Metadata line 2: dates, milestone
    printf '**Created:** %s' "$created"
    [ -n "$updated" ]   && printf ' | **Updated:** %s' "$updated"
    [ -n "$closed" ] && [ "$closed" != "null" ] && printf ' | **Closed:** %s' "$closed"
    [ -n "$milestone" ] && printf ' | **Milestone:** %s' "$milestone"
    printf '\n'

    [ -n "$url" ] && printf '**URL:** %s\n' "$url"
    printf '\n---\n\n'
    printf '%s\n' "${description:-}"
  else
    # Minimal fallback without jq
    local iid title state
    iid=$(printf '%s' "$json" | grep -o '"iid":[0-9]*' | head -1 | sed 's/"iid"://')
    title=$(printf '%s' "$json" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//')
    state=$(printf '%s' "$json" | grep -o '"state":"[^"]*"' | head -1 | sed 's/"state":"//;s/"$//')
    printf '# Issue #%s: %s\n\n**State:** %s\n\n---\n\n' "$iid" "$title" "$state"
  fi
}

# Format a single commit JSON object as a Markdown table row.
# Output: | `short_id` | YYYY-MM-DD HH:MM | message title | author name |
# Usage: convert_commit_to_markdown <json>
convert_commit_to_markdown() {
  local json="$1"

  if [ "${HAS_JQ:-0}" = "1" ]; then
    local short_id author_name date title
    short_id=$(printf '%s' "$json" | jq -r '.short_id // ""' 2>/dev/null)
    author_name=$(printf '%s' "$json" | jq -r '.author_name // ""' 2>/dev/null)
    date=$(printf '%s' "$json" | jq -r '(.authored_date // "") | gsub("(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<t>[0-9]{2}:[0-9]{2}).*"; "\(.d) \(.t)")' 2>/dev/null)
    title=$(printf '%s' "$json" | jq -r '(.title // .message // "") | split("\n") | .[0]' 2>/dev/null)
    printf '| `%s` | %s | %s | %s |\n' "$short_id" "$date" "$title" "$author_name"
  else
    local short_id author_name title date
    short_id=$(printf '%s' "$json" | grep -o '"short_id":"[^"]*"' | head -1 | sed 's/"short_id":"//;s/"$//')
    author_name=$(printf '%s' "$json" | grep -o '"author_name":"[^"]*"' | head -1 | sed 's/"author_name":"//;s/"$//')
    title=$(printf '%s' "$json" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//')
    date=$(printf '%s' "$json" | grep -o '"authored_date":"[^"]*"' | head -1 | sed 's/"authored_date":"//;s/"$//;s/T/ /;s/\.[0-9]*Z$//')
    printf '| `%s` | %s | %s | %s |\n' "$short_id" "$date" "$title" "$author_name"
  fi
}

# Format a merge request JSON object as Markdown.
# Usage: convert_mr_to_markdown <json>
convert_mr_to_markdown() {
  local json="$1"

  if [ "${HAS_JQ:-0}" = "1" ]; then
    local iid title state author assignees labels milestone source_branch target_branch
    local created updated merged url description
    iid=$(printf '%s' "$json" | jq -r '.iid // empty' 2>/dev/null)
    title=$(printf '%s' "$json" | jq -r '.title // ""' 2>/dev/null)
    state=$(printf '%s' "$json" | jq -r '.state // ""' 2>/dev/null)
    author=$(printf '%s' "$json" | jq -r '.author.username // ""' 2>/dev/null)
    assignees=$(printf '%s' "$json" | jq -r '[.assignees[]?.username] | join(", ")' 2>/dev/null)
    labels=$(printf '%s' "$json" | jq -r '[.labels[]?] | join(", ")' 2>/dev/null)
    milestone=$(printf '%s' "$json" | jq -r '.milestone.title // ""' 2>/dev/null)
    source_branch=$(printf '%s' "$json" | jq -r '.source_branch // ""' 2>/dev/null)
    target_branch=$(printf '%s' "$json" | jq -r '.target_branch // ""' 2>/dev/null)
    created=$(printf '%s' "$json" | jq -r '(.created_at // "") | split("T") | .[0]' 2>/dev/null)
    updated=$(printf '%s' "$json" | jq -r '(.updated_at // "") | split("T") | .[0]' 2>/dev/null)
    merged=$(printf '%s' "$json" | jq -r '(.merged_at // "") | split("T") | .[0]' 2>/dev/null)
    url=$(printf '%s' "$json" | jq -r '.web_url // ""' 2>/dev/null)
    description=$(printf '%s' "$json" | jq -r '.description // ""' 2>/dev/null)

    printf '# !%s: %s\n\n' "$iid" "$title"

    printf '**State:** %s' "$state"
    [ -n "$author" ]       && printf ' | **Author:** %s' "$author"
    [ -n "$assignees" ]    && printf ' | **Assignees:** %s' "$assignees"
    [ -n "$labels" ]       && printf ' | **Labels:** %s' "$labels"
    printf '\n'

    printf '**Branch:** `%s` → `%s`\n' "$source_branch" "$target_branch"

    printf '**Created:** %s' "$created"
    [ -n "$updated" ]  && printf ' | **Updated:** %s' "$updated"
    [ -n "$merged" ] && [ "$merged" != "null" ] && printf ' | **Merged:** %s' "$merged"
    [ -n "$milestone" ] && printf ' | **Milestone:** %s' "$milestone"
    printf '\n'

    [ -n "$url" ] && printf '**URL:** %s\n' "$url"
    printf '\n---\n\n'
    printf '%s\n' "${description:-}"
  else
    local iid title state source_branch target_branch
    iid=$(printf '%s' "$json" | grep -o '"iid":[0-9]*' | head -1 | sed 's/"iid"://')
    title=$(printf '%s' "$json" | grep -o '"title":"[^"]*"' | head -1 | sed 's/"title":"//;s/"$//')
    state=$(printf '%s' "$json" | grep -o '"state":"[^"]*"' | head -1 | sed 's/"state":"//;s/"$//')
    source_branch=$(printf '%s' "$json" | grep -o '"source_branch":"[^"]*"' | head -1 | sed 's/"source_branch":"//;s/"$//')
    target_branch=$(printf '%s' "$json" | grep -o '"target_branch":"[^"]*"' | head -1 | sed 's/"target_branch":"//;s/"$//')
    printf '# !%s: %s\n\n**State:** %s\n**Branch:** `%s` → `%s`\n\n---\n\n' \
      "$iid" "$title" "$state" "$source_branch" "$target_branch"
  fi
}
