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

local function parse_pecl_extensions()
    local val = os.getenv("PHP_PECL_EXTENSIONS")
    if val == nil or val == "" then return {} end
    local extensions = {}
    for ext in val:gmatch("[^,%s]+") do
        table.insert(extensions, ext)
    end
    return extensions
end

local function parse_pie_extensions()
    local val = os.getenv("PHP_PIE_EXTENSIONS")
    if val == nil or val == "" then return {} end
    local extensions = {}
    for ext in val:gmatch("[^,%s]+") do
        table.insert(extensions, ext)
    end
    return extensions
end

local VERBOSE         = is_verbose()
local QUIET           = quiet_redirect()
local SKIP_DEPS       = is_enabled("PHP_SKIP_DEPS")
local PECL_EXTENSIONS = parse_pecl_extensions()
local PIE_EXTENSIONS  = parse_pie_extensions()
local PREBUILT_STATIC = is_enabled("PHP_PREBUILT_STATIC")
local PREBUILT_STATIC_FLAVOR = os.getenv("PHP_PREBUILT_STATIC_FLAVOR") or ""

return {
    VERBOSE         = VERBOSE,
    QUIET           = QUIET,
    SKIP_DEPS       = SKIP_DEPS,
    PECL_EXTENSIONS = PECL_EXTENSIONS,
    PIE_EXTENSIONS  = PIE_EXTENSIONS,
    PREBUILT_STATIC = PREBUILT_STATIC,
    PREBUILT_STATIC_FLAVOR = PREBUILT_STATIC_FLAVOR,
}
