local http = require('http')
local util = require('util')

--- Extension point, called after PreInstall
function PLUGIN:PostInstall(ctx)
    local sdkInfo = ctx.sdkInfo['php']
    local path = sdkInfo.path

    if RUNTIME.osType == 'windows' then
        InstallComposerForWin(path)
    else
        CompileInstallPHP(path)
    end
end

function InstallComposerForWin(path)
    -- Read php.ini-development
    local content, err = util.read_file(path .. '\\php.ini-development')
    if not content then
        error('Failed to read php.ini-development: ' .. tostring(err))
    end

    -- Enable extensions
    content = content:gsub(';%s*extension_dir%s*=.*', 'extension_dir = "ext"')
    content = content:gsub(';extension=openssl', 'extension=openssl')
    content = content:gsub(';extension=php_openssl.dll', 'extension=php_openssl.dll')

    -- Write php.ini
    local ok, err = util.write_file(path .. '\\php.ini', content)
    if not ok then
        error('Failed to write php.ini: ' .. tostring(err))
    end

    -- Download Composer installer
    local resp, err = http.get({ url = 'https://getcomposer.org/installer' })
    if not resp or not resp.body then
        error('Failed to download Composer installer: ' .. tostring(err))
    end

    local setupPath = path .. '\\composer-setup.php'
    local ok, err = util.write_file(setupPath, resp.body)
    if not ok then
        error('Failed to write composer-setup.php: ' .. tostring(err))
    end

    -- Execute Composer installer
    local phpExe = '"' .. path .. '\\php.exe"'
    local installDir = '"' .. path .. '"'
    local execString = phpExe .. ' "' .. setupPath .. '" --install-dir=' .. installDir

    local code = os.execute(execString)
    if code ~= 0 then
        error('Failed to install Composer. Exit code: ' .. tostring(code))
    end

    -- Clean up
    os.remove(setupPath)

    -- Create composer.bat wrapper
    local batContent = '@php "%~dp0composer.phar" %*'
    local ok, err = util.write_file(path .. '\\composer.bat', batContent)
    if not ok then
        error('Failed to write composer.bat: ' .. tostring(err))
    end
end

function CompileInstallPHP(path)
    -- Make install script executable
    os.execute('chmod +x ' .. RUNTIME.pluginDirPath .. '/bin/install')

    local code = os.execute(RUNTIME.pluginDirPath .. '/bin/install ' .. path)
    if code ~= 0 then
        error('PHP compilation failed. Exit code: ' .. tostring(code))
    end
end
