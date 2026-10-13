function PLUGIN:PackageUninstall(ctx)
    return require("lib.skills").run("uninstall", ctx)
end
