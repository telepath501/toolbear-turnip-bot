# ToolBear Stock Bot

默认是 `dry-run` 模式，只采集行情、计算信号、写日志，不会下单。

## Files

- `toolbear_stock_bot.ps1`: 机器人主脚本
- `stock_bot_config.json`: 策略和风控配置
- `stock_bot_state.json`: 运行后自动生成的本地状态
- `stock_bot.log`: 运行后自动生成的日志

## Token

优先使用环境变量：

```powershell
$env:TOOLBEAR_TOKEN = "你的 Bearer Token"
```

也可以直接传：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_stock_bot.ps1 -Token "你的 Bearer Token" -Once
```

## Run

单次 dry-run：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_stock_bot.ps1 -Once
```

持续 dry-run：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_stock_bot.ps1
```

真实下单：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_stock_bot.ps1 -Execute
```

## Strategy

- 观察 `watchlist` 中的股票
- 用机器人自己采集到的近 5 分钟、15 分钟价格变化做入场判断
- 5 分钟和 15 分钟都满足动量阈值时开仓
- 已有仓位时按硬止损、止盈、追踪止损优先退出
- 开仓后自动补止损/止盈触发器

## Important

- 这个站点没有直接给出完整历史 K 线给股票接口，所以当前策略是“基于机器人自己采样序列”的短周期动量
- 第一次跑时历史样本不足，通常不会立刻出信号
- 建议先连续 dry-run 一段时间，再决定是否加 `-Execute`
