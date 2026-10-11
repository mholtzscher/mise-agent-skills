import { readFileSync, lstatSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
const fail = message => { throw new Error(message); };

export function parse(requests) {
  if (!Array.isArray(requests)) fail('packages must be an array');
  const names = new Set();
  return requests.map(request => {
    if (!object(request)) fail('invalid package request');
    const match = /^([A-Za-z0-9][A-Za-z0-9_-]*)\/([A-Za-z0-9][A-Za-z0-9_.-]*)\/([a-z0-9][a-z0-9_-]*)$/.exec(request.name);
    if (!match) fail('expected owner/repository/skill-name: ' + request.name);
    const [, owner, repo, skill] = match;
    if (names.has(skill)) fail('duplicate skill name in batch: ' + skill);
    names.add(skill);
    const ref = request.version === undefined || request.version === 'latest' ? undefined : request.version;
    if (ref !== undefined && (typeof ref !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(ref) || ref.includes('..') || ref.endsWith('/'))) {
      fail('invalid Git ref: ' + ref);
    }
    return { name: request.name, source: `${owner}/${repo}`, skill, ref };
  });
}

function lstat(path) {
  try { return lstatSync(path); } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  }
}

function isFile(path) {
  try { return statSync(path).isFile(); } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

export function manager({ home = homedir(), config = process.env.XDG_CONFIG_HOME || join(home, '.config'), state = process.env.XDG_STATE_HOME, run = args => execFileSync('skills', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, DISABLE_TELEMETRY: '1' } }) } = {}) {
  const canonicalRoot = join(home, '.agents/skills');
  const agentRoot = join(config, 'opencode/skills');
  const lockPath = state ? join(state, 'skills/.skill-lock.json') : join(home, '.agents/.skill-lock.json');

  function lock() {
    if (!lstat(lockPath)) return {};
    const data = JSON.parse(readFileSync(lockPath, 'utf8'));
    if (!object(data) || data.version !== 3 || !object(data.skills)) fail('unsupported or malformed skills lockfile: ' + lockPath);
    for (const [name, entry] of Object.entries(data.skills)) {
      if (!object(entry) || typeof entry.source !== 'string' || typeof entry.sourceType !== 'string' || (entry.ref !== undefined && typeof entry.ref !== 'string')) fail('malformed lock entry: ' + name);
    }
    return data.skills;
  }

  function inspect(p, entries) {
    const entry = entries[p.skill];
    const canonical = join(canonicalRoot, p.skill);
    if (entry && (entry.source.toLowerCase() !== p.source.toLowerCase() || entry.sourceType !== 'github')) fail('skill name belongs to another source: ' + p.skill);
    const native = lstat(canonical);
    if (native && (!entry || native.isSymbolicLink() || !native.isDirectory())) fail('skill is externally managed: ' + canonical);
    for (const target of [join(agentRoot, p.skill), join(home, '.pi/agent/skills', p.skill)]) {
      const linked = lstat(target);
      if (linked) {
        if (!entry || !linked.isSymbolicLink()) fail('agent skill is externally managed: ' + target);
        try {
          if (realpathSync(target) !== realpathSync(canonical)) fail('agent skill points elsewhere: ' + target);
        } catch (error) {
          // A dangling link needs explicit repair; never overwrite an unknown target.
          if (error.code === 'ENOENT') fail('dangling agent skill link: ' + target);
          throw error;
        }
      }
    }
    // skills 1.7.2 treats OpenCode and Pi as universal agents: both read canonicalRoot.
    const installed = entry && entry.ref === p.ref && isFile(join(canonical, 'SKILL.md'));
    return { name: p.name, state: installed ? 'installed' : 'missing', ...(installed ? { version: p.ref || entry.skillFolderHash || 'latest' } : {}) };
  }

  function writableParents(path) {
    // Check owned paths, not OS-level aliases such as macOS /var -> /private/var.
    const bases = [home, config, state].filter(Boolean);
    for (let cursor = dirname(path); ; cursor = dirname(cursor)) {
      const info = lstat(cursor);
      if (info?.isSymbolicLink()) fail('refusing a symlinked parent: ' + cursor);
      if (info && !info.isDirectory()) fail('parent is not a directory: ' + cursor);
      if (bases.includes(cursor) || cursor === dirname(cursor)) break;
    }
  }

  return (action, requests) => {
    if (!['installed', 'install', 'upgrade'].includes(action)) fail('unknown action: ' + action);
    const batch = parse(requests);
    const entries = lock();
    const statuses = batch.map(p => inspect(p, entries));
    if (action === 'installed') return { packages: statuses };
    // Preflight the whole batch before invoking a CLI that can replace files.
    writableParents(lockPath);
    if (lstat(lockPath)?.isSymbolicLink()) fail('refusing a symlinked lockfile: ' + lockPath);
    for (const p of batch) {
      writableParents(join(canonicalRoot, p.skill));
      writableParents(join(agentRoot, p.skill));
    }
    for (const [i, p] of batch.entries()) {
      if (action === 'install' && statuses[i].state === 'installed') continue;
      const source = `https://github.com/${p.source}` + (p.ref ? `#${encodeURIComponent(p.ref)}` : '');
      run(['add', source, '--skill', p.skill, '--global', '--agent', 'opencode', 'pi', '--yes']);
      if (inspect(p, lock()).state !== 'installed') fail('skills CLI did not install the requested source/ref: ' + p.name);
    }
    return {};
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    console.log(JSON.stringify(manager()(process.argv[2], JSON.parse(process.argv[3]))));
  } catch (error) {
    console.error('agent-skills: ' + error.message);
    process.exitCode = 1;
  }
}
