---
name: setup
description: One-time setup for Flash Vault. Clones Flashie-AI/Flash-Vault to a path you choose, then generates personal/ files and overwrites the repo's developer-mode CLAUDE.md with a per-contributor user brief so the AI loads Flash context calibrated to your role and product lines. Runs a short conversation to collect your name, role, product line(s), and squad(s) — no git email inference.
---

# /flash-vault:setup

This skill runs ONCE per local clone of Flash Vault. It generates files in `personal/` and replaces the cloned dev-mode `CLAUDE.md` at the repo root with a per-contributor user brief, then marks `CLAUDE.md` skip-worktree so it stays local and doesn't fight `git pull`.

Do NOT skip or reorder phases. Phase 1 runs from anywhere (pre-clone). Phase 2 runs from inside the freshly cloned repo. Once the contributor confirms in Phase 2 Part 3, file generation runs to completion or fails loudly.

The deterministic bash logic (pre-flight checks, clone, file generation, placeholder substitution) lives in `lib/setup-core.sh` inside this plugin. Same code runs in production and in tests. Source it at the top of any bash block:

```bash
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PLUGIN_ROOT/lib/setup-core.sh"
```

---

## Phase 1 — Pre-clone (runs from anywhere)

### Step P1.1: Required tools

```bash
set -euo pipefail
command -v git >/dev/null 2>&1 || { echo "git is required. Install it (macOS: brew install git, Linux: apt install git or equivalent) and re-run."; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "awk is required (every Unix has it; if missing, install via your package manager)."; exit 1; }
```

### Step P1.2: Ask where to create the vault

Print exactly:

> Welcome to **Flash Vault**. I'll set up a local Flash-Vault clone for you so the AI loads the right Flash context for *your* work at the start of every session.
>
> Where should I create your vault? Default is `~/flash-vault/` — press enter to accept or type a different path.

Wait for the user's response. Default to `~/flash-vault/`. Expand `~` to `$HOME`. Store in shell variable `VAULT`.

### Step P1.3: Refuse on existing setup or partial setup

```bash
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PLUGIN_ROOT/lib/setup-core.sh"
fv_check_existing_path "$VAULT"
```

Three states are detected and handled inside the lib:
1. Full + verified Flash-Vault setup → message + exit 0.
2. Partial / corrupted setup (any of 4 files missing) → recovery command + exit 0.
3. Non-empty unrelated directory → refuse + exit 1.

If none of the above match, the function returns and the skill continues.

### Step P1.4: Clone

```bash
fv_clone "$VAULT"
cd "$VAULT"
```

Auth handling: `GIT_TERMINAL_PROMPT=0` + `GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"` make any credential prompt fail fast instead of stealing stdin from the conversation. Failure prints concrete remediation commands.

### Step P1.5: Verify clone

```bash
fv_verify_clone
```

Asserts origin remote points to Flashie-AI/Flash-Vault AND `templates/personal/*-template.md` exist. Cleans up `$VAULT` on failure.

---

## Phase 2 — In-clone (runs from inside the freshly cloned repo)

### Part 1: Welcome + Turn 1

Print exactly:

> Vault cloned to `$VAULT`. Now I'll set up your personal space inside it so the AI loads context calibrated to your work. This takes one short conversation, then I'll generate `personal/identity.md` and `personal/tasks.md`, seed `drafts/`, replace the dev-mode `CLAUDE.md` at the vault root with your per-contributor brief, and mark `CLAUDE.md` skip-worktree so it stays local.
>
> First — tell me about yourself. What do you do at Flash, which product line(s) do you spend most of your time in, which squad(s) are you on, and what are you focused on right now?

Then **wait** for the user's response. Do not interrupt with follow-ups in the same message.

### Part 2: Signal extraction (silent — no model output)

After the Turn 1 response, extract these signals from the user's message.

Read the canonical product-line slug list from the cloned repo at runtime — do NOT hardcode it:

```bash
CANONICAL_LINES=$(fv_list_canonical_lines)   # one slug per line
CANONICAL_SQUADS=$(fv_list_canonical_squads)  # one slug per line
```

`fv_list_canonical_lines` returns the basenames of `product/lines/*.md`. If that directory is empty, the lib refuses to proceed (a maintainer must seed lines first).
`fv_list_canonical_squads` returns the basenames of `product/squads/*.md`. Empty list = no squads defined yet, in which case the user simply leaves squads empty.

| Signal | What to extract | Notes |
|---|---|---|
| Name | "I'm X" / "my name is X" / context | Required — never default. If absent: ask in Part 3.2. |
| Role | PM / designer / engineer / data / researcher / ops / lead | Required — never default. |
| Primary line(s) | One or more slugs from `$CANONICAL_LINES` | Required — never default. NEVER invent new line slugs. Validate with `fv_validate_lines "$FV_LINES"`; on failure, re-ask with the canonical list shown. |
| Squad(s) | One or more slugs from `$CANONICAL_SQUADS` | Optional — leave empty if not on any squad. NEVER invent new squad slugs. Validate with `fv_validate_squads "$FV_SQUADS"`; on failure, re-ask with the canonical list shown. |
| Current focus | What they said about "right now" / "this quarter" | May remain empty if the user declines to share. |
| Personality / tone | The shape of their message — terse, verbose, formal, blunt | Goes into `personal/identity.md` "How I prefer the AI to talk to me" subsection ONLY. NOT into CLAUDE.md — that file is procedural-only (the AI reads identity.md to learn tone, so duplicating it would risk drift). |

This skill sets up a team vault. It MUST know who the contributor is and which product line(s) they work on. There are no defaults for name, role, or product lines — if any of these are missing, ask again. Focus and personality may remain empty if the user declines to share.

