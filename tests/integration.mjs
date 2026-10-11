// Opt-in network test: mise exec npm:skills@1.7.2 -- node tests/integration.mjs
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

const root = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'agent-skills-integration-'));
const env = { ...process.env, HOME: join(root, 'home'), XDG_CONFIG_HOME: join(root, 'home/.config'), XDG_DATA_HOME: join(root, 'data'), XDG_STATE_HOME: join(root, 'state'), MISE_DATA_DIR: join(root, 'data/mise'), MISE_CONFIG_DIR: join(root, 'home/.config/mise'), MISE_STATE_DIR: join(root, 'state/mise'), MISE_CACHE_DIR: join(root, 'cache'), MISE_HISTORY_SYNC: 'manual', MISE_YES: '1', DISABLE_TELEMETRY: '1' };
// Do not inherit an explicitly selected config from a developer's mise exec.
delete env.MISE_CONFIG_FILE;
const mise = (...args) => execFileSync('mise', args, { env, cwd: root, encoding: 'utf8' });
try {
  writeFileSync(join(root, 'mise.toml'), '[bootstrap.packages]\n"agent-skills:vercel-labs/agent-browser/agent-browser" = "latest"\n');
  mise('plugins', 'link', 'agent-skills', fileURLToPath(new URL('..', import.meta.url)));
  mise('trust');
  assert.match(mise('bootstrap', 'packages', 'status'), /missing/);
  mise('bootstrap', 'packages', 'install', '--dry-run');
  assert.match(mise('bootstrap', 'packages', 'status'), /missing/);
  mise('bootstrap', 'packages', 'install');
  assert.match(mise('bootstrap', 'packages', 'status'), /installed/);
  mise('bootstrap', 'packages', 'install');
  const lock = () => JSON.parse(readFileSync(join(root, 'state/skills/.skill-lock.json'), 'utf8')).skills['agent-browser'];
  const beforeUpgrade = lock().updatedAt;
  mise('bootstrap', 'packages', 'upgrade');
  assert.notEqual(lock().updatedAt, beforeUpgrade);
  assert.match(mise('bootstrap', 'packages', 'status'), /installed/);
  const commit = execFileSync('git', ['ls-remote', 'https://github.com/vercel-labs/agent-browser', 'HEAD'], { encoding: 'utf8' }).split(/\s/)[0];
  assert.match(commit, /^[0-9a-f]{40}$/);
  writeFileSync(join(root, 'mise.toml'), `[bootstrap.packages]\n"agent-skills:vercel-labs/agent-browser/agent-browser" = "${commit}"\n`);
  mise('bootstrap', 'packages', 'install');
  assert.equal(lock().ref, commit);
  assert.match(mise('bootstrap', 'packages', 'status'), /installed/);
  console.log('Real Mise hooks and skills CLI: install, dry-run, status, repeat install, upgrade, commit pin passed.');
} finally {
  if (process.env.KEEP_TEST_HOME) console.log('Test fixture:', root);
  else rmSync(root, { recursive: true, force: true });
}
