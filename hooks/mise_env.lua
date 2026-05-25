local env = require("env")
local options = require("lib/options")

local function set_env(env_vars, key, value)
    local str_value = tostring(value)

    -- for current process, so install hooks can read the values immediately
    env.setenv(key, str_value)

    -- for child process envs, so `mise env --dotenv` and `mise exec` expose them too
    table.insert(env_vars, { key = key, value = str_value })
end

--- Returns environment variables to set when this plugin is active
--- Documentation: https://mise.jdx.dev/env-plugin-development.html#miseenv-hook
--- @param ctx {options: table} Context (options = plugin configuration from mise.toml)
--- @return table[] List of environment variable definitions with key/value pairs
function PLUGIN:MiseEnv(ctx)
    -- object for child process envs
    local env_vars = {}

    if options.enabled(options.get(ctx, "skip_deps")) then
        set_env(env_vars, "PHP_SKIP_DEPS", 1)
    end

    if options.enabled(options.get(ctx, "verbose")) then
        set_env(env_vars, "PHP_VERBOSE", 1)
    end

    local extra_configure_options = options.get(ctx, "extra_configure_options")
    if extra_configure_options ~= nil and extra_configure_options ~= "" and extra_configure_options ~= false then
        set_env(env_vars, "PHP_EXTRA_CONFIGURE_OPTIONS", extra_configure_options)
    end

    local configure_options = options.get(ctx, "configure_options")
    if configure_options ~= nil and configure_options ~= "" and configure_options ~= false then
        set_env(env_vars, "PHP_CONFIGURE_OPTIONS", configure_options)
    end

    if options.enabled(options.get(ctx, "prebuilt_static")) then
        set_env(env_vars, "PHP_PREBUILT_STATIC", 1)
    end

    local prebuilt_static_flavor = options.get(ctx, "prebuilt_static_flavor")
    if prebuilt_static_flavor ~= nil and prebuilt_static_flavor ~= "" and prebuilt_static_flavor ~= false then
        set_env(env_vars, "PHP_PREBUILT_STATIC_FLAVOR", prebuilt_static_flavor)
    end


    local dependency_profile = options.get(ctx, "dependency_profile")
    if dependency_profile ~= nil and dependency_profile ~= "" and dependency_profile ~= false then
        set_env(env_vars, "PHP_DEPS_PROFILE", dependency_profile)
    end

    if options.enabled(options.get(ctx, "install_optional_deps")) then
        set_env(env_vars, "PHP_INSTALL_OPTIONAL_DEPS", 1)
    end

    local pecl_extensions = options.get(ctx, "pecl_extensions")
    if pecl_extensions ~= nil and pecl_extensions ~= "" and pecl_extensions ~= false then
        set_env(env_vars, "PHP_PECL_EXTENSIONS", pecl_extensions)
    end

    local pie_extensions = options.get(ctx, "pie_extensions")
    if pie_extensions ~= nil and pie_extensions ~= "" and pie_extensions ~= false then
        set_env(env_vars, "PHP_PIE_EXTENSIONS", pie_extensions)
    end

    return env_vars
end
