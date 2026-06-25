local env = require("lib/env")
local messages = require("lib/messages")
local php_versions = require("lib/php_versions")
local tools = require("lib/tools")

local packages = {}

local VERBOSE         = env.VERBOSE
local QUIET           = env.QUIET
local PECL_EXTENSIONS = env.PECL_EXTENSIONS
local PIE_EXTENSIONS  = env.PIE_EXTENSIONS

local join_path = tools.join_path
local file_exists = tools.file_exists
local download_file = tools.download_file
local batch_path = tools.windows_cmd_quote

local function write_windows_phar_wrapper(wrapper_path, php_bin, phar_name, after_success_script)
    local content = '@echo off\r\n' ..
        string.format('%s "%%~dp0%s" %%*\r\n', batch_path(php_bin), phar_name)

    if after_success_script ~= nil and after_success_script ~= "" then
        content = content ..
            'set "MISE_PHP_EXIT_CODE=%ERRORLEVEL%"\r\n' ..
            string.format(
                'if "%%MISE_PHP_EXIT_CODE%%"=="0" %s "%%~dp0%s" >NUL 2>&1\r\n',
                batch_path(php_bin),
                after_success_script
            ) ..
            'exit /b %MISE_PHP_EXIT_CODE%\r\n'
    end

    return tools.write_file(wrapper_path, content)
end

local function sanitize_log_part(value)
    return tostring(value):gsub("[^%w%._%-]", "-")
end

local function utc_timestamp()
    return os.date("!%Y%m%dT%H%M%SZ")
end

local function temp_dir()
    if RUNTIME.osType == "windows" then
        return os.getenv("TEMP") or os.getenv("TMP") or "."
    end

    return os.getenv("TMPDIR") or "/tmp"
end

local function create_log_id(version)
    return sanitize_log_part(version) .. "-" .. utc_timestamp()
end

local function extension_log_path(log_id, pkg)
    return join_path(temp_dir(), "mise-php-" .. log_id .. "-pie-" .. sanitize_log_part(pkg) .. ".log")
end

local function write_log_header(path, label, command, cwd)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    file:write("# mise-php " .. label .. " log\n")
    file:write("# Started at: " .. utc_timestamp() .. "\n")
    if cwd and cwd ~= "" then
        file:write("# Working directory: " .. cwd .. "\n")
    end
    if command and command ~= "" then
        file:write("# Command: " .. command .. "\n")
    end
    file:write("\n")
    file:close()

    return true
end

local function append_log_output(path, output)
    local file = io.open(path, "ab")
    if not file then
        return false
    end

    local text = tostring(output or "")
    if text ~= "" then
        file:write(text)
        if text:sub(-1) ~= "\n" then
            file:write("\n")
        end
    end

    file:close()
    return true
end

local function print_file_tip(path, label)
    return "💡 Debug log: " .. path .. " (" .. label .. ")\n"
end

local function append_failed_package(failed_packages, pkg, log_path)
    failed_packages[#failed_packages + 1] = {
        name = pkg,
        log_path = log_path,
    }
end

local function failed_package_name(failed_package)
    if type(failed_package) == "table" then
        return failed_package.name
    end

    return failed_package
end

