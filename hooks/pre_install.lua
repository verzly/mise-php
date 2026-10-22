local env = require("lib/env")
local logs = require("lib/logs")
local static_php = require("lib/static_php")
local php_versions = require("lib/php_versions")
local process = require("lib/process")
local tools = require("lib/tools")

local VERBOSE   = env.VERBOSE
local QUIET     = env.QUIET

local shell_quote = tools.shell_quote

--- Returns download information for a specific version
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#preinstall-hook
--- @param ctx {version: string, runtimeVersion: string} Context
--- @return table Version and download information
function PLUGIN:PreInstall(ctx)
    local config = env.resolve(ctx)
    local version = ctx.version
    -- Static installs list versions before selecting a URL for partial and exact requests (8, 8.0, or 8.0.1).
    -- Exact versions could probe source URLs in priority order without listing,
    -- but sharing this lookup keeps the flow shorter and consistent for now.
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

    if config.PREBUILT_STATIC then
        if not static_php.is_supported_platform() then
            error("PHP_PREBUILT_STATIC is enabled, but static PHP is not supported on this platform.")
        end
        return static_php.release(release.version, config.PREBUILT_STATIC_FLAVOR)
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

    if config.SKIP_DEPS then
        print("\27[96mNote:\27[0m Skipping dependency installation (PHP_SKIP_DEPS is set).")
    else
        install_dependencies(release.version, config)
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

local DEPS_OUTPUT_TAIL_LINES = 40
local DEPS_OUTPUT_TAIL_CHARS = 4000

-- Keep the most relevant failing lines without flooding the mise error output.
local function tail_lines(output, max_lines, max_chars)
    local lines = {}
    for line in (tostring(output or "") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end

    while #lines > 0 and lines[1] == "" do
        table.remove(lines, 1)
    end

    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines, #lines)
    end

    if #lines == 0 then
        return nil
    end

    local excerpt = {}
    for index = math.max(1, #lines - max_lines + 1), #lines do
        excerpt[#excerpt + 1] = lines[index]
    end

    local text = table.concat(excerpt, "\n")
    if #text > max_chars then
        text = "... [truncated] ...\n" .. text:sub(#text - max_chars + 1)
    end

    return text
end

local function dependency_failure_message(command, result, version)
    local log_path = logs.path(logs.create_id("dependencies-" .. (version or "unknown")), "install")
    local written = logs.write_header(log_path, "dependency installation", command)
    if written then
        logs.append(log_path, result.output)
    end

    local message = "\n\nFailed to install PHP build dependencies.\n\n" ..
        "Command: \27[93m" .. command .. "\27[0m\n" ..
        "Exit code: " .. tostring(result.code) .. "\n"

    if not VERBOSE then
        local excerpt = tail_lines(result.output, DEPS_OUTPUT_TAIL_LINES, DEPS_OUTPUT_TAIL_CHARS)
        if excerpt then
            message = message ..
                "\n----- dependency installer output -----\n" .. excerpt ..
                "\n----- end dependency installer output -----\n"
        else
            message = message .. "\nThe dependency installer produced no output.\n"
        end
    end

    message = message .. "\n"
    if written then
        message = message .. "💡 Full log: " .. log_path .. "\n"
    end

    message = message ..
        "💡 Tip: \27[93mFix the reported dependency error above, then restart the installation.\27[0m\n" ..
        "💡 Tip: \27[93mInstall the build dependencies manually:\27[0m https://github.com/verzly/mise-php/blob/master/bin/install-dependencies.sh\n"

    return message
end

function install_dependencies(version, config)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Dependency installation output is captured. Set PHP_VERBOSE=1 to stream it live. A full log is written if it fails.")
    else
        print("\27[96mNote:\27[0m Dependency installation output is streamed live. A full log is written if it fails.")
    end

    print("Installing dependencies...")

    local path = RUNTIME.pluginDirPath .. '/bin/install-dependencies.sh'
    local chmod_status = os.execute("chmod +x " .. shell_quote(path) .. QUIET)
    if chmod_status ~= 0 and chmod_status ~= true then
        error(
            "\n\nFailed to prepare PHP build dependency installer.\n\n" ..
            "Could not make the dependency installer executable.\n"
        )
    end
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
        version_prefix = 'PHP_BUILD_VERSION=' .. shell_quote(version) .. ' '
    end

    local assignments = {}
    for _, field in ipairs({
        { "PHP_CONFIGURE_OPTIONS", "CONFIGURE_OPTIONS" },
        { "PHP_EXTRA_CONFIGURE_OPTIONS", "EXTRA_CONFIGURE_OPTIONS" },
        { "PHP_PECL_EXTENSIONS", "PECL_EXTENSIONS_RAW" },
        { "PHP_PIE_EXTENSIONS", "PIE_EXTENSIONS_RAW" },
    }) do
        assignments[#assignments + 1] = field[1] .. '=' .. shell_quote(config[field[2]] or '')
    end
    local command = version_prefix .. table.concat(assignments, ' ') .. ' sh ' .. shell_quote(path)
    local result = process.run(command, { quiet = "" })
    if result.ok then
        return
    end

    error(dependency_failure_message(command, result, version))
end
