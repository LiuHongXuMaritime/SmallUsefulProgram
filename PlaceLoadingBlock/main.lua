local component = require("component")
local sides = require("sides")
local navigation = component.navigation
local robot = require("robot")
local ser = require("serialization")

-- 巡航高度：放置加载方块时机器人悬停的高度
local SET_Y = 200
-- 放置间距：每 3 个区块（16*3）放一个加载方块
local DIS = 16 * 3
-- 进度存档文件
local GRID_FILE = "grid_data.lua"
-- 每个区块锚每次补充的末影珍珠数量
local PEARL_PER_VISIT = 8

--------------------------------------------------------------------------
-- 存档读写
--------------------------------------------------------------------------

local function loadGridFromDisk()
    local file = io.open(GRID_FILE, "r")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    if not data or data == "" then
        return nil
    end
    local ok, grid = pcall(ser.unserialize, data)
    if not ok or type(grid) ~= "table" or type(grid.cells) ~= "table" then
        print("存档 " .. GRID_FILE .. " 格式不正确，将重新生成网格")
        return nil
    end

    -- 兼容旧存档：旧格式只有 nx/nz 且索引从 0 开始
    if grid.i_min == nil then
        grid.i_min, grid.i_max = 0, (grid.nx or 1) - 1
        grid.j_min, grid.j_max = 0, (grid.nz or 1) - 1
        grid.x1 = grid.origin_x
        grid.x2 = grid.origin_x + grid.i_max * DIS
        grid.z1 = grid.origin_z
        grid.z2 = grid.origin_z + grid.j_max * DIS
    end
    return grid
end

local function saveGridToDisk(grid)
    local file = io.open(GRID_FILE, "w")
    if not file then
        print("无法写入 " .. GRID_FILE .. "，请检查权限")
        return false
    end
    file:write(ser.serialize(grid))
    file:close()
    return true
end

--------------------------------------------------------------------------
-- 网格（水平面为 X-Z）
--------------------------------------------------------------------------

--- 按给定世界坐标范围生成网格；ax/az 为可选网格锚点（默认取最小角）
local function buildGrid(x1, x2, z1, z2, ax, az)
    local x_min, x_max = math.min(x1, x2), math.max(x1, x2)
    local z_min, z_max = math.min(z1, z2), math.max(z1, z2)

    local origin_x = ax or x_min
    local origin_z = az or z_min

    local grid = {
        origin_x = origin_x,
        origin_z = origin_z,
        i_min = math.floor((x_min - origin_x) / DIS),
        i_max = math.floor((x_max - origin_x) / DIS),
        j_min = math.floor((z_min - origin_z) / DIS),
        j_max = math.floor((z_max - origin_z) / DIS),
        -- 记录区域边界，下次可直接复用 / 扩大
        x1 = x_min, x2 = x_max, z1 = z_min, z2 = z_max,
        cells = {}, -- cells[i][j] == true 表示已放置
    }
    for i = grid.i_min, grid.i_max do
        grid.cells[i] = {}
        for j = grid.j_min, grid.j_max do
            grid.cells[i][j] = false
        end
    end
    return grid
end

--- 网格总格数
local function gridTotal(grid)
    return (grid.i_max - grid.i_min + 1) * (grid.j_max - grid.j_min + 1)
end

--- 格号 (i, j) 换算成世界坐标
local function cellToWorld(grid, i, j)
    return grid.origin_x + i * DIS, grid.origin_z + j * DIS
end

--- 在原有网格基础上扩大范围（与旧边界取并集），
--- 只向外扩、不缩小，已放置/已投喂的记录全部保留。
local function expandGrid(grid, x1, x2, z1, z2)
    local x_min, x_max = math.min(x1, x2), math.max(x1, x2)
    local z_min, z_max = math.min(z1, z2), math.max(z1, z2)

    local n_x1 = math.min(grid.x1, x_min)
    local n_x2 = math.max(grid.x2, x_max)
    local n_z1 = math.min(grid.z1, z_min)
    local n_z2 = math.max(grid.z2, z_max)

    local origin_x, origin_z = grid.origin_x, grid.origin_z
    local ni_min = math.floor((n_x1 - origin_x) / DIS)
    local ni_max = math.floor((n_x2 - origin_x) / DIS)
    local nj_min = math.floor((n_z1 - origin_z) / DIS)
    local nj_max = math.floor((n_z2 - origin_z) / DIS)

    local old_cells = grid.cells
    local old_fueled = grid.fueled
    local cells, fueled = {}, {}
    for i = ni_min, ni_max do
        cells[i] = {}
        fueled[i] = {}
        for j = nj_min, nj_max do
            cells[i][j] = (old_cells[i] and old_cells[i][j]) or false
            fueled[i][j] = (old_fueled and old_fueled[i] and old_fueled[i][j]) or false
        end
    end

    grid.i_min, grid.i_max = ni_min, ni_max
    grid.j_min, grid.j_max = nj_min, nj_max
    grid.x1, grid.x2, grid.z1, grid.z2 = n_x1, n_x2, n_z1, n_z2
    grid.cells = cells
    grid.fueled = fueled
    return grid
