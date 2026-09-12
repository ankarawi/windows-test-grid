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
config.read(ini_path, encoding='ascii')

login = int(config.get('Common', 'Login'))
password = config.get('Common', 'Password')
server = config.get('Common', 'Server')
symbol = config.get('Tester', 'Symbol')
period_str = config.get('Tester', 'Period')
from_str = config.get('Tester', 'FromDate')
to_str = config.get('Tester', 'ToDate')

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
dt_from = datetime.strptime(from_str, "%Y.%m.%d").replace(tzinfo=timezone.utc)
dt_to = datetime.strptime(to_str, "%Y.%m.%d").replace(tzinfo=timezone.utc)

init_ok = mt5.initialize(path=term_path, portable=True, timeout=60000)
if not init_ok:
    init_ok = mt5.initialize(path=term_path, timeout=60000)
if not init_ok:
    sys.exit(2)

print("[GRID] TERMINAL_CONNECTED")

if not mt5.login(login, password=password, server=server):
    mt5.shutdown()
    sys.exit(3)

print("[GRID] AUTH_SUCCESS")

if not mt5.symbol_select(symbol, True):
    mt5.shutdown()
    sys.exit(4)

print("[GRID] SYMBOL_SELECTED")
print("[GRID] HISTORY_SYNC_BEGIN")

bars_synced = 0
for attempt in range(1, 31):
    mt5.symbol_info_tick(symbol)
    mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, 100)
    rates = mt5.copy_rates_range(symbol, tf, dt_from, dt_to)
    if rates is not None and len(rates) > 0:
        bars_synced = len(rates)
        break
    time.sleep(2)

mt5.shutdown()

if bars_synced > 0:
    print(f"[GRID] HISTORY_READY: BARS={bars_synced}")
    sys.exit(0)
else:
    sys.exit(5)
