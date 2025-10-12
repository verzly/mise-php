--- Each SDK may have different environment variable configurations.
--- This allows plugins to define custom environment variables (including PATH settings)
--- Note: Be sure to distinguish between environment variable settings for different platforms!
--- @param ctx table Context information
--- @field ctx.path string SDK installation directory
function PLUGIN:EnvKeys(ctx)
    --- this variable is same as ctx.sdkInfo['plugin-name'].path
    local mainPath = ctx.path
    local bin = ""
    if RUNTIME.osType ~= "windows" then
        bin = "/bin"
    end

    return {
        {
            key = "PATH",
            value = mainPath .. bin
        }
    }
end
