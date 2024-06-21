
local component = require("component")
local serialization = require("serialization")
local filesystem = require("filesystem")
local term = require("term")
local computer = require("computer")
local event = require("event")

local utils = require("nuke_manager.utils")
local config_utils = require("nuke_manager.config_utils")

local settings = utils.load("/etc/nuke-manager/settings.cfg") or {}
local reactors = utils.load("/etc/nuke-manager/reactors.cfg") or {}

function do_reactor_edit(reactor)
    config_utils.current_reactor = reactor

    reactor = utils.deep_copy(reactor)

    while true do
        ::start::

        local opt = config_utils.get_option({
            "Cancel",
            "Change transposer address",
            "Change ME interface address",
            "Change ME interface side",
            "Change reactor address",
            "Change reactor side",
            "Change redstone I/O address",
            "Change redstone I/O side",
            reactor.invert_redstone and "Set to 'Enable with Redstone'" or "Set to 'Disable with Redstone'",
            "Show pending changes",
            "Confirm changes"
        })

        if opt == 1 then
            return nil
        elseif opt == 2 then
            print("Select the transposer for this reactor")
            local transposer = config_utils.select_component("transposer", reactors, "transposer")

            if transposer == nil then
                goto start
            else
                reactor.transposer = transposer
            end
        elseif opt == 3 then
            print("Select the ME interface for this reactor")
            local interface_address = config_utils.select_component("me_interface", reactors, "interface_address")

            if interface_address == nil then
                goto start
            else
                reactor.interface_address = interface_address
            end
        elseif opt == 4 then
            print("Select the side of the ME interface for this reactor")
            local interface_side = config_utils.get_transposer_side(reactor.transposer)

            if interface_side == nil then
                goto start
            else
                reactor.interface_side = interface_side
            end
        elseif opt == 5 then
            print("Select the reactor")
            local reactor_address = config_utils.select_component("reactor", reactors, "reactor_address")

            if reactor_address == nil then
                goto start
            else
                reactor.reactor_address = reactor_address
            end
        elseif opt == 6 then
            print("Select the side of the transposer that is connected to the reactor")
            local reactor_side = config_utils.get_transposer_side(reactor.transposer)

            if reactor_side == nil then
                goto start
            else
                reactor.reactor_side = reactor_side
            end
        elseif opt == 7 then
            print("Select the redstone I/O")
            local redstone_io = config_utils.select_component("redstone", reactors, "redstone_io")

            if redstone_io == nil then
                goto start
            else
                reactor.redstone_io = redstone_io
            end
        elseif opt == 8 then
            print("Select the side to emit a redstone signal from")
            local redstone_side = config_utils.get_side()

            if redstone_side == nil then
                goto start
            else
                reactor.redstone_side = redstone_side
            end
        elseif opt == 9 then
            reactor.invert_redstone = not reactor.invert_redstone
        elseif opt == 10 then
            print(utils.table_to_string_pretty(reactor))
        elseif opt == 11 then
            break
        end
    end
    
    return reactor
end

