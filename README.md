# mise-agent-skills

Mise package-manager plugin for GitHub agent skills, installed globally for
OpenCode and Pi through Vercel's `skills` CLI. Requires Mise package-plugin
support (tested with 2026.10.8), Node, Git, and `skills` 1.7.2 (lock format 3).

```toml
[tools]
node = "24"
"npm:skills" = "1.7.2"

[bootstrap.plugins]
agent-skills = "https://github.com/mholtzscher/mise-agent-skills"

[bootstrap.packages]
"agent-skills:vercel-labs/agent-browser/agent-browser" = "latest"
# A Git branch, tag, or commit can replace "latest".
```

Package names are `owner/repository/skill-name`; the final component is the
skill's frontmatter name, not its directory. Names must be lowercase slugs.
Only GitHub sources and global OpenCode/Pi installations are supported.

```sh
mise bootstrap
mise bootstrap packages status
mise bootstrap packages upgrade
```

Install skips satisfied declarations; upgrade re-adds only requested skills,
preserving their selected Git refs. It never runs the CLI's global updater.
`latest` follows the default branch; branch/tag pins are not immutable—use a
commit for that. Status is local and reports the selected ref or folder hash;
it does not fetch upstream or detect edits within an installed skill.

The CLI owns `~/.agents/skills`, `~/.agents/.skill-lock.json` (or
`$XDG_STATE_HOME/skills/.skill-lock.json` when set). Both OpenCode and Pi use
the shared `~/.agents/skills` directory; the current CLI creates no additional
agent links for them. Existing OpenCode- and Pi-specific skills are checked for name
collisions. There is no additional plugin lockfile.

Conflicting sources, unmanaged directories, local links, malformed lockfiles,
and symlinked parent directories stop installation. Transfer ownership from
Nix before enrolling existing skills. This plugin does not unlink Nix files.
Removing a declaration does not delete installed skills; use the native CLI
to remove skills deliberately. Uninstall is intentionally not exposed since
the canonical directory may be shared by other agents.

## Development

```sh
lua tests/skills.lua
mise plugins link agent-skills "$PWD"
# Opt-in network smoke test in an isolated home:
mise exec npm:skills@1.7.2 -- python3 tests/integration.py
```

The plugin is entirely Lua, using Mise's filesystem, JSON, and command APIs.
Shell arguments are quoted; legacy links are checked with the Linux/macOS
`test -ef` operator. Node is only needed by the upstream `skills` CLI.
Unit tests run on Lua 5.1 or later; the optional Python smoke test exercises
the real embedded Lua hooks and CLI in a private temporary home.
