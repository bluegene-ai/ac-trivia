--==============================================================================
--  TriviaReward_conf.lua  ——  聊天答题奖励 配置文件
--  配套脚本: TriviaReward.lua（必须放在同一个 lua_scripts 目录里）
--  本文件里的每一项都是可选的：写了的以这里为准，没写的用脚本内置默认值。
--==============================================================================
--  修改后生效方式：重启 worldserver，或在服务器控制台执行 .reload ale
--  五个部分：
--      ① 开启 / 关闭 与出题节奏
--      ② 发言频道（从哪里收答案）
--      ③ 题目与答案
--      ④ 奖励物品
--      ⑤ 播报文本与管理权限
--==============================================================================

-- 下面几行保证本文件无论先加载还是后加载都能正常覆盖配置，请保留
TriviaReward                = TriviaReward or {}
TriviaReward.Config         = TriviaReward.Config or {}
TriviaReward.Questions      = TriviaReward.Questions or {}
TriviaReward.RewardPresets  = TriviaReward.RewardPresets or {}
TriviaReward.ChannelNames   = TriviaReward.ChannelNames or {}
TriviaReward.ChannelLabels  = TriviaReward.ChannelLabels or {}


--==============================================================================
--  ① 开启 / 关闭 与出题节奏
--==============================================================================

TriviaReward.Config.enabled              = true     -- 总开关：false = 完全不出题（也可用 .trivia disable 运行时关闭）

TriviaReward.Config.firstDelaySeconds    = 60       -- 服务器启动后多少秒出第一题
TriviaReward.Config.intervalSeconds      = 900      -- 上一题结束到下一题开始之间的间隔（秒）
TriviaReward.Config.answerSeconds        = 60       -- 每题作答时间（秒），超时无人答对就公布答案
TriviaReward.Config.remindEverySeconds   = 30       -- 作答期间每隔多少秒重发一次题目（0 = 不提醒）
TriviaReward.Config.minPlayersOnline     = 1        -- 在线人数少于该值时不出题（避免空服刷公告）
TriviaReward.Config.minLevel             = 1        -- 低于该等级的角色不能作答（防小号/刷号）
TriviaReward.Config.ignoreGMs            = true     -- 开着 GM 标签的账号不参与
TriviaReward.Config.gmRankExempt         = 3        -- GM 等级 >= 该值时不参与（0 = 不限制）
TriviaReward.Config.debug                = false    -- true = 每题开始/结束、频道扫描写进 ALE 日志
TriviaReward.Config.resumeDelaySeconds   = 5        -- .trivia resume / enable 之后多少秒出下一题

-- 定时启停：按"每天的固定时间段"自动开启 / 结束答题活动（面板「运行状态」页也能改）。
--   scheduleEnabled = true 时，时间段的优先级高于 .trivia enable / disable。
--   时间段写法（分号分隔多段；不带星期前缀 = 每天；1=周一 … 7=周日）：
--       "08:00-09:00"                    每天 08:00-09:00
--       "08:00-09:00; 20:00-22:00"       每天两段
--       "1-5@08:00-09:00"                周一至周五
--       "6,7@20:00-21:00"                周六、周日
--       "22:00-02:00"                    跨夜（到第二天凌晨 2 点）
TriviaReward.Config.scheduleEnabled      = false
TriviaReward.Config.scheduleWindows      = ""       -- 例： "08:00-09:00; 20:00-22:00"


--==============================================================================
--  ② 发言频道（从哪里收答案）
--==============================================================================
--  可以同时开启多个来源，玩家在任意一个里作答都算数；
--  播报里的「在哪里作答」提示会根据这里自动生成（除非你自定义了 answerHint）。

TriviaReward.Config.answerSay            = true     -- 普通说话 /s
TriviaReward.Config.answerYell           = true     -- 喊话 /y
TriviaReward.Config.answerEmote          = false    -- 表情 /e（一般不需要）
TriviaReward.Config.answerWhisper        = false    -- 悄悄话 /w（任意私聊都会参与匹配，容易误判，谨慎开启）

