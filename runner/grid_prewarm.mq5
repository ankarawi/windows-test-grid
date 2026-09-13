//+------------------------------------------------------------------+
//|                                                 grid_prewarm.mq5 |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

void OnStart()
{
   Print("[GRID_PREWARM] Prewarm script started for symbol=", _Symbol, " period=", EnumToString(_Period));
   
   // 1. Wait for connection to trade server
   int connect_retries = 45;
   while(!TerminalInfoInteger(TERMINAL_CONNECTED) && connect_retries > 0)
   {
      Sleep(1000);
      connect_retries--;
   }
   
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("[GRID_PREWARM] ERROR: Not connected to trade server within timeout.");
      TerminalClose(2);
      return;
   }
   
   Print("[GRID_PREWARM] Successfully connected to trade server.");
   
   // 2. Select symbol in Market Watch
   if(!SymbolSelect(_Symbol, true))
   {
      Print("[GRID_PREWARM] WARNING: SymbolSelect returned false for ", _Symbol);
   }
   
   // 3. Read parameters from MQL5\Files\prewarm_params.txt if present
   datetime from_dt = 0;
   datetime to_dt = 0;
   int model = 1;
   
   int file_handle = FileOpen("prewarm_params.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(file_handle != INVALID_HANDLE)
   {
      while(!FileIsEnding(file_handle))
      {
         string line = FileReadString(file_handle);
         string parts[];
         if(StringSplit(line, '=', parts) == 2)
         {
            string key = parts[0];
            string val = parts[1];
            StringTrimLeft(key); StringTrimRight(key);
            StringTrimLeft(val); StringTrimRight(val);
            if(key == "FromDate") from_dt = StringToTime(val);
            else if(key == "ToDate") to_dt = StringToTime(val);
            else if(key == "Model") model = (int)StringToInteger(val);
         }
      }
      FileClose(file_handle);
   }
   
   if(from_dt == 0) from_dt = TimeCurrent() - 30 * 86400;
   if(to_dt == 0) to_dt = TimeCurrent();
   
   Print("[GRID_PREWARM] Target range: ", TimeToString(from_dt), " -> ", TimeToString(to_dt), " model=", model);
   
   // 4. Request M1 history in bounded retry loop
   MqlRates rates[];
   int synced_m1 = 0;
   for(int attempt = 1; attempt <= 45; attempt++)
   {
      ResetLastError();
      synced_m1 = CopyRates(_Symbol, PERIOD_M1, from_dt, to_dt, rates);
      if(synced_m1 > 0)
      {
         Print("[GRID_PREWARM] M1 history synchronized: ", synced_m1, " bars (attempt ", attempt, ")");
         break;
      }
      int err = GetLastError();
      Print("[GRID_PREWARM] Waiting for M1 history (attempt ", attempt, "/45, err=", err, ")...");
      Sleep(1000);
   }
   
   // 5. Request target timeframe history in bounded retry loop
   int synced_target = 0;
   for(int attempt = 1; attempt <= 30; attempt++)
   {
      ResetLastError();
      synced_target = CopyRates(_Symbol, _Period, from_dt, to_dt, rates);
      if(synced_target > 0)
      {
         Print("[GRID_PREWARM] Target timeframe history synchronized: ", synced_target, " bars (attempt ", attempt, ")");
         break;
      }
      int err = GetLastError();
      Print("[GRID_PREWARM] Waiting for target timeframe history (attempt ", attempt, "/30, err=", err, ")...");
      Sleep(1000);
   }
   
   // 6. If Model requires real ticks (model == 2)
   if(model == 2)
   {
      MqlTick ticks[];
      ulong from_msc = (ulong)from_dt * 1000;
      ulong to_msc = (ulong)to_dt * 1000;
      int synced_ticks = 0;
      for(int attempt = 1; attempt <= 30; attempt++)
      {
         ResetLastError();
         synced_ticks = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, from_msc, to_msc);
         if(synced_ticks > 0)
         {
            Print("[GRID_PREWARM] Ticks synchronized: ", synced_ticks, " ticks");
            break;
         }
         Sleep(1000);
      }
   }
   
   // 7. Verify bars > 0
   if(synced_m1 > 0 && synced_target > 0)
   {
      Print("[GRID_PREWARM] PREWARM_SUCCESS");
      Sleep(1000);
      TerminalClose(0);
   }
   else
   {
      Print("[GRID_PREWARM] PREWARM_FAILED: m1=", synced_m1, " target=", synced_target);
      Sleep(1000);
      TerminalClose(1);
   }
}
