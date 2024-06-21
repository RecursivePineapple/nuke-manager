
local component = require("component")
local event = require("event")
local thread = require("thread")
local os = require("os")

local items = require("nuke_manager.items")
local utils = require("nuke_manager.utils")

local reactor_manager = {}

function reactor_manager.get_reactor_info(reactor)
    local tpose = component.proxy(reactor.transposer)

    if tpose == nil then
        error("could not find transposer for reactor (transposer address = " .. reactor.transposer .. ")")
    end

    local size = tpose.getInventorySize(reactor.reactor_side)
    
    if size == nil then
        error("could not find inventory on transposer (transposer address = " .. reactor.transposer .. ", reactor side = " .. utils.get_side_name(reactor.reactor_side) .. ")")
    end

    local width = size // 6
    local extra = size % 6 

    if width < 3 or width > 9 then
        error("reactor inventory must have 6 rows and have between 3 to 9 columns (inclusive): this inventory is likely not a reactor (transposer address = " ..
            reactor.transposer .. ", reactor side = " .. utils.get_side_name(reactor.reactor_side) .. ")")
    end

    if extra == 0 then
        return width, "eu"
    elseif extra == 4 then
        return width, "fluid"
    else
        error("reactor inventory must have a remainder of 0 slots if it is an EU reactor or 4 if it is a fluid reactor: this inventory is likely not a reactor " .. 
            "(transposer address = " .. reactor.transposer .. ", reactor side = " .. utils.get_side_name(reactor.reactor_side) .. ")")
    end
end

function reactor_manager.get_config_width(config)
    local config_width = 3
    
    for cell, item_config in pairs(config.grid) do
        if item_config.col > config_width then
            config_width = item_config.col
        end
    end

    return config_width
end

function reactor_manager.validate_config(config, reactor)
    local reactor_width, reactor_type = reactor_manager.get_reactor_info(reactor)

    if config.fluid and reactor_type == "eu" then
        return "cannot use a fluid reactor config in an EU reactor"
    end

    local config_width = reactor_manager.get_config_width(config)

    if config_width > reactor_width then
        return "reactor config has a width of " .. config_width .. " but the reactor has a lesser width of " .. reactor_width
    end
end

function get_reactor_slot(reactor_width, reactor_type, row, col)
    return reactor_width * row + col + 4
end

function catch(fn, logger)
    local success, ret = pcall(fn)

    if not success then
        logger.error(tostring(ret))
    else
        return ret
    end
end

function reactor_manager.run_once(settings, config, reactor, db_slot, logger)
    local tpose = component.proxy(reactor.transposer)
    local iface = component.proxy(reactor.interface_address)

    local inv = tpose.getAllStacks(reactor.reactor_side).getAll()

    local reactor_width, reactor_type = reactor_manager.get_reactor_info(reactor)

    local needed = {}

    local prefix = string.format("[%s] ", string.sub(reactor.reactor_address, 1, 3))
    
    for row = 0, 5 do
        for col = 0, reactor_width - 1 do
            local slot_name = (row + 1) .. ":" .. (col + 1)
            local slot_index = row * reactor_width + col + 1

            local config_slot = config.grid[slot_name]
            local config_item = config_slot and items[config_slot.componentId] or {}
            local actual_item = inv[slot_index - 1] or {}

            if actual_item.name == nil and config_item.item_name == nil then
                goto continue
            end

            if actual_item.name and actual_item.name ~= config_item.item_name then
                logger.info(prefix .. "removing invalid item from " .. (row + 1) .. ":" .. (col + 1) .. " called " .. actual_item.label)

                repeat
                    tpose.transferItem(reactor.reactor_side, reactor.interface_side, 64, slot_index, 2)

                    actual_item = tpose.getStackInSlot(reactor.reactor_side, slot_index) or {}
                until actual_item.name == nil
            end

            if config_item.item_name and actual_item.name ~= config_item.item_name then
                local selected = tpose.getStackInSlot(reactor.interface_side, 1) or {}

                if selected.name ~= config_item.item_name then
                    component.invoke(settings.database, "clear", db_slot)

                    if not iface.store({ name = config_item.item_name }, settings.database, db_slot, 1) then
                        logger.warn(prefix .."failed to insert " .. config_item.item_name .. " into reactor slot " .. slot_name)
                        needed[config_item.item_name] = (needed[config_item.item_name] or 0) + 1
                        goto continue
                    end
                    
                    os.sleep()

                    iface.setInterfaceConfiguration(1, settings.database, db_slot)
                end

                os.sleep()

                if tpose.transferItem(reactor.interface_side, reactor.reactor_side, 1, 1, slot_index) > 0 then
                    logger.info(prefix .."inserted " .. config_item.item_name .. " into reactor slot " .. slot_name)
                else
                    needed[config_item.item_name] = (needed[config_item.item_name] or 0) + 1
                    logger.warn(prefix .."failed to insert " .. config_item.item_name .. " into reactor slot " .. slot_name)
                end
            end

            ::continue::
        end
    end

    iface.setInterfaceConfiguration(1, settings.database, db_slot, 0)

    return needed
end

