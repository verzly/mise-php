local env = require("lib/env")
local source_php = require("lib/source_php")
local static_php = require("lib/static_php")
local php_packages = require("lib/php_packages")
local windows_php = require("lib/windows_php")

local PREBUILT_STATIC = env.PREBUILT_STATIC

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
    local version = sdkInfo.version
    local sdkPath = sdkInfo.path

    local installInfo = install_php_runtime(sdkPath, version)

    php_packages.install_after_php(sdkPath, version, installInfo)

    if installInfo and installInfo.kind == "source" then
        source_php.cleanup(sdkPath)
    end
end