end

local function readBoundary(title)
    title = title or "当前区域"
    print("请输入" .. title .. "的 X1 坐标")
    local x1 = tonumber(io.read())
    print("请输入" .. title .. "的 X2 坐标")
    local x2 = tonumber(io.read())
    print("请输入" .. title .. "的 Z1 坐标")
    local z1 = tonumber(io.read())
    print("请输入" .. title .. "的 Z2 坐标")
    local z2 = tonumber(io.read())
    if not (x1 and x2 and z1 and z2) then
        return nil
    end
    return x1, x2, z1, z2
end

--- 确保机器人悬停在 SET_Y 高度
local function ensureAltitude()
    local x, y, z = navigation.getPosition()
    if not x then
        return false, "无法获取当前位置（超出导航范围？）"
    end
    while y < SET_Y do
        if not robot.up() then
            return false, "无法上升，请检查是否有障碍物或电量不足"
        end
        y = y + 1
    end
    while y > SET_Y do
        if not robot.down() then
            return false, "无法下降，请检查是否有障碍物或电量不足"
        end
        y = y - 1
    end
    return true
end

--- 原地转身直到朝向 side（只能绕 Y 轴转，最多 4 次）
local function faceTowards(side)
    local facing = navigation.getFacing()
    for _ = 1, 4 do
        if facing == side then
            return true
        end
        if not robot.turnLeft() then
            return false
        end
        facing = navigation.getFacing()
    end
    return false
end


--- 沿 X 或 Z 轴移动 step 格（step 可正可负）
local function moveAxis(alongX, step)
    if step == 0 then
        return true
    end
    local side
    if alongX then
        side = step > 0 and sides.posx or sides.negx
    else
        side = step > 0 and sides.posz or sides.negz
    end

    if not faceTowards(side) then
        return false, "转身失败"
    end

    for _ = 1, math.abs(step) do
        if not robot.forward() then
            return false, "无法前进，请检查是否有障碍物或电量不足"
        end
    end
    return true
end



--- 移动到目标世界坐标（先走 X，再走 Z）
local function moveToPosition(target_x, target_z)
    local x, y, z = navigation.getPosition()
    if not x then
        return false, "无法获取当前位置（超出导航范围？）"
    end

    local ok, err = moveAxis(true, target_x - x)
    if not ok then
        return false, err
    end

    x, y, z = navigation.getPosition()
    if not x then
        return false, "无法获取当前位置（超出导航范围？）"
    end
    ok, err = moveAxis(false, target_z - z)
    if not ok then
        return false, err
    end
    return true
end

--- 记录起始点（home）：首次运行时记录当前位置并存档
local function ensureHome(grid)
    if grid.home_x and grid.home_z then
        return true
    end
    local x, y, z = navigation.getPosition()
    -- 导航坐标可能是浮点数，用 %.0f 格式化，避免 %d 报错
    if type(x) ~= "number" or type(z) ~= "number" then
        return false, "无法获取当前位置，无法记录起始点"
    end
    grid.home_x, grid.home_z = x, z
    saveGridToDisk(grid)
    print(string.format("已记录起始点：(%.0f, %.0f)", x, z))
    return true
end

--- 任务完成后返回起始点
local function returnHome(grid)
    if not (grid.home_x and grid.home_z) then
        return true -- 未记录起始点，跳过
    end
    local ok, err = ensureAltitude()
    if not ok then
        return false, err
    end
    ok, err = moveToPosition(grid.home_x, grid.home_z)
    if not ok then
        return false, err
    end
    print("已返回起始点", grid.home_x, grid.home_z)
    while robot.down() do
    end
    return true
