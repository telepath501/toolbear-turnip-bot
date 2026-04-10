# ToolBear 大头菜机器人

这是一个面向 Windows 的本地自动化项目，用于 `lilium.kuma.homes` 上的大头菜交易。

项目包含：

- 自动交易机器人
- 本地可视化面板
- 一键启动脚本
- 面向非技术用户的可执行发布包

## 项目结构

- `toolbear_turnip_bot.ps1`：交易机器人
- `turnip_dashboard_server.py`：面板后端
- `turnip_dashboard.html`：面板前端
- `toolbear_env.ps1`：环境加载与 Chrome token 自动检测
- `run_turnip_bot.ps1`：启动机器人
- `run_turnip_dashboard.ps1`：启动面板
- `run_turnip_suite.ps1`：同时启动机器人和面板
- `build_turnip_executables.ps1`：构建 Windows 可执行文件
- `package_turnip_release.ps1`：构建脚本版发布包

## 运行要求

- Windows PowerShell 5.1 或更高版本
- Python 3.10 或更高版本
- Google Chrome
  说明：如果希望自动读取登录 token，需要本机 Chrome 已登录目标网站

源码模式下，面板不依赖额外的第三方 Python 包。

## 快速开始

1. 先在 Chrome 中登录 `https://lilium.kuma.homes/`
2. 运行 `run_turnip_suite.bat`
3. 启动器会尝试从 Chrome 本地存储中自动读取站点 token，并写入 `.env`
4. 如果自动检测失败，再手动把 `.env.example` 复制为 `.env`，然后填写 `TOOLBEAR_TOKEN`

面板默认地址为 `http://localhost:8862/`。

## Token 处理方式

机器人读取环境变量 `TOOLBEAR_TOKEN`。

启动器会按以下顺序查找：

1. 当前环境变量
2. 项目目录中的 `.env`
3. Chrome 本地存储中的已登录 `lilium.kuma.homes` 会话

如果需要手动获取 token，可以打开浏览器开发者工具，在 `Network` 中打开任意一个已登录请求，复制 `Authorization: Bearer ...` 里的内容。

## 构建

构建脚本版发布包：

```powershell
powershell -ExecutionPolicy Bypass -File .\package_turnip_release.ps1
```

构建可执行发布包：

```powershell
powershell -ExecutionPolicy Bypass -File .\build_turnip_executables.ps1
```

构建适合 GitHub Release 的发布包：

```powershell
powershell -ExecutionPolicy Bypass -File .\package_github_release.ps1
```

## 说明

- 当前卖出策略会优先按“已交割可卖批次”的成本计算，而不是按整仓混合均价计算，以避免出现看似盈利、实际亏损的卖出。
- 配置文件中的相对路径，会以配置文件所在目录为基准解析。
- 当前发布包主要面向 Windows 本地桌面环境使用。
