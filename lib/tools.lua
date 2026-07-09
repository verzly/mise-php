local env = require("lib/env")
local cmd = require("cmd")
local http = require("http")

local tools = {}

local VERBOSE = env.VERBOSE
local PATH_SEP = package.config:sub(1, 1)
local USER_AGENT = "mise-php"

function tools.join_path(...)
    return table.concat({ ... }, PATH_SEP)
end

function tools.file_exists(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    file:close()
    return true
end

function tools.read_file(path)
    local file = io.open(path, "rb")

    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

function tools.write_file(path, content)
    local file = io.open(path, "wb")

    if not file then
        return false
    end

    file:write(content)
    file:close()
    return true
end

function tools.copy_file(source, destination)
    local content = tools.read_file(source)
    if content == nil then
        return false
    end

    return tools.write_file(destination, content)
end

function tools.is_windows()
    return RUNTIME.osType == "windows"
end

function tools.shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function write_output(output)
    if output == nil then
        return
    end

    local text = tostring(output)
    if text == "" then
        return
    end

    io.stdout:write(text)
    if text:sub(-1) ~= "\n" then
        io.stdout:write("\n")
    end
end

-- Backward-compatible process wrapper. New code should use lib/process.lua
-- directly so command execution stays platform-aware.
--
-- Returns: ok, why, code, output
function tools.execute_cmd(command, quiet)
    local process = require("lib/process")
    local result = process.run(command, { quiet = quiet or "" })

    return result.ok, result.why, result.code, result.output
end

function tools.windows_cmd_quote(value)
    value = tostring(value)

    if value:find("[%z\r\n\"]") then
        error("Unsupported Windows command argument: " .. value)
    end

    return '"' .. value:gsub("%%", "%%%%") .. '"'
end

function tools.download_file(url, destination)
    local ok, err = http.try_download_file({
        url = url,
        headers = {
            ["User-Agent"] = USER_AGENT,
        },
    }, destination)

    return ok and tools.file_exists(destination), err
end

return tools