local function failed_packages_summary(failed_packages)
    if failed_packages == nil or #failed_packages == 0 then
        return ""
    end

    local names = {}
    for _, failed_package in ipairs(failed_packages) do
        names[#names + 1] = failed_package_name(failed_package)
    end

    return "Failed PIE extension packages: " .. table.concat(names, ", ") .. ".\n"
end

local function failed_packages_log_summary(failed_packages)
    if failed_packages == nil or #failed_packages == 0 then
        return ""
    end

    local summary = ""
    for _, failed_package in ipairs(failed_packages) do
        if type(failed_package) == "table" and failed_package.log_path ~= nil and failed_package.log_path ~= "" then
            summary = summary .. print_file_tip(failed_package.log_path, failed_package.name)
        end
    end

    return summary
end

local function windows_pie_normalizer_script()
    return [=[<?php
declare(strict_types=1);

$phpPath = realpath(__DIR__ . DIRECTORY_SEPARATOR . 'php.exe') ?: (__DIR__ . DIRECTORY_SEPARATOR . 'php.exe');
$extensionDir = ini_get('extension_dir') ?: (__DIR__ . DIRECTORY_SEPARATOR . 'ext');
$extensionDir = rtrim((string) $extensionDir, "\\/");
$pieRoot = getenv('APPDATA') ? getenv('APPDATA') . DIRECTORY_SEPARATOR . 'PIE' : null;

if ($pieRoot === null || ! is_dir($pieRoot) || ! is_dir($extensionDir)) {
    exit(0);
}

$normalizePath = static function (string $path): string {
    $real = realpath($path);
    $path = $real !== false ? $real : $path;
    return strtolower(str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $path));
};

$phpPathNormalized = $normalizePath($phpPath);
$extensionDirNormalized = $normalizePath($extensionDir);
$iniPath = php_ini_loaded_file() ?: null;
$iniContent = $iniPath !== null && is_file($iniPath) ? file_get_contents($iniPath) : false;
$iniChanged = false;

$iterator = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($pieRoot, FilesystemIterator::SKIP_DOTS)
);

foreach ($iterator as $file) {
    if ($file->getFilename() !== 'installed.json') {
        continue;
    }

    $jsonPath = $file->getPathname();
    $json = json_decode((string) file_get_contents($jsonPath), true);

    if (! is_array($json) || ! isset($json['packages']) || ! is_array($json['packages'])) {
        continue;
    }

    $changed = false;

    foreach ($json['packages'] as &$package) {
        if (! isset($package['extra']) || ! is_array($package['extra'])) {
            continue;
        }

        $extra = &$package['extra'];
        $targetPhp = $extra['pie-target-platform-php-path'] ?? null;
        $installedBinary = $extra['pie-installed-binary'] ?? null;

        if (! is_string($targetPhp) || ! is_string($installedBinary)) {
            continue;
        }

        if ($normalizePath($targetPhp) !== $phpPathNormalized) {
            continue;
        }

        if (! is_file($installedBinary)) {
            continue;
        }

        $binaryDirectory = dirname($installedBinary);
        if ($normalizePath($binaryDirectory) !== $extensionDirNormalized) {
            continue;
        }

        $binaryName = basename($installedBinary);
        if (! preg_match('/^php_([A-Za-z0-9_]+)\.dll$/', $binaryName, $matches)) {
            continue;
        }

        $extensionName = strtolower($matches[1]);
        $aliasBinary = $extensionDir . DIRECTORY_SEPARATOR . $extensionName . '.dll';

        if (! is_file($aliasBinary) || hash_file('sha256', $aliasBinary) !== hash_file('sha256', $installedBinary)) {
            copy($installedBinary, $aliasBinary);
        }

        $sourcePdb = preg_replace('/\.dll$/i', '.pdb', $installedBinary);
        $aliasPdb = preg_replace('/\.dll$/i', '.pdb', $aliasBinary);
        if (is_string($sourcePdb) && is_string($aliasPdb) && is_file($sourcePdb) && ! is_file($aliasPdb)) {
            copy($sourcePdb, $aliasPdb);
        }

        if (($extra['pie-installed-binary'] ?? null) !== $aliasBinary) {
            $extra['pie-installed-binary'] = $aliasBinary;
            $changed = true;
        }

        if ($iniContent !== false) {
            $pattern = '/^(\s*(?:zend_extension|extension)\s*=\s*)"?' . preg_quote($extensionName, '/') . '"?\s*$/mi';
            $replacement = '$1' . $extensionName . '.dll';
            $updatedIni = preg_replace($pattern, $replacement, $iniContent);

            if (is_string($updatedIni) && $updatedIni !== $iniContent) {
                $iniContent = $updatedIni;
                $iniChanged = true;
            }
        }
    }
    unset($package);

    if ($changed) {
        file_put_contents(
            $jsonPath,
            json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL,
            LOCK_EX
        );
    }
}

if ($iniChanged && $iniPath !== null && is_string($iniContent)) {
    file_put_contents($iniPath, $iniContent, LOCK_EX);
}
]=]
end

