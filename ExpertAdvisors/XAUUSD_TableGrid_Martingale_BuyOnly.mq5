//+----------------------------------------------------------------------+
//| XAUUSD_TableGrid_Martingale_BuyOnly.mq5                              |
//| Buy-only table-driven grid EA for XAUUSD (MT5 Hedging)               |
// Setting Telegram                                                      |
// Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL|
// https://api.telegram.org
//+----------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum EFirstEntryMaType
{
   MA_SIMPLE = 0,
   MA_EXPONENTIAL = 1
};

input group "General"
input long   InpMagic                   = 260414; // Magic number

input group "CSV Level Table"
input string InpTableFile               = "xau_levels.csv"; // CSV filename only (placed in MQL5/Files or Common/Files), format: lot,gridPips
input bool   InpSkipFirstCsvRow         = true;   // Skip first row (header)
input bool   InpUseCommonFiles          = true;  // Read CSV from Terminal/Common/Files using FILE_COMMON
input bool   InpUseLastLevelIfExceeded  = true;   // Use last table row when positions exceed table

input group "Risk & Execution"
input int    InpMaxPositions            = 0;      // Max grid positions (0=disabled)
input int    InpMinSecondsBetweenOrders = 1;     // Min delay between orders
input int    InpCooldownAfterCloseSeconds = 0;   // Cooldown after EA closes all positions (0=disabled)
input bool   InpUseCloseLock            = true;   // Use close-lock mode until all positions are closed
input bool   InpUsePriorityCloseOrder   = true;   // Close by priority (lot desc, then profit asc)
input bool   InpUseAsyncClose           = true;   // Send close requests asynchronously for faster batch close
input int    InpCloseDeviationPoints    = 300;    // Max deviation in points for close requests (<=0 uses platform default)
input int    InpCloseAttemptsPerRun     = 1;      // Max close-all retries in one run (keep 1 for async burst)
input int    InpCloseLockTimerMs        = 100;    // Close-lock timer interval (ms, 0=off)
input double InpMaxSpreadFirstEntryPips = 50;      // Max spread for first entry in pips (0=disabled)
input double InpMaxSpreadGridEntryPips  = 50;      // Max spread for grid entry in pips (0=disabled)

input group "First Entry Filters"
input bool   InpUseFirstEntryRsiFilter  = false;  // Enable RSI filter for the first buy entry only
input bool   InpUseFirstEntryMaFilter   = true;   // Enable MA filter for first entry
input bool   InpUseFirstEntryFullCandleBelowMa = false; // MA mode: true=previous candle high < MA, false=Bid < MA
input bool   InpUseFirstEntryBullishCandle = false; // First entry: previous candle must be bullish
input int    InpFirstEntryMaPeriod      = 5;      // First entry MA period
input EFirstEntryMaType InpFirstEntryMaType = MA_EXPONENTIAL; // MA type: simple/exponential
input int    InpRsiPeriod               = 14;     // RSI period
input double InpRsiThreshold            = 50.0;   // First entry allowed only if RSI < threshold
input double InpRsiMinRise              = 1.0;    // Require RSI_now - RSI_prev >= value

input group "Exit & Trailing"
input double InpBasketTPDefaultMoney    = 15;   // Fallback basket TP when no grid-specific TP applies
input double InpBasketTPGrid1Money      = 1.5;  // Basket TP when grid count is 1
input double InpBasketTPGrid2Money      = 3.5;  // Basket TP when grid count is 2
input double InpBasketTPGrid3Money      = 7.0;  // Basket TP when grid count is 3
input double InpFloatingStopLossMoney   = 3000.0;  // Close all + stop trading when floating profit <= -value (0=off)
input bool   InpUseBasketTrail          = true;  // Enable basket profit trailing
input int    InpTrailGridFrom           = 6;     // Trailing starts from this grid count
input int    InpTrailGridTo             = 1000;     // Trailing ends at this grid count (0=no upper limit)
input double InpTrailStartMoney         = 18.0;   // Activate trailing when basket profit >= value
input double InpTrailDistanceMoney      = 5.0;    // Close all when profit drops from peak by this value

