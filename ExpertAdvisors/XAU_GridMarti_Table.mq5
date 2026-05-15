//+----------------------------------------------------------------------+
//| XAU_GridMarti_Table.mq5                                      |
//| Directional table-driven grid EA for XAUUSD (MT5 Hedging)            |
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

enum ESessionTimeMode
{
   SESSION_TIME_BROKER = 0,
   SESSION_TIME_UTC = 1,
   SESSION_TIME_WIB = 2
};

enum ETradeMode
{
   TRADE_BUY_ONLY = 0,
   TRADE_SELL_ONLY = 1
};

input group "General"
input long   InpMagic                   = 790101; // Magic number->[SYMBOL][EA][TF/SET]
input ETradeMode InpTradeMode           = TRADE_BUY_ONLY; // Trading direction: buy-only or sell-only

input group "CSV Level Table"
input string InpTableFile               = "T1_680.csv"; // CSV filename only (placed in MQL5/Files or Common/Files), format: lot,gridPoints,tpMoney
input bool   InpSkipFirstCsvRow         = true;   // Skip first row (header)
input bool   InpUseCommonFiles          = true;  // Read CSV from Terminal/Common/Files using FILE_COMMON

input group "Risk & Execution"
input int    InpMaxPositions            = 0;      // Max grid positions (0=disabled)
input int    InpMinSecondsBetweenOrders = 0;     // Min delay between orders
input bool   InpUseCloseLock            = true;   // Use close-lock mode until all positions are closed
input bool   InpUsePriorityCloseOrder   = true;   // Close by priority (lot desc, then profit asc)
input bool   InpUseAsyncClose           = true;   // Send close requests asynchronously for faster batch close
input double InpCloseDeviationPips      = 30.0;   // Max deviation in pips for close requests (<=0 uses platform default)
input int    InpCloseAttemptsPerRun     = 1;      // Max close-all retries in one run (keep 1 for async burst)
input int    InpCloseLockTimerMs        = 300;    // Close-lock timer interval (ms, 0=off)
input double InpMaxSpreadFirstEntryPips = 50;      // Max spread for first entry in pips (0=disabled)
input double InpMaxSpreadGridEntryPips  = 200;      // Max spread for grid entry in pips (0=disabled)

input group "Trading Session"
input bool   InpUseTimeFilter           = false;   // Enable trading session filter
input ESessionTimeMode InpSessionTimeMode = SESSION_TIME_UTC; // Session input timezone: broker/UTC/WIB(UTC+7)
input int    InpStartHourBroker         = 1;      // Start first entries from this hour in selected session timezone (00-23)
input int    InpPauseHourBroker         = 18;     // Pause-prep starts from this hour in selected session timezone (00-23)

input group "First Entry Filters"
input bool   InpFirstEntryOnNextCandleOpen = true; // First entry only on next candle open (first tick of new bar)
input bool   InpUseFirstEntryRsiFilter  = false;  // Enable RSI filter for the first entry only
input bool   InpUseFirstEntryMaFilter   = false;   // Enable MA filter for first entry
input bool   InpUseFirstEntryFullCandleBelowMa = false; // MA mode: true=previous candle high < MA, false=Bid < MA
input bool   InpUseFirstEntryBullishCandle = false; // First entry candle direction filter (buy=bullish, sell=bearish)
input int    InpFirstEntryMaPeriod      = 5;      // First entry MA period
input EFirstEntryMaType InpFirstEntryMaType = MA_EXPONENTIAL; // MA type: simple/exponential
input int    InpRsiPeriod               = 14;     // RSI period
input double InpRsiThreshold            = 50.0;   // First entry allowed only if RSI < threshold
input double InpRsiMinRise              = 1.0;    // Require RSI_now - RSI_prev >= value

input group "Exit & Trailing"
input bool   InpUseBasketTrail          = true;  // Enable basket profit trailing
input double InpTrailStartMoney         = 100.0;   // Mode switch: table TP <= value => fixed TP, table TP > value => start trailing after profit reaches table TP
input double InpTrailDistancePercent    = 30.0;   // Close all when profit drops this % from peak (e.g. 33 => keep ~67% of peak)
input double InpFloatingDDStopMoney     = 0.0;  // Close all + stop trading when floating drawdown >= value (0=off)

input group "Telegram Alerts"
input string InpTelegramBotToken        = "8383407093:AAFGHJ6oBVHtvRsJel2NQUOklbeOwtxtdVk"; // Telegram bot token
input string InpTelegramChatId          = "1448627275"; // Telegram chat id
input bool   InpNotifyFloatingSLStop    = false;    // Send Telegram alert when floating SL stop is triggered
input bool   InpNotifyEaActive          = true;    // Send periodic Telegram message that EA is active
input int    InpEaActiveIntervalMinutes = 10;      // Periodic active message interval in minutes

input group "Daily Stats"
input bool   InpEnableDailyStats        = false;    // Track and save daily profit + max DD for this EA (symbol+magic)
input string InpDailyStatsFolder        = "DailyStats"; // Output subfolder under Files for daily stats CSV (blank=root Files)
input bool   InpLogDailyStatsSummary    = false;    // Print daily summary when day changes/deinit

struct SLevel
{
   double lot;
   double gridPoints;
   double tpMoney;
};