function packages.has_extension_requests()
    return #PECL_EXTENSIONS > 0 or #PIE_EXTENSIONS > 0
end

function packages.warn_prebuilt_static_extensions_skipped()
    io.stderr:write(
        "\27[93mWarning:\27[0m PECL/PIE extension requests are skipped for prebuilt static PHP installs.\n" ..
        "Prebuilt static PHP already ships with a fixed extension set and is not a source-build toolchain.\n"
    )
end

function packages.install_pecl_extensions(sdkPath, envPrefix, version)
    -- Nothing to do when no PECL extensions were requested
    if #PECL_EXTENSIONS == 0 then
        return true
    end

    local phpize = sdkPath .. "/bin/phpize"
    local phpconfig = sdkPath .. "/bin/php-config"

    if not file_exists(phpize) then
        io.stderr:write(
            "\27[93mWarning:\27[0m phpize not found, skipping PECL extensions.\n" ..
            messages.verbose_tip(version) ..
            messages.see("extension-builds-require-phpize-and-build-tooling")
        )
        return false
    end

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
                messages.verbose_tip(version) ..
                messages.see("extension-builds-require-phpize-and-build-tooling")
            )
            all_ok = false
        else
            if not tools.write_file(sdkPath .. "/conf.d/" .. ext.name .. ".ini", "extension=" .. ext.name .. ".so\n") then
                io.stderr:write(
                    "\27[93mWarning:\27[0m Failed to write configuration for PECL extension " .. ext.name .. ".\n" ..
                    messages.verbose_tip(version) ..
                    messages.see("extension-builds-require-phpize-and-build-tooling")
                )
                all_ok = false
            end
        end
    end

    os.execute("rm -rf '" .. tmpdir .. "'")
    return all_ok
end

function packages.install_pie(sdkPath, version)
    print("Installing PIE...")
    local ok
    if RUNTIME.osType == "windows" then
        ok = packages.install_pie_for_windows(sdkPath, version)
    else
        ok = packages.install_pie_for_linux(sdkPath, version)
    end

    if ok then
        print("PIE installation complete!")
    else
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE installation did not complete successfully.\n" ..
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
    end
end

function packages.install_pie_for_linux(sdkPath, version)
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
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Create PIE wrapper
    local wrapper = io.open(pie_bin, "w")
    if not wrapper then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create PIE wrapper.\n" ..
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
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
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Verify PIE installation
    status = os.execute('timeout 20s "' .. pie_bin .. '" --version > /dev/null 2>&1')
    if status == 124 or status == 124 * 256 then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE verification timed out.\n" ..
            messages.manual_tip("pie --version") ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end
    if status ~= 0 and status ~= true then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE verification failed.\n" ..
            messages.manual_tip("pie --version") ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    return true
end

function packages.install_pie_for_windows(sdkPath, version)
    local php_bin  = join_path(sdkPath, "php.exe")
    local pie_phar = join_path(sdkPath, "pie.phar")
    local pie_bat  = join_path(sdkPath, "pie.bat")
    local pie_normalizer = join_path(sdkPath, "pie-normalize-windows.php")

    -- Download PIE PHAR
    local ok, err = download_file("https://github.com/php/pie/releases/latest/download/pie.phar", pie_phar)
    if not ok then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to download PIE.\n" ..
            tostring(err or "download did not create the expected file") .. "\n" ..
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    if not tools.write_file(pie_normalizer, windows_pie_normalizer_script()) then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create PIE Windows normalizer.\n" ..
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Create PIE wrapper. The normalizer keeps PIE's Windows metadata in sync
    -- with DLL names copied from prebuilt extension archives.
    if not write_windows_phar_wrapper(pie_bat, php_bin, "pie.phar", "pie-normalize-windows.php") then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create PIE wrapper.\n" ..
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Verify PIE installation
    ok = tools.execute_windows_program(pie_bat, { "--version" })

    if not ok then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE verification failed.\n" ..
            messages.manual_tip("pie --version") ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    return true
