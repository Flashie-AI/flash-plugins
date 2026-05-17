#!/usr/bin/env bash
# Flash-Vault setup skill — shared library
#
# Single source of truth for the deterministic logic invoked by both:
#   - skills/setup/SKILL.md (production, runs in Claude Code)
#   - test/setup.sh (E2E test suite in the Flash-Vault repo)
#
# Sourced, never executed directly. All functions are prefixed `fv_`.
#
# Design properties worth knowing before reading the code:
#   - Clone never prompts for credentials. GIT_TERMINAL_PROMPT=0 + SSH BatchMode
#     make any auth prompt fail fast instead of stealing stdin.
#   - Clone identity is verified by checking the origin remote URL, not by
#     heuristics on file presence — guards against typo-squatted forks.
#   - Full-setup state requires ALL 4 overlay files to exist; missing any
#     routes to the partial-setup recovery branch instead of "you're done".
#   - identity.md is the LAST file written. Its presence is the atomic flag
#     that means "setup completed cleanly." Mid-flight failure leaves it
#     absent and the next run hits the partial-setup branch.
#   - User-facing paths are quoted via printf %q so vault paths with spaces
#     or shell metacharacters render safely in messages users can copy-paste.
#   - Version compare is implemented in pure bash; sort -V is missing on
#     stock macOS.
#
# All functions assume `set -euo pipefail` is set by the caller.
#
# Cross-shell compat: this lib is bash-style, but Claude Code's Bash tool runs
# commands under the user's login shell (zsh on macOS) and `source` ignores the
# shebang. In zsh, `for x in $var` does NOT word-split unquoted variables by
# default — the entire string is one iteration. That breaks every loop in this
# lib that iterates over space-separated slugs (FV_LINES, FV_SQUADS, etc).
# SH_WORD_SPLIT makes zsh behave like bash/sh for this case. No-op under bash.
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt SH_WORD_SPLIT 2>/dev/null || true
fi

# =============================================================================
# Logging helpers
# =============================================================================

fv_log() {
  echo "$@"
}

fv_error() {
  echo "$@" >&2
}