struct SPositionSnapshot
{
   int count;
   double totalProfit;
   bool hasLatestPosition;
   double latestPrice;
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
int    g_rsiHandle = INVALID_HANDLE;
int    g_maHandle = INVALID_HANDLE;
bool   g_closeLockActive = false;
int    g_closeLockLastRemain = -1;
bool   g_closeLockWaitTradePrinted = false;
bool   g_stopTradingByFloatingSL = false;
bool   g_sessionPauseUntilStart = false;
bool   g_dailyStatsInitialized = false;
int    g_dailyDateKey = 0;
datetime g_dailyStartTime = 0;
double g_dailyClosedProfit = 0.0;
double g_dailyMaxDd = 0.0;
datetime g_lastActiveNotifyTime = 0;
datetime g_lastActiveNotifyAttemptTime = 0;
string g_dailyStatsFile = "";
bool   g_lastAlgoTradingEnabled = true;
datetime g_lastFirstEntryBarTime = 0;
int    g_lastKnownPosCount = 0;

string CleanRelativeFolder(const string folder)
{
   string cleaned = folder;
   StringTrimLeft(cleaned);
   StringTrimRight(cleaned);

   while(StringLen(cleaned) > 0)
   {
      const ushort ch = StringGetCharacter(cleaned, StringLen(cleaned) - 1);
      if(ch != '\\' && ch != '/')
         break;
      cleaned = StringSubstr(cleaned, 0, StringLen(cleaned) - 1);
   }

   while(StringLen(cleaned) > 0)
   {
      const ushort ch = StringGetCharacter(cleaned, 0);
      if(ch != '\\' && ch != '/')
         break;
      cleaned = StringSubstr(cleaned, 1);
   }

   return cleaned;
}

string FileNameOnly(const string path)
{
   int startIndex = 0;
   const int len = StringLen(path);
   for(int i = len - 1; i >= 0; i--)
   {
      const ushort ch = StringGetCharacter(path, i);
      if(ch == '\\' || ch == '/')
      {
         startIndex = i + 1;
         break;
      }
   }

   return StringSubstr(path, startIndex);
}

string BuildDailyStatsFileFromTableFile(const string tableFile)
{
   const long userId = AccountInfoInteger(ACCOUNT_LOGIN);
   string baseName = FileNameOnly(tableFile);
   string extension = ".csv";
   const int len = StringLen(baseName);
   int dotIndex = -1;
   for(int i = len - 1; i >= 0; i--)
   {
      if(StringGetCharacter(baseName, i) == '.')
      {
         dotIndex = i;
         break;
      }
   }

   if(dotIndex > 0)
   {
      extension = StringSubstr(baseName, dotIndex);
      baseName = StringSubstr(baseName, 0, dotIndex);
   }

   const string fileName = (string)userId + "_" + baseName + "_daily_stats" + extension;
   const string folder = CleanRelativeFolder(InpDailyStatsFolder);
   if(StringLen(folder) <= 0)
      return fileName;

   return (folder + "\\" + fileName);
}

bool EnsureDailyStatsFolder()
{
   const string folder = CleanRelativeFolder(InpDailyStatsFolder);
   if(StringLen(folder) <= 0)
      return true;

   int folderFlags = 0;
   if(InpUseCommonFiles)
      folderFlags |= FILE_COMMON;

   ResetLastError();
   if(FolderCreate(folder, folderFlags))
      return true;

   const int err = GetLastError();
   Print("Daily stats folder create fail | folder=", folder,
         " | err=", err,
         " | use_common=", (InpUseCommonFiles ? "true" : "false"));
   return false;
}

bool IsSellMode()
{
   return (InpTradeMode == TRADE_SELL_ONLY);
}

ENUM_POSITION_TYPE ActivePositionType()
{
   return (IsSellMode() ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
}

string ActiveSideLabel()
{
   return (IsSellMode() ? "SELL" : "BUY");
}

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

bool IsAlgoTradingEnabled()
{
   return (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);
}

bool IsTesterRun()
{
   return (MQLInfoInteger(MQL_TESTER) != 0);
}

int BrokerHour(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   return dt.hour;
}

int NormalizeHour(const int hour)
{
   int h = hour % 24;
   if(h < 0)
      h += 24;
   return h;
}

int BrokerUtcOffsetHoursNow()
{
   const datetime brokerNow = TimeCurrent();
   const datetime utcNow = TimeGMT();
   const int offsetSeconds = (int)(brokerNow - utcNow);
   return (int)MathRound((double)offsetSeconds / 3600.0);
}

string SessionTimeModeLabel()
{
   if(InpSessionTimeMode == SESSION_TIME_UTC)
      return "UTC";
   if(InpSessionTimeMode == SESSION_TIME_WIB)
      return "WIB(UTC+7)";
   return "BROKER";
}

int SessionReferenceHour(const datetime whenTime)
{
   const int brokerHour = BrokerHour(whenTime);
   if(InpSessionTimeMode == SESSION_TIME_BROKER)
      return brokerHour;

   const int brokerUtcOffset = BrokerUtcOffsetHoursNow();
   const int utcHour = NormalizeHour(brokerHour - brokerUtcOffset);
   if(InpSessionTimeMode == SESSION_TIME_UTC)
      return utcHour;

   // WIB is UTC+7.
   return NormalizeHour(utcHour + 7);
}

bool IsWithinFirstEntryWindow(const datetime whenTime)
{
   const int h = SessionReferenceHour(whenTime);
   return (h >= InpStartHourBroker && h < InpPauseHourBroker);
}

void UpdateSessionPauseState(const int posCount)
{
   if(!InpUseTimeFilter)
   {
      g_sessionPauseUntilStart = false;
      return;
   }

   const datetime now = TimeCurrent();
   const int hourNow = SessionReferenceHour(now);
   const bool inStartWindow = IsWithinFirstEntryWindow(now);

   if(g_sessionPauseUntilStart && inStartWindow)
   {
      g_sessionPauseUntilStart = false;
      if(!IsTesterRun())
         Print("Session pause OFF | resumed at ", SessionTimeModeLabel(), " hour=", hourNow);
   }

   // From pause hour onward, if basket is flat, pause until next start window.
   if(hourNow >= InpPauseHourBroker && posCount <= 0 && !g_sessionPauseUntilStart)
   {
      g_sessionPauseUntilStart = true;
      if(!IsTesterRun())
         Print("Session pause ON | reason=flat_between_pause_window | ",
               SessionTimeModeLabel(), " hour=", hourNow);
   }
}

bool IsFirstEntryAllowedNow()
{
   if(!InpUseTimeFilter)
      return true;
   if(g_sessionPauseUntilStart)
      return false;

   return IsWithinFirstEntryWindow(TimeCurrent());
}

bool IsGridEntryAllowedNow(const int posCount)
{
   if(!InpUseTimeFilter)
      return true;
   if(g_sessionPauseUntilStart)
      return false;

   // Existing basket can keep being managed even outside first-entry session.
   return (posCount > 0);
}

bool HasAnyFirstEntrySignalFilter()
{
   return (InpUseFirstEntryRsiFilter ||
           InpUseFirstEntryMaFilter ||
           InpUseFirstEntryBullishCandle);
}

bool IsNewBarForFirstEntry()
{
   // If signal filters are enabled, do not additionally restrict by
   // "next candle open" gate.
   if(HasAnyFirstEntrySignalFilter())
      return true;

   if(!InpFirstEntryOnNextCandleOpen)
      return true;

   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime <= 0)
      return false;

   if(barTime == g_lastFirstEntryBarTime)
      return false;

   g_lastFirstEntryBarTime = barTime;
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

ulong CloseDeviationPointsFromPips(const string symbol, const double deviationPips)
{
   if(deviationPips <= 0.0)
      return 0;

   const double pipPoint = PipPoint(symbol);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(pipPoint <= 0.0 || point <= 0.0)
      return 0;

   const double deviationPrice = deviationPips * pipPoint;
   const long points = (long)MathRound(deviationPrice / point);
   if(points <= 0)
      return 1;

   return (ulong)points;
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

void BuildPositionSnapshot(const string symbol, const long magic, SPositionSnapshot &snapshot)
{
   snapshot.count = 0;
   snapshot.totalProfit = 0.0;
   snapshot.hasLatestPosition = false;
   snapshot.latestPrice = 0.0;
   datetime latestPositionTime = 0;

   const ENUM_POSITION_TYPE activeType = ActivePositionType();
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != activeType) continue;

      snapshot.count++;
      snapshot.totalProfit += PositionGetDouble(POSITION_PROFIT);

      const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!snapshot.hasLatestPosition || t > latestPositionTime)
      {
         latestPositionTime = t;
         snapshot.latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         snapshot.hasLatestPosition = true;
      }
   }
}

