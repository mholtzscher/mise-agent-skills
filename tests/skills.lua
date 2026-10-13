local fs, entries, calls, environment, lock_data, command
local array = {}
local null = {}
package.preload.file = function()
    return {
        stat = function(path) return fs[path] end,
        read = function() return "lock" end,
    }
end
package.preload.json = function()
    return { decode = function(text)
        if text == "null" then return null end
        if text == "[]" then return setmetatable({}, array) end
        assert(text == "lock")
        return lock_data
    end }
end
package.preload.cmd = function()
    return { exec = function(text, options)
        calls[#calls + 1] = text
        return command(text, options)
    end }
end
os.getenv = function(name) return environment[name] end
local skills = require("lib.skills")
local request = { { name = "owner/repo/demo", version = "latest" } }
local function dir(path) fs[path] = { is_dir = true } end
local function installed(source, ref)
    entries.demo = { source = source or "owner/repo", sourceType = "github", ref = ref, skillFolderHash = "abc123" }
    dir("/home/test/.agents/skills/demo")
    fs["/home/test/.agents/skills/demo/SKILL.md"] = { is_file = true }
    fs["/home/test/.agents/.skill-lock.json"] = { is_file = true }
end
local function reset()
    fs, entries, calls = {}, {}, {}
    environment = { HOME = "/home/test" }
    lock_data = { version = 3, skills = entries }
    command = function(text)
        assert(text == "skills add 'https://github.com/owner/repo' --skill 'demo' --global --agent opencode pi --yes --full-depth", text)
        installed()
        return ""
    end
end
local function run(action, requests, dry)
    return skills.run(action, { packages = requests or request, dry_run = dry })
end
local function raises(pattern, fn)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):match(pattern), tostring(err))
end
local count = 0
local function test(name, fn)
    reset()
    fn()
    count = count + 1
    print("ok " .. count .. " - " .. name)
end

