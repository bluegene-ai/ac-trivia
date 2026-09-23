--==============================================================================
--  TriviaReward.lua  ——  聊天答题奖励系统
--  运行环境 : AzerothCore (WotLK 3.3.5a) + mod-ALE (ALE Lua Engine, Lua 5.2)
--  脚本加载 : worldserver 目录下的 lua_scripts\  （本服为 E:\Server\release\80\lua_scripts\）
--  依赖 API : RegisterPlayerEvent / CreateLuaEvent / RemoveEventById / SendWorldMessage
--             GetPlayerCount / GetPlayerByName / GetItemTemplate / GetItemLink / SendMail
--==============================================================================
--  配置（当前做法）:
--    * 全部设置 / 题库 / 奖励预设都存在数据库里（默认库 ac_eluna，见下方 Config.dbName），
--      用 AGMP 面板的「聊天答题」页（/trivia）改完点保存即时生效，不再需要改 Lua 文件。
--    * 历史上还有一个 TriviaReward_conf.lua 配置文件，现已退休：它当年配的每一项
--      都已经写进数据库（`trivia_reward_settings` 的各列），或并入本文件的默认值。
--    * 本文件里的 setDefault(...) 就是"数据库还没有那行数据时的首启默认值"；
--      表建成、第一行写入之后，一切以数据库为准（每次 .trivia reload 都会重新读库）。
--    * 仍然只能在本文件里改的（属于脚本内部参数，面板没有对应列）：
--        Config.dbName        数据表所在库（默认 ac_eluna，必须与面板 config/trivia.php 一致）
--        Config.useDatabase   false = 完全不用数据库，退回内置题库 + Config.Questions
--        Config.tickIntervalMs 内部定时器间隔（毫秒，默认 1000）
--        Config.Questions     仅数据库不可用时使用的文件题库（默认空）
--        TriviaReward.RewardPresets / ChannelNames / ChannelLabels 的内置表
--==============================================================================
--  管理员指南:
--    * 放好文件后重启 worldserver，或在服务器控制台执行 .reload ale 热重载。
--    * 推荐用 AGMP 面板的「聊天答题」页（/trivia）管理：开关、节奏、作答频道、题库、奖励预设、
--      答对排行都在面板里改，改完点"重载题库"即时生效（面板写的是 ac_eluna 下的 trivia_reward_* 表）。
--    * 管理员指令（GM 等级 >= Config.minGMRankForCommand；控制台 / SOAP 同样可用）:
--         .trivia start [题号]   立即开始一题（可指定题库下标，便于测试）
--         .trivia stop           立刻结束当前题目（不发奖励）
--         .trivia pause|off      暂停自动出题（当前题目继续到结束；已暂停时重复执行无副作用）
--         .trivia resume|on      恢复自动出题，并把下一题提前到约 Config.resumeDelaySeconds 秒后
--         .trivia enable|disable 运行时开启/关闭整个系统（下一题提前到场；重启后以库/配置为准）
--         .trivia reload         重新从数据库读取设置/题库/奖励预设
--         .trivia schedule       查看定时启停计划（每天的时间段）与下一次开关时间
--         .trivia api            输出单行 JSON 状态（AGMP 面板用）
--         .trivia status         查看运行状态（题库数、答题频道、下一题倒计时、定时计划）
--         .trivia stats          查看本次开启以来的答对排行
--         .trivia chanscan       开始/停止频道扫描：把频道发言的频道 ID 打到 ALE 日志并私聊你，
--                                用来确认"世界频道/综合频道"这类 ID（自定义频道是负数）
--         .trivia chanlist       列出内置频道名与 ID 对照表
--==============================================================================
--  玩家指南（可用 Config.answerHint 自定义，留空则按已开启的频道自动生成）:
--    * 系统会在聊天窗口出题，给出 A/B/C/D 四个选项。
--    * 在已开启的频道里输入 A、B、C、D（或 1、2、3、4）发送即可作答。
--    * 第一个答对的玩家会被系统公告，奖励通过邮件发放到邮箱。
--==============================================================================

TriviaReward = TriviaReward or {}
local TR = TriviaReward

-- 只在键不存在时写默认值：外部（别的脚本、旧配置文件）先设过就不覆盖
local function setDefault(tbl, key, value)
    if tbl[key] == nil then
        tbl[key] = value
    end
end

TR.Config = TR.Config or {}
local C = TR.Config

--==============================================================================
--  ① 配置：开启 / 关闭 与出题节奏
--==============================================================================
setDefault(C, "enabled", true)                  -- 总开关：false = 完全不运行（也可用 .trivia disable 运行时关闭）
setDefault(C, "debug", false)                   -- true = 把每题开始/结束/频道扫描写进 ALE 日志（面板里可开关）
setDefault(C, "firstDelaySeconds", 60)          -- 服务器启动（或 .reload ale）后多少秒出第一题
setDefault(C, "intervalSeconds", 900)           -- 上一题结束到下一题开始之间的间隔（秒）
setDefault(C, "answerSeconds", 60)              -- 每题作答时间（秒），超时无人答对则公布答案
setDefault(C, "remindEverySeconds", 30)         -- 作答期间每隔多少秒重发一次提示（0 = 不提醒）
setDefault(C, "tickIntervalMs", 1000)           -- 内部定时器间隔（毫秒），一般不用改（面板没有这一项）
setDefault(C, "minPlayersOnline", 1)            -- 在线人数少于该值时不出题
setDefault(C, "idleRetrySeconds", 5)            -- 人数不足时，多少秒后重新检查
setDefault(C, "resumeDelaySeconds", 5)          -- .trivia resume / enable 后多少秒出下一题

-- 定时启停：按"每天的固定时间段"自动开启/结束答题活动（面板「运行状态」页可直接改）
--   scheduleEnabled = true 时，时间段的优先级高于 .trivia enable / disable：
--   进入时间段会自动开启，离开时间段会自动结束当前题并停止出题。
--   scheduleWindows 写法（分号或换行分隔多段；不带星期前缀 = 每天）：
--       "08:00-09:00"                     每天 8:00-9:00
--       "08:00-09:00; 20:00-22:00"        每天两段
--       "1-5@08:00-09:00"                 周一至周五（1=周一 … 7=周日）
--       "6,7@20:00-21:00"                 周六、周日
--       "22:00-02:00"                     跨夜（到第二天凌晨 2 点）
setDefault(C, "scheduleEnabled", false)
setDefault(C, "scheduleWindows", "")

--==============================================================================
--  ② 配置：发言频道（从哪里收答案）
--==============================================================================
--  答题来源可以同时开启多个，玩家在任意一个里作答都算数。
setDefault(C, "answerSay", true)                -- 普通说话 /s（CHAT_MSG_SAY）
setDefault(C, "answerYell", true)               -- 喊话 /y（CHAT_MSG_YELL）
setDefault(C, "answerEmote", false)             -- 表情 /e（CHAT_MSG_EMOTE，一般不需要）
setDefault(C, "answerWhisper", false)           -- 悄悄话 /w（注意：任意私聊内容都会参与匹配，可能误判）
setDefault(C, "answerChannelIds", { "综合" })     -- 频道作答：填频道 ID 或下面的内置频道名，例如 { "综合", 1, -5 }；空 {} = 不接受频道发言
setDefault(C, "answerPrefix", "")               -- 要求答案前缀，例如 "!" 表示必须发 "!A"；空 = 不要求
setDefault(C, "allowLooseLetter", true)         -- 允许 "A." "A)" "A、" "A。" 这类写法
-- 选项标号：播报里显示的标号，同时也是允许玩家输入的答案符号（默认 A/B/C/D）
--   想用中文：TriviaReward.Config.optionLabels = { "甲", "乙", "丙", "丁" }
--             同时建议 TriviaReward.Config.optionFormat = "%s、%s"，播报就是「甲、暴风城」
--   选项也支持用标号当键来写：options = { 甲 = "暴风城", 乙 = "铁炉堡", 丙 = "达纳苏斯", 丁 = "埃索达" }
setDefault(C, "optionLabels", { "A", "B", "C", "D" })
setDefault(C, "optionFormat", "%s) %s")          -- 播报里每个选项的格式：第一个 %s = 标号，第二个 %s = 选项文本
setDefault(C, "allowLatinLetters", true)         -- 除标号外，是否仍接受 A/B/C/D（按位置）作答
setDefault(C, "allowNumberAnswer", true)        -- 允许用 1 / 2 / 3 / 4 回答
setDefault(C, "allowTextAnswer", false)         -- 允许直接输入选项全文（中文输入法玩家可能需要）
setDefault(C, "attemptsPerPlayer", 1)           -- 每题每人可作答次数（1 = 只有一次机会，0 = 不限）
setDefault(C, "ignoreGMs", true)                -- 开着 GM 标签的账号不参与答题
setDefault(C, "gmRankExempt", 3)                -- GM 等级 >= 该值时不参与（0 = 不限制）
setDefault(C, "minLevel", 1)                    -- 低于该等级的角色不参与

-- 内置频道 ID 对照表（取自本服客户端 ChatChannels.dbc，管理员可用 .trivia chanscan 核对自定义频道）
-- 注意：逐个合并而不是整体赋值，这样即使外面先建了空表也不会把内置对照表顶掉
local BUILTIN_CHANNEL_NAMES = {
    general        = 1,   ["综合"]     = 1,
    trade          = 2,   ["交易"]     = 2,
    localdefense   = 22,  ["本地防务"] = 22,
    worlddefense   = 23,  ["世界防务"] = 23,
    guildrecruit   = 25,  ["公会招募"] = 25,
    lfg            = 26,  ["寻求组队"] = 26,
}
-- 频道中文显示名（用于播报"在哪里作答"）
local BUILTIN_CHANNEL_LABELS = {
    [1] = "综合频道", [2] = "交易频道", [22] = "本地防务", [23] = "世界防务",
    [25] = "公会招募", [26] = "寻求组队",
}

TR.ChannelNames = TR.ChannelNames or {}
TR.ChannelLabels = TR.ChannelLabels or {}
for key, value in pairs(BUILTIN_CHANNEL_NAMES) do
    if TR.ChannelNames[key] == nil then
        TR.ChannelNames[key] = value
    end
end
for key, value in pairs(BUILTIN_CHANNEL_LABELS) do
    if TR.ChannelLabels[key] == nil then
        TR.ChannelLabels[key] = value
    end
end

--==============================================================================
--  ③ 配置：题目与答案
--==============================================================================
setDefault(C, "useBuiltinQuestions", true)      -- 首次建库时是否把脚本内置题库导入一次（之后题库以数据库为准）
TR.Questions = TR.Questions or {}               -- 仅"数据库不可用"时使用的文件题库（默认空，题库请放数据库）

--==============================================================================
--  ④ 配置：奖励物品
--==============================================================================
setDefault(C, "rewardMode", "question")         -- "question" = 按题目自带奖励；"pool" = 每次从奖励池随机
setDefault(C, "defaultRewardPreset", "cloth5")  -- 题目没写 reward 时用哪个预设
setDefault(C, "poolPresets", {                  -- rewardMode = "pool" 时的随机奖励池
    "cloth5", "cloth10", "heal5", "mana5", "ore5", "gold5", "gold10", "gold20", "combo"
})
setDefault(C, "senderGUID", 10667)              -- 邮件发送者的角色 low GUID（与本服 RecruitAFriend 保持一致）
setDefault(C, "mailStationery", 41)             -- 邮件信纸：41 = 普通，61 = GM，62 = 拍卖行 …
setDefault(C, "itemLinkLocale", 4)              -- 物品链接语言：0=enUS 1=koKR 2=frFR 3=deDE 4=zhCN 5=zhTW …
setDefault(C, "mailSubject", "答题奖励")
setDefault(C, "mailBody",
    "勇士，恭喜你在聊天答题中第一个答对！\n" ..
    "题目：{question}\n" ..
    "正确答案：{answer}\n" ..
    "奖励已随信附上，祝你在艾泽拉斯的旅途愉快！")

-- 奖励预设：items 支持三种写法，money 单位是铜（10000 铜 = 1 金）
--     items = { 33470 }                     → 霜纹布 x1
--     items = { { 33470, 5 } }              → 霜纹布 x5
--     items = { { entry = 33470, count = 5 } }
-- 这些只是"首次建库时的种子预设"；之后新增/修改预设请用面板（面板写 trivia_reward_presets 表）。
TR.RewardPresets = TR.RewardPresets or {}
local function preset(name, items, money)
    if TR.RewardPresets[name] == nil then
        TR.RewardPresets[name] = { items = items, money = money or 0 }
    end
end

preset("cloth5",  { { 33470, 5 } })                                     -- 霜纹布 x5
preset("cloth10", { { 33470, 10 } })                                    -- 霜纹布 x10
preset("heal5",   { { 33447, 5 } })                                     -- 符文治疗药水 x5
preset("heal10",  { { 33447, 10 } })                                    -- 符文治疗药水 x10
preset("mana5",   { { 33448, 5 } })                                     -- 符文法力药水 x5
preset("ore5",    { { 36909, 5 } })                                     -- 钴矿石 x5
preset("life2",   { { 37704, 2 } })                                     -- 生命结晶 x2
preset("gold1",   nil, 10000)                                           -- 1 金
preset("gold5",   nil, 50000)                                           -- 5 金
preset("gold10",  nil, 100000)                                          -- 10 金
preset("gold20",  nil, 200000)                                          -- 20 金
preset("combo",   { { 33470, 5 }, { 33447, 2 } }, 50000)                -- 布 + 药 + 钱

--==============================================================================
--  ⑤ 配置：播报文本 与 管理员权限
--==============================================================================
setDefault(C, "prefix", "|cff00ff00[答题]|r ")  -- 普通播报前缀（绿色）
setDefault(C, "winPrefix", "|cffffd200[答题]|r ") -- 中奖/答案播报前缀（金色）
setDefault(C, "answerHint", "")                 -- 作答方式提示，空 = 按已开启的频道自动生成
setDefault(C, "announceOnLogin", true)          -- 答题期间登录的玩家，补发当前题目
setDefault(C, "replyWrongAnswer", false)        -- 答错时是否私聊提示（默认静默，避免刷屏）
setDefault(C, "replyAlreadyAnswered", true)     -- 机会用完后再次作答时提示
setDefault(C, "minGMRankForCommand", 2)         -- 使用 .trivia 指令所需的最低 GM 等级

