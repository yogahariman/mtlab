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

enum ESessionTimeMode
{
   SESSION_TIME_BROKER = 0,
   SESSION_TIME_UTC = 1,
   SESSION_TIME_WIB = 2
};

input group "General"
input long   InpMagic                   = 260414; // Magic number
input bool   InpShowProfitGuideLines    = true;   // Show TP/trailing guide lines on chart

input group "CSV Level Table"
input string InpTableFile               = "xau_levels.csv"; // CSV filename only (placed in MQL5/Files or Common/Files), format: lot,gridPips,tpMoney
input bool   InpSkipFirstCsvRow         = true;   // Skip first row (header)
input bool   InpUseCommonFiles          = true;  // Read CSV from Terminal/Common/Files using FILE_COMMON
input bool   InpUseLastLevelIfExceeded  = true;   // Use last table row when positions exceed table

input group "Risk & Execution"
input int    InpMaxPositions            = 0;      // Max grid positions (0=disabled)
input int    InpMinSecondsBetweenOrders = 0;     // Min delay between orders
input int    InpCooldownAfterCloseSeconds = 3;   // Cooldown after EA closes all positions (0=disabled)
input bool   InpUseCloseLock            = true;   // Use close-lock mode until all positions are closed
input bool   InpUsePriorityCloseOrder   = true;   // Close by priority (lot desc, then profit asc)
input bool   InpUseAsyncClose           = true;   // Send close requests asynchronously for faster batch close
input double InpCloseDeviationPips      = 30.0;   // Max deviation in pips for close requests (<=0 uses platform default)
input int    InpCloseAttemptsPerRun     = 1;      // Max close-all retries in one run (keep 1 for async burst)
input int    InpCloseLockTimerMs        = 100;    // Close-lock timer interval (ms, 0=off)
input double InpMaxSpreadFirstEntryPips = 50;      // Max spread for first entry in pips (0=disabled)
input double InpMaxSpreadGridEntryPips  = 50;      // Max spread for grid entry in pips (0=disabled)

input group "Trading Session"
input bool   InpUseTimeFilter           = false;   // Enable trading session filter
input ESessionTimeMode InpSessionTimeMode = SESSION_TIME_WIB; // Session input timezone: broker/UTC/WIB(UTC+7)
input int    InpStartHourBroker         = 9;      // Start first entries from this hour in selected session timezone (00-23)
input int    InpPauseHourBroker         = 1;     // Pause-prep starts from this hour in selected session timezone (00-23)

input group "First Entry Filters"
input bool   InpUseFirstEntryRsiFilter  = false;  // Enable RSI filter for the first buy entry only
input bool   InpUseFirstEntryMaFilter   = false;   // Enable MA filter for first entry
input bool   InpUseFirstEntryFullCandleBelowMa = false; // MA mode: true=previous candle high < MA, false=Bid < MA
input bool   InpUseFirstEntryBullishCandle = false; // First entry: previous candle must be bullish
input int    InpFirstEntryMaPeriod      = 5;      // First entry MA period
input EFirstEntryMaType InpFirstEntryMaType = MA_EXPONENTIAL; // MA type: simple/exponential
input int    InpRsiPeriod               = 14;     // RSI period
input double InpRsiThreshold            = 50.0;   // First entry allowed only if RSI < threshold
input double InpRsiMinRise              = 1.0;    // Require RSI_now - RSI_prev >= value

input group "Exit & Trailing"
input double InpBasketTPDefaultMoney    = 10;   // Fallback basket TP when no grid-specific TP applies
input string InpBasketTPByGridMoney     = "1,2.4,4.8,4.8,12"; // Legacy fallback TP-by-grid (used only when CSV tpMoney is empty/legacy 2-column CSV).
input double InpFloatingDDStopMoney     = 0.0;  // Close all + stop trading when floating drawdown >= value (0=off)
input bool   InpUseBasketTrail          = true;  // Enable basket profit trailing
input int    InpTrailGridFrom           = 6;     // Trailing starts from this grid count
input double InpTrailStartMoney         = 18.0;   // Legacy fallback trail start when CSV tpMoney is empty/legacy 2-column CSV
input double InpTrailDistancePercent    = 33.0;   // Close all when profit drops this % from peak (e.g. 33 => keep ~67% of peak)

input group "Telegram Alerts"
input bool   InpNotifyFloatingSLStop    = true;    // Send Telegram alert when floating SL stop is triggered

