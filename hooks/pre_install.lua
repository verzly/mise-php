local util = require('util')
require('constants')

function PLUGIN:PreInstall(ctx)
    local version = ctx.version
    local releases = self:Available({})

    if not releases or #releases == 0 then
        error("⚠️ No releases available.")
    end

    if version == "latest" or version == "" then
        version = releases[1].version
    end

    local release = nil
    for _, r in ipairs(releases) do
        if r.version == version then
            release = r
            break
        end
    end

    if not release then
        error("Version not found: " .. version)
    end

    if RUNTIME.osType == 'windows' then
        return GetReleaseForWindows(release)
    else
        InstallDependencies()
        return GetReleaseForLinux(release)
    end
end

function GetReleaseForWindows(release)
    asset_name = "php-" .. release.version .. "-win-x64.zip"
    download_url = release.url .. asset_name

    return {
        version = release.version,
        url = download_url,
    }
end

function GetReleaseForLinux(release)
    -- asset_name = "php-" .. release.version .. ".tar.gz"
    -- download_url = release.url .. asset_name

    return {
        version = release.version,
        -- url = download_url, -- PHP-Build will be download.
    }
end

function InstallDependencies()
    os.execute('chmod +x ' .. RUNTIME.pluginDirPath .. '/bin/install-dependencies.sh')
    local ok, code, out = util.run_cmd(RUNTIME.pluginDirPath .. '/bin/install-dependencies.sh')
    if not ok then
        error('An unexpected error occurred while installing dependencies.' .. "\nOutput:\n" .. out)
    end
end
