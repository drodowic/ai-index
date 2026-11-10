// ai-index — OpenCode V2 plugin.
//
// Add the current repo-status digest and a short ai-index workflow reminder to every
// session model request. Durable index notes are written by the ai-index skill, not
// by this plugin.

import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Plugin } from '@opencode/plugin';

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const STATUS_SCRIPT = join(here, '..', '..', 'skills', 'ai-index', 'scripts', 'repo-status.sh');
const AUXILIARY_SESSION_HOOKS = ['compaction', 'generate', 'title'];
const STATUS_UNAVAILABLE = '[ai-index] status unavailable. Run the ai-index status check before trusting notes.';
const AI_INDEX_GUIDANCE = [
  'ai-index workflow: Before analyzing or re-reviewing repository code for information, check the ai-index status and read applicable notes first.',
  'Read fresh notes before their source files. For stale notes, start with recorded sources and follow newly relevant dependencies only as needed to verify claims; add them to sources. For unverifiable notes, verify claims against current sources, expanding from recorded sources as needed, and restamp only after verification.',
  'For cross-repo contracts, check the relevant related-repo note and status; if no fresh note exists, inspect that repo\'s specific contract. A local note SHA does not verify another repo.',
  'After non-trivial investigation, record significant durable findings with the ai-index skill and run note-touch.sh. Skip one-off findings.',
].join(' ');

async function computeDigest(target) {
  try {
    const { stdout } = await execFileAsync('bash', [STATUS_SCRIPT, target], {
      timeout: 10_000,
      // repo-status.sh loads ~/.config/opencode/ai-index.env. DOCS_ROOT points
      // directly at ai-index/, and inherited environment values can override its defaults.
      env: process.env,
    });
    return stdout.trim() || STATUS_UNAVAILABLE;
  } catch {
    return '[ai-index] status unavailable (Git check failed or timed out). Run the ai-index status check before trusting notes.';
  }
}

export default Plugin.define({
  id: 'ai-index',

  async setup(ctx) {
    const sessionTargets = new Map();
    const sessionDigests = new Map();
    const sessionStatusRequests = new Map();

    async function targetForSession(sessionID) {
      const knownTarget = sessionTargets.get(sessionID);
      if (knownTarget) return knownTarget;

      try {
        const session = await ctx.session.get({ sessionID });
        const target = resolve(session.location.directory);
        sessionTargets.set(sessionID, target);
        return target;
      } catch {
        // Preserve best-effort context injection if the session is no longer
        // available or its location cannot be resolved.
        const target = resolve(ctx.location.directory);
        sessionTargets.set(sessionID, target);
        return target;
      }
    }

    async function addAiIndexContext(event, refreshStatus) {
      const target = await targetForSession(event.sessionID);
      let digest;
      if (refreshStatus) {
        // `context` is the primary agent loop hook and runs before each model
        // request, including tool-driven continuations. Never reuse its prior
        // result here: Git and note metadata are checked once per request.
        const request = {};
        sessionStatusRequests.set(event.sessionID, request);
        sessionDigests.set(event.sessionID, { directory: target, digest: STATUS_UNAVAILABLE });
        digest = await computeDigest(target);
        if (
          sessionStatusRequests.get(event.sessionID) === request &&
          sessionTargets.get(event.sessionID) === target
        ) {
          sessionDigests.set(event.sessionID, { directory: target, digest });
        }
      } else {
        // Auxiliary requests may reuse the latest primary result, but must not
        // fall back to setup-time or previous-location status.
        const current = sessionDigests.get(event.sessionID);
        digest = current?.directory === target ? current.digest : STATUS_UNAVAILABLE;
      }
      const text = digest
        ? `${AI_INDEX_GUIDANCE}\n\nCurrent ai-index status:\n${digest}`
        : AI_INDEX_GUIDANCE;
      event.system.push({ type: 'text', text });
    }

    // Refresh before every primary agent-loop request. Auxiliary model calls
    // reuse that session's latest result rather than repeating Git work.
    await ctx.session.hook('context', (event) => addAiIndexContext(event, true));
    for (const kind of AUXILIARY_SESSION_HOOKS) {
      await ctx.session.hook(kind, (event) => addAiIndexContext(event, false));
    }

    const controller = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          types: ['session.created', 'session.moved', 'session.deleted'],
          signal: controller.signal,
        })) {
          if (event.type === 'session.deleted') {
            sessionTargets.delete(event.data.sessionID);
            sessionDigests.delete(event.data.sessionID);
            sessionStatusRequests.delete(event.data.sessionID);
            continue;
          }

          const { sessionID, location } = event.data;
          const directory = resolve(location.directory);
          const previousDirectory = sessionTargets.get(sessionID);
          sessionTargets.set(sessionID, directory);
          if (previousDirectory !== directory) {
            sessionDigests.delete(sessionID);
            sessionStatusRequests.delete(sessionID);
          }
        }
      } catch {
        // An unavailable or closing event stream must not affect chat turns.
      }
    })();

    return () => controller.abort();
  },
});
