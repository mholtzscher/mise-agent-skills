local cmd = require("cmd")
local json = require("json")
local M = {}

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.run(action, ctx)
    if ctx.dry_run and action ~= "installed" then
        action = "installed"
    end
    local requests = ctx.packages
    if #requests == 0 then
        requests = json.decode("[]")
    end
    return json.decode(cmd.exec("node " .. quote(RUNTIME.pluginDirPath .. "/lib/skills.mjs")
        .. " " .. quote(action) .. " " .. quote(json.encode(requests))))
end

return M
