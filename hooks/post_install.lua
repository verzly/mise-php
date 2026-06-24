local env = require("lib/env")
local source_php = require("lib/source_php")
local static_php = require("lib/static_php")
local php_packages = require("lib/php_packages")
local php_versions = require("lib/php_versions")
local windows_php = require("lib/windows_php")

local PREBUILT_STATIC = env.PREBUILT_STATIC

local function resolve_install_version(plugin, requested, ctx)
    requested = tostring(requested or "")

    if requested == "" then
        return requested
    end

    local lookup_ctx = {}
    if type(ctx) == "table" then
        for key, value in pairs(ctx) do
            lookup_ctx[key] = value
        end
    end

    lookup_ctx.version = requested
    lookup_ctx.runtimeVersion = requested

    local releases = plugin:Available(lookup_ctx)
    local release = php_versions.resolve_requested_version(
        releases,
        requested,
        php_versions.should_include_prereleases(lookup_ctx)
    )

    if release ~= nil and release.version ~= nil and release.version ~= "" then
        return release.version
    end

    return requested
end

local function install_php_runtime(sdkPath, version)
    if PREBUILT_STATIC then
        if not static_php.is_supported_platform() then
            error("PHP_PREBUILT_STATIC is enabled, but static PHP is not supported on this platform.")
        end

        return static_php.install(sdkPath, version)
    end

    if RUNTIME.osType == "windows" then
        return windows_php.install(sdkPath, version)
    end

    return source_php.install(sdkPath, version)
end

--- Performs additional setup after installation
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#postinstall-hook
--- @param ctx {rootPath: string, runtimeVersion: string, sdkInfo: table} Context
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local requested_version = sdkInfo.version
    local version = resolve_install_version(self, requested_version, ctx)
    local sdkPath = sdkInfo.path

    if requested_version ~= version then
        print("Resolved PHP " .. requested_version .. " -> " .. version)
    end

    local installInfo = install_php_runtime(sdkPath, version)

    php_packages.install_after_php(sdkPath, version, installInfo)

    if installInfo and installInfo.kind == "source" then
        source_php.cleanup(sdkPath)
    end
end
