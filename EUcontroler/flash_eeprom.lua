--[[
  EUcontroler - EEPROM 烧录工具（在一台正常的 OpenOS 电脑上运行）

  作用:
    把 main.lua 的源码前面拼接一段 "BIOS 兼容层"(shim)，再整体写入 EEPROM 的启动代码区。
    装好这块 EEPROM 的电脑开机后会直接运行 EUcontroller，不再启动 OpenOS。

  用法:
    flash_eeprom.lua                     -- 烧录本目录下的 main.lua
    flash_eeprom.lua <源文件> <标签>      -- 指定源文件 / EEPROM 标签
    flash_eeprom.lua -o image.lua        -- 只生成镜像文件，不烧录（可在 OpenOS 里先跑一遍测试）
    flash_eeprom.lua -r                  -- 烧录成功后立即重启

  选项:
    -o FILE   把生成的 BIOS 镜像写到文件，不写入 EEPROM
    -r        烧录成功后立刻重启电脑
    -q        安静模式，不询问确认、不输出多余信息

  安全提示:
    * 烧录期间绝对不能断电或重启，否则 EEPROM 内容会损坏；
    * 会覆盖 EEPROM 原有 BIOS，建议先备份: `flash -r eeprom_backup.lua`；
    * 脚本会自动检查代码是否超出 EEPROM 容量。
]]

-- ============================================================================
-- BIOS 兼容层：EEPROM 代码运行在机器沙盒里，没有 require / print / io，
-- 但有 component、computer 全局表和标准库。下面这段会被原样拼到 main.lua 前面。
-- （注意：这是长字符串，里面的 \n \t 会原样写入镜像，由 EEPROM 侧再解析。）
-- ============================================================================
local SHIM = [==[
-- =====================================================================
-- EUcontroler EEPROM boot shim (auto generated - do not edit by hand)
-- Runs as computer BIOS: OpenOS is NOT loaded, so there is no
-- require()/print()/io. This shim provides only what the program needs:
--   require("component"/"computer"/"sides"), sides table,
--   print() (draws on the first screen), os.sleep().
-- =====================================================================
local rawComponent = component
local rawComputer = computer
if not rawComponent and type(require) == "function" then rawComponent = require("component") end
if not rawComputer and type(require) == "function" then rawComputer = require("computer") end

local function compList(ctype)
  local iter = rawComponent.list(ctype)
  if not iter then return nil end
  return iter()
end

local function compProxy(address)
  if not address then return nil end
  if rawComponent.proxy then
    local ok, proxy = pcall(rawComponent.proxy, address)
    if ok and proxy then return proxy end
  end
  -- Fallback: build a tiny proxy on top of component.invoke
  local proxy = { address = address }
  return setmetatable(proxy, {
    __index = function(_, method)
      return function(...) return rawComponent.invoke(address, method, ...) end
    end
  })
end

-- component 表的按类型索引（component.gt_machine / component.redstone 等）
local componentCompat = setmetatable({}, {
  __index = function(self, key)
    local value = rawComponent[key]
    if value == nil then value = compProxy(compList(key)) end
    if value ~= nil then rawset(self, key, value) end
    return value
  end
})

-- OpenComputers 侧面常量: down=0 up=1 north=2 south=3 west=4 east=5
local sides = { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 }

local function biosRequire(name)
  if name == "component" then return componentCompat end
  if name == "computer" then return rawComputer end
  if name == "sides" then return sides end
  error("BIOS: module not available: " .. tostring(name), 0)
end
if type(require) ~= "function" then require = biosRequire end

-- ---------------------------- 屏幕输出 ----------------------------
local gpu = compProxy(compList("gpu"))
local screen = compList("screen")
local screenWidth, screenHeight, screenLine = 80, 25, 1
if gpu then
  if screen and gpu.bind then pcall(gpu.bind, screen) end
  local ok, w, h = pcall(gpu.getResolution)
  if ok and type(w) == "number" then
    screenWidth, screenHeight = w, h
  end
end

local function writeLine(text)
  if not gpu then return end
  text = tostring(text)
  if unicode and type(unicode.wtrunc) == "function" then
    local ok, fitted = pcall(unicode.wtrunc, text, screenWidth)
    if ok and fitted then text = fitted end
  end
  if screenLine > screenHeight then
    pcall(gpu.copy, 1, 2, screenWidth, screenHeight - 1, 0, -1)
    pcall(gpu.fill, 1, screenHeight, screenWidth, 1, " ")
    screenLine = screenHeight
  end
  pcall(gpu.set, 1, screenLine, text)
  screenLine = screenLine + 1
end

if type(print) ~= "function" then
  print = function(...)
    local count = select("#", ...)
    local parts = {}
    for index = 1, count do
      parts[index] = tostring((select(index, ...)))
    end
    local text = table.concat(parts, "\t") .. "\n"
    for line in text:gmatch("([^\n]*)\n") do
      writeLine(line)
    end
  end
end

-- ---------------------------- os.sleep ----------------------------
local osCompat = os or {}
if type(osCompat.sleep) ~= "function" then
  osCompat.sleep = function(timeout) rawComputer.pullSignal(timeout or 0) end
end
os = osCompat
]==]

