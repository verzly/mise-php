local env = require("lib/env")
local messages = require("lib/messages")
local source_php = require("lib/source_php")
local static_php = require("lib/static_php")
local tools = require("lib/tools")

local PREBUILT_STATIC = env.PREBUILT_STATIC

local install_php_for_windows

--- Performs additional setup after installation
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#postinstall-hook
--- @param ctx {rootPath: string, runtimeVersion: string, sdkInfo: table} Context
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local version = sdkInfo.version
    local sdkPath = sdkInfo.path

    if PREBUILT_STATIC and static_php.is_supported_platform() then
        static_php.install(sdkPath, version)
    elseif RUNTIME.osType == "windows" then
        install_php_for_windows(sdkPath, version)
    else
        source_php.install(sdkPath, version)
    end
end

function install_php_for_windows(sdkPath, version)
    -- Install PHP
    print("Installing PHP...")

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    local scriptPath = assert(RUNTIME.pluginDirPath .. "\\bin\\install-windows-php.ps1")
    local installCmd = string.format(
        [[powershell -NoProfile -ExecutionPolicy Bypass -File "%s" -Version %s -Arch x64 -CustomPath "%s"]],
        scriptPath,
        version,
        sdkPath
    )
    local status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to install PHP.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    -- Verify PHP installation
    local php_bin = sdkPath .. "\\php.exe"
    local verify_bat = sdkPath .. "\\mise-php-verify.bat"

    local ok = tools.write_file(verify_bat, string.format(
        [[@echo off
"%s" --version
]],
        php_bin
    ))

    if not ok then
        error(
            "\n\nFailed to create temporary PHP verification script.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    local ok, why, code = os.execute(verify_bat .. " > NUL 2>&1")
    os.remove(verify_bat)

    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        error(
            "\n\nPHP installation appears to be broken: 'php --version' failed.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end
    print("PHP installation complete!")

    -- Install PIE and PIE extensions
    if major > 8 or (major == 8 and minor >= 1) then
        tools.install_pie(sdkPath, version)
        tools.install_pie_extensions(sdkPath, version)
    end

    -- Install Composer
    tools.install_composer(sdkPath, version)
end
