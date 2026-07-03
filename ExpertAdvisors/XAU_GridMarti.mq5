//+----------------------------------------------------------------------+
//| XAU_GridMarti.mq5                                      |
//| Directional table-driven grid EA for XAUUSD (MT5 Hedging)            |
//+----------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ESessionTimeMode
{
   SESSION_TIME_BROKER = 0,
   SESSION_TIME_UTC = 1,
   SESSION_TIME_WIB = 2
};

enum ETradeMode
{
   TRADE_BUY_ONLY = 0,
   TRADE_SELL_ONLY = 1,
   TRADE_BOTH_SINGLE = 2
};

enum EMaxDdResumeMode
{
   MAX_DD_CONTINUE_TRADING = 0,
   MAX_DD_PAUSE_MANUAL = 1,
   MAX_DD_PAUSE_NEXT_DAY = 2
};

enum EMaType
{
   MA_TYPE_SIMPLE = 0,
   MA_TYPE_EXPONENTIAL = 1
};

enum ETrendFilterMode
{
   TREND_FILTER_OFF = 0,
   TREND_FILTER_SINGLE_EMA = 1,
   TREND_FILTER_DOUBLE_EMA = 2
};

input group "General"
input long   InpMagic                   = 790101; // Magic number->[SYMBOL][EA][TF/SET]
input ETradeMode InpTradeMode           = TRADE_BOTH_SINGLE; // Trading direction: buy-only, sell-only, or both-single

input group "Risk & Execution"
input int    InpMinSecondsBetweenOrders = 0;     // Min delay between orders
input bool   InpUseCloseLock            = true;   // Use close-lock mode until all positions are closed
input bool   InpUsePriorityCloseOrder   = true;   // Close by priority (lot desc, then profit asc)
input bool   InpUseAsyncClose           = true;   // Send close requests asynchronously for faster batch close
input double InpCloseDeviationPrice     = 0.30;   // Close deviation in price units (XAU)
input int    InpCloseAttemptsPerRun     = 1;      // Max close-all retries in one run (keep 1 for async burst)
input int    InpCloseLockTimerMs        = 300;    // Close-lock timer interval (ms, 0=off)
input double InpMaxSpreadGridEntryPrice  = 0.40;    // Max spread for grid entry in price units (XAU, 0=disabled)

input group "Grid Martingale"
input string InpLotTable                = "0.01;0.01;0.01;0.01;0.01;0.02;0.02;0.02;0.02;0.02;0.03;0.03;0.03;0.04;0.04;0.05;0.05;0.06;0.06;0.07;0.07;0.08;0.08;0.09;0.09;0.1;0.1;0.11;0.11;0.12;0.12;0.13;0.13;0.14;0.14;0.15;0.15;0.16;0.16;0.17;0.17;0.18;0.18;0.19;0.19;0.2;0.2;0.21;0.21;0.22;0.22;0.23;0.23;0.24;0.24;0.25;0.25;0.26;0.26"; // Lot layers, semicolon-separated
input double InpGridDistance            = 0.8;   // Grid distance in price units (XAU)
input double InpXauMoneyPerPriceUnit    = 100.0;  // Money per 1.00 price move per 1 lot

input group "Trend Filter"
input ETrendFilterMode InpTrendFilterMode = TREND_FILTER_SINGLE_EMA; // Trend EMA filter for first entry
input EMaType InpMovingAverageType        = MA_TYPE_EXPONENTIAL; // EMA/SMA for trend filter
input int    InpTrendEMAPeriod            = 120;   // Single EMA period
input int    InpFastMAPeriod              = 13;    // Fast EMA period for double EMA
input int    InpSlowMAPeriod              = 233;   // Slow EMA period for double EMA
input double InpEmaMinDistance            = 0.50;  // Minimum EMA distance in price units (XAU)

input group "Trading Session"
input bool   InpUseTimeFilter           = true;   // Enable manual time filter
input ESessionTimeMode InpSessionTimeMode = SESSION_TIME_WIB; // Session input timezone: broker/UTC/WIB(UTC+7)
input string InpPauseWindows            = "1:00-9:00;12:00-13:00;18:00-22:00"; // Trading pause windows: "hh:mm-hh:mm;hh:mm-hh:mm"

input group "Stop Loss / Drawdown"
input double InpMaxDrawdownMoney        = 1000.0;   // Close all when floating drawdown >= value (0=off)
input EMaxDdResumeMode InpMaxDdResumeMode = MAX_DD_CONTINUE_TRADING; // Continue trading, pause manual, or resume next day

