local component = require("component")
local sides = require("sides")
local min_rate = 0.1
local max_rate = 0.999

-- gt_machine : 目标电容库头
local gt_machine = component.gt_machine
local redstone = component.redstone

local function listen()
    local max_energy = gt_machine.getEUMaxStored()
        local now_energy = gt_machine.getEUStored()
    local now_rate = now_energy / max_energy
    if now_rate < min_rate then 
        return true
    end
    if now_rate > max_rate then 
        return false
    end
end

function main()
    while true do
        local result = listen()
        if result == nil then 
            -- do nothing
        elseif result == true then 
            -- 开机
            redstone.setOutput(sides["up"], 15)
        else  
            -- 关机
            redstone.setOutput(sides["up"], 0)
        end
        local max_energy = gt_machine.getEUMaxStored()
        print("当前电容库电量：" .. gt_machine.getEUStored() .. " / " .. max_energy.."\n")
        print("当前电容库电量百分比：" .. string.format("%.2f", gt_machine.getEUStored() / max_energy * 100) .. "%\n")
        print("check once\n")
        os.sleep(10)
    end 
end


main()