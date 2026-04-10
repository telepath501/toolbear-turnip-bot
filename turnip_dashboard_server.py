import argparse
import concurrent.futures
import json
import os
import socket
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError, HTTPError
from urllib.request import Request, urlopen


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json_file(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return default


def read_jsonl_history(path: Path, window_hours: int = 6):
    if not path.exists():
        return []
    cutoff = time.time() - (window_hours * 3600)
    rows = []
    try:
        with path.open("r", encoding="utf-8-sig", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                    stamp = datetime.fromisoformat(str(row.get("timestamp", "")).replace("Z", "+00:00")).timestamp()
                    if stamp >= cutoff:
                        rows.append(row)
                except Exception:
                    continue
    except Exception:
        return []
    return rows


def read_log_lines(path: Path, count: int = 120):
    if not path.exists():
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return [line for line in lines[-count:] if line.strip()]
    except Exception:
        return []


def resolve_path(base_dir: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def write_json_file(path: Path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def to_float(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default


def to_int(value, default=0):
    try:
        return int(float(value))
    except Exception:
        return default


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    p = max(0.0, min(1.0, p))
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    index = p * (len(sorted_values) - 1)
    lower = int(index)
    upper = min(len(sorted_values) - 1, lower + 1)
    weight = index - lower
    return float(sorted_values[lower]) * (1.0 - weight) + float(sorted_values[upper]) * weight


def window_prices(history, minutes):
    if not history:
        return []
    cutoff = time.time() - (minutes * 60)
    prices = []
    for row in history:
        try:
            ts = datetime.fromisoformat(str(row.get("timestamp", "")).replace("Z", "+00:00")).timestamp()
            price = float(row.get("mid_price", 0))
            if ts >= cutoff and price > 0:
                prices.append(price)
        except Exception:
            continue
    return prices


def range_position(current_price, prices, trim=0.15):
    if current_price <= 0 or len(prices) < 10:
        return None
    ordered = sorted(prices)
    low = percentile(ordered, trim)
    high = percentile(ordered, 1.0 - trim)
    if low is None or high is None:
        return None
    width = max(0.0001, high - low)
    return {
        "low": round(low, 4),
        "high": round(high, 4),
        "position": round((current_price - low) / width, 4),
        "above_low_pct": round(((current_price / low) - 1.0) * 100.0, 4) if low > 0 else 9999.0,
    }


def mean_std(values):
    if len(values) < 5:
        return None
    mean = sum(values) / len(values)
    variance = sum((v - mean) ** 2 for v in values) / max(1, len(values) - 1)
    return mean, variance ** 0.5


def compute_signal_scores(history, market, inventory, strategy):
    current_price = to_float((market or {}).get("current_price"))
    avg_cost = to_float((inventory or {}).get("avg_buy_price"))
    total_quantity = to_int((inventory or {}).get("total_quantity"))
    settled_quantity = to_int((inventory or {}).get("settled_quantity"))
    pending_quantity = to_int((inventory or {}).get("pending_quantity"))

    fair_value = current_price
    if history:
        fair_candidates = [to_float(row.get("fair_value")) for row in history[-20:]]
        fair_candidates = [v for v in fair_candidates if v > 0]
        if fair_candidates:
            fair_value = sum(fair_candidates) / len(fair_candidates)

    short_minutes = to_int(strategy.get("entry_short_window_minutes"), 90)
    long_minutes = to_int(strategy.get("entry_long_window_minutes"), 360)
    trim = to_float(strategy.get("entry_noise_trim_percentile"), 0.15)
    short_stats = range_position(current_price, window_prices(history, short_minutes), trim)
    long_stats = range_position(current_price, window_prices(history, long_minutes), trim)

    z_score = None
    z_prices = window_prices(history, to_int(strategy.get("mean_reversion_window_minutes"), 30))
    stats = mean_std(z_prices)
    if stats:
        mean, std = stats
        if std > 0 and current_price > 0:
            z_score = round((current_price - mean) / std, 4)

    def window_return(minutes):
        prices = window_prices(history, minutes)
        if len(prices) < 2 or prices[0] <= 0:
            return None
        return round(((prices[-1] / prices[0]) - 1.0) * 100.0, 4)

    ret15 = window_return(15)
    ret30 = window_return(30)
    ret60 = window_return(60)

    confirm_minutes = to_int(strategy.get("entry_confirmation_window_minutes"), 18)
    confirm_trim = to_float(strategy.get("entry_confirmation_trim_percentile"), 0.2)
    confirm_stats = range_position(current_price, window_prices(history, confirm_minutes), confirm_trim)
    bounce_pct = confirm_stats["above_low_pct"] if confirm_stats else None
    distance_from_high_pct = None
    if confirm_stats and confirm_stats["high"] > 0:
        distance_from_high_pct = round(((confirm_stats["high"] - current_price) / confirm_stats["high"]) * 100.0, 4)

    bid = to_float((market or {}).get("bid"))
    ask = to_float((market or {}).get("ask"))
    spread_pct = round(((ask - bid) / current_price) * 100.0, 4) if current_price > 0 and bid > 0 and ask > 0 else 0.0

    discount_pct = round(((fair_value - current_price) / fair_value) * 100.0, 4) if fair_value > 0 and current_price > 0 else 0.0
    profit_pct = round(((current_price / avg_cost) - 1.0) * 100.0, 4) if avg_cost > 0 and current_price > 0 else 0.0

    buy_points = 0
    buy_reasons = []
    buy_blockers = []

    if short_stats and short_stats["position"] <= to_float(strategy.get("short_window_max_range_position_for_entry"), 0.5):
        buy_points += 16
        buy_reasons.append("短窗位置偏低")
    if long_stats and long_stats["position"] <= to_float(strategy.get("long_window_max_range_position_for_entry"), 0.55):
        buy_points += 16
        buy_reasons.append("长窗位置不高")
    if short_stats and short_stats["above_low_pct"] <= to_float(strategy.get("short_window_max_above_low_pct"), 18.0):
        buy_points += 10
        buy_reasons.append("接近短窗低位")
    if long_stats and long_stats["above_low_pct"] <= to_float(strategy.get("max_price_above_long_window_low_pct"), 35.0):
        buy_points += 10
        buy_reasons.append("接近长窗稳健低位")
    if z_score is not None and z_score <= -to_float(strategy.get("mean_reversion_entry_z"), 1.25):
        buy_points += 8
        buy_reasons.append("短线偏离较深")
    if discount_pct >= 0:
        buy_points += 6
        buy_reasons.append("不高于估算公允值")
    if ret30 is not None and ret30 >= to_float(strategy.get("entry_trend_filter_30m_min_return_pct"), -0.4):
        buy_points += 10
        buy_reasons.append("30 分钟趋势未明显走坏")
    else:
        buy_blockers.append("30 分钟趋势仍偏弱")
    if ret60 is not None and ret60 >= to_float(strategy.get("entry_trend_filter_60m_min_return_pct"), -1.8):
        buy_points += 10
        buy_reasons.append("60 分钟趋势未明显下坠")
    else:
        buy_blockers.append("60 分钟趋势仍偏空")
    if ret15 is not None and ret15 >= to_float(strategy.get("entry_confirmation_min_return_15m_pct"), 0.25):
        buy_points += 8
        buy_reasons.append("15 分钟已有转强迹象")
    if bounce_pct is not None and bounce_pct >= to_float(strategy.get("entry_confirmation_min_bounce_pct"), 1.2):
        buy_points += 8
        buy_reasons.append("已从短平台低点反弹")
    if distance_from_high_pct is not None and distance_from_high_pct <= to_float(strategy.get("entry_confirmation_max_distance_from_high_pct"), 1.4):
        buy_points += 8
        buy_reasons.append("接近平台上沿")
    if spread_pct <= to_float(strategy.get("max_spread_pct"), 1.2):
        buy_points += 6
        buy_reasons.append("点差仍在可接受范围")
    else:
        buy_blockers.append("点差偏大")

    buy_score = max(0, min(100, buy_points - (12 * len(buy_blockers))))

    sell_points = 0
    sell_reasons = []
    sell_blockers = []

    if total_quantity <= 0:
        sell_blockers.append("当前没有持仓")
    else:
        if profit_pct >= 20:
            sell_points += 18
            sell_reasons.append("已有较厚利润垫")
        if profit_pct >= to_float(strategy.get("base_take_profit_pct"), 11.5):
            sell_points += 18
            sell_reasons.append("超过基础止盈线")
        if z_score is not None and z_score >= to_float(strategy.get("mean_reversion_exit_z"), 1.1):
            sell_points += 12
            sell_reasons.append("短线偏热")
        if current_price > fair_value and fair_value > 0:
            sell_points += 10
            sell_reasons.append("高于估算公允值")
        if long_stats and long_stats["position"] >= 0.75:
            sell_points += 12
            sell_reasons.append("处在长窗偏高位置")
        if ret15 is not None and ret15 < 0:
            sell_points += 10
            sell_reasons.append("15 分钟动能转弱")
        if ret30 is not None and ret30 < 0:
            sell_points += 10
            sell_reasons.append("30 分钟趋势走弱")
        if settled_quantity <= 0 and pending_quantity > 0:
            sell_blockers.append("仓位仍在交割中")
            sell_points = min(sell_points, 25)
        elif settled_quantity > 0:
            sell_points += 10
            sell_reasons.append("已有可卖仓位")

    sell_score = max(0, min(100, sell_points - (10 * len(sell_blockers))))

    def level(score):
        if score >= 75:
            return "强"
        if score >= 55:
            return "观察"
        if score >= 35:
            return "偏弱"
        return "低"

    return {
        "buy_score": buy_score,
        "sell_score": sell_score,
        "buy_level": level(buy_score),
        "sell_level": level(sell_score),
        "buy_reasons": buy_reasons,
        "sell_reasons": sell_reasons,
        "buy_blockers": buy_blockers,
        "sell_blockers": sell_blockers,
        "z_score": z_score,
        "discount_pct": discount_pct,
        "profit_pct": profit_pct,
        "spread_pct": spread_pct,
        "ret15_pct": ret15,
        "ret30_pct": ret30,
        "ret60_pct": ret60,
        "bounce_pct": bounce_pct,
        "distance_from_high_pct": distance_from_high_pct,
        "settled_quantity": settled_quantity,
        "pending_quantity": pending_quantity,
        "short_window": short_stats,
        "long_window": long_stats,
    }


class DashboardState:
    def __init__(self, base_url: str, token: str, config_path: Path, state_path: Path, tick_history_path: Path, log_path: Path, html_path: Path, bot_script_path: Path, api_timeout: int, cache_ttl: int):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.config_path = config_path
        self.state_path = state_path
        self.tick_history_path = tick_history_path
        self.log_path = log_path
        self.html_path = html_path
        self.bot_script_path = bot_script_path
        self.api_timeout = api_timeout
        self.cache_ttl = cache_ttl
        self.lock = threading.Lock()
        self.refresh_lock = threading.Lock()
        self.refresh_in_progress = False
        self.cache = {
            "generated_at": None,
            "config": read_json_file(config_path, {}),
            "market": None,
            "price_history": None,
            "depth": None,
            "inventory": None,
            "wallet": None,
            "wallet_stats": None,
            "turnip_transactions": None,
            "bot_state": {
                "tick_history": [],
                "last_actions": [],
                "last_order_at": {"buy": None, "sell": None},
                "position_peak_profit_pct": None,
            },
            "bot_logs": [],
            "service": {
                "cache_refreshed_at": None,
                "api_timeout_seconds": api_timeout,
                "errors": ["Dashboard cache not loaded yet."],
                "live_sources": [],
            },
            "derived": {
                "estimated_unrealized_pnl": 0.0,
                "open_exposure_quantity": 0.0,
                "current_price": 0.0,
                "avg_cost": 0.0,
                "sell_ladder_targets": [],
            },
        }
        self.last_refresh_epoch = 0.0
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=8)

    def get_bot_status(self):
        command = r"Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -match 'toolbear_turnip_bot\.ps1' } | Select-Object ProcessId,CommandLine | ConvertTo-Json -Depth 4"
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=False,
        )
        items = []
        if result.stdout.strip():
            try:
                parsed = json.loads(result.stdout)
                if isinstance(parsed, list):
                    items = parsed
                elif parsed:
                    items = [parsed]
            except json.JSONDecodeError:
                items = []
        return {
            "running": len(items) > 0,
            "count": len(items),
            "processes": items,
        }

    def save_capital_limit(self, amount: float):
        config = read_json_file(self.config_path, {})
        strategy = config.setdefault("strategy", {})
        strategy["max_total_capital_deployed"] = round(float(amount), 2)
        write_json_file(self.config_path, config)
        with self.lock:
          self.cache["config"] = config
          self.last_refresh_epoch = 0.0
        return config

    def stop_bot(self):
        command = r"Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -match 'toolbear_turnip_bot\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            check=False,
        )

    def start_bot(self):
        arg_string = (
            f' -ExecutionPolicy Bypass'
            f' -File "{self.bot_script_path}"'
            f' -ConfigPath "{self.config_path}"'
            f' -Token "{self.token}"'
            f' -Execute'
        )
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                f'Start-Process powershell -ArgumentList \'{arg_string}\' -WorkingDirectory "{self.config_path.parent}"'
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            check=False,
        )

    def restart_bot(self):
        self.stop_bot()
        self.start_bot()
        time.sleep(2)
        return self.get_bot_status()

    def fetch_json(self, path: str):
        req = Request(
            f"{self.base_url}{path}",
            headers={
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
                "Referer": f"{self.base_url}/",
                "Origin": self.base_url,
            },
            method="GET",
        )
        with urlopen(req, timeout=self.api_timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def fetch_or_fallback(self, name: str, path: str, fallback):
        try:
            return {"value": self.fetch_json(path), "error": None, "source": "live"}
        except (URLError, HTTPError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            return {
                "value": fallback,
                "error": f"{name} failed: {exc}",
                "source": "cache" if fallback is not None else "empty",
            }

    def build_payload(self, previous):
        config = read_json_file(self.config_path, previous.get("config", {}))
        jobs = {
            "market": self.executor.submit(self.fetch_or_fallback, "market", "/api/turnip/market", previous.get("market")),
            "price_history": self.executor.submit(self.fetch_or_fallback, "price_history", "/api/turnip/prices?hours=48&interval_minutes=60", previous.get("price_history")),
            "depth": self.executor.submit(self.fetch_or_fallback, "depth", "/api/turnip/depth", previous.get("depth")),
            "inventory": self.executor.submit(self.fetch_or_fallback, "inventory", "/api/turnip/inventory", previous.get("inventory")),
            "transactions": self.executor.submit(self.fetch_or_fallback, "transactions", "/api/turnip/transactions?limit=30&offset=0", previous.get("turnip_transactions")),
            "wallet": self.executor.submit(self.fetch_or_fallback, "wallet", "/api/wallet/balance", previous.get("wallet")),
            "wallet_stats": self.executor.submit(self.fetch_or_fallback, "wallet_stats", "/api/wallet/stats", previous.get("wallet_stats")),
            "bot_status": self.executor.submit(self.get_bot_status),
            "bot_state": self.executor.submit(read_json_file, self.state_path, previous.get("bot_state", {})),
            "tick_history": self.executor.submit(read_jsonl_history, self.tick_history_path, 6),
            "bot_logs": self.executor.submit(read_log_lines, self.log_path, 120),
        }

        market_res = jobs["market"].result()
        prices_res = jobs["price_history"].result()
        depth_res = jobs["depth"].result()
        inventory_res = jobs["inventory"].result()
        tx_res = jobs["transactions"].result()
        wallet_res = jobs["wallet"].result()
        wallet_stats_res = jobs["wallet_stats"].result()

        market = market_res["value"] or {}
        inventory = inventory_res["value"] or {}
        settled = to_float(inventory.get("settled_quantity"))
        pending = to_float(inventory.get("pending_quantity"))
        total_quantity = to_float(inventory.get("total_quantity"))
        current_price = to_float((market or {}).get("current_price"))
        avg_cost = to_float(inventory.get("avg_buy_price"))
        total_cost = to_float(inventory.get("total_cost"))
        capital_limit = to_float(((config or {}).get("strategy") or {}).get("max_total_capital_deployed"))
        bot_state = jobs["bot_state"].result()
        disk_tick_history = jobs["tick_history"].result()
        signal_history = disk_tick_history or ((bot_state or {}).get("tick_history") or [])
        if bot_state is None:
            bot_state = {}
        bot_state["tick_history"] = signal_history[-180:]
        strategy = (config or {}).get("strategy") or {}
        executed_tiers = set(((bot_state or {}).get("sell_ladder") or {}).get("executed_tiers") or [])
        signal_scores = compute_signal_scores(signal_history, market, inventory, strategy)
        estimated_pnl = round((current_price - avg_cost) * (settled + pending), 2) if avg_cost > 0 and (settled + pending) > 0 else 0.0
        remaining_budget = round(max(0.0, capital_limit - total_cost), 2) if capital_limit > 0 else 0.0
        sell_ladder_targets = []
        for tier in strategy.get("sell_ladder_tiers", []):
            profit_pct = to_float(tier.get("profit_pct"))
            sell_fraction = to_float(tier.get("sell_fraction"))
            if profit_pct <= 0 or sell_fraction <= 0:
                continue
            tier_key = str(round(profit_pct, 4))
            target_price = round(avg_cost * (1.0 + (profit_pct / 100.0)), 2) if avg_cost > 0 else 0.0
            qty_total = max(0, int(total_quantity * sell_fraction))
            qty_settled = max(0, int(settled * sell_fraction))
            if qty_total == 0 and total_quantity > 0:
                qty_total = 1
            if qty_settled == 0 and settled > 0:
                qty_settled = 1
            sell_ladder_targets.append({
                "tier_key": tier_key,
                "profit_pct": round(profit_pct, 2),
                "sell_fraction_pct": round(sell_fraction * 100.0, 2),
                "target_price": target_price,
                "quantity_on_total": qty_total,
                "quantity_on_settled": qty_settled,
                "executed": tier_key in executed_tiers,
            })

        payload = {
            "generated_at": utc_now_iso(),
            "config": config,
            "market": market_res["value"],
            "price_history": prices_res["value"],
            "depth": depth_res["value"],
            "inventory": inventory_res["value"],
            "wallet": wallet_res["value"],
            "wallet_stats": wallet_stats_res["value"],
            "turnip_transactions": tx_res["value"],
            "bot_state": bot_state,
            "bot_logs": jobs["bot_logs"].result(),
            "service": {
                "cache_refreshed_at": utc_now_iso(),
                "api_timeout_seconds": self.api_timeout,
                "errors": [x for x in [
                    market_res["error"],
                    prices_res["error"],
                    depth_res["error"],
                    inventory_res["error"],
                    tx_res["error"],
                    wallet_res["error"],
                    wallet_stats_res["error"],
                ] if x],
                "live_sources": [
                    f"market:{market_res['source']}",
                    f"price_history:{prices_res['source']}",
                    f"depth:{depth_res['source']}",
                    f"inventory:{inventory_res['source']}",
                    f"transactions:{tx_res['source']}",
                    f"wallet:{wallet_res['source']}",
                    f"wallet_stats:{wallet_stats_res['source']}",
                ],
            },
            "bot_control": jobs["bot_status"].result(),
            "derived": {
                "estimated_unrealized_pnl": estimated_pnl,
                "open_exposure_quantity": settled + pending,
                "current_price": current_price,
                "avg_cost": avg_cost,
                "deployed_capital": total_cost,
                "remaining_budget": remaining_budget,
                "capital_limit": capital_limit,
                "settled_quantity": settled,
                "pending_quantity": pending,
                "total_quantity": total_quantity,
                "sell_ladder_targets": sell_ladder_targets,
                "signal_scores": signal_scores,
            },
        }
        return payload

    def refresh_cache(self):
        with self.refresh_lock:
            if self.refresh_in_progress:
                return
            self.refresh_in_progress = True

        try:
            previous = self.cache
            payload = self.build_payload(previous)
            with self.lock:
                self.cache = payload
                self.last_refresh_epoch = time.time()
        finally:
            with self.refresh_lock:
                self.refresh_in_progress = False

    def get_payload(self):
        now = time.time()
        with self.lock:
            payload = self.cache
            stale = now - self.last_refresh_epoch >= self.cache_ttl
            empty = payload.get("generated_at") is None

        if empty:
            self.refresh_cache()
            with self.lock:
                return self.cache

        if stale and not self.refresh_in_progress:
            threading.Thread(target=self.refresh_cache, daemon=True).start()

        return payload


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "TurnipDashboard/1.0"

    def do_GET(self):
        if self.path == "/" or self.path == "":
            html = self.server.state.html_path.read_text(encoding="utf-8")
            self.respond_text(html, "text/html; charset=utf-8", 200)
            return

        if self.path == "/favicon.ico":
            self.respond_bytes(b"", "image/x-icon", 204)
            return

        if self.path == "/api/health":
            payload = self.server.state.get_payload()
            self.respond_json({
                "ok": True,
                "cache_refreshed_at": payload.get("service", {}).get("cache_refreshed_at"),
                "errors": payload.get("service", {}).get("errors", []),
            })
            return

        if self.path == "/api/dashboard":
            self.respond_json(self.server.state.get_payload())
            return

        self.respond_json({"error": "Not found", "path": self.path}, 404)

    def do_POST(self):
        if self.path == "/api/settings":
            payload = self.read_json_body()
            amount = payload.get("max_total_capital_deployed")
            if amount is None:
                self.respond_json({"error": "max_total_capital_deployed is required"}, 400)
                return

            try:
                amount = float(amount)
            except (TypeError, ValueError):
                self.respond_json({"error": "max_total_capital_deployed must be numeric"}, 400)
                return

            if amount < 0:
                self.respond_json({"error": "max_total_capital_deployed must be non-negative"}, 400)
                return

            config = self.server.state.save_capital_limit(amount)
            restart = bool(payload.get("restart_bot", True))
            status = self.server.state.restart_bot() if restart else self.server.state.get_bot_status()
            self.respond_json({
                "ok": True,
                "message": "Capital limit updated.",
                "config": config,
                "bot_control": status,
            })
            return

        if self.path == "/api/bot/restart":
            status = self.server.state.restart_bot()
            self.respond_json({
                "ok": True,
                "message": "Bot restarted.",
                "bot_control": status,
            })
            return

        self.respond_json({"error": "Not found", "path": self.path}, 404)

    def log_message(self, format, *args):
        return

    def read_json_body(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(content_length) if content_length > 0 else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def respond_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.respond_bytes(body, "application/json; charset=utf-8", status)

    def respond_text(self, text, content_type, status=200):
        self.respond_bytes(text.encode("utf-8"), content_type, status)

    def respond_bytes(self, body: bytes, content_type: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
                pass


class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def resolve_token(cli_token: str, config: dict) -> str:
    if cli_token:
        return cli_token
    env_name = config.get("token_env_var")
    if env_name:
        env_value = os.environ.get(env_name)
        if env_value:
            return env_value
    raise SystemExit("Missing token. Pass --token or set the environment variable defined by token_env_var.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-path", default="turnip_bot_config.json")
    parser.add_argument("--bot-state-path", default="turnip_bot_state.json")
    parser.add_argument("--bot-log-path", default="turnip_bot.log")
    parser.add_argument("--token")
    parser.add_argument("--port", type=int, default=8860)
    parser.add_argument("--api-timeout-seconds", type=int, default=5)
    parser.add_argument("--cache-ttl-seconds", type=int, default=8)
    args = parser.parse_args()

    config_path = Path(args.config_path).resolve()
    base_dir = config_path.parent
    config = read_json_file(config_path, {})
    token = resolve_token(args.token, config)
    state = DashboardState(
        base_url=config.get("base_url", "https://lilium.kuma.homes"),
        token=token,
        config_path=config_path,
        state_path=resolve_path(base_dir, args.bot_state_path),
        tick_history_path=resolve_path(base_dir, config.get("tick_history_path", "./turnip_tick_history.jsonl")),
        log_path=resolve_path(base_dir, args.bot_log_path),
        html_path=(Path(__file__).resolve().parent / "turnip_dashboard.html"),
        bot_script_path=(Path(__file__).resolve().parent / "toolbear_turnip_bot.ps1"),
        api_timeout=args.api_timeout_seconds,
        cache_ttl=args.cache_ttl_seconds,
    )

    httpd = DualStackServer(("::", args.port), DashboardHandler)
    httpd.state = state
    print(f"Turnip dashboard is running at http://localhost:{args.port}/", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
