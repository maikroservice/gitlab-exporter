# gitlab-exporter

A pure Bash CLI that exports GitLab project content — wiki pages, issues, merge requests, and source archives — to local files. No runtime dependencies beyond `curl` (required) and `jq` (recommended).

Run it with only a token and a URL and it maps everything your credentials can reach.

---

## Requirements

| Tool | Purpose | Notes |
|------|---------|-------|
| `bash` ≥ 3.2 | Runtime | Ships with macOS / all Linux |
| `curl` | API calls | Required |
| `jq` | JSON parsing | Strongly recommended; grep/sed fallback available |
| `python3` | Test fixture server | Only needed to run tests |
| `bats-core` | Test runner | Only needed to run tests |

---

## Installation

```bash
# Clone
git clone https://github.com/yourorg/gitlab-exporter.git
cd gitlab-exporter

# Optional: install to PATH
make install          # copies to /usr/local/bin/gitlab-exporter

# Or run directly
chmod +x gitlab-exporter.sh
./gitlab-exporter.sh --help
```

---

## Quick start

```bash
# 1. Copy and fill in credentials
cp .env.example .env
$EDITOR .env

# 2. Run — no extra args needed
./gitlab-exporter.sh
```

With only credentials set, the tool runs in **discovery mode**: it checks your token's scopes, crawls every group and project your credentials can reach, and writes two index files:

```
export/
  _scope.md       ← who you are, token scopes, export capabilities
  _discovery.md   ← every accessible group and project in a Markdown table
```

---

## Authentication

Set credentials in `.env`, `.gitlabrc` (project root or `$HOME`), or environment variables. CLI flags override config.

### Personal Access Token (default)

```bash
GITLAB_URL=https://gitlab.example.com
GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
```

Required token scopes:
- `read_api` or `api` — wiki pages, issues, merge requests
- `read_repository` or `api` — source code archives

### Bearer token (OAuth)

```bash
GITLAB_AUTH_TYPE=bearer
GITLAB_TOKEN=<oauth-token>
```

### Basic auth (username + password)

```bash
GITLAB_AUTH_TYPE=basic
GITLAB_USERNAME=alice
GITLAB_PASSWORD=s3cr3t
```

### Session cookie (browser session)

```bash
GITLAB_AUTH_TYPE=cookie
GITLAB_SESSION_COOKIE=<value-of-_gitlab_session-cookie>
```

---

## Usage

```
./gitlab-exporter.sh [OPTIONS]

Scope (optional — omit to run discovery mode):
  --project <url|id|namespace/path>   Export from a single project
  --group   <url|id|namespace/path>   Export from all projects in a group

Content type (default: all three when --project/--group given):
  --wiki                Export wiki pages
  --issues              Export issues
  --merge-requests      Export merge requests
  --source              Export default branch as a .tar.gz archive
  --branches <list>     Export named branches (comma-separated)
  --all-branches        Export all branches

Output:
  --output <dir>        Output directory (default: ./export)
  --force               Overwrite existing files

Options:
  --state open|closed|all   Issue/MR state filter (default: all)
  --list                    Dry run — print what would be exported, write nothing
  --check-scope             Show user identity and token permissions, then exit
  --debug                   Enable verbose debug output
  --help                    Show this help
```

---

## Examples

### Discovery — map what you can access

```bash
./gitlab-exporter.sh
# Writes export/_scope.md and export/_discovery.md
```

### Check token permissions

```bash
./gitlab-exporter.sh --check-scope
# [INFO]  Authenticated as: Alice Smith (@alice)
# [INFO]    Token   : my-exporter-token
# [INFO]    Scopes  : ["api","read_repository"]
# [INFO]    Scope check: OK
```

### Export a single project

```bash
# By numeric ID
./gitlab-exporter.sh --project 12345

# By namespace path
./gitlab-exporter.sh --project mygroup/myproject

# By full URL
./gitlab-exporter.sh --project https://gitlab.example.com/mygroup/myproject
```

### Export only specific content types

```bash
./gitlab-exporter.sh --project mygroup/myproject --wiki --issues
./gitlab-exporter.sh --project mygroup/myproject --merge-requests --state open
```

### Export source code

