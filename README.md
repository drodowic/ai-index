# ai-index

Shareable OpenCode ai-index skill and plugin files. The index notes themselves stay in
the user's Obsidian vault; this repository contains only the skill, scripts, and plugin.

## Contents

- `skills/ai-index/` — skill instructions and maintenance scripts.
- `plugins/ai-index/` — plugin and its package metadata.
- `ai-index.env.example` — starter configuration for each user's machine.

## Install or update

Run the installer from this checkout to copy the skill and plugin into the global OpenCode
directories. It installs missing directories and updates existing ones. `OPENCODE_CONFIG_DIR`
can override the default `~/.config/opencode` destination:

```bash
./install.sh
```

If the plugin directory is not referenced in `opencode.json` or `opencode.jsonc` using an
absolute or config-relative path, the installer prints a registration entry to merge into
the existing `plugins` array. It does not edit that config file. OpenCode V2 does not
automatically discover arbitrary directories under the global plugins folder.

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

To register the installed plugin, add its directory to the `plugins` array in
`~/.config/opencode/opencode.json(c)`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    {
      "package": "/absolute/path/to/.config/opencode/plugins/ai-index"
    }
  ]
}
```

Merge the entry into the existing configuration and preserve its other settings. The
plugin package declares `@opencode/plugin` 2.2.0 to match the V2 service API.

## OpenCode compatibility

The included plugin uses the V2 plugin API. It injects the repo-status digest and reminds
the assistant to check notes before source review. The plugin is read-only: the ai-index
skill remains responsible for recording significant durable findings. The skill and
scripts are independent of the plugin API.

## Note quality and freshness

Keep notes concise and behavioral: state what happens, when, and important exceptions;
support claims with relevant source paths, and cite tests only when an inspected test clarifies
the behavior. Label inference and dated observations. Link related notes instead of duplicating
deep dives. The 150-line overview and 200-line area limits are ceilings, not targets.

Freshness is a change-history check, not semantic verification. `fresh` means the scripts found
no committed or uncommitted changes under the note's declared `sources`; it does not prove the
claims are correct or that the source list is complete. Each source path must match tracked
content at the recorded commit; a typo or absent path is `UNVERIFIED`. `STALE` means committed
source changes; `DIRTY` means staged, unstaged, or non-ignored untracked source changes.
Git-ignored artifacts such as generated dependencies do not count; `STALE+DIRTY` reports both.
`UNVERIFIABLE` means the recorded commit is missing or not an ancestor of `HEAD`. `UNVERIFIED`
means metadata/source-path validation failed or a Git check could not be trusted. Cross-repo
evidence must be checked in the other repo when a task relies on it; `related:` is navigation,
not verification. `note-touch.sh` refuses to stamp a note while declared sources are dirty, but
the reviewer must still verify all retained claims before stamping.

## Tests and evaluation

Run the isolated shell tests with:

```bash
bash skills/ai-index/tests/test-freshness.sh
```

The tests use temporary Git repositories, config, and vault data; they require Bash, Git, `jq`,
and mikefarah `yq` v4 or newer, and do not access the network or the configured user vault.
Paired accuracy evaluation was not run in this implementation pass. No personal-vault evaluation
data is included in this repository.
