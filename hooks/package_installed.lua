function PLUGIN:PackageInstalled(ctx)
    return require("lib.bridge").run("installed", ctx)
end
