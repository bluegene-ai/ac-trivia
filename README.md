# ac-trivia — 聊天答题奖励（AzerothCore + mod-ALE）

在世界聊天窗口做答题活动：系统出题（四个选项），玩家在已开启的频道里作答，
**第一个答对的**通过邮件发奖；配套的管理页在 [AcoreGMPanel](https://github.com/bluegene-ai/AcoreGMPanel) 的 `/trivia`。

- 运行环境：AzerothCore（WotLK 3.3.5a）+ **mod-ALE**（Lua 5.2）
- 不依赖任何第三方 Lua 库，不修改核心源码
- 题库、奖励预设、开关与节奏等**全部存在数据库**（脚本首次加载时自动建库建表并导入种子题库）

```
聊天窗口                           数据库 ac_eluna                     玩家
┌────────────────────────┐        ┌──────────────────────────┐      ┌──────────┐
│ [答题] 第 1 题：…      │        │ trivia_reward_settings   │      │ 输入 A   │
│ [答题] A) …    B) …    │  ───►  │ trivia_reward_questions  │ ◄──  │ 或 1/甲  │
│ [答题] C) …    D) …    │        │ trivia_reward_presets    │      └────┬─────┘
│ [答题] …第一个答对发奖 │        │ trivia_reward_winners    │           │
└────────────────────────┘        └──────────────────────────┘     邮件发奖 ▼
```

## 功能

| 能力 | 说明 |
|---|---|
| 自动出题 | 可配置间隔、作答时长、提醒间隔、首题延迟、最少在线人数、最低等级 |
| 定时启停 | 按"每天的固定时间段"自动开启/结束活动（`scheduleEnabled` + `scheduleWindows`，例：每天 08:00-09:00）；到点自动开始，离开时间段自动结束当前题；面板「运行状态」页可看状态与下次开关时间 |
| 作答来源 | `/s` 说话、`/y` 喊话、`/e` 表情、`/w` 悄悄话、**任意频道**（内置频道名或 ID，自定义频道用负数） |
| 答案形式 | `A/B/C/D`、`1/2/3/4`、中文标号（`甲/乙/丙/丁` 等自定义标号）、`A、`/`A.` 这类写法、可选选项全文 |
| 中奖规则 | 每题每人可作答次数可配（默认一锤定音），第一个答对者立刻全服公告并发邮件 |
| 奖励 | 奖励预设（物品 + 金钱）、题目可单独指定、奖励池随机、邮件标题/正文/发件人/信纸可配 |
| 题库 | 存数据库，可由面板增删改，或 **CSV / TSV / JSON 模板导入**（面板侧提供预览与逐行诊断） |
| 排行榜 | 答对记录写库，面板可查、可清空 |
| 管理指令 | `.trivia start [题号] / stop / pause / resume / enable / disable / reload / schedule / api / status / stats / chanscan / chanlist` |

## 安装

1. 把 `TriviaReward.lua` 与 `TriviaReward_conf.lua` 放进 worldserver 同级的 `lua_scripts/`：

   ```
   <server>/
   ├── worldserver.exe
   └── lua_scripts/
       ├── TriviaReward.lua
       └── TriviaReward_conf.lua
   ```

2. 确认 `mod_ale.conf` 里 `ALE.Enabled = true`（`ALE.ScriptPath` 默认就是 `lua_scripts`）。

3. 重启 worldserver，或在控制台执行 `.reload ale`。

首次加载时脚本会自动：

- 检测 `ac_eluna` 库与 4 张表，不存在则 `CREATE DATABASE` / `CREATE TABLE`（老表缺列会 `ALTER TABLE` 补上）；
- 表为空时写入默认设置、12 个奖励预设，并把内置的 37 道题导入 `trivia_reward_questions` 作为种子题库。

> 之后**题库与设置都只以数据库为准**：改题请在面板里改或导入模板，不用再动 `.lua` 文件；
> `TriviaReward_conf.lua` 只提供"首次建库时的默认值"。

## 配置

改 `TriviaReward_conf.lua`（或在面板 `/trivia` 里改，面板写库、改完即时生效）。常用项：

```lua
TriviaReward.Config.enabled            = true     -- 总开关
TriviaReward.Config.intervalSeconds    = 900      -- 出题间隔（秒）
TriviaReward.Config.answerSeconds      = 60       -- 每题作答时间
TriviaReward.Config.resumeDelaySeconds = 5        -- .trivia resume / enable 后多少秒出下一题
TriviaReward.Config.answerSay          = true     -- 接受 /s
TriviaReward.Config.answerYell         = true     -- 接受 /y
TriviaReward.Config.answerChannelIds   = { "综合" }  -- 接受频道（内置名或 ID；自定义频道填负数）
TriviaReward.Config.attemptsPerPlayer  = 1        -- 每题每人作答次数（0 = 不限）
TriviaReward.Config.optionLabels       = { "A", "B", "C", "D" }  -- 或 { "甲", "乙", "丙", "丁" }
TriviaReward.Config.rewardMode         = "question"  -- 或 "pool"
TriviaReward.Config.dbName             = "ac_eluna"  -- 数据表所在库

-- 定时启停：每天的固定时间段自动开关（面板「运行状态」页也能改）
TriviaReward.Config.scheduleEnabled    = false
TriviaReward.Config.scheduleWindows    = "08:00-09:00"   -- 例： "08:00-09:00; 20:00-22:00"
```

### 定时启停（scheduleWindows）写法

多段用分号（或换行、逗号）分隔；不带星期前缀 = 每天；`1`=周一 … `7`=周日：

| 写法 | 含义 |
|---|---|
| `08:00-09:00` | 每天 08:00-09:00 开启 |
| `08:00-09:00; 20:00-22:00` | 每天两段 |
| `1-5@08:00-09:00` | 周一至周五（也认 `mon-fri`） |
| `6,7@20:00-21:00` | 周六、周日 |
| `1-5@08:00-09:00, 20:00-22:00` | 工作日两段（@ 后面的逗号共用同一组星期） |
| `22:00-02:00` | 跨夜（到次日凌晨 2 点） |

`scheduleEnabled = true` 时时间段**优先于** `.trivia enable / disable`：进入时间段自动开启（全服播报一次），
离开时间段自动结束当前题并停止出题，并公告下次开启时间；计划翻转会写进 ALE 日志（不受 `debug` 影响）。

内置频道 ID（解析自客户端 `ChatChannels.dbc`）：
`综合=1`、`交易=2`、`本地防务=22`、`世界防务=23`、`公会招募=25`、`寻求组队=26`；
自定义频道（玩家自建的"世界频道"）ID 是负数，用 `.trivia chanscan` 到频道里说一句话即可查到。

## 数据表

```sql
trivia_reward_settings   -- 单行配置（面板里改的就是这些；含 schedule_enabled / schedule_windows 两个定时启停列）
trivia_reward_questions  -- 题库（id, question, option1..4, answer_index, labels,
                         --        reward_preset, reward_items, reward_money,
                         --        enabled, sort_order, source, updated_at, created_at）
trivia_reward_presets    -- 奖励预设（name, items, money, enabled）
trivia_reward_winners    -- 答对排行（guid, name, wins, total_money, last_win_at, last_question）
```

> 老版本建的 `trivia_reward_settings` 缺 `schedule_enabled` / `schedule_windows` 时，
> 脚本会在下次加载（重启 worldserver 或 `.reload ale`）时自动 `ALTER TABLE` 补上；
> 面板在这两列还没补上之前会跳过它们，不会导致整条设置保存失败。

奖励物品写法：`items = '33470:5,33447:2'`（`物品ID:数量`，逗号或分号分隔）；
`reward_money` 单位是铜（10000 = 1 金）。面板里显示中文物品名（DBC + `item_template` 双源解析）。

## 题库模板格式（面板导入用）

```
题干,选项A,选项B,选项C,选项D,答案,标号,奖励预设,奖励物品,金钱,启用
巫妖王的本名是谁？,阿尔萨斯·米奈希尔,耐奥祖,克尔苏加德,伊利丹·怒风,1,,cloth5,,0,1
暗夜精灵的主城是？,暴风城,铁炉堡,达纳苏斯,埃索达,达纳苏斯,"甲,乙,丙,丁",gold5,33470:2,50000,1
```

- 表头可选，写了就按列名认列（中英文表头都认）；也支持 TSV（直接从 Excel 复制粘贴）与 JSON
- `答案` 可写 `1-4` / `A-D` / `甲-丁` / **选项原文**
- 以 `#` 开头的行会被忽略；含逗号的字段（如标号）必须用英文引号包起来
- 面板支持「解析预览」（逐行报错，不写库）→「确认导入」（事务写库 + 自动重载）

## 与 AGMP 面板配合

[AcoreGMPanel](https://github.com/bluegene-ai/AcoreGMPanel) 的 `/trivia` 页按功能分成 5 个 Tab：
**运行状态**（实时状态 + 运行控制 + 定时计划 + 下一题倒计时）、**题库**（CRUD + 模板导入导出）、
**奖励预设**、**答对排行**、**设置**（节奏 / 定时启停 / 频道 / 奖励与邮件）。
面板通过 `config/trivia.php` 里的 `custom_db_name`（默认 `ac_eluna`）读写上面这些表。

运行控制里的「暂停/恢复」与「开启/关闭」各只有一个按钮，按实时状态切换文案与动作：

| 按钮 | 下发的指令 | 效果 |
|---|---|---|
| 出一题 | `.trivia start` | 立刻出一题（不受间隔限制） |
| 按下标出题 | `.trivia start <下标>` | 指定题库下标出题（测试用） |
| 结束当前题 | `.trivia stop` | 结束当前题（不发奖励）；下一题按 `intervalSeconds` 排期 |
| 暂停 / 恢复自动出题 | `.trivia pause` / `.trivia resume` | 暂停期间不出新题；恢复会把下一题提前到 `resumeDelaySeconds` 秒后（不会让你干等完整个间隔） |
| 重载题库 | `.trivia reload` | 重新读库（改完题库/设置后自动调用） |
| 开启 / 关闭系统 | `.trivia enable` / `.trivia disable` | 运行时开关；开启会把下一题提前。重启 worldserver 后以数据库里的 `enabled` 为准 |

> 面板需要 SOAP（`worldserver.conf` 里 `SOAP.Enabled = 1`）才能读到实时状态与下发控制指令；
> 数据库里的设置与题库在 worldserver 离线时也能照常编辑。

## 测试

仓库自带离线测试（用 [lua 5.2](https://www.lua.org/) 解释器即可，不需要开服）：

```bash
# 186 项行为断言（含内存版假数据库：建表 / 种子导入 / 读库 / 暂停恢复 / 定时启停全链路）
lua tests/test_trivia.lua TriviaReward.lua TriviaReward_conf.lua script-first
lua tests/test_trivia.lua TriviaReward.lua TriviaReward_conf.lua conf-first   # 两种加载顺序都要过

# 题库自检：按脚本自身的解析规则校验，写错的题会在这里暴露
lua tests/check_questions.lua TriviaReward.lua TriviaReward_conf.lua
```

`tests/README.md` 有更详细的说明（包括怎么把真实数据库导出成快照来校验线上的题库）。

## 许可

本仓库（Lua 脚本）按 **GNU GPL v3.0** 发布，与运行它的 [mod-ale](https://github.com/azerothcore/mod-ale)（Eluna 引擎）保持一致；
配套的 [AcoreGMPanel](https://github.com/bluegene-ai/AcoreGMPanel) 面板是 GPL v2.0。
详见 [LICENSE](LICENSE)。
