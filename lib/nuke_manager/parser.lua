
local base64 = require("nuke_manager.base64")

local parser = {}

function parser.parse_code(code)
    if code:sub(1, 4) == "erp=" then
        code = code:sub(5)
    end

    local binary = base64.decode(code)
    local result = {}

    for i = 1, #binary, 1 do
        result[i] = binary:byte(i)
    end

    return result
end

function parser.bytes_to_hex(bytes)
    local hex = "0x"

    local chars = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F" }

    for i = 1, #bytes do
        local byte = bytes[i]
        hex = hex .. chars[((byte >> 4) & 0x0F) + 1] .. chars[(byte & 0x0F) + 1]
    end

    return hex
end

function parser.load_bigint(a, off, len)
    if off == nil then
        off = 0
    end
    if len == nil then
        len = #a
    end

    local indexBound = off + len

    local keep = off
    while keep < indexBound and a[keep + 1] == 0 do
        keep = keep + 1
    end

    local intLength = (indexBound - keep + 3) >> 2
    local result = {}
    local b = indexBound - 1

    for i = intLength - 1, 0, -1 do
        result[i + 1] = a[b + 1] & 255
        b = b - 1
        local bytesRemaining = b - keep + 1
        local bytesToTransfer = math.min(3, bytesRemaining)

        for j = 8, bytesToTransfer << 3, 8 do
            result[i + 1] = result[i + 1] | ((a[b + 1] & 255) << j)
            b = b - 1
        end
    end

    return result
end

function parser.divideBigint(bigint, quotient_32b)

    local bigint_result = {}
    local remainder = 0

    for i = 1, #bigint do
        local v = (bigint[i] & 0xFFFFFFFF) + (remainder << 32)

        bigint_result[i] = v // quotient_32b
        remainder = v % quotient_32b
    end

    for i = #bigint_result, 1, -1 do
        if bigint_result[i] == 0 and bigint_result[i + 1] == nil then
            bigint_result[i] = nil
        end
    end

    return {
        result = bigint_result,
        remainder = remainder
    }
end

function parser.make_storage(bigint)

    local storage = {
        bigint = bigint
    }
    
    function storage:extract(max)
        local result = parser.divideBigint(self.bigint, max + 1)
    
        self.bigint = result.result
    
        return result.remainder
    end
    
    function storage:to_string()
        local digits = ""
    
        local bigint = self.bigint
    
        while true do
            local result = parser.divideBigint(bigint, 10)
    
            digits = result.remainder .. digits
    
            bigint = result.result
    
            if #bigint == 0 then
                break
            end
        end
    
        return digits
    end
    
    return storage
end

function parser.load_config(code_string)
    local storage = parser.make_storage(parser.load_bigint(parser.parse_code(code_string)))

    local config = {}

    config.codeRevision = storage:extract(255)

    if config.codeRevision >= 1 then
        config.pulsed = storage:extract(1) > 0
        config.automated = storage:extract(1) > 0
    end

    if config.codeRevision == 4 then
        config.maxComponentHeat = 1000000000
    elseif config.codeRevision == 3 then
        config.maxComponentHeat = 1080000
    else
        config.maxComponentHeat = 360000
    end

    local gridRows = 6
    local gridCols = 9
    config.grid = {}

    for row = 1, gridRows do
        for col = 1, gridCols do
            local componentId = 0
            if config.codeRevision <= 1 then
                componentId = storage:extract(38)
            elseif config.codeRevision == 2 then
                componentId = storage:extract(44)
            elseif config.codeRevision == 3 then
                componentId = storage:extract(58)
            else
                componentId = storage:extract(72)
            end
            if componentId ~= 0 then
                local component = {
                    componentId = componentId,
                    row = row,
                    col = col,
                }

                local hasSpecialAutomationConfig = storage:extract(1)
                if hasSpecialAutomationConfig > 0 then
                    component.initialHeat = storage:extract(config.maxComponentHeat)
                    
                    if config.codeRevision == 0 or (config.codeRevision >= 1 and config.automated) then
                        component.automationThreshold = storage:extract(config.maxComponentHeat)
                        component.reactorPause = storage:extract(10000)
                    end
                end

                config.grid[row .. ":" .. col] = component
            end
        end
    end

    config.currentHeat = storage:extract(120000)

    if config.codeRevision == 0 or (config.codeRevision >= 1 and config.pulsed) then
        config.onPulse = storage:extract(5000000)
        config.offPulse = storage:extract(5000000)
        config.suspendTemp = storage:extract(120000)
        config.resumeTemp = storage:extract(120000)
    end

    config.fluid = storage:extract(1) > 0
    config.usingReactorCoolantInjectors = storage:extract(1) > 0
    if config.codeRevision == 0 then
        config.pulsed = storage:extract(1) > 0
        config.automated = storage:extract(1) > 0
    end

    config.maxSimulationTicks = storage:extract(5000000)

    return config
end

return parser