function find_unused_components(pending, reactors, reactor_key, ctype)
    local unused = {}

    for addr, t in pairs(component.list(ctype)) do
        if t ~= ctype then
            goto continue
        end

        for _, reactor in pairs(reactors) do
            if reactor[reactor_key] == addr then
                goto continue
            end
        end

        for _, reactor in pairs(pending) do
            if reactor[reactor_key] == addr then
                goto continue
            end
        end

        unused[#unused + 1] = addr

        ::continue::
    end

    return unused
end

function do_auto_mode(reactors)
    local options = {
        "Cancel"
    }

    for i, reactor in pairs(reactors) do
        options[i + 1] = serialization.serialize(reactor)
    end

    print("Select the reactor to copy all non-component values from")
    local opt = config_utils.get_option(options)

    local base_reactor

    if opt == 1 then
        return
    else
        base_reactor = reactors[opt - 1]
    end

    local state = { running = true }

    local function stop()
        if state.running then
            state.running = false
            term.clearLine()
            io.write("Stopping...")
        end
    end

    event.listen("interrupted", stop)

    print("Entering auto mode. Press Ctrl+C to return to the main menu.")

    local pending = {}

    local i = 0
    local spinners = {"/", "-", "\\", "|"}

    while state.running do
        term.clearLine()

        local unused_ios = find_unused_components(pending, reactors, "redstone_io", "redstone")
        local unused_transposers = find_unused_components(pending, reactors, "transposer", "transposer")
        local unused_interfaces = find_unused_components(pending, reactors, "interface_address", "me_interface")
        local unused_reactors = find_unused_components(pending, reactors, "reactor_address", "reactor")
        local unused_reactor_chambers = find_unused_components(pending, reactors, "reactor_address", "reactor_chamber")

        if #unused_ios == 1 and #unused_transposers == 1 and #unused_interfaces == 1 and (#unused_reactors + #unused_reactor_chambers) == 1 then
            local new_reactor = {
                invert_redstone = base_reactor.invert_redstone,
                redstone_side = base_reactor.redstone_side,
                reactor_side = base_reactor.reactor_side,
                interface_side = base_reactor.interface_side,
                transposer = unused_transposers[1],
                redstone_io = unused_ios[1],
                interface_address = unused_interfaces[1],
                reactor_address = unused_reactors[1] or unused_reactor_chambers[1],
            }

            pending[#pending + 1] = new_reactor

            computer.beep()

            print("\nAdded a new reactor: " .. utils.table_to_string_pretty(new_reactor))
        end

        io.write(string.format(
            "Waiting for one of each unused component to be available... %s (redstone I/Os=%d, transposers=%d, interfaces=%d, reactors=%d)",
            spinners[i % #spinners + 1],
            #unused_ios,
            #unused_transposers,
            #unused_interfaces,
            #unused_reactors + #unused_reactor_chambers
        ))

        i = i + 1

        os.sleep(1)
    end

    term.clearLine()

    event.ignore("interrupted", stop)

    if #pending == 0 then
        print("Exiting auto mode.")
        return
    end

    print("Exiting auto mode. Add " .. #pending .. " new reactors?")

    if config_utils.get_yes_no() then
        for _, reactor in pairs(pending) do
            reactors[#reactors + 1] = reactor
        end
    end
end

print("nuke-manager configuration tool")

while true do
    ::start::

    local option = config_utils.get_option({
        "Exit without saving",
        "Show pending reactor config",
        "Clear config",
        "Set reactor config code",
        "Add new reactor",
        "Edit reactor",
        "Select base reactor and enter auto config mode",
        "Remove reactor",
        "Save and exit"
    })

    if option == 1 then
        break
    elseif option == 2 then
        print("settings = " .. utils.table_to_string_pretty(settings))
        print("reactors = " .. utils.table_to_string_pretty(reactors))
    elseif option == 3 then
        reactors = {}
    elseif option == 4 then
        io.write("Paste the planner code for all reactors: ")
        settings.code = io.read("*l")
    elseif option == 5 then
        local reactor = {}

        print("Select the transposer for this reactor")
        reactor.transposer = config_utils.select_component("transposer", reactors, "transposer")

        if reactor.transposer == nil then
            goto start
        end

        print("Select the ME interface for this reactor that is connected to the selected transposer")
        reactor.interface_address = config_utils.select_component("me_interface", reactors, "interface_address")

        if reactor.interface_address == nil then
            goto start
        end

        print("Select the side of the transposer that is connected to the ME interface")
        reactor.interface_side = config_utils.get_transposer_side(reactor.transposer)

        if reactor.interface_side == nil then
            goto start
        end

        print("Select the reactor that is connected to the selected transposer")
        reactor.reactor_address = config_utils.select_component("reactor", reactors, "reactor_address")

        if reactor.reactor_address == nil then
            goto start
        end

        print("Select the side of the transposer that is connected to the reactor")
        reactor.reactor_side = config_utils.get_transposer_side(reactor.transposer)

        if reactor.reactor_side == nil then
            goto start
        end

        print("Select the redstone I/O")
        reactor.redstone_io = config_utils.select_component("redstone", reactors, "redstone_io")

        if reactor.redstone_io == nil then
            goto start
        end

        print("Select the side to emit a redstone signal from")
        reactor.redstone_side = config_utils.get_side()
        
        if reactor.redstone_side == nil then
            goto start
        end

        print("When the reactor should be on, should the redstone signal be low?")
        reactor.invert_redstone = config_utils.get_yes_no()

        print("Is this correct?")
        print(utils.table_to_string_pretty(reactor))

        local correct = config_utils.get_yes_no()

        if not correct then
            reactor = do_reactor_edit(reactor)
        end
        
        if reactor ~= nil then
            table.insert(reactors, reactor)
        end
    elseif option == 6 then
        local options = {
            "Cancel"
        }

        for i, reactor in pairs(reactors) do
            options[i + 1] = serialization.serialize(reactor)
        end

        print("Select the reactor to edit")
        local opt = config_utils.get_option(options)

        if opt == 1 then
            goto start
        else
            opt = opt - 1
            local r = do_reactor_edit(reactors[opt])

            if r ~= nil then
                reactors[opt] = r
            end
        end
    elseif option == 7 then
        do_auto_mode(reactors)
        
    elseif option == 8 then
        local options = {
            "Cancel"
        }

        for i, reactor in pairs(reactors) do
            options[i + 1] = serialization.serialize(reactor)
        end

        print("Select the reactor to remove")
        local opt = config_utils.get_option(options)

        if opt == 1 then
            goto start
        else
            opt = opt - 1
            table.remove(reactors, opt)
        end
    elseif option == 9 then
        if not filesystem.exists("/etc/nuke-manager") then
            filesystem.makeDirectory("/etc/nuke-manager")
        end

        if filesystem.exists("/etc/nuke-manager/reactors.cfg") then
            filesystem.rename("/etc/nuke-manager/reactors.cfg", "/etc/nuke-manager/reactors-backup.cfg")
            print("Backed up old reactors.cfg to /etc/nuke-manager/reactors-backup.cfg")
        end

        if filesystem.exists("/etc/nuke-manager/settings.cfg") then
            filesystem.rename("/etc/nuke-manager/settings.cfg", "/etc/nuke-manager/settings-backup.cfg")
            print("Backed up old settings.cfg to /etc/nuke-manager/settings-backup.cfg")
        end

        utils.save("/etc/nuke-manager/reactors.cfg", reactors)
        utils.save("/etc/nuke-manager/settings.cfg", settings)
        print("Saved reactor config")
        break
    end
end