end


function packages.install_pie_extensions(sdkPath, version)
    -- Nothing to do when no PIE extensions were requested
    if #PIE_EXTENSIONS == 0 then
        return true
    end

    local ok, failed_packages
    if RUNTIME.osType == "windows" then
        ok, failed_packages = packages.install_pie_extensions_for_windows(sdkPath, version)
    else
        ok, failed_packages = packages.install_pie_extensions_for_linux(sdkPath, version)
    end

    if ok then
        print("PIE extensions installation complete!")
    else
        local docs_anchor = (
            RUNTIME.osType == "windows"
            and "pie-for-php"
            or "extension-builds-require-phpize-and-build-tooling"
        )
        io.stderr:write(
            "\27[93mWarning:\27[0m One or more PIE extensions failed to install.\n" ..
            failed_packages_summary(failed_packages) ..
            failed_packages_log_summary(failed_packages) ..
            messages.verbose_tip(version) ..
            messages.see(docs_anchor)
        )
    end

    return ok
end

function packages.install_pie_extensions_for_linux(sdkPath, version)
    local php_bin = sdkPath .. "/bin/php"
    local phpize = sdkPath .. "/bin/phpize"
    local phpconfig = sdkPath .. "/bin/php-config"
    local pie_phar = sdkPath .. "/pie.phar"
    local log_id = create_log_id(version)

    if not file_exists(pie_phar) then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE not found, skipping PIE extensions.\n" ..
            messages.verbose_tip(version) ..
            messages.see("extension-builds-require-phpize-and-build-tooling")
        )
        return false, { "all requested PIE extensions" }
    end

    local all_ok = true
    local failed_packages = {}

    for _, pkg in ipairs(PIE_EXTENSIONS) do
        print("Installing PIE extension: " .. pkg .. "...")

        local log_file = extension_log_path(log_id, pkg)
        local command = string.format(
            'PATH="%s/bin:$PATH" "%s" "%s" install --with-php-path="%s" --with-php-config="%s" --with-phpize-path="%s" "%s"',
            sdkPath,
            php_bin,
            pie_phar,
            php_bin,
            phpconfig,
            phpize,
            pkg
        )
        write_log_header(log_file, "PIE extension " .. pkg, command, sdkPath)

        local cmd = command .. " >> " .. tools.shell_quote(log_file) .. " 2>&1"

        local status = os.execute(cmd)
        if status ~= 0 and status ~= true then
            append_failed_package(failed_packages, pkg, log_file)
            all_ok = false
        else
            os.remove(log_file)
            print("PIE extension installed: " .. pkg)
        end
    end

    return all_ok, failed_packages
end

function packages.install_pie_extensions_for_windows(sdkPath, version)
    local php_bin  = join_path(sdkPath, "php.exe")
    local pie_phar = join_path(sdkPath, "pie.phar")
    local pie_bat  = join_path(sdkPath, "pie.bat")
    local log_id = create_log_id(version)

    if not file_exists(pie_phar) then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE not found, skipping PIE extensions.\n" ..
            messages.verbose_tip(version) ..
            messages.see("extension-builds-require-phpize-and-build-tooling")
        )
        return false, { "all requested PIE extensions" }
    end

    local all_ok = true
    local failed_packages = {}

    for _, pkg in ipairs(PIE_EXTENSIONS) do
        print("Installing PIE extension: " .. pkg .. "...")

        local log_file = extension_log_path(log_id, pkg)
        local command = table.concat({
            batch_path(pie_bat),
            "install",
            batch_path("--with-php-path=" .. php_bin),
            batch_path(pkg),
        }, " ")
        write_log_header(log_file, "PIE extension " .. pkg, command, sdkPath)

        local ok, _, _, output = tools.execute_windows_program(pie_bat, {
            "install",
            "--with-php-path=" .. php_bin,
            pkg,
        }, {
            capture_only = not VERBOSE,
        })
        append_log_output(log_file, output)

        if not ok then
            append_failed_package(failed_packages, pkg, log_file)
            all_ok = false
        else
            os.remove(log_file)
            print("PIE extension installed: " .. pkg)
        end
    end

    return all_ok, failed_packages
