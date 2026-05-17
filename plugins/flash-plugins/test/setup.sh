#!/usr/bin/env bash
# Flash-Vault setup skill — E2E test suite
#
# Sources the production lib/setup-core.sh directly. No
# parallel driver implementation — drift impossible by construction.
#
# v1: local-only test. CI cannot clone the private source repo without a
# deploy token; that's a follow-up PR. The fixture at test/fixtures/source-repo/
# is converted into a local bare repo and used as fake origin via FV_CLONE_URL.
#
# Run: ./test/setup.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN_ROOT/lib/setup-core.sh"

# Sanity: lib must exist (build/install drift catch).
if [ ! -f "$LIB" ]; then
  echo "FATAL: $LIB not found. Check plugin install."
  exit 1
fi

# shellcheck source=../lib/setup-core.sh
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
  local fixture="$PLUGIN_ROOT/test/fixtures/source-repo"

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
# Used by scenarios that test the happy path.
# Args: $1=name (default Layla), $2=role (default Designer), $3=lines (default financial-wellness),
#       $4=focus, $5=personality, $6=squads (optional, default empty)
drive_full_flow() {
  fv_check_existing_path "$VAULT"
  fv_clone "$VAULT"
  cd "$VAULT" || return 1
  fv_verify_clone

  export FV_NAME="${1:-Layla}"
  export FV_ROLE="${2:-Designer}"
  export FV_LINES="${3:-financial-wellness}"
  export FV_PRIMARY_LINE
  FV_PRIMARY_LINE=$(echo "$FV_LINES" | awk '{print $1}')
  export FV_FOCUS="${4:-Auto-invest roundup redesign and empty-state consistency}"
  export FV_PERSONALITY="${5:-Direct, terse, no preamble.}"
  export FV_SQUADS="${6:-}"

  fv_generate
}

# =============================================================================
# Scenarios
# =============================================================================

