local file = require("file")
local json = require("json")
local cmd = require("cmd")
local M = {}
local null = json.decode("null")

local function fail(message)
    error("agent-skills: " .. message, 0)
end

local function object(value)
    return type(value) == "table" and value ~= null and getmetatable(value) == nil
end

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function env(name, fallback)
    local value = os.getenv(name)
    if value == nil or value == "" then return fallback end
    return value
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "/"
end

function M.parse(requests)
    if type(requests) ~= "table" or requests == null then fail("packages must be an array") end
    local count = 0
    for key in pairs(requests) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then fail("packages must be an array") end
        count = count + 1
    end
    local batch, names = {}, {}
    for i = 1, count do
        local request = requests[i]
        if not object(request) or type(request.name) ~= "string" then fail("invalid package request") end
        local owner, repo, tail = request.name:match("^([%w][%w_-]*)/([%w][%w_.-]*)/(.+)$")
        if not owner then fail("expected owner/repository/skill-name: " .. request.name) end
        local skill = tail:match("([^/]+)$")
        if not skill or not skill:match("^[a-z0-9][a-z0-9_-]*$") or tail:sub(1, 1) == "/" or tail:find("//", 1, true) then
            fail("expected a skill name or path: " .. request.name)
        end
        for segment in tail:gmatch("[^/]+") do
            if not segment:match("^[%w][%w_.-]*$") then fail("expected safe path segments: " .. request.name) end
        end
        local subpath = tail:find("/", 1, true) and tail or nil
        if names[skill] then fail("duplicate skill name in batch: " .. skill) end
        names[skill] = true
        local ref = request.version
        if ref == "latest" then ref = nil end
        if ref ~= nil and (type(ref) ~= "string" or not ref:match("^[%w][%w._/-]*$") or ref:find("..", 1, true) or ref:sub(-1) == "/") then
            fail("invalid Git ref: " .. tostring(ref))
        end
        batch[i] = { name = request.name, source = owner .. "/" .. repo, skill = skill, ref = ref, subpath = subpath }
    end
    return batch
end

local function paths()
    local home = env("HOME")
    if not home or home:sub(1, 1) ~= "/" then fail("HOME must be absolute") end
    local config = env("XDG_CONFIG_HOME", home .. "/.config")
    local state = env("XDG_STATE_HOME", home .. "/.agents")
    if config:sub(1, 1) ~= "/" or state:sub(1, 1) ~= "/" then fail("XDG directories must be absolute") end
    return {
        home = home, config = config, state = state,
        root = home .. "/.agents/skills",
        agents = { config .. "/opencode/skills", home .. "/.pi/agent/skills" },
        lock = env("XDG_STATE_HOME") and state .. "/skills/.skill-lock.json" or state .. "/.skill-lock.json",
    }
end

local function lock(paths)
    if not file.stat(paths.lock) then return {} end
    local data = json.decode(file.read(paths.lock))
    if not object(data) or data.version ~= 3 or not object(data.skills) then
        fail("unsupported or malformed skills lockfile: " .. paths.lock)
    end
    for name, entry in pairs(data.skills) do
        if not object(entry) or type(entry.source) ~= "string" or type(entry.sourceType) ~= "string"
            or (entry.ref ~= nil and type(entry.ref) ~= "string")
            or (entry.skillPath ~= nil and type(entry.skillPath) ~= "string")
            or (entry.skillFolderHash ~= nil and type(entry.skillFolderHash) ~= "string") then
            fail("malformed lock entry: " .. name)
        end
    end
    return data.skills
end

