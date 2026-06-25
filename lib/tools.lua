local env = require("lib/env")
local cmd = require("cmd")
local http = require("http")

local tools = {}

local VERBOSE = env.VERBOSE
local PATH_SEP = package.config:sub(1, 1)
local USER_AGENT = "mise-php"
local WINDOWS_EXIT_MARKER = "__MISE_PHP_EXIT_CODE__="
local UTF8_BOM = "\239\187\191"

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

local function run_command(command)
    local success, output = pcall(cmd.exec, command)

    if success then
        return true, "exit", 0, output
    end

    return false, "error", 1, output
end

function tools.execute_cmd(command)
    local success, why, code, output = run_command(command)

    if output ~= nil and (VERBOSE or not success) then
        write_output(output)
    end

    return success, why, code, output
end

function tools.windows_cmd_quote(value)
    value = tostring(value)

    if value:find("[%z\r\n\"]") then
        error("Unsupported Windows command argument: " .. value)
    end

    return '"' .. value:gsub("%%", "%%%%") .. '"'
end

local function powershell_string(value)
    value = tostring(value)

    if value:find("[%z\r\n]") then
        error("Unsupported PowerShell string value: " .. value)
    end

    return "'" .. value:gsub("'", "''") .. "'"
end

local function powershell_quote(value)
    value = tostring(value)

    if value:find("[%z\r\n\"]") then
        error("Unsupported Windows command argument: " .. value)
    end

    return powershell_string(value)
end

local function pattern_escape(value)
    return tostring(value):gsub("([^%w])", "%%%1")
end

local function dirname(path)
    path = tostring(path)
    local last_separator = 0

    for i = 1, #path do
        local char = path:sub(i, i)

        if char == "/" or char == "\\" then
            last_separator = i
        end
    end

    if last_separator == 0 then
        return "."
    end

    return path:sub(1, last_separator - 1)
end

local function windows_temp_script_path(program)
    local directory = dirname(program)

    for attempt = 1, 20 do
        local filename = string.format(
            ".mise-php-command-%d-%d-%d.ps1",
            os.time(),
            math.random(100000, 999999),
            attempt
        )
        local path = directory .. PATH_SEP .. filename

        if not tools.file_exists(path) then
            return path
        end
    end

    error("Failed to allocate temporary Windows command script path")
end

local function split_windows_exit_marker(output)
    local text = tostring(output or "")
    local marker_pattern = "[\r\n]*" .. pattern_escape(WINDOWS_EXIT_MARKER) .. "(%-?%d+)"
    local last_start, last_code = nil, nil
    local init = 1

    while true do
        local start_index, finish_index, code = text:find(marker_pattern, init)

        if start_index == nil then
            break
        end

        last_start = start_index
        last_code = code
        init = finish_index + 1
    end

    if last_code == nil then
        return text, nil
    end

    local program_output = text:sub(1, last_start - 1):gsub("[\r\n]+$", "")
    return program_output, tonumber(last_code)
end

function tools.execute_windows_program(program, args, options)
    args = args or {}
    options = options or {}
    local capture_only = options.capture_only == true

    local command = { tools.windows_cmd_quote(program) }
    for _, arg in ipairs(args) do
        command[#command + 1] = tools.windows_cmd_quote(arg)
    end

    local invocation = table.concat(command, " ")
    local script =
        "$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'; " ..
        "$misePhpStdout = [System.IO.Path]::GetTempFileName(); " ..
        "$misePhpStderr = [System.IO.Path]::GetTempFileName(); " ..
        "$misePhpCommand = " .. powershell_string(invocation .. " > \"") ..
        " + $misePhpStdout + " .. powershell_string("\" 2> \"") ..
        " + $misePhpStderr + " .. powershell_string("\"") .. "; " ..
        "$misePhpErrorCount = $Error.Count; " ..
        "& $env:ComSpec /d /s /c $misePhpCommand; " ..
        "$misePhpExitCode = $LASTEXITCODE; " ..
        "if ($null -eq $misePhpExitCode) { " ..
        "if ($Error.Count -gt $misePhpErrorCount) { $misePhpExitCode = 1 } else { $misePhpExitCode = 0 } " ..
        "}; " ..
        "if (Test-Path -LiteralPath $misePhpStdout) { Get-Content -LiteralPath $misePhpStdout -Raw -Encoding UTF8 }; " ..
        "if (Test-Path -LiteralPath $misePhpStderr) { Get-Content -LiteralPath $misePhpStderr -Raw -Encoding UTF8 }; " ..
        "Remove-Item -LiteralPath $misePhpStdout, $misePhpStderr -Force -ErrorAction SilentlyContinue; " ..
        "Write-Output ('" .. WINDOWS_EXIT_MARKER .. "' + [string]$misePhpExitCode); " ..
        "exit 0"

    local script_path = windows_temp_script_path(program)
    if not tools.write_file(script_path, UTF8_BOM .. script) then
        local output = "Failed to create temporary Windows command script: " .. script_path
        write_output(output)
        return false, "error", 1, output
    end

    local success, why, code, output = run_command(
        "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command . " .. powershell_quote(script_path)
    )
    os.remove(script_path)

    if not success then
        if output ~= nil and not capture_only and (VERBOSE or not success) then
            write_output(output)
        end

        return false, why, code, output
    end

    local program_output, program_exit_code = split_windows_exit_marker(output)
    if program_exit_code == nil then
        if program_output ~= "" and not capture_only then
            write_output(program_output)
        end

        return false, "error", 1, program_output
    end

    local program_success = program_exit_code == 0
    if program_output ~= "" and not capture_only and (VERBOSE or not program_success) then
        write_output(program_output)
    end

    return program_success, "exit", program_exit_code, program_output
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
