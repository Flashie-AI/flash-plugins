---
name: setup
description: One-time setup for Flash Vault. Clones the vault to a path you choose, then generates your personal files and a per-contributor CLAUDE.md so the AI loads Flash context calibrated to your role and product lines. Runs a two-turn conversation to collect your name, role, product line(s), squad(s), current focus, and work-style preferences — no git email inference.
---

# /flash-vault:setup

This skill runs ONCE per local clone of Flash Vault. It sets up your personal space — files under `personal/`, a personalised `CLAUDE.md` at the vault root, and a `drafts/` scratch folder. All of these stay on your machine and aren't shared with the team.

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

> Welcome to **Flash Vault** — the shared Flash knowledge base for our product team. I'll get a copy onto your machine so the AI can ground every session in real Flash context.
>
> Where should I put your vault? Default is `~/flash-vault/` — press enter to accept or type a different path.

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

The conversation has **two required turns** before generation:

- **Turn 1** — identity (name, role, lines, squads)
- **Turn 2** — focus + work style (what's on your plate, how you like to work)

Even if the user volunteers everything up front, do not collapse to a single turn. Confirm Turn-1 fields in your own words, then ask the Turn-2 follow-up. Required fields missing after Turn 2 add additional sub-turns (Part 3.2) before generation.

### Part 1: Welcome + Turn 1

Print exactly:

> Your vault is at `$VAULT`. Now let's set up your personal space inside it so the AI knows who you are and what you're working on. Everything I create in `personal/`, `drafts/`, and your `CLAUDE.md` stays on your machine — it isn't shared with the team. The shared `company/` and `product/` notes you'll touch later are the team's.
>
> First — who are you and where do you sit? Tell me your name, your role at Flash, which product line(s) you spend most of your time in, and which squad(s) you're on (if any).

Then **wait** for the user's response. Do not interrupt with follow-ups in the same message.

### Part 2a: Turn 1 extraction (silent — no model output)

After the Turn 1 response, extract identity signals. Read the canonical slug lists from the cloned repo at runtime — do NOT hardcode them:

```bash
CANONICAL_LINES=$(fv_list_canonical_lines)
CANONICAL_SQUADS=$(fv_list_canonical_squads)
```

`fv_list_canonical_lines` returns basenames of `product/lines/*.md`. Empty = the lib refuses to proceed (a maintainer must seed lines first).
`fv_list_canonical_squads` returns basenames of `product/squads/*.md`. Empty = no squads defined yet, in which case the user simply leaves squads empty.

| Signal | What to extract | Notes |
|---|---|---|
| Name | "I'm X" / "my name is X" / context | Required — never default. If absent: ask in Part 3.2. |
| Role | PM / designer / engineer / data / researcher / ops / lead | Required — never default. |
| Primary line(s) | One or more slugs from `$CANONICAL_LINES` | Required — never default. NEVER invent new line slugs. Validate with `fv_validate_lines "$FV_LINES"`; on failure, re-ask with the canonical list shown. |
| Squad(s) | One or more slugs from `$CANONICAL_SQUADS` | Optional — leave empty if not on any squad. NEVER invent new squad slugs. Validate with `fv_validate_squads "$FV_SQUADS"`; on failure, re-ask with the canonical list shown. |
| Personality / tone (running) | Shape of the message — terse, verbose, formal, blunt | Accumulate across both turns. Goes into `personal/identity.md` "How I prefer the AI to talk to me" ONLY. |

Store:

```bash
FV_NAME="..."
FV_ROLE="..."
FV_LINES="..."         # space-separated slugs
FV_PRIMARY_LINE="..."  # first slug in FV_LINES
FV_SQUADS="..."        # may be empty
FV_PERSONALITY="..."   # may be empty; refined again after Turn 2
```

### Part 2a.1: Near-match profile check

After storing the Turn 1 variables, check whether the contributor's name matches
someone who already has a profile. List the existing people:

```bash
ls company/people/*.md 2>/dev/null
```

Each filename without `.md` is a person's slug; that file's first `# ` heading is
their display name. Using your own judgment, decide whether `FV_NAME` is the same
person as any existing profile — allow for typos, nicknames, name-order
differences, and spelling or transliteration variants, not just exact matches.

Default `FV_PERSON_SLUG=""`. If you find a likely match, ask the contributor —
plain language, one question — before continuing to Turn 2:

> I found an existing profile that looks like you — **<display name>**. Is that
> you, or should I set up a new one?

- If they confirm it is them: set `FV_PERSON_SLUG` to that profile's slug (its
  filename without `.md`), and set `FV_NAME` to that profile's display name (they
  may have typed a typo of their own name).
