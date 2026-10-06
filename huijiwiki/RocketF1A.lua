local p = {}

-- 安全转数字
local function toNumber(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end
 
-- 非负值截断
local function clampNonNegative(n)
    if n < 0 then return 0 end
    return n
end
 
-- 千分位格式化（处理整数部分）
local function addThousands(intStr)
    local sign = ""
    local s = intStr
    if s:sub(1,1) == "-" then
        sign = "-"
        s = s:sub(2)
    end
    local out = s
    while true do
        local n2, k = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
        out = n2
        if k == 0 then break end
    end
    return sign .. out
end
 
-- 通用数字格式化：千分位 + 保留小数（去除尾部无意义的 .0000）
local function formatNum(n)
    if n == nil then return "0" end
    if math.abs(n) >= 1e23 then
        return string.format("%.4e", n)
    end
    local s = string.format("%.4f", n)
    s = s:gsub("%.?0+$", "")
    local int_part, frac_part = string.match(s, "^(-?%d+)%.(%d+)$")
    if not int_part then
        int_part = s
        frac_part = nil
    end
    local formatted = int_part
    while true do
        local k
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    if frac_part then
        return formatted .. "." .. frac_part
    else
        return formatted
    end
end
 
-- 整数格式化
local function fmtInt(v)
    return addThousands(tostring(math.floor((tonumber(v) or 0) + 0.5)))
end
 
-- 布尔（中文）解析
local function parseBoolZh(v, default)
    local s = tostring(v or "")
    if s == "是" or s == "1" or s == "true" then return true end
    if s == "否" or s == "0" or s == "false" then return false end
    return default
end


local BASE_L_EUT = 16384

-- 保证负数可以被三次根
local function copysign(x, y)
    if y < 0 then
        return -math.abs(x)
    else
        return math.abs(x)
    end
end

local function cbrt(x)
    return copysign(math.abs(x) ^ (1.0 / 3.0), x)
end

local function calc_eu_production(energy_t, boost)
    local energy = math.floor(energy_t)
    local energy_efficiency
    if energy > 30000 then
        local t_divide = cbrt(energy)
        energy_efficiency = 31.072325 / t_divide
        if energy >= 80000 then
            energy_efficiency = energy_efficiency * (43.0886938 / t_divide)
        end
        energy_efficiency = energy_efficiency * energy
    else
        energy_efficiency = energy * 1.0
    end
    local eu_production = math.floor(energy_efficiency)
    if boost then
        eu_production = eu_production * 3
    end
    return eu_production
end

local function calculate(special_value, fuel_per_sec, boost)
    boost = boost or false
    local fuel_value = special_value * 3
    local amount, actual_fuel
    if boost then
        amount = math.floor(fuel_per_sec / 3)
        actual_fuel = amount * 3
    else
        amount = math.floor(fuel_per_sec)
        actual_fuel = amount
    end

    if amount < 5 then
        return { ["错误"] = "amount < 5，代码会返回 false，不消耗燃料，不发电" }
    end

    local energy_per_sec = fuel_value * amount
    local energy_t = math.floor(energy_per_sec / 20)

    local eu_prod = calc_eu_production(energy_t, boost)
    local actual_output = math.floor(BASE_L_EUT * eu_prod / 10000)

    local air_per_tick = math.floor(eu_prod / 100)
    local air_per_sec = air_per_tick * 20

    local co2_per_hour = 1000 * (boost and 3 or 1)
    local loh_per_sec = math.floor((3 * eu_prod) / 1000)
    local pollution_per_sec = 1500 * math.floor(eu_prod / 10000)

    local result = {
        ["燃料值 EU/L"] = fuel_value,
        ["实际燃料消耗 L/s"] = actual_fuel,
        ["能量输入 EU/s"] = energy_per_sec,
        ["能量输入 EU/t"] = energy_t,
        ["euProduction"] = eu_prod,
        ["理论最大实际输出 EU/t"] = actual_output,
        ["空气消耗 L/s"] = air_per_sec,
        ["CO2 消耗 L/h"] = co2_per_hour,
        ["液氢消耗 L/s"] = loh_per_sec,
        ["污染 gibbl/s"] = pollution_per_sec,
        ["启动提示"] = eu_prod >= 2000 and "约 100 秒达到最大效率" or "euProduction < 2000，mEfficiencyIncrease = 0，无法启动"
    }
    return result
end

local function raw_to_consumption(raw_fuel, boost)
    if boost then
        local amount = math.floor(raw_fuel * 0.3)
        return amount * 3
    else
        return math.floor(raw_fuel * 0.9)
    end
end

local function generateVoltMap()
	-- LV阶段的电压
	local baseVolt = 32
	local map = {baseVolt}
	
	for i =1 ,20 do 
		baseVolt = baseVolt * 4
		table.insert(map,baseVolt)
	end
	
	return map
end

local function getVoltMapNumber()
	return {
		["lv"]=1,
		["mv"]=2,
		["hv"]=3,
		["ev"]=4,
		["iv"]=5,
		["luv"]=6,
		["zpm"]=7,
		["uv"]=8,
		["uhv"]=9,
		["uev"]=10,
		["uiv"]=11,
		["umv"]=12,
		["uxv"]=13
	}
end


function p.calculate(frame)
    local fuel = frame.args.fuel or "RP-1火箭燃料"
    local isBoost = parseBoolZh(frame.args.isBoost, false)
    local fuelRate = toNumber(frame.args.fuelRate, 0)
    local powerTier = tostring(frame.args.powerTier or "lv")

    local voltNumberMap = getVoltMapNumber()
    local voltMap = generateVoltMap()

    local fuelValueMap = {
        ["RP-1火箭燃料"] = 1536,
        ["密集肼火箭燃料"] = 3072,
        ["CN3H7O3火箭燃料"] = 6144,
        ["H8N4C2O4火箭燃料"] = 12588
    }
    local fuelValue = fuelValueMap[fuel] or 1536
    local result = calculate(fuelValue / 3, fuelRate, isBoost)

    if result["错误"] then
        return '<div class="lua-smart-response">'
            .. r("错误", result["错误"])
            .. '</div>'
    end

    local power_0 = result["能量输入 EU/t"]
    
    local power = result["理论最大实际输出 EU/t"]
    local airConsumption = result["空气消耗 L/s"]
    local CO2Consumption = result["CO2 消耗 L/h"]
    local HydrogenConsumption = result["液氢消耗 L/s"]
    local PollutionGeneration = result["污染 gibbl/s"]


	local efficiency = power / power_0
	if isBoost then 
		efficiency = efficiency / 3
		end
    local voltIndex = voltNumberMap[string.lower(powerTier)]
    local trans_volt = voltIndex and voltMap[voltIndex] or voltMap[1]
    local power_transed = power / trans_volt

    local function r(name, val)
        return '<div class="form-response" data-variable="' .. name .. '">' .. tostring(val) .. '</div>'
    end

    return '<div class="lua-smart-response">'
        .. r("fuelValue", toNumber(fuelValue, 0))
        .. r("power_0", formatNum(power_0))
        .. r("efficiency", formatNum(efficiency*100))
        .. r("power", formatNum(power))
        .. r("airConsumption", formatNum(airConsumption))
        .. r("CO2Consumption", formatNum(CO2Consumption))
        .. r("HydrogenConsumption", formatNum(HydrogenConsumption))
        .. r("PollutionGeneration", formatNum(PollutionGeneration))
        .. r("power_transed", formatNum(power_transed))
        .. r("tier_trans", powerTier)

        .. '</div>'
end

return p
