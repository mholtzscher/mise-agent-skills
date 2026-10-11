function PLUGIN:PackageInstalled(ctx)
    return require("lib.skills").run("installed", ctx)
end