int CountBuyPositions(const string symbol, const long magic)
{
   const ENUM_POSITION_TYPE activeType = ActivePositionType();
   int count = 0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != activeType) continue;
      count++;
   }
   return count;
}

int CloseAllBuyPositions(const string symbol, const long magic)
{
   const ENUM_POSITION_TYPE activeType = ActivePositionType();
   const ulong closeDeviation = CloseDeviationPointsFromPips(symbol, InpCloseDeviationPips);
   const bool useCustomDeviation = (closeDeviation > 0);
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
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != activeType) continue;

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
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != activeType) continue;

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
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != activeType) continue;

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
   const bool ok = (IsSellMode()
                    ? trade.Sell(vol, symbol, 0.0, 0.0, 0.0, comment)
                    : trade.Buy(vol, symbol, 0.0, 0.0, 0.0, comment));
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
   if(IsSellMode())
   {
      const double sellThreshold = 100.0 - InpRsiThreshold;
      return (rsiNow > sellThreshold && (rsiPrev - rsiNow) >= InpRsiMinRise);
   }
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
      // Use previous closed candle with full-candle relation to MA.
      if(IsSellMode())
      {
         const double l = iLow(g_symbol, PERIOD_CURRENT, 1);
         if(l == 0.0)
            return false;
         return (l > maBuf[1]);
      }

      const double h = iHigh(g_symbol, PERIOD_CURRENT, 1);
      if(h == 0.0)
         return false;
      return (h < maBuf[1]);
   }

   if(IsSellMode())
   {
      const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      return (ask > maBuf[0]);
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

   if(IsSellMode())
      return (c < o);

   return (c > o);
}