# Scenario 1: Standard flow
test_01_standard_flow() {
  drive_full_flow || return 1

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

# Scenario 2: Pre-clone refuse — full setup
test_02_refuse_full_setup() {
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
  echo "$output" | grep -q "already have a Flash Vault set up" || { echo "  FAIL: missing 'already have setup' message"; return 1; }
}

# Scenario 3: Pre-clone refuse — partial setup (single missing overlay file)
test_03_refuse_partial_setup_missing_one_file() {
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
  echo "$output" | grep -q "personal setup didn't finish" || { echo "  FAIL: missing partial-setup message"; return 1; }
  echo "$output" | grep -q "rm -rf personal/ drafts/ CLAUDE.md" || { echo "  FAIL: missing recovery cmd"; return 1; }
}

# Scenario 4: Pre-clone refuse — non-empty unrelated dir
test_04_refuse_unrelated() {
  mkdir -p "$VAULT"
  echo "random" > "$VAULT/some-file.txt"

  local output
  output=$(fv_check_existing_path "$VAULT" 2>&1) && true
  local exit_code=$?

  [ $exit_code -eq 1 ] || { echo "  FAIL: expected exit 1, got $exit_code"; return 1; }
  echo "$output" | grep -q "exists and is not empty" || { echo "  FAIL: missing unrelated-dir message"; return 1; }
}

# Scenario 5: Sanity-check failure cleanup (origin remote mismatch)
test_05_clone_sanity_cleanup() {
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

# Scenario 6: Templates missing in clone
test_06_templates_missing() {
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

# Scenario 7: Atomic flag — interrupted generation routes to recovery
test_07_atomic_flag_recovery() {
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
  echo "$output" | grep -q "personal setup didn't finish" || { echo "  FAIL: should route to partial-setup, not full-setup"; return 1; }
}

# Scenario 8: Line numbering math (LINES_LOAD_BLOCK + CURRENT_GOALS_STEP)
test_08_line_numbering() {
  cd "$PLUGIN_ROOT" || return 1

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

# Scenario 9: Personality isolation — identity.md has it, CLAUDE.md does not
test_09_personality_isolation() {
  drive_full_flow "Layla" "Designer" "financial-wellness" "Some focus" "Direct, terse, no preamble." || return 1

  # identity.md MUST contain personality
  assert_grep "Direct, terse" "$VAULT/personal/identity.md" || return 1

  # CLAUDE.md is procedural-only — personality stays in identity.md
  assert_no_grep "Direct, terse" "$VAULT/CLAUDE.md" || return 1
}

# Scenario 10: Vault path with spaces is safely handled
test_10_path_with_spaces() {
  local spaced_vault="$TMP/my flash vault"
  export VAULT="$spaced_vault"

  drive_full_flow || return 1

  # All 4 files should exist at the spaced path
  assert_file_exists "$spaced_vault/personal/identity.md" || return 1
  assert_file_exists "$spaced_vault/personal/tasks.md" || return 1
  assert_file_exists "$spaced_vault/CLAUDE.md" || return 1
  assert_file_exists "$spaced_vault/drafts/.gitkeep" || return 1
}

# Scenario 11: CLAUDE.md is marked skip-worktree and overwrites dev brief
test_11_claude_md_skip_worktree() {
  drive_full_flow || return 1

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

# Scenario 12: fv_list_canonical_lines reads from product/lines/ and excludes lines.md MOC
test_12_canonical_lines_from_repo() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1

  local lines
  lines=$(fv_list_canonical_lines)
  # Fixture has 4 lines: bill-payments, financial-wellness, growth, scan-and-pay
  echo "$lines" | grep -qx "bill-payments" || { echo "  FAIL: missing bill-payments. got: $lines"; return 1; }
  echo "$lines" | grep -qx "scan-and-pay" || { echo "  FAIL: missing scan-and-pay"; return 1; }
  echo "$lines" | grep -qx "financial-wellness" || { echo "  FAIL: missing financial-wellness"; return 1; }
  echo "$lines" | grep -qx "growth" || { echo "  FAIL: missing growth"; return 1; }
  # The lines.md MOC file must NOT appear in the canonical list
  if echo "$lines" | grep -qx "lines"; then
    echo "  FAIL: 'lines' MOC leaked into canonical lines list"
    return 1
  fi
}

# Scenario 13: fv_validate_lines accepts canonical, rejects invalid, refuses empty
test_13_validate_lines() {
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

# Scenario 14: fv_list_canonical_squads excludes squads.md MOC
test_14_canonical_squads_excludes_moc() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1
  local result
  result=$(fv_list_canonical_squads)
  if echo "$result" | grep -qx "squads"; then
    echo "  FAIL: 'squads' MOC leaked into canonical squads list"
    return 1
  fi
  # Confirm legitimate squads are present
  echo "$result" | grep -qx "bill-payments-squad" || { echo "  FAIL: bill-payments-squad missing"; return 1; }
  echo "$result" | grep -qx "growth-squad" || { echo "  FAIL: growth-squad missing"; return 1; }
}

# Scenario 15: fv_validate_squads accepts canonical, rejects unknown, empty input is valid
test_15_validate_squads_behavior() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1
  fv_validate_squads "bill-payments-squad" || { echo "  FAIL: rejected valid squad"; return 1; }
  fv_validate_squads "bill-payments-squad growth-squad" || { echo "  FAIL: rejected valid multi-squad"; return 1; }
  if fv_validate_squads "totally-fake-squad" 2>/dev/null; then
    echo "  FAIL: accepted invalid squad"; return 1
  fi
  fv_validate_squads "" || { echo "  FAIL: rejected empty input (should be valid)"; return 1; }
}

# Scenario 16: fv_build_squads_inline emits correct wiki links
test_16_build_squads_inline() {
  local out
  out=$(fv_build_squads_inline "bill-payments-squad growth-squad")
  local expected="[[product/squads/bill-payments-squad]], [[product/squads/growth-squad]]"
  if [ "$out" != "$expected" ]; then
    echo "  FAIL: got [$out], expected [$expected]"
    return 1
  fi
  # Single squad
  out=$(fv_build_squads_inline "bill-payments-squad")
  expected="[[product/squads/bill-payments-squad]]"
  [ "$out" = "$expected" ] || { echo "  FAIL: single squad got [$out]"; return 1; }
  # Empty input
  out=$(fv_build_squads_inline "")
  [ -z "$out" ] || { echo "  FAIL: empty input produced [$out]"; return 1; }
}

# Scenario 17: fv_generate writes plural squads to identity.md
test_17_generate_plural_squads() {
  drive_full_flow "Omar" "PM" "bill-payments" \
    "Q2 retention initiatives" "Numbers-driven, link-heavy" \
    "bill-payments-squad growth-squad"

  assert_grep '^squads: \[bill-payments-squad, growth-squad\]$' "$VAULT/personal/identity.md" || return 1
  assert_grep '\[\[product/squads/bill-payments-squad\]\], \[\[product/squads/growth-squad\]\]' "$VAULT/personal/identity.md" || return 1
}

# Scenario 18: fv_generate with empty FV_SQUADS renders (none yet)
test_18_generate_empty_squads() {
  drive_full_flow "Layla" "Designer" "financial-wellness" \
    "Onboarding redesign" "Direct, terse, no preamble." \
    ""

  assert_grep '^squads: \[\]$' "$VAULT/personal/identity.md" || return 1
  assert_grep '^- Squads: (none yet)$' "$VAULT/personal/identity.md" || return 1
}

# Scenario 19: fv_generate normalizes whitespace in FV_SQUADS
test_19_generate_squads_whitespace_normalized() {
  drive_full_flow "Omar" "PM" "bill-payments" \
    "x" "y" \
    "  bill-payments-squad   growth-squad  "

  # YAML must be clean — no trailing ", " or extra commas
  assert_grep '^squads: \[bill-payments-squad, growth-squad\]$' "$VAULT/personal/identity.md" || return 1
  assert_no_grep ', \]' "$VAULT/personal/identity.md" || return 1
}

# Scenario 20: identity.md has all four merged sections
test_20_identity_has_merged_sections() {
  drive_full_flow || return 1

  local id="$VAULT/personal/identity.md"
  assert_file_exists "$id" || return 1

  assert_grep "## Who I am" "$id" || return 1
  assert_grep "## What I'm focused on now" "$id" || return 1
  assert_grep "## How I prefer the AI to talk to me" "$id" || return 1
  assert_grep "## How I think about work" "$id" || return 1
}

# Scenario 21: identity.md frontmatter has product_lines + squads
test_21_identity_has_owned_arrays() {
  drive_full_flow || return 1

  local id="$VAULT/personal/identity.md"
  awk '/^---$/{n++; next} n==1' "$id" | grep -q "product_lines:" \
    || { echo "  FAIL: product_lines: missing from identity frontmatter"; return 1; }
  awk '/^---$/{n++; next} n==1' "$id" | grep -q "squads:" \
    || { echo "  FAIL: squads: missing from identity frontmatter"; return 1; }
}

# Scenario 22: tasks.md has auto-managed markers in place
test_22_tasks_has_markers() {
  drive_full_flow || return 1

  local tasks="$VAULT/personal/tasks.md"
  assert_file_exists "$tasks" || return 1

  assert_grep "<!-- flash-vault:auto-managed:start -->" "$tasks" || return 1
  assert_grep "<!-- flash-vault:auto-managed:end -->" "$tasks" || return 1

  # Manual sections preserved
  assert_grep "## In progress" "$tasks" || return 1
  assert_grep "## Queue" "$tasks" || return 1
  assert_grep "## Done" "$tasks" || return 1
}

# Scenario 23: CLAUDE.md has Daily commands section listing the three skills
test_23_claude_md_has_daily_commands() {
  drive_full_flow || return 1

  local claude="$VAULT/CLAUDE.md"
  assert_grep "Daily commands" "$claude" || return 1
  assert_grep "/process" "$claude" || return 1
  assert_grep "/validate" "$claude" || return 1
  assert_grep "/push-to-flash-vault" "$claude" || return 1

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

# Scenario 24: fv_slugify handles whitespace, casing, and non-alphanumeric runs
test_24_slugify() {
  [ "$(fv_slugify "Tarek Rajab")" = "tarek-rajab" ] \
    || { echo "  FAIL: 'Tarek Rajab' did not slug to 'tarek-rajab'"; return 1; }
  [ "$(fv_slugify "Ahmed  AbuGameel")" = "ahmed-abugameel" ] \
    || { echo "  FAIL: double-space did not collapse"; return 1; }
  [ "$(fv_slugify "  --weird name??")" = "weird-name" ] \
    || { echo "  FAIL: leading/trailing punctuation not trimmed"; return 1; }
  [ "$(fv_slugify "MIXED_Case 123")" = "mixed-case-123" ] \
    || { echo "  FAIL: mixed-case + underscore + digits"; return 1; }
  return 0
}

# Scenario 25: fv_create_person_if_missing renders a starter profile from the template
test_25_create_person_if_missing_creates() {
  fv_clone "$VAULT"
  cd "$VAULT" || return 1
  fv_verify_clone

  # No file at company/people/tarek-rajab.md yet
  [ ! -f company/people/tarek-rajab.md ] || { echo "  FAIL: precondition — file already exists"; return 1; }

  fv_create_person_if_missing "tarek-rajab" "Tarek Rajab" "Product Designer" "design" "billevers"

  assert_file_exists company/people/tarek-rajab.md || return 1
  assert_grep "# Tarek Rajab"          company/people/tarek-rajab.md || return 1
  assert_grep "^role: Product Designer" company/people/tarek-rajab.md || return 1
  assert_grep "^team: design"          company/people/tarek-rajab.md || return 1
  assert_grep "^squad: \[billevers\]"  company/people/tarek-rajab.md || return 1
  # _schema block must be stripped in the rendered file
  assert_no_grep "_schema:" company/people/tarek-rajab.md || return 1
  return 0
}

# Scenario 26: fv_create_person_if_missing leaves an existing file untouched
test_26_create_person_if_missing_preserves_existing() {
  fv_clone "$VAULT"
  cd "$VAULT" || return 1
  fv_verify_clone

  mkdir -p company/people
  printf 'EXISTING SENTINEL — do not overwrite\n' > company/people/tarek-rajab.md

  fv_create_person_if_missing "tarek-rajab" "Tarek Rajab" "Product Designer" "design" "billevers"

  assert_grep "EXISTING SENTINEL" company/people/tarek-rajab.md \
    || { echo "  FAIL: function overwrote an existing file"; return 1; }
  return 0
}

# Scenario 27: fv_drop_missing_project_drafts creates a draft only for slugs
# that don't already have a real project note AND don't have a pending draft.
test_27_drop_missing_project_drafts() {
  fv_clone "$VAULT"
  cd "$VAULT" || return 1
  fv_verify_clone

  mkdir -p product/projects drafts
  printf -- '---\ntype: project\n---\n# Already filed\n' > product/projects/already-filed.md
  printf 'pending\n' > drafts/project-already-drafted.md

  fv_drop_missing_project_drafts "already-filed already-drafted brand-new-one"

  # already-filed → no draft created (real note exists)
  [ ! -f drafts/project-already-filed.md ] \
    || { echo "  FAIL: should not create draft for existing project note"; return 1; }
  # already-drafted → unchanged
  assert_grep "^pending$" drafts/project-already-drafted.md \
    || { echo "  FAIL: existing draft was overwritten"; return 1; }
  # brand-new-one → fresh draft created
  assert_file_exists drafts/project-brand-new-one.md || return 1
  assert_grep "Mentioned during setup" drafts/project-brand-new-one.md || return 1
  assert_grep "/process drafts/project-brand-new-one.md" drafts/project-brand-new-one.md || return 1
  return 0
}

# Scenario 28: identity.md gains a Profile wiki link to the user's person file
test_28_identity_has_profile_link() {
  drive_full_flow "Tarek Rajab" "Product Designer" "financial-wellness" || return 1

  assert_grep "Profile: \[\[company/people/tarek-rajab\]\]" "$VAULT/personal/identity.md" \
    || { echo "  FAIL: identity.md missing Profile link"; return 1; }
  # And the matching starter profile should have been created
  assert_file_exists "$VAULT/company/people/tarek-rajab.md" || return 1
  return 0
}

# Scenario 29: FV_WORK_STYLE prose renders into identity.md's
# "How I think about work" section verbatim.
test_29_identity_work_style_filled() {
  export FV_WORK_STYLE="Async-first, ship daily, push back hard on scope creep."
  drive_full_flow "Layla" "Engineer" "financial-wellness" || { unset FV_WORK_STYLE; return 1; }
  unset FV_WORK_STYLE

  assert_grep "Async-first, ship daily, push back hard on scope creep." "$VAULT/personal/identity.md" || return 1
  # The old hardcoded session-rhythm text must NOT leak into identity.md
  assert_no_grep "Every session has three phases" "$VAULT/personal/identity.md" || return 1
  return 0
}

# Scenario 30: empty FV_WORK_STYLE renders an editable prompt line
# instead of leaving the placeholder unsubstituted.
test_30_identity_work_style_empty_renders_prompt() {
  unset FV_WORK_STYLE
  drive_full_flow "Layla" "Engineer" "financial-wellness" || return 1

  assert_grep "Edit this — describe your work style" "$VAULT/personal/identity.md" \
    || { echo "  FAIL: empty work-style should render a prompt line"; return 1; }
  # No unrendered placeholder should remain in the file
  assert_no_grep "{{WORK_STYLE}}" "$VAULT/personal/identity.md" || return 1
  return 0
}

# Scenario 31: FV_PERSON_SLUG overrides the name-derived person slug so identity
# links to a confirmed existing profile instead of a fresh duplicate.
test_31_person_slug_override() {
  fv_clone "$VAULT" 2>/dev/null
  cd "$VAULT" || return 1
  fv_verify_clone

  # An existing profile the contributor should be linked to.
  mkdir -p company/people
  printf -- '---\ntype: person\n---\n# Tarek Rajab\n' > company/people/tarek-rajab.md

  export FV_NAME="Tarek Q Rajab" FV_ROLE="Product Designer" \
         FV_LINES="financial-wellness" FV_PRIMARY_LINE="financial-wellness" \
         FV_FOCUS="" FV_PERSONALITY="" FV_PERSON_SLUG="tarek-rajab"
  fv_generate || { unset FV_PERSON_SLUG; return 1; }
  unset FV_PERSON_SLUG

  # identity.md links to the existing profile slug
  assert_grep "company/people/tarek-rajab" "$VAULT/personal/identity.md" || return 1
  # the existing profile file was NOT overwritten
  assert_grep "# Tarek Rajab" "$VAULT/company/people/tarek-rajab.md" || return 1
  # slugify did NOT win: no file was created at the slugified-name path
  assert_file_absent "$VAULT/company/people/tarek-q-rajab.md" || return 1
  return 0
}

# =============================================================================
# Run all scenarios
# =============================================================================

run_scenario "01-standard-flow"                  test_01_standard_flow
run_scenario "02-refuse-full-setup"              test_02_refuse_full_setup
run_scenario "03-refuse-partial-setup"           test_03_refuse_partial_setup_missing_one_file
run_scenario "04-refuse-unrelated-dir"           test_04_refuse_unrelated
run_scenario "05-clone-sanity-cleanup"           test_05_clone_sanity_cleanup
run_scenario "06-templates-missing"              test_06_templates_missing
run_scenario "07-atomic-flag-recovery"           test_07_atomic_flag_recovery
run_scenario "08-line-numbering-math"            test_08_line_numbering
run_scenario "09-personality-isolation"          test_09_personality_isolation
run_scenario "10-path-with-spaces"               test_10_path_with_spaces
run_scenario "11-claude-md-skip-worktree"        test_11_claude_md_skip_worktree
run_scenario "12-canonical-lines-from-repo"      test_12_canonical_lines_from_repo
run_scenario "13-validate-lines"                 test_13_validate_lines
run_scenario "14-canonical-squads-excludes-moc"  test_14_canonical_squads_excludes_moc
run_scenario "15-validate-squads-behavior"       test_15_validate_squads_behavior
run_scenario "16-build-squads-inline"            test_16_build_squads_inline
run_scenario "17-generate-plural-squads"         test_17_generate_plural_squads
run_scenario "18-generate-empty-squads"          test_18_generate_empty_squads
run_scenario "19-generate-squads-whitespace"     test_19_generate_squads_whitespace_normalized
run_scenario "20-identity-merged-sections"       test_20_identity_has_merged_sections
run_scenario "21-identity-owned-arrays"          test_21_identity_has_owned_arrays
run_scenario "22-tasks-auto-managed-markers"     test_22_tasks_has_markers
run_scenario "23-claude-md-daily-commands"       test_23_claude_md_has_daily_commands
run_scenario "24-slugify"                        test_24_slugify
run_scenario "25-create-person-if-missing"       test_25_create_person_if_missing_creates
run_scenario "26-create-person-preserves-existing" test_26_create_person_if_missing_preserves_existing
run_scenario "27-drop-missing-project-drafts"    test_27_drop_missing_project_drafts
run_scenario "28-identity-has-profile-link"      test_28_identity_has_profile_link
run_scenario "29-identity-work-style-filled"     test_29_identity_work_style_filled
run_scenario "30-identity-work-style-empty"      test_30_identity_work_style_empty_renders_prompt
run_scenario "31-person-slug-override"           test_31_person_slug_override

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