- If they say it is someone else / a new person: leave `FV_PERSON_SLUG` empty.
- If several profiles are plausible: list the display names, let them pick one or
  say none.

Store:

```bash
FV_PERSON_SLUG="..."   # the matched slug, or empty if no match was confirmed
```

### Part 2b: Turn 2 — focus + work style

Print exactly:

> Got it — $FV_NAME, $FV_ROLE on $FV_LINES${FV_SQUADS:+ in $FV_SQUADS}.
>
> Now: what's on your plate right now, and how do you like to work? Mention any specific projects or focus areas you're driving — and tell me anything about your work style I should know (pace, where you want me to push back, what you want surfaced, what to avoid). Skip whichever you'd rather fill in later.

Then **wait** for the user's response. After it lands, extract:

| Signal | What to extract | Notes |
|---|---|---|
| Current focus | Project / goal / theme they mentioned | Goes into `personal/identity.md` "What I'm focused on now". May remain empty. |
| Projects mentioned | Slug-like project names | Validate against `product/projects/*.md`. Missing ones become draft stubs (see Part 4). |
| Work style | How they like to work — pace, comms cadence, what to push back on, anything else | Goes into `personal/identity.md` "How I think about work". May remain empty (a prompt line is left in its place). |
| Personality / tone (refine) | Continue from Turn 1 | Final shape goes into "How I prefer the AI to talk to me". |

Store:

```bash
FV_FOCUS="..."                # prose; may be empty
FV_PROJECTS_MENTIONED="..."   # space-separated slugs; may be empty
FV_WORK_STYLE="..."           # prose; may be empty
FV_PERSONALITY="..."          # refined
```

This skill MUST know who the contributor is and which product line(s) they work on. Defaults for name, role, or product lines are forbidden — if any of these are missing after Turn 1, ask again (Part 3.2). Focus, work style, projects, and personality may remain empty if the user declines to share.

### Part 3: Confirm (Turn 3 — confirmation only)

#### 3.1 Standard confirmation

