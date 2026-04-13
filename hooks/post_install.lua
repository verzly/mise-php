local env = require("lib/env")

local VERBOSE   = env.VERBOSE
local QUIET     = env.QUIET
local SKIP_DEPS = env.SKIP_DEPS

--- Performs additional setup after installation
--- Documentation: https://mise.jdx.dev/tool-plugin-development.html#postinstall-hook
--- @param ctx {rootPath: string, runtimeVersion: string, sdkInfo: table} Context
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local version = sdkInfo.version
    local sdkPath = sdkInfo.path

    if RUNTIME.osType == "windows" then
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
            "Then run \27[93mwsl --shutdown\27[0m from Windows, update your \27[93m~/.bashrc\27[0m if needed, and restart the installation.\n"

        error(warning)
    end
end

function install_php_for_windows(sdkPath, version)
    -- Install PHP
    print("Installing PHP...")

    local scriptPath = assert(RUNTIME.pluginDirPath .. "\\bin\\install-windows-php.ps1")
    local installCmd = string.format(
        'cmd /c "cd /d %%TEMP%% && powershell -NoProfile -ExecutionPolicy Bypass -File "%s" -Version %s -Arch x64 -CustomPath "%s""',
        scriptPath,
        version,
        sdkPath
    )
    local status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error("Failed to install PHP")
    end

    -- Verify PHP installation
    local php_bin = sdkPath .. "\\php.exe"
    local ok, why, code = os.execute('"' .. php_bin .. '" --version > NUL 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        error(
            "\n\nPHP installation appears to be broken: 'php --version' failed.\n\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. version .. "'\27[0m to see the full output, fix the reported issue, and restart the installation.\n"
        )
    end
    print("PHP installation complete!")

    -- Install Composer
    install_composer(sdkPath)
end

local function normalize_build_profile()
    local profile = os.getenv("PHP_BUILD_PROFILE") or "full"
    profile = string.lower(profile)

    if profile ~= "full" and profile ~= "minimal" then
        io.stderr:write(
            "\27[93mWarning:\27[0m Unknown PHP_BUILD_PROFILE='" .. profile .. "', using 'full'.\n"
        )
        profile = "full"
    end

    return profile
end

local function build_configure_options_for_profile(sdkPath, version, profile)
    local configureOptions = "--prefix='" .. sdkPath .. "'"

    local requiredOptions = [[
        --sysconfdir=']] .. sdkPath .. [['
        --with-config-file-path=']] .. sdkPath .. [['
        --with-config-file-scan-dir=']] .. sdkPath .. [[/conf.d'
        --with-openssl
        --with-zlib
        --enable-mbstring
    ]]

    local fullOptions = [[
        --enable-bcmath
        --enable-calendar
        --enable-dba
        --enable-exif
        --enable-fpm
        --enable-ftp
        --enable-gd
        --enable-intl
        --enable-mbregex
        --enable-mysqlnd
        --enable-pcntl
        --enable-shmop
        --enable-soap
        --enable-sockets
        --enable-sysvmsg
        --enable-sysvsem
        --enable-sysvshm
        --with-curl
        --with-mhash
        --with-mysqli=mysqlnd
        --with-pdo-mysql=mysqlnd
        --without-pcre-jit
        --without-snmp
    ]]

    local minimalOptions = [[
        --without-pcre-jit
        --without-snmp
    ]]

    requiredOptions = string.gsub(requiredOptions, "%s+", " ")
    fullOptions = string.gsub(fullOptions, "%s+", " ")
    minimalOptions = string.gsub(minimalOptions, "%s+", " ")

    configureOptions = configureOptions .. " " .. requiredOptions

    if profile == "minimal" then
        configureOptions = configureOptions .. " " .. minimalOptions
    else
        configureOptions = configureOptions .. " " .. fullOptions
    end

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0
    if major > 8 or (major == 8 and minor >= 5) then
        configureOptions = configureOptions .. " --without-pear"
    else
        configureOptions = configureOptions .. " --with-pear"
    end

    return configureOptions
end

