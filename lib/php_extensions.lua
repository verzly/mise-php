local env = require("lib/env")
local messages = require("lib/messages")
local process = require("lib/process")
local tools = require("lib/tools")

local M = {}

local VERBOSE = env.VERBOSE

local function normalize_name(value)
    value = tostring(value or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("^php_", "")
    value = value:gsub("%.dll$", "")
    value = value:gsub("%.so$", "")

    return string.lower(value)
end

local function command_for(php_bin)
    if tools.is_windows() then
        return tools.windows_cmd_quote(php_bin) .. " -m"
    end

    return tools.shell_quote(php_bin) .. " -m"
end

local function module_set(output)
    local modules = {}

    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local name = normalize_name(line)
        if name ~= "" and not name:match("^%[.*%]$") then
            modules[name] = true
        end
    end

    return modules
end

local function unique_expected(expected)
    local result = {}
    local seen = {}

    for _, name in ipairs(expected or {}) do
        local normalized = normalize_name(name)
        if normalized ~= "" and not seen[normalized] then
            seen[normalized] = true
            result[#result + 1] = normalized
        end
    end

    table.sort(result)
    return result
end

local function has_startup_warning(output)
    local text = string.lower(tostring(output or ""))

    return text:find("php startup:", 1, true) ~= nil
        or text:find("unable to load dynamic library", 1, true) ~= nil
end

local function output_excerpt(output)
    output = tostring(output or "")
    if output == "" then
        return ""
    end

    local lines = {}
    local count = 0
    for line in output:gmatch("[^\r\n]+") do
        count = count + 1
        if count <= 80 then
            lines[#lines + 1] = line
        end
    end

    if count > 80 then
        lines[#lines + 1] = "... output truncated ..."
    end

    return "php -m output:\n" .. table.concat(lines, "\n") .. "\n\n"
end

function M.add(expected, value)
    if type(value) == "table" then
        for _, item in ipairs(value) do
            M.add(expected, item)
        end
        return expected
    end

    local name = normalize_name(value)
    if name ~= "" then
        expected[#expected + 1] = name
    end

    return expected
end

function M.verify_loaded(php_bin, expected, version)
    local expected_extensions = unique_expected(expected)
    if #expected_extensions == 0 then
        return true
    end

    local result = process.run(command_for(php_bin))
    if not result.ok then
        error(
            "\n\nPHP extension verification failed: 'php -m' failed.\n\n" ..
            output_excerpt(result.output) ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    if has_startup_warning(result.output) then
        error(
            "\n\nPHP extension verification failed: PHP reported startup warnings while loading extensions.\n\n" ..
            output_excerpt(result.output) ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    local loaded = module_set(result.output)
    local missing = {}
    for _, name in ipairs(expected_extensions) do
        if not loaded[name] then
            missing[#missing + 1] = name
        end
    end

    if #missing > 0 then
        error(
            "\n\nPHP extension verification failed.\n\n" ..
            "Missing PHP extensions: " .. table.concat(missing, ", ") .. ".\n" ..
            "These extensions were configured or enabled during installation but are not loaded by the installed PHP runtime.\n\n" ..
            output_excerpt(result.output) ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    if VERBOSE then
        print("Verified PHP extensions: " .. table.concat(expected_extensions, ", "))
    end

    return true
end

return M
