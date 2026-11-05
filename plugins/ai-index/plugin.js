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
const SESSION_HOOKS = ['context', 'compaction', 'generate', 'title'];
const AI_INDEX_GUIDANCE = [
  'ai-index workflow: Before analyzing or re-reviewing repository code for information, check the ai-index status and read applicable notes first.',
  'Read fresh notes before their source files; for stale or unverifiable notes, re-check only their recorded sources.',
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
    return stdout.trim();
  } catch {
    return '';
  }
}

export default Plugin.define({
  id: 'ai-index',

  async setup(ctx) {
    const digests = new Map();
    const refreshes = new Map();
    const sessionTargets = new Map();
    const sessionStatusTargets = new Map();
    const initialTarget = resolve(ctx.location.directory);
    let initialSessionUsed = false;

    async function refresh(target) {
      const directory = resolve(target || ctx.location.directory);
      const previous = refreshes.get(directory);
      const pending = (async () => {
        // Serialize refreshes for one target. A session lifecycle refresh still runs
        // after an initial/on-demand refresh, even when the target is unchanged.
        if (previous) await previous;
        const digest = await computeDigest(directory);
        digests.set(directory, digest);
        return digest;
      })();

      refreshes.set(directory, pending);
      try {
        return await pending;
      } finally {
        if (refreshes.get(directory) === pending) refreshes.delete(directory);
      }
    }

    async function digestFor(target) {
      const directory = resolve(target || ctx.location.directory);
      if (refreshes.has(directory)) return refreshes.get(directory);
      if (digests.has(directory)) return digests.get(directory);
      return refresh(directory);
    }

    async function digestForSession(sessionID, target) {
      const directory = resolve(target || ctx.location.directory);
      sessionTargets.set(sessionID, directory);
      if (sessionStatusTargets.get(sessionID) === directory) return digestFor(directory);

      sessionStatusTargets.set(sessionID, directory);
      if (!initialSessionUsed && directory === initialTarget) {
        // Reuse setup's status for the first session when its session.created
        // event has not arrived yet. Later sessions in the same repo refresh.
        initialSessionUsed = true;
        return digestFor(directory);
      }

      // A session's first request (or a moved session) refreshes even if another
      // session has already cached this directory.
      if (refreshes.has(directory)) return refreshes.get(directory);
      return refresh(directory);
    }

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
        return ctx.location.directory;
      }
    }

    async function addAiIndexContext(event) {
      const target = await targetForSession(event.sessionID);
      const digest = await digestForSession(event.sessionID, target);
      const text = digest
        ? `${AI_INDEX_GUIDANCE}\n\nCurrent ai-index status:\n${digest}`
        : AI_INDEX_GUIDANCE;
      event.system.push({ type: 'text', text });
    }

    // V2 splits model requests by purpose. Register each one so the status and
    // note-first reminder are available on primary and auxiliary requests.
    for (const kind of SESSION_HOOKS) {
      await ctx.session.hook(kind, addAiIndexContext);
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
            sessionStatusTargets.delete(event.data.sessionID);
            continue;
          }

          const { sessionID, location } = event.data;
          const directory = resolve(location.directory);
          sessionTargets.set(sessionID, directory);
          sessionStatusTargets.delete(sessionID);
          await refresh(directory);
          sessionStatusTargets.set(sessionID, directory);
        }
      } catch {
        // An unavailable or closing event stream must not affect chat turns.
      }
    })();

    // Covers one-shot runs and the race where the first session event precedes
    // event dispatch. The event refreshes again for subsequent sessions, even
    // when they use this same directory.
    await refresh(initialTarget);

    return () => controller.abort();
  },
});