string UrlEncode(const string src)
{
   string out = "";
   char bytes[];
   const int copied = StringToCharArray(src, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(copied <= 1)
      return out;

   // copied includes null-terminator, encode only data bytes.
   for(int i = 0; i < copied - 1; i++)
   {
      const int c = ((int)bytes[i]) & 0xFF;
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
   if(IsTesterRun())
      return false;

   string botToken = InpTelegramBotToken;
   StringTrimLeft(botToken);
   StringTrimRight(botToken);

   string chatId = InpTelegramChatId;
   StringTrimLeft(chatId);
   StringTrimRight(chatId);

   if(StringLen(botToken) == 0 || StringLen(chatId) == 0)
   {
      if(!IsTesterRun())
         Print("Telegram skip | token/chat_id empty");
      return false;
   }

   const string url = "https://api.telegram.org/bot" + botToken + "/sendMessage";
   const string body = "chat_id=" + UrlEncode(chatId) + "&text=" + UrlEncode(text);
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
   const string responseBody = CharArrayToString(result, 0, -1, CP_UTF8);
   if(code == -1)
   {
      Print("Telegram fail | err=", GetLastError(),
            " | allow_url=https://api.telegram.org");
      return false;
   }

   if(code < 200 || code >= 300)
   {
      Print("Telegram fail | http_code=", code,
            " | response=", responseBody);
      return false;
   }

   if(!IsTesterRun())
      Print("Telegram OK | message sent");
   return true;
}

void SendPauseWarning(const int posCount, const string reason)
{
   if(IsTesterRun())
      return;

   const string accountName = AccountInfoString(ACCOUNT_NAME);
   const string msg =
      "EA Paused | " + reason + "\n" +
      "Acct: " + accountName + "\n" +
      "Sym: " + g_symbol + "\n" +
      "Pos: " + (string)posCount + "/" + (string)g_maxPositions;

   Print(msg);
}

void TrySendEaActiveMessage(const int posCount, const double floatingProfit)
{
   if(IsTesterRun())
      return;

   if(!InpNotifyEaActive || InpEaActiveIntervalMinutes <= 0)
      return;

   const datetime nowTime = TimeCurrent();
   const int intervalSec = InpEaActiveIntervalMinutes * 60;
   const int attemptCooldownSec = 60;
   if(g_lastActiveNotifyAttemptTime > 0 &&
      (nowTime - g_lastActiveNotifyAttemptTime) < attemptCooldownSec)
      return;
   if(g_lastActiveNotifyTime > 0 && (nowTime - g_lastActiveNotifyTime) < intervalSec)
      return;
   g_lastActiveNotifyAttemptTime = nowTime;

   const string userName = AccountInfoString(ACCOUNT_NAME);
   const string sign = (floatingProfit >= 0.0 ? "+" : "");
   const string msg =
      "🟢 " + userName +
      " | Grid: " + (string)posCount +
      " | Floating: " + sign + DoubleToString(floatingProfit, 2);

   if(SendTelegramMessage(msg))
      g_lastActiveNotifyTime = nowTime;
}

void ResetTrailState()
{
   g_trailActive = false;
   g_trailPeakProfit = 0.0;
}

void ActivateCloseLock(const string reason)
{
   if(!g_closeLockActive)
   {
      if(!IsTesterRun())
         Print("Close lock ON | reason=", reason);
   }

   g_closeLockActive = true;
   g_closeLockLastRemain = -1;
   g_closeLockWaitTradePrinted = false;
}

void DeactivateCloseLock()
{
   if(g_closeLockActive)
   {
      if(!IsTesterRun())
         Print("Close lock OFF | all positions closed");
   }

   g_closeLockActive = false;
   g_closeLockLastRemain = -1;
   g_closeLockWaitTradePrinted = false;
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
      if(!IsTesterRun())
         Print("Close lock running | remain=", remain);
      g_closeLockLastRemain = remain;
   }

   return true;
}

int DateKeyFromTime(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   return (dt.year * 10000 + dt.mon * 100 + dt.day);
}

datetime DayStartFromTime(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

string DateYmdFromTime(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   return StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
}

bool IsExitDealEntryType(const long dealEntry)
{
   return (dealEntry == DEAL_ENTRY_OUT ||
           dealEntry == DEAL_ENTRY_OUT_BY ||
           dealEntry == DEAL_ENTRY_INOUT);
}

double CalcClosedProfitForRange(const datetime fromTime, const datetime toTime)
{
   if(toTime < fromTime)
      return 0.0;

   if(!HistorySelect(fromTime, toTime))
      return 0.0;

   double total = 0.0;
   const int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;

      const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(!IsExitDealEntryType(entry))
         continue;

      const double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      const double swap = HistoryDealGetDouble(deal, DEAL_SWAP);
      const double commission = HistoryDealGetDouble(deal, DEAL_COMMISSION);
      total += (profit + swap + commission);
   }

   return total;
}

double CurrentEaBasketDrawdown(const double floatingProfitNow)
{
   return (floatingProfitNow < 0.0 ? -floatingProfitNow : 0.0);
}

bool AppendDailyStatsRow()
{
   if(IsTesterRun())
      return true;

   if(!InpEnableDailyStats || !g_dailyStatsInitialized)
      return true;

   const string rowDate = DateYmdFromTime(g_dailyStartTime);
   const string rowLine = rowDate + "," +
                          g_symbol + "," +
                          (string)InpMagic + "," +
                          DoubleToString(g_dailyClosedProfit, 2) + "," +
                          DoubleToString(g_dailyMaxDd, 2);
   const string headerLine = "date,symbol,magic,daily_profit,max_dd";

   string lines[];
   int lineCount = 0;

   int readFlags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      readFlags |= FILE_COMMON;

   ResetLastError();
   const int readHandle = FileOpen(g_dailyStatsFile, readFlags);
   if(readHandle != INVALID_HANDLE)
   {
      while(!FileIsEnding(readHandle))
      {
         string line = FileReadString(readHandle);
         StringTrimLeft(line);
         StringTrimRight(line);
         if(StringLen(line) == 0)
            continue;

         const int n = lineCount + 1;
         ArrayResize(lines, n);
         lines[lineCount] = line;
         lineCount = n;
      }
      FileClose(readHandle);
   }

   bool hasHeader = false;
   if(lineCount > 0)
   {
      string first = lines[0];
      StringToLower(first);
      hasHeader = (first == headerLine);
   }

   if(!hasHeader)
   {
      const int n = lineCount + 1;
      ArrayResize(lines, n);
      for(int i = n - 1; i > 0; i--)
         lines[i] = lines[i - 1];
      lines[0] = headerLine;
      lineCount = n;
   }

   bool replaced = false;
   for(int i = 1; i < lineCount; i++)
   {
      string cells[];
      const int cellCount = StringSplit(lines[i], ',', cells);
      if(cellCount < 2)
         continue;

      string dateCell = cells[0];
      string symbolCell = cells[1];
      string magicCell = "";
      StringTrimLeft(dateCell);
      StringTrimRight(dateCell);
      StringTrimLeft(symbolCell);
      StringTrimRight(symbolCell);
      if(cellCount >= 3)
      {
         magicCell = cells[2];
         StringTrimLeft(magicCell);
         StringTrimRight(magicCell);
      }

      if(cellCount >= 5)
      {
         if(dateCell == rowDate && symbolCell == g_symbol && magicCell == (string)InpMagic)
         {
            lines[i] = rowLine;
            replaced = true;
            break;
         }
      }
      else if(cellCount == 4)
      {
         // Backward compatibility for old schema (without magic column).
         if(dateCell == rowDate && symbolCell == g_symbol)
         {
            lines[i] = rowLine;
            replaced = true;
            break;
         }
      }
   }

   if(!replaced)
   {
      const int n = lineCount + 1;
      ArrayResize(lines, n);
      lines[lineCount] = rowLine;
      lineCount = n;
   }

   int writeFlags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      writeFlags |= FILE_COMMON;

   ResetLastError();
   const int writeHandle = FileOpen(g_dailyStatsFile, writeFlags);
   if(writeHandle == INVALID_HANDLE)
   {
      Print("Daily stats file open fail | file=", g_dailyStatsFile,
            " | err=", GetLastError());
      return false;
   }

   for(int i = 0; i < lineCount; i++)
   {
      FileWriteString(writeHandle, lines[i]);
      if(i < (lineCount - 1))
         FileWriteString(writeHandle, "\r\n");
   }
   FileClose(writeHandle);

   if(InpLogDailyStatsSummary)
   {
      if(!IsTesterRun())
         Print("Daily stats saved | date=", DateYmdFromTime(g_dailyStartTime),
               " | dailyProfit=", DoubleToString(g_dailyClosedProfit, 2),
               " | maxDD=", DoubleToString(g_dailyMaxDd, 2),
               " | mode=", (replaced ? "replace" : "append"),
               " | file=", g_dailyStatsFile);
   }

   return true;
}

void StartDailyStats(const datetime nowTime, const double floatingProfitNow)
{
   g_dailyStartTime = DayStartFromTime(nowTime);
   g_dailyDateKey = DateKeyFromTime(nowTime);
   g_dailyClosedProfit = CalcClosedProfitForRange(g_dailyStartTime, nowTime);
   g_dailyMaxDd = CurrentEaBasketDrawdown(floatingProfitNow);
   g_dailyStatsInitialized = true;

   if(InpLogDailyStatsSummary)
   {
      if(!IsTesterRun())
         Print("Daily stats start | date=", DateYmdFromTime(g_dailyStartTime),
               " | closed_so_far=", DoubleToString(g_dailyClosedProfit, 2),
               " | floating_now=", DoubleToString(floatingProfitNow, 2));
   }
}

void UpdateDailyStats(const double floatingProfitNow)
{
   if(!InpEnableDailyStats)
      return;

   const datetime nowTime = TimeCurrent();
   const int nowDateKey = DateKeyFromTime(nowTime);

   if(!g_dailyStatsInitialized)
   {
      StartDailyStats(nowTime, floatingProfitNow);
      return;
   }

   if(nowDateKey != g_dailyDateKey)
   {
      AppendDailyStatsRow();
      StartDailyStats(nowTime, floatingProfitNow);
      return;
   }

   const double ddNow = CurrentEaBasketDrawdown(floatingProfitNow);
   if(ddNow > g_dailyMaxDd)
      g_dailyMaxDd = ddNow;
}

void HandleDailyStatsOnAlgoToggle(const double floatingProfitNow)
{
   if(IsTesterRun())
      return;

   const bool algoEnabledNow = IsAlgoTradingEnabled();

   // Detect ON -> OFF transition (user disables Algo Trading button).
   if(g_lastAlgoTradingEnabled && !algoEnabledNow)
   {
      // Keep stats up-to-date before flush.
      UpdateDailyStats(floatingProfitNow);
      if(AppendDailyStatsRow())
      {
         Print("Daily stats flushed | reason=algo_trading_off | date=",
               DateYmdFromTime(g_dailyStartTime),
               " | dailyProfit=", DoubleToString(g_dailyClosedProfit, 2),
               " | maxDD=", DoubleToString(g_dailyMaxDd, 2));
      }
   }

   g_lastAlgoTradingEnabled = algoEnabledNow;
}

void PrintCsvLocationGuide(const string filename)
{
   if(IsTesterRun())
      return;

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
      {
         Print("CSV note | tester uses active agent data folder");
      }
   }
}