input group "Exit & Trailing"
input bool   InpUseBasketTrail          = true;  // Enable basket profit trailing
input double InpBasketTrailStartMoney   = 100.0;   // Mode switch: basket TP <= value => fixed TP, basket TP > value => start trailing after profit reaches basket TP
input double InpTrailDistancePercent    = 30.0;   // Close all when profit drops this % from peak (e.g. 33 => keep ~67% of peak)

struct SLevel
{
   double lot;
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
bool   g_closeLockActive = false;
int    g_closeLockLastRemain = -1;
bool   g_closeLockWaitTradePrinted = false;
bool   g_pausedByMaxDd = false;
int    g_maxDdPausedDayKey = 0;
int    g_lastKnownPosCount = 0;
int    g_fastMaHandle = INVALID_HANDLE;
int    g_slowMaHandle = INVALID_HANDLE;
ENUM_POSITION_TYPE g_activeBasketType = POSITION_TYPE_BUY;
bool   g_activeBasketTypeKnown = false;
ETradeMode g_effectiveTradeMode = TRADE_BUY_ONLY;

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

bool IsSellMode()
{
   return (g_effectiveTradeMode == TRADE_SELL_ONLY);
}

bool IsBothSingleMode()
{
   return (g_effectiveTradeMode == TRADE_BOTH_SINGLE);
}

ENUM_MA_METHOD MaMethod()
{
   return (InpMovingAverageType == MA_TYPE_SIMPLE ? MODE_SMA : MODE_EMA);
}

bool UseTrendFilter()
{
   return (InpTrendFilterMode != TREND_FILTER_OFF);
}

bool UseSingleEmaTrend()
{
   return (InpTrendFilterMode == TREND_FILTER_SINGLE_EMA);
}

bool UseDoubleEmaTrend()
{
   return (InpTrendFilterMode == TREND_FILTER_DOUBLE_EMA);
}

string TradeModeLabel()
{
   if(g_effectiveTradeMode == TRADE_BUY_ONLY)
      return "BUY_ONLY";
   if(g_effectiveTradeMode == TRADE_SELL_ONLY)
      return "SELL_ONLY";
  return "BOTH_SINGLE";
}

string TrendFilterModeLabel()
{
   if(InpTrendFilterMode == TREND_FILTER_SINGLE_EMA)
      return "SINGLE_EMA";
   if(InpTrendFilterMode == TREND_FILTER_DOUBLE_EMA)
      return "DOUBLE_EMA";
   return "OFF";
}

string MovingAverageTypeLabel()
{
   return (InpMovingAverageType == MA_TYPE_SIMPLE ? "SMA" : "EMA");
}

ENUM_POSITION_TYPE DefaultBasketType()
{
   return (IsSellMode() ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
}

bool DetectBasketType(const string symbol, const long magic, ENUM_POSITION_TYPE &type)
{
   int buyCount = 0;
   int sellCount = 0;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      const ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
         buyCount++;
      else if(posType == POSITION_TYPE_SELL)
         sellCount++;
   }

   if(buyCount > 0 && sellCount > 0)
      return false;

   if(buyCount > 0)
   {
      type = POSITION_TYPE_BUY;
      return true;
   }

   if(sellCount > 0)
   {
      type = POSITION_TYPE_SELL;
      return true;
   }

   type = DefaultBasketType();
   return false;
}

ENUM_POSITION_TYPE ActivePositionType()
{
   if(g_activeBasketTypeKnown)
      return g_activeBasketType;

   ENUM_POSITION_TYPE type = DefaultBasketType();
   if(DetectBasketType(g_symbol, InpMagic, type))
      return type;

   return type;
}

string ActiveSideLabel()
{
   return (ActivePositionType() == POSITION_TYPE_SELL ? "SELL" : "BUY");
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

datetime SessionReferenceTime(const datetime whenTime)
{
   if(InpSessionTimeMode == SESSION_TIME_BROKER)
      return whenTime;

   const int brokerUtcOffset = BrokerUtcOffsetHoursNow();
   datetime refTime = whenTime - (brokerUtcOffset * 3600);
   if(InpSessionTimeMode == SESSION_TIME_WIB)
      refTime += 7 * 3600;

   return refTime;
}

string SessionTimeModeLabel()
{
   if(InpSessionTimeMode == SESSION_TIME_UTC)
      return "UTC";
   if(InpSessionTimeMode == SESSION_TIME_WIB)
      return "WIB(UTC+7)";
   return "BROKER";
}

int MinutesOfDay(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(SessionReferenceTime(whenTime), dt);
   return dt.hour * 60 + dt.min;
}

bool ParseTimeToMinutes(const string text, int &minutes)
{
   minutes = -1;

   string value = text;
   StringTrimLeft(value);
   StringTrimRight(value);

   string cells[];
   if(StringSplit(value, ':', cells) != 2)
      return false;

   string hourText = cells[0];
   string minuteText = cells[1];
   StringTrimLeft(hourText);
   StringTrimRight(hourText);
   StringTrimLeft(minuteText);
   StringTrimRight(minuteText);

   const int hour = (int)StringToInteger(hourText);
   const int minute = (int)StringToInteger(minuteText);
   if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
      return false;

   minutes = hour * 60 + minute;
   return true;
}

bool IsInPauseWindowText(const int nowMinutes, const string windowText)
{
   string value = windowText;
   StringTrimLeft(value);
   StringTrimRight(value);
   if(StringLen(value) <= 0)
      return false;

   string parts[];
   if(StringSplit(value, '-', parts) != 2)
      return false;

   int startMinutes = -1;
   int endMinutes = -1;
   if(!ParseTimeToMinutes(parts[0], startMinutes))
      return false;
   if(!ParseTimeToMinutes(parts[1], endMinutes))
      return false;

   if(startMinutes <= endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes <= endMinutes);

   return (nowMinutes >= startMinutes || nowMinutes <= endMinutes);
}

bool IsInTimePauseWindow()
{
   if(!InpUseTimeFilter)
      return false;

   string windows = InpPauseWindows;
   StringTrimLeft(windows);
   StringTrimRight(windows);
   if(StringLen(windows) <= 0)
      return false;

   const int nowMinutes = MinutesOfDay(TimeCurrent());
   string ranges[];
   const int count = StringSplit(windows, ';', ranges);
   for(int i = 0; i < count; i++)
   {
      if(IsInPauseWindowText(nowMinutes, ranges[i]))
         return true;
   }

   return false;
}

string MaxDdResumeModeLabel()
{
   if(InpMaxDdResumeMode == MAX_DD_PAUSE_MANUAL)
      return "MANUAL";
   if(InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY)
      return "NEXT_DAY";
   return "CONTINUE";
}

string MaxDdResumeReferenceModeLabel()
{
   if(InpUseTimeFilter)
      return SessionTimeModeLabel();
   return "BROKER";
}

int MaxDdResumeReferenceDateKey(const datetime whenTime)
{
   if(InpUseTimeFilter)
   {
      MqlDateTime dt;
      TimeToStruct(SessionReferenceTime(whenTime), dt);
      return dt.year * 10000 + dt.mon * 100 + dt.day;
   }

   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

bool IsFirstEntryAllowedNow()
{
   if(!InpUseTimeFilter)
      return true;
   return !IsInTimePauseWindow();
}

bool GetBufferValue(const int handle, const int bufferIndex, const int shift, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE)
      return false;

   double data[];
   ArraySetAsSeries(data, true);
   if(CopyBuffer(handle, bufferIndex, shift, 1, data) != 1)
      return false;

   value = data[0];
   return true;
}

bool BuyTrendSideOK(const int shift)
{
   if(!UseTrendFilter())
      return true;

   double fast = 0.0, slow = 0.0;
   if(!GetBufferValue(g_fastMaHandle, 0, shift, fast))
      return false;

   if(UseSingleEmaTrend())
   {
      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice > fast);
   }

   if(UseDoubleEmaTrend())
   {
      if(!GetBufferValue(g_slowMaHandle, 0, shift, slow))
         return false;
      if(fast <= slow)
         return false;
      if(InpEmaMinDistance > 0.0 && MathAbs(fast - slow) < InpEmaMinDistance)
         return false;

      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice > fast);
   }

