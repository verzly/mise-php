local options = require("lib/options")

local function is_enabled(env_var)
    local v = os.getenv(env_var)
    if v == nil then return false end
    return v ~= "" and v ~= "0" and v ~= "false"
end

local function is_verbose()
    if is_enabled("PHP_VERBOSE") then return true end
    if is_enabled("MISE_VERBOSE") then return true end
    return false
end

local function quiet_redirect()
    if is_verbose() then
        return ""
    end

    if RUNTIME ~= nil and RUNTIME.osType == "windows" then
        return " > NUL 2>&1"
    end

    return " > /dev/null 2>&1"
end

local function validate_package_token(env_var, value, allow_slash)
    if value == nil or value == "" then
        error(env_var .. " contains an empty package name")
    end

    local pattern = allow_slash and "^[%w][%w%._%-%/]*$" or "^[%w][%w%._%-]*$"
    if not value:match(pattern) or value:find("..", 1, true) then
        error(
            env_var .. " contains an unsupported package name: " .. value .. "\n" ..
            "Use plain package identifiers only: letters, numbers, dot, underscore, dash" ..
            (allow_slash and ", and optionally one slash for vendor/package names." or ".")
        )
    end

    if allow_slash then
        local slash_count = 0
        for _ in value:gmatch("/") do
            slash_count = slash_count + 1
        end

        if slash_count > 1 or value:sub(-1) == "/" then
            error(env_var .. " contains an unsupported package name: " .. value)
        end
    end
end

local function parse_pecl_extensions(val)
    if val == nil or val == "" then return {} end
    local extensions = {}
    for ext in val:gmatch("[^,%s]+") do
        validate_package_token("PHP_PECL_EXTENSIONS", ext, false)
        table.insert(extensions, ext)
    end
    return extensions
end

local function parse_pie_extensions(val)
    if val == nil or val == "" then return {} end
    local extensions = {}
    for ext in val:gmatch("[^,%s]+") do
        validate_package_token("PHP_PIE_EXTENSIONS", ext, true)
        table.insert(extensions, ext)
    end
    return extensions
end

local M = {}

local function selected(ctx, option, variable)
    local value = options.get(ctx, option)
    if value ~= nil then
        local value_type = type(value)
        if option == "skip_deps" or option == "prebuilt_static" then
            if value_type ~= "boolean" and value_type ~= "string" then
                error(option .. " must be a boolean or string")
            end
        elseif value_type ~= "string" and value ~= false then
            error(option .. " must be a string or false")
        end
        if value == false then return "" end
        return tostring(value)
    end
    return os.getenv(variable)
end

function M.resolve(ctx)
    local pecl = selected(ctx, "pecl_extensions", "PHP_PECL_EXTENSIONS")
    local pie = selected(ctx, "pie_extensions", "PHP_PIE_EXTENSIONS")
    return {
        VERBOSE = is_verbose(),
        QUIET = quiet_redirect(),
        SKIP_DEPS = options.enabled(selected(ctx, "skip_deps", "PHP_SKIP_DEPS")),
        PREBUILT_STATIC = options.enabled(selected(ctx, "prebuilt_static", "PHP_PREBUILT_STATIC")),
        PREBUILT_STATIC_FLAVOR = selected(ctx, "prebuilt_static_flavor", "PHP_PREBUILT_STATIC_FLAVOR") or "",
        CONFIGURE_OPTIONS = selected(ctx, "configure_options", "PHP_CONFIGURE_OPTIONS"),
        EXTRA_CONFIGURE_OPTIONS = selected(ctx, "extra_configure_options", "PHP_EXTRA_CONFIGURE_OPTIONS"),
        PECL_EXTENSIONS_RAW = pecl,
        PIE_EXTENSIONS_RAW = pie,
        PECL_EXTENSIONS = parse_pecl_extensions(pecl),
        PIE_EXTENSIONS = parse_pie_extensions(pie),
    }
end

-- Non-install helpers still use the ambient verbosity at module load.
M.VERBOSE = is_verbose()
M.QUIET = quiet_redirect()

return M
