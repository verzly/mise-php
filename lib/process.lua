local env = require("lib/env")

local process = {}

local VERBOSE = env.VERBOSE
local MARKER = "__MISE_PHP_EXIT_CODE__"
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

local function temp_path(extension)
    local random = tostring(math.random(100000, 999999))
    return temp_dir() .. PATH_SEP .. "mise-php-command-" .. tostring(os.time()) .. "-" .. random .. extension
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

local function strip_marker(output)
    local text = tostring(output or "")
    local code = text:match(MARKER .. "=(%-?%d+)")

    if code ~= nil then
        text = text:gsub("\r?\n?" .. MARKER .. "=%-?%d+\r?\n?", "")
    end

    return text, tonumber(code)
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

local function run_script(script_path, cwd)
    if is_windows() then
        local inner = windows_quote(script_path)
        if cwd and cwd ~= "" then
            inner = inner .. " " .. windows_quote(cwd)
        end

        return collect('cmd /D /S /C "' .. inner .. '"')
    end

    local command = "sh " .. posix_quote(script_path)
    if cwd and cwd ~= "" then
        command = command .. " " .. posix_quote(cwd)
    end
    command = command .. " 2>&1"
    return collect(command)
end

local function script_for(command, opts)
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
            "echo " .. MARKER .. "=%MISE_PHP_EXIT_CODE%",
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
        "printf '\\n" .. MARKER .. "=%s\\n' \"$code\"",
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
    local extension = is_windows() and ".cmd" or ".sh"
    local script_path = temp_path(extension)
    local script = script_for(command, opts)

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
        print("process.run: " .. command)
        print("process.script: " .. script_path)
    end

    local ok, why, code, output = run_script(script_path, opts.cwd)
    os.remove(script_path)

    output, code = strip_marker(output)
    if code == nil then
        if ok == true then
            code = 0
        elseif type(code) ~= "number" then
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