-- 面板（AGMP /trivia 页）管理用
setDefault(C, "dbName", "ac_eluna")             -- 面板读写的数据表所在库（与 RAF / 活动 Boss 一致）
setDefault(C, "useDatabase", true)              -- true = 数据库里的设置/题库/奖励预设生效（面板改完即时生效）

--==============================================================================
--  内置题库（可用 Config.useBuiltinQuestions = false 关掉，或整体替换）
--  题目写法（四种都支持）:
--      { "题干", { "选项A", "选项B", "选项C", "选项D" }, "正确答案文本" }
--      { "题干", { "选项A", "选项B", "选项C", "选项D" }, 2, "gold5" }        -- 用下标指定答案 + 奖励预设
--      { text = "题干", options = {...}, answer = "选项A", reward = { money = 10000 } }
--      { text = "题干", options = { ["甲"] = "选项A", ["乙"] = "选项B", ["丙"] = "选项C", ["丁"] = "选项D" }, answer = "选项A" }
--  选项标号可自定义：Config.optionLabels = { "A","B","C","D" }（默认）或 { "甲","乙","丙","丁" }；
--  用 甲/乙/丙/丁、数字 1/2/3/4、A/B/C/D 当 options 的键都能被自动识别，
--  但非 ASCII 标号必须写成 ["甲"] = … 的形式（Lua 标识符只认 ASCII，写 甲 = … 会语法错误）。
--  答案可以写成 answer = "答案文本"（推荐，不怕选项顺序调整），也可以写 answer = "甲" 或 correct = 下标(1-4)
--==============================================================================
if TR.builtinsAdded == nil then
    TR.builtinsAdded = true
    TR.BuiltinQuestions = {}

    local function add(text, options, correct, reward)
        TR.BuiltinQuestions[#TR.BuiltinQuestions + 1] =
            { text = text, options = options, correct = correct, reward = reward }
    end

    -- ── 魔兽世界 3.3.5 / 巫妖王之怒 ──────────────────────────────────────────
    add("巫妖王的本名是谁？", { "阿尔萨斯·米奈希尔", "耐奥祖", "克尔苏加德", "伊利丹·怒风" }, 1, "cloth5")
    add("《魔兽世界》3.3.5 资料片的名字是什么？", { "燃烧的远征", "巫妖王之怒", "大灾变", "熊猫人之谜" }, 2, "cloth5")
    add("巫妖王之怒中，玩家的等级上限是多少？", { "70", "80", "85", "90" }, 2, "gold1")
    add("冰冠堡垒（ICC）的最终首领是谁？", { "辛达苟萨", "普崔塞德教授", "巫妖王", "兰娜瑟尔女王" }, 3, "gold5")
    add("死亡骑士（DK）出生时的起始等级是？", { "1", "55", "60", "70" }, 2, "cloth5")
    add("巫妖王之怒加入的新职业是？", { "武僧", "死亡骑士", "恶魔猎手", "唤魔师" }, 2, "heal5")
    add("阿尔萨斯手中那把符文剑叫什么名字？", { "灰烬使者", "霜之哀伤", "血吼", "埃提耶什" }, 2, "mana5")
    add("纳克萨玛斯（80 级版本）位于哪张地图上？", { "晶歌森林", "龙骨荒野", "祖达克", "风暴峭壁" }, 2, "cloth5")
    add("奥杜尔团队副本的最终首领是谁？", { "米米尔隆", "尤格-萨隆", "奥尔加隆", "维扎克斯将军" }, 2, "gold5")
    add("十字军的试炼（TOC）团队副本的最终首领是谁？", { "加拉克苏斯大王", "阿努巴拉克", "瓦格里双子", "北地之魂" }, 2, "ore5")
    add("以下哪个是巫妖王之怒的团队副本？", { "安其拉神殿", "黑石塔", "黑曜石圣殿", "祖尔格拉布" }, 3, "cloth5")
    add("联盟在诺森德的据点「瓦加德」位于哪个区域？", { "北风苔原", "嚎风峡湾", "灰熊丘陵", "祖达克" }, 2, "cloth5")
    add("5 人副本「闪电大厅」位于哪个区域？", { "祖达克", "风暴峭壁", "冰冠冰川", "索拉查盆地" }, 2, "mana5")
    add("「奥妮克希亚」是什么颜色的巨龙？", { "红龙", "黑龙", "蓝龙", "绿龙" }, 2, "life2")

    -- ── 经典旧世 / 世界观 ────────────────────────────────────────────────────
    add("部落城市「幽暗城」位于哪块大陆？", { "卡利姆多", "东部王国", "诺森德", "外域" }, 2, "cloth5")
    add("暗夜精灵的主城是？", { "暴风城", "铁炉堡", "达纳苏斯", "埃索达" }, 3, "cloth5")
    add("「奥格瑞玛」是以谁的名字命名的？", { "格罗姆·地狱咆哮", "奥格瑞姆·毁灭之锤", "萨尔", "凯恩·血蹄" }, 2, "cloth5")
    add("「雷霆崖」是哪个种族的城市？", { "兽人", "牛头人", "巨魔", "亡灵" }, 2, "cloth5")
    add("被遗忘者的领袖是谁？", { "萨尔", "希尔瓦娜斯·风行者", "凯恩·血蹄", "沃金" }, 2, "cloth5")
    add("血精灵加入部落是在哪个资料片？", { "经典旧世", "燃烧的远征", "巫妖王之怒", "大灾变" }, 2, "cloth5")
    add("以下哪座城市不在艾泽拉斯（而是位于外域）？", { "暴风城", "沙塔斯城", "雷霆崖", "幽暗城" }, 2, "cloth5")
    add("经典旧世中，艾泽拉斯有哪两块主要大陆？", { "只有东部王国", "东部王国与卡利姆多", "东部王国、卡利姆多与诺森德", "四块大陆" }, 2, "cloth5")
    add("经典旧世副本「斯坦索姆」亡灵区的最终首领是谁？", { "玛尔加尼斯", "瑞文戴尔男爵", "巴纳扎尔", "泰兰·弗丁" }, 2, "gold1")
    add("「灰烬使者」这把传奇武器上一任持有者是？", { "提里奥·弗丁", "亚历山德罗斯·莫格莱尼", "阿尔萨斯", "乌瑟尔" }, 2, "gold5")
    add("魔兽世界的货币换算中，1 金币等于多少铜币？", { "100", "1000", "10000", "100000" }, 3, "gold1")

    -- ── 游戏机制 / 职业 ─────────────────────────────────────────────────────
    add("以下哪个职业在 3.3.5 中可以装备盾牌？", { "战士", "圣骑士", "萨满祭司", "以上都可以" }, 4, "cloth5")
    add("德鲁伊的变形形态不包括以下哪一种？", { "熊形态", "猎豹形态", "蜘蛛形态", "旅行形态" }, 3, "mana5")
    add("「耐力」属性主要提升角色的什么？", { "攻击强度", "生命值", "法力值", "暴击等级" }, 2, "heal5")
    add("「急速等级」主要影响什么？", { "暴击几率", "命中几率", "施法速度与攻击速度", "护甲值" }, 3, "heal5")
    add("以下哪个是魔兽世界的采集类专业？", { "锻造", "采药", "工程学", "裁缝" }, 2, "ore5")
    add("以下哪一项不是 3.3.5 版本已有的专业技能？", { "钓鱼", "烹饪", "考古学", "急救" }, 3, "cloth5")
    add("3.3.5 中，一个角色最多可以学习几个主要专业技能？", { "1 个", "2 个", "3 个", "不限" }, 2, "gold1")
    add("附魔专业分解装备后获得的主要材料是？", { "无限之尘", "霜纹布", "萨隆邪铁矿石", "水晶化空气" }, 1, "cloth5")
    add("以下哪个职业拥有复活队友的技能（战斗中不可用）？", { "法师", "盗贼", "牧师", "猎人" }, 3, "mana5")
    add("想重置自己的副本进度，应该使用哪条聊天指令？", { "/reset", "/resetinstances", "/rinstances", "/resetall" }, 2, "cloth5")
    add("想给某个玩家发送悄悄话，应该使用哪条指令？", { "/s", "/w", "/y", "/p" }, 2, "cloth5")

    -- ── 服务端 / 硬核向 ─────────────────────────────────────────────────────
    add("AzerothCore 是一个开源的魔兽世界服务端，它主要支持哪个客户端版本？", { "1.12", "2.4.3", "3.3.5a", "4.3.4" }, 3, "gold5")
end

--==============================================================================
--  以下为逻辑实现，正常情况下不需要修改
--==============================================================================

local function now()
    return os.time()
end

local function logInfo(fmt, ...)
    if TR.Config.debug then
        PrintInfo("[答题] " .. string.format(fmt, ...))
    end
end

local function logError(fmt, ...)
    PrintError("[答题] " .. string.format(fmt, ...))
end

--================================================================= 频道解析
-- 把 { "综合", 2, -5 } 这类配置解析成数字 ID 数组（也允许直接写单个值：answerChannelIds = "综合"）
local function resolveAnswerChannelIds()
    local cfg = TR.Config
    local out = {}

    local src = cfg.answerChannelIds
    if src == nil then
        return out
    end
    if type(src) ~= "table" then
        src = { src }
    end

    for i = 1, #src do
        local v = src[i]
        local id = tonumber(v)
        if id == nil and type(v) == "string" then
            id = TR.ChannelNames[v] or TR.ChannelNames[string.lower(v)]
        end
        if id == nil then
            logError("频道「%s」无法识别：请填数字 ID，或使用内置频道名（综合/交易/本地防务/世界防务/公会招募/寻求组队），自定义频道请用 .trivia chanscan 查 ID。", tostring(v))
        else
            local exists = false
            for j = 1, #out do
                if out[j] == id then
                    exists = true
                    break
                end
            end
            if not exists then
                out[#out + 1] = id
            end
        end
    end

    return out
end

local function channelLabel(id)
    return TR.ChannelLabels[id] or ("频道 " .. tostring(id))
end

--==============================================================================
--  ⑥ 面板（AGMP /trivia 页）管理用的数据库
--     表建在 Config.dbName（默认 ac_eluna，与 RAF / 活动 Boss 同一个库）下：
--         trivia_reward_settings   单行配置（面板里改的就是这些）
--         trivia_reward_questions  题库（面板/模板导入维护，脚本只读）
--         trivia_reward_presets    奖励预设（面板维护，脚本只读）
--         trivia_reward_winners    答对排行（脚本写，面板读）
--
--     题库与奖励预设**只以数据库为准**：脚本加载时检测表不存在就建库建表，
--     并在题库为空时把内置题库导入一次（之后改题一律走面板或模板导入，不用改 lua 文件）。
--     设置同理：表里的 trivia_reward_settings 那一行就是全部配置，改它请用面板。
--     数据库不可用时才会退回 内置题库 + Config.Questions，保证活动不会因为数据库问题中断。
--==============================================================================
local DB = { available = false, tables = {}, lastError = "", checked = false }
TR.db = DB

-- 数据库列 → 配置键 的映射（面板表单与这里一一对应，两边改动要同步）
local SETTING_FIELDS = {
    { "enabled",                 "enabled",                "bool" },
    { "interval_seconds",        "intervalSeconds",        "int" },
    { "answer_seconds",          "answerSeconds",          "int" },
    { "remind_every_seconds",    "remindEverySeconds",     "int" },
    { "first_delay_seconds",     "firstDelaySeconds",      "int" },
    { "min_players_online",      "minPlayersOnline",       "int" },
    { "min_level",               "minLevel",               "int" },
    { "answer_say",              "answerSay",              "bool" },
    { "answer_yell",             "answerYell",             "bool" },
    { "answer_emote",            "answerEmote",            "bool" },
    { "answer_whisper",          "answerWhisper",          "bool" },
    { "answer_channel_ids",      "answerChannelIds",       "csv" },
    { "answer_prefix",           "answerPrefix",           "string" },
    { "allow_number_answer",     "allowNumberAnswer",      "bool" },
    { "allow_latin_letters",     "allowLatinLetters",      "bool" },
    { "allow_text_answer",       "allowTextAnswer",        "bool" },
    { "attempts_per_player",     "attemptsPerPlayer",      "int" },
    { "option_labels",           "optionLabels",           "csv" },
    { "option_format",           "optionFormat",           "string" },
    { "reward_mode",             "rewardMode",             "string" },
    { "default_reward_preset",   "defaultRewardPreset",    "string" },
    { "pool_presets",            "poolPresets",            "csv" },
    { "use_builtin_questions",   "useBuiltinQuestions",    "bool" },
    { "announce_on_login",       "announceOnLogin",        "bool" },
    { "reply_wrong_answer",      "replyWrongAnswer",       "bool" },
    { "reply_already_answered",  "replyAlreadyAnswered",   "bool" },
    { "min_gm_rank_for_command", "minGMRankForCommand",    "int" },
    { "sender_guid",             "senderGUID",             "int" },
    { "mail_stationery",         "mailStationery",         "int" },
    { "item_link_locale",        "itemLinkLocale",         "int" },
    { "mail_subject",            "mailSubject",            "string" },
    { "mail_body",               "mailBody",               "string" },
    { "schedule_enabled",        "scheduleEnabled",        "bool" },
    { "schedule_windows",        "scheduleWindows",        "csvtext" },
    -- 以下 9 列是 TriviaReward_conf.lua 退休时搬进数据库的（面板「设置」页可改）
    { "debug_log",               "debug",                  "bool" },
    { "idle_retry_seconds",      "idleRetrySeconds",       "int" },
    { "resume_delay_seconds",    "resumeDelaySeconds",     "int" },
    { "allow_loose_letter",      "allowLooseLetter",       "bool" },
    { "ignore_gms",              "ignoreGMs",              "bool" },
    { "gm_rank_exempt",          "gmRankExempt",           "int" },
    { "answer_hint",             "answerHint",             "string" },
    { "broadcast_prefix",        "prefix",                 "string" },
    { "win_prefix",              "winPrefix",              "string" },
}

-- 建表语句（面板靠表结构读写，加列时请同步 AGMP 的 Domain/Trivia 与视图）
local SCHEMA_SQL = {
    "CREATE DATABASE IF NOT EXISTS `%s`;",
    "CREATE TABLE IF NOT EXISTS `%s`.`trivia_reward_settings` ("
        .. "`id` TINYINT UNSIGNED NOT NULL DEFAULT 1,"
        .. "`enabled` TINYINT NOT NULL DEFAULT 1,"
        .. "`interval_seconds` INT NOT NULL DEFAULT 900,"
        .. "`answer_seconds` INT NOT NULL DEFAULT 60,"
        .. "`remind_every_seconds` INT NOT NULL DEFAULT 30,"
        .. "`first_delay_seconds` INT NOT NULL DEFAULT 60,"
        .. "`min_players_online` INT NOT NULL DEFAULT 1,"
        .. "`min_level` INT NOT NULL DEFAULT 1,"
        .. "`answer_say` TINYINT NOT NULL DEFAULT 1,"
        .. "`answer_yell` TINYINT NOT NULL DEFAULT 1,"
        .. "`answer_emote` TINYINT NOT NULL DEFAULT 0,"
        .. "`answer_whisper` TINYINT NOT NULL DEFAULT 0,"
        .. "`answer_channel_ids` VARCHAR(255) NOT NULL DEFAULT '1',"
        .. "`answer_prefix` VARCHAR(16) NOT NULL DEFAULT '',"
        .. "`allow_number_answer` TINYINT NOT NULL DEFAULT 1,"
        .. "`allow_latin_letters` TINYINT NOT NULL DEFAULT 1,"
        .. "`allow_text_answer` TINYINT NOT NULL DEFAULT 0,"
        .. "`attempts_per_player` INT NOT NULL DEFAULT 1,"
        .. "`option_labels` VARCHAR(64) NOT NULL DEFAULT 'A,B,C,D',"
        .. "`option_format` VARCHAR(32) NOT NULL DEFAULT '%%s) %%s',"
        .. "`reward_mode` VARCHAR(16) NOT NULL DEFAULT 'question',"
        .. "`default_reward_preset` VARCHAR(32) NOT NULL DEFAULT 'cloth5',"
        .. "`pool_presets` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "`use_builtin_questions` TINYINT NOT NULL DEFAULT 1,"
        .. "`announce_on_login` TINYINT NOT NULL DEFAULT 1,"
        .. "`reply_wrong_answer` TINYINT NOT NULL DEFAULT 0,"
        .. "`reply_already_answered` TINYINT NOT NULL DEFAULT 1,"
        .. "`min_gm_rank_for_command` INT NOT NULL DEFAULT 2,"
        .. "`sender_guid` INT NOT NULL DEFAULT 10667,"
        .. "`mail_stationery` INT NOT NULL DEFAULT 41,"
        .. "`item_link_locale` INT NOT NULL DEFAULT 4,"
        .. "`mail_subject` VARCHAR(128) NOT NULL DEFAULT '答题奖励',"
        .. "`mail_body` TEXT NULL,"
        .. "`schedule_enabled` TINYINT NOT NULL DEFAULT 0,"
        .. "`schedule_windows` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "`debug_log` TINYINT NOT NULL DEFAULT 0,"
        .. "`idle_retry_seconds` INT NOT NULL DEFAULT 5,"
        .. "`resume_delay_seconds` INT NOT NULL DEFAULT 5,"
        .. "`allow_loose_letter` TINYINT NOT NULL DEFAULT 1,"
        .. "`ignore_gms` TINYINT NOT NULL DEFAULT 1,"
        .. "`gm_rank_exempt` INT NOT NULL DEFAULT 3,"
        .. "`answer_hint` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "`broadcast_prefix` VARCHAR(32) NOT NULL DEFAULT '|cff00ff00[答题]|r ',"
        .. "`win_prefix` VARCHAR(32) NOT NULL DEFAULT '|cffffd200[答题]|r ',"
        .. "`updated_at` INT NOT NULL DEFAULT 0,"
        .. "PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
    "CREATE TABLE IF NOT EXISTS `%s`.`trivia_reward_questions` ("
        .. "`id` INT UNSIGNED NOT NULL AUTO_INCREMENT,"
        .. "`question` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "`option1` VARCHAR(120) NOT NULL DEFAULT '',"
        .. "`option2` VARCHAR(120) NOT NULL DEFAULT '',"
        .. "`option3` VARCHAR(120) NOT NULL DEFAULT '',"
        .. "`option4` VARCHAR(120) NOT NULL DEFAULT '',"
        .. "`answer_index` TINYINT NOT NULL DEFAULT 1,"
        .. "`labels` VARCHAR(32) NOT NULL DEFAULT '',"
        .. "`reward_preset` VARCHAR(32) NOT NULL DEFAULT '',"
        .. "`reward_items` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "`reward_money` INT NOT NULL DEFAULT 0,"
        .. "`enabled` TINYINT NOT NULL DEFAULT 1,"
        .. "`sort_order` INT NOT NULL DEFAULT 0,"
        .. "`source` VARCHAR(16) NOT NULL DEFAULT 'panel',"
        .. "`updated_at` INT NOT NULL DEFAULT 0,"
        .. "`created_at` INT NOT NULL DEFAULT 0,"
        .. "PRIMARY KEY (`id`), KEY `enabled` (`enabled`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
    "CREATE TABLE IF NOT EXISTS `%s`.`trivia_reward_presets` ("
        .. "`name` VARCHAR(32) NOT NULL,"
        .. "`items` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "`money` INT NOT NULL DEFAULT 0,"
        .. "`enabled` TINYINT NOT NULL DEFAULT 1,"
        .. "`updated_at` INT NOT NULL DEFAULT 0,"
        .. "PRIMARY KEY (`name`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
    "CREATE TABLE IF NOT EXISTS `%s`.`trivia_reward_winners` ("
        .. "`guid` INT UNSIGNED NOT NULL,"
        .. "`name` VARCHAR(64) NOT NULL DEFAULT '',"
        .. "`wins` INT NOT NULL DEFAULT 0,"
        .. "`total_money` BIGINT NOT NULL DEFAULT 0,"
        .. "`last_win_at` INT NOT NULL DEFAULT 0,"
        .. "`last_question` VARCHAR(255) NOT NULL DEFAULT '',"
        .. "PRIMARY KEY (`guid`), KEY `wins` (`wins`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
}

local function dbName()
    local name = tostring(TR.Config.dbName or "ac_eluna")
    -- 库名会直接拼进 SQL，只允许字母数字下划线
    if name:match("^[%w_]+$") == nil then
        return "ac_eluna"
    end
    return name
end

local function dbEscape(value)
    local s = tostring(value == nil and "" or value)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("'", "''")
    return s
end

local function dbExec(sql)
    local ok = pcall(CharDBExecute, sql)
    if not ok then
        logError("数据库写入失败：%s", tostring(sql))
    end
    return ok
end

local function dbRow(sql)
    local ok, query = pcall(CharDBQuery, sql)
    if not ok or query == nil then
        return nil
    end
    local okRow, row = pcall(function() return query:GetRow() end)
    if not okRow then
        return nil
    end
    return row
end

local function dbRows(sql)
    local rows = {}
    local ok, query = pcall(CharDBQuery, sql)
    if not ok or query == nil then
        return rows
    end

    local okRow, row = pcall(function() return query:GetRow() end)
    while okRow and row ~= nil do
        rows[#rows + 1] = row
        local okNext, hasNext = pcall(function() return query:NextRow() end)
        if not okNext or not hasNext then
            break
        end
        okRow, row = pcall(function() return query:GetRow() end)
    end

    return rows
end

local function splitCsv(text)
    local out = {}
    local s = tostring(text or "")
    if s == "" then
        return out
    end
    for token in s:gmatch("[^,]+") do
        token = token:gsub("^%s+", ""):gsub("%s+$", "")
        if token ~= "" then
            out[#out + 1] = token
        end
    end
    return out
end

local function joinCsv(list)
    if type(list) ~= "table" then
        return ""
    end
    local parts = {}
    for i = 1, #list do
        parts[#parts + 1] = tostring(list[i])
    end
    return table.concat(parts, ",")
end

-- 按 UTF-8 字符切开（Lua 5.2 没有 utf8 库，这里手写）
local function splitUtf8Chars(text)
    local out = {}
    local s = tostring(text or "")
    local i = 1
    local len = #s
    while i <= len do
        local byte = s:byte(i)
        local size = 1
        if byte >= 240 then
            size = 4
        elseif byte >= 224 then
            size = 3
        elseif byte >= 192 then
            size = 2
        end
        local char = s:sub(i, i + size - 1)
        if char:match("%s") == nil then
            out[#out + 1] = char
        end
        i = i + size
    end
    return out
end

-- 选项标号："甲,乙,丙,丁" / "甲乙丙丁" / "A,B,C,D" / "ABCD" 都能解析
local function parseLabels(text)
    local s = tostring(text or "")
    if s == "" then
        return {}
    end

    local out = splitCsv(s)
    if #out >= 2 then
        return out
    end

    return splitUtf8Chars(s)
end

-- "33470:5,33447:2" / "33470:5;33447 x2" → { {33470,5}, {33447,2} }
-- 分隔符只用逗号/分号；条目内部的空格（"33447 x2"）要保留给模式匹配
local function parseItemsText(text)
    local items = {}
    local s = tostring(text or "")
    if s == "" then
        return items
    end
    for pair in s:gmatch("[^,;]+") do
        local entry, count = pair:match("^%s*(%d+)%s*[:xX*]%s*(%d+)%s*$")
        if entry == nil then
            entry = pair:match("^%s*(%d+)%s*$")
            count = "1"
        end
        if entry ~= nil then
            items[#items + 1] = { tonumber(entry), tonumber(count) or 1 }
        end
    end
    return items
end

local function itemsToText(reward)
    if type(reward) ~= "table" or type(reward.items) ~= "table" then
        return ""
    end
    local parts = {}
    for i = 1, #reward.items do
        local it = reward.items[i]
        local entry, count
        if type(it) == "number" then
            entry, count = it, 1
        elseif type(it) == "table" then
            entry = tonumber(it.entry or it[1])
            count = tonumber(it.count or it[2]) or 1
        end
        if entry and entry > 0 then
            parts[#parts + 1] = tostring(entry) .. ":" .. tostring(count or 1)
        end
    end
    return table.concat(parts, ",")
end

local function sqlQuote(value)
    return "'" .. dbEscape(value) .. "'"
end

local function sqlValueOf(key, sqlType)
    local cfg = TR.Config
    local value = cfg[key]

    if sqlType == "bool" then
        return (value == true or value == 1) and "1" or "0"
    end
    if sqlType == "int" then
        return tostring(math.floor(tonumber(value) or 0))
    end
    if sqlType == "csv" then
        return sqlQuote(joinCsv(value))
    end
    if sqlType == "csvtext" then
        -- 允许写成数组：{ "08:00-09:00", "20:00-21:00" }
        if type(value) == "table" then
            value = table.concat(value, ";")
        end
        return sqlQuote(tostring(value == nil and "" or value))
    end
    return sqlQuote(tostring(value == nil and "" or value))
end

local function convertSetting(sqlType, raw)
    if sqlType == "bool" then
        local num = tonumber(raw)
        if num ~= nil then
            return num ~= 0
        end
        return tostring(raw) == "true"
    end
    if sqlType == "int" then
        return tonumber(raw)
    end
    if sqlType == "csv" then
        return splitCsv(raw)
    end
    return tostring(raw)
end

-- 表结构升级：缺列就补（老版本建的 trivia_reward_questions 没有 source/created_at）
local function ensureColumn(tableName, columnName, definition)
    local row = dbRow(string.format(
        "SELECT COUNT(*) AS `c` FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = %s AND TABLE_NAME = '%s' AND COLUMN_NAME = '%s';",
        sqlQuote(dbName()), dbEscape(tableName), dbEscape(columnName)))
    if row ~= nil and (tonumber(row.c) or 0) > 0 then
        return false
    end

    dbExec(string.format("ALTER TABLE `%s`.`%s` ADD COLUMN `%s` %s;", dbName(), tableName, columnName, definition))
    logInfo("已为 %s 补充字段 %s。", tableName, columnName)
    return true
end

-- 把一道"题库表里还没有"的题写进数据库（首次导入种子题库用）
local function insertQuestionRow(q, index)
    dbExec(string.format(
        "INSERT INTO `%s`.`trivia_reward_questions` "
            .. "(`question`,`option1`,`option2`,`option3`,`option4`,`answer_index`,`labels`,"
            .. "`reward_preset`,`reward_items`,`reward_money`,`enabled`,`sort_order`,`source`,`updated_at`,`created_at`) "
            .. "VALUES ('%s','%s','%s','%s','%s',%d,'%s','%s','%s',%d,1,%d,'%s',%d,%d);",
        dbName(),
        dbEscape(q.text),
        dbEscape((q.options and q.options[1]) or ""),
        dbEscape((q.options and q.options[2]) or ""),
        dbEscape((q.options and q.options[3]) or ""),
        dbEscape((q.options and q.options[4]) or ""),
        tonumber(q.correct) or 1,
        dbEscape(joinCsv(q.labels or {})),
        dbEscape(type(q.reward) == "string" and q.reward or ""),
        dbEscape(type(q.reward) == "table" and itemsToText(q.reward) or ""),
        (type(q.reward) == "table" and math.floor(tonumber(q.reward.money) or 0)) or 0,
        tonumber(index) or 0,
        "seed",
        now(), now()))
end

-- 建库建表（幂等）：库/表不存在就建，并补齐老版本缺的列。
-- 只做结构，不写任何业务数据——默认设置的写入见 seedDefaults()，
-- 它要等所有脚本都加载完才能跑（否则会把脚本默认值当成配置写进库）。
local seedQuestionsIfEmpty -- 前置声明：实现在"题目准备"一节（依赖 normalizeQuestion）

local function ensureSchema()
    if DB.checked then
        return DB.available
    end
    DB.checked = true

    local db = dbName()

    -- 库已存在就不再执行 CREATE DATABASE：只有建表权限、没有建库权限的账号也不会刷错误日志
    local schemaRow = dbRow(string.format(
        "SELECT COUNT(*) AS `c` FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s;", sqlQuote(db)))
    if schemaRow == nil or (tonumber(schemaRow.c) or 0) == 0 then
        dbExec(string.format(SCHEMA_SQL[1], db))
    end

    for i = 2, #SCHEMA_SQL do
        dbExec(string.format(SCHEMA_SQL[i], db))
    end

    local probe = dbRow(string.format(
        "SELECT COUNT(*) AS `c` FROM information_schema.TABLES WHERE TABLE_SCHEMA = %s AND TABLE_NAME IN "
            .. "('trivia_reward_settings','trivia_reward_questions','trivia_reward_presets','trivia_reward_winners');",
        sqlQuote(db)))

    DB.available = probe ~= nil and (tonumber(probe.c) or 0) >= 4
    if not DB.available then
        DB.lastError = "数据表不可用（" .. db .. "）"
        logError("答题数据表不可用，本次运行使用内置题库 + 文件配置：%s", DB.lastError)
        return false
    end

    -- 老版本表结构补列（面板与模板导入会用到 source/created_at）
    ensureColumn("trivia_reward_questions", "source", "VARCHAR(16) NOT NULL DEFAULT 'panel'")
    ensureColumn("trivia_reward_questions", "created_at", "INT NOT NULL DEFAULT 0")
    -- 定时启停（面板「运行状态」页的定时计划）
    ensureColumn("trivia_reward_settings", "schedule_enabled", "TINYINT NOT NULL DEFAULT 0")
    ensureColumn("trivia_reward_settings", "schedule_windows", "VARCHAR(255) NOT NULL DEFAULT ''")
    -- TriviaReward_conf.lua 退休后搬进数据库的 9 项（面板「设置」页可改）
    ensureColumn("trivia_reward_settings", "debug_log", "TINYINT NOT NULL DEFAULT 0")
    ensureColumn("trivia_reward_settings", "idle_retry_seconds", "INT NOT NULL DEFAULT 5")
    ensureColumn("trivia_reward_settings", "resume_delay_seconds", "INT NOT NULL DEFAULT 5")
    ensureColumn("trivia_reward_settings", "allow_loose_letter", "TINYINT NOT NULL DEFAULT 1")
    ensureColumn("trivia_reward_settings", "ignore_gms", "TINYINT NOT NULL DEFAULT 1")
    ensureColumn("trivia_reward_settings", "gm_rank_exempt", "INT NOT NULL DEFAULT 3")
    ensureColumn("trivia_reward_settings", "answer_hint", "VARCHAR(255) NOT NULL DEFAULT ''")
    ensureColumn("trivia_reward_settings", "broadcast_prefix", "VARCHAR(32) NOT NULL DEFAULT '|cff00ff00[答题]|r '")
    ensureColumn("trivia_reward_settings", "win_prefix", "VARCHAR(32) NOT NULL DEFAULT '|cffffd200[答题]|r '")

    return true
end

-- 首次写入业务数据：设置行 / 奖励预设 / 种子题库（都只在表为空时写一次）。
-- 必须在脚本加载完成后调用（放到 tick 里，保证所有脚本都已加载）。
local function seedDefaults()
    if not DB.available then
        return false
    end

    local db = dbName()

    -- 设置行
    local settingsRow = dbRow(string.format("SELECT COUNT(*) AS `c` FROM `%s`.`trivia_reward_settings`;", db))
    if settingsRow ~= nil and (tonumber(settingsRow.c) or 0) == 0 then
        local cols, vals = {}, {}
        for i = 1, #SETTING_FIELDS do
            local field = SETTING_FIELDS[i]
            cols[#cols + 1] = "`" .. field[1] .. "`"
            vals[#vals + 1] = sqlValueOf(field[2], field[3])
        end
        cols[#cols + 1] = "`updated_at`"
        vals[#vals + 1] = tostring(now())
        dbExec(string.format("INSERT INTO `%s`.`trivia_reward_settings` (`id`,%s) VALUES (1,%s);",
            db, table.concat(cols, ","), table.concat(vals, ",")))
        logInfo("已在 %s 初始化 trivia_reward_settings 默认配置。", db)
    end

    -- 奖励预设（首次把脚本内置预设写进去，之后以数据库为准）
    local presetRow = dbRow(string.format("SELECT COUNT(*) AS `c` FROM `%s`.`trivia_reward_presets`;", db))
    if presetRow ~= nil and (tonumber(presetRow.c) or 0) == 0 then
        local names = {}
        for name in pairs(TR.RewardPresets) do
            names[#names + 1] = name
        end
        table.sort(names)
        for i = 1, #names do
            local p = TR.RewardPresets[names[i]]
            dbExec(string.format(
                "INSERT IGNORE INTO `%s`.`trivia_reward_presets` (`name`,`items`,`money`,`enabled`,`updated_at`) VALUES ('%s','%s',%d,1,%d);",
                db, dbEscape(names[i]), itemsToText(p), math.floor(tonumber(p.money) or 0), now()))
        end
        logInfo("已在 %s 初始化 %d 个奖励预设。", db, #names)
    end

    seedQuestionsIfEmpty()

    return true
end

-- 题库为空时把内置题库导入一次（之后题库以数据库为准，改题走面板或模板导入）
-- 注意：这里用到 normalizeQuestion，所以定义在它之后（见"题目准备"一节）。


local function loadSettingsFromDb()
    local row = dbRow(string.format("SELECT * FROM `%s`.`trivia_reward_settings` WHERE `id` = 1;", dbName()))
    if row == nil then
        return 0
    end

    local applied = 0
    for i = 1, #SETTING_FIELDS do
        local field = SETTING_FIELDS[i]
        local raw = row[field[1]]
        if raw ~= nil then
            local value = convertSetting(field[3], raw)
            if value ~= nil then
                TR.Config[field[2]] = value
                applied = applied + 1
            end
        end
    end

    logInfo("已从数据库载入 %d 项设置。", applied)
    return applied
end

local function loadPresetsFromDb()
    local rows = dbRows(string.format("SELECT * FROM `%s`.`trivia_reward_presets` WHERE `enabled` = 1;", dbName()))
    local count = 0
    for i = 1, #rows do
        local row = rows[i]
        local name = tostring(row.name or "")
        if name ~= "" then
            TR.RewardPresets[name] = {
                items = parseItemsText(row.items),
                money = math.floor(tonumber(row.money) or 0),
                fromDb = true,
            }
            count = count + 1
        end
    end
    logInfo("已从数据库载入 %d 个奖励预设。", count)
    return count
end

-- 数据库题库 → 题目表（由 prepareQuestions 汇总）
local function loadQuestionsFromDb()
    local rows = dbRows(string.format(
        "SELECT * FROM `%s`.`trivia_reward_questions` WHERE `enabled` = 1 ORDER BY `sort_order` ASC, `id` ASC;", dbName()))

    local list = {}
    for i = 1, #rows do
        local row = rows[i]
        local options = {}
        for n = 1, 4 do
            local text = tostring(row["option" .. n] or "")
            if text ~= "" then
                options[#options + 1] = text
            end
        end

        local labels = parseLabels(row.labels)
        local reward = nil
        local preset = tostring(row.reward_preset or "")
        local itemsText = tostring(row.reward_items or "")
        local money = math.floor(tonumber(row.reward_money) or 0)
        if preset ~= "" then
            reward = preset
        elseif itemsText ~= "" or money > 0 then
            reward = { items = parseItemsText(itemsText), money = money }
        end

        list[#list + 1] = {
            text = tostring(row.question or ""),
            options = options,
            correct = tonumber(row.answer_index) or 1,
            answer = nil,
            labels = (#labels >= 2) and labels or nil,
            reward = reward,
            fromDb = true,
            dbId = tonumber(row.id) or 0,
        }
    end

    logInfo("已从数据库载入 %d 道题目。", #list)
    return list
end

-- 答对记录（面板排行榜读这张表）
local function recordWinner(player, question, reward)
    if not DB.available then
        return
    end

    local money = 0
    if type(reward) == "table" then
        money = math.floor(tonumber(reward.money) or 0)
    end

    dbExec(string.format(
        "INSERT INTO `%s`.`trivia_reward_winners` (`guid`,`name`,`wins`,`total_money`,`last_win_at`,`last_question`) "
            .. "VALUES (%d,'%s',1,%d,%d,'%s') ON DUPLICATE KEY UPDATE `name`=VALUES(`name`), "
            .. "`wins`=`wins`+1, `total_money`=`total_money`+VALUES(`total_money`), "
            .. "`last_win_at`=VALUES(`last_win_at`), `last_question`=VALUES(`last_question`);",
        dbName(), player:GetGUIDLow(), dbEscape(player:GetName()), money, now(),
        dbEscape(question and question.text or "")))
end

--================================================================= 题目准备
local FULLWIDTH_SPACE = "\227\128\128" -- U+3000 全角空格

local function normalizeText(text)
    local s = tostring(text or "")
    s = s:gsub(FULLWIDTH_SPACE, " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- 选项标号的候选集合：写 options = { X = "…", Y = "…" } 时按这些顺序去认键
local LABEL_SETS = {
    { "A", "B", "C", "D", "E", "F", "G", "H" },
    { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛" },
    { "1", "2", "3", "4", "5", "6", "7", "8" },
}

-- 把 { A = "选项A", B = "选项B", … } 或 { 甲 = "…", 乙 = "…", … } 这类"带标号的选项表"转成数组
-- 返回 选项数组, 命中的标号表；认不出来返回 nil, nil
local function optionsFromKeys(tbl, preferredLabels)
    local sets = {}
    if type(preferredLabels) == "table" and #preferredLabels > 0 then
        sets[#sets + 1] = preferredLabels
    end
    for i = 1, #LABEL_SETS do
        sets[#sets + 1] = LABEL_SETS[i]
    end

    for s = 1, #sets do
        local labels = sets[s]
        local out = {}
        for i = 1, #labels do
            local key = labels[i]
            local v = tbl[key]
            if v == nil and type(key) == "string" then
                v = tbl[string.lower(key)]
            end
            if v == nil or type(v) ~= "string" then
                break
            end
            out[#out + 1] = v
        end
        if #out >= 2 then
            return out, labels
        end
    end

    return nil, nil
end

-- 判断两组标号是否等价（按内容比较；配置里的 { "A","B","C","D" } 与内置表是两个不同的 table，不能比地址）
local function sameLabels(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end
    for i = 1, #a do
        if tostring(a[i]) ~= tostring(b[i]) then
            return false
        end
    end
    return true
end

-- 某道题第 i 个选项用的标号
local function labelFor(q, i)
    if q ~= nil and type(q.labels) == "table" then
        local own = q.labels[i]
        if own ~= nil and tostring(own) ~= "" then
            return tostring(own)
        end
    end

    local labels = TR.Config.optionLabels
    if type(labels) == "table" then
        local v = labels[i]
        if v ~= nil and tostring(v) ~= "" then
            return tostring(v)
        end
    end

    return string.char(string.byte("A") + i - 1) -- 兜底 A/B/C/D…
end

-- "A / B / C / D" 这样的标号串，用于自动生成的作答提示
local function labelsText(q)
    local n = 4
    if q ~= nil and type(q.options) == "table" and #q.options > 0 then
        n = #q.options
    end
    if n > 8 then
        n = 8
    end
    local parts = {}
    for i = 1, n do
        parts[#parts + 1] = labelFor(q, i)
    end
    return table.concat(parts, " / ")
end

-- 规范化一道题：支持简写、answer 文本答案、选项字母表；返回 题目 或 nil, 原因
local function normalizeQuestion(q, index)
    if type(q) ~= "table" then
        return nil, "题目必须是 table"
    end

    -- 简写：{ "题干", {"A","B","C","D"}, 2 } 或 { "题干", {...}, "答案文本" }
    if q.text == nil and type(q[1]) == "string" then
        q.text = q[1]
        q.options = q.options or q[2]
        local third = q[3]
        if q.correct == nil and q.answer == nil and third ~= nil then
            if type(third) == "number" then
                q.correct = third
            elseif type(third) == "string" then
                q.answer = third
            else
                q.reward = q.reward or third
            end
        end
        if q.reward == nil and q[4] ~= nil then
            q.reward = q[4]
        end
    end

    if type(q.text) ~= "string" or q.text == "" then
        return nil, "缺少题干 text"
    end

    if type(q.options) == "table" and #q.options == 0 then
        local opts, labels = optionsFromKeys(q.options, TR.Config.optionLabels)
        if opts == nil then
            return nil, "选项表认不出来：请写成数组 { \"甲\", \"乙\", \"丙\", \"丁\" }，或用 [\"甲\"]=\"…\"、A=\"…\"、[\"1\"]=\"…\" 之一作为键（中文标号必须带方括号）"
        end
        q.options = opts
        -- 只有当题目用了"非默认"标号（比如 甲/乙/丙/丁）时才记住它；
        -- 用 A/B/C/D 或 1/2/3/4 当键的题目仍然跟随全局 Config.optionLabels
        local isDefault = sameLabels(labels, TR.Config.optionLabels)
            or sameLabels(labels, LABEL_SETS[1])
            or sameLabels(labels, LABEL_SETS[3])
        if not isDefault then
            q.labels = q.labels or labels
        end
    end
    if type(q.options) ~= "table" or #q.options < 2 then
        return nil, "缺少选项 options（至少 2 个）"
    end

    local n = #q.options

    -- answer 文本答案 → correct 下标
    if type(q.answer) == "string" and q.answer ~= "" then
        local target = string.lower(normalizeText(q.answer))
        local found = nil
        for i = 1, n do
            if string.lower(normalizeText(q.options[i])) == target then
                found = i
                break
            end
        end
        if found == nil then
            -- answer 也可以直接写标号（A / 甲 / 3）
            local labels = q.labels or TR.Config.optionLabels
            if type(labels) == "table" then
                for i = 1, n do
                    if labels[i] ~= nil and string.lower(normalizeText(tostring(labels[i]))) == target then
                        found = i
                        break
                    end
                end
            end
        end
        if found == nil then
            local letter = target:match("^([a-h])$")
            if letter then
                found = string.byte(letter) - string.byte("a") + 1
            end
        end
        if found == nil or found > n then
            return nil, string.format("答案「%s」不在选项里", tostring(q.answer))
        end
        q.correct = found
    end

    if type(q.correct) ~= "number" or q.correct < 1 or q.correct > n then
        return nil, string.format("correct 必须是 1-%d 的数字，或提供 answer = \"答案文本\"", n)
    end

    return q
end

-- 题库为空时把内置题库导入一次（之后题库以数据库为准，改题走面板或模板导入）
function seedQuestionsIfEmpty()
    if not DB.available then
        return 0
    end

    local row = dbRow(string.format("SELECT COUNT(*) AS `c` FROM `%s`.`trivia_reward_questions`;", dbName()))
    if row == nil or (tonumber(row.c) or 0) > 0 then
        return 0
    end

    if TR.Config.useBuiltinQuestions == false then
        logInfo("题库为空，且 use_builtin_questions = 0：跳过种子题库导入。")
        return 0
    end

    local seeded = 0
    -- 种子来源：内置题库 + 文件里仍写着的题目（保证迁移过来的老配置不丢题）
    local sources = {
        { list = TR.BuiltinQuestions, label = "内置题库" },
        { list = TR.Questions, label = "文件题库" },
    }

    for s = 1, #sources do
        local list = sources[s].list
        if type(list) == "table" then
            for i = 1, #list do
                local normalized, err = normalizeQuestion(list[i], i)
                if normalized ~= nil then
                    insertQuestionRow(normalized, seeded + 1)
                    seeded = seeded + 1
                else
                    logError("%s 第 %d 题无法导入数据库：%s", sources[s].label, i, tostring(err))
                end
            end
        end
    end

    if seeded > 0 then
        logInfo("已把 %d 道种子题目导入 %s.trivia_reward_questions（之后题库以数据库为准）。", seeded, dbName())
    end

    return seeded
end

-- 把所有来源汇总成最终题库（第一次使用时执行，保证所有脚本都已加载完）
local function prepareQuestions()
    if TR.prepared then
        return
    end
    TR.prepared = true

    local cfg = TR.Config
    local list = {}
    local builtinCount, customCount, dbCount = 0, 0, 0

    local function addAll(src, label, isBuiltin)
        if type(src) ~= "table" then
            return 0
        end
        local ok = 0
        for i = 1, #src do
            local q, err = normalizeQuestion(src[i], i)
            if q then
                q.builtin = isBuiltin and true or nil
                list[#list + 1] = q
                ok = ok + 1
            else
                logError("%s 第 %d 题被忽略：%s", label, i, tostring(err))
            end
        end
        return ok
    end

    -- 面板数据表：先读设置（数据库权威）→ 再补齐首次数据 → 最后读题库
    TR.DbQuestions = {}
    if cfg.useDatabase ~= false and cfg.dbName then
        if ensureSchema() then
            loadSettingsFromDb()
            seedDefaults()
            loadPresetsFromDb()
            TR.DbQuestions = loadQuestionsFromDb()
        end
    end

    -- 载入数据库设置后，选项标号可能变化：先校验标号，再解析作答频道
    if type(cfg.optionLabels) ~= "table" or #cfg.optionLabels < 2 then
        logError("optionLabels 配置无效（应为至少 2 个标号的数组，例如 { \"甲\", \"乙\", \"丙\", \"丁\" }），已退回 A/B/C/D。")
        cfg.optionLabels = { "A", "B", "C", "D" }
    end
    if type(cfg.optionFormat) ~= "string" or not cfg.optionFormat:find("%%s") then
        logError("optionFormat 配置无效（应含两个 %%s，例如 \"%%s) %%s\"），已退回默认值。")
        cfg.optionFormat = "%s) %s"
    end

    TR.AnswerChannelIds = resolveAnswerChannelIds()

    if DB.available then
        -- 题库以数据库为准：只读 trivia_reward_questions
        dbCount = addAll(TR.DbQuestions, "数据库题库", false)
        if dbCount == 0 then
            logError("数据库题库是空的，本次不会出题。请在 AGMP 的「聊天答题」页新增题目或导入模板。")
        end
    else
        -- 数据库不可用时的兜底：内置题库 + 文件配置
        logError("数据库不可用，本次使用内置题库 + 文件配置出题（改动请等数据库恢复后在面板里做）。")
        if cfg.useBuiltinQuestions ~= false then
            builtinCount = addAll(TR.BuiltinQuestions, "内置题库", true)
        end
        customCount = addAll(TR.Questions, "文件题库", false)
    end

    TR.ActiveQuestions = list
    TR.builtinCount = builtinCount
    TR.customCount = customCount
    TR.dbCount = dbCount
    TR.bag = {}

    PrintInfo(string.format("[答题] 题库准备完成：共 %d 题（内置 %d + 文件 %d + 数据库 %d）；作答频道 %d 个；选项标号 %s。",
        #list, builtinCount, customCount, dbCount, #TR.AnswerChannelIds, labelsText()))

    if #list == 0 then
        logError("题库为空，答题系统不会出题。请在 AGMP 的「聊天答题」页新增题目或导入模板。")
    end
end

-- 自动生成"在哪里作答"的提示（Config.answerHint 非空时以它为准）
local function buildAnswerHint(q)
    local cfg = TR.Config
    if type(cfg.answerHint) == "string" and cfg.answerHint ~= "" then
        return cfg.answerHint
    end

    local places = {}
    if cfg.answerSay then places[#places + 1] = "普通说话(/s)" end
    if cfg.answerYell then places[#places + 1] = "喊话(/y)" end
    if cfg.answerEmote then places[#places + 1] = "表情(/e)" end

    local ids = TR.AnswerChannelIds or {}
    for i = 1, #ids do
        places[#places + 1] = channelLabel(ids[i])
    end
    if cfg.answerWhisper then places[#places + 1] = "悄悄话(/w)" end

    if #places == 0 then
        return "（当前没有开启任何作答频道，请在面板「聊天答题 → 设置」里开启 answerSay / answerChannelIds）"
    end

    local hint = "在 " .. table.concat(places, " 或 ") .. " 中输入 " .. labelsText(q)
    if cfg.allowNumberAnswer then
        local n = 4
        if q ~= nil and type(q.options) == "table" and #q.options > 0 then
            n = math.min(#q.options, 8)
        end
        local nums = {}
        for i = 1, n do
            nums[#nums + 1] = tostring(i)
        end
        hint = hint .. "（或 " .. table.concat(nums, " / ") .. "）"
    end
    hint = hint .. " 即可作答"
    if type(cfg.answerPrefix) == "string" and cfg.answerPrefix ~= "" then
        hint = hint .. "，注意需要加前缀 " .. cfg.answerPrefix
    end
    return hint
end

--================================================================= 奖励
local function itemLink(entry)
    local locale = tonumber(TR.Config.itemLinkLocale) or 0
    if locale < 0 or locale > 8 then
        locale = 0
    end
    return GetItemLink(entry, locale)
end

local function getPreset(name)
    local p = TR.RewardPresets[name]
    if type(p) == "table" then
        return p
    end
    return nil
end

-- 过滤出真正存在的物品，返回 {{entry=, count=}, ...}
-- 支持的写法：{ 33470 } / { { 33470, 5 } } / { { entry = 33470, count = 5 } }
local function buildItemList(reward)
    local list = {}
    if type(reward) ~= "table" or type(reward.items) ~= "table" then
        return list
    end

    for i = 1, #reward.items do
        local it = reward.items[i]
        local entry, count

        if type(it) == "number" then
            entry, count = it, 1
        elseif type(it) == "table" then
            entry = tonumber(it.entry or it[1] or it.item or it.id)
            count = tonumber(it.count or it[2] or it.amount) or 1
        end

        if entry and entry > 0 then
            if GetItemTemplate(entry) == nil then
                logError("奖励物品 %d 不存在，已跳过。", entry)
            else
                if count < 1 then
                    count = 1
                end
                list[#list + 1] = { entry = entry, count = count }
                if #list >= 12 then -- 一封邮件最多 12 种物品
                    break
                end
            end
        else
            logError("奖励物品配置无法解析（第 %d 项），已跳过。", i)
        end
    end

    return list
end

local function coinText(copper)
    copper = tonumber(copper) or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "金" end
    if s > 0 then parts[#parts + 1] = s .. "银" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "铜" end
    return table.concat(parts)
end

local function fillTemplate(template, map)
    local out = tostring(template or "")
    out = out:gsub("{(%w+)}", function(key)
        local v = map[key]
        if v == nil then
            return "{" .. key .. "}"
        end
        return tostring(v)
    end)
    return out
end

-- 题目/回合的奖励：字符串=预设名，数字=金钱(铜)，table=奖励本体
local function resolveReward(q)
    local cfg = TR.Config

    if cfg.rewardMode == "pool" and type(cfg.poolPresets) == "table" and #cfg.poolPresets > 0 then
        local name = cfg.poolPresets[math.random(#cfg.poolPresets)]
        return getPreset(name) or getPreset(cfg.defaultRewardPreset)
    end

    local r = q and q.reward
    if r == nil then
        return getPreset(cfg.defaultRewardPreset)
    end
    if type(r) == "string" then
        local p = getPreset(r)
        if p == nil then
            logError("奖励预设「%s」不存在，改用默认预设「%s」。", r, tostring(cfg.defaultRewardPreset))
        end
        return p or getPreset(cfg.defaultRewardPreset)
    end
    if type(r) == "number" then
        return { money = r }
    end
    if type(r) == "table" then
        return r
    end
    return getPreset(cfg.defaultRewardPreset)
end

local function describeReward(reward)
    local parts = {}

    if type(reward) == "table" then
        local items = buildItemList(reward)
        for i = 1, #items do
            parts[#parts + 1] = string.format("%s x%d", itemLink(items[i].entry), items[i].count)
        end
        local money = tonumber(reward.money) or 0
        if money > 0 then
            parts[#parts + 1] = coinText(money)
        end
    end

    if #parts == 0 then
        return "（未配置奖励）"
    end

    return table.concat(parts, "、")
end

local function sendRewardMail(player, q, reward)
    local cfg = TR.Config
    local items = buildItemList(reward)
    local money = 0
    if type(reward) == "table" then
        money = tonumber(reward.money) or 0
    end

    local body = fillTemplate(cfg.mailBody, {
        question = q.text,
        answer = q.options[q.correct] or "?",
        player = player:GetName(),
    })

    -- SendMail(subject, text, receiverGUIDLow, senderGUIDLow, stationery, delay, money, cod, entry, amount, ...)
    local args = {
        cfg.mailSubject, body, player:GetGUIDLow(), cfg.senderGUID, cfg.mailStationery, 0, money, 0,
    }
    for i = 1, #items do
        args[#args + 1] = items[i].entry
        args[#args + 1] = items[i].count
    end

    local unpackFn = table.unpack or unpack
    SendMail(unpackFn(args))
end

--================================================================= 广播
local function broadcast(line)
    SendWorldMessage(line)
end

local function broadcastAll(lines)
    for i = 1, #lines do
        broadcast(lines[i])
    end
end

local function buildQuestionLines(q, qno, remainSeconds, reward)
    local cfg = TR.Config
    local o = q.options
    local fmt = tostring(cfg.optionFormat or "%s) %s")

    -- 每行放两个选项，标号由 Config.optionLabels（或题目自带的标号）决定
    local function optionPair(left, right)
        local text = string.format(fmt, labelFor(q, left), o[left] or "?")
        if right ~= nil and o[right] ~= nil then
            text = text .. "    " .. string.format(fmt, labelFor(q, right), o[right])
        end
        return cfg.prefix .. text
    end

    local lines = {}
    lines[#lines + 1] = string.format("%s第 %d 题：%s", cfg.prefix, qno, q.text)
    local i = 1
    while i <= #o do
        lines[#lines + 1] = optionPair(i, (i + 1 <= #o) and (i + 1) or nil)
        i = i + 2
    end

    if remainSeconds then
        lines[#lines + 1] = string.format("%s%s，剩余 %d 秒。奖励：%s",
            cfg.prefix, buildAnswerHint(q), remainSeconds, describeReward(reward))
    else
        lines[#lines + 1] = string.format("%s%s，限时 %d 秒。奖励：%s",
            cfg.prefix, buildAnswerHint(q), cfg.answerSeconds, describeReward(reward))
    end

    return lines
end

--================================================================= 答案匹配
local TRAILING_SEPARATORS = { ".", ",", ")", "]", ":", ">", "-", "、", "）", "】", "。", "：", "，" }

local function stripTrailingSeparators(s)
    local changed = true
    while changed and #s > 1 do
        changed = false
        for i = 1, #TRAILING_SEPARATORS do
            local sep = TRAILING_SEPARATORS[i]
            if #s > #sep and s:sub(-#sep) == sep then
                s = s:sub(1, #s - #sep)
                changed = true
            end
        end
    end
    return s
end

-- 按一组标号匹配答案（支持 甲/乙/丙/丁 这类中文标号）
local function matchAgainstLabels(labels, candidate, n)
    if type(labels) ~= "table" then
        return nil
    end
    for i = 1, n do
        local lb = labels[i]
        if lb ~= nil then
            lb = string.lower(normalizeText(tostring(lb)))
            if lb ~= "" and lb == candidate then
                return i
            end
        end
    end
    return nil
end

-- 返回 1-4 表示选项下标，nil 表示这句话不是有效答案
local function matchAnswer(msg, q)
    local cfg = TR.Config
    local s = string.lower(normalizeText(msg))
    if s == "" then
        return nil
    end

    local prefix = string.lower(tostring(cfg.answerPrefix or ""))
    if prefix ~= "" then
        if s:sub(1, #prefix) ~= prefix then
            return nil
        end
        s = normalizeText(s:sub(#prefix + 1))
        if s == "" then
            return nil
        end
    end

    local n = #q.options
    local candidate = s

    if cfg.allowLooseLetter then
        candidate = stripTrailingSeparators(s)
    end

    -- ① 题目自带的标号（选项用 甲=… 之类写的）→ ② 配置的标号（Config.optionLabels）
    local hit = matchAgainstLabels(q.labels, candidate, n)
    if hit == nil then
        hit = matchAgainstLabels(cfg.optionLabels, candidate, n)
    end
    if hit then
        return hit
    end

    -- ③ 拉丁字母 A/B/C/D（按位置），可用 allowLatinLetters = false 关掉
    if cfg.allowLatinLetters ~= false then
        local letter = candidate:match("^([a-h])$")
        if letter then
            local pos = string.byte(letter) - string.byte("a") + 1
            if pos <= n then
                return pos
            end
        end
    end

    -- ④ 数字 1/2/3/4
    if cfg.allowNumberAnswer then
        local num = tonumber(candidate:match("^(%d)$"))
        if num and num >= 1 and num <= n then
            return num
        end
    end

    -- ⑤ 选项全文
    if cfg.allowTextAnswer then
        for i = 1, n do
            if string.lower(normalizeText(q.options[i])) == s then
                return i
            end
        end
    end

    return nil
end

--================================================================= 回合调度
local round = {
    active = false,
    index = nil,
    question = nil,
    questionNo = 0,
    reward = nil,
    startedAt = 0,
    deadlineAt = 0,
    lastRemindAt = 0,
    attempts = {},
}
TR.round = round

TR.roundCounter = TR.roundCounter or 0
TR.bag = TR.bag or {}
TR.stats = TR.stats or {}
TR.nextRoundAt = TR.nextRoundAt or 0
TR.paused = TR.paused or false

local function pickQuestion(optIndex)
    local bank = TR.ActiveQuestions or {}
    if optIndex and bank[optIndex] then
        return optIndex, bank[optIndex]
    end

    -- 洗牌袋：把所有题目打乱后逐题取用，取完再重新洗牌，避免连续重复
    if #TR.bag == 0 then
        TR.bag = {}
        for i = 1, #bank do
            TR.bag[#TR.bag + 1] = i
        end
        for i = #TR.bag, 2, -1 do
            local j = math.random(i)
            TR.bag[i], TR.bag[j] = TR.bag[j], TR.bag[i]
        end
    end

    local idx = table.remove(TR.bag)
    return idx, bank[idx]
end

local function finishRound(winner, reason)
    if not round.active then
        return
    end

    local cfg = TR.Config
    local q = round.question
    local answer = (q and q.options[q.correct]) or "?"
    -- 奖励在出题时就已经确定，发奖时直接用同一份，保证播报与实际发放一致
    local reward = round.reward

    round.active = false
    round.question = nil
    round.index = nil
    round.reward = nil
    TR.nextRoundAt = now() + cfg.intervalSeconds

    if winner then
        local guid = winner:GetGUIDLow()
        local st = TR.stats[guid]
        if st == nil then
            st = { name = winner:GetName(), wins = 0 }
            TR.stats[guid] = st
        end
        st.name = winner:GetName()
        st.wins = st.wins + 1

        local granted, err = pcall(sendRewardMail, winner, q, reward)
        if granted then
            broadcast(string.format("%s恭喜玩家 |cff00ff00%s|r 第一个答对！正确答案是「%s」，奖励已通过邮件发放，请查收。",
                cfg.winPrefix, winner:GetName(), answer))
        else
            logError("给 %s 发放奖励邮件失败: %s", winner:GetName(), tostring(err))
            broadcast(string.format("%s恭喜玩家 |cff00ff00%s|r 第一个答对！正确答案是「%s」（奖励邮件发送异常，请联系管理员）。",
                cfg.winPrefix, winner:GetName(), answer))
        end

        -- 面板排行榜：写入 ac_eluna.trivia_reward_winners（数据库不可用时自动跳过）
        local recorded, recordErr = pcall(recordWinner, winner, q, reward)
        if not recorded then
            logError("记录答对排行失败: %s", tostring(recordErr))
        end

        logInfo("%s 答对了第 %d 题（%s）。", winner:GetName(), round.questionNo, answer)
    elseif reason == "timeout" then
        broadcast(string.format("%s时间到，本题无人答对。正确答案是「%s」，下一题稍后继续。", cfg.prefix, answer))
        logInfo("第 %d 题超时，答案 %s。", round.questionNo, answer)
    elseif reason == "stopped" then
        broadcast(string.format("%s本题已被管理员取消。正确答案是「%s」。", cfg.prefix, answer))
        logInfo("第 %d 题被管理员取消。", round.questionNo)
    elseif reason == "scheduled" then
        broadcast(string.format("%s答题活动到点了，本题提前结束。正确答案是「%s」。", cfg.winPrefix, answer))
        logInfo("第 %d 题因定时计划结束而提前收尾。", round.questionNo)
    end
end

local function startRound(optIndex, force)
    local cfg = TR.Config

    if not cfg.enabled then
        return false, "答题系统已关闭（Config.enabled = false，或用 .trivia enable 打开）"
    end
    if round.active then
        return false, "已有一题正在进行"
    end

    prepareQuestions()

    if #(TR.ActiveQuestions or {}) == 0 then
        return false, "题库为空"
    end
    if not force and GetPlayerCount() < cfg.minPlayersOnline then
        return false, "在线人数不足"
    end

    local idx, q = pickQuestion(optIndex)
    if q == nil then
        return false, "题目不存在"
    end

    TR.roundCounter = TR.roundCounter + 1

    round.active = true
    round.index = idx
    round.question = q
    round.questionNo = TR.roundCounter
    round.reward = resolveReward(q)
    round.startedAt = now()
    round.deadlineAt = round.startedAt + cfg.answerSeconds
    round.lastRemindAt = round.startedAt
    round.attempts = {}

    broadcastAll(buildQuestionLines(q, round.questionNo, nil, round.reward))
    logInfo("第 %d 题开始（题库下标 %d）：%s", round.questionNo, idx, q.text)

    return true
end

--================================================================= 作答处理
local function handleAnswer(player, msg, source)
    local cfg = TR.Config

    if not round.active or player == nil then
        return
    end
    if now() > round.deadlineAt then
        return
    end
    if cfg.ignoreGMs and player:IsGM() then
        return
    end
    if cfg.gmRankExempt > 0 and player:GetGMRank() >= cfg.gmRankExempt then
        return
    end
    if player:GetLevel() < cfg.minLevel then
        return
    end

    -- 先判断这句话是不是一个有效答案（闲聊不消耗机会）
    local choice = matchAnswer(msg, round.question)
    if choice == nil then
        return
    end

    local guid = player:GetGUIDLow()
    local attempts = round.attempts[guid] or 0
    local maxAttempts = tonumber(cfg.attemptsPerPlayer) or 1

    -- 机会用尽的玩家不能再作答（<= 0 表示不限次数）
    if maxAttempts > 0 and attempts >= maxAttempts then
        if cfg.replyAlreadyAnswered then
            player:SendBroadcastMessage(string.format("%s本题你的作答机会已经用完了。", cfg.prefix))
        end
        return
    end

    round.attempts[guid] = attempts + 1

    if choice == round.question.correct then
        logInfo("%s 通过 %s 提交了正确答案。", player:GetName(), tostring(source or "聊天"))
        finishRound(player, "winner")
        return
    end

    if maxAttempts > 0 and (attempts + 1) >= maxAttempts then
        if cfg.replyAlreadyAnswered then
            player:SendBroadcastMessage(string.format("%s很遗憾，答案不正确。", cfg.prefix))
        end
    elseif cfg.replyWrongAnswer then
        player:SendBroadcastMessage(string.format("%s答案不正确，再想想？", cfg.prefix))
    end
end

--================================================================= 事件回调
-- ChatMsg（SharedDefines.h）: SAY=1 YELL=6 EMOTE=10
local CHAT_MSG_SAY = 1
local CHAT_MSG_YELL = 6
local CHAT_MSG_EMOTE = 10

local PLAYER_EVENT_ON_LOGIN = 3
local PLAYER_EVENT_ON_CHAT = 18
local PLAYER_EVENT_ON_WHISPER = 19
local PLAYER_EVENT_ON_CHANNEL_CHAT = 22
local PLAYER_EVENT_ON_COMMAND = 42

-- 让回调永不向引擎抛错：ALE 的 CallOneFunction 在回调出错时只会压入 1 个错误值，
-- 而 OnChat 等钩子会无条件 lua_pop(2)，栈不匹配时可能影响同一事件上其它脚本的处理。
local function guard(name, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        logError("%s 回调异常: %s", name, tostring(result))
        return nil
    end
    return result
end

-- 判断这条聊天是否属于"允许作答的说话方式"
local function isAcceptedChatType(chatType)
    local cfg = TR.Config
    if chatType == CHAT_MSG_SAY then
        return cfg.answerSay == true
    end
    if chatType == CHAT_MSG_YELL then
        return cfg.answerYell == true
    end
    if chatType == CHAT_MSG_EMOTE then
        return cfg.answerEmote == true
    end
    return false
end

local function isAcceptedChannel(channelId)
    local ids = TR.AnswerChannelIds or {}
    local id = tonumber(channelId)
    if id == nil then
        return false
    end
    for i = 1, #ids do
        if ids[i] == id then
            return true
        end
    end
    return false
end

-- 指令消息（.xxx / !xxx）不算作答；但如果答案前缀本身就是这个字符，则放行
local function looksLikeCommand(msg)
    local head = msg:sub(1, 1)
    if head ~= "." and head ~= "!" then
        return false
    end
    return head ~= tostring(TR.Config.answerPrefix or ""):sub(1, 1)
end

local function onChatImpl(event, player, msg, chatType, lang)
    local cfg = TR.Config
    if not cfg.enabled or not round.active or type(msg) ~= "string" then
        return
    end
    if not isAcceptedChatType(chatType) then
        return
    end
    if looksLikeCommand(msg) then
        return
    end

    handleAnswer(player, msg, "说话")
end

local function onWhisperImpl(event, player, msg, chatType, lang, receiver)
    local cfg = TR.Config
    if not cfg.enabled or not cfg.answerWhisper or not round.active or type(msg) ~= "string" then
        return
    end
    if looksLikeCommand(msg) then
        return
    end

    handleAnswer(player, msg, "悄悄话")
end

local function onChannelChatImpl(event, player, msg, chatType, lang, channelId)
    local cfg = TR.Config

    -- 频道扫描：把频道 ID 打到日志并私聊发起扫描的 GM，方便确认自定义频道 ID
    if TR.chanScanUntil and now() <= TR.chanScanUntil then
        local line = string.format("[答题] 频道扫描: 玩家=%s 频道ID=%s 内容=%s",
            tostring(player and player:GetName() or "?"), tostring(channelId), tostring(msg))
        PrintInfo(line)
        if TR.chanScanBy then
            local gm = GetPlayerByName(TR.chanScanBy)
            if gm then
                gm:SendBroadcastMessage(string.format("%s频道扫描：频道ID=%s（%s）来自 %s",
                    cfg.prefix, tostring(channelId), channelLabel(tonumber(channelId) or 0),
                    tostring(player and player:GetName() or "?")))
            end
        end
    end

    if not cfg.enabled or not round.active or type(msg) ~= "string" then
        return
    end
    if not isAcceptedChannel(channelId) then
        return
    end
    if looksLikeCommand(msg) then
        return
    end

    handleAnswer(player, msg, "频道 " .. tostring(channelId))
end

local function onLoginImpl(event, player)
    local cfg = TR.Config
    if not cfg.enabled or not cfg.announceOnLogin or not round.active then
        return
    end
    if cfg.ignoreGMs and player:IsGM() then
        return
    end

    local remain = round.deadlineAt - now()
    if remain <= 0 then
        return
    end

    local lines = buildQuestionLines(round.question, round.questionNo, remain, round.reward)
    for i = 1, #lines do
        player:SendBroadcastMessage(lines[i])
    end
end

--================================================================= 定时启停计划
-- 面板里配的"每天 8:00-9:00 开启答题"就是这块。
-- 纯函数部分（解析/判定）不依赖任何运行状态，方便离线测试。
local SCHEDULE_DAY_NAMES = {
    ["mon"] = 1, ["tue"] = 2, ["wed"] = 3, ["thu"] = 4, ["fri"] = 5, ["sat"] = 6, ["sun"] = 7,
    ["一"] = 1, ["二"] = 2, ["三"] = 3, ["四"] = 4, ["五"] = 5, ["六"] = 6, ["日"] = 7, ["天"] = 7,
}

-- "08:00-09:00" / "8:00-9:00" → from, to（分钟）
local function parseClockRange(text)
    local h1, m1, h2, m2 = tostring(text):match("^(%d%d?):(%d%d)%s*%-%s*(%d%d?):(%d%d)$")
    if h1 == nil then
        return nil
    end
    h1, m1, h2, m2 = tonumber(h1), tonumber(m1), tonumber(h2), tonumber(m2)
    if h1 > 23 or h2 > 23 or m1 > 59 or m2 > 59 then
        return nil
    end
    return (h1 * 60 + m1), (h2 * 60 + m2)
end

local function formatClockRange(fromMin, toMin)
    return string.format("%02d:%02d-%02d:%02d", math.floor(fromMin / 60), fromMin % 60, math.floor(toMin / 60), toMin % 60)
end

-- 星期掩码 → "1,2,3,4,5"（与面板归一化后的写法一致）
local function formatDaySetText(days)
    local out = {}
    for day = 1, 7 do
        if days[day] then
            out[#out + 1] = tostring(day)
        end
    end
    return table.concat(out, ",")
end

-- 秒 → "1 小时 5 分钟" / "5 分钟" / "30 秒"
local function formatDuration(seconds)
    local s = math.max(0, math.floor(tonumber(seconds) or 0))
    if s < 60 then
        return s .. " 秒"
    end
    local minutes = math.floor(s / 60)
    if minutes < 60 then
        return minutes .. " 分钟"
    end
    local hours = math.floor(minutes / 60)
    local rest = minutes % 60
    if rest == 0 then
        return hours .. " 小时"
    end
    return hours .. " 小时 " .. rest .. " 分钟"
end

-- "1-5" / "6,7" / "mon-fri" / "一,三,五" → { [1]=true, ... }（1=周一 … 7=周日）
local function parseDaySet(text)
    local days = {}
    for chunk in tostring(text):gmatch("[^,]+") do
        chunk = chunk:lower():gsub("%s+", "")
        if chunk ~= "" then
            local a, b = chunk:match("^([^%-]+)%-([^%-]+)$")
            if a == nil then
                a, b = chunk, chunk
            end
            local from = tonumber(a) or SCHEDULE_DAY_NAMES[a]
            local to = tonumber(b) or SCHEDULE_DAY_NAMES[b]
            if from == nil or to == nil or from < 1 or from > 7 or to < 1 or to > 7 then
                return nil
            end
            local day = from
            while true do
                days[day] = true
                if day == to then
                    break
                end
                day = day % 7 + 1
            end
        end
    end
    if next(days) == nil then
        return nil
    end
    return days
end

-- 解析 scheduleWindows；非法片段直接跳过（面板侧也会校验，这里只保证不会因此崩掉）
--
-- 拆分规则（与面板的 ScheduleWindows.php 一致）：
--   * 先用 ; 与换行切成段；
--   * 段里有 @ 时，@ 之前是星期、之后是时间；时间部分再按逗号拆（共享同一组星期），
--     所以 "1-5@08:00-09:00, 20:00-22:00" = 工作日两段；星期本身可以用逗号（"6,7@..."）；
--   * 段里没有 @ 时，整个段按逗号拆成多段（每天）。
local function parseScheduleWindows(raw)
    local list = {}
    local text = tostring(raw or "")
    if type(raw) == "table" then
        text = table.concat(raw, ";")
    end

    -- 先展开成 { days = 星期掩码或 nil, time = "08:00-09:00" } 的组合
    local combos = {}
    for piece in text:gmatch("[^;\r\n]+") do
        local trimmed = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            local dayPart, timePart = nil, trimmed
            local at = trimmed:match(".*()@")   -- 贪婪匹配 = 最后一个 @
            if at ~= nil then
                dayPart = trimmed:sub(1, at - 1):gsub("^%s+", ""):gsub("%s+$", "")
                timePart = trimmed:sub(at + 1)
            end

            local days = nil
            local dayOk = true
            if dayPart ~= nil then
                days = parseDaySet(dayPart)
                if days == nil then
                    logError("定时计划「%s」的星期写法无法识别，已跳过这一段。", trimmed)
                    dayOk = false
                end
            end

            if dayOk then
                for sub in timePart:gmatch("[^,]+") do
                    sub = sub:gsub("^%s+", ""):gsub("%s+$", "")
                    if sub ~= "" then
                        combos[#combos + 1] = { days = days, time = sub, source = trimmed }
                    end
                end
            end
        end
    end

    for i = 1, #combos do
        local combo = combos[i]
        local from, to = parseClockRange(combo.time)
        if from == nil or from == to then
            logError("定时计划「%s」的时间段无法识别（应形如 08:00-09:00），已跳过这一段。", combo.source)
        else
            local label = formatClockRange(from, to)
            if combo.days ~= nil then
                label = formatDaySetText(combo.days) .. "@" .. label
            end
            list[#list + 1] = { from = from, to = to, days = combo.days, text = label }
        end
    end

    return list
end

-- 1=周一 … 7=周日（Lua 的 wday 是 1=周日）
local function isoWeekday(t)
    local wday = tonumber(os.date("%w", t)) or 0   -- 0=周日
    return wday == 0 and 7 or wday
end

local function clockMinutes(t)
    local d = os.date("*t", t)
    return (tonumber(d.hour) or 0) * 60 + (tonumber(d.min) or 0)
end

-- 这一时刻是否落在某一段里；跨夜段（22:00-02:00）按"段开始的那天"判断星期
local function windowActiveAt(t, w)
    local minutes = clockMinutes(t)
    local day = isoWeekday(t)
    if w.from < w.to then
        if w.days ~= nil and not w.days[day] then
            return false
        end
        return minutes >= w.from and minutes < w.to
    end

    -- 跨夜：今天 from 点之后，或明天 to 点之前
    if minutes >= w.from then
        return w.days == nil or w.days[day] == true
    end
    if minutes < w.to then
        local prev = day == 1 and 7 or (day - 1)
        return w.days == nil or w.days[prev] == true
    end
    return false
end

-- 返回 active, 命中的段；没有任何段命中时第二个返回值为下一次要开启的段
local function scheduleActiveAt(t, list)
    for i = 1, #list do
        if windowActiveAt(t, list[i]) then
            return true, list[i]
        end
    end
    return false, nil
end

-- 距下一次"计划状态翻转"还有多少秒（0 = 没有可用计划），只用于面板展示
local function scheduleNextChange(t, list)
    if #list == 0 then
        return 0
    end
    local active = scheduleActiveAt(t, list)
    local best = nil
    local dayStart = t - clockMinutes(t) * 60 - (tonumber(os.date("%S", t)) or 0)
    for i = 1, #list do
        for offset = 0, 7 do
            local base = dayStart + offset * 86400
            local from = base + list[i].from * 60
            local to = base + list[i].to * 60
            if list[i].from >= list[i].to then
                to = to + 86400
            end
            local candidates = active and { to } or { from }
            for c = 1, #candidates do
                local moment = candidates[c]
                if moment > t and (best == nil or moment < best) then
                    best = moment
                end
            end
        end
    end
    if best == nil then
        return 0
    end
    return best - t
end

local scheduleCache = { raw = nil, list = nil }

local function scheduleWindowsRaw()
    local value = TR.Config.scheduleWindows
    if type(value) == "table" then
        return table.concat(value, ";")
    end
    return tostring(value or "")
end

local function scheduleWindows()
    local raw = scheduleWindowsRaw()
    if scheduleCache.raw ~= raw then
        scheduleCache.raw = raw
        scheduleCache.list = parseScheduleWindows(raw)
    end
    return scheduleCache.list
end

-- 手动 enable/disable 时如果定时计划开着，提醒一句：计划会在下个 tick 覆盖手动开关
local function scheduleHint()
    if TR.Config.scheduleEnabled ~= true then
        return ""
    end
    local list = scheduleWindows()
    if #list == 0 then
        return "（注意：定时计划已启用，但还没有有效时间段）"
    end
    return "（注意：定时计划已启用，手动开关会在 1 秒内被计划覆盖，详见 .trivia schedule）"
end

local function scheduleSummaryText()
    local cfg = TR.Config
    local list = scheduleWindows()
    local parts = {}
    for i = 1, #list do
        parts[#parts + 1] = list[i].text
    end

    local state = "未启用"
    if cfg.scheduleEnabled then
        if #list == 0 then
            state = "已启用（无有效时间段）"
        else
            local active = scheduleActiveAt(now(), list)
            local nextIn = scheduleNextChange(now(), list)
            state = (active and "活动中" or "未到时间")
                .. (nextIn > 0 and ("，" .. (active and "还有 " or "距下次开启 ") .. formatDuration(nextIn)) or "")
        end
    end

    return string.format("定时启停：%s；时间段：%s；系统开关：%s；当前：%s",
        cfg.scheduleEnabled and "已启用" or "未启用",
        #parts > 0 and table.concat(parts, "，") or "（无）",
        cfg.enabled and "开" or "关",
        state)
end

-- 按计划强制开关：进入时间段自动开启，离开时间段自动结束并停题。
-- 计划开启时它的优先级高于 .trivia enable / disable（面板会给出提示）。
local function applySchedule(t)
    local cfg = TR.Config
    if not cfg.scheduleEnabled then
        TR.scheduleInfo = nil
        return
    end

    local list = scheduleWindows()
    if #list == 0 then
        TR.scheduleInfo = { active = false, window = nil, nextChange = 0, empty = true }
        return
    end

    local active, hit = scheduleActiveAt(t, list)
    local wasActive = TR.scheduleActive == true
    TR.scheduleActive = active
    TR.scheduleInfo = {
        active = active,
        window = hit and hit.text or nil,
        nextChange = scheduleNextChange(t, list),
        empty = false,
    }

    if active then
        if not cfg.enabled then
            cfg.enabled = true
            TR.paused = false
            if not round.active and (TR.nextRoundAt or 0) > t + (tonumber(cfg.resumeDelaySeconds) or 5) then
                TR.nextRoundAt = t + (tonumber(cfg.resumeDelaySeconds) or 5)
            end
            broadcast(string.format("%s答题活动已按定时计划开启（%s），祝你好运！", cfg.prefix, tostring(hit.text)))
            -- 定时计划一天只会翻转几次，属于运维事件：无条件写日志（不受 Config.debug 影响）
            PrintInfo("[答题] 定时计划：进入 " .. tostring(hit.text) .. "，已自动开启答题。")
        end
        return
    end

    if cfg.enabled then
        cfg.enabled = false
        local hadRound = round.active
        if round.active then
            finishRound(nil, "scheduled")
        end
        -- 只在"真的从活动中掉出来"时播报，避免服务器刚启动（库里开关是 1、当前不在时间段）就发一条"活动已结束"
        if wasActive or hadRound then
            local nextIn = scheduleNextChange(t, list)
            broadcast(string.format("%s本次答题活动已结束（定时计划）。%s", cfg.winPrefix,
                nextIn > 0 and ("下次开启还有 " .. formatDuration(nextIn) .. "。") or ""))
        end
        -- 定时计划一天只会翻转几次，属于运维事件：无条件写日志（不受 Config.debug 影响）
        PrintInfo("[答题] 定时计划：不在时间段内，已自动关闭答题。")
    end
end

--================================================================= 定时器
local function tickBody()
    local cfg = TR.Config

    -- 启动后第一件事：把数据表准备好（建库建表 + 首次默认值），不受 enabled 开关影响
    if TR.pendingDbBootstrap then
        TR.pendingDbBootstrap = nil
        if cfg.useDatabase ~= false then
            if ensureSchema() then
                seedDefaults()
            end
        end
    end

    local t = now()

    -- 定时计划先于开关判定：它自己会改写 cfg.enabled
    applySchedule(t)

    if not cfg.enabled then
        return
    end

    if round.active then
        if t >= round.deadlineAt then
            finishRound(nil, "timeout")
        elseif cfg.remindEverySeconds > 0 and (t - round.lastRemindAt) >= cfg.remindEverySeconds then
            round.lastRemindAt = t
            broadcastAll(buildQuestionLines(round.question, round.questionNo, round.deadlineAt - t, round.reward))
        end
        return
    end

    if TR.paused then
        return
    end

    if t < (TR.nextRoundAt or 0) then
        return
    end

    if GetPlayerCount() < cfg.minPlayersOnline then
        TR.nextRoundAt = t + cfg.idleRetrySeconds
        return
    end

    local ok = startRound(nil, false)
    if not ok then
        TR.nextRoundAt = t + cfg.idleRetrySeconds
    end
end

local function safeTick(eventId, delay, repeats)
    local ok, err = pcall(tickBody)
    if not ok then
        logError("定时器异常: %s", tostring(err))
    end
end

local function startTicker()
    if TR.timerId then
        RemoveEventById(TR.timerId)
        TR.timerId = nil
    end
    TR.timerId = CreateLuaEvent(safeTick, TR.Config.tickIntervalMs, 0)
    if TR.timerId == nil then
        logError("创建定时器失败，答题系统未启动。")
    end
end

--================================================================= 管理员指令
local function replyTo(chatHandler, player, success, message)
    local text = tostring(message or "")

    if player == nil then
        -- 控制台 / SOAP（AGMP 面板）调用：带标记，方便面板解析结果
        local marker = success and "[AGMP_OK] " or "[AGMP_ERROR] "
        if chatHandler ~= nil and chatHandler.SendSysMessage then
            chatHandler:SendSysMessage(marker .. text)
        else
            PrintInfo("[答题] " .. marker .. text)
        end
        return
    end

    if chatHandler ~= nil and chatHandler.SendSysMessage then
        chatHandler:SendSysMessage(text)
    else
        player:SendBroadcastMessage(text)
    end
end

local function splitArgs(text)
    local args = {}
    for word in string.gmatch(tostring(text or ""), "%S+") do
        args[#args + 1] = word
    end
    return args
end

local function statsText(limit)
    local list = {}
    for _, st in pairs(TR.stats) do
        list[#list + 1] = st
    end
    table.sort(list, function(a, b)
        if a.wins == b.wins then
            return tostring(a.name) < tostring(b.name)
        end
        return a.wins > b.wins
    end)

    local parts = {}
    for i = 1, #list do
        if i > limit then
            break
        end
        parts[#parts + 1] = string.format("%s(%d)", tostring(list[i].name), list[i].wins)
    end

    if #parts == 0 then
        return "本次开启以来还没有人答对过。"
    end
    return table.concat(parts, "、")
end

-- 已开启的作答来源，用于 status 展示
local function answerSourcesText()
    local cfg = TR.Config
    local parts = {}
    if cfg.answerSay then parts[#parts + 1] = "说话" end
    if cfg.answerYell then parts[#parts + 1] = "喊话" end
    if cfg.answerEmote then parts[#parts + 1] = "表情" end
    local ids = TR.AnswerChannelIds or {}
    for i = 1, #ids do
        parts[#parts + 1] = channelLabel(ids[i])
    end
    if cfg.answerWhisper then parts[#parts + 1] = "悄悄话" end
    if #parts == 0 then
        return "（无）"
    end
    return table.concat(parts, "、")
end

local function answerChannelIdsText()
    local ids = TR.AnswerChannelIds or {}
    return joinCsv(ids)
end

local function presetCount()
    local n = 0
    for _ in pairs(TR.RewardPresets) do
        n = n + 1
    end
    return n
end

-- 给面板解析用的单行 JSON（转义自己处理，脚本不依赖任何第三方库）
local function jsonEscape(value)
    local s = tostring(value == nil and "" or value)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

local function jsonString(value)
    return '"' .. jsonEscape(value) .. '"'
end

local function statusJson()
    local cfg = TR.Config
    local t = now()
    local q = round.question

    -- state 反映"此刻有没有题在跑"这个事实；enabled / paused 另行给出，面板可以同时展示
    local state = "idle"
    if not cfg.enabled then
        state = "disabled"
    elseif round.active then
        state = "running"
    elseif TR.paused then
        state = "paused"
    end

    -- 定时计划：面板靠这几个字段显示"计划生效中 / 距下次开关还有多久"
    local schedEnabled = cfg.scheduleEnabled == true
    local schedList = schedEnabled and scheduleWindows() or {}
    local schedActive = false
    local schedNext = 0
    if schedEnabled and #schedList > 0 then
        schedActive = scheduleActiveAt(t, schedList)
        schedNext = scheduleNextChange(t, schedList)
    end
    local schedParts = {}
    for i = 1, #schedList do
        schedParts[#schedParts + 1] = schedList[i].text
    end

    local parts = {
        '"ok":true',
        '"state":' .. jsonString(state),
        '"enabled":' .. tostring(cfg.enabled == true),
        '"paused":' .. tostring(TR.paused == true),
        '"round_active":' .. tostring(round.active == true),
        '"question_no":' .. tostring(tonumber(round.questionNo) or 0),
        '"question":' .. jsonString(q and q.text or ""),
        '"answer_index":' .. tostring(q and tonumber(q.correct) or 0),
        '"answer_text":' .. jsonString(q and q.options[q.correct] or ""),
        '"remaining":' .. tostring(round.active and math.max(0, round.deadlineAt - t) or 0),
        '"next_in":' .. tostring((not round.active) and math.max(0, (TR.nextRoundAt or 0) - t) or 0),
        '"schedule_enabled":' .. tostring(schedEnabled),
        '"schedule_active":' .. tostring(schedActive),
        '"schedule_valid":' .. tostring(schedEnabled and #schedList > 0),
        '"schedule_windows":' .. jsonString(table.concat(schedParts, "; ")),
        '"schedule_next_change":' .. tostring(schedNext),
        '"schedule_next_change_text":' .. jsonString(schedNext > 0 and formatDuration(schedNext) or ""),
        '"schedule_hint":' .. jsonString(scheduleHint()),
        '"bank":' .. tostring(#(TR.ActiveQuestions or {})),
        '"builtin":' .. tostring(tonumber(TR.builtinCount) or 0),
        '"custom":' .. tostring(tonumber(TR.customCount) or 0),
        '"from_db":' .. tostring(tonumber(TR.dbCount) or 0),
        '"labels":' .. jsonString(labelsText()),
        '"format":' .. jsonString(cfg.optionFormat),
        '"sources":' .. jsonString(answerSourcesText()),
        '"channel_ids":' .. jsonString(answerChannelIdsText()),
        '"online":' .. tostring(GetPlayerCount()),
        '"rounds":' .. tostring(TR.roundCounter),
        '"interval":' .. tostring(tonumber(cfg.intervalSeconds) or 0),
        '"answer_seconds":' .. tostring(tonumber(cfg.answerSeconds) or 0),
        '"attempts":' .. tostring(tonumber(cfg.attemptsPerPlayer) or 0),
        '"reward_mode":' .. jsonString(cfg.rewardMode),
        '"default_preset":' .. jsonString(cfg.defaultRewardPreset),
        '"presets":' .. tostring(presetCount()),
        '"use_db":' .. tostring(cfg.useDatabase ~= false),
        '"db":' .. tostring(DB.available == true),
        '"db_name":' .. jsonString(dbName()),
        '"ts":' .. tostring(t),
    }

    return "{" .. table.concat(parts, ",") .. "}"
end

local function onCommandImpl(event, player, command, chatHandler)
    local args = splitArgs(command)
    local name = string.lower(args[1] or "")
    -- 核心已经剥掉前导的点号/叹号，这里再兜一次底，避免版本差异导致匹配不上
    name = name:gsub("^[%.!]+", "")

    if name ~= "trivia" and name ~= "答题" then
        return -- 不是本脚本的指令，交回核心处理
    end

    local cfg = TR.Config

    if player ~= nil and player:GetGMRank() < cfg.minGMRankForCommand then
        replyTo(chatHandler, player, false, cfg.prefix .. "你没有权限使用 .trivia 指令。")
        return false
    end

    prepareQuestions()

    local sub = string.lower(args[2] or "help")

    if sub == "start" then
        local idx = tonumber(args[3])
        local ok, err = startRound(idx, true)
        if ok then
            replyTo(chatHandler, player, true, string.format("第 %d 题已开始（题库下标 %s）。",
                TR.roundCounter, tostring(idx or "随机")))
        else
            replyTo(chatHandler, player, false, "无法开始答题：" .. tostring(err))
        end
        return false
    end

    if sub == "stop" then
        if round.active then
            finishRound(nil, "stopped")
            replyTo(chatHandler, player, true, "已结束当前题目。")
        else
            replyTo(chatHandler, player, true, "当前没有正在进行的题目。")
        end
        return false
    end

    if sub == "pause" or sub == "off" then
        if TR.paused then
            replyTo(chatHandler, player, true, "自动出题已经是暂停状态（当前题目继续到结束）。")
            return false
        end
        TR.paused = true
        replyTo(chatHandler, player, true, "已暂停自动出题（当前题目继续到结束；用 .trivia resume 恢复）。")
        return false
    end

    if sub == "resume" or sub == "on" then
        local delay = tonumber(cfg.resumeDelaySeconds) or 5
        TR.paused = false
        -- 无条件把下一题提前：否则"暂停→恢复"之后还要等完整个 intervalSeconds（默认 900 秒），
        -- 面板上看起来就是"恢复按钮点了没用"。
        if not round.active and (TR.nextRoundAt or 0) > now() + delay then
            TR.nextRoundAt = now() + delay
        end
        if not cfg.enabled then
            replyTo(chatHandler, player, true, string.format(
                "已取消暂停，但答题系统当前是关闭状态（用 .trivia enable 打开）。%s", scheduleHint()))
        elseif round.active then
            replyTo(chatHandler, player, true, "已恢复自动出题（当前题目结束后 " .. tostring(cfg.intervalSeconds) .. " 秒出下一题）。")
        else
            replyTo(chatHandler, player, true, string.format("已恢复自动出题，约 %d 秒后出下一题。", delay))
        end
        return false
    end

    if sub == "enable" then
        local delay = tonumber(cfg.resumeDelaySeconds) or 5
        cfg.enabled = true
        TR.paused = false
        if not round.active and (TR.nextRoundAt or 0) > now() + delay then
            TR.nextRoundAt = now() + delay
        end
        replyTo(chatHandler, player, true, string.format("答题系统已开启，约 %d 秒后出下一题（重启服务器后以数据库里的开关为准）。%s",
            delay, scheduleHint()))
        return false
    end

    if sub == "disable" then
        cfg.enabled = false
        if round.active then
            finishRound(nil, "stopped")
        end
        replyTo(chatHandler, player, true, "答题系统已关闭（重启服务器后以数据库里的开关为准）。" .. scheduleHint())
        return false
    end

    if sub == "schedule" then
        local list = scheduleWindows()
        if not cfg.scheduleEnabled then
            replyTo(chatHandler, player, true, "定时启停：未启用。可在 AGMP 面板的聊天答题页「运行状态」里配置每天的时间段。")
        elseif #list == 0 then
            replyTo(chatHandler, player, true, "定时启停：已启用，但还没有有效的时间段。")
        else
            replyTo(chatHandler, player, true, scheduleSummaryText())
        end
        return false
    end

    if sub == "reload" then
        -- 面板改完题库/设置后调用：重新读库并重建题库（顺带重查一次表结构）
        TR.prepared = nil
        DB.checked = false
        prepareQuestions()
        replyTo(chatHandler, player, true, string.format(
            "已重新载入：共 %d 题（数据库 %d + 内置 %d + 文件 %d），奖励预设 %d 个，作答频道 %d 个。",
            #(TR.ActiveQuestions or {}), tonumber(TR.dbCount) or 0,
            tonumber(TR.builtinCount) or 0, tonumber(TR.customCount) or 0, (function()
                local n = 0
                for _ in pairs(TR.RewardPresets) do n = n + 1 end
                return n
            end)(), #(TR.AnswerChannelIds or {})))
        return false
    end

    if sub == "api" or sub == "json" then
        -- 给 AGMP 面板用的单行 JSON 状态（SOAP 调用后由面板解析）
        replyTo(chatHandler, player, true, statusJson())
        return false
    end

    if sub == "chanscan" then
        if TR.chanScanUntil and now() <= TR.chanScanUntil then
            TR.chanScanUntil = nil
            TR.chanScanBy = nil
            replyTo(chatHandler, player, true, "频道扫描已停止。")
        else
            local seconds = tonumber(args[3]) or 120
            TR.chanScanUntil = now() + seconds
            TR.chanScanBy = player and player:GetName() or nil
            replyTo(chatHandler, player, true, string.format(
                "频道扫描已开始（%d 秒）。请到目标频道里随便说一句话，我会把频道 ID 告诉你（自定义频道是负数）；结果同时写入 ALE 日志。", seconds))
        end
        return false
    end

    if sub == "chanlist" then
        local parts = {}
        local list = {}
        for name2, id in pairs(TR.ChannelNames) do
            list[#list + 1] = { name = name2, id = id }
        end
        table.sort(list, function(a, b) return a.id < b.id end)
        local seen = {}
        for i = 1, #list do
            if not seen[list[i].id] then
                seen[list[i].id] = true
                parts[#parts + 1] = string.format("%s=%d", channelLabel(list[i].id), list[i].id)
            end
        end
        replyTo(chatHandler, player, true, "内置频道：" .. table.concat(parts, "，") ..
            "；自定义频道请用 .trivia chanscan 查看（负数 ID）。")
        return false
    end

    if sub == "status" then
        local state
        if not cfg.enabled then
            state = "已关闭"
        elseif TR.paused then
            state = "已暂停"
        elseif round.active then
            state = string.format("进行中（第 %d 题，剩余 %d 秒）", round.questionNo, math.max(0, round.deadlineAt - now()))
        else
            state = string.format("空闲（下一题约 %s后）", formatDuration(math.max(0, (TR.nextRoundAt or 0) - now())))
        end
        replyTo(chatHandler, player, true, string.format(
            "状态：%s；题库：%d 题（内置 %d + 自定义 %d）；作答来源：%s；已出题：%d 次；在线：%d 人；间隔：%d 秒/题，作答：%d 秒。%s",
            state, #(TR.ActiveQuestions or {}), tonumber(TR.builtinCount) or 0, tonumber(TR.customCount) or 0,
            answerSourcesText(), TR.roundCounter, GetPlayerCount(), cfg.intervalSeconds, cfg.answerSeconds,
            scheduleSummaryText()))
        return false
    end

    if sub == "stats" then
        replyTo(chatHandler, player, true, "答对排行：" .. statsText(10))
        return false
    end

    replyTo(chatHandler, player, true,
        "用法：.trivia start [题号] | stop | pause(on/off) | resume | enable | disable | reload | schedule | api | status | stats | chanscan [秒] | chanlist")
    return false
end

--================================================================= 注册事件
-- 统一包一层 guard，保证回调异常不会影响引擎的事件分发
local function onChat(event, player, msg, chatType, lang)
    guard("onChat", onChatImpl, event, player, msg, chatType, lang)
end

local function onWhisper(event, player, msg, chatType, lang, receiver)
    guard("onWhisper", onWhisperImpl, event, player, msg, chatType, lang, receiver)
end

local function onChannelChat(event, player, msg, chatType, lang, channelId)
    guard("onChannelChat", onChannelChatImpl, event, player, msg, chatType, lang, channelId)
end

local function onLogin(event, player)
    guard("onLogin", onLoginImpl, event, player)
end

local function onCommand(event, player, command, chatHandler)
    return guard("onCommand", onCommandImpl, event, player, command, chatHandler)
end

RegisterPlayerEvent(PLAYER_EVENT_ON_CHAT, onChat)
RegisterPlayerEvent(PLAYER_EVENT_ON_WHISPER, onWhisper)
RegisterPlayerEvent(PLAYER_EVENT_ON_CHANNEL_CHAT, onChannelChat)
RegisterPlayerEvent(PLAYER_EVENT_ON_COMMAND, onCommand)
RegisterPlayerEvent(PLAYER_EVENT_ON_LOGIN, onLogin)

-- 数据表在脚本加载完成后立刻准备：第一个 tick（约 1 秒后）里建库建表并写入首次默认值。
-- 放到 tick 里而不是文件末尾，是为了确保所有脚本都已加载完，
-- 否则会把脚本内置默认值当成首次配置写进数据库。
TR.pendingDbBootstrap = true

-- 定时器无论开关都创建，这样 .trivia enable / disable 才能即时生效
TR.nextRoundAt = now() + TR.Config.firstDelaySeconds
startTicker()

if TR.Config.enabled then
    PrintInfo(string.format("[答题] 已加载，%d 秒后自动开始第一题（间隔 %d 秒/题，作答 %d 秒）。",
        TR.Config.firstDelaySeconds, TR.Config.intervalSeconds, TR.Config.answerSeconds))
else
    PrintInfo("[答题] Config.enabled = false，答题系统处于关闭状态（可用 .trivia enable 打开）。")
end