   return true;
}

bool SellTrendSideOK(const int shift)
{
   if(!UseTrendFilter())
      return true;

   double fast = 0.0, slow = 0.0;
   if(!GetBufferValue(g_fastMaHandle, 0, shift, fast))
      return false;

   if(UseSingleEmaTrend())
   {
      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice < fast);
   }

   if(UseDoubleEmaTrend())
   {
      if(!GetBufferValue(g_slowMaHandle, 0, shift, slow))
         return false;
      if(fast >= slow)
         return false;
      if(InpEmaMinDistance > 0.0 && MathAbs(fast - slow) < InpEmaMinDistance)
         return false;

      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice < fast);
   }

   return true;
}

bool SelectFirstEntryType(ENUM_POSITION_TYPE &entryType)
{
   entryType = DefaultBasketType();

   if(InpTradeMode == TRADE_BUY_ONLY)
      return (!UseTrendFilter() || BuyTrendSideOK(0));

   if(InpTradeMode == TRADE_SELL_ONLY)
      return (!UseTrendFilter() || SellTrendSideOK(0));

   if(!UseTrendFilter())
      return false;

   const bool buyOk = BuyTrendSideOK(0);
   const bool sellOk = SellTrendSideOK(0);

   if(buyOk && !sellOk)
   {
      entryType = POSITION_TYPE_BUY;
      return true;
   }

   if(sellOk && !buyOk)
   {
      entryType = POSITION_TYPE_SELL;
      return true;
   }

   if(buyOk)
   {
      entryType = POSITION_TYPE_BUY;
      return true;
   }

   if(sellOk)
   {
      entryType = POSITION_TYPE_SELL;
      return true;
   }

   return false;
}

