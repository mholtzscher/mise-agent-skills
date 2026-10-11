import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { manager, parse } from '../lib/skills.mjs';

function fixture(t) {
  const home = mkdtempSync(join(tmpdir(), 'agent-skills-'));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const canonical = join(home, '.agents/skills/demo');
  const agent = join(home, '.config/opencode/skills/demo');
  const calls = [];
  function installed(source = 'owner/repo', ref) {
    mkdirSync(canonical, { recursive: true });
    mkdirSync(join(home, '.config/opencode/skills'), { recursive: true });
    writeFileSync(join(canonical, 'SKILL.md'), 'fixture');
    rmSync(agent, { force: true });
    symlinkSync(canonical, agent);
    writeFileSync(join(home, '.agents/.skill-lock.json'), JSON.stringify({ version: 3, skills: { demo: { source, sourceType: 'github', ref, skillFolderHash: 'abc123' } } }));
  }
  const run = args => { calls.push(args); installed('owner/repo', args[1].includes('#') ? decodeURIComponent(args[1].split('#')[1]) : undefined); };
  return { home, canonical, agent, calls, installed, invoke: manager({ home, config: join(home, '.config'), state: '', run }) };
}
const request = [{ name: 'owner/repo/demo', version: 'latest' }];

test('install verifies native state, skips satisfied skills, upgrades selected skill', t => {
  const f = fixture(t);
  assert.equal(f.invoke('installed', request).packages[0].state, 'missing');
  f.invoke('install', request);
  f.invoke('install', request);
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0], ['add', 'https://github.com/owner/repo', '--skill', 'demo', '--global', '--agent', 'opencode', 'pi', '--yes']);
  f.invoke('upgrade', request);
  assert.equal(f.calls.length, 2);
});
test('ref changes reinstall and branch refs stay single arguments', t => {
  const f = fixture(t); f.installed();
  const pinned = [{ name: 'owner/repo/demo', version: 'feature/skills' }];
  assert.equal(f.invoke('installed', pinned).packages[0].state, 'missing');
  f.invoke('install', pinned);
  assert.equal(f.calls[0][1], 'https://github.com/owner/repo#feature%2Fskills');
  assert.equal(f.invoke('installed', pinned).packages[0].version, 'feature/skills');
});
test('refuses another source and unowned directories before mutation', t => {
  const f = fixture(t); f.installed('other/repo');
  assert.throws(() => f.invoke('upgrade', request), /another source/);
  rmSync(join(f.home, '.agents/.skill-lock.json'));
  assert.throws(() => f.invoke('install', request), /externally managed/);
  assert.equal(f.calls.length, 0);
});
test('universal agents need no link; conflicting legacy links are refused', t => {
  const f = fixture(t); f.installed(); rmSync(f.agent);
  assert.equal(f.invoke('installed', request).packages[0].state, 'installed');
  symlinkSync(f.home, f.agent);
  assert.throws(() => f.invoke('upgrade', request), /points elsewhere/);
});
test('malformed lock does not masquerade as missing', t => {
  const f = fixture(t); f.installed();
  writeFileSync(join(f.home, '.agents/.skill-lock.json'), '{"version":4,"skills":{}}');
  assert.throws(() => f.invoke('installed', request), /unsupported/);
});
test('rejects traversal, shell syntax and colliding names', () => {
  for (const name of ['a/b/../c', 'a/b/$(id)', 'a/b/*']) assert.throws(() => parse([{ name }]), /expected/);
  assert.throws(() => parse([{ name: 'a/b/demo', version: 'x;touch /tmp/foo' }]), /invalid Git ref/);
  assert.throws(() => parse([...request, { name: 'other/repo/demo' }]), /duplicate/);
});
test('success exit without installing is an error', t => {
  const f = fixture(t);
  const invoke = manager({ home: f.home, config: join(f.home, '.config'), state: '', run: () => '' });
  assert.throws(() => invoke('install', request), /did not install/);
});
test('symlinked parent cannot receive installs', t => {
  const f = fixture(t);
  mkdirSync(join(f.home, 'elsewhere')); symlinkSync(join(f.home, 'elsewhere'), join(f.home, '.agents'));
  assert.throws(() => f.invoke('install', request), /symlinked parent/);
  assert.equal(f.calls.length, 0);
});
test('XDG state lockfile is used instead of the default location', t => {
  const f = fixture(t); f.installed();
  const state = join(f.home, 'state');
  mkdirSync(join(state, 'skills'), { recursive: true });
  writeFileSync(join(state, 'skills/.skill-lock.json'), JSON.stringify({ version: 3, skills: { demo: { source: 'other/repo', sourceType: 'github' } } }));
  const invoke = manager({ home: f.home, config: join(f.home, '.config'), state });
  assert.throws(() => invoke('installed', request), /another source/);
});
test('batch preflight stops before installing an earlier valid entry', t => {
  const f = fixture(t); f.installed('other/repo');
  assert.throws(() => f.invoke('install', [{ name: 'owner/repo/valid' }, ...request]), /another source/);
  assert.equal(f.calls.length, 0);
});
test('Nix-style links cannot be replaced even with matching lock metadata', t => {
  const f = fixture(t); f.installed();
  rmSync(f.canonical, { recursive: true }); symlinkSync('/nix/store/nonexistent-skill', f.canonical);
  assert.throws(() => f.invoke('upgrade', request), /externally managed/);
  assert.equal(f.calls.length, 0);
});