input group "Telegram Alerts"
input bool   InpWarnOnMaxPositions      = false;   // Send Telegram warning when max positions is reached
input string InpFloatingLossLevels      = "1000,2000"; // Floating loss alert levels (comma-separated)

struct SLevel
{
   double lot;
   double gridPips;
};

CTrade trade;
string g_symbol = "";
bool   g_ready  = false;

datetime g_lastTradeTime = 0;
datetime g_lastCloseAllTime = 0;

SLevel g_levels[];
int    g_levelCount = 0;
int    g_maxPositions = 0;
bool   g_trailActive = false;
double g_trailPeakProfit = 0.0;
bool   g_maxPosWarnSent = false;
int    g_rsiHandle = INVALID_HANDLE;
int    g_maHandle = INVALID_HANDLE;
double g_floatingAlertLevels[];
bool   g_floatingAlertSent[];
bool   g_closeLockActive = false;
int    g_closeLockLastRemain = -1;
bool   g_closeLockWaitTradePrinted = false;
bool   g_stopTradingByFloatingSL = false;
bool   g_prevTerminalTradeAllowed = true;

// Hardcoded Telegram credentials (hidden from EA Properties/.set)
const string TG_BOT_TOKEN = "8588631523:AAF6cWB6IHNkBLJyEKmATTme9E-LSSooudw";
const string TG_CHAT_ID   = "8371480289";

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

bool GetLatestBuyPosition(const string symbol, const long magic, double &latest_price)
{
   bool found = false;
   datetime latest_time = 0;
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
   const bool useCustomDeviation = (InpCloseDeviationPoints > 0);
   const ulong closeDeviation = (useCustomDeviation ? (ulong)InpCloseDeviationPoints : 0);
   const bool useAsyncClose = InpUseAsyncClose;

   if(useAsyncClose)
      trade.SetAsyncMode(true);

   if(InpUsePriorityCloseOrder)
   {
      // Build close queue:
      // 1) larger volume first (reduce exposure faster)
      // 2) if equal volume, worse profit first
      ulong tickets[];
      double vols[];
      double profits[];
      int q = 0;

      const int total = PositionsTotal();
      for(int i = 0; i < total; i++)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

         const int n = q + 1;
         ArrayResize(tickets, n);
         ArrayResize(vols, n);
         ArrayResize(profits, n);
         tickets[q] = ticket;
         vols[q] = PositionGetDouble(POSITION_VOLUME);
         profits[q] = PositionGetDouble(POSITION_PROFIT);
         q = n;
      }

      // Simple in-place sort for queue size used in grid EA.
      for(int i = 0; i < q - 1; i++)
      {
         int best = i;
         for(int j = i + 1; j < q; j++)
         {
            bool better = false;
            if(vols[j] > vols[best])
               better = true;
            else if(vols[j] == vols[best] && profits[j] < profits[best])
               better = true;

            if(better)
               best = j;
         }

         if(best != i)
         {
            const ulong tTicket = tickets[i];
            tickets[i] = tickets[best];
            tickets[best] = tTicket;

            const double tVol = vols[i];
            vols[i] = vols[best];
            vols[best] = tVol;

            const double tProfit = profits[i];
            profits[i] = profits[best];
            profits[best] = tProfit;
         }
      }

      for(int i = 0; i < q; i++)
      {
         const ulong ticket = tickets[i];
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

         const bool closeOk = (useCustomDeviation ?
                               trade.PositionClose(ticket, closeDeviation) :
                               trade.PositionClose(ticket));
         if(!closeOk)
         {
            Print("Close fail | ticket=", (string)ticket,
                  " | retcode=", (string)trade.ResultRetcode(),
                  " | desc=", trade.ResultRetcodeDescription());
         }
      }
   }
   else
   {
      // Legacy close order (index descending) for A/B testing.
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

         const bool closeOk = (useCustomDeviation ?
                               trade.PositionClose(ticket, closeDeviation) :
                               trade.PositionClose(ticket));
         if(!closeOk)
         {
            Print("Close fail | ticket=", (string)ticket,
                  " | retcode=", (string)trade.ResultRetcode(),
                  " | desc=", trade.ResultRetcodeDescription());
         }
      }
   }

   if(useAsyncClose)
      trade.SetAsyncMode(false);

   const int remain = CountBuyPositions(symbol, magic);
   if(remain == 0)
      g_lastCloseAllTime = TimeCurrent();
   return remain;
}

