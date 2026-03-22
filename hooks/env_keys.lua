--- Returns environment variables for PHP
--- @param ctx table Context provided by vfox
--- @return table Environment configuration
function PLUGIN:EnvKeys(ctx)
    local sdkInfo = ctx.sdkInfo["php"]
    local installDir = sdkInfo.path

    local envs = {}

    -- Add PATHs on Windows
    if RUNTIME.osType == 'windows' then
        table.insert(envs, {
            key = "PATH",
            value = installDir,
        })

    -- Add PATHs on Linux & macOS
    else
        table.insert(envs, {
            key = "PATH",
            value = installDir .. "/bin",
        })
        table.insert(envs, {
            key = "PATH",
            value = installDir .. "/sbin",
        })

        -- Add LD_LIBRARY_PATH on Linux
        if RUNTIME.osType == "linux" then
          table.insert(envs, {
              key = "LD_LIBRARY_PATH",
              value = installDir .. "/lib",
          })
        end
    end

    return envs
end