end

--- 返回第一个有物品的槽位，没有则返回 nil
local function searchSlotUseful()
    for slot = 1, 16 do
        if robot.count(slot) > 0 then
            return slot
        end
    end
    return nil
end

--- 在当前位置下方放置一个加载方块
local function placeLoadingBlock()
    local slot = searchSlotUseful()
    if not slot then
        return false, "背包里没有可放置的方块"
    end
    robot.select(slot)
    if not robot.placeDown() then
        return false, "放置失败（下方已有方块或空间不足）"
    end
    return true
end

--- 查找装有末影珍珠的槽位，没有则返回 nil
local function findPearlSlot(nowSlot)
    local ic = component.inventory_controller
    if ic then
        for slot = 1, robot.inventorySize() do
            if slot ~= nowSlot then
                local stack = ic.getStackInInternalSlot(slot)
                if stack and stack.name then
                    -- 归一化物品名：去掉空格/下划线/横线/点，再匹配 enderpearl
                    local name = stack.name:lower():gsub("[%s_%-%.]", "")
                    if name:find("enderpearl", 1, true) then
                        return slot, stack.count
                    end
                end
            end
        end
    end
    -- 没有 inventory_controller 升级时，退化为第一个非空槽位
    return searchSlotUseful()
end

local function reFuelAnchorSlot(nowSelectSlot,needFuelAmount)
    local nowCount = robot.count(nowSelectSlot)
    if nowCount + needFuelAmount > 64 then
        print("当前槽位末影珍珠数量过多，无法补充")
        needFuelAmount = 64 - nowCount
    end

    local nextSlot, nextCount = findPearlSlot(nowSelectSlot)
    local needFuelAmount = needFuelAmount or PEARL_PER_VISIT
    if nextSlot then
        if needFuelAmount <= nextCount then
            robot.select(nextSlot)
            robot.transferTo(nowSelectSlot, needFuelAmount)
            print("单次补充完毕")
        else 
            robot.select(nextSlot)
            robot.transferTo(nowSelectSlot, nextCount)
            reFuelAnchorSlot(nowSelectSlot,needFuelAmount - nextCount)
        end
        
    end

end

--- 为正下方的区块锚补充末影珍珠
local function refuelAnchor()
    local nowSelectSlot =  robot.select()
    local startSlot = findPearlSlot(nowSelectSlot)
    if not startSlot then
        return false, "背包里没有末影珍珠"
    end

    robot.select(startSlot)

    -- todo
    -- 自动补充库存 而非换取槽位
    reFuelAnchorSlot(nowSelectSlot,PEARL_PER_VISIT)
    local have = robot.count(startSlot)
    if have <= 0 then
        return false, "背包里没有末影珍珠"
    end
    -- 将末影珍珠丢入正下方的区块锚燃料槽
    local ok = robot.dropDown(math.min(have,PEARL_PER_VISIT))
    if not ok then
        return false, "补充末影珍珠失败（下方不是区块锚或空间不足）"
    end
    return true
end

--------------------------------------------------------------------------
-- 蛇形遍历（支持断点续跑）
--------------------------------------------------------------------------

--- 蛇形顺序中的下一格；越界时返回 i_max+1 作为结束哨兵
local function nextCell(grid, i, j)
    local odd = ((i - grid.i_min) % 2 == 1)
    local j_end = odd and grid.j_min or grid.j_max
    local j_step = odd and -1 or 1

    if j ~= j_end then
        return i, j + j_step
    end
    i = i + 1
    if i > grid.i_max then
        return grid.i_max + 1, grid.j_min -- 越界哨兵：遍历结束
    end
    local new_odd = ((i - grid.i_min) % 2 == 1)
    return i, (new_odd and grid.j_max or grid.j_min)
end