Store the extracted values in shell variables for Part 3 confirmation and Part 4 generation:

```bash
FV_NAME="..."          # extracted/derived
FV_ROLE="..."
FV_LINES="..."         # space-separated slugs
FV_PRIMARY_LINE="..."  # first slug in FV_LINES
FV_SQUADS="..."        # space-separated slugs; may be empty
FV_FOCUS="..."
FV_PERSONALITY="..."
```

### Part 3: Confirm (Turn 2)

#### 3.1 Standard confirmation

> Got it. Here's what I'll set up for you:
>
> - **You:** $FV_NAME, $FV_ROLE
> - **Product lines you work on:** $FV_LINES — these load at session start
> - **Squads:** ${FV_SQUADS:-(none)}
> - **What you're focused on now:** $FV_FOCUS
> - **Your personal docs:** `personal/identity.md` (who you are, focus, tone) and `personal/tasks.md` (your TBD list) — both gitignored
> - **Your AI tone preferences:** captured in `personal/identity.md` based on how you wrote — edit anytime
>
> If any product lines or squads are wrong, tell me. Otherwise: ready to generate?

#### 3.2 Missing-required-field turns

If `FV_NAME`, `FV_ROLE`, or `FV_LINES` is empty after Part 2, ask for the missing field(s) directly. The skill cannot proceed without all three:

- Missing name: "What's your name? I need it to address you and to anchor your local `CLAUDE.md`."
- Missing role: "What do you do at Flash? (PM, designer, engineer, data, researcher, ops, lead, etc.)"
- Missing or invalid lines: print the canonical list (`fv_list_canonical_lines`) and ask the user to pick one or more from it.
- Invalid squads (non-empty but contains slug(s) not in `fv_list_canonical_squads`): print the canonical squads list and ask the user to pick one or more, or to skip. If the user replies "none", "skip", or leaves it blank, set `FV_SQUADS=""` — do NOT pass the literal string "none" through `fv_validate_squads`. Squads is optional — empty is fine, invalid is not.

After each answer, re-extract and re-validate. Only emit 3.1 once all three required fields are populated.

#### 3.3 Impatience handling — never default required fields

If the user says "ready", "go ahead", "just do it", or similar while any of `FV_NAME`, `FV_ROLE`, or `FV_LINES` is missing or invalid, do NOT substitute defaults. Acknowledge the urgency and re-ask only the missing field(s) using 3.2 prompts. Setup is blocked until all three are answered explicitly. The remaining fields (focus, personality) may be left empty if the user wants to skip them.

### Part 4: Generate (deterministic — no model decisions)

```bash
export FV_NAME FV_ROLE FV_LINES FV_PRIMARY_LINE FV_SQUADS FV_FOCUS FV_PERSONALITY
fv_generate
```

The lib handles atomic generation in this exact order (identity.md is the last-write atomic flag):

1. `mkdir -p personal drafts; touch drafts/.gitkeep`
2. `personal/tasks.md` (rendered from `templates/tasks-template.md`, `_schema:` block stripped, includes the `<!-- flash-vault:auto-managed:start -->` / `:end` markers used by `tbd-core.sh::fv_tbds_upsert`)
3. `CLAUDE.md` at repo root — overwrites the cloned dev-mode brief with the user-mode brief from `templates/personal/claude-template.md`. Includes the new "Daily commands" section listing `/process`, `/validate`, `/push-to-flash-vault`. The lib then runs `git update-index --skip-worktree CLAUDE.md` so the local user version is not tracked or pushed, and appends `/CLAUDE.md` to `.git/info/exclude` so the file is gitignored locally.
4. `personal/identity.md` (LAST — atomic flag) — merged content (Who I am / What I'm focused on / How I prefer the AI to talk to me / How I think about work). Frontmatter includes `product_lines:` and `squads:` arrays consumed by `tbd-core.sh::fv_tbds_owned_paths`.

Then verifies all 4 files exist. Failure during this step exits 1; re-run hits the partial-setup recovery branch (Step P1.3 state 2).

### Part 5: Success

```bash
fv_success "$VAULT" "$FV_LINES" "$FV_PRIMARY_LINE" "$FV_ROLE"
```

Prints the final message with concrete paths and a suggested first question to validate setup.

---

## Notes for the AI running this skill

- **Never invent line slugs.** The canonical list comes from `product/lines/*.md` in the cloned repo — read it at runtime via `fv_list_canonical_lines`. If a user names something not in that list (e.g. "security team"), record it in identity but DO NOT add to the lines list — fictional lines break the orient sequence. Re-ask with the canonical list shown.
- **Never invent squad slugs.** The canonical list comes from `product/squads/*.md` — read it via `fv_list_canonical_squads`. If the user names a squad not in that list, re-ask with the canonical list shown, or accept an empty value if they choose to skip. Fictional squad slugs produce broken wiki links in `personal/identity.md` (the rendered `[[product/squads/<slug>]]` link points at a file that doesn't exist).
- **Never default required fields.** Name, role, and product line(s) are required. Impatience signals don't waive them.
- **Never bump VERSION or edit CHANGELOG.md.** Those are developer-mode actions.
- **Never commit anything.** Generated files in `personal/` and `drafts/` are gitignored. `CLAUDE.md` is marked skip-worktree so the user version stays local without being tracked.
- **Propagate Bash failures.** If a step exits non-zero, surface it. Don't soft-recover.
- **The conversation lives in YOUR voice.** The lib handles deterministic state; you handle the language. Read `personal/identity.md` after generation completes if you want to immediately match the contributor's tone preferences for the success message.