local function inspect(p, entries, paths)
    local entry = entries[p.skill]
    local canonical = paths.root .. "/" .. p.skill
    if entry and (entry.source:lower() ~= p.source:lower() or entry.sourceType ~= "github") then
        fail("skill name belongs to another source: " .. p.skill)
    end
    if entry and p.subpath and entry.skillPath ~= p.subpath .. "/SKILL.md" then
        fail("skill name belongs to another source path: " .. p.skill)
    end
    local native = file.stat(canonical)
    if native and (not entry or native.is_symlink or not native.is_dir) then
        fail("skill is externally managed: " .. canonical)
    end
    for _, root in ipairs(paths.agents) do
        local target = root .. "/" .. p.skill
        local linked = file.stat(target)
        if linked then
            if not entry or not linked.is_symlink then fail("agent skill is externally managed: " .. target) end
            -- POSIX test follows links; -ef compares filesystem identity on Linux/macOS.
            local same = cmd.exec("if test " .. quote(target) .. " -ef " .. quote(canonical) .. "; then printf yes; else printf no; fi")
            if same ~= "yes" then fail("agent skill points elsewhere or is dangling: " .. target) end
        end
    end
    local manifest_path = canonical .. "/SKILL.md"
    local manifest = file.stat(manifest_path)
    local manifest_is_file = manifest and manifest.is_file
    if manifest and manifest.is_symlink then
        manifest_is_file = cmd.exec("if test -f " .. quote(manifest_path) .. "; then printf yes; else printf no; fi") == "yes"
    end
    -- Prune queries the installed version it recorded, which is the folder
    -- hash for default-branch skills rather than a requested Git ref.
    local installed = entry and (entry.ref == p.ref or (p.ref ~= nil and entry.skillFolderHash == p.ref)) and manifest_is_file
    local result = { name = p.name, state = installed and "installed" or "missing" }
    if installed then result.version = p.ref or (entry.skillFolderHash ~= "" and entry.skillFolderHash) or "latest" end
    return result
end

local function writable_parents(path, paths)
    local cursor = dirname(path)
    while true do
        local info = file.stat(cursor)
        if info and info.is_symlink then fail("refusing a symlinked parent: " .. cursor) end
        if info and not info.is_dir then fail("parent is not a directory: " .. cursor) end
        -- Stop at owned roots, allowing OS aliases such as macOS /var.
        if cursor == paths.home or cursor == paths.config or cursor == paths.state or cursor == "/" or cursor == "" then break end
        cursor = dirname(cursor)
    end
end

function M.run(action, ctx)
    if action ~= "installed" and action ~= "install" and action ~= "upgrade" and action ~= "uninstall" then fail("unknown action") end
    local batch = M.parse(ctx.packages)
    local paths = paths()
    local entries = lock(paths)
    local statuses = json.decode("[]")
    for i, p in ipairs(batch) do statuses[i] = inspect(p, entries, paths) end
    if action == "installed" then return { packages = statuses } end
    writable_parents(paths.lock, paths)
    local lock_info = file.stat(paths.lock)
    if lock_info and lock_info.is_symlink then fail("refusing a symlinked lockfile: " .. paths.lock) end
    for _, p in ipairs(batch) do
        writable_parents(paths.root .. "/" .. p.skill, paths)
        for _, root in ipairs(paths.agents) do writable_parents(root .. "/" .. p.skill, paths) end
    end
    if ctx.dry_run then return end
    for i, p in ipairs(batch) do
        if action == "uninstall" then
            -- Prune supplies an installed version (possibly a folder hash), not
            -- a requested Git ref. Ownership, rather than ref equality, controls removal.
            if entries[p.skill] then
                cmd.exec("skills remove --global " .. quote(p.skill) .. " --yes", {
                    env = { DISABLE_TELEMETRY = "1" },
                })
                if lock(paths)[p.skill] or file.stat(paths.root .. "/" .. p.skill) then
                    fail("skills CLI did not remove the requested skill: " .. p.name)
                end
                for _, root in ipairs(paths.agents) do
                    if file.stat(root .. "/" .. p.skill) then
                        fail("skills CLI did not remove the agent link: " .. root .. "/" .. p.skill)
                    end
                end
            end
        elseif action == "upgrade" or statuses[i].state ~= "installed" then
            local source = "https://github.com/" .. p.source
            -- The CLI's GitHub shorthand supports subpaths plus fragment refs,
            -- unlike tree URLs which cannot represent refs containing slashes.
            if p.subpath then source = p.source .. "/" .. p.subpath end
            if p.ref then
                source = source .. "#" .. p.ref:gsub("([^%w._~-])", function(c) return string.format("%%%02X", c:byte()) end)
            end
            cmd.exec("skills add " .. quote(source) .. " --skill " .. quote(p.skill) .. " --global --agent opencode pi --yes --full-depth", {
                env = { DISABLE_TELEMETRY = "1" },
            })
            if inspect(p, lock(paths), paths).state ~= "installed" then
                fail("skills CLI did not install the requested source/ref: " .. p.name)
            end
        end
    end
end

return M