end

function packages.install_composer(sdkPath, version)
    print("Installing Composer...")
    local ok
    if RUNTIME.osType == "windows" then
        ok = packages.install_composer_for_windows(sdkPath, version)
    else
        ok = packages.install_composer_for_linux(sdkPath, version)
    end

    if ok then
        print("Composer installation complete!")
    else
        io.stderr:write(
            "\27[93mWarning:\27[0m Composer installation did not complete successfully.\n" ..
            messages.verbose_tip(version) ..
            messages.see("composer-verification-may-prompt-when-run-as-root")
        )
    end
end

function packages.install_composer_for_windows(sdkPath, version)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Composer installation output is hidden. Set PHP_VERBOSE=1 to see full output.")
    end

    local composer_phar = join_path(sdkPath, "composer.phar")
    local composer_bat  = join_path(sdkPath, "composer.bat")

    -- Download Composer PHAR
    local ok, err = download_file("https://getcomposer.org/composer-stable.phar", composer_phar)
    if not ok then
        io.stderr:write(
            "\27[91mError:\27[0m Failed to download Composer.\n" ..
            tostring(err or "download did not create the expected file") .. "\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
        return false
    end

    local php_bin = join_path(sdkPath, "php.exe")

    -- Create Composer wrapper. This .bat is the runtime shim users invoke; no
    -- temporary command runner files are created.
    if not write_windows_phar_wrapper(composer_bat, php_bin, "composer.phar") then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create Composer wrapper.\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
        return false
    end

    -- Verify Composer installation
    ok = tools.execute_windows_program(composer_bat, { "--version" })

    if not ok then
        io.stderr:write(
            "\n\n\27[93mWarning:\27[0m Composer verification failed, but installation may still be usable.\n\n" ..
            messages.manual_tip("composer --version") ..
            messages.see("composer-verification-may-prompt-when-run-as-root")
        )
        return false
    end

    return true
end


function packages.install_composer_for_linux(sdkPath, version)
    if not VERBOSE then
        print("\27[96mNote:\27[0m Composer installation output is hidden. Set PHP_VERBOSE=1 to see full output.")
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
            messages.verbose_tip(version) ..
            messages.see("debugging")
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
            messages.verbose_tip(version) ..
            messages.see("debugging")
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
            messages.manual_tip("composer --version") ..
            messages.see("composer-verification-may-prompt-when-run-as-root")
        )
        return false
    end

    return true
end



function packages.install_after_php(sdkPath, version, installInfo)
    installInfo = installInfo or {}

    if installInfo.kind == "static" then
        if packages.has_extension_requests() then
            packages.warn_prebuilt_static_extensions_skipped()
        end

        if php_versions.at_least(version, 8, 1) then
            packages.install_pie(sdkPath, version)
        end

        packages.install_composer(sdkPath, version)
        return
    end

    if installInfo.kind == "source" then
        if not php_versions.at_least(version, 8, 5) then
            packages.install_pecl_extensions(sdkPath, installInfo.env_prefix or "", version)
        end
    end

    if php_versions.at_least(version, 8, 1) then
        packages.install_pie(sdkPath, version)
        packages.install_pie_extensions(sdkPath, version)
    end

    packages.install_composer(sdkPath, version)
end

return packages
