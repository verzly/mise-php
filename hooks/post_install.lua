local http = require('http')
local util = require('util')
require('constants')

function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo['php']
    local path = sdkInfo.path
    local version = sdkInfo.version

    if RUNTIME.osType == 'windows' then
        InstallComposerForWin(path)
    else
        InstallPHPWithPhpBuild(path, version)
    end
end

function InstallPHPWithPhpBuild(install_path, version)
    local php_build_dir = install_path .. "_tmp"
    local php_build_exe = php_build_dir .. "/bin/php-build"
    local php_build_deps_exe = php_build_dir .. "/install-dependencies.sh"
    
    -- Download php-build
    local exists = os.execute("test -d " .. php_build_dir .. " >/dev/null 2>&1")
    if exists ~= 0 then
        local ok, code, out = util.run_cmd("git clone https://github.com/php-build/php-build " .. php_build_dir)
        if not ok then
            error("Failed to clone php-build: " .. out)
        end
    end

    -- Install deps
    local cmd = string.format(
        'bash "%s"',
        php_build_deps_exe
    )
    local ok, code, out = util.run_cmd(cmd)
    if not ok then
        error("Failed to run install-dependencies.sh: " .. out)
    end

    -- Permission
    local ok, code, out = util.run_cmd("chmod +x " .. php_build_exe)
    if not ok then
        error("Failed to chmod php-build: " .. out)
    end

    -- Install PHP
    local handle = io.popen("nproc")
    local nproc_str = handle:read("*l")
    handle:close()
    local nproc_num = tonumber(nproc_str) or 1
    local cmd = string.format("MAKEFLAGS='-j%d' bash %s %s %s", nproc_num, php_build_exe, version, install_path)
    local ok, code, out = util.run_cmd(cmd)
    if not ok then
        error("PHP build failed for version " .. version .. "\nOutput:\n" .. out)
    end

    -- Remove temporary php-build
    util.run_cmd("rm -rf " .. php_build_dir)

    -- Install Composer
    InstallComposer(install_path)
end

function InstallComposer(path)
    local resp, err = http.get({ url = 'https://getcomposer.org/installer' })
    if not resp or not resp.body then
        error('Failed to download Composer installer: ' .. tostring(err))
    end

    local setupPath = path .. '/composer-setup.php'
    local ok, err = util.write_file(setupPath, resp.body)
    if not ok then
        error('Failed to write composer-setup.php: ' .. tostring(err))
    end

    local phpExe = path .. '/bin/php'
    local cmd = string.format('"%s" "%s" --install-dir="%s/bin" --filename=composer', phpExe, setupPath, path)
    local ok, code, out = util.run_cmd(cmd)
    if not ok then
        error('Failed to install Composer. Output:\n' .. out)
    end

    util.run_cmd('chmod +x ' .. path .. '/bin/composer')
    util.run_cmd('rm -f ' .. setupPath)
end

function InstallComposerForWin(path)
    local content, err = util.read_file(path .. '\\php.ini-development')
    if not content then
        error('Failed to read php.ini-development: ' .. tostring(err))
    end

    content = content:gsub(';%s*extension_dir%s*=.*', 'extension_dir = "ext"')
    content = content:gsub(';extension=openssl', 'extension=openssl')
    content = content:gsub(';extension=php_openssl.dll', 'extension=php_openssl.dll')

    local ok, err = util.write_file(path .. '\\php.ini', content)
    if not ok then
        error('Failed to write php.ini: ' .. tostring(err))
    end

    local resp, err = http.get({ url = 'https://getcomposer.org/installer' })
    if not resp or not resp.body then
        error('Failed to download Composer installer: ' .. tostring(err))
    end

    local setupPath = path .. '\\composer-setup.php'
    local ok, err = util.write_file(setupPath, resp.body)
    if not ok then
        error('Failed to write composer-setup.php: ' .. tostring(err))
    end

    local phpExe = '"' .. path .. '\\php.exe"'
    local installDir = path
    local cmd = string.format('%s "%s" --install-dir="%s" --filename=composer', phpExe, setupPath, installDir)
    local ok, code, out = util.run_cmd(cmd)
    if not ok then
        error('Failed to install Composer. Output:\n' .. out)
    end

    util.run_cmd('rm -f ' .. setupPath)

    local batContent = '@php "%~dp0composer.phar" %*'
    local ok, err = util.write_file(path .. '\\composer.bat', batContent)
    if not ok then
        error('Failed to write composer.bat: ' .. tostring(err))
    end
end
