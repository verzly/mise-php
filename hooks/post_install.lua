local env = require("lib/env")
local source_php = require("lib/source_php")
local static_php = require("lib/static_php")
local php_packages = require("lib/php_packages")
local windows_php = require("lib/windows_php")

local PREBUILT_STATIC = env.PREBUILT_STATIC

local install_php_for_windows

--- Performs additional setup after installation
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#postinstall-hook
--- @param ctx {rootPath: string, runtimeVersion: string, sdkInfo: table} Context
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local version = sdkInfo.version
    local sdkPath = sdkInfo.path

    if PREBUILT_STATIC then
        if not static_php.is_supported_platform() then
            error("PHP_PREBUILT_STATIC is enabled, but static PHP is not supported on this platform.")
        end

        static_php.install(sdkPath, version)
        return
    end

    if RUNTIME.osType == "windows" then
        install_php_for_windows(sdkPath, version)
        return
    end

    source_php.install(sdkPath, version)
end

function install_php_for_windows(sdkPath, version)
    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    windows_php.install(sdkPath, version)

    -- Install PIE and PIE extensions
    if major > 8 or (major == 8 and minor >= 1) then
        php_packages.install_pie(sdkPath, version)
        php_packages.install_pie_extensions(sdkPath, version)
    end

    -- Install Composer
    php_packages.install_composer(sdkPath, version)
end
