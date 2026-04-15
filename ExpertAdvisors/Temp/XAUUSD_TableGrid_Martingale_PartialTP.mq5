//+----------------------------------------------------------------------+
//| XAUUSD_TableGrid_Martingale_BuyOnly.mq5                              |
//| Buy-only table-driven grid EA for XAUUSD (MT5 Hedging)               |
// Setting Telegram                                                      |
// Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL|
// tambahkan https://api.telegram.org
//+----------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "General"
input long   InpMagic                   = 260414; // Magic number
input bool   InpShowCycleRefOnChart     = true;   // Show manual cycle reference on chart

input group "Manual Resume (Top Priority)"
input int    InpManualResumeCycleId     = 0;      // "Trigger button" 1->2->3; new batch only when this value increases
input double InpManualResumeLot         = 0.12;   // Manual resume lot per order
input double InpManualResumeGridPips    = 100.0;  // Manual resume grid in pips
input int    InpManualResumeCount       = 5;      // Additional positions to open in current manual batch

input group "CSV Level Table"
input string InpTableFile               = "files/xau_levels.csv"; // CSV in MQL5/Files, format: lot,gridPips per line
input bool   InpSkipFirstCsvRow         = true;   // Skip first row (header)
input bool   InpUseCommonFiles          = true;  // Read CSV from Terminal/Common/Files using FILE_COMMON
input bool   InpUseLastLevelIfExceeded  = true;   // Use last table row when positions exceed table

input group "Risk & Entry"
input int    InpMaxPositions            = 29;      // Max grid positions (0=disabled)
input int    InpMinSecondsBetweenOrders = 0;     // Min delay between orders
input double InpMaxSpreadPips           = 0;      // Max spread in pips (0=disabled)
input bool   InpUseFirstEntryRsiFilter  = false;  // Enable RSI filter for the first buy entry only
input ENUM_TIMEFRAMES InpRsiTimeframe   = PERIOD_CURRENT; // RSI timeframe
input int    InpRsiPeriod               = 14;     // RSI period
input double InpRsiThreshold            = 50.0;   // First entry allowed only if RSI < threshold
input double InpRsiMinRise              = 1.0;    // Require RSI_now - RSI_prev >= value

input group "Exit & Trailing"
input double InpBasketTPMoney           = 15.0;   // Close all when total profit >= value
input bool   InpUseBasketTrail          = true;  // Enable basket profit trailing
input double InpTrailStartMoney         = 15.0;   // Activate trailing when basket profit >= value
input double InpTrailDistanceMoney      = 3.0;    // Close all when profit drops from peak by this value

input group "Telegram Alerts"
input bool   InpWarnOnMaxPositions      = true;   // Send Telegram warning when max positions is reached
input string InpTelegramBotToken        = "8588631523:AAF6cWB6IHNkBLJyEKmATTme9E-LSSooudw";      // Telegram bot token
input string InpTelegramChatId          = "8371480289";      // Telegram chat_id

struct SLevel
{
   double lot;
   double gridPips;
};

CTrade trade;
string g_symbol = "";
bool   g_ready  = false;

datetime g_lastTradeTime = 0;

SLevel g_levels[];
int    g_levelCount = 0;
int    g_maxPositions = 0;
bool   g_trailActive = false;
double g_trailPeakProfit = 0.0;
bool   g_maxPosWarnSent = false;
int    g_lastAppliedManualCycleId = 0;
bool   g_manualBatchActive = false;
bool   g_manualPausedByBatch = false;
int    g_manualBatchStartPos = 0;
int    g_manualBatchTargetCount = 0;
double g_manualBatchLot = 0.0;
double g_manualBatchGridPips = 0.0;
int    g_rsiHandle = INVALID_HANDLE;

bool IsHedgingAccount()
{
   long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   return true;
}

