# flash-plugins

Claude Code marketplace for Flashie-AI plugins.

## Plugins

| Plugin | Description |
|---|---|
| [`flash-vault`](plugins/flash-vault/) | Per-contributor setup for [Flash Vault](https://github.com/Flashie-AI/Flash-Vault). Clones the private vault repo to a path you choose, then generates `personal/` files and a per-user `CLAUDE.md` so the AI loads Flash context calibrated to your role and product lines. |

## Install

```text
/plugin marketplace add Flashie-AI/flash-plugins
/plugin install flash-vault@flash-plugins
/setup
```

You need read access to `Flashie-AI/Flash-Vault` (private) on the GitHub account configured in your local git. The `setup` skill clones the vault using your SSH / HTTPS credentials.

## Local development

Iterate on the plugin against a local clone:

```text
/plugin marketplace add /path/to/flash-plugins
/plugin install flash-vault@flash-plugins
```

After editing skills or lib, `/plugin marketplace update flash-plugins` then reinstall to pick up changes.
