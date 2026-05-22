local M = {}

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

function M.table(ctx)
    local options = safe_index(ctx, "options")
    if options == nil then
        return {}
    end

    return options
end

function M.get(ctx, key)
    return safe_index(M.table(ctx), key)
end

function M.enabled(value)
    if value == true then
        return true
    end

    if value == nil or value == false then
        return false
    end

    value = tostring(value)
    return value ~= "" and value ~= "0" and value ~= "false"
end

return M
