import sys
import time
import configparser
from datetime import datetime, timezone

if len(sys.argv) < 3:
    print("Usage: python prewarm.py <tester.ini> <terminal64.exe>")
    sys.exit(1)

ini_path = sys.argv[1]
term_path = sys.argv[2]

config = configparser.ConfigParser(strict=False)
for enc in ['utf-8', 'utf-16', 'ascii', 'latin-1']:
    try:
        config.read(ini_path, encoding=enc)
        if config.has_section('Common') or config.has_section('Tester'):
            break
    except Exception:
        continue

def clean_val(val):
    return val.strip(' "\'') if val else ''

def get_clean(section, key, default=''):
    if config.has_section(section) and config.has_option(section, key):
        return clean_val(config.get(section, key))
    return default

login_str = get_clean('Common', 'Login') or get_clean('Tester', 'Login')
login = int(login_str) if login_str else 0
password = get_clean('Common', 'Password')
server = get_clean('Common', 'Server')
symbol = get_clean('Tester', 'Symbol')
period_str = get_clean('Tester', 'Period')
from_str = get_clean('Tester', 'FromDate')
to_str = get_clean('Tester', 'ToDate')

import MetaTrader5 as mt5

timeframe_map = {
    'M1': mt5.TIMEFRAME_M1, 'M2': mt5.TIMEFRAME_M2, 'M3': mt5.TIMEFRAME_M3,
    'M4': mt5.TIMEFRAME_M4, 'M5': mt5.TIMEFRAME_M5, 'M6': mt5.TIMEFRAME_M6,
    'M10': mt5.TIMEFRAME_M10, 'M12': mt5.TIMEFRAME_M12, 'M15': mt5.TIMEFRAME_M15,
    'M20': mt5.TIMEFRAME_M20, 'M30': mt5.TIMEFRAME_M30, 'H1': mt5.TIMEFRAME_H1,
    'H2': mt5.TIMEFRAME_H2, 'H3': mt5.TIMEFRAME_H3, 'H4': mt5.TIMEFRAME_H4,
    'H6': mt5.TIMEFRAME_H6, 'H8': mt5.TIMEFRAME_H8, 'H12': mt5.TIMEFRAME_H12,
    'D1': mt5.TIMEFRAME_D1, 'W1': mt5.TIMEFRAME_W1, 'MN1': mt5.TIMEFRAME_MN1
}
tf = timeframe_map.get(period_str.upper(), mt5.TIMEFRAME_H1)

def parse_date(d_str):
    for fmt in ('%Y.%m.%d', '%Y-%m-%d', '%Y/%m/%d'):
        try:
            return datetime.strptime(d_str.strip(), fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None

dt_from = parse_date(from_str)
dt_to = parse_date(to_str)

init_ok = False
for attempt in range(5):
    try:
        if mt5.initialize(path=term_path, login=login, password=password, server=server, portable=True, timeout=60000):
            init_ok = True
            break
    except Exception:
        pass
    time.sleep(2)

if not init_ok:
    for attempt in range(5):
        try:
            if mt5.initialize(path=term_path, portable=True, timeout=60000):
                init_ok = True
                break
        except Exception:
            pass
        time.sleep(2)

if not init_ok:
    print(f"[GRID] TERMINAL_CONNECT_FAILED: {mt5.last_error()}")
    sys.exit(2)

print("[GRID] TERMINAL_CONNECTED")

auth_ok = False
for attempt in range(15):
    acc = mt5.account_info()
    if acc is not None and acc.login == login and acc.connected:
        auth_ok = True
        break
    if mt5.login(login, password=password, server=server):
        for _ in range(5):
            acc = mt5.account_info()
            if acc is not None and acc.connected:
                auth_ok = True
                break
            time.sleep(1)
        if auth_ok:
            break
    time.sleep(2)

if not auth_ok:
    print(f"[GRID] AUTH_FAILED: {mt5.last_error()}")
    mt5.shutdown()
    sys.exit(3)

print("[GRID] AUTH_SUCCESS")

selected = False
for _ in range(5):
    if mt5.symbol_select(symbol, True):
        selected = True
        break
    time.sleep(2)

if not selected:
    print(f"[GRID] SYMBOL_SELECT_FAILED: {mt5.last_error()}")
    mt5.shutdown()
    sys.exit(4)

print("[GRID] SYMBOL_SELECTED")
print("[GRID] HISTORY_SYNC_BEGIN")

bars_synced = 0
for attempt in range(1, 45):
    mt5.symbol_info_tick(symbol)
    if dt_from and dt_to:
        mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, dt_from, dt_to)
        rates = mt5.copy_rates_range(symbol, tf, dt_from, dt_to)
    else:
        rates = mt5.copy_rates_from_pos(symbol, tf, 0, 100)

    if rates is not None and len(rates) > 0:
        bars_synced = len(rates)
        break
    time.sleep(2)

mt5.shutdown()
time.sleep(2)

if bars_synced > 0:
    print(f"[GRID] HISTORY_READY: BARS={bars_synced}")
    sys.exit(0)
else:
    print("[GRID] HISTORY_PREWARM_FAILED")
    sys.exit(5)
