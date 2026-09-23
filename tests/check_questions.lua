-- 题库自检工具：加载 TriviaReward.lua（可选再加载一个旧配置文件），打印最终解析结果
-- 用法:  lua.exe check_questions.lua <脚本> [快照路径]
--        （兼容旧写法：第二个参数文件名里含 "conf" 时按配置文件加载，快照顺延到第三个参数）
-- 作用:
--   有 db_snapshot.lua（由 dump_db_snapshot.php 从真实数据库导出）时，
--   按脚本自身的解析规则校验**数据库里真实的题库**，写错的题会在这里暴露；
--   没有快照则模拟"数据库不可用"，校验内置题库这条兜底路径。

local SCRIPT = arg[1] or "E:/Server/lua/TriviaReward.lua"
local CONF, SNAPSHOT = nil, nil
local SCRIPT_DIR = (arg[0] or ""):match("^(.*)[/\\]") or "."
if arg[2] ~= nil and arg[2]:find("conf", 1, true) ~= nil then
    CONF = arg[2]
    SNAPSHOT = arg[3]
else
    SNAPSHOT = arg[2]
end
SNAPSHOT = SNAPSHOT or (SCRIPT_DIR .. "/db_snapshot.lua")

local snapshot = nil
do
    local chunk = loadfile(SNAPSHOT)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" and type(data.questions) == "table" then
            snapshot = data
        end
    end
end

