local env = require("env")

--- Returns environment variables to set when this plugin is active
--- Documentation: https://mise.jdx.dev/env-plugin-development.html#miseenv-hook
--- @param ctx {options: table} Context (options = plugin configuration from mise.toml)
--- @return table[] List of environment variable definitions with key/value pairs
function PLUGIN:MiseEnv(ctx)
    local options = ctx.options or {}
    -- object for child process envs
    local env_vars = {}

    if options.skip_deps == true or options.skip_deps == "true" or options.skip_deps == "1" then
        -- for current process
        env.setenv("PHP_SKIP_DEPS", 1)
        -- for child process
        -- table.insert(env_vars, { key = "PHP_SKIP_DEPS", value = "1" })    
    end

    if options.verbose == true or options.verbose == "true" or options.verbose == "1" then
        env.setenv("PHP_VERBOSE", 1)
    end

    if options.extra_configure_options ~= nil and options.extra_configure_options ~= "" and options.extra_configure_options ~= false then
        env.setenv("PHP_EXTRA_CONFIGURE_OPTIONS", tostring(options.extra_configure_options))
    end

    if options.configure_options ~= nil and options.configure_options ~= "" and options.configure_options ~= false then
        env.setenv("PHP_CONFIGURE_OPTIONS", tostring(options.configure_options))
    end

    if options.prebuilt_static == true or options.prebuilt_static == "true" or options.prebuilt_static == "1" then
        env.setenv("PHP_PREBUILT_STATIC", 1)
    end

    if options.prebuilt_static_flavor ~= nil and options.prebuilt_static_flavor ~= "" and options.prebuilt_static_flavor ~= false then
        env.setenv("PHP_PREBUILT_STATIC_FLAVOR", tostring(options.prebuilt_static_flavor))
    end

    if options.pecl_extensions ~= nil and options.pecl_extensions ~= "" and options.pecl_extensions ~= false then
        env.setenv("PHP_PECL_EXTENSIONS", tostring(options.pecl_extensions))
    end

    if options.pie_extensions ~= nil and options.pie_extensions ~= "" and options.pie_extensions ~= false then
        env.setenv("PHP_PIE_EXTENSIONS", tostring(options.pie_extensions))
    end

    return env_vars
end