double PipPoint(const string symbol)
{
   string sym = symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") >= 0)
      return 0.01;

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

double NormalizeVolume(double lot, const string symbol)
{
   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double vol = lot;
   vol = MathFloor(vol * 100.0 + 1e-8) / 100.0;
   if(vol < vmin) vol = vmin;
   if(vol > vmax) vol = vmax;
   if(vstep > 0.0)
      vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin) vol = vmin;
   vol = MathFloor(vol * 100.0 + 1e-8) / 100.0;
   return vol;
}

int CountBuyPositions(const string symbol, const long magic)
{
   int count = 0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      count++;
   }
   return count;
}

bool GetLatestBuyPosition(const string symbol, const long magic, datetime &latest_time, double &latest_price)
{
   bool found = false;
   latest_time = 0;
   latest_price = 0.0;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t > latest_time)
      {
         latest_time = t;
         latest_price = PositionGetDouble(POSITION_PRICE_OPEN);
         found = true;
      }
   }
   return found;
}

double TotalProfit(const string symbol, const long magic)
{
   double profit = 0.0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      profit += PositionGetDouble(POSITION_PROFIT);
   }
   return profit;
}

int CloseAllBuyPositions(const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Failed to close position ticket=", (string)ticket,
               " | retcode=", (string)trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      }
   }

   return CountBuyPositions(symbol, magic);
}

