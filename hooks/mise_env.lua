local env = require("env")
local options = require("lib/options")

--- Returns environment variables to set when this plugin is active
--- Documentation: https://mise.jdx.dev/env-plugin-development.html#miseenv-hook
--- @param ctx {options: table} Context (options = plugin configuration from mise.toml)
--- @return table[] List of environment variable definitions with key/value pairs
function PLUGIN:MiseEnv(ctx)
    -- object for child process envs
    local env_vars = {}

    if options.enabled(options.get(ctx, "skip_deps")) then
        -- for current process
        env.setenv("PHP_SKIP_DEPS", 1)
        -- for child process
        -- table.insert(env_vars, { key = "PHP_SKIP_DEPS", value = "1" })
    end

    if options.enabled(options.get(ctx, "verbose")) then
        env.setenv("PHP_VERBOSE", 1)
    end

    local extra_configure_options = options.get(ctx, "extra_configure_options")
    if extra_configure_options ~= nil and extra_configure_options ~= "" and extra_configure_options ~= false then
        env.setenv("PHP_EXTRA_CONFIGURE_OPTIONS", tostring(extra_configure_options))
    end

    local configure_options = options.get(ctx, "configure_options")
    if configure_options ~= nil and configure_options ~= "" and configure_options ~= false then
        env.setenv("PHP_CONFIGURE_OPTIONS", tostring(configure_options))
    end

    if options.enabled(options.get(ctx, "prebuilt_static")) then
        env.setenv("PHP_PREBUILT_STATIC", 1)
    end

    local prebuilt_static_flavor = options.get(ctx, "prebuilt_static_flavor")
    if prebuilt_static_flavor ~= nil and prebuilt_static_flavor ~= "" and prebuilt_static_flavor ~= false then
        env.setenv("PHP_PREBUILT_STATIC_FLAVOR", tostring(prebuilt_static_flavor))
    end

    local pecl_extensions = options.get(ctx, "pecl_extensions")
    if pecl_extensions ~= nil and pecl_extensions ~= "" and pecl_extensions ~= false then
        env.setenv("PHP_PECL_EXTENSIONS", tostring(pecl_extensions))
    end

    local pie_extensions = options.get(ctx, "pie_extensions")
    if pie_extensions ~= nil and pie_extensions ~= "" and pie_extensions ~= false then
        env.setenv("PHP_PIE_EXTENSIONS", tostring(pie_extensions))
    end

    return env_vars
end