struct SLevel
{
   double lot;
   double gridPips;
   double tpMoney;
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
double g_basketTpByGridMoney[];
bool   g_closeLockActive = false;
int    g_closeLockLastRemain = -1;
bool   g_closeLockWaitTradePrinted = false;
bool   g_stopTradingByFloatingSL = false;
bool   g_sessionPauseUntilStart = false;

string GuideLineName(const string suffix)
{
   return "TG_" + g_symbol + "_" + (string)InpMagic + "_" + suffix;
}

void UpsertGuideLine(const string name, const double price, const color clr, const ENUM_LINE_STYLE style)
{
   if(!InpShowProfitGuideLines || price <= 0.0)
   {
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
      return;
   }

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);

   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

void ClearProfitGuideLines()
{
   ObjectDelete(0, GuideLineName("TP"));
   ObjectDelete(0, GuideLineName("TRAIL_STOP"));
}

double BasketProfitSlopePerPrice(const string symbol, const long magic)
{
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(bid <= 0.0 || point <= 0.0)
      return 0.0;

   const double bidUp = bid + point;
   double slope = 0.0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      const double vol = PositionGetDouble(POSITION_VOLUME);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(vol <= 0.0 || openPrice <= 0.0)
         continue;

      double p0 = 0.0;
      double p1 = 0.0;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, symbol, vol, openPrice, bid, p0))
         continue;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, symbol, vol, openPrice, bidUp, p1))
         continue;

      slope += (p1 - p0) / point;
   }

   // Fallback for rare brokers/symbols where OrderCalcProfit is unavailable.
   if(slope <= 0.0)
   {
      const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      const double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0.0 && tickSize > 0.0)
      {
         double lots = 0.0;
         for(int i = 0; i < total; i++)
         {
            const ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
            lots += PositionGetDouble(POSITION_VOLUME);
         }
         if(lots > 0.0)
            slope = (tickValue / tickSize) * lots;
      }
   }

   return slope;
}

double BasketBidForTargetProfit(const string symbol, const long magic, const double targetProfit, const double currentProfit)
{
   const double slope = BasketProfitSlopePerPrice(symbol, magic);
   if(slope <= 0.0)
      return 0.0;

   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(bid <= 0.0)
      return 0.0;

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double needMove = (targetProfit - currentProfit) / slope;
   return NormalizeDouble(bid + needMove, digits);
}

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
      Print("Session pause OFF | resumed at ", SessionTimeModeLabel(), " hour=", hourNow);
   }

   // From pause hour onward, if basket is flat, pause until next start window.
   if(hourNow >= InpPauseHourBroker && posCount <= 0 && !g_sessionPauseUntilStart)
   {
      g_sessionPauseUntilStart = true;
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

void SetDefaultBasketTpByGridMoney()
{
   ArrayResize(g_basketTpByGridMoney, 3);
   g_basketTpByGridMoney[0] = 1.0;
   g_basketTpByGridMoney[1] = 4.0;
   g_basketTpByGridMoney[2] = 10.0;
}

bool LoadBasketTpByGridMoneyFromInput(const string rawInput)
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

   bool hasPairFormat = false;
   for(int i = 0; i < partCount; i++)
   {
      if(StringFind(parts[i], ":") >= 0)
      {
         hasPairFormat = true;
         break;
      }
   }

   // Pair format: "1:1,2:4,3:10"
   if(hasPairFormat)
   {
      int grids[];
      double values[];
      int validPairCount = 0;
      int maxGrid = 0;

      for(int i = 0; i < partCount; i++)
      {
         string token = parts[i];
         StringTrimLeft(token);
         StringTrimRight(token);
         if(StringLen(token) == 0)
            continue;
         if(StringFind(token, ":") < 0)
            continue;

         string pairCells[];
         const int n = StringSplit(token, ':', pairCells);
         if(n != 2)
            continue;

         const int grid = (int)StringToInteger(pairCells[0]);
         const double level = StringToDouble(pairCells[1]);
         if(grid <= 0 || level <= 0.0)
            continue;

         const int newSize = validPairCount + 1;
         ArrayResize(grids, newSize);
         ArrayResize(values, newSize);
         grids[validPairCount] = grid;
         values[validPairCount] = level;
         validPairCount = newSize;

         if(grid > maxGrid)
            maxGrid = grid;
      }

      if(validPairCount <= 0 || maxGrid <= 0)
      {
         ArrayResize(g_basketTpByGridMoney, 0);
         return false;
      }

      ArrayResize(g_basketTpByGridMoney, maxGrid);
      for(int i = 0; i < maxGrid; i++)
         g_basketTpByGridMoney[i] = 0.0;

      for(int i = 0; i < validPairCount; i++)
         g_basketTpByGridMoney[grids[i] - 1] = values[i];

      // Fill missing intermediate grids with previous TP value.
      double last = 0.0;
      for(int i = 0; i < maxGrid; i++)
      {
         if(g_basketTpByGridMoney[i] > 0.0)
            last = g_basketTpByGridMoney[i];
         else if(last > 0.0)
            g_basketTpByGridMoney[i] = last;
      }

      if(g_basketTpByGridMoney[0] <= 0.0)
      {
         ArrayResize(g_basketTpByGridMoney, 0);
         return false;
      }
      return true;
   }

   // Plain list format: "1,4,10"
   ArrayResize(g_basketTpByGridMoney, 0);
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
      ArrayResize(g_basketTpByGridMoney, newSize);
      g_basketTpByGridMoney[validCount] = level;
      validCount = newSize;
   }

   if(validCount <= 0)
   {
      ArrayResize(g_basketTpByGridMoney, 0);
      return false;
   }

   return true;
}