bool OpenMarket(const ENUM_POSITION_TYPE type,
                const double lot,
                const string comment)
{
   bool ok = false;
   if(type == POSITION_TYPE_SELL)
      ok = trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, comment);
   else
      ok = trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, comment);

   if(ok)
   {
      g_lastTradeTime = TimeCurrent();
      g_activeBasketType = type;
      g_activeBasketTypeKnown = true;
      return true;
   }

   if(!IsTesterRun())
      Print("Open market failed | type=", (type == POSITION_TYPE_SELL ? "SELL" : "BUY"),
            " | lot=", DoubleToString(lot, 2),
            " | retcode=", (string)trade.ResultRetcode(),
            " | desc=", trade.ResultRetcodeDescription());

   return false;
}

bool IsGridDistanceReached(const double latestPrice,
                           const double gridPrice,
                           const double buyReferencePrice,
                           const double sellReferencePrice,
                           const bool includeEqual)
{
   if(includeEqual)
   {
      return (ActivePositionType() == POSITION_TYPE_SELL
              ? (sellReferencePrice >= (latestPrice + gridPrice))
              : (buyReferencePrice <= (latestPrice - gridPrice)));
   }

   return (ActivePositionType() == POSITION_TYPE_SELL
           ? (sellReferencePrice > (latestPrice + gridPrice))
           : (buyReferencePrice < (latestPrice - gridPrice)));
}

bool IsGridEntrySignalNow(const double latestPrice,
                          const double gridPrice)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   return IsGridDistanceReached(latestPrice, gridPrice, bid, ask, false);
}

ulong CloseDeviationPointsFromPriceDistance(const string symbol, const double deviationPrice)
{
   if(deviationPrice <= 0.0)
      return 0;

   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0;

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

void BuildPositionSnapshot(const string symbol, const long magic, const ENUM_POSITION_TYPE type, SPositionSnapshot &snapshot)
{
   snapshot.count = 0;
   snapshot.totalProfit = 0.0;
   snapshot.hasLatestPosition = false;
   snapshot.latestPrice = 0.0;
   datetime latestPositionTime = 0;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

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

int CountPositionsByType(const string symbol, const long magic, const ENUM_POSITION_TYPE type)
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
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      count++;
   }
   return count;
}

int CountManagedPositions(const string symbol, const long magic)
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
      count++;
   }
   return count;
}

int CloseAllPositionsByType(const string symbol, const long magic, const ENUM_POSITION_TYPE type)
{
   const ulong closeDeviation = CloseDeviationPointsFromPriceDistance(symbol, InpCloseDeviationPrice);
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
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

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
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

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
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

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

   const int remain = CountPositionsByType(symbol, magic, type);
   return remain;
}

int CloseAllPositionsWithRetries(const string symbol, const long magic, const ENUM_POSITION_TYPE type, const int maxAttempts)
{
   int attempts = maxAttempts;
   if(attempts <= 0)
      attempts = 1;
   if(InpUseAsyncClose && attempts > 1)
      attempts = 1;

   int remain = CountPositionsByType(symbol, magic, type);
   int prevRemain = remain + 1;
   for(int attempt = 0; attempt < attempts && remain > 0; attempt++)
   {
      remain = CloseAllPositionsByType(symbol, magic, type);
      if(remain >= prevRemain)
         break;
      prevRemain = remain;
   }

   return remain;
}