int CloseAllBuyPositionsWithRetries(const string symbol, const long magic, const int maxAttempts)
{
   int attempts = maxAttempts;
   if(attempts <= 0)
      attempts = 1;
   if(InpUseAsyncClose && attempts > 1)
      attempts = 1;

   int remain = CountBuyPositions(symbol, magic);
   int prevRemain = remain + 1;
   for(int attempt = 0; attempt < attempts && remain > 0; attempt++)
   {
      remain = CloseAllBuyPositions(symbol, magic);
      if(remain >= prevRemain)
         break;
      prevRemain = remain;
   }

   return remain;
}

bool SpreadOK(const string symbol, const double maxSpreadPips)
{
   if(maxSpreadPips <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double pipPoint = PipPoint(symbol);
   if(pipPoint <= 0.0) return true;

   const double spreadPips = (ask - bid) / pipPoint;
   return (spreadPips <= maxSpreadPips);
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

bool FirstEntryMaOK()
{
   if(!InpUseFirstEntryMaFilter)
      return true;

   if(g_maHandle == INVALID_HANDLE)
      return false;

   double maBuf[];
   ArrayResize(maBuf, 2);
   ArraySetAsSeries(maBuf, true);
   const int copied = CopyBuffer(g_maHandle, 0, 0, 2, maBuf);
   if(copied < 2)
      return false;

   if(InpUseFirstEntryFullCandleBelowMa)
   {
      // Use previous closed candle: require full candle below MA (high < MA).
      const double h = iHigh(g_symbol, PERIOD_CURRENT, 1);
      if(h == 0.0)
         return false;
      return (h < maBuf[1]);
   }

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   return (bid < maBuf[0]);
}

bool FirstEntryBullishCandleOK()
{
   if(!InpUseFirstEntryBullishCandle)
      return true;

   // Use previous closed candle on current chart timeframe.
   const double o = iOpen(g_symbol, PERIOD_CURRENT, 1);
   const double c = iClose(g_symbol, PERIOD_CURRENT, 1);
   if(o == 0.0 && c == 0.0)
      return false;

   return (c > o);
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
   if(StringLen(TG_BOT_TOKEN) == 0 || StringLen(TG_CHAT_ID) == 0)
   {
      Print("Telegram skip | token/chat_id empty");
      return false;
   }

   const string url = "https://api.telegram.org/bot" + TG_BOT_TOKEN + "/sendMessage";
   const string body = "chat_id=" + UrlEncode(TG_CHAT_ID) + "&text=" + UrlEncode(text);
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
      Print("Telegram fail | err=", GetLastError(),
            " | allow_url=https://api.telegram.org");
      return false;
   }

   if(code < 200 || code >= 300)
   {
      Print("Telegram fail | http_code=", code);
      return false;
   }

   Print("Telegram OK | pause warning sent");
   return true;
}

void SendPauseWarning(const int posCount, const string reason)
{
   const string accountName = AccountInfoString(ACCOUNT_NAME);
   const string msg =
      "EA Paused | " + reason + "\n" +
      "Acct: " + accountName + "\n" +
      "Sym: " + g_symbol + "\n" +
      "Pos: " + (string)posCount + "/" + (string)g_maxPositions;

   Print(msg);
   if(InpWarnOnMaxPositions)
      SendTelegramMessage(msg);
}

void ResetTrailState()
{
   g_trailActive = false;
   g_trailPeakProfit = 0.0;
}

void ActivateCloseLock(const string reason)
{
   if(!g_closeLockActive)
      Print("Close lock ON | reason=", reason);

   g_closeLockActive = true;
   g_closeLockLastRemain = -1;
   g_closeLockWaitTradePrinted = false;
}

void DeactivateCloseLock()
{
   if(g_closeLockActive)
      Print("Close lock OFF | all positions closed");

   g_closeLockActive = false;
   g_closeLockLastRemain = -1;
   g_closeLockWaitTradePrinted = false;
}

void SetDefaultFloatingAlertLevels()
{
   ArrayResize(g_floatingAlertLevels, 7);
   g_floatingAlertLevels[0] = 5000.0;
   g_floatingAlertLevels[1] = 10000.0;
   g_floatingAlertLevels[2] = 20000.0;
   g_floatingAlertLevels[3] = 30000.0;
   g_floatingAlertLevels[4] = 50000.0;
   g_floatingAlertLevels[5] = 70000.0;
   g_floatingAlertLevels[6] = 90000.0;
}

bool LoadFloatingAlertLevelsFromInput(const string rawInput)
{
   string text = rawInput;
   StringTrimLeft(text);
   StringTrimRight(text);
   if(StringLen(text) == 0)
      return false;

   StringReplace(text, ";", ",");
   StringReplace(text, "|", ",");
   StringReplace(text, " ", "");

   string parts[];
   const int partCount = StringSplit(text, ',', parts);
   if(partCount <= 0)
      return false;

   ArrayResize(g_floatingAlertLevels, 0);
   int validCount = 0;
   for(int i = 0; i < partCount; i++)
   {
      string token = parts[i];
      StringTrimLeft(token);
      StringTrimRight(token);
      if(StringLen(token) == 0)
         continue;

      const double level = StringToDouble(token);
      if(level <= 0.0)
         continue;

      const int newSize = validCount + 1;
      ArrayResize(g_floatingAlertLevels, newSize);
      g_floatingAlertLevels[validCount] = level;
      validCount = newSize;
   }

   if(validCount <= 0)
   {
      ArrayResize(g_floatingAlertLevels, 0);
      return false;
   }

   // Ensure ascending order so alerts trigger from smaller loss to larger loss.
   ArraySort(g_floatingAlertLevels);

   // Remove duplicate levels to avoid duplicate alerts at the same threshold.
   int uniqueCount = 0;
   for(int i = 0; i < validCount; i++)
   {
      if(i == 0 || g_floatingAlertLevels[i] != g_floatingAlertLevels[i - 1])
      {
         g_floatingAlertLevels[uniqueCount] = g_floatingAlertLevels[i];
         uniqueCount++;
      }
   }
   ArrayResize(g_floatingAlertLevels, uniqueCount);
   return true;
}

void ResetFloatingAlertState()
{
   const int n = ArraySize(g_floatingAlertLevels);
   ArrayResize(g_floatingAlertSent, n);
   for(int i = 0; i < n; i++)
      g_floatingAlertSent[i] = false;
}

void CheckFloatingLossAlerts(const double floatingProfit, const int posCount)
{
   if(posCount <= 0)
      return;

   const int n = ArraySize(g_floatingAlertLevels);
   if(ArraySize(g_floatingAlertSent) != n)
      ResetFloatingAlertState();

   for(int i = 0; i < n; i++)
   {
      if(g_floatingAlertSent[i])
         continue;

      const double level = g_floatingAlertLevels[i];
      if(floatingProfit <= -level)
      {
         const string msg =
            "Floating Alert\n" +
            "Acct: " + AccountInfoString(ACCOUNT_NAME) + "\n" +
            "Sym: " + g_symbol + "\n" +
            "Floating: " + DoubleToString(floatingProfit, 2) + "\n" +
            "Level: -" + DoubleToString(level, 0);

         Print(msg);
         SendTelegramMessage(msg);
         g_floatingAlertSent[i] = true;
      }
   }
}

bool ProcessCloseLock(const int posCount)
{
   if(!InpUseCloseLock)
      return false;
   if(!g_closeLockActive)
      return false;

   if(posCount <= 0)
   {
      DeactivateCloseLock();
      return true;
   }

   if(!IsTradeAllowed())
   {
      if(!g_closeLockWaitTradePrinted)
      {
         Print("Close lock wait | trade not allowed");
         g_closeLockWaitTradePrinted = true;
      }
      return true;
   }

   g_closeLockWaitTradePrinted = false;
   const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
   if(remain == 0)
   {
      ResetTrailState();
      DeactivateCloseLock();
   }
   else if(remain != g_closeLockLastRemain)
   {
      Print("Close lock running | remain=", remain);
      g_closeLockLastRemain = remain;
   }

   return true;
}

void PrintCsvLocationGuide(const string filename)
{
   const string dataPath = TerminalInfoString(TERMINAL_DATA_PATH);
   const string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   const bool isTester = (MQLInfoInteger(MQL_TESTER) != 0);

   Print("CSV config | file=", filename);
   Print("CSV mode | run=", (isTester ? "TESTER" : "LIVE"),
         " | use_common=", (InpUseCommonFiles ? "true" : "false"));

   if(InpUseCommonFiles)
   {
      Print("CSV path | ", commonPath, "\\Files\\", filename);
      Print("CSV note | FILE_COMMON works in live and tester");
   }
   else
   {
      Print("CSV path | ", dataPath, "\\MQL5\\Files\\", filename);
      if(isTester)
         Print("CSV note | tester uses active agent data folder");
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
      Print("CSV open fail | file=", filename,
            " | err=", err,
            " | use_relative_path=true");
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
         Print("CSV row invalid | line=", lineNo,
               " | row='", line, "' | expected=lot,gridPips (>0)");
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
      Print("CSV invalid | no valid levels | file=", filename);
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
      Print("Init fail | symbol select | symbol=", g_symbol);
      return INIT_FAILED;
   }

   string sym = g_symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") < 0)
   {
      Print("Init fail | symbol must contain XAUUSD");
      return INIT_FAILED;
   }

   if(!IsHedgingAccount())
   {
      Print("Init fail | account type must be HEDGING");
      return INIT_FAILED;
   }

   PrintCsvLocationGuide(InpTableFile);

   if(!LoadLevelTableFromCsv(InpTableFile))
      return INIT_FAILED;

   if(InpUseFirstEntryRsiFilter)
   {
      if(InpRsiPeriod <= 1)
      {
         Print("Init fail | invalid RSI period | need > 1");
         return INIT_FAILED;
      }
      g_rsiHandle = iRSI(g_symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE);
      if(g_rsiHandle == INVALID_HANDLE)
      {
      Print("Init fail | cannot create RSI handle");
         return INIT_FAILED;
      }
   }

   if(InpUseFirstEntryMaFilter)
   {
      if(InpFirstEntryMaPeriod <= 0)
      {
         Print("Init fail | invalid MA period | need > 0");
         return INIT_FAILED;
      }

      const ENUM_MA_METHOD maMethod = (InpFirstEntryMaType == MA_SIMPLE ? MODE_SMA : MODE_EMA);
      g_maHandle = iMA(g_symbol, PERIOD_CURRENT, InpFirstEntryMaPeriod, 0, maMethod, PRICE_CLOSE);
      if(g_maHandle == INVALID_HANDLE)
      {
         Print("Init fail | cannot create MA handle for first entry");
         return INIT_FAILED;
      }
   }

   if(InpMaxPositions <= 0)
      g_maxPositions = 0;
   else
      g_maxPositions = InpMaxPositions;

   if(InpBasketTPDefaultMoney <= 0.0)
      Print("Info | basket_tp=OFF");
   if(InpUseBasketTrail)
   {
      if(InpTrailStartMoney <= 0.0)
         Print("Warn | trail_start<=0");
      if(InpTrailDistanceMoney <= 0.0)
         Print("Warn | trail_distance<=0");
   }

   if(!LoadFloatingAlertLevelsFromInput(InpFloatingLossLevels))
   {
      SetDefaultFloatingAlertLevels();
      Print("Warn | floating_levels invalid -> fallback to default");
   }

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;
   ResetTrailState();
   ResetFloatingAlertState();
   DeactivateCloseLock();
   g_maxPosWarnSent = false;
   g_stopTradingByFloatingSL = false;
   g_prevTerminalTradeAllowed = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);

   if(InpCloseLockTimerMs > 0)
   {
      if(!EventSetMillisecondTimer(InpCloseLockTimerMs))
         Print("Warn | timer setup failed | ms=", InpCloseLockTimerMs);
   }

   Print("EA init OK | Symbol=", g_symbol,
         " | Levels: ", g_levelCount,
         " | CSV: ", InpTableFile,
         " | CommonFiles: ", (InpUseCommonFiles ? "true" : "false"),
         " | FirstEntryRSI: ", (InpUseFirstEntryRsiFilter ? "true" : "false"),
         " | FirstEntryMA: ", (InpUseFirstEntryMaFilter ? "true" : "false"),
         " | MA mode: ", (InpUseFirstEntryFullCandleBelowMa ? "full_candle_below" : "bid_below"),
         " | MA period/type: ", (string)InpFirstEntryMaPeriod, "/",
         (InpFirstEntryMaType == MA_SIMPLE ? "SMA" : "EMA"),
         " | FirstEntryBullishCandle: ", (InpUseFirstEntryBullishCandle ? "true" : "false"),
         " | WarnPause: ", (InpWarnOnMaxPositions ? "true" : "false"),
         " | UseCloseLock: ", (InpUseCloseLock ? "true" : "false"),
         " | PriorityCloseOrder: ", (InpUsePriorityCloseOrder ? "true" : "false"),
         " | UseAsyncClose: ", (InpUseAsyncClose ? "true" : "false"),
         " | CloseDeviationPoints: ", (string)InpCloseDeviationPoints,
         " | CloseAttemptsPerRun: ", (string)InpCloseAttemptsPerRun,
         " | CloseLockTimerMs: ", (string)InpCloseLockTimerMs,
         " | MaxSpreadFirst: ", DoubleToString(InpMaxSpreadFirstEntryPips, 1),
         " | MaxSpreadGrid: ", DoubleToString(InpMaxSpreadGridEntryPips, 1),
         " | Use last level on exceed: ", (InpUseLastLevelIfExceeded ? "true" : "false"),
         " | Basket TP default: ", DoubleToString(InpBasketTPDefaultMoney, 2),
         " | Floating SL stop: ", DoubleToString(InpFloatingStopLossMoney, 2),
         " | Basket trail: ", (InpUseBasketTrail ? "true" : "false"),
         " | Trail grid range: ", (string)InpTrailGridFrom, "-", (InpTrailGridTo == 0 ? "INF" : (string)InpTrailGridTo),
         " | Trail start: ", DoubleToString(InpTrailStartMoney, 2),
         " | Trail distance: ", DoubleToString(InpTrailDistanceMoney, 2),
         " | Max positions: ", g_maxPositions);

   if(InpWarnOnMaxPositions)
      Print("Telegram setup | allow_url=https://api.telegram.org");

   for(int i = 0; i < g_levelCount; i++)
   {
      Print("Level ", (i + 1), " | lot=", DoubleToString(g_levels[i].lot, 2),
            " | gridPips=", DoubleToString(g_levels[i].gridPips, 1));
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   if(g_rsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_rsiHandle);
      g_rsiHandle = INVALID_HANDLE;
   }

   if(g_maHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_maHandle);
      g_maHandle = INVALID_HANDLE;
   }
}

