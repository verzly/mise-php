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

-- Executes a shell command and captures its output.
--
-- Uses io.popen() instead of mise's cmd.exec() to avoid command wrapping
-- performed by mise on Windows.
--
-- The optional quiet argument is appended to the command and can be used for
-- redirection, for example: " 2>&1".
--
-- Imortant:
-- - Work in `cmd` format quotes: `cmd /C "echo "test""`
-- - Use `UTF-8`
-- - Ger actual `exit code` from `cmd` instead of `handle:close()`
-- - Write info for verbose mode
--
-- Returns: ok, why, code, output_quited
function tools.execute_cmd(command, quiet)
    quiet = quiet or ""

    local command_echo_exit_code = "echo __MISE_PHP_EXIT_CODE__=!ERRORLEVEL!"
    local command_wrapper_with_exit_code = 'cmd /V:ON /C "chcp 65001 >NUL & ' ..  command ..  quiet .. " & " .. command_echo_exit_code .. '"'

    local handle = io.popen(command_wrapper_with_exit_code)

    if not handle then
        return false, "error", 1, "Failed to start command"
    end

    local output_quited = {}

    if VERBOSE then
        print("execute_cmd: " .. command_wrapper_with_exit_code);
    end

    for line in handle:lines() do
        if VERBOSE then
            print("> " .. line)
        end

        output_quited[#output_quited + 1] = line
    end

    output_quited = table.concat(output_quited, "\n");

    local ok, why, code = handle:close()

    -- fix: set actual `ok`, `why`, `code` from `__MISE_PHP_EXIT_CODE__`
    local command_error_code = output_quited:match("__MISE_PHP_EXIT_CODE__=(%-?%d+)")
    if command_error_code then
        code = tonumber(command_error_code)
        output_quited = output_quited:gsub("\r?\n?__MISE_PHP_EXIT_CODE__=%-?%d+\r?\n?", "")

        if code and code ~= 0 then
            ok = false
            why = 'error'
        end
    end

    return ok, why, code, tostring(output_quited)
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
