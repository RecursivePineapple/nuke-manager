
local component = require("component")
local sides = require("sides")
local io = require("io")

local utils = require("nuke_manager.utils")

local config_utils = {}

config_utils.current_reactor = {}

function config_utils.get_option(options)
    while true do
        local keys = utils.keys(options)
        
        table.sort(keys)

        print()
        
        for i, k in ipairs(keys) do
            print("  " .. i .. ". " .. options[k])
        end

        io.write("Enter selection: ")

        local n = tonumber(io.read("*l"))

        if n ~= nil and options[keys[n]] ~= nil then
            print()
            return n
        end

        print("\nInvalid option, expected a number between 1 and " .. #keys)
    end
end

function config_utils.get_yes_no()
    return config_utils.get_option({
        "Yes",
        "No"
    }) == 1
end

function config_utils.select_component(component_type, reactors, reactor_key)
    ::reload::

    local options = {
        "Cancel",
        "Reload components",
    }

    local addresses = {}

    for address, t in pairs(component.list(component_type)) do
        local used_by = {}

        for i, reactor in pairs(reactors) do
            if reactor[reactor_key] == address and reactor ~= config_utils.current_reactor then
                table.insert(used_by, "#" .. i)
            end
        end

        local idx = #options + 1
        addresses[idx] = address

        if #used_by > 0 then
            if config_utils.current_reactor[reactor_key] == address then
                options[idx] = address .. " (used by the current reactor and reactor(s) " .. table.concat(used_by, ", ") .. ")"
            else
                options[idx] = address .. " (used by reactor(s) " .. table.concat(used_by, ", ") .. ")"
            end
        else
            if config_utils.current_reactor[reactor_key] == address then
                options[idx] = address .. " (used by the current reactor)"
            else
                options[idx] = address .. " (unused)"
            end
        end
    end

    local opt = config_utils.get_option(options)

    if opt == 1 then
        return nil
    elseif opt == 2 then
        goto reload
    else
        return addresses[opt]
    end
end

function config_utils.get_side()
    opt = config_utils.get_option({
        "Cancel",
        [sides.top + 2] = "Top",
        [sides.bottom + 2] = "Bottom",
        [sides.north + 2] = "North",
        [sides.south + 2] = "South",
        [sides.east + 2] = "East",
        [sides.west + 2] = "West",
    })

    if opt == 1 then
        return nil
    else
        return opt - 2
    end
end

function config_utils.get_transposer_side(address)
    ::reload::

    local tpose = address and component.proxy(address)
    local opt

    if tpose ~= nil then
        opt = config_utils.get_option({
            "Cancel",
            "Reload inventory names",
            [sides.top + 3] = "Top (inventory name = " .. (tpose.getInventoryName(sides.top) or "nil") .. ")",
            [sides.bottom + 3] = "Bottom (inventory name = " .. (tpose.getInventoryName(sides.bottom) or "nil") .. ")",
            [sides.north + 3] = "North (inventory name = " .. (tpose.getInventoryName(sides.north) or "nil") .. ")",
            [sides.south + 3] = "South (inventory name = " .. (tpose.getInventoryName(sides.south) or "nil") .. ")",
            [sides.east + 3] = "East (inventory name = " .. (tpose.getInventoryName(sides.east) or "nil") .. ")",
            [sides.west + 3] = "West (inventory name = " .. (tpose.getInventoryName(sides.west) or "nil") .. ")",
        })
    else
        opt = config_utils.get_option({
            "Cancel",
            [sides.top + 3] = "Top",
            [sides.bottom + 3] = "Bottom",
            [sides.north + 3] = "North",
            [sides.south + 3] = "South",
            [sides.east + 3] = "East",
            [sides.west + 3] = "West",
        })
    end

    if opt == 1 then
        return nil
    elseif opt == 2 then
        goto reload
    else
        return opt - 3
    end
end

return config_utils