bool ParseCsvLevelRow(const string row, double &lot, double &gridPoints, double &tpMoney)
{
   string text = row;
   StringTrimLeft(text);
   StringTrimRight(text);
   if(StringLen(text) == 0)
      return false;

   string cells[];
   int cellCount = StringSplit(text, ',', cells);
   if(cellCount != 3)
   {
      // Fallback support for semicolon-separated files.
      cellCount = StringSplit(text, ';', cells);
      if(cellCount != 3)
         return false;
   }

   string slot = cells[0];
   string sgrid = cells[1];
   string stp = cells[2];
   StringTrimLeft(slot);
   StringTrimRight(slot);
   StringTrimLeft(sgrid);
   StringTrimRight(sgrid);
   StringTrimLeft(stp);
   StringTrimRight(stp);

   lot = StringToDouble(slot);
   gridPoints = StringToDouble(sgrid);
   tpMoney = StringToDouble(stp);
   if(lot <= 0.0 || gridPoints <= 0.0 || tpMoney <= 0.0)
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
      double gridPoints = 0.0;
      double tpMoney = 0.0;
      if(!ParseCsvLevelRow(line, lot, gridPoints, tpMoney))
      {
         Print("CSV row invalid | line=", lineNo,
               " | row='", line, "' | expected=lot,gridPoints,tpMoney (all >0)");
         FileClose(handle);
         return false;
      }

      const int newSize = g_levelCount + 1;
      ArrayResize(g_levels, newSize);
      g_levels[g_levelCount].lot = lot;
      g_levels[g_levelCount].gridPoints = gridPoints;
      g_levels[g_levelCount].tpMoney = tpMoney;
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

bool GetLevelByPositionCount(const int positionCount, int &levelIndex, double &lot, double &gridPoints, double &tpMoney)
{
   if(g_levelCount <= 0)
      return false;

   int idx = positionCount;
   if(idx >= g_levelCount)
      idx = g_levelCount - 1;

   levelIndex = idx;
   lot = g_levels[idx].lot;
   gridPoints = g_levels[idx].gridPoints;
   tpMoney = g_levels[idx].tpMoney;
   return true;
}

bool GetCurrentGridTpMoney(const int posCount, double &tpMoney)
{
   if(posCount <= 0)
      return false;

   // posCount=1 means level index 0.
   int levelIndex = -1;
   double lot = 0.0;
   double gridPoints = 0.0;
   return GetLevelByPositionCount(posCount - 1, levelIndex, lot, gridPoints, tpMoney);
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

   if(InpUseTimeFilter)
   {
      if(InpStartHourBroker < 0 || InpStartHourBroker > 23 ||
         InpPauseHourBroker < 0 || InpPauseHourBroker > 23)
      {
         Print("Init fail | invalid session hour | start/pause must be 0..23");
         return INIT_FAILED;
      }

      if(InpStartHourBroker >= InpPauseHourBroker)
      {
         Print("Init fail | session config invalid | need start_hour < pause_hour");
         return INIT_FAILED;
      }
   }

   PrintCsvLocationGuide(InpTableFile);
   g_dailyStatsFile = BuildDailyStatsFileFromTableFile(InpTableFile);
   if(InpEnableDailyStats && !EnsureDailyStatsFolder())
      return INIT_FAILED;

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

   if(InpUseBasketTrail)
   {
      if(InpTrailStartMoney <= 0.0)
      {
         if(!IsTesterRun())
            Print("Warn | trail_start<=0");
      }
      if(InpTrailDistancePercent <= 0.0 || InpTrailDistancePercent >= 100.0)
      {
         if(!IsTesterRun())
            Print("Warn | trail_distance_percent_out_of_range | need >0 and <100");
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;
   ResetTrailState();
   DeactivateCloseLock();
   g_maxPosWarnSent = false;
   g_stopTradingByFloatingSL = false;
   g_sessionPauseUntilStart = false;
   g_lastAlgoTradingEnabled = IsAlgoTradingEnabled();
   g_lastFirstEntryBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   g_lastKnownPosCount = CountBuyPositions(g_symbol, InpMagic);

   const bool needTimer =
      (InpUseCloseLock ||
       (InpNotifyEaActive && InpEaActiveIntervalMinutes > 0) ||
       InpEnableDailyStats);
   int timerMs = InpCloseLockTimerMs;
   if(timerMs <= 0)
      timerMs = 1000;

   if(needTimer)
   {
      if(!EventSetMillisecondTimer(timerMs))
      {
         if(!IsTesterRun())
            Print("Warn | timer setup failed | ms=", timerMs);
      }
      else if(!IsTesterRun() && InpCloseLockTimerMs <= 0)
      {
         Print("Info | timer_ms adjusted to 1000 | reason=non_close_lock_timer_features");
      }
   }

   if(!IsTesterRun())
   {
      Print("EA init OK | Symbol=", g_symbol,
            " | Levels=", g_levelCount,
            " | Mode=", ActiveSideLabel(),
            " | CSV=", InpTableFile,
            " | CommonFiles=", (InpUseCommonFiles ? "true" : "false"),
            " | FirstEntryRSI=", (InpUseFirstEntryRsiFilter ? "true" : "false"),
            " | FirstEntryMA=", (InpUseFirstEntryMaFilter ? "true" : "false"),
            " | MA=", (InpFirstEntryMaType == MA_SIMPLE ? "SMA" : "EMA"),
            " | MAperiod=", (string)InpFirstEntryMaPeriod);

      Print("Init risk/execution | BullishCandle=", (InpUseFirstEntryBullishCandle ? "true" : "false"),
            " | UseCloseLock=", (InpUseCloseLock ? "true" : "false"),
            " | PriorityClose=", (InpUsePriorityCloseOrder ? "true" : "false"),
            " | UseAsyncClose=", (InpUseAsyncClose ? "true" : "false"),
            " | CloseDevPips=", DoubleToString(InpCloseDeviationPips, 1),
            " | CloseDevPoints=", (string)CloseDeviationPointsFromPips(g_symbol, InpCloseDeviationPips),
            " | CloseAttempts=", (string)InpCloseAttemptsPerRun,
            " | CloseLockTimerMs=", (string)InpCloseLockTimerMs,
            " | MaxSpreadFirst=", DoubleToString(InpMaxSpreadFirstEntryPips, 1),
            " | MaxSpreadGrid=", DoubleToString(InpMaxSpreadGridEntryPips, 1));

      if(InpFirstEntryOnNextCandleOpen && HasAnyFirstEntrySignalFilter())
         Print("Info | first_entry_on_next_candle_open=IGNORED | reason=first_entry_signal_filter_enabled");

      Print("Init session/exit | UseTimeFilter=", (InpUseTimeFilter ? "true" : "false"),
            " | SessionMode=", SessionTimeModeLabel(),
            " | BrokerUTCOffset=", (string)BrokerUtcOffsetHoursNow(),
            " | StartHour=", (string)InpStartHourBroker,
            " | PauseHour=", (string)InpPauseHourBroker,
            " | FloatingDDStop=", DoubleToString(InpFloatingDDStopMoney, 2),
            " | BasketTrail=", (InpUseBasketTrail ? "true" : "false"),
            " | TrailStart=", DoubleToString(InpTrailStartMoney, 2),
            " | TrailDistance%=", DoubleToString(InpTrailDistancePercent, 2),
            " | MaxPositions=", g_maxPositions);

      Print("Init daily_stats | enabled=", (InpEnableDailyStats ? "true" : "false"),
            " | file=", g_dailyStatsFile,
            " | use_common=", (InpUseCommonFiles ? "true" : "false"));
      if(InpEnableDailyStats)
      {
         if(InpUseCommonFiles)
            Print("Daily stats path | ",
                  TerminalInfoString(TERMINAL_COMMONDATA_PATH),
                  "\\Files\\", g_dailyStatsFile);
         else
            Print("Daily stats path | ",
                  TerminalInfoString(TERMINAL_DATA_PATH),
                  "\\MQL5\\Files\\", g_dailyStatsFile);
      }

      if(InpFloatingDDStopMoney > 0.0 && InpNotifyFloatingSLStop)
         Print("Telegram setup | allow_url=https://api.telegram.org");

      for(int i = 0; i < g_levelCount; i++)
      {
         Print("Level ", (i + 1), " | lot=", DoubleToString(g_levels[i].lot, 2),
               " | gridPoints=", DoubleToString(g_levels[i].gridPoints, 1),
               " | tpMoney=", DoubleToString(g_levels[i].tpMoney, 2));
      }
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   AppendDailyStatsRow();

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

   SPositionSnapshot snapshot;
   BuildPositionSnapshot(g_symbol, InpMagic, snapshot);
   const int posCount = snapshot.count;
   const double floatingProfit = snapshot.totalProfit;
   HandleDailyStatsOnAlgoToggle(floatingProfit);
   if(InpNotifyEaActive && InpEaActiveIntervalMinutes > 0)
      TrySendEaActiveMessage(posCount, floatingProfit);
   ProcessCloseLock(posCount);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!g_ready || !InpEnableDailyStats)
      return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   const ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))
      return;

   if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol)
      return;
   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
      return;

   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(!IsExitDealEntryType(entry))
      return;

   if(!g_dailyStatsInitialized)
      return;

   const datetime dealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   if(DateKeyFromTime(dealTime) != g_dailyDateKey)
      return;

   const double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
   const double swap = HistoryDealGetDouble(deal, DEAL_SWAP);
   const double commission = HistoryDealGetDouble(deal, DEAL_COMMISSION);
   g_dailyClosedProfit += (profit + swap + commission);
}