function reactor_manager.start(settings, config, reactor, db_slot, logger)
    return thread.create(function()
        logger.info("started worker thread for reactor " .. reactor.reactor_address)

        local prefix = string.format("[%s] ", string.sub(reactor.reactor_address, 1, 3))
        
        local state = {
            start = os.time() / 72,
            last_update = 0,
            last_inv_check = 0,
            last_component_warn = 0,
            paused = false,
            checking = false,
            suspended = false,
            stopped = false,
        }

        local function do_status_check()
            local heat = component.invoke(reactor.reactor_address, "getHeat")
            local maxHeat = component.invoke(reactor.reactor_address, "getMaxHeat")

            local redlined = false

            if heat / maxHeat > 0.8 then
                redlined = true
            end

            if state.suspended and config.resumeTemp and heat < config.resumeTemp then
                state.suspended = false
            end
            
            if not state.suspended and config.suspendTemp and heat > config.suspendTemp then
                state.suspended = true
            end

            local should_be_on = true

            local now = os.time() / 72

            if config.pulsed then
                local pulse_period = config.onPulse + config.offPulse
                local within_period = (now - state.start) % pulse_period

                should_be_on = within_period > config.onPulse
            end

            if now - state.last_update > 5 then
                local status = ""

                if redlined then status = status .. " redlined" end
                if state.paused or state.checking then status = status .. " paused" end
                if state.suspended then status = status .. " suspended" end
                if not (state.paused or state.checking) and should_be_on then status = status .. " active" end
                if status == "" then status = "idle" end

                logger.info(prefix .. "reactor status: " .. status .. "   heat: " .. utils.format_int(heat) .. "/" .. utils.format_int(maxHeat))
                state.last_update = now
            end

            local output = false

            if redlined or state.paused or state.checking or state.suspended or state.stopped or not should_be_on then
                output = false
            else
                output = true
            end

            if reactor.invert_redstone then
                output = not output
            end

            local curr = output and 14 or 0

            local prev = component.proxy(reactor.redstone_io).setOutput(reactor.redstone_side, curr)

            if curr ~= prev then
                logger.info(prefix .. "redstone: " .. prev .. " -> " .. curr)
            end
        end

        local function do_inv_check()
            state.checking = true

            logger.info(prefix .. "starting reactor inventory check: reactor will be paused")

            do_status_check()

            local missing = reactor_manager.run_once(settings, config, reactor, db_slot, logger)

            if next(missing) ~= nil then
                logger.info(prefix .. "reactor will not restart until the following missing items are available: " .. utils.table_to_string_pretty(missing))
            else
                logger.info(prefix .. "reactor inventory check finished: reactor will resume")

                state.checking = false
            end
        end

        local function pause(evt, addr)
            if not addr or addr == reactor.reactor_address then
                state.paused = true
            end
        end

        local function continue(evt, addr)
            if not addr or addr == reactor.reactor_address then
                state.paused = false
            end
        end

        local function stop(evt, addr)
            if addr == nil or addr == reactor.reactor_address then
                logger.info(prefix .. "stopping worker thread")
                state.stopped = true
            end
        end

        event.listen("reactor_pause", pause)
        event.listen("reactor_continue", continue)
        event.listen("reactor_stop", stop)
        event.listen("interrupted", stop)

        while not state.stopped do
            local now = os.time() / 72

            local any_disconnected = false

            if component.proxy(reactor.transposer) == nil then
                if (now - state.last_component_warn) > 10 then
                    logger.warn(prefix .. "transposer " .. reactor.transposer .. " is not connected")
                end
                any_disconnected = true
            end

            if component.proxy(reactor.reactor_address) == nil then
                if (now - state.last_component_warn) > 10 then
                    logger.warn(prefix .. "reactor " .. reactor.reactor_address .. " is not connected")
                end
                any_disconnected = true
            end

            if component.proxy(reactor.interface_address) == nil then
                if (now - state.last_component_warn) > 10 then
                    logger.warn(prefix .. "me interface " .. reactor.interface_address .. " is not connected")
                end
                any_disconnected = true
            end

            if component.proxy(reactor.redstone_io) == nil then
                if (now - state.last_component_warn) > 10 then
                    logger.warn(prefix .. "redstone I/O " .. reactor.redstone_io .. " is not connected")
                end
                any_disconnected = true
            end

            if any_disconnected then
                if (now - state.last_component_warn) > 10 then
                    state.last_component_warn = now
                end

                local redstone = component.proxy(reactor.redstone_io)

                if redstone then
                    redstone.setOutput(reactor.redstone_side, reactor.invert_redstone and 15 or 0)
                end

                goto continue
            end

            catch(do_status_check, logger)

            if now - state.last_inv_check > 20 then
                catch(do_inv_check, logger)
                state.last_inv_check = now
            end
            
            ::continue::

            os.sleep(0.5)
        end

        component.invoke(reactor.redstone_io, "setOutput", reactor.redstone_side, reactor.invert_redstone and 15 or 0)

        event.ignore("reactor_pause", pause)
        event.ignore("reactor_continue", continue)
        event.ignore("reactor_stop", stop)
        event.ignore("interrupted", stop)

        logger.info(prefix .. "worker thread stopped")
    end)
end

return reactor_manager
