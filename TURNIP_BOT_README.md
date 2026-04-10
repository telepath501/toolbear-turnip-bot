# ToolBear Turnip Bot

这个机器人现在只走大头菜页面自己的交易接口，不再走交易行挂单。

核心接口：

- `GET /api/turnip/market`
- `GET /api/turnip/depth`
- `GET /api/turnip/inventory`
- `POST /api/turnip/buy`
- `POST /api/turnip/sell`

## 交易逻辑

- 用 `market + depth` 采样价格、买卖盘和最近成交，建立自己的短周期序列。
- 买入是“量化择时 + 直购”：
  - 价格相对滚动均值偏低，或短期出现足够折价时才考虑买。
  - 波动、点差、盘口失衡、最近成交失衡太差时不买。
  - 下单时给 `max_price`，控制高波动下的滑点。
- 卖出是“已交割库存管理 + 直卖”：
  - 只会卖 `settled_quantity`，不会动还在 6 小时交割期里的 `pending_quantity`。
  - 用止盈、止损、追踪止盈、均值回归退出四类信号决定卖出。
  - 下单时给 `min_price`，避免急跌时被过度滑价。

## 为什么这样更适合大头菜

- 大头菜买入后要等 6 小时交割，所以机器人会把 `pending_quantity` 也算进风险敞口，避免连续追买。
- 大头菜波动大，单看涨跌很容易追在局部高点，所以买入要同时过“折价/均值/波动/盘口/成交”几层过滤。
- 直购直卖比挂单更贴近页面真实玩法，因此参数重点放在仓位、滑点和交割节奏上，而不是挂单撤单管理。

## 使用方法

先设置 token：

```powershell
$env:TOOLBEAR_TOKEN = "你的 Bearer Token"
```

先跑一轮观察：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_turnip_bot.ps1 -Once
```

持续观察模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_turnip_bot.ps1
```

确认逻辑没问题后，再启用真实交易：

```powershell
powershell -ExecutionPolicy Bypass -File .\toolbear_turnip_bot.ps1 -Execute
```

## 主要参数

- `max_pending_quantity`: 交割中的库存上限，防止 6 小时内堆太多待交割仓位。
- `buy_slippage_limit_pct`: 买入允许的最高滑点保护。
- `sell_slippage_limit_pct`: 卖出允许的最低滑点保护。
- `volatility_entry_ceiling_pct`: 波动太大时停止新开仓。
- `fair_value_discount_entry_pct`: 需要达到的基础折价。
- `min_recent_trade_imbalance_for_buy`: 最近成交明显偏空时不买。

## 文件

- `toolbear_turnip_bot.ps1`: 机器人主体
- `turnip_bot_config.json`: 策略参数
- `turnip_bot_state.json`: 运行状态
- `turnip_bot.log`: 日志
