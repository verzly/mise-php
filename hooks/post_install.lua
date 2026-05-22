local env = require("lib/env")
local static_php = require("lib/static_php")

local VERBOSE         = env.VERBOSE
local QUIET           = env.QUIET
local SKIP_DEPS       = env.SKIP_DEPS
local PECL_EXTENSIONS = env.PECL_EXTENSIONS
local PIE_EXTENSIONS  = env.PIE_EXTENSIONS
local PREBUILT_STATIC = env.PREBUILT_STATIC

local function verbose_tip(version)
    if VERBOSE then
        return "💡 Verbose mode is enabled; full output will be shown.\n"
    end
    return "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. (version or "VERSION") .. "'\27[0m to see the full output.\n"
end

local function manual_tip(command)
    return "💡 Tip: \27[93mRun '" .. command .. "'\27[0m manually after installation to confirm it works.\n"
end

local function see(anchor)
    return "→ See: https://github.com/verzly/mise-php#" .. anchor .. "\n"
end

--- Performs additional setup after installation
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#postinstall-hook
--- @param ctx {rootPath: string, runtimeVersion: string, sdkInfo: table} Context
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local version = sdkInfo.version
    local sdkPath = sdkInfo.path

    if PREBUILT_STATIC and static_php.is_supported_platform() then
        install_prebuilt_static_php(sdkPath, version)
    elseif RUNTIME.osType == "windows" then
        install_php_for_windows(sdkPath, version)
    else
        install_php_for_linux(sdkPath, version)
    end
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
            see("wsl-windows-path-exposure")

        error(warning)
    end
end

local function find_prebuilt_php_binary(sdkPath)
    local candidates = {
        sdkPath .. "/bin/php",
        sdkPath .. "/php",
        sdkPath .. "/buildroot/bin/php",
    }

    for _, candidate in ipairs(candidates) do
        local f = io.open(candidate, "r")
        if f then
            f:close()
            return candidate
        end
    end

    local result_file = "/tmp/mise-php-prebuilt-php-" .. os.time() .. ".txt"
    os.remove(result_file)

    os.execute("find '" .. sdkPath .. "' -type f -name php 2>/dev/null | head -n 1 > '" .. result_file .. "'")

    local f = io.open(result_file, "r")
    if not f then
        return nil
    end

    local candidate = f:read("*l")
    f:close()
    os.remove(result_file)

    if candidate == nil or candidate == "" then
        return nil
    end

    return candidate
end