bool SpreadOK(const string symbol)
{
   if(InpMaxSpreadPips <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double pipPoint = PipPoint(symbol);
   if(pipPoint <= 0.0) return true;

   const double spreadPips = (ask - bid) / pipPoint;
   return (spreadPips <= InpMaxSpreadPips);
}

bool OpenBuy(const string symbol, const double lot, const string comment)
{
   if(!IsTradeAllowed())
      return false;

   const double vol = NormalizeVolume(lot, symbol);
   const bool ok = trade.Buy(vol, symbol, 0.0, 0.0, 0.0, comment);
   if(ok)
      g_lastTradeTime = TimeCurrent();
   return ok;
}

bool FirstEntryRsiOK()
{
   if(!InpUseFirstEntryRsiFilter)
      return true;

   if(g_rsiHandle == INVALID_HANDLE)
      return false;

   double rsiBuf[];
   ArrayResize(rsiBuf, 2);
   ArraySetAsSeries(rsiBuf, true);
   // Use closed bars only: shift 1 (latest closed), shift 2 (previous closed)
   const int copied = CopyBuffer(g_rsiHandle, 0, 1, 2, rsiBuf);
   if(copied < 2)
      return false;

   const double rsiNow = rsiBuf[0];
   const double rsiPrev = rsiBuf[1];
   return (rsiNow < InpRsiThreshold && (rsiNow - rsiPrev) >= InpRsiMinRise);
}

string UrlEncode(const string src)
{
   string out = "";
   const int n = StringLen(src);
   for(int i = 0; i < n; i++)
   {
      const ushort c = (ushort)StringGetCharacter(src, i);
      const bool safe = ((c >= 'a' && c <= 'z') ||
                         (c >= 'A' && c <= 'Z') ||
                         (c >= '0' && c <= '9') ||
                         c == '-' || c == '_' || c == '.' || c == '~');
      if(safe)
         out += CharToString((uchar)c);
      else if(c == ' ')
         out += "%20";
      else if(c <= 255)
         out += StringFormat("%%%02X", (int)c);
      else
         out += "%3F";
   }
   return out;
}

bool SendTelegramMessage(const string text)
{
   if(StringLen(InpTelegramBotToken) == 0 || StringLen(InpTelegramChatId) == 0)
   {
      Print("MaxPositions warning: Telegram token/chat_id is empty.");
      return false;
   }

   const string url = "https://api.telegram.org/bot" + InpTelegramBotToken + "/sendMessage";
   const string body = "chat_id=" + UrlEncode(InpTelegramChatId) + "&text=" + UrlEncode(text);
   const string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   char data[];
   char result[];
   string result_headers = "";

   int copied = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(copied > 0)
      ArrayResize(data, copied - 1);
   else
      ArrayResize(data, 0);

   ResetLastError();
   const int code = WebRequest("POST", url, headers, 5000, data, result, result_headers);
   if(code == -1)
   {
      Print("MaxPositions warning: WebRequest failed, err=", GetLastError(),
            ". Enable URL: https://api.telegram.org");
      return false;
   }

   if(code < 200 || code >= 300)
   {
      Print("MaxPositions warning: Telegram HTTP code=", code);
      return false;
   }

   Print("MaxPositions warning sent to Telegram.");
   return true;
}

void SendPauseWarning(const int posCount, const string reason)
{
   const string msg =
      "MT5 Alert: EA Paused\n" +
      "Reason: " + reason + "\n" +
      "Symbol: " + g_symbol + "\n" +
      "Magic: " + (string)InpMagic + "\n" +
      "Current: " + (string)posCount + "\n" +
      "Limit: " + (string)g_maxPositions;

   Print(msg);
   if(InpWarnOnMaxPositions)
      SendTelegramMessage(msg);
}

void ResetTrailState()
{
   g_trailActive = false;
   g_trailPeakProfit = 0.0;
}

void DeactivateManualBatch()
{
   g_manualBatchActive = false;
   g_manualBatchStartPos = 0;
   g_manualBatchTargetCount = 0;
   g_manualBatchLot = 0.0;
   g_manualBatchGridPips = 0.0;
}

void TryActivateManualBatch(const int posCount)
{
   if(InpManualResumeCycleId <= g_lastAppliedManualCycleId)
      return;

   g_lastAppliedManualCycleId = InpManualResumeCycleId;

   if(InpManualResumeLot <= 0.0 || InpManualResumeGridPips <= 0.0 || InpManualResumeCount <= 0)
   {
      Print("Manual resume ignored: invalid parameters. Need lot>0, grid>0, count>0.");
      DeactivateManualBatch();
      return;
   }

   g_manualBatchActive = true;
   g_manualPausedByBatch = false;
   g_manualBatchStartPos = posCount;
   g_manualBatchTargetCount = InpManualResumeCount;
   g_manualBatchLot = InpManualResumeLot;
   g_manualBatchGridPips = InpManualResumeGridPips;
   g_maxPosWarnSent = false;

   Print("Manual resume activated. Cycle=", InpManualResumeCycleId,
         " | StartPos=", g_manualBatchStartPos,
         " | AddCount=", g_manualBatchTargetCount,
         " | Lot=", DoubleToString(g_manualBatchLot, 2),
         " | GridPips=", DoubleToString(g_manualBatchGridPips, 1));
}

void UpdateCycleReferenceComment(const int posCount)
{
   if(!InpShowCycleRefOnChart)
      return;

   string state = "IDLE";
   if(g_manualBatchActive)
      state = "ACTIVE";
   else if(g_manualPausedByBatch)
      state = "PAUSED";

   int added = 0;
   if(g_manualBatchActive)
      added = posCount - g_manualBatchStartPos;

   string txt =
      "Manual Cycle Ref\n" +
      "Input CycleId: " + (string)InpManualResumeCycleId + "\n" +
      "Applied CycleId: " + (string)g_lastAppliedManualCycleId + "\n" +
      "State: " + state + "\n" +
      "Added/Target: " + (string)added + "/" + (string)g_manualBatchTargetCount + "\n" +
      "Positions: " + (string)posCount + "/" + (string)g_maxPositions;

   Comment(txt);
}

void PrintCsvLocationGuide(const string filename)
{
   const string dataPath = TerminalInfoString(TERMINAL_DATA_PATH);
   const string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   const bool isTester = (MQLInfoInteger(MQL_TESTER) != 0);

   Print("CSV input (relative path): ", filename);
   Print("Mode: ", (isTester ? "TESTER" : "LIVE"), " | UseCommonFiles: ", (InpUseCommonFiles ? "true" : "false"));

   if(InpUseCommonFiles)
   {
      Print("Place CSV here: ", commonPath, "\\Files\\", filename);
      Print("Note: FILE_COMMON works for both live and tester.");
   }
   else
   {
      Print("Place CSV here: ", dataPath, "\\MQL5\\Files\\", filename);
      if(isTester)
         Print("Tester mode detected: path above should point to the active tester agent data folder.");
   }
}

bool ParseCsvLevelRow(const string row, double &lot, double &gridPips)
{
   string text = row;
   StringTrimLeft(text);
   StringTrimRight(text);
   if(StringLen(text) == 0)
      return false;

   string cells[];
   int cellCount = StringSplit(text, ',', cells);
   if(cellCount != 2)
   {
      // Fallback support for semicolon-separated files.
      cellCount = StringSplit(text, ';', cells);
      if(cellCount != 2)
         return false;
   }

   string slot = cells[0];
   string sgrid = cells[1];
   StringTrimLeft(slot);
   StringTrimRight(slot);
   StringTrimLeft(sgrid);
   StringTrimRight(sgrid);

   lot = StringToDouble(slot);
   gridPips = StringToDouble(sgrid);
   if(lot <= 0.0 || gridPips <= 0.0)
      return false;

   return true;
}

bool LoadLevelTableFromCsv(const string filename)
{
   g_levelCount = 0;
   ArrayResize(g_levels, 0);

   int fileFlags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      fileFlags |= FILE_COMMON;

   ResetLastError();
   const int handle = FileOpen(filename, fileFlags);
   if(handle == INVALID_HANDLE)
   {
      const int err = GetLastError();
      Print("Failed to open CSV file: ", filename,
            " | Error: ", err,
            " | Use relative path only (no absolute path). ",
            "If InpUseCommonFiles=false place in MQL5/Files (or MQL5/Tester/Files in tester). ",
            "If InpUseCommonFiles=true place in Terminal/Common/Files.");
      PrintCsvLocationGuide(filename);
      return false;
   }

   int lineNo = 0;
   bool firstDataRowHandled = false;
   while(!FileIsEnding(handle))
   {
      lineNo++;
      string line = FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);

      if(StringLen(line) == 0)
         continue;

      if(StringGetCharacter(line, 0) == '#')
         continue;

      if(InpSkipFirstCsvRow && !firstDataRowHandled)
      {
         firstDataRowHandled = true;
         continue;
      }
      firstDataRowHandled = true;

      double lot = 0.0;
      double gridPips = 0.0;
      if(!ParseCsvLevelRow(line, lot, gridPips))
      {
         Print("Invalid CSV row #", lineNo, ": '", line, "'. Expected lot,gridPips with numeric values > 0");
         FileClose(handle);
         return false;
      }

      const int newSize = g_levelCount + 1;
      ArrayResize(g_levels, newSize);
      g_levels[g_levelCount].lot = lot;
      g_levels[g_levelCount].gridPips = gridPips;
      g_levelCount = newSize;
   }

   FileClose(handle);

   if(g_levelCount <= 0)
   {
      Print("CSV file has no valid levels: ", filename);
      return false;
   }

   ArrayResize(g_levels, g_levelCount);
   return true;
}

