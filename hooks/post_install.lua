--- Compiles and installs PHP from source
--- @param ctx table Context provided by vfox
--- @field ctx.sdkInfo table SDK information with version and path
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local version = sdkInfo.version
    local sdkPath = sdkInfo.path

    if RUNTIME.osType == 'windows' then
        install_php_for_windows(sdkPath, version)
    else
        install_php_for_linux(sdkPath, version)
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

    -- Install Composer
    install_composer(sdkPath)

    -- Clean up source files to save space
    local cleanCmd = string.format(
        'cmd /c "cd /d "%s" && rmdir /s /q Zend ext sapi main TSRM build 2>nul && del /f /q configure* aclocal* Makefile* 2>nul"',
        sdkPath
    )
    os.execute(cleanCmd)

    print("PHP installation complete!")
end

function install_php_for_linux(sdkPath, version)
    -- mise extracts tarball to sdkPath, with top-level directory stripped
    -- So sdkPath IS the source directory (php-src-php-X.Y.Z contents)

    local os_type = RUNTIME.osType
    local homebrew_prefix = os.getenv("HOMEBREW_PREFIX") or "/opt/homebrew"

    -- Build environment and configure options
    local envPrefix = ""
    local configureOptions = "--prefix='" .. sdkPath .. "'"

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
        --with-mysqli=mysqlnd
        --with-pdo-mysql=mysqlnd
        --with-zlib
        --with-pear
        --without-pcre-jit
        --without-snmp
    ]]

    -- Clean up whitespace in common options
    commonOptions = string.gsub(commonOptions, "%s+", " ")
    configureOptions = configureOptions .. " " .. commonOptions

    if os_type == "darwin" then
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

    -- Run buildconf
    print("Running buildconf...")
    local buildconfCmd = string.format("cd '%s' && ./buildconf --force", sdkPath)
    local status = os.execute(buildconfCmd)
    if status ~= 0 and status ~= true then
        error("Failed to run buildconf")
    end

    -- Run configure
    print("Configuring PHP with options...")
    local configureCmd = string.format("cd '%s' && %s./configure %s", sdkPath, envPrefix, configureOptions)
    status = os.execute(configureCmd)
    if status ~= 0 and status ~= true then
        error("Failed to configure PHP")
    end

    -- Build PHP
    print("Building PHP (this may take several minutes)...")
    local makeCmd =
        string.format("cd '%s' && make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)", sdkPath)
    status = os.execute(makeCmd)
    if status ~= 0 and status ~= true then
        error("Failed to build PHP")
    end

    -- Install PHP
    print("Installing PHP...")
    local installCmd = string.format("cd '%s' && make install", sdkPath)
    status = os.execute(installCmd)
    if status ~= 0 and status ~= true then
        error("Failed to install PHP")
    end

    -- Create conf.d directory
    os.execute(string.format("mkdir -p '%s/conf.d'", sdkPath))
    local confFile = io.open(sdkPath .. "/conf.d/php.ini", "w")
    if confFile then
        confFile:write("# Add system-wide PHP configuration options here\n")
        confFile:close()
    end

    -- Install Composer
    install_composer(sdkPath)

    -- Clean up source files to save space
    print("Cleaning up source files...")
    local cleanCmd = string.format(
        "cd '%s' && rm -rf Zend ext sapi main TSRM build configure* aclocal* Makefile* 2>/dev/null",
        sdkPath
    )
    os.execute(cleanCmd)

    print("PHP installation complete!")
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
    local sep = package.config:sub(1,1)
    local function join_path(...)
        return table.concat({...}, sep)
    end

    local composer_phar = join_path(sdkPath, "composer.phar")
    local composer_bat  = join_path(sdkPath, "composer.bat")

    local dl_cmd = string.format(
        'powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri https://getcomposer.org/composer-stable.phar -OutFile \'%s\'"',
        composer_phar
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write("Warning: Failed to download Composer\n")
        return
    end

    local bat = io.open(composer_bat, "w")
    if bat then
        bat:write('@echo off\r\n')
        bat:write(string.format('"%s" "%%~dp0composer.phar" %%*\r\n', join_path(sdkPath, "php.exe")))
        bat:close()
    end
end

function install_composer_for_linux(sdkPath)
    local sep = package.config:sub(1,1)
    local function join_path(...)
        return table.concat({...}, sep)
    end

    local php_bin        = join_path(sdkPath, "bin", "php")
    local composer_setup = join_path(sdkPath, "composer-setup.php")
    local install_dir    = join_path(sdkPath, "bin")

    local dl_cmd = string.format(
        '%s -r "copy(\'https://getcomposer.org/installer\', \'%s\');"',
        php_bin, composer_setup
    )
    local status = os.execute(dl_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write("Warning: Failed to download Composer installer\n")
        return
    end

    local install_cmd = string.format(
        '%s "%s" --install-dir="%s" --filename=composer',
        php_bin, composer_setup, install_dir
    )
    status = os.execute(install_cmd)
    if status ~= 0 and status ~= true then
        io.stderr:write("Warning: Failed to install Composer\n")
    end

    os.remove(composer_setup)
end
