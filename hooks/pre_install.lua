local env = require("lib/env")
local static_php = require("lib/static_php")
local php_versions = require("lib/php_versions")

local VERBOSE   = env.VERBOSE
local QUIET     = env.QUIET
local SKIP_DEPS = env.SKIP_DEPS

--- Returns download information for a specific version
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#preinstall-hook
--- @param ctx {version: string, runtimeVersion: string} Context
--- @return table Version and download information
function PLUGIN:PreInstall(ctx)
    local version = ctx.version
    local releases = self:Available(ctx or {})

    if not releases or #releases == 0 then
        error("⚠️ No releases available.")
    end

    local release = php_versions.resolve_requested_version(
        releases,
        version,
        php_versions.prerelease_flag_enabled(ctx)
    )

    if not release then
        error("Version not found: " .. tostring(version))
    end

    if static_php.is_requested(ctx) and static_php.is_supported_platform() then
        local flavor = static_php.requested_flavor(ctx)
        print(static_php.warning(flavor))
        return static_php.release(release.version, flavor)
    end

    if RUNTIME.osType == "windows" then
        return get_release_for_windows(release)
    end

    version_check_before_dependencies(release)

    print(
        "\27[96mNote:\27[0m " ..
        "PHP will be compiled from source for your system. " ..
        "Required build dependencies will be installed automatically. " ..
        "See: https://github.com/verzly/mise-php/blob/master/bin/install-dependencies.sh"
    )

    if SKIP_DEPS then
        print("\27[96mNote:\27[0m Skipping dependency installation (PHP_SKIP_DEPS is set).")
    else
        install_dependencies(release.version)
    end

    version_check_after_dependencies(release)

    return get_release_for_linux(release)
end

function version_check_before_dependencies(release)
    openssl_check_for_linux(release)  --- PHP < 8.1 with OpenSSL 3 (BAD)
end

function version_check_after_dependencies(release)
    mcrypt_check_for_linux(release)   --- PHP < 7.2 requires libmcrypt
end

function openssl_check_for_linux(release)
    local openssl_too_new = os.execute([[
        sh -c '
            v="$(openssl version 2>/dev/null | awk "{print \$2}")"
            major="${v%%.*}"
            rest="${v#*.}"
            minor="${rest%%.*}"

            if [ -n "$major" ] && [ -n "$minor" ]; then
                if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -gt 1 ]; }; then
                    exit 0
                fi
            fi

            exit 1
        '
    ]])

    local php_major, php_minor = string.match(release.version, "^(%d+)%.(%d+)")
    php_major = tonumber(php_major) or 0
    php_minor = tonumber(php_minor) or 0

    local php_too_old = (php_major < 8) or (php_major == 8 and php_minor < 1)

    if (openssl_too_new == true or openssl_too_new == 0) and php_too_old then
       error(
          "\n\nFailed to prepare PHP installation.\n\n" ..
          "Requested PHP version: \27[93m" .. release.version .. "\27[0m\n\n" ..
          "💡 Tip: \27[93mPHP versions below 8.1 are not compatible with OpenSSL versions newer than 1.1 on this system.\27[0m\n\n" ..
          "Quick workaround for PHP 7.4.x and 8.0.x with OpenSSL 3:\n" ..
          "1. Open \27[93mext/openssl/openssl.c\27[0m\n" ..
          "2. Remove or comment out:\n" ..
          "   \27[93mREGISTER_LONG_CONSTANT(\"OPENSSL_SSLV23_PADDING\", RSA_SSLV23_PADDING, CONST_CS|CONST_PERSISTENT);\27[0m\n" ..
          "3. Re-run the build\n\n" ..
          "Note: this is only a best-effort workaround and full compatibility is not guaranteed.\n" ..
          "Recommended: use PHP 8.1 or newer, or build this PHP version against OpenSSL 1.1 instead.\n"
      )
    end
end

function mcrypt_check_for_linux(release)
    local php_major, php_minor = string.match(release.version, "^(%d+)%.(%d+)")
    php_major = tonumber(php_major) or 0
    php_minor = tonumber(php_minor) or 0

    local needs_mcrypt = (php_major < 7) or (php_major == 7 and php_minor < 2)
    if not needs_mcrypt then
        return
    end

    local mcrypt_found = os.execute("pkg-config --exists libmcrypt 2>/dev/null")
    if mcrypt_found ~= 0 and mcrypt_found ~= true then
        error(
            "\n\nPHP " .. release.version .. " requires libmcrypt, which was not found on this system.\n\n" ..
            "💡 Tip: Install it first:\n" ..
            "  Debian/Ubuntu:   \27[93msudo apt-get install libmcrypt-dev\27[0m\n" ..
            "  Fedora:          \27[93msudo dnf install libmcrypt-devel\27[0m\n" ..
            "  RHEL/Rocky/Alma: \27[93msudo dnf install epel-release && sudo dnf install libmcrypt-devel\27[0m\n" ..
            "  Arch:            \27[93msudo pacman -S libmcrypt\27[0m\n\n" ..
            "Note: mcrypt was removed in PHP 7.2. Consider using PHP 7.2 or newer instead.\n"
        )
    end
end

function get_release_for_windows(release)
    -- Download from GitHub php-src releases
    return {
        version = release.version,
        -- url = "",
    }
end

function get_release_for_linux(release)
    -- Download from GitHub php-src releases
    return {
        version = release.version,
        url = "https://github.com/php/php-src/archive/php-" .. release.version .. ".tar.gz",
    }
end

function install_dependencies(version)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Dependency installation output is hidden. Set PHP_VERBOSE=1 or use --verbose to see full output.")
    end

    print("Installing dependencies...")

    local path = RUNTIME.pluginDirPath .. '/bin/install-dependencies.sh'
    os.execute('chmod +x "' .. path .. '"')

    if RUNTIME.osType ~= "darwin" then
        local has_sudo = os.execute('command -v sudo >/dev/null 2>&1')
        if has_sudo == true or has_sudo == 0 then
            local sudo_ready = os.execute('sudo -n -v >/dev/null 2>&1')
            if sudo_ready ~= true and sudo_ready ~= 0 then
                error(
                    "\n\nFailed to install PHP build dependencies.\n\n" ..
                    "💡 Tip: \27[93mRun 'sudo -v' manually first, then restart the installation.\27[0m\n\n" ..
                    "This step requires an already authenticated sudo session.\n"
                )
            end
        end
    end

    local version_prefix = ''
    if version ~= nil and version ~= '' then
        version_prefix = 'PHP_BUILD_VERSION="' .. version .. '" '
    end

    local status = os.execute(version_prefix .. 'sh "' .. path .. '"' .. QUIET)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to install PHP build dependencies.\n\n" ..
            "💡 Tip: \27[93mThe dependency installation command failed.\27[0m " ..
            "Check the output above, fix the reported issue, and restart the installation.\n"
        )
    end
end
