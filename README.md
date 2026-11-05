# ai-index

Shareable OpenCode ai-index skill and plugin files. The index notes themselves stay in
the user's Obsidian vault; this repository contains only the skill, scripts, and plugin.

## Contents

- `skills/ai-index/` — skill instructions and maintenance scripts.
- `plugins/ai-index/` — plugin and its package metadata.
- `ai-index.env.example` — starter configuration for each user's machine.

## Local setup

The scripts load `~/.config/opencode/ai-index.env`. Copy the example there, then adjust
the roots to your own locations:

```bash
mkdir -p ~/.config/opencode
cp -n ai-index.env.example ~/.config/opencode/ai-index.env
```

`AI_INDEX_DOCS_ROOT` must point directly to the `ai-index/` directory. `AI_INDEX_GIT_ROOT`
must point to the parent directory containing your project checkouts. The scripts require
Bash, Git, `jq`, and mikefarah `yq` v4 or newer.

To install the skill and plugin into the existing global OpenCode layout, copy
`skills/ai-index/` to `~/.config/opencode/skills/ai-index/` and
`plugins/ai-index/` to `~/.config/opencode/plugins/ai-index/`.

## OpenCode compatibility

The included plugin currently uses the legacy plugin API. OpenCode V2 requires a plugin
port to the V2 API before this can be published as a V2 npm plugin. The skill and scripts
are independent of that port.
