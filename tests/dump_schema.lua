-- 把 TriviaReward.lua 真实执行的建表/初始化 SQL 抓出来，交给 mysql 客户端执行。
-- 这样能校验脚本里的 DDL 在真实 MySQL 上是否成立，同时让面板在 worldserver 启动前就有表可用。
-- 用法: lua.exe dump_schema.lua <脚本> <配置> <输出.sql>

local SCRIPT = arg[1] or "E:/Server/lua/TriviaReward.lua"
local CONF   = arg[2] or "E:/Server/lua/TriviaReward_conf.lua"
local OUT    = arg[3] or "E:/Server/.tmp-luacheck/schema.sql"

os.time = function() return 1000000 end
local world, handlers = {}, {}
function PrintInfo(...) end
function PrintError(...) io.stderr:write("ERR: " .. table.concat({...}, " ") .. "\n") end
function SendWorldMessage(m) world[#world + 1] = m end
function CreateLuaEvent() return 1 end
function RemoveEventById() end
function GetPlayerCount() return 1 end
function GetPlayerByName() return nil end
function GetItemTemplate(e) return e and e > 0 and { GetName = function() return "i" end } or nil end
function GetItemLink(e) return "[item" .. tostring(e) .. "]" end
function SendMail() end
function RegisterPlayerEvent(id, fn) handlers[id] = fn end

local captured = {}

local function newQuery(rows)
    local q = { rows = rows or {}, index = 0 }
    function q:GetRow() return self.rows[self.index + 1] end
    function q:NextRow() if self.index + 1 >= #self.rows then return false end self.index = self.index + 1 return true end
    return q
end

-- 模拟"空库"：建表成功、表存在但都是空的 → 走首次初始化分支
function CharDBExecute(sql) captured[#captured + 1] = sql; return true end
function CharDBQuery(sql)
    if sql:match("^%s*CREATE") or sql:match("^%s*INSERT") or sql:match("^%s*REPLACE") then
        captured[#captured + 1] = sql
        return newQuery({ { c = 0 } })
    end
    if sql:find("information_schema", 1, true) then
        return newQuery({ { c = 4 } })
    end
    return newQuery({ { c = 0 } }) -- COUNT(*) 一律 0：让脚本写出默认设置与预设
end

assert(loadfile(SCRIPT))()
assert(loadfile(CONF))()
handlers[42](42, nil, "trivia status", { SendSysMessage = function() end })

local f = assert(io.open(OUT, "w"))
local n = 0
for i = 1, #captured do
    local sql = captured[i]
    if sql:match("^%s*CREATE") or sql:match("^%s*INSERT") then
        f:write(sql:gsub(";%s*$", "") .. ";\n")
        n = n + 1
    end
end
f:close()
print(string.format("已导出 %d 条 SQL 到 %s", n, OUT))
