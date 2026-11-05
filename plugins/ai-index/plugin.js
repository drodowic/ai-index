// ai-index — opencode plugin
//
// Ports the Claude Code SessionStart hook (ai-index-session-start.sh) to opencode's
// plugin lifecycle. Claude Code injects hook stdout as hidden system context on every
// session start; opencode has no equivalent static hook, so this uses the same mechanism
// the caveman opencode plugin uses for its per-turn reinforcement line:
// `experimental.chat.system.transform`, which lets a plugin push strings onto
// `output.system` (string[]) before every LLM request.
//
// Flow:
//   event (event.type === 'session.created') → run scripts/repo-status.sh against the
//   session's directory, cache the digest text for that directory.
//   experimental.chat.system.transform → push the cached digest into the system prompt.
//
// Silent-fails everywhere: a missing `jq`/`yq`, a non-git cwd, or a script error must
// never block a session or break a chat turn — same contract as the Claude Code hook.

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const STATUS_SCRIPT = join(here, '..', '..', 'skills', 'ai-index', 'scripts', 'repo-status.sh');

async function computeDigest(target) {
  try {
    const { stdout } = await execFileAsync('bash', [STATUS_SCRIPT, target], {
      timeout: 10_000,
      // repo-status.sh loads ~/.config/opencode/ai-index.env. DOCS_ROOT points
      // directly at ai-index/, and inherited environment values can override its defaults.
      env: process.env,
    });
    return stdout.trim();
  } catch {
    return '';
  }
}

export const AiIndexPlugin = async ({ directory, worktree } = {}) => {
  let cachedDigest = '';
  let cachedForTarget = null;

  async function refresh() {
    const target = worktree || directory || process.cwd();
    if (target === cachedForTarget) return;
    cachedForTarget = target;
    cachedDigest = await computeDigest(target);
  }

  // Factory-time refresh covers one-shot `opencode run`, where the first
  // session.created can publish before plugin event dispatch is wired (same race
  // the caveman opencode plugin documents for its own session-init write).
  await refresh();

  return {
    event: async ({ event } = {}) => {
      if (event && event.type === 'session.created') await refresh();
    },

    'experimental.chat.system.transform': async (_input, output) => {
      if (!output || !Array.isArray(output.system)) return;
      if (cachedDigest) output.system.push(cachedDigest);
    },
  };
};

export default AiIndexPlugin;
