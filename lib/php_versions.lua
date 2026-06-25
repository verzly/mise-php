local versions = {}

local ALIASES = {
    stable = true,
    latest = true,
    prerelease = true,
}

-- mise reverses vfox/tool-plugin available output before displaying it.
-- Insert aliases at the beginning so the CLI displays them as the final
-- entries in this order: stable, latest, prerelease.
local ALIAS_ORDER = { "stable", "latest", "prerelease" }

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function lower(value)
    return string.lower(trim(value))
end

local function safe_index(value, key)
    if value == nil then
        return nil
    end

    local ok, result = pcall(function()
        return value[key]
    end)

    if ok then
        return result
    end

    return nil
end

local function truthy(value)
    if value == true then
        return true
    end

    if value == nil or value == false then
        return false
    end

    value = lower(value)
    return value ~= "" and value ~= "0" and value ~= "false" and value ~= "no"
end

local function getenv(name)
    local ok, value = pcall(os.getenv, name)

    if ok then
        return value
    end

    return nil
end

local function runtime_os()
    local ok, value = pcall(function()
        return RUNTIME.osType
    end)

    if ok then
        return value
    end

    return nil
end

local function read_command_output(command)
    local ok, handle = pcall(io.popen, command)

    if not ok or handle == nil then
        return nil
    end

    local read_ok, output = pcall(function()
        return handle:read("*a")
    end)

    pcall(function()
        handle:close()
    end)

    if read_ok then
        return output
    end

    return nil
end

local function command_line_has_prerelease_flag(command_line)
    command_line = tostring(command_line or "")

    return command_line:match("%-%-prereleases?%f[%A]") ~= nil
end

local function process_command_line_has_prerelease_flag()
    -- vfox/tool-plugin hooks do not currently receive the ls-remote
    -- --prerelease CLI flag in ctx.args. As a best-effort fallback, inspect the
    -- current mise command line from the hook process. This keeps ordinary
    -- ls-remote stable-only while making native `mise ls-remote --prerelease`
    -- work for this plugin backend.
    local os_type = runtime_os()
    local output = nil

    if os_type == "windows" then
        output = read_command_output([[powershell -NoProfile -ExecutionPolicy Bypass -Command "$pidToRead=$PID; for($i=0; $i -lt 6; $i++){ $p=Get-CimInstance Win32_Process -Filter "ProcessId=$pidToRead"; if($null -eq $p){ break }; if($p.CommandLine){ $p.CommandLine }; $pidToRead=$p.ParentProcessId }"]])
    else
        output = read_command_output([[ps -o args= -p "$PPID" 2>/dev/null]])
    end

    return command_line_has_prerelease_flag(output)
end

function versions.at_least(version, major, minor)
    local current_major, current_minor = tostring(version):match("^(%d+)%.(%d+)")
    current_major = tonumber(current_major) or 0
    current_minor = tonumber(current_minor) or 0

    if current_major > major then
        return true
    end

    return current_major == major and current_minor >= minor
end

function versions.is_alias(version)
    return ALIASES[lower(version)] == true
end

function versions.is_stable(version)
    return trim(version):match("^%d+%.%d+%.%d+$") ~= nil
end

function versions.is_prerelease(version)
    if versions.is_alias(version) then
        return false
    end

    return not versions.is_stable(version)
end

function versions.available_record(version, created_at)
    local record = {
        version = trim(version),
        prerelease = versions.is_prerelease(version),
    }

    if created_at ~= nil and created_at ~= "" then
        record.created_at = created_at
    end

    return record
end

local function has_version(records, version)
    local normalized = lower(version)

    for _, record in ipairs(records) do
        if lower(record.version) == normalized then
            return true
        end
    end

    return false
end

local function has_matching(records, predicate)
    for _, record in ipairs(records) do
        if not versions.is_alias(record.version) and predicate(record) then
            return true
        end
    end

    return false
end

function versions.append_aliases(records, alias_source_records)
    alias_source_records = alias_source_records or records

    local aliases = {
        stable = has_matching(alias_source_records, function(record)
            return not record.prerelease
        end),
        latest = has_matching(alias_source_records, function(_)
            return true
        end),
        prerelease = has_matching(alias_source_records, function(record)
            return record.prerelease
        end),
    }

    for _, alias in ipairs(ALIAS_ORDER) do
        if aliases[alias] and not has_version(records, alias) then
            table.insert(records, 1, {
                version = alias,
                prerelease = false,
                rolling = true,
            })
        end
    end

    return records
end

function versions.prerelease_flag_enabled(ctx)
    if truthy(getenv("MISE_PRERELEASES")) or truthy(getenv("MISE_PRERELEASE")) then
        return true
    end

    if process_command_line_has_prerelease_flag() then
        return true
    end

    if ctx == nil then
        return false
    end

    if truthy(safe_index(ctx, "prerelease")) or truthy(safe_index(ctx, "prereleases")) then
        return true
    end

    local options = safe_index(ctx, "options")
    if type(options) == "table" then
        if truthy(safe_index(options, "prerelease")) or truthy(safe_index(options, "prereleases")) then
            return true
        end
    end

    local args = safe_index(ctx, "args")
    if type(args) == "table" then
        for key, value in pairs(args) do
            local key_text = lower(key)
            local value_text = lower(value)

            if truthy(value) and (
                key_text == "prerelease" or
                key_text == "prereleases" or
                key_text == "include_prerelease" or
                key_text == "include_prereleases"
            ) then
                return true
            end

            if value_text == "--prerelease" or
                value_text == "--prereleases" or
                value_text == "prerelease" or
                value_text == "prereleases" then
                return true
            end
        end
    end

    return false