--- 通用蛇形遍历：
--- 从存档游标处继续，逐格调用 action；每完成一格就把游标指向下一格并写盘，
--- 这样机器人关机/意外中断后能直接从上次位置继续，而不是从头扫。
--- grid：存档网格；cursorKey：游标字段名；isDone(i,j)：该格是否已完成；
--- done：已完成数量；total：总数量；action(i,j,tx,tz)：执行动作；label：日志前缀。
local function traverseAll(grid, cursorKey, isDone, done, total, action, label)
    local i, j = grid.i_min, grid.j_min
    local cur = grid[cursorKey]
    if type(cur) == "table" and type(cur.i) == "number" and type(cur.j) == "number"
        and cur.i >= grid.i_min and cur.i <= grid.i_max
        and cur.j >= grid.j_min and cur.j <= grid.j_max then
        i, j = cur.i, cur.j
        print(string.format("检测到上次进度，从格 (%d, %d) 继续", i, j))
    end

    while i <= grid.i_max do
        if not isDone(i, j) then
            local tx, tz = cellToWorld(grid, i, j)

            local ok, err = ensureAltitude()
            if not ok then
                print("调整高度失败：" .. err)
                return false, done
            end

            ok, err = moveToPosition(tx, tz)
            if not ok then
                print("移动到 (" .. tx .. ", " .. tz .. ") 失败：" .. err)
                return false, done
            end

            ok, err = action(i, j, tx, tz)
            if not ok then
                print("在 (" .. tx .. ", " .. tz .. ") " .. label .. "失败：" .. err)
                return false, done
            end

            done = done + 1
            -- 游标指向下一格，保证关机/中断后能续跑
            local ni, nj = nextCell(grid, i, j)
            if ni <= grid.i_max then
                grid[cursorKey] = { i = ni, j = nj }
            else
                grid[cursorKey] = nil
            end
            saveGridToDisk(grid)
            print(string.format("%s %d/%d：(%.0f, %.0f)", label, done, total, tx, tz))
        end

        i, j = nextCell(grid, i, j)
    end
    return true, done
end

--------------------------------------------------------------------------
-- 动作：放置 / 投喂
--------------------------------------------------------------------------

--- 放置锚并立即投喂末影珍珠，使其马上开始工作
local function placeAndFuelAction(grid, i, j)
    local ok, err = placeLoadingBlock()
    if not ok then
        return false, err
    end
    grid.cells[i][j] = true
    -- 放置成功后立即写盘，避免中途断电后重复放置同一格
    saveGridToDisk(grid)

    local ok2, err2 = refuelAnchor()
    if ok2 then
        grid.fueled = grid.fueled or {}
        grid.fueled[i] = grid.fueled[i] or {}
        grid.fueled[i][j] = true
    else
        print("  警告：已放置但投喂末影珍珠失败：" .. err2)
    end
    return true
end

--- 为已放置的锚补充末影珍珠
local function fuelAction(grid, i, j)
    local ok, err = refuelAnchor()
    if not ok then
        return false, err
    end
    grid.fueled = grid.fueled or {}
    grid.fueled[i] = grid.fueled[i] or {}
    grid.fueled[i][j] = true
    return true
end



local function main1()
    local x, y, z = navigation.getPosition()
    if not x then
        print("无法获取当前位置，请检查导航模块是否安装正确")
        return
    end

    -- 有存档就直接复用其边界，无需再输入；否则询问新建
    local grid = loadGridFromDisk()
    if grid then
        print(string.format("已加载存档区域 X[%.0f, %.0f] Z[%.0f, %.0f]（如需扩大请选 3）",
            grid.x1, grid.x2, grid.z1, grid.z2))
    else
        local x1, x2, z1, z2 = readBoundary()
        if not x1 then
            print("输入的坐标有误，请重新运行程序")
            return
        end
        grid = buildGrid(x1, x2, z1, z2)
    end

    -- 记录起始点（首次运行时），任务结束后返回
    ensureHome(grid)

    local ok, err = ensureAltitude()
    if not ok then
        print(err)
        return
    end

    if not searchSlotUseful() then
        print("背包里没有可放置的方块")
        return
    end

    -- 统计已放置的格子
    local total = gridTotal(grid)
    local placed = 0
    for i = grid.i_min, grid.i_max do
        for j = grid.j_min, grid.j_max do
            if grid.cells[i][j] then
                placed = placed + 1
            end
        end
    end

    if placed >= total then
        print("该区域已全部放置完成，无需重复执行")
        return
    end
    print(string.format("共 %d 格，已完成 %d 格", total, placed))

    -- 蛇形遍历（断点续跑），放置后立即投喂末影珍珠
    local ok2, done = traverseAll(grid, "cursor_place",
        function(i, j) return grid.cells[i][j] end,
        placed, total,
        function(i, j) return placeAndFuelAction(grid, i, j) end,
        "已放置")
    if ok2 then
        print("全部放置完成，共 " .. done .. " 格")
        local okHome, errHome = returnHome(grid)
        if not okHome then
            print("返回起始点失败：" .. errHome)
        end
    end