bool GetNextLevelByPosition(const int current_positions, int &levelIndex, double &lot, double &gridPips)
{
   if(g_levelCount <= 0)
      return false;

   int idx = current_positions;
   if(idx >= g_levelCount)
   {
      if(!InpUseLastLevelIfExceeded)
         return false;
      idx = g_levelCount - 1;
   }

   levelIndex = idx;
   lot = g_levels[idx].lot;
   gridPips = g_levels[idx].gridPips;
   return true;
}

int OnInit()
{
   g_symbol = _Symbol;
   if(!SymbolSelect(g_symbol, true))
   {
      Print("Failed to select symbol: ", g_symbol);
      return INIT_FAILED;
   }

   string sym = g_symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") < 0)
   {
      Print("This EA is focused on XAUUSD. Please attach it to an XAUUSD chart.");
      return INIT_FAILED;
   }

   if(!IsHedgingAccount())
   {
      Print("This EA requires a Hedging account type. Detected non-hedging account.");
      return INIT_FAILED;
   }

   PrintCsvLocationGuide(InpTableFile);

   if(!LoadLevelTableFromCsv(InpTableFile))
      return INIT_FAILED;

   if(InpUseFirstEntryRsiFilter)
   {
      if(InpRsiPeriod <= 1)
      {
         Print("Invalid RSI period. Must be > 1.");
         return INIT_FAILED;
      }
      g_rsiHandle = iRSI(g_symbol, InpRsiTimeframe, InpRsiPeriod, PRICE_CLOSE);
      if(g_rsiHandle == INVALID_HANDLE)
      {
         Print("Failed to create RSI handle for first-entry filter.");
         return INIT_FAILED;
      }
   }

   if(InpMaxPositions <= 0)
      g_maxPositions = 0;
   else
      g_maxPositions = InpMaxPositions;

   if(InpBasketTPMoney <= 0.0)
      Print("Basket TP is disabled (InpBasketTPMoney <= 0). Positions will not auto-close.");
   if(InpUseBasketTrail)
   {
      if(InpTrailStartMoney <= 0.0)
         Print("Trailing start is <= 0. Trailing may activate too early.");
      if(InpTrailDistanceMoney <= 0.0)
         Print("Trailing distance is <= 0. Trailing may close immediately after activation.");
   }

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;
   ResetTrailState();
   DeactivateManualBatch();
   g_manualPausedByBatch = false;
   g_maxPosWarnSent = false;

   Print("EA initialized for symbol: ", g_symbol,
         " | Levels: ", g_levelCount,
         " | CSV: ", InpTableFile,
         " | CommonFiles: ", (InpUseCommonFiles ? "true" : "false"),
         " | ManualCycleId: ", InpManualResumeCycleId,
         " | FirstEntryRSI: ", (InpUseFirstEntryRsiFilter ? "true" : "false"),
         " | WarnMaxPos: ", (InpWarnOnMaxPositions ? "true" : "false"),
         " | Use last level on exceed: ", (InpUseLastLevelIfExceeded ? "true" : "false"),
         " | Basket TP money: ", DoubleToString(InpBasketTPMoney, 2),
         " | Basket trail: ", (InpUseBasketTrail ? "true" : "false"),
         " | Trail start: ", DoubleToString(InpTrailStartMoney, 2),
         " | Trail distance: ", DoubleToString(InpTrailDistanceMoney, 2),
         " | Max positions: ", g_maxPositions);

   if(InpWarnOnMaxPositions)
      Print("To send Telegram warning, allow WebRequest URL: https://api.telegram.org");

   for(int i = 0; i < g_levelCount; i++)
   {
      Print("Level ", (i + 1), ": lot=", DoubleToString(g_levels[i].lot, 2),
            " gridPips=", DoubleToString(g_levels[i].gridPips, 1));
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_rsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_rsiHandle);
      g_rsiHandle = INVALID_HANDLE;
   }
}