bool SpreadOK(const string symbol, const double maxSpreadPrice)
{
   if(maxSpreadPrice <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   return ((ask - bid) <= maxSpreadPrice);
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

bool TryAutoRestartAfterMaxDd(const int posCount)
{
   if(!g_pausedByMaxDd)
      return false;
   if(posCount > 0)
      return false;
   if(InpMaxDdResumeMode != MAX_DD_PAUSE_NEXT_DAY)
      return false;
   if(g_maxDdPausedDayKey <= 0)
      return false;

   const datetime now = TimeCurrent();
   const int nowDateKey = MaxDdResumeReferenceDateKey(now);
   if(nowDateKey <= g_maxDdPausedDayKey)
      return false;

   g_pausedByMaxDd = false;
   g_maxDdPausedDayKey = 0;
   ResetTrailState();
   DeactivateCloseLock();
   g_maxPosWarnSent = false;

   if(!IsTesterRun())
      Print("Max DD pause lifted | resume=next_day | ",
            MaxDdResumeReferenceModeLabel(), " | date_key=", nowDateKey,
            " | time_filter=", (InpUseTimeFilter ? "enabled" : "disabled"));

   return true;
}

bool ProcessCloseLock(const ENUM_POSITION_TYPE type, const int posCount)
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
   const int remain = CloseAllPositionsWithRetries(g_symbol, InpMagic, type, InpCloseAttemptsPerRun);
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

bool ParseLotTable()
{
   g_levelCount = 0;
   ArrayResize(g_levels, 0);

   string table = InpLotTable;
   StringTrimLeft(table);
   StringTrimRight(table);
   if(StringLen(table) <= 0)
      return false;

   string cells[];
   const int count = StringSplit(table, ';', cells);
   if(count <= 0)
      return false;

   int skippedCells = 0;
   for(int i = 0; i < count; i++)
   {
      string cell = cells[i];
      StringTrimLeft(cell);
      StringTrimRight(cell);
      if(StringLen(cell) <= 0)
      {
         skippedCells++;
         continue;
      }

      const double lot = StringToDouble(cell);
      if(lot <= 0.0)
      {
         skippedCells++;
         continue;
      }

      const int newSize = g_levelCount + 1;
      ArrayResize(g_levels, newSize);
      g_levels[g_levelCount].lot = NormalizeVolume(lot, g_symbol);
      g_levelCount = newSize;
   }

   if(skippedCells > 0 && !IsTesterRun())
      Print("Warn | lot table cells skipped | skipped=", skippedCells,
            " | parsed_levels=", g_levelCount);

   return (g_levelCount > 0);
}

double BasketTotalVolume(const string symbol, const long magic, const ENUM_POSITION_TYPE type)
{
   double totalVolume = 0.0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      totalVolume += PositionGetDouble(POSITION_VOLUME);
   }
   return totalVolume;
}

double BasketTpMoneyTarget(const string symbol, const long magic, const ENUM_POSITION_TYPE type)
{
   if(InpXauMoneyPerPriceUnit <= 0.0)
      return 0.0;

   const double totalVolume = BasketTotalVolume(symbol, magic, type);
   if(totalVolume <= 0.0)
      return 0.0;

   return totalVolume * InpXauMoneyPerPriceUnit;
}

bool GetLevelByPositionCount(const int positionCount, int &levelIndex, double &lot, double &gridPoints)
{
   if(g_levelCount <= 0)
      return false;

   int idx = positionCount;
   if(idx >= g_levelCount)
      idx = g_levelCount - 1;

   levelIndex = idx;
   lot = g_levels[idx].lot;
   gridPoints = InpGridDistance;
   return true;
}

bool CreateTrendHandles()
{
   if(!UseTrendFilter())
      return true;

   if(InpTrendEMAPeriod <= 0 || InpFastMAPeriod <= 0 || InpSlowMAPeriod <= 0)
      return false;

   const ENUM_APPLIED_PRICE appliedPrice = PRICE_CLOSE;
   if(UseSingleEmaTrend())
   {
      g_fastMaHandle = iMA(g_symbol, PERIOD_CURRENT, InpTrendEMAPeriod, 0, MaMethod(), appliedPrice);
      return (g_fastMaHandle != INVALID_HANDLE);
   }

   if(UseDoubleEmaTrend())
   {
      g_fastMaHandle = iMA(g_symbol, PERIOD_CURRENT, InpFastMAPeriod, 0, MaMethod(), appliedPrice);
      g_slowMaHandle = iMA(g_symbol, PERIOD_CURRENT, InpSlowMAPeriod, 0, MaMethod(), appliedPrice);
      return (g_fastMaHandle != INVALID_HANDLE && g_slowMaHandle != INVALID_HANDLE);
   }

   return true;
}

void ReleaseTrendHandles()
{
   if(g_fastMaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_fastMaHandle);
      g_fastMaHandle = INVALID_HANDLE;
   }

   if(g_slowMaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_slowMaHandle);
      g_slowMaHandle = INVALID_HANDLE;
   }
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
      if(!IsTesterRun())
         Print("Warn | account type is not HEDGING | fallback=limited_netting_behavior");
   }

   if(InpUseTimeFilter && StringLen(InpPauseWindows) <= 0)
   {
      Print("Init fail | invalid pause windows | value cannot be empty");
      return INIT_FAILED;
   }

   Print("Lot table config | table=", InpLotTable,
         " | grid_distance=", DoubleToString(InpGridDistance, 2),
         " | money_per_1price_1lot=", DoubleToString(InpXauMoneyPerPriceUnit, 2));

   if(InpGridDistance <= 0.0)
   {
      Print("Init fail | invalid grid distance | need > 0");
      return INIT_FAILED;
   }

   if(InpXauMoneyPerPriceUnit <= 0.0)
   {
      Print("Init fail | invalid money per price unit | need > 0");
      return INIT_FAILED;
   }

   if(!ParseLotTable())
   {
      Print("Init fail | lot table parse failed | table=", InpLotTable);
      return INIT_FAILED;
   }

   g_maxPositions = g_levelCount;

   if(!UseTrendFilter() && InpTradeMode == TRADE_BOTH_SINGLE)
   {
      g_effectiveTradeMode = TRADE_BUY_ONLY;
      if(!IsTesterRun())
         Print("Warn | TRADE_BOTH_SINGLE with Trend Filter OFF | fallback=BUY_ONLY");
   }
   else
   {
      g_effectiveTradeMode = InpTradeMode;
   }

   if(UseTrendFilter() && !CreateTrendHandles())
   {
      Print("Init fail | trend handle setup failed | mode=", TrendFilterModeLabel(),
            " | ma_type=", MovingAverageTypeLabel());
      ReleaseTrendHandles();
      return INIT_FAILED;
   }

   if(UseTrendFilter())
   {
      if(InpTrendFilterMode == TREND_FILTER_SINGLE_EMA && InpTrendEMAPeriod <= 0)
      {
         Print("Init fail | invalid Trend EMA period | need > 0");
         ReleaseTrendHandles();
         return INIT_FAILED;
      }

      if(InpTrendFilterMode == TREND_FILTER_DOUBLE_EMA &&
         (InpFastMAPeriod <= 0 || InpSlowMAPeriod <= 0))
      {
         Print("Init fail | invalid fast/slow EMA period | need > 0");
         ReleaseTrendHandles();
         return INIT_FAILED;
      }

   }

   if(InpUseBasketTrail)
   {
      if(InpBasketTrailStartMoney <= 0.0)
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
   g_pausedByMaxDd = false;
   g_maxDdPausedDayKey = 0;
   g_lastKnownPosCount = CountManagedPositions(g_symbol, InpMagic);

   const bool needTimer = InpUseCloseLock;
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
            " | InputTradeMode=", (InpTradeMode == TRADE_BUY_ONLY ? "BUY_ONLY" : (InpTradeMode == TRADE_SELL_ONLY ? "SELL_ONLY" : "BOTH_SINGLE")),
            " | EffectiveTradeMode=", TradeModeLabel(),
            " | DefaultSide=", ActiveSideLabel(),
            " | LotTable=", InpLotTable,
            " | GridDistance=", DoubleToString(InpGridDistance, 2),
            " | XauMoneyPerPriceUnit=", DoubleToString(InpXauMoneyPerPriceUnit, 2));

      Print("Init trend filter | Enabled=", (UseTrendFilter() ? "true" : "false"),
            " | TrendMode=", TrendFilterModeLabel(),
            " | MAType=", MovingAverageTypeLabel(),
            " | TrendEMA=", (string)InpTrendEMAPeriod,
            " | FastEMA=", (string)InpFastMAPeriod,
            " | SlowEMA=", (string)InpSlowMAPeriod,
            " | EminDistance=", DoubleToString(InpEmaMinDistance, 2));

      Print("Init risk/execution | UseCloseLock=", (InpUseCloseLock ? "true" : "false"),
            " | PriorityClose=", (InpUsePriorityCloseOrder ? "true" : "false"),
            " | UseAsyncClose=", (InpUseAsyncClose ? "true" : "false"),
            " | CloseDevPrice=", DoubleToString(InpCloseDeviationPrice, 2),
            " | CloseDevPoints=", (string)CloseDeviationPointsFromPriceDistance(g_symbol, InpCloseDeviationPrice),
            " | CloseAttempts=", (string)InpCloseAttemptsPerRun,
            " | CloseLockTimerMs=", (string)InpCloseLockTimerMs,
            " | MaxSpreadGridPrice=", DoubleToString(InpMaxSpreadGridEntryPrice, 2));

      Print("Init session/exit | UseTimeFilter=", (InpUseTimeFilter ? "true" : "false"),
            " | SessionMode=", SessionTimeModeLabel(),
            " | BrokerUTCOffset=", (string)BrokerUtcOffsetHoursNow(),
            " | PauseWindows=", InpPauseWindows,
            " | MaxDrawdown=", DoubleToString(InpMaxDrawdownMoney, 2),
            " | MaxDdResumeMode=", MaxDdResumeModeLabel(),
            " | MaxDdResumeRef=", MaxDdResumeReferenceModeLabel(),
            " | BasketTrail=", (InpUseBasketTrail ? "true" : "false"),
            " | BasketTrailStart=", DoubleToString(InpBasketTrailStartMoney, 2),
            " | TrailDistance%=", DoubleToString(InpTrailDistancePercent, 2),
            " | MaxPositions=", g_maxPositions,
            " | XauMoneyPerPriceUnit=", DoubleToString(InpXauMoneyPerPriceUnit, 2));

      for(int i = 0; i < g_levelCount; i++)
      {
         Print("Level ", (i + 1), " | lot=", DoubleToString(g_levels[i].lot, 2),
               " | gridDistance=", DoubleToString(InpGridDistance, 2));
      }
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseTrendHandles();
}