void OnTick()
{
   if(!g_ready)
      return;

   if(_Symbol != g_symbol)
      return;

   SPositionSnapshot snapshot;
   BuildPositionSnapshot(g_symbol, InpMagic, snapshot);
   const int posCount = snapshot.count;
   const double floatingProfitNow = snapshot.totalProfit;

   // Detect transition from active basket to flat.
   // Reset first-entry bar baseline so "next candle open" truly means
   // the candle after basket close, not after last first-entry check.
   if(posCount <= 0 && g_lastKnownPosCount > 0)
      g_lastFirstEntryBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   g_lastKnownPosCount = posCount;

   UpdateDailyStats(floatingProfitNow);

   if(posCount <= 0)
   {
      ResetTrailState();
      DeactivateCloseLock();
      g_maxPosWarnSent = false;
   }

   if(InpUseCloseLock && g_closeLockActive)
   {
      // Safety fallback: when timer is disabled/unavailable, keep processing lock on ticks.
      ProcessCloseLock(posCount);
      return;
   }

   UpdateSessionPauseState(posCount);

   if(g_stopTradingByFloatingSL)
   {
      if(posCount > 0)
      {
         if(InpUseCloseLock)
         {
            ActivateCloseLock("floating_dd_stop");
            return;
         }
         else
         {
            if(!IsTradeAllowed())
               return;

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
         }
      }
      return;
   }

   if(g_maxPositions > 0 && posCount < g_maxPositions)
      g_maxPosWarnSent = false;

   if(posCount > 0)
   {
      const double profit = floatingProfitNow;
      if(InpFloatingDDStopMoney > 0.0 && profit <= -InpFloatingDDStopMoney)
      {
         g_stopTradingByFloatingSL = true;

         const string msg =
            "Floating DD Stop Triggered\n" +
            "Acct: " + AccountInfoString(ACCOUNT_NAME) + "\n" +
            "Sym: " + g_symbol + "\n" +
            "Floating: " + DoubleToString(profit, 2) + "\n" +
            "Limit: -" + DoubleToString(InpFloatingDDStopMoney, 2) + "\n" +
            "Action: close all + stop trading (manual restart from MT5)";

         if(InpNotifyFloatingSLStop)
            SendTelegramMessage(msg);

         if(InpUseCloseLock)
         {
            ActivateCloseLock("floating_dd_stop");
            return;
         }
         else
         {
            if(!IsTradeAllowed())
               return;

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
         }
         return;
      }
      double currentLevelTpMoney = 0.0;
      if(!GetCurrentGridTpMoney(posCount, currentLevelTpMoney))
         return;

      const bool trailConfigOk =
         (InpUseBasketTrail &&
          InpTrailStartMoney > 0.0 &&
          InpTrailDistancePercent > 0.0 &&
          InpTrailDistancePercent < 100.0);
      // Mode selection per your requested flow:
      // - table TP <= trail start -> fixed TP
      // - table TP > trail start  -> table TP becomes trailing activation level
      const bool useTrailForThisGrid =
         (trailConfigOk &&
          currentLevelTpMoney > InpTrailStartMoney);

      if(g_trailActive && !useTrailForThisGrid)
      {
         string trailOffReason = "table_tp_below_trail_start";
         if(!InpUseBasketTrail)
            trailOffReason = "trail_disabled";
         else if(InpTrailDistancePercent <= 0.0 || InpTrailDistancePercent >= 100.0)
            trailOffReason = "trail_distance_out_of_range";
         else if(InpTrailStartMoney <= 0.0)
            trailOffReason = "trail_start_invalid";

         if(!IsTesterRun())
            Print("Basket trail OFF | reason=", trailOffReason,
                  " | table_tp=", DoubleToString(currentLevelTpMoney, 2),
                  " | trail_start=", DoubleToString(InpTrailStartMoney, 2));
         ResetTrailState();
      }

      if(!useTrailForThisGrid &&
         currentLevelTpMoney > 0.0 && profit >= currentLevelTpMoney)
      {
         if(!IsTesterRun())
            Print("Level TP hit | grid=", posCount,
                  " | profit=", DoubleToString(profit, 2),
                  " | target=", DoubleToString(currentLevelTpMoney, 2));
         if(InpUseCloseLock)
         {
            ActivateCloseLock("level_tp");
            return;
         }
         else
         {
            if(!IsTradeAllowed())
               return;

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
         }
         return;
      }

      // For trail-mode grids, start trailing only after profit reaches table TP.
      if(useTrailForThisGrid)
      {
         if(!g_trailActive && profit >= currentLevelTpMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            if(!IsTesterRun())
               Print("Basket trail ON | profit=", DoubleToString(profit, 2),
                     " | table_tp=", DoubleToString(currentLevelTpMoney, 2),
                     " | trail_start=", DoubleToString(InpTrailStartMoney, 2),
                     " | mode=activated_after_table_tp_hit");
         }

         if(g_trailActive)
         {
            if(profit > g_trailPeakProfit)
               g_trailPeakProfit = profit;

            // Apply trailing-stop only after basket reaches positive peak profit.
            if(g_trailPeakProfit > 0.0)
            {
               const double trailStopProfit = g_trailPeakProfit * (1.0 - (InpTrailDistancePercent / 100.0));
               if(profit <= trailStopProfit)
               {
                  if(!IsTesterRun())
                     Print("Basket trail hit | profit=", DoubleToString(profit, 2),
                           " | peak=", DoubleToString(g_trailPeakProfit, 2),
                           " | stop=", DoubleToString(trailStopProfit, 2));
                  if(InpUseCloseLock)
                  {
                     ActivateCloseLock("basket_trail");
                     return;
                  }
                  else
                  {
                     if(!IsTradeAllowed())
                        return;

                     const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
                     if(remain == 0)
                        ResetTrailState();
                  }
                  return;
               }
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

   if(InpMinSecondsBetweenOrders > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
      return;

   double lot;
   double gridPoints;
   double tpMoney;
   int levelIndex = -1;
   if(!GetLevelByPositionCount(posCount, levelIndex, lot, gridPoints, tpMoney))
      return;

   if(posCount == 0)
   {
      if(!IsNewBarForFirstEntry())
         return;

      if(!IsFirstEntryAllowedNow())
         return;

      if(!SpreadOK(g_symbol, InpMaxSpreadFirstEntryPips))
         return;

      if(!FirstEntryRsiOK())
         return;
      if(!FirstEntryMaOK())
         return;
      if(!FirstEntryBullishCandleOK())
         return;

      if(!IsTesterRun())
         Print("Open first entry | level=", (levelIndex + 1),
               " | side=", ActiveSideLabel(),
               " | lot=", DoubleToString(lot, 2));
      OpenBuy(g_symbol, lot, (IsSellMode() ? "TableGridSell" : "TableGridBuy"));
      return;
   }

   if(!snapshot.hasLatestPosition)
      return;
   const double latest_price = snapshot.latestPrice;

   const double gridPrice = gridPoints * PipPoint(g_symbol);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const bool shouldOpenGrid = (IsSellMode()
                                ? (ask > (latest_price + gridPrice))
                                : (bid < (latest_price - gridPrice)));
   if(shouldOpenGrid)
   {
      if(!IsGridEntryAllowedNow(posCount))
         return;

      if(!SpreadOK(g_symbol, InpMaxSpreadGridEntryPips))
         return;

      if(!IsTesterRun())
         Print("Open grid entry | level=", (levelIndex + 1),
               " | side=", ActiveSideLabel(),
               " | lot=", DoubleToString(lot, 2),
               " | gridPoints=", DoubleToString(gridPoints, 1),
               " | tpMoney=", DoubleToString(tpMoney, 2));
      OpenBuy(g_symbol, lot, (IsSellMode() ? "TableGridSell" : "TableGridBuy"));
   }
}