test("missing, install, repeat install, selected upgrade", function()
    assert(run("installed").packages[1].state == "missing")
    run("install")
    assert(run("installed").packages[1].version == "abc123")
    run("install")
    assert(#calls == 1)
    run("upgrade")
    assert(#calls == 2)
end)
test("dry runs never invoke installer", function()
    run("install", nil, true)
    run("upgrade", nil, true)
    assert(#calls == 0)
end)
test("prune status recognizes a recorded default-branch folder hash", function()
    installed()
    local recorded = { { name = "owner/repo/demo", version = "abc123" } }
    local status = run("installed", recorded).packages[1]
    assert(status.state == "installed" and status.version == "abc123")
    assert(#calls == 0)
end)
test("symlinked manifests remain installed when their target is a file", function()
    installed()
    fs["/home/test/.agents/skills/demo/SKILL.md"] = { is_symlink = true }
    command = function(text)
        assert(text == "if test -f '/home/test/.agents/skills/demo/SKILL.md'; then printf yes; else printf no; fi")
        return "yes"
    end
    assert(run("installed").packages[1].state == "installed")
    run("install")
    assert(#calls == 2) -- Only the two manifest checks, no installer.
    command = function() return "no" end
    assert(run("installed").packages[1].state == "missing")
end)
test("branch pin is escaped and checked", function()
    installed()
    local pinned = { { name = "owner/repo/demo", version = "feature/skills" } }
    assert(run("installed", pinned).packages[1].state == "missing")
    command = function(text)
        assert(text:find("https://github.com/owner/repo#feature%%2Fskills"))
        installed(nil, "feature/skills")
        return ""
    end
    run("install", pinned)
    assert(run("installed", pinned).packages[1].version == "feature/skills")
end)
test("nested sources preserve source path and refs", function()
    local nested = { { name = "owner/repo/path/to/demo", version = "feature/skills" } }
    command = function(text)
        assert(text == "skills add 'owner/repo/path/to/demo#feature%2Fskills' --skill 'demo' --global --agent opencode pi --yes --full-depth")
        installed(nil, "feature/skills")
        entries.demo.skillPath = "path/to/demo/SKILL.md"
        return ""
    end
    run("install", nested)
    assert(run("installed", nested).packages[1].state == "installed")
    entries.demo.skillPath = "elsewhere/demo/SKILL.md"
    raises("another source path", function() run("upgrade", nested) end)
end)
test("unowned directory and Nix links cannot be overwritten", function()
    dir("/home/test/.agents/skills/demo")
    raises("externally managed", function() run("install") end)
    installed()
    fs["/home/test/.agents/skills/demo"] = { is_symlink = true }
    raises("externally managed", function() run("upgrade") end)
    assert(#calls == 0)
end)
test("whole batch is preflighted for source collisions", function()
    installed("other/repo")
    raises("another source", function()
        run("install", { { name = "owner/repo/valid" }, request[1] })
    end)
    assert(#calls == 0)
end)
test("legacy agent links must point to canonical skill", function()
    installed()
    fs["/home/test/.config/opencode/skills/demo"] = { is_symlink = true }
    command = function(text)
        assert(text == "if test '/home/test/.config/opencode/skills/demo' -ef '/home/test/.agents/skills/demo'; then printf yes; else printf no; fi")
        return "yes"
    end
    assert(run("installed").packages[1].state == "installed")
    command = function() return "no" end
    raises("elsewhere or is dangling", function() run("installed") end)
end)
test("Pi collision also stops mutation", function()
    installed()
    dir("/home/test/.pi/agent/skills/demo")
    raises("externally managed", function() run("upgrade") end)
end)
test("malformed locks fail closed", function()
    installed()
    lock_data.version = 4
    raises("unsupported or malformed", function() run("installed") end)
    lock_data.version = 3
    entries.demo.ref = null
    raises("malformed lock entry", function() run("installed") end)
end)
test("XDG state controls native lock location", function()
    installed()
    environment.XDG_STATE_HOME = "/state"
    raises("externally managed", function() run("installed") end)
    fs["/state/skills/.skill-lock.json"] = { is_file = true }
    assert(run("installed").packages[1].state == "installed")
end)
test("symlinked parents and lockfiles stop mutation", function()
    fs["/home/test/.agents"] = { is_symlink = true }
    raises("symlinked parent", function() run("install") end)
    fs["/home/test/.agents"] = nil
    installed()
    fs["/home/test/.agents/.skill-lock.json"] = { is_symlink = true }
    raises("symlinked lockfile", function() run("upgrade") end)
    assert(#calls == 0)
end)
test("valid exit without installation fails postcondition", function()
    command = function() return "" end
    raises("did not install", function() run("install") end)
end)
test("input validation rejects traversal, syntax, duplicates, sparse arrays", function()
    for _, name in ipairs({ "a/b/../c", "a/b/$(id)", "a/b/*", "a/b//demo", "a/b/path//demo", "a/b/path/demo/" }) do
        raises("expected", function() skills.parse({ { name = name } }) end)
    end
    raises("invalid Git ref", function() skills.parse({ { name = "a/b/demo", version = "x;touch /tmp/foo" } }) end)
    raises("duplicate", function() skills.parse({ request[1], { name = "other/repo/demo" } }) end)
    raises("invalid package request", function() skills.parse({ [2] = request[1] }) end)
end)
test("empty results preserve JSON array identity", function()
    assert(getmetatable(run("installed", {}).packages) == array)
end)
test("quoted home paths are safely passed to shell", function()
    environment.HOME = "/home/it's me"
    environment.XDG_STATE_HOME = "/state"
    fs["/state/skills/.skill-lock.json"] = { is_file = true }
    installed()
    dir("/home/it's me/.agents/skills/demo")
    fs["/home/it's me/.config/opencode/skills/demo"] = { is_symlink = true }
    command = function(text)
        assert(text:find("'/home/it'\\''s me/.config/opencode/skills/demo'", 1, true))
        return "yes"
    end
    run("installed")
end)
test("uninstall targets only requested skill and ignores installed hash as ref", function()
    installed(nil, "feature/skills")
    entries.other = { source = "other/repo", sourceType = "github" }
    dir("/home/test/.agents/skills/other")
    command = function(text, options)
        assert(text == "skills remove --global 'demo' --yes", text)
        assert(options.env.DISABLE_TELEMETRY == "1")
        entries.demo = nil
        fs["/home/test/.agents/skills/demo"] = nil
        return ""
    end
    run("uninstall", { { name = "owner/repo/demo", version = "abc123" } })
    assert(#calls == 1 and entries.other and fs["/home/test/.agents/skills/other"])
    run("uninstall")
    assert(#calls == 1) -- Already absent is a no-op.
end)
test("uninstall dry run preserves state", function()
    installed()
    run("uninstall", nil, true)
    assert(#calls == 0 and entries.demo and fs["/home/test/.agents/skills/demo"])
end)
test("uninstall preflights the whole batch and rejects unmanaged state", function()
    installed("other/repo")
    raises("another source", function()
        run("uninstall", { { name = "owner/repo/valid" }, request[1] })
    end)
    installed()
    entries.demo = nil
    raises("externally managed", function() run("uninstall") end)
    installed()
    fs["/home/test/.agents/skills/demo"] = { is_symlink = true }
    raises("externally managed", function() run("uninstall") end)
    assert(#calls == 0)
end)
test("uninstall rejects source path changes and unsafe parents", function()
    installed()
    entries.demo.skillPath = "wrong/demo/SKILL.md"
    raises("another source path", function()
        run("uninstall", { { name = "owner/repo/path/demo" } })
    end)
    fs["/home/test/.agents"] = { is_symlink = true }
    raises("symlinked parent", function() run("uninstall") end)
    fs["/home/test/.agents"] = nil
    fs["/home/test/.agents/.skill-lock.json"] = { is_symlink = true }
    raises("symlinked lockfile", function() run("uninstall") end)
    assert(#calls == 0)
end)
test("uninstall fails when CLI retains lock entry or canonical directory", function()
    installed()
    command = function() return "" end
    raises("did not remove the requested skill", function() run("uninstall") end)
    command = function() entries.demo = nil; return "" end
    raises("did not remove the requested skill", function() run("uninstall") end)
end)
test("uninstall propagates CLI failure", function()
    installed()
    command = function() error("CLI failed") end
    raises("CLI failed", function() run("uninstall") end)
    assert(entries.demo and fs["/home/test/.agents/skills/demo"])
end)
test("uninstall checks legacy links were removed", function()
    installed()
    fs["/home/test/.pi/agent/skills/demo"] = { is_symlink = true }
    command = function(text)
        if text:match("^if test") then return "yes" end
        entries.demo = nil
        fs["/home/test/.agents/skills/demo"] = nil
        return ""
    end
    raises("did not remove the agent link", function() run("uninstall") end)
end)
print(count .. " tests passed")