end

-- suppy some 末影珍珠
local function main2()
    local grid = loadGridFromDisk()
    if not grid then
        print("未找到存档，请先执行放置程序")
        return
    end

    -- 确保背包里有末影珍珠
    if not findPearlSlot() then
        print("背包里没有末影珍珠，请先装填后再运行")
        return
    end

    local ok, err = ensureAltitude()
    if not ok then
        print(err)
        return
    end

    ensureHome(grid)

    -- 记录每个锚是否已补充过
    grid.fueled = grid.fueled or {}

    -- 统计已放置的锚与已补充的数量
    local total = 0
    local fueled = 0
    for i = grid.i_min, grid.i_max do
        grid.fueled[i] = grid.fueled[i] or {}
        for j = grid.j_min, grid.j_max do
            if grid.cells[i][j] then
                total = total + 1
                if grid.fueled[i][j] then
                    fueled = fueled + 1
                end
            end
        end
    end

    if total == 0 then
        print("存档中没有已放置的锚，请先执行放置程序")
        return
    end

    if fueled >= total then
        print("所有区块锚均已补充过末影珍珠，无需重复执行")
        return
    end
    print(string.format("共有 %d 个已放置的锚，已补充 %d 个", total, fueled))

    -- 蛇形遍历（断点续跑），只处理已放置且未补充的格子
    local ok2, done = traverseAll(grid, "cursor_fuel",
        function(i, j) return (not grid.cells[i][j]) or grid.fueled[i][j] end,
        fueled, total,
        function(i, j) return fuelAction(grid, i, j) end,
        "已补充")
    if ok2 then
        print("全部补充完成，共 " .. done .. " 个区块锚")
        -- 全部补充完毕，重置补充状态，方便下次重新补充
        grid.fueled = {}
        for i = grid.i_min, grid.i_max do
            grid.fueled[i] = {}
            for j = grid.j_min, grid.j_max do
                grid.fueled[i][j] = false
            end
        end
        grid.cursor_fuel = nil
        saveGridToDisk(grid)
        print("已重置补充状态，下次运行可重新补充")
        local okHome, errHome = returnHome(grid)
        if not okHome then
            print("返回起始点失败：" .. errHome)
        end
    end
end

--- 扩大范围：在原有区域基础上向外扩展，已放置/已投喂的锚不受影响
local function main3()
    local grid = loadGridFromDisk()
    if not grid then
        print("未找到存档，请先执行放置程序")
        return
    end

    print(string.format("当前区域 X[%.0f, %.0f] Z[%.0f, %.0f]",
        grid.x1, grid.x2, grid.z1, grid.z2))
    print("请输入扩大后的新边界（只会向外取并集，不会缩小或移动已放置的锚）")

    local x1, x2, z1, z2 = readBoundary("扩大后区域")
    if not x1 then
        print("输入的坐标有误，请重新运行程序")
        return
    end

    local old = string.format("X[%.0f, %.0f] Z[%.0f, %.0f]", grid.x1, grid.x2, grid.z1, grid.z2)
    expandGrid(grid, x1, x2, z1, z2)
    saveGridToDisk(grid)

    local total = gridTotal(grid)
    local placed = 0
    for i = grid.i_min, grid.i_max do
        for j = grid.j_min, grid.j_max do
            if grid.cells[i][j] then
                placed = placed + 1
            end
        end
    end

    if old == string.format("X[%.0f, %.0f] Z[%.0f, %.0f]", grid.x1, grid.x2, grid.z1, grid.z2) then
        print("范围没有变化（新边界未超出原范围）")
    else
        print(string.format("已扩大为 X[%.0f, %.0f] Z[%.0f, %.0f]",
            grid.x1, grid.x2, grid.z1, grid.z2))
        print("如需放置新增的锚，请重新运行并选择 1")
    end
    print(string.format("当前共 %d 格，已放置 %d 格", total, placed))
end

local function main()
    print("请选择操作：")
    print("  1. 放置加载方块（区块锚）")
    print("  2. 补充末影珍珠")
    print("  3. 扩大区域范围")
    local press = io.read()
    if press == "1" then
        main1()
    elseif press == "2" then
        main2()
    elseif press == "3" then
        main3()
    else
        print("无效的选项，请输入 1、2 或 3")
    end
end

main()