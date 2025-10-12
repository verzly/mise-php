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

    local asset_name
    if RUNTIME.osType == "windows" then
        asset_name = "php-" .. release.version .. "-win-x64.zip"
    elseif RUNTIME.osType == "linux" then
        asset_name = "php-" .. release.version .. ".tar.gz"
    elseif RUNTIME.osType == "macos" then
        asset_name = "php-" .. release.version .. "-mac.tar.gz"
    else
        error("Unsupported OS: " .. tostring(RUNTIME.osType))
    end

    return {
        version = release.version,
        name = asset_name,
        url = release.url .. asset_name
    }
end