-- ============================================================================
-- 烧录工具本体
-- ============================================================================
local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local process = require("process")
local shell = require("shell")

local args, options = shell.parse(...)

if options.h or options.help then
  io.write("Usage: flash_eeprom [-q] [-r] [-o FILE] [source.lua] [label]\n")
  io.write("  -o FILE  write the generated BIOS image to FILE instead of flashing\n")
  io.write("  -q       quiet, do not ask for confirmation\n")
  io.write("  -r       reboot after a successful flash\n")
  io.write("  source   program to embed (default: main.lua next to this script)\n")
  io.write("  label    EEPROM label (default: EUcontroler)\n")
  return 0
end

local eeprom = component.eeprom
if not eeprom and not options.o then
  io.stderr:write("未找到 EEPROM 组件：请先在这台电脑上装一块 EEPROM 再运行。\n")
  return 1
end

-- ---------------------------- 解析源文件路径 ----------------------------
local sourcePath = args[1]
if sourcePath then
  sourcePath = shell.resolve(sourcePath)
else
  local scriptPath
  pcall(function() scriptPath = process.running() end)
  local scriptDir = scriptPath and fs.path(scriptPath) or shell.getWorkingDirectory()
  sourcePath = fs.concat(scriptDir, "main.lua")
end

local label = args[2] or "EUcontroler"

-- ---------------------------- 读取源码 ----------------------------
local handle, reason = io.open(sourcePath, "rb")
if not handle then
  io.stderr:write("无法打开源文件: " .. tostring(sourcePath) .. " (" .. tostring(reason) .. ")\n")
  return 1
end
local program = handle:read("*a")
handle:close()

if not program or #program == 0 then
  io.stderr:write("源文件为空: " .. tostring(sourcePath) .. "\n")
  return 1
end

-- ---------------------------- 生成 BIOS 镜像 ----------------------------
local runnerHead = "\n-- ===== run embedded program, keep the screen alive on error =====\n" ..
                   "local __ok, __err = pcall(function()\n"
local runnerTail = "\nend)\n" ..
                   "if not __ok then\n" ..
                   "  writeLine('BIOS: program error: ' .. tostring(__err))\n" ..
                   "  while true do rawComputer.pullSignal(60) end\n" ..
                   "end\n"

local image = SHIM .. "\n-- ===== embedded program =====\n" ..
        runnerHead .. program .. runnerTail

-- ---------------------------- 容量检查 ----------------------------
local capacity
if eeprom then
  capacity = eeprom.getSize()
end

if not options.q and not options.o then
  io.write("源文件   : " .. sourcePath .. "\n")
  io.write("EEPROM标签: " .. label .. "\n")
  io.write("镜像大小 : " .. #image .. " 字节")
  if capacity then
    io.write(" / EEPROM 容量 " .. capacity .. " 字节\n")
  else
    io.write("\n")
  end
end

if capacity and #image > capacity then
  io.stderr:write("镜像太大，装不进 EEPROM（超出 " .. (#image - capacity) .. " 字节）。\n")
  return 1
end

-- ---------------------------- 只写文件（测试用） ----------------------------
if options.o then
  if type(options.o) ~= "string" then
    io.stderr:write("-o 需要跟一个文件名, 例如: flash_eeprom.lua -o image.lua\n")
    return 1
  end
  local outPath = shell.resolve(options.o)
  local out = assert(io.open(outPath, "wb"))
  out:write(image)
  out:close()
  io.write("已生成镜像文件: " .. outPath .. "（可先用 lua " .. outPath .. " 在 OpenOS 下测试）\n")
  return 0
end

-- ---------------------------- 确认 ----------------------------
if not options.q then
  io.write("\n警告: 烧录期间绝对不要断电或重启！\n")
  io.write("按 y 确认烧录，其它键取消: ")
  local answer = (io.read() or ""):lower()
  if answer:sub(1, 1) ~= "y" then
    io.write("已取消。\n")
    return 0
  end
  io.write("正在写入 EEPROM，请不要断电...\n")
end

-- ---------------------------- 写入 EEPROM ----------------------------
local _, writeReason = eeprom.set(image)
if writeReason then
  io.stderr:write("烧录失败: " .. tostring(writeReason) .. "\n")
  return 1
end

local _, labelReason = eeprom.setLabel(label)
if labelReason then
  io.stderr:write("标签设置失败: " .. tostring(labelReason) .. "\n")
  return 1
end

if not options.q then
  io.write("烧录完成，EEPROM 标签: '" .. tostring(eeprom.getLabel()) .. "'\n")
  io.write("代码校验和: " .. tostring(eeprom.getChecksum()) .. "\n")
end

if options.r then
  computer.shutdown(true)
end

return 0
