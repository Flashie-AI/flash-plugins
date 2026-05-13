# Changelog

All notable changes to the `flash-plugins` marketplace.

Versioning note: pre-0.1.1 commits in this repo were internally labeled `0.2.0`
(inherited from the vault's old manifest) but were never published. `0.1.1` is
the first real release.

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
