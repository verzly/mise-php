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

local function write_windows_phar_wrapper(wrapper_path, php_bin, phar_name)
    return tools.write_file(
        wrapper_path,
        '@echo off\r\n' .. string.format('%s "%%~dp0%s" %%*\r\n', batch_path(php_bin), phar_name)
    )
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

    -- Create PIE wrapper. This .bat is the runtime shim users invoke; no
    -- temporary command runner files are created.
    if not write_windows_phar_wrapper(pie_bat, php_bin, "pie.phar") then
        io.stderr:write(
            "\27[93mWarning:\27[0m Failed to create PIE wrapper.\n" ..
            messages.verbose_tip(version) ..
            messages.see("pie-verification-may-fail-or-time-out")
        )
        return false
    end

    -- Verify PIE installation
    ok = tools.execute_cmd(string.format(
        '"%s" --version',
        pie_bat
    ), QUIET);

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

    local ok
    if RUNTIME.osType == "windows" then
        ok = packages.install_pie_extensions_for_windows(sdkPath, version)
    else
        ok = packages.install_pie_extensions_for_linux(sdkPath, version)
    end

    if ok then
        print("PIE extensions installation complete!")
    else
        io.stderr:write(
            "\27[93mWarning:\27[0m One or more PIE extensions failed to install.\n" ..
            messages.verbose_tip(version) ..
            messages.see("extension-builds-require-phpize-and-build-tooling")
        )
    end

    return ok
end

function packages.install_pie_extensions_for_linux(sdkPath, version)
    local php_bin = sdkPath .. "/bin/php"
    local phpize = sdkPath .. "/bin/phpize"
    local phpconfig = sdkPath .. "/bin/php-config"
    local pie_phar = sdkPath .. "/pie.phar"

    if not file_exists(pie_phar) then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE not found, skipping PIE extensions.\n" ..
            messages.verbose_tip(version) ..
            messages.see("extension-builds-require-phpize-and-build-tooling")
        )
        return false
    end

    local all_ok = true

    for _, pkg in ipairs(PIE_EXTENSIONS) do
        print("Installing PIE extension: " .. pkg .. "...")

        local cmd = string.format(
            'PATH="%s/bin:$PATH" "%s" "%s" install --with-php-path="%s" --with-php-config="%s" --with-phpize-path="%s" "%s"%s',
            sdkPath,
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
                messages.verbose_tip(version) ..
                messages.see("extension-builds-require-phpize-and-build-tooling")
            )
            all_ok = false
        end
    end

    return all_ok
end

function packages.install_pie_extensions_for_windows(sdkPath, version)
    local php_bin  = join_path(sdkPath, "php.exe")
    local pie_phar = join_path(sdkPath, "pie.phar")

    if not file_exists(pie_phar) then
        io.stderr:write(
            "\27[93mWarning:\27[0m PIE not found, skipping PIE extensions.\n" ..
            messages.verbose_tip(version) ..
            messages.see("extension-builds-require-phpize-and-build-tooling")
        )
        return false
    end

    local all_ok = true

    for _, pkg in ipairs(PIE_EXTENSIONS) do
        print("Installing PIE extension: " .. pkg .. "...")

        local ok = tools.execute_cmd(string.format(
            '"%s" "%s" install --with-php-path="%s" "%s"',
            php_bin,
            pie_phar,
            php_bin,
            pkg
        ), QUIET);

        if not ok then
            io.stderr:write(
                "\27[93mWarning:\27[0m Failed to install PIE extension package " .. pkg .. ".\n" ..
                messages.verbose_tip(version) ..
                messages.see("extension-builds-require-phpize-and-build-tooling")
            )

            all_ok = false
        end
    end

    return all_ok
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
    ok = tools.execute_cmd(string.format(
        '"%s" --version',
        composer_bat
    ), QUIET);

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
