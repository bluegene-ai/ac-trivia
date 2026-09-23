-- 测试脚手架：用假的 ALE API 模拟 worldserver，验证 TriviaReward.lua + TriviaReward_conf.lua
-- 运行: lua.exe test_trivia.lua <脚本路径> <配置路径> [conf-first]

local SCRIPT = arg[1] or "E:/Server/lua/TriviaReward.lua"
local CONF   = arg[2] or "E:/Server/lua/TriviaReward_conf.lua"
local ORDER  = arg[3] or "script-first"
local SCRIPT_DIR = (arg[0] or ""):match("^(.*)[/\\]") or "."

local fakeTime = 1000000
os.time = function() return fakeTime end
math.randomseed(20260924)

-- ---------------------------------------------------------------- 假的 ALE 运行时
local world = {}
local mail = {}
local tickFn = nil
local handlers = {}
local tickerId = 0
local logs = {}
local players = {}

function PrintInfo(...) logs[#logs + 1] = "INFO " .. table.concat({...}, " ") end
function PrintError(...) logs[#logs + 1] = "ERROR " .. table.concat({...}, " ") end
function PrintDebug(...) logs[#logs + 1] = "DEBUG " .. table.concat({...}, " ") end

function SendWorldMessage(msg) world[#world + 1] = msg end
function CreateLuaEvent(fn, delay, repeats) tickFn = fn; tickerId = tickerId + 1; return tickerId end
function RemoveEventById(id) end
function GetPlayerCount() return 3 end
function GetPlayerByName(name) return players[name] end
function GetItemTemplate(entry)
    if entry == 999999 then return nil end
    if entry and entry > 0 then return { GetName = function() return "item" .. entry end } end
    return nil
end
function GetItemLink(entry, locale) return "|cff0070dd|Hitem:" .. tostring(entry) .. "|h[物品" .. tostring(entry) .. "]|h|r" end
function SendMail(...) mail[#mail + 1] = { ... } end
function RegisterPlayerEvent(id, fn) handlers[id] = fn end

-- ---------------------------------------------------------------- 假的 ALE 数据库
-- 用一个极简的"表名 → 行数组"存储模拟 ac_eluna，验证脚本的建表/读配置/读题库/写排行逻辑
local db = {
    tables = {},      -- name -> { {col=value}, ... }
    executed = {},    -- 记录执行过的 SQL（建表、INSERT/REPLACE/UPSERT）
    failQueries = false,
}

local function dbTable(name)
    if db.tables[name] == nil then db.tables[name] = {} end
    return db.tables[name]
end

local function newQuery(rows)
    local q = { rows = rows or {}, index = 0 }
    function q:GetRow()
        local row = self.rows[self.index + 1]
        return row
    end
    function q:NextRow()
        if self.index + 1 >= #self.rows then return false end
        self.index = self.index + 1
        return true
    end
    function q:GetUInt32(col) local r = self.rows[self.index + 1] or {}; return r[col] or 0 end
    function q:GetString(col) local r = self.rows[self.index + 1] or {}; return tostring(r[col] or "") end
    return q
end

-- 极简 SQL 写入解析：把 INSERT 真正落到内存表里，这样"首次导入种子题库 → 再读库"的链路可测
local function splitSqlList(text)
    local out, buf, inQuote = {}, {}, false
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if inQuote then
            if c == "'" then
                if text:sub(i + 1, i + 1) == "'" then
                    buf[#buf + 1] = "'"
                    i = i + 1
                else
                    inQuote = false
                end
            else
                buf[#buf + 1] = c
            end
        else
            if c == "'" then
                inQuote = true
            elseif c == "," then
                out[#out + 1] = table.concat(buf)
                buf = {}
            else
                buf[#buf + 1] = c
            end
        end
        i = i + 1
    end
    out[#out + 1] = table.concat(buf)
    return out
end

local function applyWrite(sql)
    if sql:match("^%s*INSERT") == nil then
        return
    end

    local tableName, colList, valList = sql:match("INTO%s+`[^`]+`%.`([^`]+)`%s*%((.-)%)%s*VALUES%s*%((.-)%)%s*;?%s*$")
    if tableName == nil then
        return
    end

    local cols = {}
    for c in colList:gmatch("`([^`]+)`") do
        cols[#cols + 1] = c
    end

    local vals = splitSqlList(valList)
    local row = {}
    for i = 1, #cols do
        local raw = (vals[i] or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if raw:match("^-?%d+$") then
            row[cols[i]] = tonumber(raw)
        else
            row[cols[i]] = raw
        end
    end

    local rows = dbTable(tableName)

    if tableName == "trivia_reward_winners" then
        for i = 1, #rows do
            if rows[i].guid == row.guid then
                rows[i].wins = (tonumber(rows[i].wins) or 0) + (tonumber(row.wins) or 1)
                rows[i].total_money = (tonumber(rows[i].total_money) or 0) + (tonumber(row.total_money) or 0)
                rows[i].last_win_at = row.last_win_at
                rows[i].last_question = row.last_question
                return
            end
        end
    end

    if tableName == "trivia_reward_questions" and row.id == nil then
        row.id = #rows + 1
    end

    rows[#rows + 1] = row
end

function CharDBExecute(sql)
    db.executed[#db.executed + 1] = sql
    applyWrite(sql)
    return true
end

function CharDBQuery(sql)
    if db.failQueries then return nil end
    db.executed[#db.executed + 1] = sql

    -- CREATE / ALTER：只记录（表由种子 INSERT 填充）
    if sql:match("^%s*CREATE") or sql:match("^%s*ALTER") then
        return newQuery({ { c = 0 } })
    end
    if sql:match("^%s*INSERT") or sql:match("^%s*REPLACE") then
        applyWrite(sql)
        return newQuery({ { c = 0 } })
    end

    -- information_schema 探测：四张表都在
    if sql:find("information_schema", 1, true) then
        return newQuery({ { c = 4 } })
    end

    local tableName = sql:match("FROM `[^`]+`%.`([^`]+)`") or sql:match("FROM%s+`([^`]+)`")
    if tableName == nil then
        return newQuery({})
    end

    local rows = dbTable(tableName)
    -- COUNT(*) 永远有一行，真实 MySQL 行为要模拟对，否则"表为空 → 写默认值"的分支测不到
    if sql:upper():find("COUNT(*)", 1, true) then
        return newQuery({ { c = #rows } })
    end

    -- WHERE id = 1 / WHERE enabled = 1 之类的简单过滤
    if sql:find("WHERE `id` = 1", 1, true) then
        local filtered = {}
        for i = 1, #rows do
            if tonumber(rows[i].id) == 1 then filtered[#filtered + 1] = rows[i] end
        end
        return newQuery(filtered)
    end
    if sql:find("WHERE `enabled` = 1", 1, true) then
        local filtered = {}
        for i = 1, #rows do
            if tonumber(rows[i].enabled or 1) == 1 then filtered[#filtered + 1] = rows[i] end
        end
        return newQuery(filtered)
    end

    return newQuery(rows)
end

local EV_LOGIN, EV_CHAT, EV_WHISPER, EV_CHANNEL, EV_COMMAND = 3, 18, 19, 22, 42
local CHAT_SAY, CHAT_YELL, CHAT_EMOTE = 1, 6, 10

local function makePlayer(name, guid, level, gmRank, gmTag)
    local p = {
        GetName = function() return name end,
        GetGUIDLow = function() return guid end,
        GetLevel = function() return level or 80 end,
        GetGMRank = function() return gmRank or 0 end,
        IsGM = function() return gmTag or false end,
        SendBroadcastMessage = function(self, msg)
            self.msgs = (self.msgs or 0) + 1
            self.lastMsg = msg
        end,
    }
    players[name] = p
    return p
end

local function makeHandler()
    local h = { sent = {} }
    function h:SendSysMessage(msg) self.sent[#self.sent + 1] = msg end
    return h
end

-- ---------------------------------------------------------------- 载入脚本
local globalsBefore = {}
for k in pairs(_G) do globalsBefore[k] = true end

local function runFile(path)
    local chunk = assert(loadfile(path))
    chunk()
end

if ORDER == "conf-first" then
    runFile(CONF)
    runFile(SCRIPT)
else
    runFile(SCRIPT)
    runFile(CONF)
end

local TR = TriviaReward
assert(TR, "TriviaReward 全局表不存在")

local leaked = {}
for k in pairs(_G) do
    if not globalsBefore[k] then leaked[#leaked + 1] = k end
end

local pass, fail = 0, 0
local function check(cond, label, extra)
    if cond then
        pass = pass + 1
        print("  PASS  " .. label)
    else
        fail = fail + 1
        print("  FAIL  " .. label .. (extra and ("  -> " .. tostring(extra)) or ""))
    end
end

local function clearWorld() world = {} end
local function clearMail() mail = {} end
local function tick() tickFn(1, 1000, 0) end
local function cmd(text, player)
    local h = makeHandler()
    handlers[EV_COMMAND](EV_COMMAND, player, text, h)
    return h
end
local function bank() return TR.ActiveQuestions or {} end
local function logHas(needle)
    for i = 1, #logs do
        if logs[i]:find(needle, 1, true) then return true end
    end
    return false
end

print("== [" .. ORDER .. "] 1. 加载 / 全局命名 ==")
check(#leaked == 1 and leaked[1] == "TriviaReward",
    "只新增 1 个全局名 TriviaReward（实际: " .. table.concat(leaked, ",") .. "）")
check(type(handlers[EV_CHAT]) == "function" and type(handlers[EV_WHISPER]) == "function"
    and type(handlers[EV_CHANNEL]) == "function" and type(handlers[EV_COMMAND]) == "function"
    and type(handlers[EV_LOGIN]) == "function", "5 个事件回调都已注册")
check(type(tickFn) == "function", "定时器已创建")

print("== 2. 配置生效（" .. ORDER .. "）==")
check(TR.Config.intervalSeconds == 900, "conf: intervalSeconds = 900", TR.Config.intervalSeconds)
check(TR.Config.answerSeconds == 60, "conf: answerSeconds = 60")
check(TR.Config.answerSay == true and TR.Config.answerEmote == false, "conf: 说话开 / 表情关")
check(TR.RewardPresets.gold20 ~= nil and TR.RewardPresets.gold20.money == 200000, "conf: 自定义奖励预设 gold20")
check(TR.RewardPresets.cloth5 ~= nil and TR.RewardPresets.cloth5.items[1][1] == 33470, "conf: 内置预设 cloth5 仍在")
check(#TR.Questions == 0, "conf 不再存放题目数据（题库在数据库里）", #TR.Questions)

print("== 3. 加载时自动建表 + 首次导入种子题库 ==")
-- 脚本把建表/种子导入放到第一个 tick 里做（保证 TriviaReward_conf.lua 已加载），
-- 所以这里先跑一次 tick 再断言。
tick()
check(logHas("初始化") or #db.tables.trivia_reward_settings == 1, "启动后写入了默认设置行")
check(db.executed[1] ~= nil and db.executed[1]:find("information_schema", 1, true) ~= nil,
    "启动时先探测库是否存在（存在就不再执行 CREATE DATABASE）")
local createCount = 0
for i = 1, #db.executed do
    if db.executed[i]:find("CREATE TABLE IF NOT EXISTS", 1, true) then createCount = createCount + 1 end
end
check(createCount >= 4, "建了 4 张表（实际 " .. createCount .. "）", createCount)
check(#db.tables.trivia_reward_questions == 37, "首次把内置 37 题导入题库表（实际 " .. #db.tables.trivia_reward_questions .. "）")
check(#db.tables.trivia_reward_presets >= 9, "首次把奖励预设写入预设表（实际 " .. #db.tables.trivia_reward_presets .. "）")
check(#db.tables.trivia_reward_settings == 1, "首次写入 1 行默认设置")
local seededRow = db.tables.trivia_reward_questions[1]
check(seededRow ~= nil and seededRow.source == "seed", "种子题目标记为 source=seed", tostring(seededRow and seededRow.source))
check(seededRow ~= nil and tonumber(seededRow.answer_index) >= 1, "种子题目带上了正确答案下标")
local sortOrders = {}
for i = 1, #db.tables.trivia_reward_questions do
    sortOrders[tonumber(db.tables.trivia_reward_questions[i].sort_order) or 0] = true
end
check(sortOrders[1] and sortOrders[2] and sortOrders[#db.tables.trivia_reward_questions],
    "种子题目的 sort_order 是 1..N（不是全都 1）")
check(db.tables.trivia_reward_settings[1].answer_channel_ids == "综合",
    "默认设置写的是 conf 里的值（而不是脚本默认值）：answer_channel_ids=综合",
    tostring(db.tables.trivia_reward_settings[1].answer_channel_ids))

print("== 4. 题库以数据库为准（面板/模板写库 → 脚本读库）==")
local h0 = cmd("trivia status")
check(#h0.sent == 1, "status 指令有回复")
check(TR.dbCount == 37, "题库来自数据库：37 题", TR.dbCount)
check(TR.builtinCount == 0 and TR.customCount == 0, "数据库可用时不再叠加内置/文件题库",
    "builtin=" .. tostring(TR.builtinCount) .. " custom=" .. tostring(TR.customCount))

-- 模拟面板/模板导入：直接往题库表里写题
table.insert(db.tables.trivia_reward_questions, {
    id = 900, question = "测试：字母表选项", option1 = "一", option2 = "二", option3 = "三", option4 = "四",
    answer_index = 3, labels = "", reward_preset = "", reward_items = "", reward_money = 0, enabled = 1, sort_order = 1,
})
table.insert(db.tables.trivia_reward_questions, {
    id = 901, question = "测试：纯金钱奖励", option1 = "甲", option2 = "乙", option3 = "丙", option4 = "丁",
    answer_index = 4, labels = "", reward_preset = "", reward_items = "", reward_money = 12345, enabled = 1, sort_order = 2,
})
table.insert(db.tables.trivia_reward_questions, {
    id = 902, question = "测试：答案下标越界", option1 = "甲", option2 = "乙", option3 = "", option4 = "",
    answer_index = 9, labels = "", reward_preset = "", reward_items = "", reward_money = 0, enabled = 1, sort_order = 3,
})
table.insert(db.tables.trivia_reward_questions, {
    id = 903, question = "测试：停用的题不进题库", option1 = "甲", option2 = "乙", option3 = "", option4 = "",
    answer_index = 1, labels = "", reward_preset = "", reward_items = "", reward_money = 0, enabled = 0, sort_order = 4,
})

logs = {}
cmd("trivia reload")
local b = bank()
check(#b == 39, "题库 = 37 + 2 道有效题（越界题被跳过、停用题被过滤）：实际 " .. #b)
check(logHas("correct 必须是"), "答案下标越界的题目被跳过并写日志")

local letterQ, moneyQ
for i = 1, #b do
    if b[i].text == "测试：字母表选项" then letterQ = b[i] end
    if b[i].text == "测试：纯金钱奖励" then moneyQ = b[i] end
end
check(letterQ ~= nil and letterQ.correct == 3, "A/B/C/D 表格式选项 → 答案文本解析为下标 3")
check(moneyQ ~= nil and type(moneyQ.reward) == "table" and moneyQ.reward.money == 12345,
    "reward_money 经数据库来回后仍是纯金钱奖励", moneyQ and type(moneyQ.reward) == "table" and moneyQ.reward.money or "nil")

print("== 4. 答案匹配规则 ==")
local function startQ()
    cmd("trivia start")
end
local function answerOf(q) return string.char(string.byte("a") + q.correct - 1) end

startQ()
local q1 = TR.round.question
check(TR.round.active == true, "题目已开始")
local p1 = makePlayer("玩家甲", 101)
clearMail()
handlers[EV_CHAT](EV_CHAT, p1, "z", CHAT_SAY, 0)
check(#mail == 0, "无关内容不触发")
handlers[EV_CHAT](EV_CHAT, p1, "  " .. answerOf(q1) .. "、", CHAT_SAY, 0)
check(#mail == 1, "带空格/顿号的大写答案可识别")
check(TR.round.active == false, "答对后本题结束")

print("== 5. 发言频道过滤（说话 / 喊话 / 表情）==")
startQ()
local q2 = TR.round.question
local p2 = makePlayer("玩家乙", 202)
clearMail()
handlers[EV_CHAT](EV_CHAT, p2, answerOf(q2), CHAT_EMOTE, 0)
check(#mail == 0, "表情（answerEmote=false）不作答")
handlers[EV_CHAT](EV_CHAT, p2, answerOf(q2), CHAT_YELL, 0)
check(#mail == 1, "喊话（answerYell=true）可作答")

print("== 6. 频道作答（conf: answerChannelIds = { 综合 }）==")
startQ()
local q3 = TR.round.question
local p3 = makePlayer("玩家丙", 303)
clearMail()
handlers[EV_CHANNEL](EV_CHANNEL, p3, answerOf(q3), 17, 0, 2)   -- 2 = 交易，未开启
check(#mail == 0, "未开启的频道（交易=2）不作答")
handlers[EV_CHANNEL](EV_CHANNEL, p3, answerOf(q3), 17, 0, 1)   -- 1 = 综合，已开启
check(#mail == 1, "已开启的频道（综合=1）可作答")
check(TR.AnswerChannelIds ~= nil and TR.AnswerChannelIds[1] == 1, "频道名「综合」解析为 ID 1")

print("== 7. 频道扫描 ==")
local gm = makePlayer("GM甲", 404, 80, 3, false)
local hs = cmd("trivia chanscan 60", gm)
check(#hs.sent == 1 and hs.sent[1]:find("频道扫描已开始", 1, true) ~= nil, "chanscan 已开始")
clearWorld()
handlers[EV_CHANNEL](EV_CHANNEL, p3, "随便说句话", 17, 0, 1)
check(gm.msgs ~= nil and gm.msgs >= 1 and gm.lastMsg:find("频道ID=1", 1, true) ~= nil,
    "扫描结果私聊给发起者: " .. tostring(gm.lastMsg))
check(logHas("频道扫描"), "扫描结果写入 ALE 日志")
cmd("trivia chanlist", gm)
check(true, "chanlist 可执行")

print("== 8. 悄悄话（默认关闭）==")
TR.Config.answerWhisper = false
startQ()
local q4 = TR.round.question
local p4 = makePlayer("玩家丁", 505)
clearMail()
handlers[EV_WHISPER](EV_WHISPER, p4, answerOf(q4), 7, 0, p1)
check(#mail == 0, "answerWhisper=false 时悄悄话不作答")
TR.Config.answerWhisper = true
handlers[EV_WHISPER](EV_WHISPER, p4, answerOf(q4), 7, 0, p1)
check(#mail == 1, "开启后悄悄话可作答")
TR.Config.answerWhisper = false

print("== 9. 奖励：预设 / 数字 / 内联 物品写法 ==")
TR.paused = true
-- 预设
cmd("trivia start 2")
local qp = TR.round.question
local pr = makePlayer("奖励甲", 606)
clearMail()
handlers[EV_CHAT](EV_CHAT, pr, answerOf(qp), CHAT_SAY, 0)
check(#mail == 1 and mail[1][9] == 33470 and mail[1][10] == 5, "预设奖励 cloth5 → 33470 x5")

-- 纯金钱（reward = 12345）
local moneyIndex
for i = 1, #bank() do
    if bank()[i].text == "测试：纯金钱奖励" then moneyIndex = i end
end
cmd("trivia start " .. moneyIndex)
local qm = TR.round.question
clearMail()
handlers[EV_CHAT](EV_CHAT, pr, answerOf(qm), CHAT_SAY, 0)
check(#mail == 1 and mail[1][7] == 12345 and #mail[1] == 8, "reward = 数字 → 只发金钱（铜），无物品参数")

-- 内联物品表
TR.Config.rewardMode = "pool"
TR.Config.poolPresets = { "combo" }
cmd("trivia start")
local qc = TR.round.question
clearMail()
handlers[EV_CHAT](EV_CHAT, pr, answerOf(qc), CHAT_SAY, 0)
check(#mail == 1 and mail[1][7] == 50000 and mail[1][9] == 33470 and mail[1][11] == 33447,
    "内联奖励 combo → 两件物品 + 金钱")
TR.Config.rewardMode = "question"

-- 不存在的物品被跳过
TR.Config.poolPresets = { "combo" }
TR.Config.rewardMode = "pool"
TR.RewardPresets.baditem = { items = { { 999999, 3 }, { 33470, 1 } } }
TR.Config.poolPresets = { "baditem" }
cmd("trivia start")
local qb2 = TR.round.question
clearMail()
logs = {}
handlers[EV_CHAT](EV_CHAT, pr, answerOf(qb2), CHAT_SAY, 0)
check(logHas("奖励物品 999999 不存在"), "不存在的物品 ID 被跳过并写日志")
check(#mail == 1 and mail[1][9] == 33470 and #mail[1] == 10, "跳过坏物品后仍发出剩余物品")
TR.Config.rewardMode = "question"
TR.Config.poolPresets = { "cloth5", "cloth10", "heal5", "mana5", "ore5", "gold5", "gold10", "gold20", "combo" }

print("== 10. 作答次数 / 闲聊不消耗 ==")
TR.Config.attemptsPerPlayer = 1
cmd("trivia start")
local q5 = TR.round.question
local pa = makePlayer("次数甲", 707)
local wrong5 = (q5.correct == 1) and "c" or "a"
clearMail()
handlers[EV_CHAT](EV_CHAT, pa, "哈哈哈哈", CHAT_SAY, 0)
handlers[EV_CHAT](EV_CHAT, pa, wrong5, CHAT_SAY, 0)   -- 明确的错误答案
local afterWrong = #mail
handlers[EV_CHAT](EV_CHAT, pa, answerOf(q5), CHAT_SAY, 0)
check(#mail == afterWrong, "机会用完后即使答对也不能中奖")
check(TR.round.active == true, "本题仍在等待其他玩家")

print("== 11. 超时 / 提醒 ==")
TR.Config.remindEverySeconds = 30
cmd("trivia start")
check(TR.round.active == true, "新一题开始")
clearWorld()
fakeTime = fakeTime + 31
tick()
check(#world == 4, "提醒重发 4 行（实际 " .. #world .. "）")
check(world[4] ~= nil and world[4]:find("剩余", 1, true) ~= nil, "提醒行显示剩余时间: " .. tostring(world[4]))
fakeTime = TR.round.deadlineAt + 1
clearWorld()
tick()
check(TR.round.active == false and world[1]:find("无人答对", 1, true) ~= nil, "超时公布答案")

print("== 12. 登录补发 ==")
cmd("trivia start")
local late = makePlayer("迟到玩家", 808)
handlers[EV_LOGIN](EV_LOGIN, late)
check(late.msgs == 4, "登录补发 4 行题目")

print("== 13. 作答提示自动生成 ==")
local hint = nil
for i = 1, #world do
    local m = world[i]:match("中输入 A / B / C / D")
    if m then hint = world[i] end
end
check(hint ~= nil, "播报里包含自动生成的作答提示")
check(hint ~= nil and hint:find("普通说话", 1, true) ~= nil and hint:find("综合频道", 1, true) ~= nil,
    "提示里列出了 说话 与 综合频道")
TR.Config.answerHint = "自定义提示"
cmd("trivia stop")
cmd("trivia start")
check(world[#world]:find("自定义提示", 1, true) ~= nil, "answerHint 自定义后以自定义为准")
TR.Config.answerHint = ""

print("== 14. 开启 / 关闭（运行时）==")
cmd("trivia disable")
check(TR.Config.enabled == false, ".trivia disable 生效")
local beforeCount = TR.roundCounter
TR.nextRoundAt = fakeTime
tick()
check(TR.roundCounter == beforeCount, "关闭后不再自动出题")
cmd("trivia enable")
check(TR.Config.enabled == true, ".trivia enable 生效")
TR.nextRoundAt = fakeTime
tick()
check(TR.roundCounter > beforeCount, "开启后恢复自动出题")
cmd("trivia pause")
TR.nextRoundAt = fakeTime
local pausedCount = TR.roundCounter
fakeTime = fakeTime + 1
tick()
check(TR.roundCounter == pausedCount, ".trivia pause 后不出新题")
cmd("trivia resume")
cmd("trivia stop")

print("== 14b. 恢复自动出题：无条件把下一题提前 ==")
-- 曾经的 bug：finishRound 把下一题排到 now+intervalSeconds（默认 900 秒），而 resume 只在
-- nextRoundAt 已过期时才提前，于是"暂停 → 恢复"之后还要干等 15 分钟，看起来就是恢复无效。
TR.Config.scheduleEnabled = false
TR.Config.scheduleWindows = ""
TR.Config.intervalSeconds = 900
TR.Config.resumeDelaySeconds = 5
TR.paused = false
TR.Config.enabled = true

cmd("trivia start")
cmd("trivia stop")
check(TR.nextRoundAt > fakeTime + 800,
    "结束当前题后，下一题按出题间隔排期（" .. tostring(TR.nextRoundAt - fakeTime) .. " 秒后）")
local roundsBeforeResume = TR.roundCounter
fakeTime = fakeTime + 1
tick()
check(TR.roundCounter == roundsBeforeResume, "间隔没到不会自动出下一题")

check(cmd("trivia pause").sent[1]:find("已暂停自动出题", 1, true) ~= nil, ".trivia pause 回复明确")
check(cmd("trivia pause").sent[1]:find("已经是暂停状态", 1, true) ~= nil, "重复暂停给出「已经是暂停」的提示")
fakeTime = fakeTime + 1
tick()
check(TR.roundCounter == roundsBeforeResume, "暂停期间不出新题")

local resumeReply = cmd("trivia resume")
check(TR.paused == false, ".trivia resume 清掉暂停标记")
check(resumeReply.sent[1]:find("恢复自动出题", 1, true) ~= nil, ".trivia resume 回复明确")
check(TR.nextRoundAt <= fakeTime + 5, "恢复后下一题被提前到 " .. tostring(TR.nextRoundAt - fakeTime) .. " 秒后")
fakeTime = fakeTime + 6
tick()
check(TR.roundCounter == roundsBeforeResume + 1, "恢复后自动出下一题（不再等满 intervalSeconds）")
check(TR.round.active == true, "恢复后的新题已经在进行中")
cmd("trivia stop")

print("== 14c. 定时启停计划 ==")
-- 造一个"指定本地时刻"的时间戳（os.time 被测试替换了，所以自己扫）
local function tsAt(wday, hh, mm)
    -- wday: 0=周日 … 6=周六；nil = 不看星期
    local base = fakeTime - (fakeTime % 60)
    for i = 0, 9 * 24 * 60 do
        local cand = base + i * 60
        local d = os.date("*t", cand)
        if d.hour == hh and d.min == mm and (wday == nil or tonumber(os.date("%w", cand)) == wday) then
            return cand
        end
    end
    return nil
end

-- 新列已经写进默认设置行
local seededSettings = db.tables.trivia_reward_settings[1]
check(seededSettings.schedule_enabled ~= nil and tonumber(seededSettings.schedule_enabled) == 0,
    "默认设置行带 schedule_enabled=0")
check(seededSettings.schedule_windows ~= nil and seededSettings.schedule_windows == "",
    "默认设置行带 schedule_windows=''")

TR.Config.scheduleEnabled = true
TR.Config.scheduleWindows = "08:00-09:00"
local inMorning = tsAt(nil, 8, 30)
local beforeMorning = tsAt(nil, 7, 30)
check(inMorning ~= nil and beforeMorning ~= nil, "测试环境能构造出指定时刻的时间戳")

-- 时间段外：即使库/配置里开关是开的，也会被计划关掉
fakeTime = beforeMorning
TR.Config.enabled = true
TR.paused = false
TR.scheduleActive = nil
clearWorld()
tick()
check(TR.Config.enabled == false, "不在时间段内 → 计划自动关闭系统")
check(TR.round.active == false, "关闭时不会留着一道没结束的题")

-- 进入时间段：自动开启 + 到点出题
cmd("trivia stop")
fakeTime = inMorning
clearWorld()
logs = {}
tick()
check(TR.Config.enabled == true, "进入时间段 → 计划自动开启系统")
check(TR.scheduleInfo ~= nil and TR.scheduleInfo.active == true, "计划状态标记为进行中")
local opened = false
for i = 1, #world do
    if world[i]:find("已按定时计划开启", 1, true) then opened = true end
end
check(opened, "开启时向全服播报了一次")
fakeTime = fakeTime + 6
tick()
check(TR.round.active == true, "计划开启后自动出题")
check(logHas("定时计划"), "计划动作写入 ALE 日志")

-- 到点结束：结束当前题 + 停题
fakeTime = tsAt(nil, 9, 0)
clearWorld()
tick()
check(TR.Config.enabled == false, "离开时间段 → 计划自动关闭系统")
check(TR.round.active == false, "到点会结束正在进行的那道题")
local ended = false
for i = 1, #world do
    if world[i]:find("本次答题活动已结束", 1, true) then ended = true end
end
check(ended, "结束时有播报（含下次开启时间）")

-- 跨夜时间段
TR.Config.enabled = false
TR.Config.scheduleWindows = "22:00-02:00"
TR.scheduleActive = nil
fakeTime = tsAt(nil, 23, 0)
tick()
check(TR.Config.enabled == true, "跨夜时间段：23:00 在 22:00-02:00 之内")
fakeTime = tsAt(nil, 1, 0)
tick()
check(TR.Config.enabled == true, "跨夜时间段：次日 01:00 仍在 22:00-02:00 之内")
fakeTime = tsAt(nil, 3, 0)
tick()
check(TR.Config.enabled == false, "跨夜时间段：03:00 已在外（自动结束）")

-- 星期限制（1 = 周一）
TR.Config.enabled = false
TR.Config.scheduleWindows = "1@08:00-09:00"
TR.scheduleActive = nil
fakeTime = tsAt(1, 8, 30)
tick()
check(TR.Config.enabled == true, "周一 08:30 落在「1@08:00-09:00」内")
fakeTime = tsAt(2, 8, 30)
tick()
check(TR.Config.enabled == false, "周二 08:30 不在「1@08:00-09:00」内")

-- 多个时间段 / 逗号分隔写法
TR.Config.scheduleWindows = "08:00-09:00, 20:00-22:00"
TR.scheduleActive = nil
fakeTime = tsAt(nil, 21, 0)
tick()
check(TR.Config.enabled == true, "逗号分隔的第二段（20:00-22:00）也生效")

-- 带星期前缀 + 逗号多段（"1-5@08:00-09:00, 20:00-22:00" = 工作日两段）
TR.Config.enabled = false
TR.Config.scheduleWindows = "1-5@08:00-09:00, 20:00-22:00"
TR.scheduleActive = nil
fakeTime = tsAt(3, 21, 0)          -- 周三晚上
tick()
check(TR.Config.enabled == true, "星期前缀 + 逗号多段：周三 21:00 命中第二段")
fakeTime = tsAt(6, 21, 0)          -- 周六晚上（不在 1-5）
tick()
check(TR.Config.enabled == false, "同一段的星期限制同样作用于第二段（周六不生效）")
check(TR.scheduleInfo ~= nil and TR.scheduleInfo.active == false, "计划状态标记为不在时间段内")

-- 星期写法的规范化文本（面板归一化成 1,2,3,4,5，脚本要能读懂同一种写法）
TR.Config.enabled = false
TR.Config.scheduleWindows = "1,2,3,4,5@08:00-09:00"
TR.scheduleActive = nil
fakeTime = tsAt(4, 8, 30)
tick()
check(TR.Config.enabled == true, "面板归一化写法 1,2,3,4,5@08:00-09:00 可识别")

-- 手动开关被计划覆盖，并且提示里说明白
TR.Config.scheduleWindows = "08:00-09:00"
fakeTime = tsAt(nil, 7, 0)
tick()
check(TR.Config.enabled == false, "时间段外保持关闭")
local manualEnable = cmd("trivia enable")
check(manualEnable.sent[1]:find("定时计划", 1, true) ~= nil, ".trivia enable 会提示定时计划优先")
check(TR.Config.enabled == true, "手动 enable 当次生效")
fakeTime = fakeTime + 1
tick()
check(TR.Config.enabled == false, "下一个 tick 就被计划拉回关闭状态")

-- .trivia schedule 指令
TR.Config.scheduleEnabled = false
TR.Config.scheduleWindows = ""
TR.scheduleActive = nil
local schedCmd = cmd("trivia schedule")
check(#schedCmd.sent == 1 and schedCmd.sent[1]:find("定时启停", 1, true) ~= nil,
    ".trivia schedule 可执行并在未启用时说明")
TR.Config.scheduleEnabled = true
TR.Config.scheduleWindows = "08:00-09:00; 20:00-22:00"
local schedCmd2 = cmd("trivia schedule")
check(schedCmd2.sent[1]:find("08:00-09:00", 1, true) ~= nil and schedCmd2.sent[1]:find("20:00-22:00", 1, true) ~= nil,
    ".trivia schedule 列出全部时间段")

-- 非法写法不会把脚本弄崩，只是被跳过
TR.Config.scheduleWindows = "这不是时间段"
TR.scheduleActive = nil
local okBad = pcall(tick)
check(okBad == true, "非法时间段不会抛错")
check(TR.Config.enabled == false, "非法时间段视作没有计划（保持关闭）")

-- 日志里能看出是哪一段被跳过（运维排查用）
logs = {}
TR.Config.scheduleWindows = "08:00-09:00; 25:00-26:00"
TR.scheduleActive = nil
pcall(tick)
check(logHas("25:00-26:00"), "非法时间段会写日志指出具体是哪一段")

-- 复位，避免影响后面的用例
TR.Config.scheduleEnabled = false
TR.Config.scheduleWindows = ""
TR.scheduleActive = nil
TR.Config.enabled = true
TR.Config.intervalSeconds = 900

print("== 15. 种子开关 / 空题库 ==")
-- use_builtin_questions 现在表示"首次建库时是否导入内置种子题库"；
-- 数据库一旦有题就以数据库为准，这里模拟"题库被清空"的极端情况。
local backupQuestions = db.tables.trivia_reward_questions
local backupSeedFlag = db.tables.trivia_reward_settings[1].use_builtin_questions
db.tables.trivia_reward_questions = {}
db.tables.trivia_reward_settings[1].use_builtin_questions = 0   -- 数据库开关才是权威
TR.prepared = nil
TR.db.checked = false
logs = {}
cmd("trivia reload")
check(#db.tables.trivia_reward_questions == 0, "use_builtin_questions=0 时题库表里不会写入种子题目")
check(#bank() == 0, "题库为空（实际 " .. #bank() .. "）")
check(logHas("题库是空的"), "空题库写了明确的错误日志，而不是静默不出题")

-- 打开开关后重新导入
db.tables.trivia_reward_settings[1].use_builtin_questions = 1
TR.prepared = nil
TR.db.checked = false
cmd("trivia reload")
check(#db.tables.trivia_reward_questions == 37, "打开开关后重新导入内置 37 题")
check(#bank() == 37, "题库恢复为 37 题（实际 " .. #bank() .. "）")
db.tables.trivia_reward_questions = backupQuestions
db.tables.trivia_reward_settings[1].use_builtin_questions = backupSeedFlag

print("== 16. 权限与指令别名 ==")
local normal = makePlayer("普通玩家", 909, 80, 0, false)
local hn = cmd("trivia status", normal)
check(#hn.sent == 1 and hn.sent[1]:find("没有权限", 1, true) ~= nil, "普通玩家被拒绝")
local g2 = makePlayer("GM乙", 910, 80, 3, false)
check(#cmd(".trivia status", g2).sent == 1, "带点号 .trivia status 可识别")
check(#cmd("TRIVIA STATUS", g2).sent == 1, "大写可识别")
check(#cmd("答题 status", g2).sent == 1, "中文别名可识别")
local hother = makeHandler()
local ret = handlers[EV_COMMAND](EV_COMMAND, g2, "reload ale", hother)
check(ret == nil and #hother.sent == 0, "非本脚本指令不被拦截")

print("== 17. 题库/预设完整性 ==")
for i = 1, #bank() do
    local q = bank()[i]
    if type(q.text) ~= "string" or type(q.options) ~= "table" or #q.options < 2
        or type(q.correct) ~= "number" or q.correct < 1 or q.correct > #q.options then
        check(false, "第 " .. i .. " 题结构正确", q.text)
    end
end
check(true, "最终题库 " .. #bank() .. " 题结构全部合法")
for name, p in pairs(TR.RewardPresets) do
    local hasItem = type(p.items) == "table" and #p.items > 0
    local hasMoney = (tonumber(p.money) or 0) > 0
    check(hasItem or hasMoney, "奖励预设 " .. name .. " 有实际内容")
end

print("== 18. 回调异常被 guard 兜住 ==")
TR.paused = false
cmd("trivia start")
logs = {}
local broken = { GetName = function() return "坏对象" end }
local okCall = pcall(handlers[EV_CHAT], EV_CHAT, broken, "a", CHAT_SAY, 0)
check(okCall == true, "回调内部出错不抛给引擎")
check(logHas("回调异常"), "异常写入 ALE 错误日志")
cmd("trivia stop")

print("== 19. 选项标号（甲/乙/丙/丁）==")
local ZH = { "甲", "乙", "丙", "丁" }

-- 找出配置里那道用 ["甲"]=… 键写的题
cmd("trivia stop")
-- 模拟面板导入的一道"带中文标号"的题：labels = 甲,乙,丙,丁
table.insert(db.tables.trivia_reward_questions, {
    id = 910, question = "「奥格瑞玛」位于哪块大陆？",
    option1 = "东部王国", option2 = "卡利姆多", option3 = "诺森德", option4 = "外域",
    answer_index = 2, labels = "甲,乙,丙,丁", reward_preset = "", reward_items = "", reward_money = 0,
    enabled = 1, sort_order = 10,
})
cmd("trivia reload")
local zhQ, zhIdx = nil, nil
for i = 1, #bank() do
    if bank()[i].text == "「奥格瑞玛」位于哪块大陆？" then
        zhQ, zhIdx = bank()[i], i
    end
end
check(zhQ ~= nil, "找到带中文标号的题目（labels = 甲,乙,丙,丁）")
check(zhQ ~= nil and zhQ.labels ~= nil and zhQ.labels[1] == "甲", "该题记录了自己的标号 甲/乙/丙/丁")
check(zhQ ~= nil and zhQ.correct == 2, "answers 解析为下标 2", zhQ and zhQ.correct)

-- labels 为空的题目应该跟随全局 optionLabels
local asciiKeyed = nil
for i = 1, #bank() do
    if bank()[i].text == "测试：字母表选项" then asciiKeyed = bank()[i] end
end
check(asciiKeyed ~= nil and asciiKeyed.labels == nil, "labels 为空的题不记录自身标号（跟随全局）")

TR.paused = true
clearWorld()
cmd("trivia start " .. tostring(zhIdx))
local shown = table.concat(world, "\n")
check(shown:find("甲)", 1, true) ~= nil, "播报用题目标号显示选项：甲)")
check(world[4] ~= nil and world[4]:find("甲 / 乙 / 丙 / 丁", 1, true) ~= nil,
    "作答提示使用题目自己的标号: " .. tostring(world[4]))

local pzh = makePlayer("中文作答", 1111)
clearMail()
handlers[EV_CHAT](EV_CHAT, pzh, "乙", CHAT_SAY, 0)
check(#mail == 1, "玩家输入「乙」即算作答")

cmd("trivia start " .. tostring(zhIdx))
clearMail()
handlers[EV_CHAT](EV_CHAT, pzh, "B", CHAT_SAY, 0)
check(#mail == 1, "同一题用拉丁字母 B 也能作答（allowLatinLetters）")

cmd("trivia start " .. tostring(zhIdx))
clearMail()
handlers[EV_CHAT](EV_CHAT, pzh, "乙、", CHAT_SAY, 0)
check(#mail == 1, "「乙、」这种带标点的写法也能识别")

-- 全局把标号换成中文，普通题目也应跟着变
TR.Config.optionLabels = { "甲", "乙", "丙", "丁" }
TR.Config.optionFormat = "%s、%s"
clearWorld()
cmd("trivia start 1")
local qz = TR.round.question
local shown2 = table.concat(world, "\n")
check(shown2:find("甲、", 1, true) ~= nil, "全局 optionLabels=甲乙丙丁 后，普通题也显示「甲、」")
check(world[4] ~= nil and world[4]:find("甲 / 乙 / 丙 / 丁", 1, true) ~= nil, "提示也变成中文标号")
clearMail()
handlers[EV_CHAT](EV_CHAT, pzh, ZH[qz.correct], CHAT_SAY, 0)
check(#mail == 1, "用中文标号回答普通题可以中奖（答案=" .. ZH[qz.correct] .. "）")

-- 标号写错时退回 A/B/C/D，不影响出题
db.tables.trivia_reward_settings[1].option_labels = "只有一个"
TR.prepared = nil
TR.db.checked = false
logs = {}
cmd("trivia reload")
check(logHas("optionLabels 配置无效"), "非法 optionLabels 被拒绝并写日志")
check(type(TR.Config.optionLabels) == "table" and TR.Config.optionLabels[1] == "A", "已退回 A/B/C/D")
db.tables.trivia_reward_settings[1].option_labels = "A,B,C,D"
TR.Config.optionFormat = "%s) %s"
TR.prepared = nil
cmd("trivia status")
cmd("trivia stop")

print("== 20. 数据库（AGMP 面板）集成 ==")
-- 面板写的设置行 + 题库 + 奖励预设
db.tables.trivia_reward_settings = {
    {
        id = 1,
        enabled = 1,
        interval_seconds = 1234,
        answer_seconds = 45,
        remind_every_seconds = 15,
        first_delay_seconds = 10,
        min_players_online = 1,
        min_level = 5,
        answer_say = 1,
        answer_yell = 0,
        answer_emote = 0,
        answer_whisper = 0,
        answer_channel_ids = "1,2",
        answer_prefix = "",
        allow_number_answer = 1,
        allow_latin_letters = 1,
        allow_text_answer = 0,
        attempts_per_player = 2,
        option_labels = "甲,乙,丙,丁",
        option_format = "%s、%s",
        reward_mode = "question",
        default_reward_preset = "dbpreset",
        pool_presets = "",
        use_builtin_questions = 1,
        announce_on_login = 1,
        reply_wrong_answer = 0,
        reply_already_answered = 1,
        min_gm_rank_for_command = 2,
        sender_guid = 10667,
        mail_stationery = 41,
        item_link_locale = 4,
        mail_subject = "面板标题",
        mail_body = "面板正文 {question} / {answer}",
    },
}
db.tables.trivia_reward_presets = {
    { name = "dbpreset", items = "33470:3,33447:1", money = 25000, enabled = 1 },
}
db.tables.trivia_reward_questions = {
    { id = 1, question = "面板题一：1+1=?", option1 = "1", option2 = "2", option3 = "3", option4 = "4",
      answer_index = 2, labels = "", reward_preset = "", reward_items = "", reward_money = 0, enabled = 1, sort_order = 1 },
    { id = 2, question = "面板题二：答案在第三个", option1 = "甲甲", option2 = "乙乙", option3 = "丙丙", option4 = "丁丁",
      answer_index = 3, labels = "甲乙丙丁", reward_preset = "dbpreset", reward_items = "", reward_money = 0, enabled = 1, sort_order = 2 },
    { id = 3, question = "面板题三：停用的题不该进题库", option1 = "a", option2 = "b", option3 = "c", option4 = "d",
      answer_index = 1, labels = "", reward_preset = "", reward_items = "", reward_money = 0, enabled = 0, sort_order = 3 },
}

TR.prepared = nil
db.executed = {}
cmd("trivia reload")

check(TR.Config.intervalSeconds == 1234, "数据库覆盖 intervalSeconds = 1234", TR.Config.intervalSeconds)
check(TR.Config.minLevel == 5, "数据库覆盖 minLevel = 5", TR.Config.minLevel)
check(TR.Config.answerYell == false, "数据库覆盖 answerYell = false")
check(TR.Config.mailSubject == "面板标题", "数据库覆盖 mailSubject")
check(TR.Config.attemptsPerPlayer == 2, "数据库覆盖 attemptsPerPlayer = 2")
check(TR.Config.defaultRewardPreset == "dbpreset", "数据库覆盖默认奖励预设")
check(#TR.Config.optionLabels == 4 and TR.Config.optionLabels[1] == "甲", "数据库 option_labels 解析为 { 甲,乙,丙,丁 }")
check(TR.Config.optionFormat == "%s、%s", "数据库 option_format 生效")
check(type(TR.Config.answerChannelIds) == "table" and #TR.Config.answerChannelIds == 2, "数据库 answer_channel_ids → 2 个频道")
check(TR.AnswerChannelIds[1] == 1 and TR.AnswerChannelIds[2] == 2, "频道 ID 解析为 {1,2}")
check(TR.RewardPresets.dbpreset ~= nil and TR.RewardPresets.dbpreset.money == 25000, "数据库奖励预设已载入")
check(TR.RewardPresets.dbpreset.items[1][1] == 33470 and TR.RewardPresets.dbpreset.items[1][2] == 3, "预设物品 '33470:3' 解析正确")
check(TR.dbCount == 2, "数据库题库 2 道（停用的第 3 道被过滤）", TR.dbCount)
check(#bank() == 2, "题库 = 数据库里的 2 题（数据库是权威来源，不再叠加内置/文件）：实际 " .. #bank())

-- 数据库题库的题目本身
local dbQ1, dbQ2
for i = 1, #bank() do
    if bank()[i].dbId == 1 then dbQ1 = bank()[i] end
    if bank()[i].dbId == 2 then dbQ2 = bank()[i] end
end
check(dbQ1 ~= nil and dbQ1.correct == 2 and dbQ1.options[2] == "2", "数据库题目选项/答案解析正确")
check(dbQ2 ~= nil and dbQ2.labels ~= nil and dbQ2.labels[1] == "甲", "数据库题目的自定义标号生效")
check(dbQ2 ~= nil and dbQ2.reward == "dbpreset", "数据库题目的奖励预设生效")

-- 面板题能被抽到、能作答、能发奖
TR.paused = true
local dbIndex
for i = 1, #bank() do
    if bank()[i].dbId == 1 then dbIndex = i end
end
clearWorld()
clearMail()
cmd("trivia start " .. tostring(dbIndex))
check(TR.round.active == true and TR.round.question.dbId == 1, "可以按题库下标抽到数据库题目")
local zhP = makePlayer("中文标号玩家", 2222)
handlers[EV_CHAT](EV_CHAT, zhP, "乙", CHAT_SAY, 0)
check(#mail == 1, "用「乙」作答数据库题目成功")
check(mail[1][1] == "面板标题", "邮件标题来自数据库设置: " .. tostring(mail[1][1]))
check(mail[1][9] == 33470 and mail[1][10] == 3 and mail[1][11] == 33447 and mail[1][7] == 25000,
    "邮件物品/金钱来自数据库奖励预设")

-- 答对排行写库
local winnerSql = nil
for i = 1, #db.executed do
    if db.executed[i]:find("trivia_reward_winners", 1, true) then winnerSql = db.executed[i] end
end
check(winnerSql ~= nil, "答对后写入 trivia_reward_winners")
check(winnerSql ~= nil and winnerSql:find("ON DUPLICATE KEY UPDATE", 1, true) ~= nil, "排行写入用 UPSERT（可累加）")
check(winnerSql ~= nil and winnerSql:find("2222", 1, true) ~= nil, "排行写入带上了获胜者 GUID")

-- .trivia api 的 JSON（SOAP/控制台调用会带 [AGMP_OK] 标记，面板解析时会剥掉）
cmd("trivia start")
local hApi = cmd("trivia api")
check(#hApi.sent == 1, ".trivia api 有输出")
local raw = hApi.sent[1] or ""
local payload = raw:gsub("^%[AGMP_OK%]%s*", "")
check(raw:find("[AGMP_OK]", 1, true) == 1, "控制台/SOAP 调用带 [AGMP_OK] 标记")
check(payload:sub(1, 1) == "{" and payload:sub(-1) == "}", "JSON 首尾完整")
check(payload:find('"state":"running"', 1, true) ~= nil, "JSON state=running（当前有题进行中）")
check(payload:find('"interval":1234', 1, true) ~= nil, "JSON interval 来自数据库")
check(payload:find('"from_db":2', 1, true) ~= nil, "JSON from_db=2")
check(payload:find('"db":true', 1, true) ~= nil, "JSON db=true")
check(payload:find('"labels":"甲 / 乙 / 丙 / 丁"', 1, true) ~= nil, "JSON labels 为中文标号")
check(payload:find('"channel_ids":"1,2"', 1, true) ~= nil, "JSON channel_ids=1,2")
-- 面板的运行控制/倒计时/定时计划展示依赖下面这些字段，字段名两边必须一致
check(payload:find('"enabled":', 1, true) ~= nil and payload:find('"paused":', 1, true) ~= nil,
    "JSON 带 enabled / paused（面板据此决定按钮文案）")
check(payload:find('"next_in":', 1, true) ~= nil, "JSON 带 next_in（下一题倒计时）")
check(payload:find('"schedule_enabled":false', 1, true) ~= nil, "JSON schedule_enabled=false（未开定时）")
check(payload:find('"schedule_windows":""', 1, true) ~= nil, "JSON schedule_windows 为空")
check(payload:find('"schedule_active":false', 1, true) ~= nil, "JSON schedule_active=false")
check(payload:find('"schedule_next_change_text":', 1, true) ~= nil, "JSON 带 schedule_next_change_text")
cmd("trivia stop")
TR.Config.scheduleEnabled = true
TR.Config.scheduleWindows = "08:00-09:00"
TR.Config.enabled = false
fakeTime = tsAt(nil, 8, 30)
tick()
local hSched = cmd("trivia api")
local schedPayload = (hSched.sent[1] or ""):gsub("^%[AGMP_OK%]%s*", "")
check(schedPayload:find('"schedule_enabled":true', 1, true) ~= nil, "计划开启时 JSON schedule_enabled=true")
check(schedPayload:find('"schedule_active":true', 1, true) ~= nil, "时间段内 JSON schedule_active=true")
check(schedPayload:find('"schedule_windows":"08:00-09:00"', 1, true) ~= nil, "JSON 回显时间段文本")
check(schedPayload:find('"schedule_next_change":' .. tostring(30 * 60), 1, true) ~= nil,
    "JSON schedule_next_change = 30 分钟（到 09:00 结束）")
check(schedPayload:find('"enabled":true', 1, true) ~= nil, "计划把它自己打开的开关反映到 JSON")
TR.Config.scheduleEnabled = false
TR.Config.scheduleWindows = ""
TR.scheduleActive = nil
TR.Config.enabled = true

-- 交给真正的 JSON 解析器校验（Node），避免"看起来像 JSON"就通过
local dump = io.open(SCRIPT_DIR .. "/payload.json", "w")
if dump then
    dump:write(payload)
    dump:close()
    check(true, "已导出 payload.json 供 Node 校验")
else
    check(false, "无法写出 payload.json")
end

-- 面板把某题停用后 reload，题库应减少
db.tables.trivia_reward_questions[1].enabled = 0
TR.prepared = nil
cmd("trivia reload")
check(TR.dbCount == 1, "停用一道后 reload → 数据库题库 1 道", TR.dbCount)

-- 数据库整体不可用时自动退回文件配置
db.failQueries = true
TR.prepared = nil
TR.Config.intervalSeconds = 900
cmd("trivia reload")
check(TR.Config.intervalSeconds == 900, "数据库不可用时保留文件配置的 intervalSeconds")
check(#bank() == 37, "数据库不可用时退回内置题库 37 题（实际 " .. #bank() .. "）")
db.failQueries = false

print("")
print(string.format("[%s] 结果: %d 通过, %d 失败", ORDER, pass, fail))
if fail > 0 then os.exit(1) end
