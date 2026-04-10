# Release Notes

## Current release

This release includes:

- executable launcher bundle for Windows
- automatic `TOOLBEAR_TOKEN` detection from Chrome local storage
- source launchers for bot and dashboard
- disk-backed tick history
- dashboard support for local monitoring
- sell logic updated to use sellable settled cost basis instead of blended inventory average

## Intended use

This project is designed for local personal automation on Windows.

Users should:

- log in to `lilium.kuma.homes` in Chrome before first launch
- review the strategy configuration before enabling live execution
- keep the machine awake while the bot is running

## Release artifacts

- `toolbear-turnip-exe.zip`: executable-oriented release package
- `toolbear-turnip-bot.zip`: script-oriented release package

## Upgrade notes

- Existing users can replace the old launcher files with this release.
- If `.env` already exists, it will still be respected.
- If `.env` is missing, the new launcher will try to populate it automatically from Chrome.
