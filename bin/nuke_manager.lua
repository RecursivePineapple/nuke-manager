
local filesystem = require("filesystem")
local serialization = require("serialization")
local component = require("component")
local thread = require("thread")
local event = require("event")
local os = require("os")
local term = require("term")

local parser = require("nuke_manager.parser")
local utils = require("nuke_manager.utils")
local items = require("nuke_manager.items")
local reactor_manager = require("nuke_manager.reactor_manager")
local logging = require("nuke_manager.logging")

local nuke_manager = {
    logger = nil,
    settings = {},
    reactor_config = {},
    threads = {}
}

local function load_config()
    if not filesystem.exists("/etc/nuke-manager") then
        filesystem.makeDirectory("/etc/nuke-manager")
    end
    
    if not component.isAvailable("database") then
        print("error: an unrecoverable error has occurred:")
        print("error: a database upgrade is required for this program to work.")
        print("error: install one into an adapter and ensure the adapter is connected to the computer network.")
        error("a database upgrade is required")
    end
    
    nuke_manager.settings = utils.load("/etc/nuke-manager/settings.cfg") or {}
    
    if nuke_manager.settings.code == nil or nuke_manager.settings.code == "" then
        error("reactor planner code is not set: please run config.lua and set it")
    end
    
    local reactors = utils.load("/etc/nuke-manager/reactors.cfg")
    
    if reactors == nil then
        error("/etc/nuke-manager/reactors.cfg has not been initialized: please run config.lua")
    end
    
    nuke_manager.settings.database = nuke_manager.settings.database or component.database.address
    nuke_manager.settings.reactors = reactors
    
    nuke_manager.reactor_config = parser.load_config(nuke_manager.settings.code)

    nuke_manager.logger = logging({
        app_name = "nuke_manager",
        debug = nuke_manager.settings.debug_logs,
        max_level = nuke_manager.settings.max_log_level,
    })

    for _, reactor in pairs(nuke_manager.settings.reactors) do
        local config_error = reactor_manager.validate_config(nuke_manager.reactor_config, reactor)
    
        if config_error ~= nil then
            error(config_error)
        end
    end
    
end

local function start()
    load_config()

    local next_slot = 1

    for _, reactor in pairs(nuke_manager.settings.reactors) do
        local state = reactor_manager.start(nuke_manager.settings, nuke_manager.reactor_config, reactor, next_slot, nuke_manager.logger)

        state.thread:detach()

        nuke_manager.threads[#nuke_manager.threads + 1] = state

        next_slot = next_slot + 1
    end
end

local function stop()
    for _, state in pairs(nuke_manager.threads) do
        state.stopped = true
    end

    for _, state in pairs(nuke_manager.threads) do
        nuke_manager.logger.info("Waiting for worker thread to stop for reactor " .. state.reactor.reactor_address)
        state.thread:join()
    end

    threads = {}
end

local function run()
    term.clear()

    print("Starting nuke_manager in 5 seconds, press Ctrl+C to cancel")
    
    if event.pull(5, "interrupted") then
        return
    end
    
    local state = { running = true }
    
    start()
    
    while state.running do
        if nuke_manager.settings.coolant_interface then
            local iface

            if nuke_manager.settings.coolant_interface == "any" then
                if component.isAvailable("me_interface") then
                    iface = component.me_interface
                end
            else
                iface = component.proxy(nuke_manager.settings.coolant_interface)
            end

            if iface == nil then
                nuke_manager.logger.warn("Could not find me_interface to check coolant levels")
                
                for _, state in pairs(nuke_manager.threads) do
                    state.paused = true
                end

                goto continue
            end

            local hot_coolant = 0
            local coolant = 0

            for _, fluid in pairs(iface.getFluidsInNetwork()) do
                if fluid.name == "ic2hotcoolant" then
                    hot_coolant = fluid.amount
                elseif fluid.name == "ic2coolant" then
                    coolant = fluid.amount
                end
            end

            local needs_hot_coolant = nuke_manager.settings.hot_coolant_max == nil or hot_coolant < nuke_manager.settings.hot_coolant_max
            local has_coolant = coolant > (nuke_manager.settings.cool_coolant_min or 0)

            if not has_coolant then
                nuke_manager.logger.warn("not enough coolant: needs " .. utils.format_int(nuke_manager.settings.cool_coolant_min or 0) .. " but has " .. utils.format_int(coolant))
            else
                nuke_manager.logger.info("hot coolant: " .. utils.format_int(hot_coolant) .. "    coolant: " .. utils.format_int(coolant))
            end

            if has_coolant and needs_hot_coolant then
                for _, state in pairs(nuke_manager.threads) do
                    state.paused = false
                end
            else
                for _, state in pairs(nuke_manager.threads) do
                    state.paused = true
                end
            end
        end

        ::continue::

        if event.pull(5, "interrupted") ~= nil then
            nuke_manager.logger.info("Interrupted")
            state.running = false

            for _, state in pairs(nuke_manager.threads) do
                state.stopped = true
            end
        end
    end
    
    stop()
end

function catch(fn, logger)
    local success, ret = pcall(fn)

    if not success then
        logger.error(tostring(ret))
    else
        return ret
    end
end

run()
