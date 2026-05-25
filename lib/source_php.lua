local env = require("lib/env")
local messages = require("lib/messages")
local tools = require("lib/tools")

local source_php = {}

local VERBOSE = env.VERBOSE
local QUIET = env.QUIET

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function read_lines(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local lines = {}
    for line in file:lines() do
        table.insert(lines, line)
    end
    file:close()

    return lines
end

local function strip_configure_failed_program_blocks(lines)
    local cleaned = {}
    local skipping_program = false

    for _, line in ipairs(lines) do
        if line:find("configure: failed program was:", 1, true) then
            skipping_program = true
        elseif skipping_program and line:match("^|") then
            -- Autoconf prints the full temporary C program after many failed
            -- probes. That block is very noisy and rarely helps users fix the
            -- actual dependency problem, so keep it out of the concise summary.
        else
            skipping_program = false
            table.insert(cleaned, line)
        end
    end

    return cleaned
end

local function line_is_configure_failure(line)
    return line:match("configure:%d+: error:") ~= nil
        or line:match("^configure: error:") ~= nil
        or line:match("undefined reference") ~= nil
        or line:match("ld returned 1 exit status") ~= nil
        or line:match("collect2: error") ~= nil
        or line:match("fatal error:") ~= nil
        or line:match("Package requirements .* were not met") ~= nil
        or line:match("No package .* found") ~= nil
        or line:match("Package .* was not found") ~= nil
        or line:match("command not found") ~= nil
        or line:match("cannot find") ~= nil
        or line:match("too old") ~= nil
end

local function find_excerpt_start(lines, failure_index)
    local min_index = math.max(1, failure_index - 35)

    for i = failure_index, min_index, -1 do
        if lines[i]:match("^configure:%d+: checking ") then
            return i
        end
    end

    return math.max(1, failure_index - 8)
end

local function extract_configure_failure_excerpt(path)
    local lines = read_lines(path)
    if not lines or #lines == 0 then
        return nil
    end

    lines = strip_configure_failed_program_blocks(lines)

    local failure_index = nil
    for i = #lines, 1, -1 do
        if line_is_configure_failure(lines[i]) then
            failure_index = i
            break
        end
    end

    if not failure_index then
        return nil
    end

    local start_index = find_excerpt_start(lines, failure_index)
    local end_index = math.min(#lines, failure_index + 25)
    local excerpt = {}

    for i = start_index, end_index do
        local line = lines[i]

        if line:match("^##") or line:match("^configure: exit ") then
            break
        end

        table.insert(excerpt, line)

        if #excerpt >= 80 then
            break
        end
    end

    while #excerpt > 0 and excerpt[1] == "" do
        table.remove(excerpt, 1)
    end

    while #excerpt > 0 and excerpt[#excerpt] == "" do
        table.remove(excerpt, #excerpt)
    end

    if #excerpt == 0 then
        return nil
    end

    return table.concat(excerpt, "\n")
end

local function print_configure_failure_excerpt(path)
    local excerpt = extract_configure_failure_excerpt(path)
    if not excerpt or excerpt == "" then
        return false
    end

    io.stderr:write("\n----- PHP configure failure -----\n")
    io.stderr:write(excerpt)
    if not excerpt:match("\n$") then
        io.stderr:write("\n")
    end
    io.stderr:write("----- end PHP configure failure -----\n")

    return true
end

local function line_is_make_failure(line)
    return line:match("[Ee]rror:") ~= nil
        or line:match("fatal error:") ~= nil
        or line:match("undefined reference") ~= nil
        or line:match("ld returned 1 exit status") ~= nil
        or line:match("collect2: error") ~= nil
        or line:match("No such file or directory") ~= nil
        or line:match("recipe for target") ~= nil
        or line:match("%*%*%*") ~= nil
        or line:match("Stop%.") ~= nil
end

local function extract_make_failure_excerpt(path)
    local lines = read_lines(path)
    if not lines or #lines == 0 then
        return nil
    end

    local failure_index = nil
    for i = #lines, 1, -1 do
        if line_is_make_failure(lines[i]) then
            failure_index = i
            break
        end
    end

    if not failure_index then
        -- Fall back to the last part of the build log. Build systems sometimes
        -- fail through wrapper scripts without a clean, machine-readable error
        -- marker, and the tail is still more useful than dumping the full log.
        failure_index = #lines
    end

    local start_index = math.max(1, failure_index - 35)
    local end_index = math.min(#lines, failure_index + 15)
    local excerpt = {}

    for i = start_index, end_index do
        table.insert(excerpt, lines[i])
        if #excerpt >= 80 then
            break
        end
    end

    while #excerpt > 0 and excerpt[1] == "" do
        table.remove(excerpt, 1)
    end

    while #excerpt > 0 and excerpt[#excerpt] == "" do
        table.remove(excerpt, #excerpt)
    end

    if #excerpt == 0 then
        return nil
    end

    return table.concat(excerpt, "\n")
end

local function print_make_failure_excerpt(path)
    local excerpt = extract_make_failure_excerpt(path)
    if not excerpt or excerpt == "" then
        return false
    end

    io.stderr:write("\n----- PHP build failure -----\n")
    io.stderr:write(excerpt)
    if not excerpt:match("\n$") then
        io.stderr:write("\n")
    end
    io.stderr:write("----- end PHP build failure -----\n")

    return true
end

local function print_file_tip(path, label)
    if VERBOSE then
        return "💡 Debug log: \27[93m" .. path .. "\27[0m (" .. label .. ")\n"
    end

    return "💡 Tip: \27[93mCheck the " .. label .. " log for details:\27[0m " .. path .. "\n"
end

local function run_make(sdkPath, envPrefix, version)
    local makeLog = "/tmp/mise-php-make-" .. version .. ".log"
    local status = os.execute(string.format(
        "cd %s && %smake -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) > %s 2>&1",
        shell_quote(sdkPath),
        envPrefix,
        shell_quote(makeLog)
    ))

    return status, makeLog
end

local function is_wsl()
    local f = io.open("/proc/version", "r")
    if not f then
        return false
    end

    local content = f:read("*a") or ""
    f:close()

    content = string.lower(content)
    return string.find(content, "microsoft", 1, true) ~= nil
end

local function fail_if_windows_php_is_visible_or_hangs()
    if RUNTIME.osType ~= "linux" then
        return
    end

    if not is_wsl() then
        return
    end

    local php_path_file = "/tmp/mise-php-detected-path.txt"

    os.remove(php_path_file)

    local detect_cmd = string.format([[
        sh -c '
            PHP_PATH="$(command -v php 2>/dev/null || true)"
            printf "%%s" "$PHP_PATH" > "%s"

            if [ -z "$PHP_PATH" ]; then
                exit 0
            fi

            case "$PHP_PATH" in
                /mnt/[a-zA-Z]/*|*.exe)
                    exit 42
                    ;;
            esac

            timeout 10s "$PHP_PATH" -v >/dev/null 2>&1
            rc=$?

            if [ "$rc" -eq 124 ]; then
                exit 124
            fi

            exit 0
        '
    ]], php_path_file)

    local status = os.execute(detect_cmd)

    local detected_php_path = ""
    local f = io.open(php_path_file, "r")
    if f then
        detected_php_path = f:read("*a") or ""
        f:close()
        os.remove(php_path_file)
    end

    if status == 42 or status == 124 or status == 42 * 256 or status == 124 * 256 then
        local warning =
            "\n\nWSL may be exposing Windows PATH entries inside your Linux shell, which can cause the installer to access a PHP binary installed on Windows.\n\n" ..
            "Detected PHP path: \27[93m" .. (detected_php_path ~= "" and detected_php_path or "(unknown)") .. "\27[0m\n\n" ..
            "💡 Tip: Add the following to \27[93m/etc/wsl.conf\27[0m and restart WSL:\n\n" ..
            "\27[93m[interop]\nappendWindowsPath=false\27[0m\n\n" ..
            "Then run \27[93mwsl --shutdown\27[0m from Windows, update your \27[93m~/.bashrc\27[0m if needed, and restart the installation.\n" ..
            messages.see("wsl-windows-path-exposure")

        error(warning)
    end
end


local configure_macos
local configure_linux

function source_php.install(sdkPath, version)
    fail_if_windows_php_is_visible_or_hangs()

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    -- mise extracts the tarball to sdkPath with the top-level directory stripped,
    -- so sdkPath is the PHP source directory
    local os_type = RUNTIME.osType
    local homebrew_prefix = os.getenv("HOMEBREW_PREFIX") or "/opt/homebrew"

    -- Build environment and configure options
    local envPrefix = ""
    local configureOptions = "--prefix='" .. sdkPath .. "'"

    if not VERBOSE then
        print("\27[96mNote:\27[0m Build output is written to temporary log files. Set PHP_VERBOSE=1 to show commands, failure summaries, and log paths.")
    end

    -- Common configure options
    local commonOptions = [[
        --enable-bcmath
        --enable-calendar
        --enable-dba
        --enable-exif
        --enable-fpm
        --enable-ftp
        --enable-gd
        --enable-intl
        --enable-mbregex
        --enable-mbstring
        --enable-mysqlnd
        --enable-pcntl
        --enable-shmop
        --enable-soap
        --enable-sockets
        --enable-sysvmsg
        --enable-sysvsem
        --enable-sysvshm
        --sysconfdir=']] .. sdkPath .. [['
        --with-config-file-path=']] .. sdkPath .. [['
        --with-config-file-scan-dir=']] .. sdkPath .. [[/conf.d'
        --with-curl
        --with-mhash
        --with-openssl
        --with-mysqli=mysqlnd
        --with-pdo-mysql=mysqlnd
        --with-zlib
        --without-pcre-jit
        --without-snmp
    ]]

    commonOptions = string.gsub(commonOptions, "%s+", " ")
    configureOptions = configureOptions .. " " .. commonOptions

    -- PEAR was removed from the PHP source tree in 8.5.
    if major > 8 or (major == 8 and minor >= 5) then
        configureOptions = configureOptions .. " --without-pear"
    else
        configureOptions = configureOptions .. " --with-pear"
    end

    if os_type == "darwin" then
        configureOptions, envPrefix = configure_macos(configureOptions, homebrew_prefix)
    else
        configureOptions = configure_linux(configureOptions)
    end

    -- Older PHP source releases may contain K&R-style function definitions
    -- that are not supported in C23, e.g. in ext/bcmath/libbcmath.
    -- Newer Autoconf/compiler toolchains may select C23 automatically,
    -- so pin affected older PHP builds to GNU17.
    if major < 8 or (major == 8 and minor <= 2) then
        local existing_cflags = os.getenv("CFLAGS") or ""
        local cflags_val = "-std=gnu17"
        if existing_cflags ~= "" then
            cflags_val = cflags_val .. " " .. existing_cflags
        end
        envPrefix = envPrefix .. 'export CFLAGS="' .. cflags_val .. '" && '
    end

    -- Allow user to append configure options
    local extraOptions = os.getenv("PHP_EXTRA_CONFIGURE_OPTIONS")
    if extraOptions ~= nil and extraOptions ~= "" then
        configureOptions = configureOptions .. " " .. extraOptions
    end

    -- Allow user to replace configure options entirely while preserving prefix
    local userOptions = os.getenv("PHP_CONFIGURE_OPTIONS")
    if userOptions ~= nil and userOptions ~= "" then
        configureOptions = "--prefix='" .. sdkPath .. "' " .. userOptions
    end

    -- Run buildconf
    print("Running buildconf...")
    local buildconfCmd = string.format("cd '%s' && ./buildconf --force" .. QUIET, sdkPath)
    local status = os.execute(buildconfCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to run buildconf.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    -- Run configure
    print("Configuring PHP with options...")
    if VERBOSE then
        print("Configure command: " .. envPrefix .. "./configure " .. configureOptions)
    end

    local configureOutputLog = "/tmp/mise-php-configure-output-" .. version .. ".log"
    local configureCmd = string.format(
        "cd %s && %s./configure %s > %s 2>&1",
        shell_quote(sdkPath),
        envPrefix,
        configureOptions,
        shell_quote(configureOutputLog)
    )
    status = os.execute(configureCmd)
    if status ~= 0 and status ~= true then
        local src_log = sdkPath .. "/config.log"
        local dst_log = "/tmp/mise-php-config-" .. version .. ".log"
        local saved_log = print_file_tip(configureOutputLog, "configure output")

        if os.execute("cp '" .. src_log .. "' '" .. dst_log .. "' 2>/dev/null") == 0 then
            if VERBOSE then
                print_configure_failure_excerpt(dst_log)
            end
            saved_log = saved_log .. print_file_tip(dst_log, "configure config.log")
        elseif VERBOSE then
            print_configure_failure_excerpt(configureOutputLog)
        end

        error(
            "\n\nFailed to configure PHP.\n\n" ..
            saved_log ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    -- Build PHP
    print("Building PHP (this may take several minutes)...")
    local makeLog
    status, makeLog = run_make(sdkPath, envPrefix, version)
    if status ~= 0 and status ~= true then
        if makeLog and makeLog ~= "" and VERBOSE then
            print_make_failure_excerpt(makeLog)
        end
        error(
            "\n\nFailed to build PHP.\n\n" ..
            (makeLog and print_file_tip(makeLog, "build") or "") ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    -- Install PHP
    print("Installing PHP...")
    local installCmd = string.format("cd '%s' && %smake install" .. QUIET, sdkPath, envPrefix)
    status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to install PHP.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    -- Create conf.d directory
    os.execute(string.format("mkdir -p '%s/conf.d'", sdkPath))
    local confFile = io.open(sdkPath .. "/conf.d/php.ini", "w")
    if confFile then
        confFile:write("# Add system-wide PHP configuration options here\n")
        confFile:close()
    end

    -- Verify PHP installation
    local php_bin = sdkPath .. "/bin/php"
    local ok, why, code = os.execute('"' .. php_bin .. '" --version > /dev/null 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        error(
            "\n\nPHP installation appears to be broken: 'php --version' failed.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    print("PHP installation complete!")

    -- Install PECL extensions
    if not (major > 8 or (major == 8 and minor >= 5)) then
        tools.install_pecl_extensions(sdkPath, envPrefix, version)
    end

    -- Install PIE and PIE extensions
    if major > 8 or (major == 8 and minor >= 1) then
        tools.install_pie(sdkPath, version)
        tools.install_pie_extensions(sdkPath, version)
    end

    -- Install Composer
    tools.install_composer(sdkPath, version)

    -- Clean up source files to save space
    print("Cleaning up source files...")
    local cleanCmd = string.format(
        "cd '%s' && rm -rf Zend ext sapi main TSRM build configure* aclocal* Makefile* 2>/dev/null",
        sdkPath
    )
    os.execute(cleanCmd)
end

--- Configure options for macOS with Homebrew
function configure_macos(configureOptions, homebrew_prefix)
    local envPrefix = ""
    local pkg_config_paths = {}

    -- Required packages
    -- bzip2 does not ship pkg-config metadata, and freetype/libpng depend on it,
    -- so freetype/libpng are handled by path-based detection instead
    local required_packages = {
        { name = "bison", path_only = true },
        { name = "re2c", path_only = true },
        { name = "icu4c", pkg_config = true },
        { name = "krb5", pkg_config = true },
        { name = "libedit", pkg_config = true },
        { name = "libxml2", pkg_config = true },
        { name = "openssl@3", pkg_config = true },
        { name = "zlib", pkg_config = true },
        { name = "libzip", pkg_config = true },
        { name = "oniguruma", pkg_config = true },
        { name = "sqlite", pkg_config = true },
        { name = "curl", pkg_config = true },
    }

    -- Check for versioned icu4c (icu4c@76, icu4c@77, icu4c@78, etc.)
    local icu_path = nil
    for v = 80, 70, -1 do
        local test_path = homebrew_prefix .. "/opt/icu4c@" .. v
        local f = io.open(test_path .. "/lib", "r")
        if f ~= nil then
            f:close()
            icu_path = test_path
            break
        end
    end
    if icu_path == nil then
        local f = io.open(homebrew_prefix .. "/opt/icu4c/lib", "r")
        if f ~= nil then
            f:close()
            icu_path = homebrew_prefix .. "/opt/icu4c"
        end
    end

    for _, pkg in ipairs(required_packages) do
        local pkg_path
        if pkg.name == "icu4c" then
            pkg_path = icu_path
        else
            pkg_path = homebrew_prefix .. "/opt/" .. pkg.name
        end

        if pkg_path ~= nil then
            -- Check /bin for path-only packages and /lib for the rest
            local check_dir = pkg.path_only and "/bin" or "/lib"
            local f = io.open(pkg_path .. check_dir, "r")
            if f ~= nil then
                f:close()
                if pkg.pkg_config then
                    table.insert(pkg_config_paths, pkg_path .. "/lib/pkgconfig")
                end
                if pkg.path_only then
                    envPrefix = envPrefix .. 'export PATH="' .. pkg_path .. '/bin:$PATH" && '
                end
            else
                io.stderr:write("Warning: " .. pkg.name .. " not found at " .. pkg_path .. check_dir .. "\n")
            end
        else
            io.stderr:write("Warning: " .. pkg.name .. " not found\n")
        end
    end

    -- Build PKG_CONFIG_PATH
    if #pkg_config_paths > 0 then
        local existing_pkg = os.getenv("PKG_CONFIG_PATH") or ""
        local new_pkg = table.concat(pkg_config_paths, ":")
        if existing_pkg ~= "" then
            new_pkg = new_pkg .. ":" .. existing_pkg
        end
        envPrefix = envPrefix .. 'export PKG_CONFIG_PATH="' .. new_pkg .. '" && '
    end

    -- Set FREETYPE2 flags to bypass pkg-config because bzip2 has no .pc file
    local freetype_path = homebrew_prefix .. "/opt/freetype"
    local f = io.open(freetype_path .. "/lib", "r")
    if f ~= nil then
        f:close()
        envPrefix = envPrefix .. 'export FREETYPE2_CFLAGS="-I' .. freetype_path .. '/include/freetype2" && '
        envPrefix = envPrefix .. 'export FREETYPE2_LIBS="-L' .. freetype_path .. '/lib -lfreetype" && '
    end

    -- Optional packages with configure flags
    -- extra_flags: LDFLAGS/CPPFLAGS needed for keg-only packages without .pc files
    local optional_packages = {
        { name = "gmp", flag = "--with-gmp" },
        { name = "libsodium", flag = "--with-sodium" },
        { name = "freetype", flag = "--with-freetype" },
        { name = "gettext", flag = "--with-gettext" },
        { name = "jpeg", flag = "--with-jpeg" },
        { name = "webp", flag = "--with-webp" },
        { name = "libpng", flag = "--with-png" },
        { name = "readline", flag = "--with-readline" },
        { name = "bzip2", flag = "--with-bz2" },
        { name = "libiconv", flag = "--with-iconv", missing_flag = "--without-iconv", extra_flags = true },
        { name = "libpq", flag = "--with-pdo-pgsql" },
    }

    local ldflags = {}
    local cppflags = {}

    for _, pkg in ipairs(optional_packages) do
        local pkg_path = homebrew_prefix .. "/opt/" .. pkg.name
        local f = io.open(pkg_path .. "/lib", "r")
        if f ~= nil then
            f:close()
            configureOptions = configureOptions .. " " .. pkg.flag .. "='" .. pkg_path .. "'"
            if pkg.extra_flags then
                table.insert(ldflags, "-L" .. pkg_path .. "/lib")
                table.insert(cppflags, "-I" .. pkg_path .. "/include")
            end
        else
            if pkg.missing_flag then
                configureOptions = configureOptions .. " " .. pkg.missing_flag
                io.stderr:write("Info: " .. pkg.name .. " not found, using " .. pkg.missing_flag .. "\n")
            else
                io.stderr:write("Info: " .. pkg.name .. " not found, skipping " .. pkg.flag .. "\n")
            end
        end
    end

    if #ldflags > 0 then
        local existing = os.getenv("LDFLAGS") or ""
        local val = table.concat(ldflags, " ")
        if existing ~= "" then
            val = val .. " " .. existing
        end
        envPrefix = envPrefix .. 'export LDFLAGS="' .. val .. '" && '
    end
    if #cppflags > 0 then
        local existing = os.getenv("CPPFLAGS") or ""
        local val = table.concat(cppflags, " ")
        if existing ~= "" then
            val = val .. " " .. existing
        end
        envPrefix = envPrefix .. 'export CPPFLAGS="' .. val .. '" && '
    end

    -- Add external-gd if the required dependencies are available
    local has_gd_deps = true
    for _, dep in ipairs({ "freetype", "jpeg", "libpng" }) do
        local f = io.open(homebrew_prefix .. "/opt/" .. dep .. "/lib", "r")
        if f ~= nil then
            f:close()
        else
            has_gd_deps = false
            break
        end
    end
    if has_gd_deps then
        configureOptions = configureOptions .. " --with-external-gd"
    end

    return configureOptions, envPrefix
end

--- Configure options for Linux
function configure_linux(configureOptions)
    -- On Linux, most libraries are in standard paths.
    configureOptions = configureOptions .. " --with-curl --with-readline --with-gettext"

    local bz2_check = os.execute("printf '#include <bzlib.h>\nint main(void){return 0;}\n' | cc -x c - -lbz2 >/dev/null 2>&1")
    if bz2_check == 0 or bz2_check == true then
        configureOptions = configureOptions .. " --with-bz2"
    end

    local gmp_check = os.execute("pkg-config --exists gmp 2>/dev/null")
    if gmp_check == 0 or gmp_check == true then
        configureOptions = configureOptions .. " --with-gmp"
    end

    local sodium_check = os.execute("pkg-config --exists libsodium 2>/dev/null")
    if sodium_check == 0 or sodium_check == true then
        configureOptions = configureOptions .. " --with-sodium"
    end

    -- Check for external GD support. Older enterprise distributions may provide
    -- libpng or gd-devel but only an outdated gdlib, so require gdlib explicitly.
    local gd_check = os.execute("pkg-config --exists 'gdlib >= 2.1.0' 2>/dev/null")
    if gd_check == 0 or gd_check == true then
        configureOptions = configureOptions .. " --with-external-gd"
    end

    -- Check for PostgreSQL.
    local pgsql_check = os.execute("pg_config --version 2>/dev/null")
    if pgsql_check == 0 or pgsql_check == true then
        configureOptions = configureOptions .. " --with-pdo-pgsql"
    end

    -- Avoid enabling libzip from very old enterprise repositories. The PHP
    -- configure script performs its own final check, but this avoids predictable
    -- failures on systems that expose an old libzip through pkg-config.
    local zip_check = os.execute("pkg-config --exists 'libzip >= 0.11' 2>/dev/null")
    if zip_check == 0 or zip_check == true then
        configureOptions = configureOptions .. " --with-zip"
    end

    return configureOptions
end

return source_php
