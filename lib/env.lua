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

local VERBOSE   = is_verbose()
local QUIET     = VERBOSE and "" or " > /dev/null 2>&1"
local SKIP_DEPS = is_enabled("PHP_SKIP_DEPS")

return {
    VERBOSE   = VERBOSE,
    QUIET     = QUIET,
    SKIP_DEPS = SKIP_DEPS,
}