void GetForcedTpByGrid(const int posCount, const double tableTpMoney, double &forcedTpMoney, bool &forceTrailOff)
{
   forcedTpMoney = 0.0;
   forceTrailOff = false;

   if(posCount <= 0 || InpTrailGridFrom <= 1 || posCount >= InpTrailGridFrom)
      return;

   forceTrailOff = true;

   // Priority: TP from current CSV level (3rd column).
   if(tableTpMoney > 0.0)
   {
      forcedTpMoney = tableTpMoney;
      return;
   }

   const int n = ArraySize(g_basketTpByGridMoney);
   if(n <= 0)
      return;

   int idx = posCount - 1;
   if(idx >= n)
      idx = n - 1;

   forcedTpMoney = g_basketTpByGridMoney[idx];
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

bool ParseCsvLevelRow(const string row, double &lot, double &gridPips, double &tpMoney)
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
      {
         // Backward compatibility: old 2-column format (lot,gridPips).
         cellCount = StringSplit(text, ',', cells);
         if(cellCount != 2)
            cellCount = StringSplit(text, ';', cells);
         if(cellCount != 2)
            return false;
      }
   }

   string slot = cells[0];
   string sgrid = cells[1];
   string stp = "";
   if(cellCount >= 3)
      stp = cells[2];
   StringTrimLeft(slot);
   StringTrimRight(slot);
   StringTrimLeft(sgrid);
   StringTrimRight(sgrid);
   StringTrimLeft(stp);
   StringTrimRight(stp);

   lot = StringToDouble(slot);
   gridPips = StringToDouble(sgrid);
   tpMoney = (StringLen(stp) > 0 ? StringToDouble(stp) : 0.0);
   if(lot <= 0.0 || gridPips <= 0.0)
      return false;
   if(cellCount >= 3 && tpMoney <= 0.0)
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
      double tpMoney = 0.0;
      if(!ParseCsvLevelRow(line, lot, gridPips, tpMoney))
      {
         Print("CSV row invalid | line=", lineNo,
               " | row='", line, "' | expected=lot,gridPips,tpMoney (>0) or legacy lot,gridPips");
         FileClose(handle);
         return false;
      }

      const int newSize = g_levelCount + 1;
      ArrayResize(g_levels, newSize);
      g_levels[g_levelCount].lot = lot;
      g_levels[g_levelCount].gridPips = gridPips;
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

bool GetLevelByPositionCount(const int positionCount, int &levelIndex, double &lot, double &gridPips, double &tpMoney)
{
   if(g_levelCount <= 0)
      return false;

   int idx = positionCount;
   if(idx >= g_levelCount)
   {
      if(!InpUseLastLevelIfExceeded)
         return false;
      idx = g_levelCount - 1;
   }

   levelIndex = idx;
   lot = g_levels[idx].lot;
   gridPips = g_levels[idx].gridPips;
   tpMoney = g_levels[idx].tpMoney;
   return true;
}