function install_prebuilt_static_php(sdkPath, version)
    print("Preparing prebuilt static PHP...")

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    os.execute(string.format("mkdir -p '%s/bin' '%s/conf.d'", sdkPath, sdkPath))

    local php_bin = sdkPath .. "/bin/php"
    local php_exists = io.open(php_bin, "r")

    if php_exists then
        php_exists:close()
    else
        local candidate = find_prebuilt_php_binary(sdkPath)
        if not candidate then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "The downloaded static-php-cli archive did not contain a PHP CLI binary.\n" ..
                "Version: \27[93m" .. version .. "\27[0m\n"
            )
        end

        local copy_status = os.execute(string.format("cp '%s' '%s'", candidate, php_bin))
        if copy_status ~= 0 and copy_status ~= true then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "Could not copy the PHP binary into the expected bin directory.\n"
            )
        end
    end

    local chmod_status = os.execute('chmod +x "' .. php_bin .. '"' .. QUIET)
    if chmod_status ~= 0 and chmod_status ~= true then
        error(
            "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
            "Could not make the PHP binary executable.\n"
        )
    end

    local confFile = io.open(sdkPath .. "/conf.d/php.ini", "w")
    if confFile then
        confFile:write("# Add system-wide PHP configuration options here\n")
        confFile:close()
    end

    local status = os.execute('"' .. php_bin .. '" --version > /dev/null 2>&1')
    if status ~= 0 and status ~= true then
        error(
            "\n\nPrebuilt static PHP installation appears to be broken: 'php --version' failed.\n\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
    end

    print("Prebuilt static PHP installation complete!")

    if #PECL_EXTENSIONS > 0 or #PIE_EXTENSIONS > 0 then
        io.stderr:write(
            "\27[93mWarning:\27[0m PECL/PIE extension requests are skipped for prebuilt static PHP installs.\n" ..
            "Prebuilt static PHP already ships with a fixed extension set and is not a source-build toolchain.\n"
        )
    end

    if major > 8 or (major == 8 and minor >= 1) then
        install_pie(sdkPath, version)
    end

    install_composer(sdkPath, version)
end

function install_php_for_windows(sdkPath, version)
    -- Install PHP
    print("Installing PHP...")

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    local scriptPath = assert(RUNTIME.pluginDirPath .. "\\bin\\install-windows-php.ps1")
    local installCmd = string.format(
        'cmd /c "cd /d %%TEMP%% && powershell -NoProfile -ExecutionPolicy Bypass -File "%s" -Version %s -Arch x64 -CustomPath "%s""',
        scriptPath,
        version,
        sdkPath
    )
    local status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to install PHP.\n\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
    end

    -- Verify PHP installation
    local php_bin = sdkPath .. "\\php.exe"
    local ok, why, code = os.execute('"' .. php_bin .. '" --version > NUL 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        error(
            "\n\nPHP installation appears to be broken: 'php --version' failed.\n\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
    end
    print("PHP installation complete!")

    -- Install PIE and PIE extensions
    if major > 8 or (major == 8 and minor >= 1) then
        install_pie(sdkPath, version)
        install_pie_extensions(sdkPath, version)
    end

    -- Install Composer
    install_composer(sdkPath, version)
end

function install_php_for_linux(sdkPath, version)
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
        print("\27[96mNote:\27[0m Build output is hidden. Set PHP_VERBOSE=1 to see full output.")
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
            verbose_tip(version) ..
            see("debugging")
        )
    end

    -- Run configure
    print("Configuring PHP with options...")
    local configureCmd = string.format("cd '%s' && %s./configure %s" .. QUIET, sdkPath, envPrefix, configureOptions)
    status = os.execute(configureCmd)
    if status ~= 0 and status ~= true then
        local saved_log = ""
        local src_log = sdkPath .. "/config.log"
        local dst_log = "/tmp/mise-php-config-" .. version .. ".log"
        if os.execute("cp '" .. src_log .. "' '" .. dst_log .. "' 2>/dev/null") == 0 then
            saved_log = "💡 Tip: \27[93mCheck the configure log for details:\27[0m " .. dst_log .. "\n"
        end
        error(
            "\n\nFailed to configure PHP.\n\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
    end

    -- Build PHP
    print("Building PHP (this may take several minutes)...")
    local makeLog = "/tmp/mise-php-make-" .. version .. ".log"
    local makeCmd = string.format(
        "cd '%s' && %smake -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) > '%s' 2>&1",
        sdkPath,
        envPrefix,
        makeLog
    )
    if VERBOSE then
        print("\27[96mNote:\27[0m Capturing build output to " .. makeLog .. ", run 'tail -f " .. makeLog .. "' to watch")
    end
    status = os.execute(makeCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to build PHP.\n\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
    end

    -- Install PHP
    print("Installing PHP...")
    local installCmd = string.format("cd '%s' && %smake install" .. QUIET, sdkPath, envPrefix)
    status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to install PHP.\n\n" ..
            verbose_tip(version) ..
            see("debugging")
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
            verbose_tip(version) ..
            see("debugging")
        )
    end

    print("PHP installation complete!")

    -- Install PECL extensions
    if not (major > 8 or (major == 8 and minor >= 5)) then
        install_pecl_extensions(sdkPath, envPrefix, version)
    end

    -- Install PIE and PIE extensions
    if major > 8 or (major == 8 and minor >= 1) then
        install_pie(sdkPath, version)
        install_pie_extensions(sdkPath, version)
    end

    -- Install Composer
    install_composer(sdkPath, version)

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
    -- On Linux, most libraries are in standard paths
    configureOptions = configureOptions .. " --with-curl --with-readline --with-gettext"

    -- Check for GD dependencies
    local gd_check = os.execute("pkg-config --exists libpng 2>/dev/null")
    if gd_check == 0 or gd_check == true then
        configureOptions = configureOptions .. " --with-external-gd"
    end

    -- Check for PostgreSQL
    local pgsql_check = os.execute("pg_config --version 2>/dev/null")
    if pgsql_check == 0 or pgsql_check == true then
        configureOptions = configureOptions .. " --with-pdo-pgsql"
    end

    -- Check for libzip
    local zip_check = os.execute("pkg-config --exists libzip 2>/dev/null")
    if zip_check == 0 or zip_check == true then
        configureOptions = configureOptions .. " --with-zip"
    end

    return configureOptions
end

function install_pecl_extensions(sdkPath, envPrefix, version)
    -- Nothing to do when no PECL extensions were requested
    if #PECL_EXTENSIONS == 0 then
        return true
    end

    local phpize = sdkPath .. "/bin/phpize"
    local phpconfig = sdkPath .. "/bin/php-config"

    local f = io.open(phpize, "r")
    if not f then
        io.stderr:write(
            "\27[93mWarning:\27[0m phpize not found, skipping PECL extensions.\n" ..
            verbose_tip(version) ..
            see("extension-builds-require-phpize-and-build-tooling")
        )
        return false
    end
    f:close()

    local extensions = {}
    for _, name in ipairs(PECL_EXTENSIONS) do
        table.insert(extensions, { name = name, url = "https://pecl.php.net/get/" .. name })
    end

    local tmpdir = "/tmp/mise-php-pecl-" .. os.time()
    os.execute("mkdir -p '" .. tmpdir .. "'")

    local all_ok = true

    for _, ext in ipairs(extensions) do
        print("Installing PECL extension: " .. ext.name .. "...")
        local extdir = tmpdir .. "/" .. ext.name
        local cmd = string.format(
            "mkdir -p '%s' && cd '%s' && " ..
            "curl -fsSL '%s' | tar xz --strip-components=1 && " ..
            "%s '%s' && " ..
            "%s ./configure --with-php-config='%s' && " ..
            "%s make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) && " ..
            "%s make install",
            extdir, extdir,
            ext.url,
            envPrefix, phpize,
            envPrefix, phpconfig,
            envPrefix,
            envPrefix
        )
        if QUIET ~= "" then
            cmd = cmd .. QUIET
        end

        local status = os.execute(cmd)
        if status ~= 0 and status ~= true then
            io.stderr:write(
                "\27[93mWarning:\27[0m Failed to install " .. ext.name .. " PECL extension.\n" ..
                verbose_tip(version) ..
                see("extension-builds-require-phpize-and-build-tooling")
            )
            all_ok = false
        else
            local iniFile = io.open(sdkPath .. "/conf.d/" .. ext.name .. ".ini", "w")
            if iniFile then
                iniFile:write("extension=" .. ext.name .. ".so\n")
                iniFile:close()
            else
                io.stderr:write(
                    "\27[93mWarning:\27[0m Failed to write configuration for PECL extension " .. ext.name .. ".\n" ..
                    verbose_tip(version) ..
                    see("extension-builds-require-phpize-and-build-tooling")
                )
                all_ok = false
            end
        end
    end

    os.execute("rm -rf '" .. tmpdir .. "'")
    return all_ok
end

function install_pie(sdkPath, version)
    print("Installing PIE...")
    local ok
    if RUNTIME.osType == "windows" then
        ok = install_pie_for_windows(sdkPath, version)
    else
        ok = install_pie_for_linux(sdkPath, version)
    end

    if ok then
        print("PIE installation complete!")
    else
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE installation did not complete successfully.\n" ..
            verbose_tip(version) ..
            see("pie-verification-may-fail-or-time-out")
        )
    end
end

function install_pie_for_linux(sdkPath, version)
    local php_bin = sdkPath .. "/bin/php"
    local pie_bin = sdkPath .. "/bin/pie"
    local pie_phar = sdkPath .. "/pie.phar"

    -- Download PIE PHAR
    local dl_cmd = string.format(
        'curl -fsSL https://github.com/php/pie/releases/latest/download/pie.phar -o "%s"' .. QUIET,
        pie_phar
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to download PIE.\n" ..
            verbose_tip(version) ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Create PIE wrapper
    local wrapper = io.open(pie_bin, "w")
    if not wrapper then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create PIE wrapper.\n" ..
            verbose_tip(version) ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    wrapper:write("#!/usr/bin/env sh\n")
    wrapper:write('exec "' .. php_bin .. '" "' .. pie_phar .. '" "$@"\n')
    wrapper:close()

    -- Make PIE wrapper executable
    status = os.execute('chmod +x "' .. pie_bin .. '"' .. QUIET)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to make PIE wrapper executable.\n" ..
            verbose_tip(version) ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Verify PIE installation
    status = os.execute('timeout 20s "' .. pie_bin .. '" --version > /dev/null 2>&1')
    if status == 124 or status == 124 * 256 then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE verification timed out.\n" ..
            manual_tip("pie --version") ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE verification failed.\n" ..
            manual_tip("pie --version") ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    return true
end

function install_pie_for_windows(sdkPath, version)
    local sep = package.config:sub(1, 1)
    local function join_path(...)
        return table.concat({ ... }, sep)
    end

    local php_bin  = join_path(sdkPath, "php.exe")
    local pie_phar = join_path(sdkPath, "pie.phar")
    local pie_bat  = join_path(sdkPath, "pie.bat")

    -- Download PIE PHAR
    local dl_cmd = string.format(
        'powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://github.com/php/pie/releases/latest/download/pie.phar -OutFile \'%s\'"' .. QUIET,
        pie_phar
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to download PIE.\n" ..
            verbose_tip(version) ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Create PIE wrapper
    local bat = io.open(pie_bat, "w")
    if not bat then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create PIE wrapper.\n" ..
            verbose_tip(version) ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    bat:write('@echo off\r\n')
    bat:write(string.format('"%s" "%%~dp0pie.phar" %%*\r\n', php_bin))
    bat:close()

    -- Verify PIE installation
    local ok, why, code = os.execute('"' .. pie_bat .. '" --version > NUL 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE verification failed.\n" ..
            manual_tip("pie --version") ..
            see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    return true
end

function install_pie_extensions(sdkPath, version)
    -- Nothing to do when no PIE extensions were requested
    if #PIE_EXTENSIONS == 0 then
        return true
    end

    local ok
    if RUNTIME.osType == "windows" then
        ok = install_pie_extensions_for_windows(sdkPath, version)
    else
        ok = install_pie_extensions_for_linux(sdkPath, version)
    end

    if ok then
        print("PIE extensions installation complete!")
    else
        io.stderr:write(
            "\27[93mWarning:\27[0m One or more PIE extensions failed to install.\n" ..
            verbose_tip(version) ..
            see("extension-builds-require-phpize-and-build-tooling")
        )
    end

    return ok
end

function install_pie_extensions_for_linux(sdkPath, version)
    local php_bin = sdkPath .. "/bin/php"
    local phpize = sdkPath .. "/bin/phpize"
    local phpconfig = sdkPath .. "/bin/php-config"
    local pie_phar = sdkPath .. "/pie.phar"

    local f = io.open(pie_phar, "r")
    if not f then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE not found, skipping PIE extensions.\n" ..
            verbose_tip(version) ..
            see("extension-builds-require-phpize-and-build-tooling")
        )
        return false
    end
    f:close()

    local all_ok = true

    for _, pkg in ipairs(PIE_EXTENSIONS) do
        print("Installing PIE extension: " .. pkg .. "...")

        local cmd = string.format(
            '"%s" "%s" install --with-php-path="%s" --with-php-config="%s" --with-phpize-path="%s" "%s"%s',
            php_bin,
            pie_phar,
            php_bin,
            phpconfig,
            phpize,
            pkg,
            QUIET
        )

        local status = os.execute(cmd)
        if status ~= 0 and status ~= true then
            io.stderr:write(
                "\27[93mWarning:\27[0m Failed to install PIE extension package " .. pkg .. ".\n" ..
                verbose_tip(version) ..
                see("extension-builds-require-phpize-and-build-tooling")
            )
            all_ok = false
        end
    end

    return all_ok
end

function install_pie_extensions_for_windows(sdkPath, version)
    local sep = package.config:sub(1, 1)
    local function join_path(...)
        return table.concat({ ... }, sep)
    end

    local php_bin  = join_path(sdkPath, "php.exe")
    local pie_phar = join_path(sdkPath, "pie.phar")

    local f = io.open(pie_phar, "r")
    if not f then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE not found, skipping PIE extensions.\n" ..
            verbose_tip(version) ..
            see("extension-builds-require-phpize-and-build-tooling")
        )
        return false
    end
    f:close()

    local all_ok = true

    for _, pkg in ipairs(PIE_EXTENSIONS) do
        print("Installing PIE extension: " .. pkg .. "...")

        local cmd = string.format(
            '"%s" "%s" install --with-php-path="%s" "%s"%s',
            php_bin,
            pie_phar,
            php_bin,
            pkg,
            QUIET
        )

        local status = os.execute(cmd)
        if status ~= 0 and status ~= true then
            io.stderr:write(
                "\27[93mWarning:\27[0m Failed to install PIE extension package " .. pkg .. ".\n" ..
                verbose_tip(version) ..
                see("extension-builds-require-phpize-and-build-tooling")
            )
            all_ok = false
        end
    end

    return all_ok
end

function install_composer(sdkPath, version)
    print("Installing Composer...")
    local ok
    if RUNTIME.osType == "windows" then
        ok = install_composer_for_windows(sdkPath, version)
    else
        ok = install_composer_for_linux(sdkPath, version)
    end

    if ok then
        print("Composer installation complete!")
    else
        io.stderr:write(
            "\27[93mWarning:\27[0m Composer installation did not complete successfully.\n" ..
            verbose_tip(version) ..
            see("composer-verification-may-prompt-when-run-as-root")
        )
    end
end

function install_composer_for_windows(sdkPath, version)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Composer installation output is hidden. Set PHP_VERBOSE=1 to see full output.")
    end

    local sep = package.config:sub(1, 1)
    local function join_path(...)
        return table.concat({ ... }, sep)
    end

    local composer_phar = join_path(sdkPath, "composer.phar")
    local composer_bat  = join_path(sdkPath, "composer.bat")

    -- Download Composer PHAR
    local dl_cmd = string.format(
        'powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://getcomposer.org/composer-stable.phar -OutFile \'%s\'"' .. QUIET,
        composer_phar
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to download Composer.\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
        return false
    end

    local php_bin = join_path(sdkPath, "php.exe")

    -- Create Composer wrapper
    local bat = io.open(composer_bat, "w")
    if not bat then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create Composer wrapper.\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
        return false
    end

    bat:write('@echo off\r\n')
    bat:write(string.format('"%s" "%%~dp0composer.phar" %%*\r\n', php_bin))
    bat:close()

    -- Verify Composer installation
    local ok, why, code = os.execute('"' .. composer_bat .. '" --version > NUL 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        io.stderr:write(
            "\n\n\27[93mWarning:\27[0m Composer verification failed, but installation may still be usable.\n\n" ..
            manual_tip("composer --version") ..
            see("composer-verification-may-prompt-when-run-as-root")
        )
        return false
    end

    return true
end

function install_composer_for_linux(sdkPath, version)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Composer installation output is hidden. Set PHP_VERBOSE=1 to see full output.")
    end

    local sep = package.config:sub(1, 1)
    local function join_path(...)
        return table.concat({ ... }, sep)
    end

    local php_bin        = join_path(sdkPath, "bin", "php")
    local composer_setup = join_path(sdkPath, "composer-setup.php")
    local install_dir    = join_path(sdkPath, "bin")

    -- Download Composer installer
    local dl_cmd = string.format(
        'curl -fsSL https://getcomposer.org/installer -o "%s"' .. QUIET,
        composer_setup
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to install Composer.\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
        return false
    end

    -- Run Composer installer
    local install_cmd = string.format(
        '"%s" "%s" --install-dir="%s" --filename=composer' .. QUIET,
        php_bin,
        composer_setup,
        install_dir
    )
    status = os.execute(install_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to install Composer.\n" ..
            verbose_tip(version) ..
            see("debugging")
        )
        os.remove(composer_setup)
        return false
    end

    os.remove(composer_setup)

    -- Verify Composer installation
    local composer_bin = install_dir .. "/composer"
    local ok, why, code = os.execute(
        'COMPOSER_ALLOW_SUPERUSER=1 "' .. php_bin .. '" "' .. composer_bin .. '" --version > /dev/null 2>&1'
    )
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        io.stderr:write(
            "\n\n\27[93mWarning:\27[0m Composer verification failed, but installation may still be usable.\n\n" ..
            manual_tip("composer --version") ..
            see("composer-verification-may-prompt-when-run-as-root")
        )
        return false
    end

    return true
end