-- 频道作答：留空 {} = 不接受频道发言；可以填内置频道名或频道 ID，也可以混着写。
--   内置频道名/ID（取自本服客户端 ChatChannels.dbc）:
--       综合 = 1       交易 = 2       本地防务 = 22
--       世界防务 = 23   公会招募 = 25   寻求组队 = 26
--   自定义频道（玩家自己建的「世界频道」）ID 是负数，用 .trivia chanscan 到频道里说一句话就能查到。
--   例：{ "综合", "交易" } 或 { 1, 2, -5 } 或 { "综合", -5 }
TriviaReward.Config.answerChannelIds     = { "综合" }

-- 也可以把自定义频道起个名字，之后就能像内置频道一样用名字配置
-- TriviaReward.ChannelNames["世界"] = -5
-- TriviaReward.ChannelLabels[-5]    = "世界频道"

-- 答案写法要求
TriviaReward.Config.answerPrefix         = ""       -- 要求前缀，例如 "!" 表示必须发 "!A"；空 = 不要求
TriviaReward.Config.allowLooseLetter     = true     -- 允许 "A." "A)" "A、" "A。" 这类写法
TriviaReward.Config.allowNumberAnswer    = true     -- 允许用 1 / 2 / 3 / 4 回答
TriviaReward.Config.allowLatinLetters    = true     -- 除标号外，是否仍允许用 A/B/C/D（按位置）作答
TriviaReward.Config.allowTextAnswer      = false    -- 允许直接输入选项全文（中文输入法玩家可能需要）
TriviaReward.Config.attemptsPerPlayer    = 1        -- 每题每人作答次数（1 = 一锤定音，0 = 不限）
TriviaReward.Config.replyWrongAnswer     = false    -- 答错时私聊提示（默认静默，避免刷屏）
TriviaReward.Config.replyAlreadyAnswered = true     -- 机会用完后再次作答时提示

-- ── 选项标号（默认 A/B/C/D；想改成 甲乙丙丁 就打开下面两行）──────────────────
-- optionLabels 决定播报里显示的标号，同时也决定玩家可以输入什么答案；
-- optionFormat 决定播报里每个选项的排版（两个 %s：标号、选项文本）。
-- TriviaReward.Config.optionLabels = { "甲", "乙", "丙", "丁" }
-- TriviaReward.Config.optionFormat = "%s、%s"      -- 播报效果： 甲、暴风城    乙、铁炉堡
-- 标号也可以只用 2 个（只要不比题目选项数少就行），例如 { "是", "否" } 配两道判断题。
--
-- 题目里写选项也有两种方式，都可以配合上面的标号使用：
--     options = { "暴风城", "铁炉堡", "达纳苏斯", "埃索达" }              -- 数组：标号按 optionLabels 顺序
--     options = { ["甲"] = "暴风城", ["乙"] = "铁炉堡", ["丙"] = "达纳苏斯", ["丁"] = "埃索达" }  -- 带标号的键
-- 用 甲/乙/丙/丁、A/B/C/D、1/2/3/4 当键都能被自动识别，不需要额外配置；
-- 中文/非 ASCII 标号必须写成 ["甲"] = … 的形式，直接写 甲 = … 是 Lua 语法错误。

-- 提示：如果担心玩家在综合频道闲聊时误答（比如随手打一个 "1"），
--       可以把 answerChannelIds 清空为 {}，只保留 /s；或把 attemptsPerPlayer 设为 1（默认）。