# =============================================================================
# Portable version compare — sort -V isn't on stock macOS
# =============================================================================
#
# Returns 0 if $1 >= $2, 1 otherwise. Both args are dotted version strings.
# Splits on '.' and compares numerically component-by-component.
fv_compare_version() {
  local have="$1"
  local want="$2"
  local -a h_parts w_parts
  # IFS is scoped to each read invocation — prefer per-call assignment over global.
  IFS=. read -r -a h_parts <<< "$have"
  IFS=. read -r -a w_parts <<< "$want"
  local i
  for ((i = 0; i < ${#w_parts[@]} || i < ${#h_parts[@]}; i++)); do
    local h_part="${h_parts[i]:-0}"
    local w_part="${w_parts[i]:-0}"
    # Strip non-numeric tail (e.g. 0.2.0-rc1 -> 0)
    h_part="${h_part//[!0-9]*/}"
    w_part="${w_part//[!0-9]*/}"
    h_part="${h_part:-0}"
    w_part="${w_part:-0}"
    if ((h_part > w_part)); then return 0; fi
    if ((h_part < w_part)); then return 1; fi
  done
  return 0
}

# =============================================================================
# Pre-flight: detect existing setup state at chosen path
# =============================================================================
#
# Three states:
#   1. Full + verified setup    -> exit 0 with "you already have setup" message
#   2. Partial setup (any file missing or corrupted) -> exit 0 with recovery cmd
#   3. Non-empty unrelated dir  -> exit 1
#   (else: path does not exist or is empty -> return cleanly to continue)
#
# Identity verification: origin remote MUST match Flashie-AI/Flash-Vault.
# Integrity verification: ALL 4 overlay files must exist.
fv_is_flash_vault_clone() {
  local d="$1"
  [ -d "$d/.git" ] || return 1
  local origin
  origin=$(git -C "$d" remote get-url origin 2>/dev/null || echo "")
  case "$origin" in
    *Flashie-AI/Flash-Vault*|*flashie-ai/flash-vault*) return 0 ;;
    *) return 1 ;;
  esac
}

fv_overlay_complete() {
  local d="$1"
  local f
  for f in personal/identity.md personal/tasks.md CLAUDE.md drafts/.gitkeep; do
    [ -f "$d/$f" ] || return 1
  done
  return 0
}

fv_check_existing_path() {
  local vault="$1"
  local qvault
  qvault=$(printf %q "$vault")

  if fv_is_flash_vault_clone "$vault"; then
    if fv_overlay_complete "$vault"; then
      # State 1: full + verified setup
      local date
      date=$(grep '^updated:' "$vault/personal/identity.md" 2>/dev/null | head -1 | sed 's/^updated:[[:space:]]*//' || echo "unknown")
      fv_log "You already have a Flash Vault set up at $qvault (last updated $date)."
      fv_log ""
      fv_log "Setup runs once per vault. From here you can:"
      fv_log "  1. Open Claude Code at $qvault and start working."
      fv_log "  2. Edit your personal files directly — they live in $qvault/personal/ and $qvault/CLAUDE.md."
      fv_log "  3. Reset and re-run setup:"
      fv_log "       cd $qvault && rm -rf personal/ drafts/ CLAUDE.md && git -C $qvault update-index --no-skip-worktree CLAUDE.md 2>/dev/null && git -C $qvault checkout -- CLAUDE.md"
      fv_log "  4. Choose a different folder next time you run setup."
      exit 0
    else
      # State 2: partial / corrupted setup — at least one overlay file missing.
      fv_log "$qvault looks like a Flash Vault clone, but your personal setup didn't finish — some files are missing."
      fv_log ""
      fv_log "To reset and try again:"
      fv_log "  cd $qvault && rm -rf personal/ drafts/ CLAUDE.md && git update-index --no-skip-worktree CLAUDE.md 2>/dev/null && git checkout -- CLAUDE.md"
      fv_log ""
      fv_log "Then re-run setup. Your other local edits in $qvault are preserved."
      exit 0
    fi
  fi

  # State 3: not a Flash-Vault clone. Don't print Flash-specific recovery for arbitrary dirs.
  if [ -d "$vault" ] && [ -n "$(ls -A "$vault" 2>/dev/null)" ]; then
    fv_error "Directory $qvault exists and is not empty, and its origin remote does not point to Flashie-AI/Flash-Vault."
    fv_error "Refusing to clone into an unrelated directory. Choose a different path or empty $qvault first."
    exit 1
  fi
}

# =============================================================================
# Clone Flashie-AI/Flash-Vault into the chosen path
# =============================================================================
#
# GIT_TERMINAL_PROMPT=0 prevents HTTPS credential prompts from stealing stdin.
# GIT_SSH_COMMAND BatchMode=yes prevents SSH passphrase / host-key prompts.
# Failures are fast and explicit, with concrete remediation commands.
#
# Override via FV_CLONE_URL env var for tests (point at a local file:// repo).
fv_clone() {
  local vault="$1"
  local qvault
  qvault=$(printf %q "$vault")

  mkdir -p "$(dirname "$vault")"

  fv_log "Cloning Flashie-AI/Flash-Vault to $qvault (this may take 10-60 seconds)..."

  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

  local ssh_url="${FV_CLONE_URL:-git@github.com:Flashie-AI/Flash-Vault.git}"
  local https_url="https://github.com/Flashie-AI/Flash-Vault.git"

  if git clone "$ssh_url" "$vault" 2>/dev/null; then
    fv_log "Cloned via SSH."
    return 0
  fi

  # Only try HTTPS fallback if we're using the real origin (not a test override)
  if [ -z "${FV_CLONE_URL:-}" ] && git clone "$https_url" "$vault" 2>/dev/null; then
    fv_log "Cloned via HTTPS."
    return 0
  fi

  fv_error "Clone failed. Most likely causes:"
  fv_error ""
  fv_error "  1. SSH not set up for this machine."
  fv_error "     Test: ssh -T git@github.com (should print 'Hi <username>!')"
  fv_error "     Fix:  https://docs.github.com/en/authentication/connecting-to-github-with-ssh"
  fv_error ""
  fv_error "  2. HTTPS credentials needed (for first-time HTTPS clone)."
  fv_error "     Run:  gh auth login   (or set up a credential helper)"
  fv_error ""
  fv_error "  3. You're not a member of the Flashie-AI GitHub org (private repo)."
  fv_error "     Fix:  ask a teammate to add you, then re-run."
  fv_error ""

  # Clean up empty stub directory if git left one
  [ -d "$vault" ] && [ ! -d "$vault/.git" ] && rmdir "$vault" 2>/dev/null || true
  exit 1
}

# =============================================================================
# Verify clone identity + structure
# =============================================================================
#
# Asserts the clone has Flashie-AI/Flash-Vault origin AND has the
# templates/personal/ contents the skill needs. Cleanup on failure.
# Caller must `cd "$vault"` before invoking.
fv_verify_clone() {
  local vault
  vault=$(pwd)
  local qvault
  qvault=$(printf %q "$vault")

  local origin
  origin=$(git remote get-url origin 2>/dev/null || echo "")
  case "$origin" in
    *Flashie-AI/Flash-Vault*|*flashie-ai/flash-vault*) ;;
    *)
      fv_error "Cloned repo origin ($origin) does not point to Flashie-AI/Flash-Vault."
      fv_error "This shouldn't happen with a fresh clone. Cleaning up."
      cd /
      rm -rf "$vault"
      exit 1
      ;;
  esac

  if [ ! -d templates/personal ] \
     || [ ! -f templates/personal/identity-template.md ] \
     || [ ! -f templates/personal/claude-template.md ] \
     || [ ! -f templates/tasks-template.md ]; then
    fv_error "Clone is missing templates/personal/ contents. The setup skill requires Flash-Vault v0.2.0+."
    fv_error "Your clone may be checked out at an older tag, or HEAD is in a transient state."
    fv_error "Run:  cd $qvault && git checkout main && git pull && cd .. && re-run setup"
    fv_error "(Cleaning up incomplete clone for now.)"
    cd /
    rm -rf "$vault"
    exit 1
  fi

  fv_log "Clone verified — Flash-Vault v$(cat VERSION 2>/dev/null || echo 'unknown')."
}

