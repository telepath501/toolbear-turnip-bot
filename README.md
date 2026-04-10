# ToolBear Turnip Bot

ToolBear Turnip Bot is a Windows-first automation bundle for the turnip market on `lilium.kuma.homes`.

It includes:

- an automated trading bot
- a local dashboard
- one-click launchers
- an executable release build for non-technical users

## Repository layout

- `toolbear_turnip_bot.ps1`: trading bot
- `turnip_dashboard_server.py`: dashboard backend
- `turnip_dashboard.html`: dashboard frontend
- `toolbear_env.ps1`: environment and Chrome token detection
- `run_turnip_bot.ps1`: starts the bot
- `run_turnip_dashboard.ps1`: starts the dashboard
- `run_turnip_suite.ps1`: starts both
- `build_turnip_executables.ps1`: builds Windows executables
- `package_turnip_release.ps1`: builds the plain script zip

## Requirements

- Windows PowerShell 5.1 or newer
- Python 3.10 or newer
- Google Chrome, if you want automatic token detection

The dashboard does not require third-party Python dependencies in source mode.

## Quick start

1. Log in to `https://lilium.kuma.homes/` in Chrome.
2. Run `run_turnip_suite.bat`.
3. If a valid site token is found in Chrome local storage, it will be written into `.env` automatically.
4. If automatic detection fails, copy `.env.example` to `.env` and fill in `TOOLBEAR_TOKEN` manually.

The dashboard listens on `http://localhost:8862/`.

## Token handling

The bot reads `TOOLBEAR_TOKEN`.

By default the launchers try the following, in order:

1. existing environment variable
2. `.env` in the project folder
3. Chrome local storage from a logged-in `lilium.kuma.homes` session

If you need to extract the token manually, open browser DevTools, go to `Network`, open any authenticated request, and copy the `Authorization: Bearer ...` value.

## Build

Build the script release zip:

```powershell
powershell -ExecutionPolicy Bypass -File .\package_turnip_release.ps1
```

Build the executable bundle:

```powershell
powershell -ExecutionPolicy Bypass -File .\build_turnip_executables.ps1
```

Build the GitHub-style release bundle:

```powershell
powershell -ExecutionPolicy Bypass -File .\package_github_release.ps1
```

## Notes

- The current strategy avoids selling turnips at a loss by checking sellable settled cost basis instead of blended inventory average.
- Relative paths in config are resolved from the config file location.
- The release launchers are intended for local desktop use on Windows.