--==============================================================================
--  ③ 题库（现在存在数据库里，本文件不再放题目）
--==============================================================================
--  题库统一存在 Config.dbName（默认 ac_eluna）的 `trivia_reward_questions` 表里：
--    * 脚本加载时会自动检测：库/表不存在就建库建表；
--    * 表是空的就自动把脚本内置的 37 道题导入一次（种子题库）；
--    * 之后改题一律走 AGMP 面板「聊天答题」页（新增/编辑/启停/删除，或模板导入）；
--    * 本文件里写的题目只会在「首次导入种子题库」时被一起写进数据库，
--      数据库建好之后就不再读它了，所以请不要把题目放这里。
--
--  首次建库时是否导入内置种子题库：
TriviaReward.Config.useBuiltinQuestions  = true     -- false = 首次不导入内置题库，题库完全由面板/模板导入维护
--
--  面板里可用的题库操作：新增题目、编辑、启停、删除、CSV/JSON 模板导入、导出当前题库。
--  数据表结构（脚本自动创建/补列）：
--    trivia_reward_questions(id, question, option1..option4, answer_index, labels,
--                            reward_preset, reward_items, reward_money, enabled,
--                            sort_order, source, updated_at, created_at)


--==============================================================================
--  ④ 奖励物品
--==============================================================================
--  items 三种写法都支持，money 单位是铜（10000 铜 = 1 金）：
--      items = { 33470 }                      → 霜纹布 x1
--      items = { { 33470, 5 } }               → 霜纹布 x5
--      items = { { entry = 33470, count = 5 } }
--  一封邮件最多 12 种物品；不存在的物品 ID 会被自动跳过并写入 ALE 错误日志。
--
--  常用物品参照（本服 item_template 已确认存在）:
--      33470 霜纹布   33447 符文治疗药水   33448 符文法力药水
--      36909 钴矿石   37704 生命结晶       4306 丝绸   14047 符文布

-- 新增/覆盖奖励预设（名字随便起，题目里用 reward = "名字" 引用）
TriviaReward.RewardPresets.gold20   = { money = 200000 }                                        -- 20 金
TriviaReward.RewardPresets.heal10   = { items = { { 33447, 10 } } }                             -- 符文治疗药水 x10
TriviaReward.RewardPresets.combo    = { items = { { 33470, 5 }, { 33447, 2 } }, money = 50000 }  -- 布 + 药 + 钱

-- 题目没写 reward 时用哪个预设
TriviaReward.Config.defaultRewardPreset  = "cloth5"

-- 发奖方式："question" = 按题目各自配置；"pool" = 每次从下面的池子里随机挑一个
TriviaReward.Config.rewardMode           = "question"
TriviaReward.Config.poolPresets          = {
    "cloth5", "cloth10", "heal5", "mana5", "ore5", "gold5", "gold10", "gold20", "combo",
}

-- 邮件本身
TriviaReward.Config.senderGUID           = 10667    -- 发件人角色 low GUID（本服 RecruitAFriend 用的同一个）
TriviaReward.Config.mailStationery       = 41       -- 41 = 普通，61 = GM，62 = 拍卖行
TriviaReward.Config.itemLinkLocale       = 4        -- 物品链接语言：4 = zhCN，5 = zhTW，0 = enUS
TriviaReward.Config.mailSubject          = "答题奖励"
TriviaReward.Config.mailBody             =
    "勇士，恭喜你在聊天答题中第一个答对！\n" ..
    "题目：{question}\n" ..
    "正确答案：{answer}\n" ..
    "奖励已随信附上，祝你在艾泽拉斯的旅途愉快！"
-- 可用占位符：{question} 题干、{answer} 正确答案、{player} 角色名


--==============================================================================
--  ⑤ 播报文本与管理权限
--==============================================================================

TriviaReward.Config.prefix               = "|cff00ff00[答题]|r "     -- 普通播报前缀（绿色）
TriviaReward.Config.winPrefix            = "|cffffd200[答题]|r "     -- 中奖/公布答案前缀（金色）

-- 作答方式提示：留空 = 按第②节开启的频道自动生成（推荐）
-- 想自己写就填，例如：
-- TriviaReward.Config.answerHint        = "在综合频道输入 A / B / C / D 作答，第一个答对的发奖励！"
TriviaReward.Config.answerHint           = ""

TriviaReward.Config.announceOnLogin      = true     -- 答题期间登录的玩家，补发当前题目
TriviaReward.Config.minGMRankForCommand  = 2        -- 使用 .trivia 指令所需的最低 GM 等级
