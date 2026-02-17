local util = require('util')

--- Each SDK may have different environment variable configurations.
--- This allows plugins to define custom environment variables (including PATH settings)
--- Note: Be sure to distinguish between environment variable settings for different platforms!
--- @param ctx table Context information
--- @field ctx.path string SDK installation directory
function PLUGIN:EnvKeys(ctx)
    --- this variable is same as ctx.sdkInfo['plugin-name'].path
    local mainPath = ctx.path
    local bin = ""
    local composerHome = ""

    if RUNTIME.osType == 'windows' then
        bin = mainPath .. "\\"
        composerHome = mainPath .. "\\.composer"
        composerBin = composerHome .. "\\vendor\\bin"
    else
        bin = mainPath .. "/bin"
        composerHome = mainPath .. "/.composer"
        composerBin = composerHome .. "/vendor/bin"
    end

    util.ensure_dir(composerHome)

    return {
        {
            key = "PATH",
            value = bin
        },
        {
            key = "PATH",
            value = composerBin
        },
        {
            key = "COMPOSER_HOME",
            value = composerHome
        }
    }
end