-- ---- 最小 ALE 环境 ----
os.time = function() return 1000000 end
local errors = {}
function PrintInfo(...) end
function PrintError(...) errors[#errors + 1] = table.concat({ ... }, " ") end
function SendWorldMessage() end
function CreateLuaEvent() return 1 end
function RemoveEventById() end
function GetPlayerCount() return 3 end
function GetPlayerByName() return nil end
function GetItemTemplate(e)
    -- 用一份"缺少的物品"黑名单模拟数据库查不到的情况
    if e == 999999 then return nil end
    return e and e > 0 and { GetName = function() return "item" .. e end } or nil
end
function GetItemLink(e) return "[" .. tostring(e) .. "]" end
function SendMail() end
local handlers = {}
function RegisterPlayerEvent(id, fn) handlers[id] = fn end

-- 离线自检：有快照按真实数据库内容回答查询，没有快照就模拟数据库不可用（走兜底路径）。
local function emptyQuery(rows)
    local q = { rows = rows or {}, index = 0 }
    function q:GetRow() return self.rows[self.index + 1] end
    function q:NextRow() if self.index + 1 >= #self.rows then return false end self.index = self.index + 1 return true end
    return q
end

local snapshotTables = nil
if snapshot ~= nil then
    snapshotTables = {
        trivia_reward_settings = (snapshot.settings ~= nil) and { snapshot.settings } or {},
        trivia_reward_questions = snapshot.questions or {},
        trivia_reward_presets = snapshot.presets or {},
        trivia_reward_winners = {},
    }
end

function CharDBExecute() return true end
function CharDBQuery(sql)
    if snapshotTables == nil then
        return nil
    end
    if sql:find("information_schema", 1, true) then
        return emptyQuery({ { c = 4 } })
    end
    local tableName = sql:match("FROM `[^`]+`%.`([^`]+)`")
    if tableName == nil then
        return emptyQuery({ { c = 0 } })
    end
    local rows = snapshotTables[tableName] or {}
    if sql:upper():find("COUNT(*)", 1, true) then
        return emptyQuery({ { c = #rows } })
    end
    if sql:find("WHERE `id` = 1", 1, true) then
        local filtered = {}
        for i = 1, #rows do
            if tonumber(rows[i].id) == 1 then filtered[#filtered + 1] = rows[i] end
        end
        return emptyQuery(filtered)
    end
    if sql:find("WHERE `enabled` = 1", 1, true) then
        local filtered = {}
        for i = 1, #rows do
            if tonumber(rows[i].enabled or 1) == 1 then filtered[#filtered + 1] = rows[i] end
        end
        return emptyQuery(filtered)
    end
    return emptyQuery(rows)
end

-- 第一个 tick（脚本把建表/种子导入放在这里，保证所有脚本都已加载）

assert(loadfile(SCRIPT))()
if CONF ~= nil then
    local confChunk = loadfile(CONF)
    if confChunk ~= nil then
        confChunk()
    else
        print("(提示) 找不到 " .. CONF .. " —— TriviaReward_conf.lua 已退休，忽略该参数")
    end
end
handlers[42](42, nil, "trivia status", { SendSysMessage = function() end })

local TR = TriviaReward
local bank = TR.ActiveQuestions or {}

print("================ 解析结果 ================")
print(string.format("题目总数 : %d（内置 %d + 自定义 %d）", #bank, TR.builtinCount or 0, TR.customCount or 0))
print(string.format("选项标号 : %s   排版: %s", table.concat(TR.Config.optionLabels, "/"), TR.Config.optionFormat))
print(string.format("作答来源 : 说话=%s 喊话=%s 表情=%s 悄悄话=%s 频道=%s",
    tostring(TR.Config.answerSay), tostring(TR.Config.answerYell), tostring(TR.Config.answerEmote),
    tostring(TR.Config.answerWhisper), (function()
        local ids = TR.AnswerChannelIds or {}
        if #ids == 0 then return "（未开启）" end
        local out = {}
        for i = 1, #ids do out[#out + 1] = tostring(ids[i]) end
        return table.concat(out, ",")
    end)()))
print(string.format("奖励模式 : %s   默认预设: %s", TR.Config.rewardMode, tostring(TR.Config.defaultRewardPreset)))
print(string.format("奖励预设 : %d 个", (function() local n = 0 for _ in pairs(TR.RewardPresets) do n = n + 1 end return n end)()))
print(string.format("数据来源 : %s", snapshot ~= nil
    and ("数据库快照 " .. tostring(#snapshot.questions) .. " 条（含停用）")
    or "模拟数据库不可用 → 校验内置题库 + 文件配置这条兜底路径"))

print("---------------- 带自定义标号的题目 ----------------")
local n = 0
for i = 1, #bank do
    if bank[i].labels ~= nil then
        n = n + 1
        print(string.format("%d. %s", i, bank[i].text))
        print(string.format("   标号 = %s   正确答案 = %s", table.concat(bank[i].labels, "/"), tostring(bank[i].options[bank[i].correct])))
    end
end
if n == 0 then print("（无）") end

print("---------------- 自定义题库（前 10 题）----------------")
local function rewardText(r)
    if r == nil then return "默认预设（" .. tostring(TR.Config.defaultRewardPreset) .. "）" end
    if type(r) == "string" then return "预设 " .. r end
    if type(r) == "number" then return "金钱 " .. tostring(r) .. " 铜" end
    if type(r) == "table" then
        local parts = {}
        if type(r.items) == "table" then
            for i = 1, #r.items do
                local it = r.items[i]
                if type(it) == "number" then
                    parts[#parts + 1] = tostring(it) .. " x1"
                elseif type(it) == "table" then
                    parts[#parts + 1] = tostring(it.entry or it[1]) .. " x" .. tostring(it.count or it[2] or 1)
                end
            end
        end
        if (tonumber(r.money) or 0) > 0 then parts[#parts + 1] = tostring(r.money) .. " 铜" end
        return table.concat(parts, " + ")
    end
    return tostring(r)
end

local shown = 0
for i = 1, #bank do
    if not bank[i].builtin then
        shown = shown + 1
        if shown <= 10 then
            print(string.format("%d. %s", i, bank[i].text))
            print(string.format("   选项 = %s", table.concat(bank[i].options, " | ")))
            print(string.format("   答案 = %s（下标 %d）  奖励 = %s",
                tostring(bank[i].options[bank[i].correct]), bank[i].correct, rewardText(bank[i].reward)))
        end
    end
end
if shown == 0 then print("（无）") end

print("---------------- 错误 / 警告 ----------------")
if #errors == 0 then
    print("（无）")
else
    for i = 1, #errors do print("  " .. errors[i]) end
end
print("=========================================")

if #errors > 0 then os.exit(2) end