# =============================================================================
# Canonical product-line list (read from the cloned repo, not hardcoded)
# =============================================================================
#
# Source of truth: filenames in product/lines/*.md. Each filename's basename
# (without .md) is a canonical line slug. Empty list = repo has no lines seeded
# yet, in which case the skill must surface this and refuse to default.
#
# Output: one slug per line, sorted, deduplicated.
fv_list_canonical_lines() {
  if [ ! -d product/lines ]; then
    return 0
  fi
  local f base
  for f in product/lines/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$base" = "lines" ] && continue   # skip MOC (convention: MOC basename = parent dir name)
    printf '%s\n' "$base"
  done | sort -u
}

# Validate a space-separated list of line slugs against the canonical list.
# Args: $1 = space-separated user slugs.
# Returns 0 if every slug is canonical (and the list is non-empty), 1 otherwise.
# Prints invalid slugs to stderr.
fv_validate_lines() {
  local user_lines="$1"
  if [ -z "$user_lines" ]; then
    fv_error "No product lines provided. The setup skill requires at least one."
    return 1
  fi

  local canonical
  canonical=$(fv_list_canonical_lines)
  if [ -z "$canonical" ]; then
    fv_error "No product lines defined in the vault yet (product/lines/ is empty)."
    fv_error "A vault maintainer must seed product/lines/<slug>.md before contributors can run setup."
    return 1
  fi

  local invalid="" slug
  for slug in $user_lines; do
    if ! printf '%s\n' "$canonical" | grep -qx "$slug"; then
      invalid+="$slug "
    fi
  done

  if [ -n "$invalid" ]; then
    fv_error "Invalid product line slug(s): $invalid"
    fv_error "Valid slugs (from product/lines/):"
    printf '%s\n' "$canonical" | sed 's/^/  /' >&2
    return 1
  fi

  return 0
}

# =============================================================================
# Canonical squads list + validation + builders (mirror of lines)
# =============================================================================

# Canonical squads list. Same MOC exclusion as fv_list_canonical_lines.
fv_list_canonical_squads() {
  if [ ! -d product/squads ]; then
    return 0
  fi
  local f base
  for f in product/squads/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$base" = "squads" ] && continue   # skip MOC (convention: MOC basename = parent dir name)
    printf '%s\n' "$base"
  done | sort -u
}

