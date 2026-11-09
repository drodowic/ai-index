#!/usr/bin/env bash
# Optional performance benchmark; --check enforces a five-second limit per run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATUS="${ROOT}/skills/ai-index/scripts/repo-status.sh"
case "${1:-}" in
    '') CHECK=0 ;;
    --check) CHECK=1 ;;
    *) echo 'usage: bench-repo-status.sh [--check]' >&2; exit 1 ;;
esac
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-index-bench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}/.config/opencode" "${TMP}/vault/repos/demo" "${TMP}/repos/demo/src"
cat >"${HOME}/.config/opencode/ai-index.env" <<EOF
AI_INDEX_DOCS_ROOT='${TMP}/vault'
AI_INDEX_GIT_ROOT='${TMP}/repos'
EOF

cd "${TMP}/repos/demo"
git init -q
git config user.name 'ai-index benchmark'
git config user.email 'ai-index-benchmark@example.invalid'
for i in $(seq -w 1 250); do printf 'source %s\n' "$i" >"src/source-${i}.txt"; done
printf 'common source\n' >src/common.txt
git add .
git commit -qm initial
shas=("$(git rev-parse HEAD)")
for i in $(seq 1 20); do
    printf 'update\n' >>"src/source-$(printf '%03d' "$i").txt"
    git add .
    git commit -qm "source update ${i}"
    shas+=("$(git rev-parse HEAD)")
done
for i in $(seq 1 250); do
    n="$(printf '%03d' "$i")"
    cat >"${TMP}/vault/repos/demo/note-${n}.md" <<EOF
---
repo: demo
sha: "${shas[i%21]}"
sources:
  - "src/source-${n}.txt"
  - "src/common.txt"
related:
  - another-repo
---
EOF
done
printf 'staged\n' >>src/source-099.txt
git add src/source-099.txt
printf 'unstaged\n' >>src/source-100.txt

# Match the plugin's actual subprocess timeout and measure complete digest delivery.
node - "$STATUS" "${TMP}/repos/demo" "$CHECK" <<'JS'
const { execFile } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const { promisify } = require('node:util');
const run = promisify(execFile);
const [script, repo, check] = process.argv.slice(2);

(async () => {
  let slow = false;
  for (let i = 0; i < 3; i++) {
    const start = performance.now();
    const { stdout } = await run('bash', [script, repo], { timeout: 10_000 });
    const elapsed = performance.now() - start;
    const match = stdout.match(/freshness: (\d+) fresh, (\d+) needing review/);
    if (!match || Number(match[1]) + Number(match[2]) !== 250 || !stdout.includes('related: another-repo')) {
      throw new Error('status digest was incomplete');
    }
    console.log(`run ${i + 1}: ${(elapsed / 1000).toFixed(2)}s`);
    if (elapsed >= 5000) slow = true;
  }
  if (check === '1' && slow) throw new Error('five-second benchmark target exceeded');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
JS