```bash
# Default branch only
./gitlab-exporter.sh --project mygroup/myproject --source

# Specific branches
./gitlab-exporter.sh --project mygroup/myproject --branches main,staging,release-1.0

# Every branch
./gitlab-exporter.sh --project mygroup/myproject --all-branches
```

Source archives are saved to `export/<namespace>/<project>/source/<branch>.tar.gz`.  
The `.gitlab-ci.yml` pipeline definition is included in each archive automatically.

### Export an entire group

```bash
# By numeric ID
./gitlab-exporter.sh --group 42

# By path
./gitlab-exporter.sh --group myorg

# Issues only, open state
./gitlab-exporter.sh --group myorg --issues --state open
```

### Dry run

```bash
./gitlab-exporter.sh --project mygroup/myproject --list
# Prints what would be exported without writing any files
```

### Custom output directory

```bash
./gitlab-exporter.sh --project mygroup/myproject --output /tmp/gitlab-backup
```

---

## Output structure

```
export/
  _scope.md                          ← credential scope report (discovery mode)
  _discovery.md                      ← accessible groups + projects index (discovery mode)

  <namespace>/<project>/
    wiki/
      <slug>.md                      ← one file per wiki page
    issues/
      <iid>-<title-slug>.md          ← one file per issue
    merge-requests/
      <iid>-<title-slug>.md          ← one file per merge request
    source/
      <branch>.tar.gz                ← source archive per branch
```

### Issue / MR file format

```markdown
# Issue #42: Fix the login bug

**State:** opened | **Author:** alice | **Labels:** bug, priority::high
**Created:** 2024-01-15 | **Updated:** 2024-01-20 | **Milestone:** v1.0
**URL:** https://gitlab.example.com/mygroup/myproject/-/issues/42

---

Description text here...
```

---

## Configuration reference

All options can be set in `.env` or `.gitlabrc` (project root or `$HOME`). Copy `.env.example` to get started.

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_URL` | `https://gitlab.com` | Base URL of your GitLab instance |
| `GITLAB_AUTH_TYPE` | `pat` | Auth scheme: `pat`, `bearer`, `basic`, `cookie` |
| `GITLAB_TOKEN` | — | PAT or OAuth token |
| `GITLAB_USERNAME` | — | Username for basic auth |
| `GITLAB_PASSWORD` | — | Password for basic auth |
| `GITLAB_SESSION_COOKIE` | — | `_gitlab_session` cookie value |
| `GITLAB_PROJECT` | — | Default project (URL, ID, or path) |
| `GITLAB_GROUP` | — | Default group (URL, ID, or path) |
| `GITLAB_OUTPUT_DIR` | `./export` | Output directory |
| `GITLAB_STATE` | `all` | Issue/MR state filter |
| `GITLAB_MAX_RETRIES` | `3` | API retry attempts on transient errors |
| `GITLAB_RETRY_DELAY` | `5` | Base delay (seconds) between retries |
| `GITLAB_PER_PAGE` | `100` | Items per API page |
| `GITLAB_DEBUG` | `0` | Set to `1` for verbose output |

---

## Running tests

```bash
# Install test dependencies (macOS)
make install-deps        # bats-core, jq, shellcheck

# All tests
make test

# Unit tests only (no network, fixture server only)
make test-unit

# Integration tests only
make test-integration

# Lint
make lint
```

Tests use a local Python HTTP fixture server (`tests/helpers/fixture_server.py`) — no real GitLab instance required.

---

## Project layout

```
gitlab-exporter/
├── gitlab-exporter.sh      Main entry point
├── lib/
│   ├── log.sh              Logging helpers
│   ├── deps.sh             curl / jq detection
│   ├── config.sh           Load .env / .gitlabrc
│   ├── auth.sh             Auth headers, scope check
│   ├── api.sh              GitLab REST API v4 calls + pagination
│   ├── output.sh           Path building, atomic file writes
│   ├── convert.sh          Format issues / MRs as Markdown
│   └── discovery.sh        Scope and discovery report generation
├── tests/
│   ├── fixtures/           JSON / binary API response fixtures
│   ├── helpers/            Python fixture server, bash helpers
│   ├── unit/               Unit tests (bats)
│   └── integration/        Integration tests (bats)
├── .env.example            Configuration template
└── Makefile
```