void OnTimer()
{
   if(!g_ready)
      return;

   ENUM_POSITION_TYPE basketType = DefaultBasketType();
   const bool hasBasket = DetectBasketType(g_symbol, InpMagic, basketType);
   const int posCount = CountManagedPositions(g_symbol, InpMagic);
   if(hasBasket)
   {
      g_activeBasketType = basketType;
      g_activeBasketTypeKnown = true;
   }

   ProcessCloseLock(hasBasket ? basketType : DefaultBasketType(), posCount);
}

void OnTick()
{
   if(!g_ready)
      return;

   if(_Symbol != g_symbol)
      return;

   ENUM_POSITION_TYPE basketType = DefaultBasketType();
   const bool hasBasket = DetectBasketType(g_symbol, InpMagic, basketType);
   if(hasBasket)
   {
      g_activeBasketType = basketType;
      g_activeBasketTypeKnown = true;
   }
   else
   {
      g_activeBasketTypeKnown = false;
   }

   SPositionSnapshot snapshot;
   BuildPositionSnapshot(g_symbol, InpMagic, basketType, snapshot);
   const int posCount = snapshot.count;
   const double floatingProfitNow = snapshot.totalProfit;

   // Detect transition from active basket to flat.
   if(posCount <= 0 && g_lastKnownPosCount > 0)
      g_maxPosWarnSent = false;
   g_lastKnownPosCount = posCount;

   if(posCount <= 0)
   {
      ResetTrailState();
      DeactivateCloseLock();
   }

   if(InpUseCloseLock && g_closeLockActive)
   {
      // Safety fallback: when timer is disabled/unavailable, keep processing lock on ticks.
      ProcessCloseLock(basketType, posCount);
      return;
   }

   if(g_pausedByMaxDd)
   {
      if(!TryAutoRestartAfterMaxDd(posCount))
      {
         if(posCount > 0)
         {
            if(InpUseCloseLock)
            {
               ActivateCloseLock("max_dd");
               return;
            }
            else
            {
               if(!IsTradeAllowed())
                  return;

               const int remain = CloseAllPositionsWithRetries(g_symbol, InpMagic, basketType, InpCloseAttemptsPerRun);
               if(remain == 0)
                  ResetTrailState();
            }
         }
         return;
      }
   }

   if(g_maxPositions > 0 && posCount < g_maxPositions)
      g_maxPosWarnSent = false;

   if(posCount > 0)
   {
      const double profit = floatingProfitNow;
      const double basketTpMoneyTarget = BasketTpMoneyTarget(g_symbol, InpMagic, basketType);
      if(InpMaxDrawdownMoney > 0.0 && profit <= -InpMaxDrawdownMoney)
      {
         g_pausedByMaxDd = (InpMaxDdResumeMode != MAX_DD_CONTINUE_TRADING);
         g_maxDdPausedDayKey = (InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY ? MaxDdResumeReferenceDateKey(TimeCurrent()) : 0);

         if(InpUseCloseLock)
         {
            ActivateCloseLock("max_dd");
            return;
         }
         else
         {
            if(!IsTradeAllowed())
               return;

            const int remain = CloseAllPositionsWithRetries(g_symbol, InpMagic, basketType, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
         }
         return;
      }
      double currentLevelTpMoney = 0.0;
      currentLevelTpMoney = basketTpMoneyTarget;

      const bool trailConfigOk =
         (InpUseBasketTrail &&
          InpBasketTrailStartMoney > 0.0 &&
          InpTrailDistancePercent > 0.0 &&
          InpTrailDistancePercent < 100.0);
      // Mode selection per your requested flow:
      // - basket TP <= trail start -> fixed TP
      // - basket TP > trail start  -> basket TP becomes trailing activation level
      const bool useTrailForThisGrid =
         (trailConfigOk &&
          currentLevelTpMoney > InpBasketTrailStartMoney);

      if(g_trailActive && !useTrailForThisGrid)
      {
         string trailOffReason = "basket_tp_below_trail_start";
         if(!InpUseBasketTrail)
            trailOffReason = "trail_disabled";
         else if(InpTrailDistancePercent <= 0.0 || InpTrailDistancePercent >= 100.0)
            trailOffReason = "trail_distance_out_of_range";
         else if(InpBasketTrailStartMoney <= 0.0)
            trailOffReason = "trail_start_invalid";

         if(!IsTesterRun())
            Print("Basket trail OFF | reason=", trailOffReason,
                  " | basket_tp=", DoubleToString(currentLevelTpMoney, 2),
                  " | trail_start=", DoubleToString(InpBasketTrailStartMoney, 2));
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

            const int remain = CloseAllPositionsWithRetries(g_symbol, InpMagic, basketType, InpCloseAttemptsPerRun);
            if(remain == 0)
               ResetTrailState();
         }
         return;
      }

      // For trail-mode grids, start trailing only after profit reaches basket TP.
      if(useTrailForThisGrid)
      {
         if(!g_trailActive && profit >= currentLevelTpMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            if(!IsTesterRun())
               Print("Basket trail ON | profit=", DoubleToString(profit, 2),
                     " | basket_tp=", DoubleToString(currentLevelTpMoney, 2),
                     " | trail_start=", DoubleToString(InpBasketTrailStartMoney, 2),
                     " | mode=activated_after_basket_tp_hit");
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

                     const int remain = CloseAllPositionsWithRetries(g_symbol, InpMagic, basketType, InpCloseAttemptsPerRun);
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

   if(posCount == 0)
   {
      if(!IsFirstEntryAllowedNow())
         return;

      double firstLot = 0.0;
      double dummyGridPoints = 0.0;
      int levelIndex = -1;
      if(!GetLevelByPositionCount(posCount, levelIndex, firstLot, dummyGridPoints))
         return;

      if(!SpreadOK(g_symbol, InpMaxSpreadGridEntryPrice))
         return;

      ENUM_POSITION_TYPE firstType = DefaultBasketType();
      if(!SelectFirstEntryType(firstType))
         return;
      if(!IsTesterRun())
         Print("Open first entry | level=", (levelIndex + 1),
               " | side=", (firstType == POSITION_TYPE_SELL ? "SELL" : "BUY"),
               " | lot=", DoubleToString(firstLot, 2),
               " | gridDistance=", DoubleToString(InpGridDistance, 2),
               " | trendMode=", TrendFilterModeLabel());
      if(!OpenMarket(firstType, firstLot, (firstType == POSITION_TYPE_SELL ? "TableGridSell" : "TableGridBuy")))
         return;
      return;
   }

   double lot;
   double gridPoints;
   int levelIndex = -1;
   if(!GetLevelByPositionCount(posCount, levelIndex, lot, gridPoints))
      return;

   if(!snapshot.hasLatestPosition)
      return;
   const double latest_price = snapshot.latestPrice;

   const double gridPrice = gridPoints;
   const bool shouldOpenGrid = IsGridEntrySignalNow(latest_price, gridPrice);
   if(shouldOpenGrid)
   {
      if(!SpreadOK(g_symbol, InpMaxSpreadGridEntryPrice))
         return;

      if(!IsTesterRun())
         Print("Open grid entry | level=", (levelIndex + 1),
               " | side=", ActiveSideLabel(),
               " | lot=", DoubleToString(lot, 2),
               " | gridDistance=", DoubleToString(gridPoints, 2),
               " | trigger=live_price");
      if(!OpenMarket(basketType, lot, (basketType == POSITION_TYPE_SELL ? "TableGridSell" : "TableGridBuy")))
         return;
   }
}