end

local function requested_version(ctx)
    if ctx == nil then
        return ""
    end

    return trim(safe_index(ctx, "version") or safe_index(ctx, "runtimeVersion") or "")
end

local function is_numeric_fuzzy_request(version)
    return trim(version):match("^%d+$") ~= nil or trim(version):match("^%d+%.%d+$") ~= nil
end

function versions.should_include_prereleases(ctx)
    if versions.prerelease_flag_enabled(ctx) then
        return true
    end

    local requested = requested_version(ctx)
    local requested_lower = lower(requested)

    if requested_lower == "latest" or requested_lower == "prerelease" then
        return true
    end

    -- Explicit non-stable versions such as 8.5.8RC1 must remain installable even
    -- when ordinary fuzzy requests like php@8 still prefer the latest stable.
    if requested ~= "" and not is_numeric_fuzzy_request(requested) and versions.is_prerelease(requested) then
        return true
    end

    return false
end

function versions.filter_for_available(records, ctx)
    if versions.should_include_prereleases(ctx) then
        return records
    end

    local result = {}

    for _, record in ipairs(records or {}) do
        if not record.prerelease then
            table.insert(result, record)
        end
    end

    return result
end

local function numeric_parts(version)
    local major, minor, patch, suffix = tostring(version):match("^(%d+)%.(%d+)%.(%d+)(.*)$")

    return tonumber(major) or 0,
        tonumber(minor) or 0,
        tonumber(patch) or 0,
        suffix or ""
end

local function prerelease_number(version)
    local suffix = select(4, numeric_parts(version))
    return tonumber(tostring(suffix):match("(%d+)$")) or 0
end

local function suffix_order(version)
    if versions.is_stable(version) then
        return 5
    end

    local suffix = lower(select(4, numeric_parts(version))):gsub("^[%-%._]+", "")

    if suffix:match("^rc%d*$") then
        return 4
    end

    if suffix:match("^beta%d*$") or suffix:match("^b%d*$") then
        return 3
    end

    if suffix:match("^alpha%d*$") then
        return 2
    end

    return 1
end

local function sort_key(version)
    local major, minor, patch, suffix = numeric_parts(version)

    return major,
        minor,
        patch,
        suffix_order(version),
        prerelease_number(version),
        lower(suffix)
end

function versions.greater_than(a, b)
    local a_major, a_minor, a_patch, a_suffix_order, a_prerelease_number, a_suffix = sort_key(a)
    local b_major, b_minor, b_patch, b_suffix_order, b_prerelease_number, b_suffix = sort_key(b)

    if a_major ~= b_major then return a_major > b_major end
    if a_minor ~= b_minor then return a_minor > b_minor end
    if a_patch ~= b_patch then return a_patch > b_patch end
    if a_suffix_order ~= b_suffix_order then return a_suffix_order > b_suffix_order end
    if a_prerelease_number ~= b_prerelease_number then return a_prerelease_number > b_prerelease_number end

    return a_suffix > b_suffix
end

local function actual_records(records)
    local result = {}

    for _, record in ipairs(records or {}) do
        if record.version ~= nil and not versions.is_alias(record.version) then
            table.insert(result, record)
        end
    end

    return result
end

local function best_matching(records, predicate)
    local best = nil

    for _, record in ipairs(actual_records(records)) do
        if predicate(record) and (best == nil or versions.greater_than(record.version, best.version)) then
            best = record
        end
    end

    return best
end

local function matches_numeric_prefix(version, requested)
    version = lower(version)
    requested = trim(requested)

    local major = requested:match("^(%d+)$")
    if major ~= nil then
        return version:match("^" .. major .. "%.") ~= nil
    end

    local req_major, req_minor = requested:match("^(%d+)%.(%d+)$")
    if req_major ~= nil then
        return version:match("^" .. req_major .. "%." .. req_minor .. "%.") ~= nil
    end

    return false
end

function versions.resolve_requested_version(records, requested, include_prereleases)
    requested = trim(requested)

    if requested == "" or lower(requested) == "stable" then
        return best_matching(records, function(record)
            return not record.prerelease
        end)
    end

    if lower(requested) == "latest" then
        return best_matching(records, function(_)
            return true
        end)
    end

    if lower(requested) == "prerelease" then
        return best_matching(records, function(record)
            return record.prerelease
        end)
    end

    local exact = best_matching(records, function(record)
        return lower(record.version) == lower(requested)
    end)

    if exact ~= nil then
        return exact
    end

    if not requested:match("^%d+%.?%d*$") then
        return nil
    end

    if include_prereleases then
        local preferred_prerelease = best_matching(records, function(record)
            return matches_numeric_prefix(record.version, requested)
        end)

        if preferred_prerelease ~= nil then
            return preferred_prerelease
        end
    end

    return best_matching(records, function(record)
        return matches_numeric_prefix(record.version, requested) and not record.prerelease
    end)
end

return versions
