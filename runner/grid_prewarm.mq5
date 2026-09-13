//+------------------------------------------------------------------+
//|                                                 grid_prewarm.mq5 |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

void WriteStatus(string text)
{
   int handle = FileOpen("grid_prewarm.status", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, text);
      FileFlush(handle);
      FileClose(handle);
   }
}

void OnStart()
{
   Print("[GRID_PREWARM] START");
   WriteStatus("STATUS=STARTED\n");
   
   // 1. Wait for connection to trade server
   int connect_retries = 45;
   while(!TerminalInfoInteger(TERMINAL_CONNECTED) && connect_retries > 0)
   {
      Sleep(1000);
      connect_retries--;
   }
   
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("[GRID_PREWARM] CONNECT_FAIL");
      WriteStatus("STATUS=CONNECT_FAIL\n");
      TerminalClose(2);
      return;
   }
   
   Print("[GRID_PREWARM] CONNECTED");
   
   // 2. Select symbol in Market Watch
   if(!SymbolSelect(_Symbol, true))
   {
      Print("[GRID_PREWARM] SYMBOL_SELECT_FAIL");
      WriteStatus("STATUS=SYMBOL_SELECT_FAIL\n");
      TerminalClose(3);
      return;
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
   
   // 4. Request M1 history in bounded retry loop
   MqlRates rates[];
   int synced_m1 = 0;
   for(int attempt = 1; attempt <= 45; attempt++)
   {
      ResetLastError();
      synced_m1 = CopyRates(_Symbol, PERIOD_M1, from_dt, to_dt, rates);
      if(synced_m1 > 0)
      {
         Print("[GRID_PREWARM] M1_READY");
         break;
      }
      Sleep(1000);
   }
   
   if(synced_m1 <= 0)
   {
      Print("[GRID_PREWARM] M1_FAIL");
      WriteStatus("STATUS=M1_HISTORY_FAIL\n");
      TerminalClose(4);
      return;
   }
   
   // 5. Request target timeframe history in bounded retry loop
   int synced_target = 0;
   for(int attempt = 1; attempt <= 30; attempt++)
   {
      ResetLastError();
      synced_target = CopyRates(_Symbol, _Period, from_dt, to_dt, rates);
      if(synced_target > 0)
      {
         Print("[GRID_PREWARM] TARGET_READY");
         break;
      }
      Sleep(1000);
   }
   
   if(synced_target <= 0)
   {
      Print("[GRID_PREWARM] TARGET_FAIL");
      WriteStatus("STATUS=TARGET_HISTORY_FAIL\n");
      TerminalClose(5);
      return;
   }
   
   // 6. If Model requires real ticks (model == 2)
   string ticks_str = "NOT_REQUIRED";
   int synced_ticks = 0;
   if(model == 2)
   {
      MqlTick ticks[];
      ulong from_msc = (ulong)from_dt * 1000;
      ulong to_msc = (ulong)to_dt * 1000;
      for(int attempt = 1; attempt <= 30; attempt++)
      {
         ResetLastError();
         synced_ticks = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, from_msc, to_msc);
         if(synced_ticks > 0)
         {
            Print("[GRID_PREWARM] TICKS_READY");
            ticks_str = IntegerToString(synced_ticks);
            break;
         }
         Sleep(1000);
      }
      
      if(synced_ticks <= 0)
      {
         Print("[GRID_PREWARM] TICKS_FAIL");
         WriteStatus("STATUS=TICKS_HISTORY_FAIL\n");
         TerminalClose(6);
         return;
      }
   }
   
   // 7. Success sentinel
   string finalStatus = "STATUS=PASS\nM1_BARS=" + IntegerToString(synced_m1) + "\nTARGET_BARS=" + IntegerToString(synced_target) + "\nTICKS=" + ticks_str + "\n";
   WriteStatus(finalStatus);
   Print("[GRID_PREWARM] PASS");
   Sleep(1000);
   TerminalClose(0);
}
