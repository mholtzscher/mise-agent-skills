function PLUGIN:PackageInstall(ctx)
    return require("lib.skills").run("install", ctx)
end
