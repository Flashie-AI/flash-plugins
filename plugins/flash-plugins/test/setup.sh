#!/usr/bin/env bash
# Flash-Vault setup skill — E2E test suite
#
# Sources the production .claude/skills/setup/lib/setup-core.sh directly. No
# parallel driver implementation — drift impossible by construction.
#
# v1: local-only test. CI cannot clone the private source repo without a
# deploy token; that's a follow-up PR. The fixture at test/fixtures/source-repo/
# is converted into a local bare repo and used as fake origin via FV_CLONE_URL.
#
# Run: ./test/setup.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/.claude/lib/setup-core.sh"

# Sanity: lib must exist (build/install drift catch).
if [ ! -f "$LIB" ]; then
  echo "FATAL: $LIB not found. Did Task 3 commit?"
  exit 1
fi

# shellcheck source=.claude/skills/setup/lib/setup-core.sh
source "$LIB"

# =============================================================================
# Test infrastructure
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
FAILED_SCENARIOS=()

# Per-scenario tempdir (creates isolated playground for each test)
mk_tempdir() {
  local d
  d=$(mktemp -d 2>/dev/null || mktemp -d -t fv-test)
  echo "$d"
}

# Build a bare git repo from the canonical fixture, return its path.
# This is the fake "origin" that fv_clone clones from.
mk_fake_origin() {
  local origin_dir="$1"
  local fixture="$REPO_ROOT/test/fixtures/source-repo"

  # Stage area that becomes the working repo
  local work
  work=$(mktemp -d)
  cp -R "$fixture"/* "$work/"
  cp -R "$fixture"/.[!.]* "$work/" 2>/dev/null || true

  (
    cd "$work"
    git init -q
    git checkout -q -b main 2>/dev/null || git branch -m main 2>/dev/null || true
    # Configure local identity so commit doesn't fail in CI-like envs
    git config user.email "test@flash.test"
    git config user.name "Test"
    git add -A
    git commit -q -m "fixture initial commit"
  )

  # Convert the working repo to a bare clone at $origin_dir; this is what
  # the test scenarios will clone from. Path is namespaced so verify_clone's
  # origin remote check passes (...Flashie-AI/Flash-Vault... pattern).
  local bare
  bare="$origin_dir/Flashie-AI/Flash-Vault"
  mkdir -p "$origin_dir/Flashie-AI"
  git clone -q --bare "$work" "$bare"

  rm -rf "$work"
  echo "$bare"
}

# Run a scenario function with a fresh tempdir + fake origin in scope.
run_scenario() {
  local name="$1"
  local fn="$2"

  local tmp
  tmp=$(mk_tempdir)
  local origin_root="$tmp/origin-root"
  local fake_origin
  fake_origin=$(mk_fake_origin "$origin_root")
  local vault="$tmp/vault"

  # Each scenario inherits these env vars
  export FV_CLONE_URL="file://$fake_origin"
  export FAKE_ORIGIN_ROOT="$origin_root"
  export TMP="$tmp"
  export VAULT="$vault"

  echo "=== $name ==="
  if (
    set +e
    "$fn"
  ); then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: $name"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_SCENARIOS+=("$name")
    echo "FAIL: $name"
  fi
  echo ""

  # Clean up
  rm -rf "$tmp"
  unset FV_CLONE_URL FAKE_ORIGIN_ROOT TMP VAULT
}

assert_file_exists() {
  if [ ! -f "$1" ]; then
    echo "  ASSERT FAIL: file missing: $1"
    return 1
  fi
}

assert_file_absent() {
  if [ -e "$1" ]; then
    echo "  ASSERT FAIL: file should not exist: $1"
    return 1
  fi
}

assert_grep() {
  local pattern="$1"
  local file="$2"
  if ! grep -q -- "$pattern" "$file" 2>/dev/null; then
    echo "  ASSERT FAIL: '$pattern' not found in $file"
    return 1
  fi
}

assert_no_grep() {
  local pattern="$1"
  local file="$2"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    echo "  ASSERT FAIL: '$pattern' should NOT appear in $file"
    return 1
  fi
}

# Drive the deterministic flow end-to-end with provided pre-fills.
# Used by scenarios that test the happy path (1, 2, 10, 11, 12).
drive_full_flow() {
  fv_check_existing_path "$VAULT"
  fv_clone "$VAULT"
  cd "$VAULT" || return 1
  fv_verify_clone

  local email="${1:-}"
  fv_autodetect "$email" || true

  # Prefer auto-detect values, fall back to test args
  export FV_NAME="${FV_PREFILL_NAME:-${2:-Layla}}"
  export FV_ROLE="${FV_PREFILL_ROLE:-${3:-Designer}}"
  export FV_LINES="${FV_PREFILL_LINES:-${4:-financial-wellness}}"
  export FV_PRIMARY_LINE
  FV_PRIMARY_LINE=$(echo "$FV_LINES" | awk '{print $1}')
  export FV_FOCUS="${5:-Auto-invest roundup redesign and empty-state consistency}"
  export FV_PERSONALITY="${6:-Direct, terse, no preamble.}"

  fv_generate
}

# =============================================================================
# Scenarios
# =============================================================================

# Scenario 1: Standard flow (no auto-detect match)
test_01_standard_flow() {
  drive_full_flow "noone@nowhere.test" || return 1

  assert_file_exists "$VAULT/personal/identity.md" || return 1
  assert_file_exists "$VAULT/personal/tasks.md" || return 1
  assert_file_exists "$VAULT/CLAUDE.md" || return 1
  assert_file_exists "$VAULT/drafts/.gitkeep" || return 1

  # Methodology + goals files are gone (collapsed into identity.md)
  [ ! -f "$VAULT/personal/methodology.md" ] || { echo "  FAIL: methodology.md should not exist"; return 1; }
  [ ! -f "$VAULT/personal/goals.md" ] || { echo "  FAIL: goals.md should not exist"; return 1; }

  assert_grep "Layla" "$VAULT/personal/identity.md" || return 1
  assert_grep "Designer" "$VAULT/personal/identity.md" || return 1
  assert_grep "financial-wellness" "$VAULT/personal/identity.md" || return 1
  # What I'm focused on now (was goals.md content) is now in identity.md
  assert_grep "Auto-invest" "$VAULT/personal/identity.md" || return 1
  assert_grep "Layla" "$VAULT/CLAUDE.md" || return 1
  assert_grep "Daily commands" "$VAULT/CLAUDE.md" || return 1   # new section
}

# Scenario 2: Auto-detect full match
test_02_auto_detect_full() {
  fv_check_existing_path "$VAULT"
  fv_clone "$VAULT"
  cd "$VAULT" || return 1
  fv_verify_clone

  if ! fv_autodetect "layla@flash.test"; then
    echo "  FAIL: auto-detect should have succeeded for layla@flash.test"
    return 1
  fi

  [ "$FV_PREFILL_NAME" = "Layla Test" ] || { echo "  FAIL: name=$FV_PREFILL_NAME"; return 1; }
  [ "$FV_PREFILL_ROLE" = "Senior Designer" ] || { echo "  FAIL: role=$FV_PREFILL_ROLE"; return 1; }
  [ "$FV_PREFILL_SQUAD" = "financial-wellness-squad" ] || { echo "  FAIL: squad=$FV_PREFILL_SQUAD"; return 1; }
  [ "$FV_PREFILL_LINES" = "financial-wellness" ] || { echo "  FAIL: lines=$FV_PREFILL_LINES"; return 1; }
}

# Scenario 3: Pre-clone refuse — full setup
test_03_refuse_full_setup() {
  # Pre-create a clone with all 4 overlay files
  mkdir -p "$VAULT/personal" "$VAULT/drafts" "$VAULT/.git"
  cd "$VAULT" || return 1
  git init -q
  git remote add origin "git@github.com:Flashie-AI/Flash-Vault.git" 2>/dev/null || true
  echo "updated: 2026-04-15" > "$VAULT/personal/identity.md"
  echo "x" > "$VAULT/personal/tasks.md"
  echo "x" > "$VAULT/CLAUDE.md"
  touch "$VAULT/drafts/.gitkeep"
  cd / || true

  local output
  output=$(fv_check_existing_path "$VAULT" 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 0 ] || { echo "  FAIL: expected exit 0, got $exit_code"; return 1; }
  echo "$output" | grep -q "already have a Flash Vault setup" || { echo "  FAIL: missing 'already have setup' message"; return 1; }
}

# Scenario 4: Pre-clone refuse — partial setup (single missing overlay file)
test_04_refuse_partial_setup_missing_one_file() {
  # Pre-create a verified Flash-Vault clone with CLAUDE.md MISSING (one file
  # short of complete) and verify the partial-setup branch fires.
  mkdir -p "$VAULT/personal" "$VAULT/drafts"
  cd "$VAULT" || return 1
  git init -q
  git remote add origin "git@github.com:Flashie-AI/Flash-Vault.git" 2>/dev/null || true
  echo "updated: 2026-04-15" > "$VAULT/personal/identity.md"
  echo "x" > "$VAULT/personal/tasks.md"
  # Deliberately NOT creating CLAUDE.md — should still detect partial
  touch "$VAULT/drafts/.gitkeep"
  cd / || true

  local output
  output=$(fv_check_existing_path "$VAULT" 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 0 ] || { echo "  FAIL: expected exit 0, got $exit_code"; return 1; }
  echo "$output" | grep -q "incomplete or corrupted" || { echo "  FAIL: missing partial-setup message"; return 1; }
  echo "$output" | grep -q "rm -rf personal/ drafts/ CLAUDE.md" || { echo "  FAIL: missing recovery cmd"; return 1; }
}

# Scenario 5: Pre-clone refuse — non-empty unrelated dir
test_05_refuse_unrelated() {
  mkdir -p "$VAULT"
  echo "random" > "$VAULT/some-file.txt"

  local output
  output=$(fv_check_existing_path "$VAULT" 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 1 ] || { echo "  FAIL: expected exit 1, got $exit_code"; return 1; }
  echo "$output" | grep -q "exists and is not empty" || { echo "  FAIL: missing unrelated-dir message"; return 1; }
}

# Scenario 6: Sanity-check failure cleanup (origin remote mismatch)
test_06_clone_sanity_cleanup() {
  # Create a fake origin that doesn't have Flashie-AI/Flash-Vault in the path
  local bad_origin="$TMP/bad-origin"
  mkdir -p "$bad_origin"
  ( cd "$bad_origin" && git init -q --bare )
  local seed
  seed=$(mktemp -d)
  ( cd "$seed" && git init -q && echo "0.2.0" > VERSION && echo "Flash Vault" > README.md && git config user.email t@t.t && git config user.name t && git add -A && git commit -q -m init )
  ( cd "$seed" && git remote add origin "$bad_origin" && git push -q origin main 2>/dev/null )
  rm -rf "$seed"

  export FV_CLONE_URL="file://$bad_origin"
  fv_clone "$VAULT" 2>/dev/null || true
  cd "$VAULT" 2>/dev/null || true

  local output
  output=$(fv_verify_clone 2>&1) && true
  local exit_code=$?

  # fv_verify_clone exits 1 on mismatch and rm -rf's $VAULT
  [ $exit_code -eq 1 ] || { echo "  FAIL: expected exit 1, got $exit_code"; return 1; }
  echo "$output" | grep -q "does not point to Flashie-AI/Flash-Vault" || { echo "  FAIL: missing identity-mismatch message"; return 1; }
  [ ! -d "$VAULT" ] || { echo "  FAIL: vault dir not cleaned up"; return 1; }
}

# Scenario 7: Templates missing in clone
test_07_templates_missing() {
  # Create a fake origin that has the right URL pattern but missing templates/personal/
  local stripped_root="$TMP/stripped-root"
  local stripped_bare="$stripped_root/Flashie-AI/Flash-Vault"
  mkdir -p "$stripped_root/Flashie-AI"
  local seed
  seed=$(mktemp -d)
  (
    cd "$seed"
    git init -q
    git config user.email t@t.t && git config user.name t
    echo "0.2.0" > VERSION
    echo "Flash Vault" > README.md
    git checkout -q -b main 2>/dev/null || true
    git add -A
    git commit -q -m init
  )
  git clone -q --bare "$seed" "$stripped_bare"
  rm -rf "$seed"

  export FV_CLONE_URL="file://$stripped_bare"
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" 2>/dev/null || return 1

  local output
  output=$(fv_verify_clone 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 1 ] || { echo "  FAIL: expected exit 1, got $exit_code"; return 1; }
  echo "$output" | grep -q "missing templates/personal/" || { echo "  FAIL: missing templates-missing message"; return 1; }
  [ ! -d "$VAULT" ] || { echo "  FAIL: vault dir not cleaned up"; return 1; }
}

# Scenario 8: Duplicate email — count-then-match, fail loud
test_08_duplicate_email() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" 2>/dev/null || return 1

  # Inject a duplicate email entry in the clone
  cat > "$VAULT/company/people/duplicate.md" <<EOF
---
type: person
name: Duplicate
role: PM
team: product
email: layla@flash.test
updated: 2026-04-28
---
EOF

  local output
  output=$(fv_autodetect "layla@flash.test" 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 1 ] || { echo "  FAIL: expected exit 1 on duplicate, got $exit_code"; return 1; }
  echo "$output" | grep -q "Multiple people files match" || { echo "  FAIL: missing duplicate message"; return 1; }
}

# Scenario 8a: Email with regex special chars matches via awk exact-string
test_08a_codex_c7_regex_chars() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" 2>/dev/null || return 1

  # The fixture has a regex-test.md with email: first.last+test@flash.test
  if ! fv_autodetect "first.last+test@flash.test"; then
    echo "  FAIL: auto-detect failed on email with regex chars (. +)"
    return 1
  fi

  [ "$FV_PREFILL_NAME" = "Regex Test" ] || { echo "  FAIL: prefill name=$FV_PREFILL_NAME"; return 1; }
}

# Scenario 8b: Regex chars in fixture emails don't cause false-positive matches
test_08b_codex_c7_no_false_positive() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" 2>/dev/null || return 1

  # An email that DOESN'T match should NOT match anything via regex coincidence
  fv_autodetect "first_last_test@flash.test" || true

  [ -z "$FV_MATCH_FILE" ] || { echo "  FAIL: false-positive match on non-existent email: $FV_MATCH_FILE"; return 1; }
}

# Scenario 9: Atomic flag — interrupted generation routes to recovery
test_09_atomic_flag_recovery() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" 2>/dev/null || return 1

  # Simulate partial generation: create tasks.md + CLAUDE.md but NOT identity.md
  mkdir -p personal drafts
  touch drafts/.gitkeep
  echo "x" > personal/tasks.md
  echo "x" > CLAUDE.md
  # personal/identity.md INTENTIONALLY ABSENT — atomic flag missing

  cd / || true

  local output
  output=$(fv_check_existing_path "$VAULT" 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 0 ] || { echo "  FAIL: expected exit 0, got $exit_code"; return 1; }
  echo "$output" | grep -q "incomplete or corrupted" || { echo "  FAIL: should route to partial-setup, not full-setup"; return 1; }
}

# Scenario 10: Line numbering math (LINES_LOAD_BLOCK + CURRENT_GOALS_STEP)
test_10_line_numbering() {
  cd "$REPO_ROOT" || return 1

  # 1 line: load block has 1 entry (numbered 6), current goals step = 7
  local block n
  block=$(fv_build_lines_load_block "financial-wellness" 6)
  [ "$block" = "6. \`product/lines/financial-wellness.md\`" ] || { echo "  FAIL 1-line: '$block'"; return 1; }
  n=$(fv_current_goals_step_num "financial-wellness")
  [ "$n" = "7" ] || { echo "  FAIL 1-line current_goals_step: $n"; return 1; }

  # 4 lines: entries 6,7,8,9, current goals step = 10
  block=$(fv_build_lines_load_block "bill-payments scan-and-pay financial-wellness growth" 6)
  expected_4=$'6. `product/lines/bill-payments.md`\n7. `product/lines/scan-and-pay.md`\n8. `product/lines/financial-wellness.md`\n9. `product/lines/growth.md`'
  [ "$block" = "$expected_4" ] || { echo "  FAIL 4-line: $block"; return 1; }
  n=$(fv_current_goals_step_num "bill-payments scan-and-pay financial-wellness growth")
  [ "$n" = "10" ] || { echo "  FAIL 4-line current_goals_step: $n"; return 1; }
}

# Scenario 11: Personality isolation — identity.md has it, CLAUDE.md does not
test_11_personality_isolation() {
  drive_full_flow "noone@nowhere.test" "Layla" "Designer" "financial-wellness" "Some focus" "Direct, terse, no preamble." || return 1

  # identity.md MUST contain personality
  assert_grep "Direct, terse" "$VAULT/personal/identity.md" || return 1

  # CLAUDE.md is procedural-only — personality stays in identity.md
  assert_no_grep "Direct, terse" "$VAULT/CLAUDE.md" || return 1
}

# Scenario 12: Codex C6 — vault path with spaces is safely handled
test_12_codex_c6_path_with_spaces() {
  local spaced_vault="$TMP/my flash vault"
  export VAULT="$spaced_vault"

  drive_full_flow "noone@nowhere.test" || return 1

  # All 4 files should exist at the spaced path
  assert_file_exists "$spaced_vault/personal/identity.md" || return 1
  assert_file_exists "$spaced_vault/personal/tasks.md" || return 1
  assert_file_exists "$spaced_vault/CLAUDE.md" || return 1
  assert_file_exists "$spaced_vault/drafts/.gitkeep" || return 1
}

# Scenario 13: CLAUDE.md is marked skip-worktree and overwrites dev brief
test_13_claude_md_skip_worktree() {
  drive_full_flow "noone@nowhere.test" || return 1

  # The fixture committed a dev-brief CLAUDE.md. After setup, the local
  # CLAUDE.md should be the user version, not the dev brief.
  assert_grep "session brief for Layla" "$VAULT/CLAUDE.md" || return 1
  assert_no_grep "Test-fixture dev brief" "$VAULT/CLAUDE.md" || return 1

  # skip-worktree bit should be set, so git status sees no changes to CLAUDE.md
  cd "$VAULT" || return 1
  local ls_files
  ls_files=$(git ls-files -v CLAUDE.md)
  case "$ls_files" in
    S*) ;; # 'S' = skip-worktree set
    *) echo "  ASSERT FAIL: skip-worktree not set on CLAUDE.md (git ls-files -v: $ls_files)"; return 1 ;;
  esac

  # And `git status --porcelain` should be empty for CLAUDE.md
  if git status --porcelain CLAUDE.md | grep -q .; then
    echo "  ASSERT FAIL: CLAUDE.md should not appear in git status after skip-worktree"
    return 1
  fi

  # /CLAUDE.md should be appended to .git/info/exclude (local gitignore)
  if ! grep -qxF '/CLAUDE.md' .git/info/exclude; then
    echo "  ASSERT FAIL: /CLAUDE.md not appended to .git/info/exclude"
    return 1
  fi

  # Re-running fv_generate must not create a duplicate exclude entry
  fv_generate >/dev/null 2>&1 || true
  local count
  count=$(grep -cxF '/CLAUDE.md' .git/info/exclude)
  [ "$count" = "1" ] || { echo "  ASSERT FAIL: /CLAUDE.md appears $count times in exclude (expected 1)"; return 1; }
}

# Scenario 14: fv_list_canonical_lines reads from product/lines/
test_14_canonical_lines_from_repo() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1

  local lines
  lines=$(fv_list_canonical_lines)
  # Fixture has 4 lines: bill-payments, financial-wellness, growth, scan-and-pay
  echo "$lines" | grep -qx "bill-payments" || { echo "  FAIL: missing bill-payments. got: $lines"; return 1; }
  echo "$lines" | grep -qx "scan-and-pay" || { echo "  FAIL: missing scan-and-pay"; return 1; }
  echo "$lines" | grep -qx "financial-wellness" || { echo "  FAIL: missing financial-wellness"; return 1; }
  echo "$lines" | grep -qx "growth" || { echo "  FAIL: missing growth"; return 1; }
}

# Scenario 15: fv_validate_lines accepts canonical, rejects invalid, refuses empty
test_15_validate_lines() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1

  # Canonical pass
  fv_validate_lines "financial-wellness growth" 2>/dev/null || { echo "  FAIL: should accept canonical slugs"; return 1; }

  # Invalid slug rejected
  if fv_validate_lines "security" 2>/dev/null; then
    echo "  FAIL: should reject invalid slug 'security'"
    return 1
  fi

  # Mixed canonical+invalid rejected
  if fv_validate_lines "bill-payments security" 2>/dev/null; then
    echo "  FAIL: should reject when any slug is invalid"
    return 1
  fi

  # Empty input rejected
  if fv_validate_lines "" 2>/dev/null; then
    echo "  FAIL: should reject empty input"
    return 1
  fi

  # Empty canonical (no product/lines/) -> refuse
  rm -rf product/lines
  if fv_validate_lines "anything" 2>/dev/null; then
    echo "  FAIL: should refuse when product/lines/ is empty"
    return 1
  fi
}

# Scenario 16: tbd-core.sh sources cleanly and fv_check_yq exists
test_16_tbd_core_sources_cleanly() {
  local TBD_LIB="$REPO_ROOT/.claude/lib/tbd-core.sh"
  [ -f "$TBD_LIB" ] || { echo "  FAIL: tbd-core.sh missing at $TBD_LIB"; return 1; }

  # shellcheck source=/dev/null
  source "$TBD_LIB" || { echo "  FAIL: tbd-core.sh failed to source"; return 1; }

  type fv_check_yq >/dev/null 2>&1 || { echo "  FAIL: fv_check_yq not defined"; return 1; }
  type fv_validate_slug >/dev/null 2>&1 || { echo "  FAIL: fv_validate_slug not defined"; return 1; }
  type fv_section_append >/dev/null 2>&1 || { echo "  FAIL: fv_section_append not defined"; return 1; }
  type fv_tbds_scan >/dev/null 2>&1 || { echo "  FAIL: fv_tbds_scan not defined"; return 1; }
  type fv_archive_draft >/dev/null 2>&1 || { echo "  FAIL: fv_archive_draft not defined"; return 1; }
}

# Scenario 17: fv_validate_slug accepts valid, rejects invalid
test_17_validate_slug() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"

  fv_validate_slug "project-x" || { echo "  FAIL: 'project-x' rejected"; return 1; }
  fv_validate_slug "ab" || { echo "  FAIL: 'ab' (2 chars) rejected"; return 1; }
  fv_validate_slug "a1-b2-c3" || { echo "  FAIL: 'a1-b2-c3' rejected"; return 1; }

  fv_validate_slug "Project-X" && { echo "  FAIL: uppercase 'Project-X' accepted"; return 1; }
  fv_validate_slug "x" && { echo "  FAIL: single-char 'x' accepted"; return 1; }
  fv_validate_slug "-leading" && { echo "  FAIL: '-leading' accepted"; return 1; }
  fv_validate_slug "trailing-" && { echo "  FAIL: 'trailing-' accepted"; return 1; }
  fv_validate_slug "spaces here" && { echo "  FAIL: 'spaces here' accepted"; return 1; }
  fv_validate_slug 'inject"; rm' && { echo "  FAIL: shell metacharacters accepted"; return 1; }

  local long
  long=$(printf 'a%.0s' {1..61})
  fv_validate_slug "$long" && { echo "  FAIL: 61-char slug accepted"; return 1; }

  return 0
}

# Scenario 18: fv_section_append inserts under named section, atomic
test_18_section_append() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"

  local f="$VAULT/test-section.md"
  mkdir -p "$VAULT"
  cat > "$f" <<'EOF'
# Title

## Owns
- existing entry

## Background
prior content
EOF

  fv_section_append "$f" "## Owns" "- new entry" || { echo "  FAIL: append failed"; return 1; }
  grep -q "^- new entry" "$f" || { echo "  FAIL: new entry not in file"; return 1; }

  # Verify it landed UNDER ## Owns and BEFORE ## Background
  awk '/^## Owns/{flag=1; next} /^## Background/{flag=0} flag && /^- new entry/{found=1} END{exit !found}' "$f" \
    || { echo "  FAIL: new entry not under '## Owns' section"; return 1; }

  # Section that doesn't exist → return 1, no file change
  local sha_before
  sha_before=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1 || sha256sum "$f" | cut -d' ' -f1)
  fv_section_append "$f" "## Nope" "- ignored" && { echo "  FAIL: missing section returned 0"; return 1; }
  local sha_after
  sha_after=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1 || sha256sum "$f" | cut -d' ' -f1)
  [ "$sha_before" = "$sha_after" ] || { echo "  FAIL: file changed despite missing section"; return 1; }

  # No .tmp orphan
  [ ! -f "${f}.tmp" ] || { echo "  FAIL: .tmp orphan remains"; return 1; }
}

# Scenario 19: fv_tbds_scan finds markers, ignores code blocks
test_19_tbds_scan() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"

  local f="$VAULT/scan-target.md"
  mkdir -p "$VAULT"
  cat > "$f" <<'EOF'
---
data_source: TBD
---

# Title

Body has _TBD — capture biller variance_ here.

And a <placeholder> too.

```bash
# This TBD is in code and should be ignored
echo TBD
```

Final TBD line at end.
EOF

  local out
  out=$(fv_tbds_scan "$f")
  local count
  count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')

  # Expected: 4 hits (frontmatter TBD, body _TBD, <placeholder>, final TBD)
  # Code-block TBD must NOT match
  [ "$count" = "4" ] || { echo "  FAIL: expected 4 hits, got $count"; printf '%s\n' "$out"; return 1; }

  printf '%s\n' "$out" | grep -q "data_source: TBD" || { echo "  FAIL: missed frontmatter TBD"; return 1; }
  printf '%s\n' "$out" | grep -q "<placeholder>" || { echo "  FAIL: missed <placeholder>"; return 1; }
  printf '%s\n' "$out" | grep -q "echo TBD" && { echo "  FAIL: code-block TBD leaked through"; return 1; }
  return 0
}

# Scenario 20: fv_extract_links + fv_extract_incoming
test_20_extract_links() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"

  mkdir -p "$VAULT"
  cd "$VAULT" || return 1
  mkdir -p product/projects company/people

  cat > product/projects/project-x.md <<'EOF'
---
type: project
---
# Project X

Owners: [[ahmed]] and [[product/people/sarah]].

Related: [[other-project]].

```
This [[code-example]] is in a backtick block.
```
EOF

  cat > company/people/ahmed.md <<'EOF'
---
type: person
---
# Ahmed

Drives [[product/projects/project-x]].
EOF

  local out
  out=$(fv_extract_links product/projects/project-x.md)

  # Should have ahmed, sarah, other-project; NOT code-example
  echo "$out" | grep -qx "ahmed" || { echo "  FAIL: missing ahmed"; return 1; }
  echo "$out" | grep -qx "sarah" || { echo "  FAIL: missing sarah"; return 1; }
  echo "$out" | grep -qx "other-project" || { echo "  FAIL: missing other-project"; return 1; }
  echo "$out" | grep -qx "code-example" && { echo "  FAIL: code-example leaked"; return 1; }

  # Incoming check
  local incoming
  incoming=$(fv_extract_incoming "project-x")
  echo "$incoming" | grep -q "company/people/ahmed.md" || { echo "  FAIL: incoming missed ahmed"; return 1; }
}

# Scenario 21: fv_schema_required reads _schema block
test_21_schema_readers() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"
  fv_check_yq 2>/dev/null || { echo "  SKIP: yq not installed"; return 0; }

  # Use the freshly cloned fixture vault for real templates
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1

  # Use a real template the fixture already ships
  [ -f templates/project-template.md ] || { echo "  FAIL: project-template.md missing"; return 1; }

  local req
  req=$(fv_schema_required project)
  echo "$req" | grep -q "type" || { echo "  FAIL: 'type' not in required for project"; return 1; }

  # Optional may or may not have entries depending on template; just verify the call works
  fv_schema_optional project >/dev/null || { echo "  FAIL: schema_optional errored"; return 1; }
}

# Scenario 22: fv_archive_draft moves to dated subfolder, handles collisions
test_22_archive_draft() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"

  mkdir -p "$VAULT"
  cd "$VAULT" || return 1
  mkdir -p drafts
  echo "first draft" > drafts/test.md
  fv_archive_draft drafts/test.md || { echo "  FAIL: first archive failed"; return 1; }

  local today
  today=$(date +%Y-%m-%d)
  [ -f "drafts/archive/$today/test.md" ] || { echo "  FAIL: archived file missing"; return 1; }
  [ -f "drafts/test.md" ] && { echo "  FAIL: source still in drafts/"; return 1; }

  # Collision: archive a second draft of same name on same day
  echo "second draft" > drafts/test.md
  fv_archive_draft drafts/test.md || { echo "  FAIL: second archive failed"; return 1; }
  [ -f "drafts/archive/$today/test-2.md" ] || { echo "  FAIL: collision rename missing"; return 1; }

  # Refuse non-drafts/ paths
  echo "x" > /tmp/not-a-draft.md
  fv_archive_draft /tmp/not-a-draft.md && { echo "  FAIL: accepted non-drafts/ path"; rm -f /tmp/not-a-draft.md; return 1; }
  rm -f /tmp/not-a-draft.md
}

# Scenario 23: fv_tbds_owned_paths derives owned set from identity.md
test_23_owned_paths() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"
  fv_check_yq 2>/dev/null || { echo "  SKIP: yq not installed"; return 0; }

  mkdir -p "$VAULT"
  cd "$VAULT" || return 1
  mkdir -p personal product/lines product/projects product/metrics product/squads company/people

  cat > personal/identity.md <<'EOF'
---
product_lines:
  - bill-payments
squads:
  - billevers
---
# Test
EOF

  echo "x" > product/lines/bill-payments.md
  echo "x" > product/lines/other-line.md
  echo "x" > product/squads/billevers.md

  cat > product/projects/inquiry-fix.md <<'EOF'
---
type: project
lines: [bill-payments]
---
EOF

  cat > product/projects/unrelated.md <<'EOF'
---
type: project
lines: [other-line]
---
EOF

  cat > company/people/alice.md <<'EOF'
---
type: person
squad: [billevers]
---
EOF

  local out
  out=$(fv_tbds_owned_paths)

  echo "$out" | grep -qx "product/lines/bill-payments.md" || { echo "  FAIL: owned line missing"; return 1; }
  echo "$out" | grep -qx "product/squads/billevers.md" || { echo "  FAIL: owned squad missing"; return 1; }
  echo "$out" | grep -qx "product/projects/inquiry-fix.md" || { echo "  FAIL: owned project missing"; return 1; }
  echo "$out" | grep -qx "company/people/alice.md" || { echo "  FAIL: squad member missing"; return 1; }
  echo "$out" | grep -qx "product/projects/unrelated.md" && { echo "  FAIL: unrelated project leaked"; return 1; }
  echo "$out" | grep -qx "product/lines/other-line.md" && { echo "  FAIL: other-line leaked"; return 1; }
  return 0
}

# Scenario 24: fv_tbds_upsert + fv_tbds_resolve roundtrip
test_24_upsert_resolve() {
  source "$REPO_ROOT/.claude/lib/tbd-core.sh"

  mkdir -p "$VAULT"
  cd "$VAULT" || return 1
  mkdir -p personal product/lines

  cat > personal/tasks.md <<EOF
# My tasks

$FV_AUTO_MANAGED_START
$FV_AUTO_MANAGED_END

## In progress
- [ ] manual task
EOF

  cat > product/lines/test-line.md <<'EOF'
---
type: product-line
last_reviewed: TBD
---
# Test
EOF

  # Upsert with one TBD
  local new_tbds
  new_tbds="product/lines/test-line.md	2	last_reviewed: TBD"
  fv_tbds_upsert "$new_tbds" || { echo "  FAIL: upsert failed"; return 1; }

  grep -q "### product/lines/test-line.md" personal/tasks.md || { echo "  FAIL: subheader missing"; return 1; }
  grep -q "L2 — last_reviewed: TBD" personal/tasks.md || { echo "  FAIL: entry missing"; return 1; }
  grep -q "manual task" personal/tasks.md || { echo "  FAIL: manual section clobbered"; return 1; }

  # Now resolve the source TBD by editing the file
  sed -i.bak 's/last_reviewed: TBD/last_reviewed: 2026-05-10/' product/lines/test-line.md && rm product/lines/test-line.md.bak

  fv_tbds_resolve || { echo "  FAIL: resolve failed"; return 1; }
  grep -q "L2 — last_reviewed: TBD" personal/tasks.md && { echo "  FAIL: stale entry not removed"; return 1; }
  grep -q "manual task" personal/tasks.md || { echo "  FAIL: manual section clobbered by resolve"; return 1; }
  return 0
}

# Scenario 25: identity.md has all four merged sections
test_25_identity_has_merged_sections() {
  drive_full_flow "noone@nowhere.test" || return 1

  local id="$VAULT/personal/identity.md"
  assert_file_exists "$id" || return 1

  assert_grep "## Who I am" "$id" || return 1
  assert_grep "## What I'm focused on now" "$id" || return 1
  assert_grep "## How I prefer the AI to talk to me" "$id" || return 1
  assert_grep "## How I think about work" "$id" || return 1
}

# Scenario 26: identity.md frontmatter has product_lines + squads
test_26_identity_has_owned_arrays() {
  drive_full_flow "layla@flash.test" || return 1

  local id="$VAULT/personal/identity.md"
  awk '/^---$/{n++; next} n==1' "$id" | grep -q "product_lines:" \
    || { echo "  FAIL: product_lines: missing from identity frontmatter"; return 1; }
  awk '/^---$/{n++; next} n==1' "$id" | grep -q "squads:" \
    || { echo "  FAIL: squads: missing from identity frontmatter"; return 1; }
}

# Scenario 27: tasks.md has auto-managed markers in place
test_27_tasks_has_markers() {
  drive_full_flow "noone@nowhere.test" || return 1

  local tasks="$VAULT/personal/tasks.md"
  assert_file_exists "$tasks" || return 1

  assert_grep "<!-- flash-vault:auto-managed:start -->" "$tasks" || return 1
  assert_grep "<!-- flash-vault:auto-managed:end -->" "$tasks" || return 1

  # Manual sections preserved
  assert_grep "## In progress" "$tasks" || return 1
  assert_grep "## Queue" "$tasks" || return 1
  assert_grep "## Done" "$tasks" || return 1
}

# Scenario 28: CLAUDE.md has Daily commands section listing the three skills
test_28_claude_md_has_daily_commands() {
  drive_full_flow "noone@nowhere.test" || return 1

  local claude="$VAULT/CLAUDE.md"
  assert_grep "Daily commands" "$claude" || return 1
  assert_grep "/flash-vault:process" "$claude" || return 1
  assert_grep "/flash-vault:validate" "$claude" || return 1
  assert_grep "/flash-vault:push-to-flash-vault" "$claude" || return 1

  # Orient should mention 3 reads, not the old 7
  assert_grep "personal/identity.md" "$claude" || return 1
  assert_grep "personal/tasks.md" "$claude" || return 1
  assert_grep "company/company.md" "$claude" || return 1

  # Methodology / goals should NOT be referenced
  if grep -q "personal/methodology.md" "$claude"; then
    echo "  FAIL: stale methodology reference"
    return 1
  fi
  if grep -q "personal/goals.md" "$claude"; then
    echo "  FAIL: stale goals reference"
    return 1
  fi
  return 0
}

# =============================================================================
# Run all scenarios
# =============================================================================

run_scenario "01-standard-flow"                  test_01_standard_flow
run_scenario "02-auto-detect-full"               test_02_auto_detect_full
run_scenario "03-refuse-full-setup"              test_03_refuse_full_setup
run_scenario "04-refuse-partial-setup"           test_04_refuse_partial_setup_missing_one_file
run_scenario "05-refuse-unrelated-dir"           test_05_refuse_unrelated
run_scenario "06-clone-sanity-cleanup"           test_06_clone_sanity_cleanup
run_scenario "07-templates-missing"              test_07_templates_missing
run_scenario "08-duplicate-email"                test_08_duplicate_email
run_scenario "08a-regex-chars-in-email"          test_08a_codex_c7_regex_chars
run_scenario "08b-no-false-positive-regex-chars" test_08b_codex_c7_no_false_positive
run_scenario "09-atomic-flag-recovery"           test_09_atomic_flag_recovery
run_scenario "10-line-numbering-math"            test_10_line_numbering
run_scenario "11-personality-isolation"          test_11_personality_isolation
run_scenario "12-path-with-spaces"               test_12_codex_c6_path_with_spaces
run_scenario "13-claude-md-skip-worktree"        test_13_claude_md_skip_worktree
run_scenario "14-canonical-lines-from-repo"      test_14_canonical_lines_from_repo
run_scenario "15-validate-lines"                 test_15_validate_lines
run_scenario "16: tbd-core sources cleanly"      test_16_tbd_core_sources_cleanly
run_scenario "17: fv_validate_slug"              test_17_validate_slug
run_scenario "18: fv_section_append"             test_18_section_append
run_scenario "19: fv_tbds_scan"                  test_19_tbds_scan
run_scenario "20: fv_extract_links"              test_20_extract_links
run_scenario "21: fv_schema_readers"             test_21_schema_readers
run_scenario "22: fv_archive_draft"              test_22_archive_draft
run_scenario "23: fv_tbds_owned_paths"           test_23_owned_paths
run_scenario "24: fv_tbds_upsert + resolve"      test_24_upsert_resolve
run_scenario "25: identity.md merged sections"   test_25_identity_has_merged_sections
run_scenario "26: identity.md owned arrays"      test_26_identity_has_owned_arrays
run_scenario "27: tasks.md auto-managed markers" test_27_tasks_has_markers
run_scenario "28: CLAUDE.md Daily commands"      test_28_claude_md_has_daily_commands

# =============================================================================
# Summary
# =============================================================================

echo "================================================================"
echo "PASSED: $PASS_COUNT"
echo "FAILED: $FAIL_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
  echo "Failed scenarios:"
  for s in "${FAILED_SCENARIOS[@]}"; do
    echo "  - $s"
  done
  exit 1
fi
echo "All scenarios passed."
