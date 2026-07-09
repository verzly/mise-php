local env = require("lib/env")

local process = {}

local VERBOSE = env.VERBOSE
local MARKER_PREFIX = "__MISE_PHP_EXIT_CODE__"
local PATH_SEP = package.config:sub(1, 1)

local function is_windows()
    return RUNTIME ~= nil and RUNTIME.osType == "windows"
end

local function temp_dir()
    if is_windows() then
        return os.getenv("TEMP") or os.getenv("TMP") or "."
    end

    return os.getenv("TMPDIR") or "/tmp"
end

local function unique_id()
    return tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
end

local function temp_path(extension)
    return temp_dir() .. PATH_SEP .. "mise-php-command-" .. unique_id() .. extension
end

local function write_file(path, content)
    local file = io.open(path, "wb")
    if not file then
        return false
    end

    file:write(content)
    file:close()
    return true
end

local function posix_quote(value)
    value = tostring(value)
    if value:find("[%z\r\n]") then
        error("Unsupported POSIX command argument: " .. value)
    end

    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function posix_script_quote(value)
    value = tostring(value)
    if value:find("%z") then
        error("Unsupported POSIX command script")
    end

    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function posix_command(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("POSIX command arguments must be a non-empty table")
    end

    local quoted = {}
    for index = 1, #argv do
        if argv[index] == nil then
            error("POSIX command argument " .. index .. " must not be nil")
        end
        quoted[index] = posix_quote(argv[index])
    end

    return table.concat(quoted, " ")
end

local function windows_quote(value)
    value = tostring(value)

    if value:find("[%z\r\n\"]") then
        error("Unsupported Windows command argument: " .. value)
    end

    return '"' .. value:gsub("%%", "%%%%") .. '"'
end

local function marker_for()
    return MARKER_PREFIX .. "_" .. unique_id()
end

local function pattern_escape(value)
    return tostring(value):gsub("([^%w])", "%%%1")
end

local function strip_marker(output, marker)
    local text = tostring(output or "")
    local marker_pattern = pattern_escape(marker)
    local code = nil
    local lines = {}

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local normalized = line:gsub("\r$", "")
        local found = normalized:match("^" .. marker_pattern .. "=(%-?%d+)$")

        if found ~= nil then
            code = tonumber(found)
        else
            lines[#lines + 1] = line
        end
    end

    return table.concat(lines, "\n"), code
end

local function collect(command)
    local handle = io.popen(command)
    if not handle then
        return false, "error", 1, "Failed to start command"
    end

    local output = {}
    for line in handle:lines() do
        if VERBOSE then
            print("> " .. line)
        end
        output[#output + 1] = line
    end

    local ok, why, code = handle:close()
    return ok, why, code, table.concat(output, "\n")
end

local function run_windows_script_file(script_path, cwd)
    local inner = windows_quote(script_path)
    if cwd and cwd ~= "" then
        inner = inner .. " " .. windows_quote(cwd)
    end

    return collect('cmd /D /S /C "' .. inner .. '"')
end

local function run_posix_script(script, cwd)
    local command = "sh -c " .. posix_script_quote(script) .. " mise-php"
    if cwd and cwd ~= "" then
        command = command .. " " .. posix_quote(cwd)
    end
    command = command .. " 2>&1"
    return collect(command)
end

local function script_for(command, opts, marker)
    opts = opts or {}
    local quiet = opts.quiet or ""
    local command_line = command .. quiet

    if is_windows() then
        return table.concat({
            "@echo off",
            "chcp 65001 >NUL",
            "if not \"%~1\"==\"\" cd /D \"%~1\"",
            command_line,
            "set \"MISE_PHP_EXIT_CODE=%ERRORLEVEL%\"",
            "echo " .. marker .. "=%MISE_PHP_EXIT_CODE%",
            "exit /b %MISE_PHP_EXIT_CODE%",
            "",
        }, "\r\n")
    end

    return table.concat({
        "#!/usr/bin/env sh",
        "if [ -n \"$1\" ]; then",
        "    cd \"$1\" || exit 125",
        "fi",
        command_line,
        "code=$?",
        "printf '\\n" .. marker .. "=%s\\n' \"$code\"",
        "exit \"$code\"",
        "",
    }, "\n")
end

-- Build a POSIX sh timeout wrapper without requiring GNU timeout, which macOS lacks.
function process.unix_timeout_command(argv, seconds)
    seconds = tonumber(seconds)
    if seconds == nil or seconds < 1 then
        error("Timeout seconds must be a positive number")
    end

    return string.format([[
(
    %s &
    child=$!
    (
        sleep %d
        kill "$child" 2>/dev/null
    ) &
    watchdog=$!
    wait "$child"
    status=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    if [ "$status" -ge 128 ]; then
        exit 124
    fi
    exit "$status"
)]], posix_command(argv), math.floor(seconds))
end

function process.run(command, opts)
    opts = opts or {}
    local marker = marker_for()
    local script = script_for(command, opts, marker)

    if VERBOSE then
        print("process.run: " .. command)
    end

    local ok, why, close_code, output
    if is_windows() then
        local script_path = temp_path(".cmd")
        if not write_file(script_path, script) then
            return {
                ok = false,
                why = "error",
                code = 1,
                output = "Failed to write temporary command script",
                command = command,
            }
        end

        if VERBOSE then
            print("process.script: " .. script_path)
        end

        ok, why, close_code, output = run_windows_script_file(script_path, opts.cwd)
        os.remove(script_path)
    else
        ok, why, close_code, output = run_posix_script(script, opts.cwd)
    end

    local marker_code
    output, marker_code = strip_marker(output, marker)
    local code = marker_code
    if code == nil then
        if ok == true then
            code = 0
        elseif type(close_code) == "number" then
            code = close_code
        else
            code = 1
        end
    end

    return {
        ok = code == 0,
        why = code == 0 and "exit" or (why or "error"),
        code = code,
        output = tostring(output or ""),
        command = command,
    }
end

return process