# Validate a space-separated list of squad slugs against the canonical list.
# Returns 0 if every slug is canonical (and the list is non-empty), 1 otherwise.
# Empty input is valid — contributors may legitimately not be in any squad.
fv_validate_squads() {
  local user_squads="$1"
  if [ -z "$user_squads" ]; then
    return 0
  fi

  local canonical
  canonical=$(fv_list_canonical_squads)
  if [ -z "$canonical" ]; then
    fv_error "No squads defined in the vault yet (product/squads/ is empty)."
    fv_error "Either skip squad entry, or have a maintainer seed product/squads/<slug>.md first."
    return 1
  fi

  local invalid="" slug
  for slug in $user_squads; do
    if ! printf '%s\n' "$canonical" | grep -qx "$slug"; then
      invalid+="$slug "
    fi
  done

  if [ -n "$invalid" ]; then
    fv_error "Invalid squad slug(s): $invalid"
    fv_error "Valid slugs (from product/squads/):"
    printf '%s\n' "$canonical" | sed 's/^/  /' >&2
    return 1
  fi

  return 0
}

# Lowercase + non-alphanumerics → "-" + trim leading/trailing dashes.
# Used for deriving a person slug from FV_NAME so identity.md can link to a
# canonical `company/people/<slug>.md` file. Collisions (two contributors with
# the same slug) are out of scope for v1 — the user can rename manually.
fv_slugify() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# Render a starter profile `company/people/<slug>.md` from the person template if no file
# at that path already exists. The file is untracked-by-default in the user's
# clone (it lives under the tracked `company/people/` directory, so it shows up
# as untracked until the user ships it via /push-to-flash-vault).
#
# Args:
#   $1 = person slug (e.g. "tarek-rajab")
#   $2 = display name (e.g. "Tarek Rajab")
#   $3 = role
#   $4 = team slug (defaults to "product" when caller passes empty)
#   $5 = squads (space-separated; may be empty)
fv_create_person_if_missing() {
  local slug="$1"
  local name="$2"
  local role="$3"
  local team="${4:-product}"
  local squads="$5"

  local dest="company/people/$slug.md"
  [ -f "$dest" ] && return 0
  [ -f templates/person-template.md ] || return 0

  local squads_yaml
  if [ -n "$squads" ]; then
    squads_yaml=$(echo "$squads" | xargs | sed 's/ /, /g')
  else
    squads_yaml=""
  fi

  local today
  today=$(date +%Y-%m-%d)

  mkdir -p company/people

  # Render manually rather than via fv_render_template because the person
  # template ships with a `_schema:` block we must strip and slug-shaped
  # frontmatter values that aren't `{{KEY}}` placeholders.
  awk -v name="$name" -v role="$role" -v team="$team" -v squads="$squads_yaml" -v today="$today" '
    BEGIN { in_schema = 0 }
    /^_schema:[[:space:]]*$/ { in_schema = 1; next }
    in_schema && /^[^[:space:]]/ { in_schema = 0 }
    in_schema { next }
    /^role:[[:space:]]*<role title>/    { print "role: " role; next }
    /^team:[[:space:]]*<functional team slug>/ { print "team: " team; next }
    /^# squad:/                          { next }
    /^squad:[[:space:]]*\[<squad slug>\]/ {
      if (squads != "") { print "squad: [" squads "]" } else { print "squad: []" }
      next
    }
    /^updated:[[:space:]]*YYYY-MM-DD/    { print "updated: " today; next }
    /^# <Full name>/                     { print "# " name; next }
    /^One sentence:/                     { print "_TBD — describe role, squad, and anchor in one line. Drop a draft and run /process to flesh out the rest._"; next }
    { print }
  ' templates/person-template.md > "$dest"
}

