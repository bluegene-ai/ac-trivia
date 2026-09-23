# 测试与自检工具

这些工具**不需要开服**，用任意 Lua 5.2 解释器（[lua.org](https://www.lua.org/) 或 LuaJIT）就能跑。
它们用一套假的 ALE API（`RegisterPlayerEvent` / `SendMail` / `SendWorldMessage` / `CreateLuaEvent` /
`CharDBQuery` …）模拟 worldserver，其中假数据库带一个极简 SQL 写入解析器，
所以「首次建库 → 写入种子题库 → 再从库里读题」这条链路也能在离线状态下被测到。

| 文件 | 说明 |
|---|---|
| `test_trivia.lua` | 行为测试：202 项断言，覆盖出题/作答/发奖/频道/次数限制/超时/数据库/指令/暂停恢复/定时启停/异常兜底 |
| `check_questions.lua` | 题库自检：按脚本自身的解析规则校验题库，逐条列出被跳过的错题 |
| `dump_schema.lua` | 把脚本真实执行的建表/初始化 SQL 抓成 `schema.sql`（校验 DDL，或给 DBA 预建表用） |

> `TriviaReward_conf.lua` 已退休，这些工具不再需要它（旧的命令行传了也只会提示一句然后照常跑）。

## 跑测试

```bash
# 行为测试
lua tests/test_trivia.lua TriviaReward.lua

# 题库自检（没有数据库快照时，校验的是内置题库兜底路径）
lua tests/check_questions.lua TriviaReward.lua
```

退出码 0 = 全部通过。

## 用真实数据库校验题库

`check_questions.lua` 支持一份"数据库快照"：给它一个 `db_snapshot.lua`
（`return { settings = {...}, questions = {...}, presets = {...} }`），
它就会用脚本自己的规则去校验**线上真实的题库**，而不是内置示例。

生成快照最简单的方式是用 AGMP 面板仓库里的
[`dump_db_snapshot.php`](https://github.com/bluegene-ai/AcoreGMPanel)（它会读 `ac_eluna` 并写出这个文件），
或自己从这几张表导出一份 Lua 表：

```lua
-- db_snapshot.lua
return {
  settings  = { interval_seconds = 900, option_labels = "A,B,C,D", ... },  -- trivia_reward_settings 的一行
  questions = { { question = "...", option1 = "...", answer_index = 2, ... }, ... },
  presets   = { { name = "cloth5", items = "33470:5", money = 0 }, ... },
}
```

```bash
lua tests/check_questions.lua TriviaReward.lua db_snapshot.lua
```

## 抓建表 SQL

```bash
lua tests/dump_schema.lua TriviaReward.lua schema.sql
mysql --default-character-set=utf8mb4 -h 127.0.0.1 -P 3306 -u root -p ac_eluna -e "source schema.sql"
```

生成出来的就是脚本首次加载时会执行的建表/初始化语句（含默认设置、奖励预设和种子题库），
可以用来验证 DDL 在目标 MySQL 上是否成立，或事先把表建好。
