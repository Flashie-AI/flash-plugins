# Changelog

All notable changes to the `flash-plugins` marketplace.

Versioning note: pre-0.1.1 commits in this repo were internally labeled `0.2.0`
(inherited from the vault's old manifest) but were never published. `0.1.1` is
the first real release.

## [0.1.4] - 2026-05-17

### Added
- **Near-match profile detection in `/setup`.** After the contributor gives their name, the setup skill has Claude read existing `company/people/` profiles and, on a close match (a typo, nickname, or transliteration variant — e.g. "Ragab" vs an existing "Rajab"), ask the contributor to confirm before creating a duplicate profile. New `FV_PERSON_SLUG` override makes `fv_generate` link `identity.md` to the confirmed existing profile.

### Changed
- **User-facing copy is plain language.** "stub" is now "draft note" / "starter profile"; the setup skill's voice rule keeps internal jargon out of what the contributor sees. Skill references are bare (`/setup`, not `/flash-vault:setup`).

## [0.1.3] - 2026-05-13

### Added
- **Test coverage for v0.1.2 work** ([#3](https://github.com/Flashie-AI/flash-plugins/pull/3)). Seven new scenarios close the coverage gap flagged in the prior changelog:
  - `24` — `fv_slugify` handles whitespace, casing, non-alphanumeric runs.
  - `25` — `fv_create_person_if_missing` renders a stub from the person template with correct frontmatter and strips the `_schema:` block.
  - `26` — `fv_create_person_if_missing` is overwrite-safe (preserves an existing file).
  - `27` — `fv_drop_missing_project_drafts` creates a draft only for slugs that lack both a real note AND a pending draft.
  - `28` — identity.md gets a `Profile: [[company/people/<slug>]]` link and the matching person stub is created.
  - `29` — `FV_WORK_STYLE` prose renders into identity.md verbatim; no session-rhythm leakage.
  - `30` — empty `FV_WORK_STYLE` renders the editable prompt line; no unrendered `{{WORK_STYLE}}` placeholder remains.

### Fixed
- **Three pre-existing scenarios updated** to match the v0.1.2 de-jargoned copy: `02-refuse-full-setup`, `03-refuse-partial-setup`, `07-atomic-flag-recovery` now grep for the new strings (`"already have a Flash Vault set up"`, `"personal setup didn't finish"`).
- **Test fixture re-synced to Flash-Vault@0.8.1** templates (`test/fixtures/source-repo/templates/personal/identity-template.md`, `claude-template.md`). Added the previously-missing `templates/person-template.md` to the fixture — `fv_create_person_if_missing` requires it.

### Notes
- Tests + fixtures only. No lib changes, no SKILL.md changes, no schema changes. `test/setup.sh` now 30/30 (was 20/23, the 3 fails were wording-mismatches from v0.1.2).

## [0.1.2] - 2026-05-13

### Added
- **Person stub creation.** New `fv_slugify` helper and `fv_create_person_if_missing` function. During `fv_generate`, the lib derives a slug from `FV_NAME` and renders `company/people/<slug>.md` from `templates/person-template.md` (filled with role, team, squads) if no file exists at that path. Identity.md now links to the contributor's profile via `[[company/people/<slug>]]`. The file is left untracked locally so the user ships it via `/push-to-flash-vault` when ready.
- **Project draft stubs.** New `fv_drop_missing_project_drafts` function. For each slug the model passes in `FV_PROJECTS_MENTIONED`, the lib drops `drafts/project-<slug>.md` if no `product/projects/<slug>.md` exists and no draft with the same name is pending. The user runs `/process` later to file each one with the proper project schema (avoids polluting `product/projects/` with TBD-laden stubs we can't fully fill from a single setup mention).
- **Work-style field.** New env var `FV_WORK_STYLE`. Setup asks the user how they like to work during Turn 2; the answer renders into `personal/identity.md` under "How I think about work" (replacing the prior hardcoded session-rhythm text that duplicated CLAUDE.md's procedural section). Empty values render a prompt line for the user to fill in later.

### Changed
- **Setup is now a two-turn conversation.** Turn 1 collects identity (name, role, lines, squads); Turn 2 collects focus + work style + project mentions. The skill no longer collapses to a single turn even if the user volunteers everything up front — Turn 2 surfaces work-style preferences and project mentions that would otherwise be missed. Required-field re-asks (Part 3.2) still add sub-turns when name, role, or lines are missing.
- **User-facing copy de-jargoned.** Removed "dev-mode CLAUDE.md", "skip-worktree", "overwrite", and most "gitignored" mentions from `fv_check_existing_path`, `fv_success`, and the SKILL.md welcome, Phase 1, Phase 2 Part 1, and Part 5 strings. The user now sees one consistent line: "Your files in `personal/`, `drafts/`, and `CLAUDE.md` stay on your machine — they aren't shared with the team." The underlying plumbing still happens (skip-worktree is still set, `.git/info/exclude` is still updated, gitignored paths are still gitignored) — it just isn't surfaced to non-technical contributors.
- **Part 3 confirmation expanded** to list the work-style answer, the auto-created profile note, and any project draft stubs that will be dropped.
- **`fv_generate` order updated** to write the person stub and project drafts before tasks.md / CLAUDE.md / identity.md — keeps identity.md (the atomic-flag write) last.

### Notes
- Requires Flash-Vault `0.8.1`+ for `{{PERSON_SLUG}}` and `{{WORK_STYLE}}` placeholders in `templates/personal/identity-template.md`. Older vault clones will leave those placeholders unrendered.
- Test harness (`test/setup.sh`) does not yet cover the new functions, the two-turn flow, or the new env vars. Tests need updating before this version is published.

## [0.1.1] - 2026-05-13

### Removed
- **Email-based autodetect.** Deleted `fv_autodetect`, `fv_match_email`, `fv_yaml_field` (all orphans after the autodetect removal). Setup is now purely conversational — the skill no longer reads `git config user.email` or inspects `company/people/*.md` for matches. Contributors are asked for name, role, product lines, and squad(s).

### Added
- **Plural-squad plumbing.** New env var `FV_SQUADS` (space-separated slug list, mirrors `FV_LINES`). New helpers `fv_list_canonical_squads`, `fv_validate_squads`, `fv_build_squads_inline`. `fv_generate` now renders `squads: [a, b]` in YAML and `[[product/squads/a]], [[product/squads/b]]` as wiki links in `personal/identity.md`.
- **MOC-file exclusion** in `fv_list_canonical_lines` and the new `fv_list_canonical_squads`: files whose basename matches the parent directory name (e.g. `product/lines/lines.md`, `product/squads/squads.md`) are skipped so they can't be mistaken for canonical slugs.
- **Whitespace normalization** for `FV_LINES` and `FV_SQUADS` before YAML render (trims surrounding whitespace and collapses internal runs, preventing malformed `squads: [a, b, ]` output if the caller passes a trailing space).
- **`CHANGELOG.md`** at marketplace root (this file).

### Fixed
- **zsh word-splitting.** `setopt SH_WORD_SPLIT` guarded by `ZSH_VERSION` at the top of `lib/setup-core.sh`. Claude Code's Bash tool sources the lib under zsh, where `for x in $var` doesn't word-split by default — that bug had produced malformed wiki links like `[[product/lines/financial-wellness bill-payments]]` and a confusing "Invalid product line slug(s)" message on valid input.
- **Stale overlay-file count** in lib header and `fv_check_existing_path` log messages (`6 overlay files` → `4`) — reflects the actual 4-file overlay (`personal/identity.md`, `personal/tasks.md`, `CLAUDE.md`, `drafts/.gitkeep`).