function install_php_for_linux(sdkPath, version)
    fail_if_windows_php_is_visible_or_hangs()
    
    local os_type = RUNTIME.osType
    local buildProfile = normalize_build_profile()
    print("Using PHP build profile: " .. buildProfile)

    local envPrefix = ""
    local configureOptions = build_configure_options_for_profile(sdkPath, version, buildProfile)

    if os_type == "darwin" then
        local homebrew_prefix = os.getenv("HOMEBREW_PREFIX") or "/opt/homebrew"
        configureOptions, envPrefix = configure_macos(configureOptions, homebrew_prefix)
    else
        configureOptions = configure_linux(configureOptions)
    end

    -- Allow user to override configure options
    local extraOptions = os.getenv("PHP_EXTRA_CONFIGURE_OPTIONS")
    if extraOptions ~= nil and extraOptions ~= "" then
        configureOptions = configureOptions .. " " .. extraOptions
    end

    local userOptions = os.getenv("PHP_CONFIGURE_OPTIONS")
    if userOptions ~= nil and userOptions ~= "" then
        -- User provided full options, use those instead (but keep prefix)
        configureOptions = "--prefix='" .. sdkPath .. "' " .. userOptions
    end

    if not VERBOSE then
        print("\27[96mNote:\27[0m Build output is hidden. Set PHP_VERBOSE=1 to see full output.")
    end
    
    -- Run buildconf
    print("Running buildconf...")
    local buildconfCmd = string.format("cd '%s' && ./buildconf --force" .. QUIET, sdkPath)
    local status = os.execute(buildconfCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to run buildconf.\n\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. version .. "'\27[0m to see the full output, fix the reported issue, and restart the installation.\n"
        )
    end

    -- Run configure
    print("Configuring PHP with options...")
    local configureCmd = string.format("cd '%s' && %s./configure %s" .. QUIET, sdkPath, envPrefix, configureOptions)
    status = os.execute(configureCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to configure PHP.\n\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. version .. "'\27[0m to see the full output, fix the reported issue, and restart the installation.\n"
        )
    end

    -- Build PHP
    print("Building PHP (this may take several minutes)...")
    local makeCmd =
        string.format("cd '%s' && %smake -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)" .. QUIET, sdkPath, envPrefix)
    status = os.execute(makeCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to build PHP.\n\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. version .. "'\27[0m to see the full output, fix the reported issue, and restart the installation.\n"
        )
    end

    -- Install PHP
    print("Installing PHP...")
    local installCmd = string.format("cd '%s' && %smake install" .. QUIET, sdkPath, envPrefix)
    status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error(
            "\n\nFailed to install PHP.\n\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. version .. "'\27[0m to see the full output, fix the reported issue, and restart the installation.\n"
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
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. version .. "'\27[0m to see the full output, fix the reported issue, and restart the installation.\n"
        )
    end

    print("PHP installation complete!")

    -- Install Composer
    install_composer(sdkPath)

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
    -- Note: bzip2 doesn't have pkgconfig, freetype/libpng depend on it
    -- So we don't add freetype/libpng to PKG_CONFIG_PATH, instead rely on path-based detection
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
            -- Check for /bin for path_only packages, /lib for others
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

    -- Set FREETYPE2 flags to bypass pkg-config (bzip2 doesn't have .pc file)
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
        if existing ~= "" then val = val .. " " .. existing end
        envPrefix = envPrefix .. 'export LDFLAGS="' .. val .. '" && '
    end
    if #cppflags > 0 then
        local existing = os.getenv("CPPFLAGS") or ""
        local val = table.concat(cppflags, " ")
        if existing ~= "" then val = val .. " " .. existing end
        envPrefix = envPrefix .. 'export CPPFLAGS="' .. val .. '" && '
    end

    -- Add external-gd if we have the dependencies
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
    configureOptions = configureOptions .. " --with-openssl --with-curl --with-readline --with-gettext"

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

function install_composer(sdkPath)
    print("Installing Composer...")
    if RUNTIME.osType == 'windows' then
        install_composer_for_windows(sdkPath)
    else
        install_composer_for_linux(sdkPath)
    end
    print("Composer installation complete!")
end

function install_composer_for_windows(sdkPath)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Composer installation output is hidden. Set PHP_VERBOSE=1 to see full output.")
    end

    -- Install Composer
    local sep = package.config:sub(1,1)
    local function join_path(...)
        return table.concat({...}, sep)
    end

    local composer_phar = join_path(sdkPath, "composer.phar")
    local composer_bat  = join_path(sdkPath, "composer.bat")

    local dl_cmd = string.format(
        'powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://getcomposer.org/composer-stable.phar -OutFile \'%s\'"' .. QUIET,
        composer_phar
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to download Composer.\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. (version or "VERSION") .. "'\27[0m to see the full output.\n"
        )
        return
    end

    local php_bin = join_path(sdkPath, "php.exe")
    local bat = io.open(composer_bat, "w")
    if bat then
        bat:write('@echo off\r\n')
        bat:write(string.format('"%s" "%%~dp0composer.phar" %%*\r\n', php_bin))
        bat:close()
    end

    -- Verify Composer installation
    local ok, why, code = os.execute('"' .. php_bin .. '" "' .. composer_phar .. '" --version > NUL 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        io.stderr:write(
            "\n\n\27[93mWarning:\27[0m Composer verification failed, but installation may still be usable.\n\n" ..
            "💡 Tip: \27[93mRun 'composer --version'\27[0m manually after installation to confirm it works.\n"
        )
    end
end

function install_composer_for_linux(sdkPath)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Composer installation output is hidden. Set PHP_VERBOSE=1 to see full output.")
    end
    
    -- Install Composer
    local sep = package.config:sub(1,1)
    local function join_path(...)
        return table.concat({...}, sep)
    end

    local php_bin        = join_path(sdkPath, "bin", "php")
    local composer_setup = join_path(sdkPath, "composer-setup.php")
    local install_dir    = join_path(sdkPath, "bin")

    local dl_cmd = string.format(
        '%s -r "copy(\'https://getcomposer.org/installer\', \'%s\');"' .. QUIET,
        php_bin, composer_setup
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to install Composer.\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. (version or "VERSION") .. "'\27[0m to see the full output.\n"
        )
    end

    local install_cmd = string.format(
        '%s "%s" --install-dir="%s" --filename=composer' .. QUIET,
        php_bin, composer_setup, install_dir
    )
    status = os.execute(install_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to install Composer.\n" ..
            "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. (version or "VERSION") .. "'\27[0m to see the full output.\n"
        )
    end

    os.remove(composer_setup)

    -- Verify Composer installation
    local composer_bin = install_dir .. "/composer"
    local ok, why, code = os.execute('"' .. php_bin .. '" "' .. composer_bin .. '" --version > /dev/null 2>&1')
    if not ok or (why and (why ~= "exit" or code ~= 0)) or ok == nil then
        io.stderr:write(
            "\n\n\27[93mWarning:\27[0m Composer verification failed, but installation may still be usable.\n\n" ..
            "💡 Tip: \27[93mRun 'composer --version'\27[0m manually after installation to confirm it works.\n"
        )
    end
end
