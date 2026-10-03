

local robot = require("robot")
local sides = require("sides")

NowSlot = 1

robot.

robot.select(NowSlot)
local function main()
    while robot.forward() do
        if robot.count(NowSlot) == 0 then
            NowSlot = NowSlot + 1
            robot.select(NowSlot)
        end  
        robot.placeUp()
    end    
    print("放置完成")
end


main()