void OnTimer()
{
   if(!g_ready)
      return;
   if(!InpUseCloseLock)
      return;
   if(!g_closeLockActive)
      return;

   const int posCount = CountBuyPositions(g_symbol, InpMagic);
   const bool terminalTradeAllowed = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);

   if(!g_prevTerminalTradeAllowed && terminalTradeAllowed)
   {
      if(g_stopTradingByFloatingSL)
      {
         if(posCount <= 0)
         {
            g_stopTradingByFloatingSL = false;
            ResetTrailState();
            ResetFloatingAlertState();
            g_maxPosWarnSent = false;
            Print("Floating SL stop reset | reason=terminal_algo_toggled_on");
         }
         else
         {
            Print("Floating SL stop keep active | reason=positions_not_flat | pos=", posCount);
         }
      }
   }
   g_prevTerminalTradeAllowed = terminalTradeAllowed;
   ProcessCloseLock(posCount);
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
      // In async close mode, the last close can complete after close requests are sent.
      // Record close-all time here so cooldown still applies before any new entry.
      if(g_closeLockActive)
         g_lastCloseAllTime = TimeCurrent();

      ResetTrailState();
      ResetFloatingAlertState();
      DeactivateCloseLock();
      g_maxPosWarnSent = false;
   }

   if(ProcessCloseLock(posCount))
      return;

   if(g_stopTradingByFloatingSL)
   {
      if(posCount > 0)
      {
         if(InpUseCloseLock)
         {
            ActivateCloseLock("floating_sl_stop");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Floating SL stop wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Floating SL stop close partial | remain=", remain);
         }
      }
      return;
   }

   if(g_maxPositions > 0 && posCount < g_maxPositions)
      g_maxPosWarnSent = false;

   if(posCount > 0)
   {
      const double profit = TotalProfit(g_symbol, InpMagic);
      CheckFloatingLossAlerts(profit, posCount);
      if(InpFloatingStopLossMoney > 0.0 && profit <= -InpFloatingStopLossMoney)
      {
         g_stopTradingByFloatingSL = true;

         const string msg =
            "Floating SL Stop Triggered\n" +
            "Acct: " + AccountInfoString(ACCOUNT_NAME) + "\n" +
            "Sym: " + g_symbol + "\n" +
            "Floating: " + DoubleToString(profit, 2) + "\n" +
            "Limit: -" + DoubleToString(InpFloatingStopLossMoney, 2) + "\n" +
            "Action: close all + stop trading";

         Print(msg);
         SendTelegramMessage(msg);

         if(InpUseCloseLock)
         {
            ActivateCloseLock("floating_sl_stop");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Floating SL stop wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Floating SL stop close partial | remain=", remain);
         }
         return;
      }
      double forcedTpMoney = 0.0;
      bool forceTrailOff = false;
      const bool trailRangeValid = (InpTrailGridFrom > 0 && (InpTrailGridTo == 0 || InpTrailGridTo >= InpTrailGridFrom));
      const bool trailGridInRange =
         trailRangeValid &&
         posCount >= InpTrailGridFrom &&
         (InpTrailGridTo == 0 || posCount <= InpTrailGridTo);

      // Requested behavior:
      // - Grid 1..3: trailing OFF, basket TP fixed to 2/4/8
      // - Grid 4+: trailing can run normally
      if(posCount == 1)
      {
         forcedTpMoney = InpBasketTPGrid1Money;
         forceTrailOff = true;
      }
      else if(posCount == 2)
      {
         forcedTpMoney = InpBasketTPGrid2Money;
         forceTrailOff = true;
      }
      else if(posCount == 3)
      {
         forcedTpMoney = InpBasketTPGrid3Money;
         forceTrailOff = true;
      }

      const bool useTrailForThisGrid =
         (!forceTrailOff &&
          InpUseBasketTrail &&
          trailGridInRange &&
          InpTrailDistanceMoney > 0.0);

      if(forceTrailOff && g_trailActive)
      {
         Print("Basket trail OFF | reason=grid<=3");
         ResetTrailState();
      }
      else if(!forceTrailOff && g_trailActive && !useTrailForThisGrid)
      {
         Print("Basket trail OFF | reason=grid_outside_trail_range");
         ResetTrailState();
      }

      if(forcedTpMoney > 0.0 && profit >= forcedTpMoney)
      {
         Print("Forced TP hit | grid=", posCount,
               " | profit=", DoubleToString(profit, 2),
               " | target=", DoubleToString(forcedTpMoney, 2));
         if(InpUseCloseLock)
         {
            ActivateCloseLock("forced_tp");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Forced TP wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Forced TP close partial | remain=", remain);
         }
         return;
      }

      // Fixed basket TP default is used only when trailing is not active for this grid.
      if(!forceTrailOff && !useTrailForThisGrid &&
         InpBasketTPDefaultMoney > 0.0 && profit >= InpBasketTPDefaultMoney)
      {
         Print("Basket TP hit | profit=", DoubleToString(profit, 2),
               " | target=", DoubleToString(InpBasketTPDefaultMoney, 2));
         if(InpUseCloseLock)
         {
            ActivateCloseLock("basket_tp");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Basket TP wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Basket TP close partial | remain=", remain);
         }
         return;
      }

      // Trailing profit is used only for configured trail grid range.
      if(useTrailForThisGrid)
      {
         if(!g_trailActive && profit >= InpTrailStartMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            Print("Basket trail ON | start_profit=", DoubleToString(profit, 2));
         }

         if(g_trailActive)
         {
            if(profit > g_trailPeakProfit)
               g_trailPeakProfit = profit;

            const double trailStopProfit = g_trailPeakProfit - InpTrailDistanceMoney;
            if(profit <= trailStopProfit)
            {
               Print("Basket trail hit | profit=", DoubleToString(profit, 2),
                     " | peak=", DoubleToString(g_trailPeakProfit, 2),
                     " | stop=", DoubleToString(trailStopProfit, 2));
               if(InpUseCloseLock)
               {
                  ActivateCloseLock("basket_trail");
                  ProcessCloseLock(posCount);
               }
               else
               {
                  if(!IsTradeAllowed())
                  {
                     Print("Basket trail wait | trade not allowed");
                     return;
                  }

                  const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
                  if(remain == 0)
                     ResetTrailState();
                  else
                     Print("Basket trail close partial | remain=", remain);
               }
               return;
            }
         }
      }
   }

   if(g_maxPositions > 0 && posCount >= g_maxPositions)
   {
      if(!g_maxPosWarnSent)
      {
         SendPauseWarning(posCount, "Max positions reached");
         g_maxPosWarnSent = true;
      }
      return;
   }

   if(!IsTradeAllowed())
      return;

   if(InpCooldownAfterCloseSeconds > 0 &&
      g_lastCloseAllTime > 0 &&
      (TimeCurrent() - g_lastCloseAllTime) < InpCooldownAfterCloseSeconds)
      return;

   if(InpMinSecondsBetweenOrders > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
      return;

   double lot;
   double gridPips;
   int levelIndex = -1;
   if(!GetNextLevelByPosition(posCount, levelIndex, lot, gridPips))
      return;

   if(posCount == 0)
   {
      if(!SpreadOK(g_symbol, InpMaxSpreadFirstEntryPips))
         return;

      if(!FirstEntryRsiOK())
         return;
      if(!FirstEntryMaOK())
         return;
      if(!FirstEntryBullishCandleOK())
         return;

      Print("Open first entry | level=", (levelIndex + 1), " | lot=", DoubleToString(lot, 2));
      OpenBuy(g_symbol, lot, "TableGridBuy");
      return;
   }

   double latest_price;
   if(!GetLatestBuyPosition(g_symbol, InpMagic, latest_price))
      return;

   const double gridPrice = gridPips * PipPoint(g_symbol);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid < (latest_price - gridPrice))
   {
      if(!SpreadOK(g_symbol, InpMaxSpreadGridEntryPips))
         return;

      Print("Open grid entry | level=", (levelIndex + 1),
            " | lot=", DoubleToString(lot, 2),
            " | gridPips=", DoubleToString(gridPips, 1));
      OpenBuy(g_symbol, lot, "TableGridBuy");
   }
}