bool GetCurrentGridLevel(const int posCount, int &levelIndex, double &lot, double &gridPips, double &tpMoney)
{
   if(posCount <= 0)
      return false;

   // posCount=1 means level index 0.
   return GetLevelByPositionCount(posCount - 1, levelIndex, lot, gridPips, tpMoney);
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
      if(InpTrailDistancePercent <= 0.0)
         Print("Warn | trail_distance_percent<=0");
   }

   if(!LoadBasketTpByGridMoneyFromInput(InpBasketTPByGridMoney))
   {
      SetDefaultBasketTpByGridMoney();
      Print("Warn | basket_tp_by_grid invalid -> fallback to default");
   }

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;
   ResetTrailState();
   DeactivateCloseLock();
   ClearProfitGuideLines();
   g_maxPosWarnSent = false;
   g_stopTradingByFloatingSL = false;
   g_sessionPauseUntilStart = false;

   if(InpUseCloseLock && InpCloseLockTimerMs > 0)
   {
      if(!EventSetMillisecondTimer(InpCloseLockTimerMs))
         Print("Warn | timer setup failed | ms=", InpCloseLockTimerMs);
   }

   Print("EA init OK | Symbol=", g_symbol,
         " | Levels=", g_levelCount,
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

   Print("Init session/exit | UseTimeFilter=", (InpUseTimeFilter ? "true" : "false"),
         " | SessionMode=", SessionTimeModeLabel(),
         " | BrokerUTCOffset=", (string)BrokerUtcOffsetHoursNow(),
         " | StartHour=", (string)InpStartHourBroker,
         " | PauseHour=", (string)InpPauseHourBroker,
         " | UseLastLevelOnExceed=", (InpUseLastLevelIfExceeded ? "true" : "false"),
         " | BasketTPDefault=", DoubleToString(InpBasketTPDefaultMoney, 2),
         " | BasketTPByGrid=", InpBasketTPByGridMoney,
         " | FloatingDDStop=", DoubleToString(InpFloatingDDStopMoney, 2),
         " | BasketTrail=", (InpUseBasketTrail ? "true" : "false"),
         " | TrailGridFrom=", (string)InpTrailGridFrom,
         " | TrailStart=", DoubleToString(InpTrailStartMoney, 2),
         " | TrailDistance%=", DoubleToString(InpTrailDistancePercent, 2),
         " | MaxPositions=", g_maxPositions);

   if(InpFloatingDDStopMoney > 0.0 && InpNotifyFloatingSLStop)
      Print("Telegram setup | allow_url=https://api.telegram.org");

   for(int i = 0; i < g_levelCount; i++)
   {
      Print("Level ", (i + 1), " | lot=", DoubleToString(g_levels[i].lot, 2),
            " | gridPips=", DoubleToString(g_levels[i].gridPips, 1),
            " | tpMoney=", DoubleToString(g_levels[i].tpMoney, 2));
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ClearProfitGuideLines();

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

   const int posCount = CountBuyPositions(g_symbol, InpMagic);
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
      DeactivateCloseLock();
      ClearProfitGuideLines();
      g_maxPosWarnSent = false;
   }

   if(ProcessCloseLock(posCount))
      return;

   UpdateSessionPauseState(posCount);

   if(g_stopTradingByFloatingSL)
   {
      ClearProfitGuideLines();
      if(posCount > 0)
      {
         if(InpUseCloseLock)
         {
            ActivateCloseLock("floating_dd_stop");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Floating DD stop wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Floating DD stop close partial | remain=", remain);
         }
      }
      return;
   }

   if(g_maxPositions > 0 && posCount < g_maxPositions)
      g_maxPosWarnSent = false;

   if(posCount > 0)
   {
      const double profit = TotalProfit(g_symbol, InpMagic);
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

         Print(msg);
         if(InpNotifyFloatingSLStop)
            SendTelegramMessage(msg);

         if(InpUseCloseLock)
         {
            ActivateCloseLock("floating_dd_stop");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Floating DD stop wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Floating DD stop close partial | remain=", remain);
         }
         return;
      }
      int currentLevelIndex = -1;
      double currentLevelLot = 0.0;
      double currentLevelGridPips = 0.0;
      double currentLevelTpMoney = 0.0;
      GetCurrentGridLevel(posCount, currentLevelIndex, currentLevelLot, currentLevelGridPips, currentLevelTpMoney);

      double forcedTpMoney = 0.0;
      bool forceTrailOff = false;
      // Use fixed TP by grid for grids below TrailGridFrom.
      GetForcedTpByGrid(posCount, currentLevelTpMoney, forcedTpMoney, forceTrailOff);
      const double trailStartMoney = (currentLevelTpMoney > 0.0 ? currentLevelTpMoney : InpTrailStartMoney);

      const bool useTrailForThisGrid =
         (!forceTrailOff &&
          InpUseBasketTrail &&
          InpTrailGridFrom > 0 &&
          posCount >= InpTrailGridFrom &&
          InpTrailDistancePercent > 0.0);

      // Profit guide lines on chart (price projection from basket money targets).
      // TP line behavior:
      // - Trailing not active yet (but eligible): show trailing activation target.
      // - Trailing active: show peak-profit reference (highest TP anchor for trailing).
      // - Non-trailing mode: show fixed TP target.
      double tpGuidePrice = 0.0;
      if(useTrailForThisGrid)
      {
         if(!g_trailActive && trailStartMoney > 0.0)
            tpGuidePrice = BasketBidForTargetProfit(g_symbol, InpMagic, trailStartMoney, profit);
         else if(g_trailActive && g_trailPeakProfit > 0.0)
            tpGuidePrice = BasketBidForTargetProfit(g_symbol, InpMagic, g_trailPeakProfit, profit);
      }
      else if(forcedTpMoney > 0.0)
         tpGuidePrice = BasketBidForTargetProfit(g_symbol, InpMagic, forcedTpMoney, profit);
      else if(currentLevelTpMoney > 0.0)
         tpGuidePrice = BasketBidForTargetProfit(g_symbol, InpMagic, currentLevelTpMoney, profit);
      else if(InpBasketTPDefaultMoney > 0.0)
         tpGuidePrice = BasketBidForTargetProfit(g_symbol, InpMagic, InpBasketTPDefaultMoney, profit);

      double trailStopGuidePrice = 0.0;
      if(useTrailForThisGrid && g_trailActive)
      {
         const double trailStopProfitGuide = g_trailPeakProfit * (1.0 - (InpTrailDistancePercent / 100.0));
         trailStopGuidePrice = BasketBidForTargetProfit(g_symbol, InpMagic, trailStopProfitGuide, profit);
      }

      UpsertGuideLine(GuideLineName("TP"), tpGuidePrice, clrAqua, STYLE_DOT);
      UpsertGuideLine(GuideLineName("TRAIL_STOP"), trailStopGuidePrice, clrOrange, STYLE_DOT);

      if(forceTrailOff && g_trailActive)
      {
         Print("Basket trail OFF | reason=grid<=3");
         ResetTrailState();
      }
      else if(!forceTrailOff && g_trailActive && !useTrailForThisGrid)
      {
         Print("Basket trail OFF | reason=grid_below_trail_from");
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

      if(!useTrailForThisGrid &&
         currentLevelTpMoney > 0.0 && profit >= currentLevelTpMoney)
      {
         Print("Level TP hit | grid=", posCount,
               " | profit=", DoubleToString(profit, 2),
               " | target=", DoubleToString(currentLevelTpMoney, 2));
         if(InpUseCloseLock)
         {
            ActivateCloseLock("level_tp");
            ProcessCloseLock(posCount);
         }
         else
         {
            if(!IsTradeAllowed())
            {
               Print("Level TP wait | trade not allowed");
               return;
            }

            const int remain = CloseAllBuyPositionsWithRetries(g_symbol, InpMagic, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
            else
               Print("Level TP close partial | remain=", remain);
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

      // Trailing profit is used from configured trail start grid onward.
      if(useTrailForThisGrid)
      {
         if(!g_trailActive && trailStartMoney > 0.0 && profit >= trailStartMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            Print("Basket trail ON | start_profit=", DoubleToString(profit, 2));
         }

         if(g_trailActive)
         {
            if(profit > g_trailPeakProfit)
               g_trailPeakProfit = profit;

            const double trailStopProfit = g_trailPeakProfit * (1.0 - (InpTrailDistancePercent / 100.0));
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
   double tpMoney;
   int levelIndex = -1;
   if(!GetLevelByPositionCount(posCount, levelIndex, lot, gridPips, tpMoney))
      return;

   if(posCount == 0)
   {
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
      if(!IsGridEntryAllowedNow(posCount))
         return;

      if(!SpreadOK(g_symbol, InpMaxSpreadGridEntryPips))
         return;

      Print("Open grid entry | level=", (levelIndex + 1),
            " | lot=", DoubleToString(lot, 2),
            " | gridPips=", DoubleToString(gridPips, 1),
            " | tpMoney=", DoubleToString(tpMoney, 2));
      OpenBuy(g_symbol, lot, "TableGridBuy");
   }
}