void OnTick()
{
   if(!g_ready)
      return;

   if(_Symbol != g_symbol)
      return;

   const int posCount = CountBuyPositions(g_symbol, InpMagic);

   if(posCount <= 0)
   {
      ResetTrailState();
      DeactivateManualBatch();
      g_manualPausedByBatch = false;
      g_maxPosWarnSent = false;
   }

   TryActivateManualBatch(posCount);
   UpdateCycleReferenceComment(posCount);

   if(g_manualBatchActive)
   {
      if(posCount < g_manualBatchStartPos)
         g_manualBatchStartPos = posCount;

      const int added = posCount - g_manualBatchStartPos;
      if(added >= g_manualBatchTargetCount)
      {
         g_manualBatchActive = false;
         g_manualPausedByBatch = true;
         if(!g_maxPosWarnSent)
         {
            SendPauseWarning(posCount, "Manual resume batch completed");
            g_maxPosWarnSent = true;
         }
         return;
      }
      g_maxPosWarnSent = false;
   }
   else if(g_manualPausedByBatch)
      return;
   else if(g_maxPositions > 0 && posCount < g_maxPositions)
      g_maxPosWarnSent = false;

   if(posCount > 0)
   {
      const double profit = TotalProfit(g_symbol, InpMagic);

      // Optional fixed basket TP
      if(InpBasketTPMoney > 0.0 && profit >= InpBasketTPMoney)
      {
         Print("Basket TP hit. Profit=", DoubleToString(profit, 2),
               " Target=", DoubleToString(InpBasketTPMoney, 2));
         if(!IsTradeAllowed())
         {
            Print("Basket TP reached but trade is not allowed now. Will retry on next tick.");
            return;
         }

         const int remain = CloseAllBuyPositions(g_symbol, InpMagic);
         if(remain == 0)
            ResetTrailState();
         else
            Print("Basket TP close incomplete. Remaining positions=", remain);
         return;
      }

      // Optional basket trailing profit
      if(InpUseBasketTrail && InpTrailDistanceMoney > 0.0)
      {
         if(!g_trailActive && profit >= InpTrailStartMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            Print("Basket trail activated at profit ", DoubleToString(profit, 2));
         }

         if(g_trailActive)
         {
            if(profit > g_trailPeakProfit)
               g_trailPeakProfit = profit;

            const double trailStopProfit = g_trailPeakProfit - InpTrailDistanceMoney;
            if(profit <= trailStopProfit)
            {
               Print("Basket trail hit. Profit=", DoubleToString(profit, 2),
                     " Peak=", DoubleToString(g_trailPeakProfit, 2),
                     " Stop=", DoubleToString(trailStopProfit, 2));
               if(!IsTradeAllowed())
               {
                  Print("Basket trail reached but trade is not allowed now. Will retry on next tick.");
                  return;
               }

               const int remain = CloseAllBuyPositions(g_symbol, InpMagic);
               if(remain == 0)
                  ResetTrailState();
               else
                  Print("Basket trail close incomplete. Remaining positions=", remain);
               return;
            }
         }
      }
   }

   if(!g_manualBatchActive && g_maxPositions > 0 && posCount >= g_maxPositions)
   {
      if(!g_maxPosWarnSent)
      {
         SendPauseWarning(posCount, "Reached InpMaxPositions");
         g_maxPosWarnSent = true;
      }
      return;
   }

   if(!IsTradeAllowed())
      return;

   if(!SpreadOK(g_symbol))
      return;

   if(InpMinSecondsBetweenOrders > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
      return;

   double lot;
   double gridPips;
   int levelIndex = -1;
   if(g_manualBatchActive)
   {
      lot = g_manualBatchLot;
      gridPips = g_manualBatchGridPips;
   }
   else
   {
      if(!GetNextLevelByPosition(posCount, levelIndex, lot, gridPips))
         return;
   }

   if(posCount == 0)
   {
      if(!FirstEntryRsiOK())
         return;

      if(g_manualBatchActive)
         Print("Open initial buy using MANUAL resume | lot=", DoubleToString(lot, 2));
      else
         Print("Open initial buy using level ", (levelIndex + 1), " | lot=", DoubleToString(lot, 2));
      OpenBuy(g_symbol, lot, "TableGridBuy");
      return;
   }

   datetime latest_time;
   double latest_price;
   if(!GetLatestBuyPosition(g_symbol, InpMagic, latest_time, latest_price))
      return;

   const double gridPrice = gridPips * PipPoint(g_symbol);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid <= (latest_price - gridPrice))
   {
      if(g_manualBatchActive)
         Print("Open grid buy using MANUAL resume | lot=", DoubleToString(lot, 2),
               " | gridPips=", DoubleToString(gridPips, 1));
      else
         Print("Open grid buy using level ", (levelIndex + 1),
               " | lot=", DoubleToString(lot, 2),
               " | gridPips=", DoubleToString(gridPips, 1));
      OpenBuy(g_symbol, lot, "TableGridBuy");
   }
}
