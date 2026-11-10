import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

test('refreshes primary status and never reuses stale status after a failed check', async () => {
  const tempRoot = mkdtempSync(join(tmpdir(), 'ai-index-plugin-'));
  const originalHome = process.env.HOME;
  let cleanup;

  try {
    const repo = join(tempRoot, 'git', 'sample');
    const docsRoot = join(tempRoot, 'docs');
    const home = join(tempRoot, 'home');
    const configDir = join(home, '.config', 'opencode');
    const note = join(docsRoot, 'repos', 'sample', 'overview.md');
    const scripts = join(repoRoot, 'skills', 'ai-index', 'scripts');
    const pluginDir = join(tempRoot, 'plugins', 'ai-index');
    const statusScripts = join(tempRoot, 'skills', 'ai-index', 'scripts');
    const pluginSource = readFileSync(join(repoRoot, 'plugins', 'ai-index', 'plugin.js'), 'utf8');

    mkdirSync(join(repo, 'src'), { recursive: true });
    mkdirSync(dirname(note), { recursive: true });
    mkdirSync(configDir, { recursive: true });
    mkdirSync(statusScripts, { recursive: true });
    mkdirSync(pluginDir, { recursive: true });
    mkdirSync(join(tempRoot, 'node_modules', '@opencode', 'plugin'), { recursive: true });
    writeFileSync(join(tempRoot, 'package.json'), '{"type":"module"}\n');
    writeFileSync(join(tempRoot, 'node_modules', '@opencode', 'plugin', 'package.json'),
      '{"name":"@opencode/plugin","type":"module","exports":"./index.js"}\n');
    writeFileSync(join(tempRoot, 'node_modules', '@opencode', 'plugin', 'index.js'),
      'export const Plugin = { define: (definition) => definition };\n');
    writeFileSync(join(pluginDir, 'package.json'), '{"type":"module"}\n');
    writeFileSync(join(pluginDir, 'plugin.js'), pluginSource);
    cpSync(scripts, statusScripts, { recursive: true });

    execFileSync('git', ['init', '-q', '-b', 'main', repo]);
    execFileSync('git', ['-C', repo, 'config', 'user.name', 'ai-index test']);
    execFileSync('git', ['-C', repo, 'config', 'user.email', 'ai-index-test@example.invalid']);
    writeFileSync(join(repo, 'src', 'source.txt'), 'initial\n');
    execFileSync('git', ['-C', repo, 'add', 'src/source.txt']);
    execFileSync('git', ['-C', repo, 'commit', '-qm', 'initial source']);
    const baseline = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    writeFileSync(join(configDir, 'ai-index.env'),
      `AI_INDEX_DOCS_ROOT="${docsRoot}"\nAI_INDEX_GIT_ROOT="${join(tempRoot, 'git')}"\n`);
    writeFileSync(note, `---\nrepo: sample\nsha: ${baseline}\nsources:\n  - src/source.txt\n---\n# Overview\n`);
    process.env.HOME = home;

    const plugin = (await import(pathToFileURL(join(pluginDir, 'plugin.js')).href)).default;
    const hooks = new Map();
    const context = {
      location: { directory: repo },
      session: {
        hook: async (kind, handler) => hooks.set(kind, handler),
        get: async () => ({ location: { directory: repo } }),
      },
      event: {
        subscribe: ({ signal }) => ({
          async *[Symbol.asyncIterator]() {
            await new Promise((done) => signal.addEventListener('abort', done, { once: true }));
          },
        }),
      },
    };
    cleanup = await plugin.setup(context);

    const request = async (kind) => {
      const event = { sessionID: 'session-1', system: [] };
      await hooks.get(kind)(event);
      return event.system.at(-1).text;
    };

    const beforePrimary = await request('generate');
    assert.match(beforePrimary, /status unavailable/);
    assert.match(beforePrimary, /before trusting notes/);
    assert.match(beforePrimary, /start with recorded sources and follow newly relevant dependencies/);
    assert.match(beforePrimary, /verify claims against current sources/);
    assert.match(beforePrimary, /restamp only after verification/);

    assert.match(await request('context'), /notes: overview/);
    writeFileSync(join(repo, 'src', 'source.txt'), 'committed change\n');
    execFileSync('git', ['-C', repo, 'add', 'src/source.txt']);
    execFileSync('git', ['-C', repo, 'commit', '-qm', 'change source']);

    const refreshed = await request('context');
    assert.match(refreshed, /STALE: overview/);
    assert.match(await request('generate'), /STALE: overview/);

    unlinkSync(join(configDir, 'ai-index.env'));
    const unavailable = await request('context');
    assert.match(unavailable, /status unavailable/);
    assert.match(unavailable, /before trusting notes/);
    assert.doesNotMatch(unavailable, /STALE: overview/);
    assert.match(await request('compaction'), /status unavailable/);
  } finally {
    cleanup?.();
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    rmSync(tempRoot, { recursive: true, force: true });
  }
});
