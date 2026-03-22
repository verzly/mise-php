--- Returns pre-install information for PHP
--- @param ctx table Context provided by vfox
--- @return table Pre-install info
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
        return get_release_for_windows(release)
    else
        install_dependencies()
        return get_release_for_linux(release)
    end
end

function get_release_for_windows(release)
    -- Download from GitHub php-src releases
    return {
        version = release.version,
        -- url = "",
    }
end

function get_release_for_linux(release)
    -- Download from GitHub php-src releases
    return {
        version = release.version,
        url = "https://github.com/php/php-src/archive/php-" .. version .. ".tar.gz",
    }
end

function install_dependencies()
    print("Installing dependencies...")
    local path = RUNTIME.pluginDirPath .. '/bin/install-dependencies.sh'
    os.execute('chmod +x ' .. path)
    status = os.execute(path)
    if status ~= 0 and status ~= true then
        error("Failed to install dependencies")
    end
end
