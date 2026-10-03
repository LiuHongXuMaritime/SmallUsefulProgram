local component = require("component")
local sides = require(
    "sides"
)

local transposer = component.transposer

InputSide = -1
FromSide = -1

local function listen()
    
end

for i = 0, 5 do 
    local t =   component.transposer.getFluidInTank(i) 
    for key,valtable in pairs(t)do 
        print(key)
        if valtable.amount <= 100 then 
            InputSide = i
        else if valtable.label == "太阳能盐(冷)" then 
            FromSide = i
        else
        for attr,value in pairs(valtable) do 
            print(attr,value) 
        end 
    end 
    end 
end
end
print(InputSide,FromSide)

local ser = require("serialization")
local gt_machine = component.gt_machine
local infoTable = gt_machine.getSensorInformation()

local f = io.open("table.lua","w")
if f then
    f:write(ser.serialize(infoTable))
    f:close()
end

local nowHeat = -1
local nowHeatTable = gt_machine.getSensorInformation()
for key,val in pairs(nowHeatTable) do 
    if key == "Internal Heat Level" then
        local  nowHeat = ser.unserialize(val)
        break
    end

end

local maxHeat = 100000
local setHeat = 50000
-- 为了确保机器加热 需向其赛进1ml 盐 使其反应


while true do
    local dis = nowHeat - setHeat
    if dis > 0  then
        transposer.transferFluidFromTankToContainer(FromSide,InputSide,dis)
    else if transposer.getFluidInTank(InputSide).amount == 0 then
        transposer.transferFluidFromTankToContainer(FromSide,InputSide,1)
    end
end
end
