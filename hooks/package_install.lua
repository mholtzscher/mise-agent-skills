function PLUGIN:PackageInstall(ctx)
    return require("lib.bridge").run("install", ctx)
end