> Here's what I'll set up:
>
> - **You:** $FV_NAME, $FV_ROLE
> - **Product lines you work on:** $FV_LINES — these load at session start
> - **Squads:** ${FV_SQUADS:-(none)}
> - **What you're focused on now:** ${FV_FOCUS:-(blank — you can fill it in later)}
> - **Work style:** ${FV_WORK_STYLE:-(blank — you can fill it in later)}
> - **Your personal files:** `personal/identity.md`, `personal/tasks.md`, your `CLAUDE.md`, and a `drafts/` scratch folder — all stay on your machine
> - **Your profile:** if you confirmed an existing profile above, I'll link your personal files to it; otherwise I'll create a new profile note for you under `company/people/`
> - **Draft stubs** in `drafts/` for any projects you mentioned that don't have a vault note yet — run `/process` on them later to file them properly
>
> Anything wrong? Otherwise: ready to generate?

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
export FV_NAME FV_ROLE FV_LINES FV_PRIMARY_LINE FV_SQUADS FV_PERSON_SLUG
export FV_FOCUS FV_WORK_STYLE FV_PERSONALITY FV_PROJECTS_MENTIONED
fv_generate
```

The lib handles atomic generation in this order (identity.md is the last-write atomic flag):

1. `mkdir -p personal drafts; touch drafts/.gitkeep`
2. **Person stub** — if `company/people/<slug>.md` doesn't exist for the user (slug derived from `FV_NAME` via `fv_slugify`), render a stub from `templates/person-template.md` with role/team/squads filled in. The file is untracked locally; the user ships it via `/push-to-flash-vault` when ready.
3. **Project draft stubs** — for each slug in `FV_PROJECTS_MENTIONED`, if `product/projects/<slug>.md` is missing AND no `drafts/project-<slug>.md` is pending, drop a one-line stub draft for `/process` to file later.
4. `personal/tasks.md` (rendered from `templates/tasks-template.md`, `_schema:` block stripped, includes the `<!-- flash-vault:auto-managed:start -->` / `:end` markers used by `tbd-core.sh::fv_tbds_upsert`)
5. `CLAUDE.md` at repo root — the user-mode brief rendered from `templates/personal/claude-template.md`. The lib runs `git update-index --skip-worktree CLAUDE.md` and appends `/CLAUDE.md` to `.git/info/exclude` so the user's local brief stays on their machine and isn't fought by `git pull`. (These are implementation details — don't surface them to the user.)
6. `personal/identity.md` (LAST — atomic flag) — Who I am (with `[[company/people/<slug>]]` profile link) / What I'm focused on now / How I prefer the AI to talk to me / How I think about work (filled from `FV_WORK_STYLE`, or a prompt line if empty). Frontmatter includes `product_lines:` and `squads:` arrays consumed by `tbd-core.sh::fv_tbds_owned_paths`.

Then verifies all 4 expected files exist. Failure during this step exits 1; re-run hits the partial-setup recovery branch (Step P1.3 state 2).

### Part 5: Success

```bash
fv_success "$VAULT" "$FV_LINES" "$FV_PRIMARY_LINE" "$FV_ROLE"
```

Prints the final message with concrete paths and a suggested first question to validate setup.

---

## Notes for the AI running this skill

- **Never invent line slugs.** The canonical list comes from `product/lines/*.md` in the cloned repo — read it at runtime via `fv_list_canonical_lines`. If a user names something not in that list (e.g. "security team"), record it in identity but DO NOT add to the lines list — fictional lines break the orient sequence. Re-ask with the canonical list shown.
- **Never invent squad slugs.** The canonical list comes from `product/squads/*.md` — read it via `fv_list_canonical_squads`. If the user names a squad not in that list, re-ask with the canonical list shown, or accept an empty value if they choose to skip. Fictional squad slugs produce broken wiki links in `personal/identity.md`.
- **Always run both turns.** Turn 1 collects identity; Turn 2 collects focus + work style. Do not collapse to a single turn even if the user volunteers everything up front — Turn 2 lets the user think about work style separately and surfaces project mentions that need stub drafts.
- **Project slugs you pull from Turn 2 must be kebab-case.** Pass them in `FV_PROJECTS_MENTIONED` (space-separated). The lib decides which need stub drafts based on what already exists in `product/projects/` and `drafts/`.
- **Never default required fields.** Name, role, and product line(s) are required. Impatience signals don't waive them. Focus and work style may legitimately be left empty.
- **Never bump VERSION or edit CHANGELOG.md.** Those are developer-mode actions.
- **Never commit anything.** Personal files stay local; the person stub under `company/people/` and any project drafts under `drafts/` are left untracked for the user to ship later via `/push-to-flash-vault`.
- **Don't surface plumbing.** Phrases like "skip-worktree", "gitignored", "overwrite dev-mode CLAUDE.md" are internals — keep them out of user-facing text. The user only needs to know their personal files stay on their machine.
- **Propagate Bash failures.** If a step exits non-zero, surface it. Don't soft-recover.
- **The conversation lives in YOUR voice.** The lib handles deterministic state; you handle the language. Read `personal/identity.md` after generation completes if you want to immediately match the contributor's tone preferences for the success message.