# For each project slug the user mentioned during setup, drop a draft note into
# `drafts/project-<slug>.md` IF no real project note exists yet AND no draft
# with the same name is already pending. The user runs `/process` later to
# turn these into proper `product/projects/<slug>.md` notes.
#
# We don't auto-create real project notes from a passing setup mention because
# the project template has many required fields (status, pm, squad, started,
# target_launch) that we can't fill from a single sentence.
#
# Args: $1 = space-separated project slugs
fv_drop_missing_project_drafts() {
  local slugs="$1"
  [ -z "$slugs" ] && return 0
  mkdir -p drafts
  local slug
  for slug in $slugs; do
    [ -z "$slug" ] && continue
    if [ ! -f "product/projects/$slug.md" ] && [ ! -f "drafts/project-$slug.md" ]; then
      cat > "drafts/project-$slug.md" <<EOF
# $slug

Mentioned during setup. Run \`/process drafts/project-$slug.md\` to file this as a proper project note under \`product/projects/\`.
EOF
    fi
  done
}

# Inline-formatted squad links (comma-separated wiki links).
# Args: $1 = space-separated slug list
# Output: e.g. "[[product/squads/billevers]], [[product/squads/mercury]]"
fv_build_squads_inline() {
  local squads="$1"
  local out=""
  local first=1
  local slug
  for slug in $squads; do
    if [ $first -eq 1 ]; then first=0; else out+=", "; fi
    out+="[[product/squads/${slug}]]"
  done
  printf '%s' "$out"
}

# =============================================================================
# Render a template with placeholder substitution
# =============================================================================
#
# Args:
#   $1 = source template path (relative to repo root)
#   $2 = destination path (relative to repo root)
#   Then key=value pairs:
#     NAME, ROLE, LINES, LINES_BULLETED, LINES_LOAD_BLOCK,
#     PRIMARY_LINE, FOCUS, PERSONALITY, TODAY, CURRENT_GOALS_STEP
#
# Substitutes {{KEY}} -> value via sed. Values are escaped for sed: backslash,
# slash, and ampersand. Multiline values use \n in the input, which sed
# substitutes literally — caller is responsible for using a body that doesn't
# need multi-line substitution within a single placeholder (lists go in
# bulleted format with literal newlines done at the bash level).
fv_render_template() {
  local src="$1"
  local dst="$2"
  shift 2

  local content
  content=$(cat "$src")

  while [ $# -gt 0 ]; do
    local key="$1"
    local value="$2"
    shift 2
    # Use awk for substitution since it handles arbitrary characters cleanly,
    # including multiline values, slashes, ampersands, and backslashes.
    content=$(awk -v key="{{$key}}" -v val="$value" '
      {
        s = $0
        n = index(s, key)
        while (n > 0) {
          s = substr(s, 1, n - 1) val substr(s, n + length(key))
          n = index(s, key)
        }
        print s
      }
    ' <<< "$content")
  done

  # Ensure parent directory exists for nested destinations
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" > "$dst"
}

# =============================================================================
# Build helper: LINES_BULLETED and LINES_LOAD_BLOCK from a space-separated list
# =============================================================================
fv_build_lines_bulleted() {
  local lines="$1"
  local out=""
  local first=1
  local slug
  for slug in $lines; do
    if [ $first -eq 1 ]; then
      first=0
    else
      out+=$'\n'
    fi
    out+="- [[product/lines/${slug}]]"
  done
  printf '%s' "$out"
}

# Inline-formatted line links (comma-separated wiki links).
# Args: $1 = space-separated slug list
# Output: e.g. "[[product/lines/bill-payments]], [[product/lines/financial-wellness]]"
fv_build_lines_inline() {
  local lines="$1"
  local out=""
  local first=1
  local slug
  for slug in $lines; do
    if [ $first -eq 1 ]; then first=0; else out+=", "; fi
    out+="[[product/lines/${slug}]]"
  done
  printf '%s' "$out"
}

# Build the "What I'm focused on now" body from FV_FOCUS prose.
# v1: just put the focus prose as a single bullet. Future: parse out wiki
# links from the prose and structure them as proper bullets.
# Args: $1 = focus prose
fv_build_focus_links() {
  local focus="$1"
  if [ -z "$focus" ]; then
    printf '%s' "(nothing yet — edit this section as priorities form)"
  else
    printf -- '- %s' "$focus"
  fi
}

# Build the LINES_LOAD_BLOCK (numbered list starting at $2, one entry per line).
# Returns the next number to use after the block (for CURRENT_GOALS_STEP).
fv_build_lines_load_block() {
  local lines="$1"
  local start_num="$2"
  local out=""
  local n=$start_num
  local first=1
  local slug
  for slug in $lines; do
    if [ $first -eq 1 ]; then
      first=0
    else
      out+=$'\n'
    fi
    out+=$(printf '%d. `product/lines/%s.md`' "$n" "$slug")
    n=$((n + 1))
  done
  printf '%s' "$out"
}

# Compute the step number for CURRENT_GOALS_STEP given line count + start (= 6).
fv_current_goals_step_num() {
  local lines="$1"
  local count=0
  local slug
  for slug in $lines; do
    count=$((count + 1))
  done
  echo $((6 + count))
}

# =============================================================================
# Generate the personal overlay (atomic order)
# =============================================================================
#
# Generation order: drafts/.gitkeep -> tasks.md -> CLAUDE.md -> identity.md
# (LAST). identity.md is the atomic flag — its presence means setup completed
# cleanly. Mid-generation failure leaves identity.md absent, and re-run hits
# the partial-setup recovery branch.
#
# CLAUDE.md handling: a fresh clone has the dev-mode CLAUDE.md committed to
# HEAD. The setup skill replaces it with the user-mode brief, marks it
# skip-worktree so the local copy is not tracked or pushed and is not
# overwritten by ordinary `git pull`, and adds it to the clone's local
# .git/info/exclude so it's also gitignored locally (defense in depth — the
# project-level .gitignore can't ignore the file because it's tracked).
# Plain `git clone` (no setup skill) leaves the dev brief in place — that's
# how dev mode is preserved.
#
# Args via env vars (set by caller):
#   FV_NAME, FV_ROLE, FV_LINES (space-sep), FV_PRIMARY_LINE,
#   FV_FOCUS, FV_PERSONALITY
#   FV_WORK_STYLE (optional; how the user likes to work — fills identity.md
#                  "How I think about work")
#   FV_TEAM (optional; defaults to "product")
#   FV_PERSON_SLUG (optional; overrides the name-derived person slug so identity.md
#                  links to a confirmed existing profile)
#   FV_SQUADS (optional, space-separated squad slugs)
#   FV_PROJECTS_MENTIONED (optional, space-separated project slugs the user
#                  named during setup; missing ones get draft notes in drafts/)
fv_generate() {
  local today
  today=$(date +%Y-%m-%d)

  : "${FV_SQUADS:=}"
  : "${FV_WORK_STYLE:=}"
  : "${FV_PROJECTS_MENTIONED:=}"

  local lines_bulleted_inline
  lines_bulleted_inline=$(fv_build_lines_inline "$FV_LINES")

  local squads_bulleted_inline squads_yaml
  # Caller is responsible for validating FV_SQUADS via fv_validate_squads before
  # invoking fv_generate; invalid slugs produce broken wiki links to nonexistent files.
  if [ -n "$FV_SQUADS" ]; then
    squads_bulleted_inline=$(fv_build_squads_inline "$FV_SQUADS")
    squads_yaml=$(echo "$FV_SQUADS" | xargs | sed 's/ /, /g')
  else
    squads_bulleted_inline="(none yet)"
    squads_yaml=""
  fi

  local lines_yaml
  lines_yaml=$(echo "$FV_LINES" | xargs | sed 's/ /, /g')

  local focus_links
  focus_links=$(fv_build_focus_links "$FV_FOCUS")

  # FV_PERSON_SLUG (optional) — set by the skill when the contributor confirmed an
  # existing near-match profile; links identity.md to that file instead of a new one.
  local person_slug
  person_slug="${FV_PERSON_SLUG:-$(fv_slugify "$FV_NAME")}"

  local work_style_rendered
  if [ -n "$FV_WORK_STYLE" ]; then
    work_style_rendered="$FV_WORK_STYLE"
  else
    work_style_rendered="(Edit this — describe your work style: pace, decision-making, where you want the AI to push back, what you want surfaced.)"
  fi

  # 1. Directory scaffold
  mkdir -p personal drafts
  touch drafts/.gitkeep

  # 1a. Starter profile in company/people/ if missing — gives identity.md a valid
  # `[[company/people/<slug>]]` link target. File is untracked locally; user
  # ships it via /push-to-flash-vault when ready.
  fv_create_person_if_missing "$person_slug" "$FV_NAME" "$FV_ROLE" "${FV_TEAM:-product}" "$FV_SQUADS"

  # 1b. Drop draft notes for any projects the user mentioned that don't yet
  # exist in product/projects/. The user runs /process later to file each one.
  fv_drop_missing_project_drafts "$FV_PROJECTS_MENTIONED"

  # 2. tasks.md (with auto-managed markers section pre-populated empty)
  fv_render_template templates/tasks-template.md personal/tasks.md \
    TODAY "$today"
  # The template ships YYYY-MM-DD as a literal placeholder; replace with today
  sed -i.bak "s/YYYY-MM-DD/$today/g" personal/tasks.md && rm personal/tasks.md.bak
  # Strip the _schema block (template ships with it; runtime files don't have it).
  # The block is a top-level YAML key `_schema:` followed by indented sub-keys
  # (e.g. `  entity_type: tasks`, `  required: [...]`). Strip only that
  # contiguous block: end the strip when we hit another top-level YAML key
  # (line starting with a non-space char) or the closing `---` of the
  # frontmatter.
  awk '
    BEGIN { in_schema = 0 }
    /^_schema:[[:space:]]*$/ { in_schema = 1; next }
    in_schema && /^[^[:space:]]/ { in_schema = 0 }
    in_schema { next }
    { print }
  ' personal/tasks.md > personal/tasks.md.tmp && mv personal/tasks.md.tmp personal/tasks.md

  # 3. CLAUDE.md (overwrite committed dev brief with user brief, mark skip-worktree)
  fv_render_template templates/personal/claude-template.md CLAUDE.md \
    NAME "$FV_NAME" \
    ROLE "$FV_ROLE" \
    PRIMARY_LINE "$FV_PRIMARY_LINE"

  # Mark CLAUDE.md skip-worktree so the user's local brief is not tracked,
  # not pushed, and not overwritten by ordinary `git pull`. Tolerated to fail
  # in test environments that source the lib outside a real git repo.
  git update-index --skip-worktree CLAUDE.md 2>/dev/null || true

  # Also gitignore CLAUDE.md locally via .git/info/exclude. Project .gitignore
  # can't ignore tracked files, but .git/info/exclude is per-clone and works
  # if the file is ever untracked. Append idempotently.
  if [ -f .git/info/exclude ] && ! grep -qxF '/CLAUDE.md' .git/info/exclude 2>/dev/null; then
    printf '/CLAUDE.md\n' >> .git/info/exclude
  fi

  # 4. identity.md (LAST — atomic flag for "setup completed cleanly")
  fv_render_template templates/personal/identity-template.md personal/identity.md \
    NAME "$FV_NAME" \
    ROLE "$FV_ROLE" \
    TEAM "${FV_TEAM:-product}" \
    PERSON_SLUG "$person_slug" \
    LINES_BULLETED_INLINE "$lines_bulleted_inline" \
    SQUADS_BULLETED_INLINE "$squads_bulleted_inline" \
    LINES_YAML "$lines_yaml" \
    SQUADS_YAML "$squads_yaml" \
    FOCUS_LINKS "$focus_links" \
    PERSONALITY "$FV_PERSONALITY" \
    WORK_STYLE "$work_style_rendered" \
    LINES "$lines_yaml" \
    TODAY "$today"

  # Integrity verification: all 4 expected files exist
  local missing=()
  local f
  for f in personal/identity.md personal/tasks.md CLAUDE.md drafts/.gitkeep; do
    [ -f "$f" ] || missing+=("$f")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    fv_error "fv_generate: missing files after render: ${missing[*]}"
    return 1
  fi

  fv_log "All 4 files generated."
}

# =============================================================================
# Success message
# =============================================================================
fv_success() {
  local vault="$1"
  local qvault
  qvault=$(printf %q "$vault")
  local lines_csv="$2"
  local primary_line="$3"
  local role="$4"

  fv_log ""
  fv_log "Setup complete. Your vault is at $qvault."
  fv_log ""
  fv_log "  - personal/identity.md, tasks.md  — who you are and what's on your plate"
  fv_log "  - CLAUDE.md                       — what the AI reads at session start"
  fv_log "  - drafts/                         — scratch folder for half-formed notes"
  fv_log ""
  fv_log "Everything in personal/, drafts/, and CLAUDE.md stays on your machine — it isn't shared with the team."
  fv_log ""
  fv_log "Next: open Claude Code at $qvault (run: cd $qvault && claude, or open the folder"
  fv_log "in your IDE if it has the integration). The AI will load your Flash context"
  fv_log "calibrated for $role on $lines_csv."
  fv_log ""
  fv_log "Try: ask 'what's the current state of [[product/lines/$primary_line]]?' — the AI"
  fv_log "should ground its answer in real vault content and cite the files it read."
  fv_log ""
  fv_log "If anything looks wrong, edit the files in personal/ directly."
}
