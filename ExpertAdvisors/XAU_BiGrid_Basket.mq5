//+------------------------------------------------------------------+
//| XAU_BiGrid_Basket.mq5                                            |
//| Virtual grid above/below + basket close all                      |
//| Normal: buy above/sell below, reverse: buy below/sell above      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "2.19"
#property strict

#include <Trade/Trade.mqh>

enum ESessionTimeMode
{
   SESSION_TIME_BROKER = 0,
   SESSION_TIME_UTC = 1,
   SESSION_TIME_WIB = 2
};

input group "General"
input long   InpMagic                   = 260429;

input group "CSV Level Table"
input string InpTableFile               = "T_BG_90.csv"; // CSV in MQL5/Files or Common/Files: lot,gridPips,tpMoney
input bool   InpSkipFirstCsvRow         = true;  // Skip first CSV row/header
input bool   InpUseCommonFiles          = true;  // Read CSV from Terminal/Common/Files

input group "Grid"
input int    InpMinSecondsBetweenRearm  = 30;
input int    InpMaxGridPositions        = 0;  // Max open grid positions (0=Off, limited by CSV levels)
input bool   InpReverseGrid             = false; // false=buy breakout/sell breakdown, true=buy dip/sell rally

input group "Basket Exit"
input bool   InpUseBasketTrail          = true; // Trail basket after larger table TP is reached
input double InpTrailStartMoney         = 100.0; // Table TP >= this value uses trailing mode
input double InpTrailDistancePercent    = 30.0; // Close when profit drops this % from peak
input double InpBasketStopLossMoney     = 0.0; // Basket Stop Loss (Account Currency, 0=Off)
input bool   InpStopTradingAfterBasketSL = false; // After basket SL, stop trading until next start day
input double InpEquityStopPercent       = 0.0;  // Equity Drawdown Stop (% of Balance, 0=Off)

input group "Trading Session"
input ESessionTimeMode InpSessionTimeMode = SESSION_TIME_UTC; // Session input timezone: broker/UTC/WIB(UTC+7)
input bool   InpUseTimeFilter           = true;   // Enable trading session filter
input int    InpStartHourBroker         = 1;      // Start first entries from this hour in selected session timezone (00-23)
input int    InpPauseHourBroker         = 20;     // Pause-prep starts from this hour in selected session timezone (00-23)
input bool   InpUseMondaySession        = true;  // Use custom start hour on Monday
input int    InpMondayStartHourBroker   = 2;      // Monday start hour in selected session timezone (00-23)
input bool   InpUseFridaySession        = true;  // Use custom pause hour on Friday
input int    InpFridayPauseHourBroker   = 10;     // Friday pause-prep hour in selected session timezone (00-23)

input group "Trend Filter"
input bool   InpUseTrendFilter          = false;  // Enable MA trend filter for new grid placement
input ENUM_TIMEFRAMES InpTrendTimeframe = PERIOD_H1; // Trend timeframe
input int    InpTrendMAPeriod           = 100;    // MA period for trend
input ENUM_MA_METHOD InpTrendMAMethod   = MODE_EMA; // MA method
input int    InpTrendSlopeBars          = 5;      // MA slope lookback bars
input double InpTrendBufferPips         = 50.0;   // Neutral zone around MA (pips)

input group "Filter"
input double InpMaxSpreadPips           = 500.0; // Max Allowed Spread (Pips, 0=Off)

struct SGridLevel
{
   double lot;
   double gridPips;
   double distancePips;
   double tpMoney;
};

CTrade trade;
string g_symbol = "";
datetime g_lastRearmTime = 0;
bool g_closeLockActive = false;
bool g_sessionPauseUntilStart = false;
bool g_stopTradingByBasketSL = false;
int  g_trendMaHandle = INVALID_HANDLE;
datetime g_lastSpreadSkipLogTime = 0;
datetime g_lastMaxPositionLogTime = 0;
int g_basketSLStopDateKey = 0;
bool g_gridActive = false;
double g_gridAnchorPrice = 0.0;
int g_gridTrendDir = 0;
int g_nextBuyLevel = 1;
int g_nextSellLevel = 1;
SGridLevel g_levels[];
int g_levelCount = 0;
bool g_trailActive = false;
double g_trailPeakProfit = 0.0;

void ResetBasketTrail()
{
   g_trailActive = false;
   g_trailPeakProfit = 0.0;
}

void ResetVirtualGrid()
{
   g_gridActive = false;
   g_gridAnchorPrice = 0.0;
   g_gridTrendDir = 0;
   g_nextBuyLevel = 1;
   g_nextSellLevel = 1;
}

int BrokerHour(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   return dt.hour;
}


int BrokerUtcOffsetHoursNow()
{
   const datetime brokerNow = TimeCurrent();
   const datetime utcNow = TimeGMT();
   const int offsetSeconds = (int)(brokerNow - utcNow);
   return (int)MathRound((double)offsetSeconds / 3600.0);
}


void SessionReferenceTimeStruct(const datetime whenTime, MqlDateTime &dt)
{
   datetime refTime = whenTime;
   if(InpSessionTimeMode != SESSION_TIME_BROKER)
   {
      const int brokerUtcOffset = BrokerUtcOffsetHoursNow();
      refTime = whenTime - (brokerUtcOffset * 3600);
      if(InpSessionTimeMode == SESSION_TIME_WIB)
         refTime += 7 * 3600;
   }

   TimeToStruct(refTime, dt);
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
   MqlDateTime dt;
   SessionReferenceTimeStruct(whenTime, dt);
   return dt.hour;
}


int SessionReferenceDayOfWeek(const datetime whenTime)
{
   MqlDateTime dt;
   SessionReferenceTimeStruct(whenTime, dt);
   return dt.day_of_week;
}


bool GetTradingSession(const datetime whenTime, int &startHour, int &pauseHour, string &label)
{
   const int dayOfWeek = SessionReferenceDayOfWeek(whenTime);
   startHour = InpStartHourBroker;
   pauseHour = InpPauseHourBroker;
   label = "DEFAULT";

   if(!InpUseTimeFilter)
   {
      if(InpUseMondaySession && dayOfWeek == 1)
      {
         startHour = InpMondayStartHourBroker;
         label = "MONDAY";
         return true;
      }

      if(InpUseFridaySession && dayOfWeek == 5)
      {
         pauseHour = InpFridayPauseHourBroker;
         label = "FRIDAY";
         return true;
      }

      return false;
   }

   if(InpUseMondaySession && dayOfWeek == 1)
   {
      startHour = InpMondayStartHourBroker;
      label = "MONDAY";
   }
   else if(InpUseFridaySession && dayOfWeek == 5)
   {
      pauseHour = InpFridayPauseHourBroker;
      label = "FRIDAY";
   }

   return true;
}


int SessionReferenceDateKey(const datetime whenTime)
{
   MqlDateTime dt;
   SessionReferenceTimeStruct(whenTime, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}


int BrokerDateKey(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}


int CutLossRestartReferenceHour(const datetime whenTime)
{
   int startHour = 0;
   int pauseHour = 0;
   string label = "";
   if(GetTradingSession(whenTime, startHour, pauseHour, label))
      return SessionReferenceHour(whenTime);
   return BrokerHour(whenTime);
}


int CutLossRestartReferenceDateKey(const datetime whenTime)
{
   int startHour = 0;
   int pauseHour = 0;
   string label = "";
   if(GetTradingSession(whenTime, startHour, pauseHour, label))
      return SessionReferenceDateKey(whenTime);
   return BrokerDateKey(whenTime);
}


bool IsWithinTradingWindow(const datetime whenTime)
{
   int startHour = 0;
   int pauseHour = 0;
   string label = "";
   if(!GetTradingSession(whenTime, startHour, pauseHour, label))
      return true;

   const int h = SessionReferenceHour(whenTime);
   return (h >= startHour && h < pauseHour);
}


void UpdateSessionPauseState(const int posCount)
{
   const datetime now = TimeCurrent();
   int startHour = 0;
   int pauseHour = 0;
   string label = "";
   if(!GetTradingSession(now, startHour, pauseHour, label))
   {
      g_sessionPauseUntilStart = false;
      return;
   }

   const int hourNow = SessionReferenceHour(now);
   const bool inStartWindow = IsWithinTradingWindow(now);

   if(g_sessionPauseUntilStart && inStartWindow)
   {
      g_sessionPauseUntilStart = false;
      Print("Session pause OFF | resumed at ", SessionTimeModeLabel(),
            " hour=", hourNow,
            " | startHour=", startHour,
            " | session=", label);
   }

   if(hourNow >= pauseHour && posCount <= 0 && !g_sessionPauseUntilStart)
   {
      g_sessionPauseUntilStart = true;
      ResetVirtualGrid();
      Print("Session pause ON | reason=flat_after_pause_hour | ",
            SessionTimeModeLabel(), " hour=", hourNow,
            " | pauseHour=", pauseHour,
            " | session=", label);
   }
}


bool IsNewGridAllowedNow(const int posCount)
{
   const datetime now = TimeCurrent();
   int startHour = 0;
   int pauseHour = 0;
   string label = "";
   if(!GetTradingSession(now, startHour, pauseHour, label))
      return true;

   if(g_sessionPauseUntilStart)
      return false;

   // After pause hour, keep managing/averaging an active basket; block only fresh flat starts.
   return (IsWithinTradingWindow(now) || posCount > 0);
}


bool TryAutoRestartAfterBasketSL(const int posCount)
{
   if(!g_stopTradingByBasketSL)
      return true;

   if(posCount > 0)
      return false;

   if(g_basketSLStopDateKey <= 0)
      return false;

   const datetime now = TimeCurrent();
   const int nowDateKey = CutLossRestartReferenceDateKey(now);
   const int nowHour = CutLossRestartReferenceHour(now);
   int startHour = InpStartHourBroker;
   int pauseHour = InpPauseHourBroker;
   string label = "";
   const bool sessionFilterActive = GetTradingSession(now, startHour, pauseHour, label);
   if(nowDateKey <= g_basketSLStopDateKey)
      return false;
   if(nowHour < startHour)
      return false;
   if(sessionFilterActive && !IsWithinTradingWindow(now))
      return false;

   g_stopTradingByBasketSL = false;
   g_basketSLStopDateKey = 0;
   ResetVirtualGrid();
   ResetBasketTrail();
   g_sessionPauseUntilStart = false;

   Print("Basket SL auto restart | hour=", nowHour,
         " | startHour=", startHour,
         " | pauseHour=", pauseHour,
         " | session=", (sessionFilterActive ? label : "DEFAULT"),
         " | timeMode=", (sessionFilterActive ? SessionTimeModeLabel() : "BROKER"));
   return true;
}


int TrendDirectionNow()
{
   if(!InpUseTrendFilter)
      return 0;

   if(g_trendMaHandle == INVALID_HANDLE)
      return 0;

   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   const int neededBars = InpTrendSlopeBars + 1;
   if(CopyBuffer(g_trendMaHandle, 0, 0, neededBars, maBuf) < neededBars)
      return 0;

   const double ma = maBuf[0];
   const double maPast = maBuf[InpTrendSlopeBars];
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double pipPoint = PipPoint(g_symbol);
   if(ma <= 0.0 || maPast <= 0.0 || bid <= 0.0 || ask <= 0.0 || pipPoint <= 0.0)
      return 0;

   const double buffer = InpTrendBufferPips * pipPoint;
   if(bid > ma + buffer && ma > maPast)
      return 1;  // uptrend
   if(ask < ma - buffer && ma < maPast)
      return -1; // downtrend
   return 0;     // neutral
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


double NormalizeVolume(const double lot, const string symbol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double vol = lot;
   if(vol < vmin) vol = vmin;
   if(vol > vmax) vol = vmax;
   if(vstep > 0.0)
      vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin) vol = vmin;

   return NormalizeDouble(vol, 2);
}


bool IsSpreadOk()
{
   if(InpMaxSpreadPips <= 0.0)
      return true;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double pipPoint = PipPoint(g_symbol);
   if(pipPoint <= 0.0 || bid <= 0.0 || ask <= 0.0)
      return false;

   const double spreadPips = (ask - bid) / pipPoint;
   if(spreadPips <= InpMaxSpreadPips)
      return true;

   if((TimeCurrent() - g_lastSpreadSkipLogTime) >= 300)
   {
      g_lastSpreadSkipLogTime = TimeCurrent();
      Print("Skip grid | spread too high: ",
            DoubleToString(spreadPips, 1), " pips > max ",
            DoubleToString(InpMaxSpreadPips, 1), " pips");
   }

   return false;
}


int CountMyPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      count++;
   }
   return count;
}


bool IsHedgingAccount()
{
   const long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}


int EffectiveMaxGridPositions()
{
   if(g_levelCount <= 0)
      return 0;
   if(InpMaxGridPositions <= 0)
      return g_levelCount;
   return (int)MathMin(g_levelCount, InpMaxGridPositions);
}


bool CanOpenMorePositions(const int posCount)
{
   const int maxPositions = EffectiveMaxGridPositions();
   if(maxPositions <= 0)
      return false;

   if(posCount < maxPositions)
      return true;

   if((TimeCurrent() - g_lastMaxPositionLogTime) >= 300)
   {
      g_lastMaxPositionLogTime = TimeCurrent();
      Print("Skip entry | max open positions reached: ",
            (string)posCount, " >= ", (string)maxPositions,
            " | csvLevels=", (string)g_levelCount,
            " | maxGrid=", (string)InpMaxGridPositions);
   }

   return false;
}


int CountMyPendingOrders()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT)
         count++;
   }
   return count;
}


void BasketStats(int &count, double &totalProfit, double &totalLots)
{
   count = 0;
   totalProfit = 0.0;
   totalLots = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      count++;
      totalProfit += PositionGetDouble(POSITION_PROFIT);
      totalLots += PositionGetDouble(POSITION_VOLUME);
   }
}


bool GetLevelByPositionCount(const int positionCount, int &levelIndex, double &lot, double &gridPips, double &tpMoney)
{
   if(g_levelCount <= 0)
      return false;

   int idx = positionCount;
   if(idx < 0)
      idx = 0;
   if(idx >= g_levelCount)
      idx = g_levelCount - 1;

   levelIndex = idx;
   lot = g_levels[idx].lot;
   gridPips = g_levels[idx].gridPips;
   tpMoney = g_levels[idx].tpMoney;
   return true;
}


double CurrentBasketTPMoney(const int posCount)
{
   if(posCount <= 0)
      return 0.0;

   int levelIndex = -1;
   double lot = 0.0;
   double gridPips = 0.0;
   double tpMoney = 0.0;
   if(GetLevelByPositionCount(posCount - 1, levelIndex, lot, gridPips, tpMoney))
      return tpMoney;

   return 0.0;
}


bool ParseCsvLevelRow(const string row, double &lot, double &gridPips, double &tpMoney)
{
   string line = row;
   StringTrimLeft(line);
   StringTrimRight(line);
   if(StringLen(line) <= 0)
      return false;

   string cells[];
   const int cellCount = StringSplit(line, ',', cells);
   if(cellCount < 3)
      return false;

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
   gridPips = StringToDouble(sgrid);
   tpMoney = StringToDouble(stp);
   return (lot > 0.0 && gridPips > 0.0 && tpMoney > 0.0);
}


bool LoadLevelTableFromCsv(const string filename)
{
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   ResetLastError();
   const int handle = FileOpen(filename, flags);
   if(handle == INVALID_HANDLE)
   {
      Print("CSV open failed | file=", filename,
            " | err=", GetLastError(),
            " | common=", (InpUseCommonFiles ? "true" : "false"));
      return false;
   }

   ArrayResize(g_levels, 0);
   g_levelCount = 0;

   int rowNo = 0;
   bool firstDataRowHandled = false;
   double cumulativeGridPips = 0.0;
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      rowNo++;

      string trimmed = line;
      StringTrimLeft(trimmed);
      StringTrimRight(trimmed);
      if(StringLen(trimmed) <= 0)
         continue;
      if(StringGetCharacter(trimmed, 0) == '#')
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
      if(!ParseCsvLevelRow(trimmed, lot, gridPips, tpMoney))
      {
         Print("CSV invalid row | row=", rowNo,
               " | expected=lot,gridPips,tpMoney | data=", trimmed);
         FileClose(handle);
         return false;
      }

      cumulativeGridPips += gridPips;
      const int n = g_levelCount + 1;
      ArrayResize(g_levels, n);
      g_levels[g_levelCount].lot = lot;
      g_levels[g_levelCount].gridPips = gridPips;
      g_levels[g_levelCount].distancePips = cumulativeGridPips;
      g_levels[g_levelCount].tpMoney = tpMoney;
      g_levelCount = n;
   }

   FileClose(handle);

   if(g_levelCount <= 0)
   {
      Print("CSV invalid | no levels loaded | file=", filename);
      return false;
   }

   return true;
}


void CloseAllMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Close position failed ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " msg=", trade.ResultRetcodeDescription());
      }
   }
}


void DeleteAllMyPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP &&
         type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
         continue;

      if(!trade.OrderDelete(ticket))
      {
         Print("Delete pending failed ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " msg=", trade.ResultRetcodeDescription());
      }
   }
}


bool HasVirtualGridLevelsLeft()
{
   if(!g_gridActive)
      return false;

   if(g_gridTrendDir >= 0 && g_nextBuyLevel <= g_levelCount)
      return true;
   if(g_gridTrendDir <= 0 && g_nextSellLevel <= g_levelCount)
      return true;

   return false;
}


bool ArmVirtualGrid(const double anchorPrice, const int trendDir)
{
   const double pipPoint = PipPoint(g_symbol);
   if(pipPoint <= 0.0)
      return false;

   if(g_levelCount <= 0)
      return false;

   g_gridActive = true;
   g_gridAnchorPrice = anchorPrice;
   g_gridTrendDir = trendDir;
   g_nextBuyLevel = 1;
   g_nextSellLevel = 1;

   return true;
}


void ProcessVirtualGrid()
{
   if(!g_gridActive)
      return;

   const int posCount = CountMyPositions();
   UpdateSessionPauseState(posCount);
   if(!IsNewGridAllowedNow(posCount))
      return;

   if(!CanOpenMorePositions(posCount))
      return;

   if(!HasVirtualGridLevelsLeft())
   {
      ResetVirtualGrid();
      return;
   }

   if(!IsSpreadOk())
      return;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double pipPoint = PipPoint(g_symbol);
   if(bid <= 0.0 || ask <= 0.0 || pipPoint <= 0.0)
      return;

   const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const int maxPositions = EffectiveMaxGridPositions();
   int openCount = posCount;

   while(openCount < maxPositions)
   {
      bool opened = false;

      if(g_gridTrendDir >= 0 && g_nextBuyLevel <= g_levelCount)
      {
         const int idx = g_nextBuyLevel - 1;
         const double distance = g_levels[idx].distancePips * pipPoint;
         if(distance <= 0.0)
            return;

         const double upperPrice = NormalizeDouble(g_gridAnchorPrice + distance, digits);
         const double lowerPrice = NormalizeDouble(g_gridAnchorPrice - distance, digits);
         const bool shouldBuy = InpReverseGrid ? (ask <= lowerPrice) : (ask >= upperPrice);
         if(shouldBuy)
         {
            const double lot = NormalizeVolume(g_levels[idx].lot, g_symbol);
            if(trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, InpReverseGrid ? "TableGrid BuyDip" : "TableGrid BuyBreak"))
            {
               g_nextBuyLevel++;
               openCount++;
               opened = true;
            }
            else
            {
               Print("Virtual buy failed level=", g_nextBuyLevel,
                     " retcode=", trade.ResultRetcode(),
                     " msg=", trade.ResultRetcodeDescription());
               return;
            }
         }
      }

      if(openCount >= maxPositions)
         return;

      if(g_gridTrendDir <= 0 && g_nextSellLevel <= g_levelCount)
      {
         const int idx = g_nextSellLevel - 1;
         const double distance = g_levels[idx].distancePips * pipPoint;
         if(distance <= 0.0)
            return;

         const double upperPrice = NormalizeDouble(g_gridAnchorPrice + distance, digits);
         const double lowerPrice = NormalizeDouble(g_gridAnchorPrice - distance, digits);
         const bool shouldSell = InpReverseGrid ? (bid >= upperPrice) : (bid <= lowerPrice);
         if(shouldSell)
         {
            const double lot = NormalizeVolume(g_levels[idx].lot, g_symbol);
            if(trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, InpReverseGrid ? "TableGrid SellRally" : "TableGrid SellBreak"))
            {
               g_nextSellLevel++;
               openCount++;
               opened = true;
            }
            else
            {
               Print("Virtual sell failed level=", g_nextSellLevel,
                     " retcode=", trade.ResultRetcode(),
                     " msg=", trade.ResultRetcodeDescription());
               return;
            }
         }
      }

      if(!opened)
         break;
   }

   if(!HasVirtualGridLevelsLeft())
      ResetVirtualGrid();
}


void CloseEverythingAndLock()
{
   g_closeLockActive = true;
   ResetVirtualGrid();
   ResetBasketTrail();
   CloseAllMyPositions();
   DeleteAllMyPendingOrders();
}


void ManageBasketExit()
{
   int posCount = 0;
   double profit = 0.0;
   double totalLots = 0.0;
   BasketStats(posCount, profit, totalLots);
   if(posCount <= 0)
   {
      ResetBasketTrail();
      if(!g_closeLockActive || CountMyPendingOrders() <= 0)
         g_closeLockActive = false;
      return;
   }

   if(InpEquityStopPercent > 0.0)
   {
      const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(bal > 0.0)
      {
         const double ddPct = (bal - eq) / bal * 100.0;
         if(ddPct >= InpEquityStopPercent)
         {
            Print("Equity stop hit. DD%=", DoubleToString(ddPct, 2), " -> close all.");
            CloseEverythingAndLock();
            return;
         }
      }
   }

   const double targetTp = CurrentBasketTPMoney(posCount);
   const bool trailConfigOk =
      (InpUseBasketTrail &&
       InpTrailStartMoney > 0.0 &&
       InpTrailDistancePercent > 0.0 &&
       InpTrailDistancePercent < 100.0);
   const bool useTrailForThisBasket =
      (trailConfigOk &&
       targetTp >= InpTrailStartMoney);

   if(g_trailActive && !useTrailForThisBasket)
   {
      ResetBasketTrail();
      Print("Basket trail OFF | target=", DoubleToString(targetTp, 2),
            " | trailStart=", DoubleToString(InpTrailStartMoney, 2));
   }

   if(targetTp > 0.0)
   {
      if(!useTrailForThisBasket && profit >= targetTp)
      {
         Print("Basket TP hit. Profit=", DoubleToString(profit, 2),
               " | target=", DoubleToString(targetTp, 2),
               " | lots=", DoubleToString(totalLots, 2),
               " | positions=", (string)posCount,
               " -> close all.");
         CloseEverythingAndLock();
         return;
      }

      if(useTrailForThisBasket)
      {
         if(!g_trailActive && profit >= targetTp)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            Print("Basket trail ON | profit=", DoubleToString(profit, 2),
                  " | target=", DoubleToString(targetTp, 2),
                  " | lots=", DoubleToString(totalLots, 2),
                  " | distance%=", DoubleToString(InpTrailDistancePercent, 2));
         }

         if(g_trailActive)
         {
            if(profit > g_trailPeakProfit)
               g_trailPeakProfit = profit;

            const double trailStopProfit = g_trailPeakProfit * (1.0 - (InpTrailDistancePercent / 100.0));
            if(profit <= trailStopProfit)
            {
               Print("Basket trail hit. Profit=", DoubleToString(profit, 2),
                     " | peak=", DoubleToString(g_trailPeakProfit, 2),
                     " | stop=", DoubleToString(trailStopProfit, 2),
                     " -> close all.");
               CloseEverythingAndLock();
               return;
            }
         }
      }
   }

   if(InpBasketStopLossMoney > 0.0 && profit <= -InpBasketStopLossMoney)
   {
      if(InpStopTradingAfterBasketSL)
      {
         g_stopTradingByBasketSL = true;
         g_basketSLStopDateKey = CutLossRestartReferenceDateKey(TimeCurrent());
      }

      Print("Basket SL hit. Profit=", DoubleToString(profit, 2),
            " -> close all",
            (InpStopTradingAfterBasketSL ? " + stop trading until next day." : "."));
      CloseEverythingAndLock();
   }
}


void RearmGridIfNeeded()
{
   if((TimeCurrent() - g_lastRearmTime) < InpMinSecondsBetweenRearm)
      return;

   const int posCount = CountMyPositions();
   UpdateSessionPauseState(posCount);

   if(!IsNewGridAllowedNow(posCount))
      return;

   if(!CanOpenMorePositions(posCount))
      return;

   if(HasVirtualGridLevelsLeft())
      return;

   if(!IsSpreadOk())
      return;

   int trendDir = 0;
   if(InpUseTrendFilter)
   {
      trendDir = TrendDirectionNow();
      if(trendDir == 0)
      {
         Print("Trend filter: neutral zone, skip new grid.");
         return;
      }
   }

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   const double anchor = (bid + ask) * 0.5;
   if(ArmVirtualGrid(anchor, trendDir))
   {
      g_lastRearmTime = TimeCurrent();
      if(posCount == 0)
         Print("Virtual grid armed at anchor=", DoubleToString(anchor, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
      else
         Print("Virtual grid replenished at anchor=", DoubleToString(anchor, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
   }
}


int OnInit()
{
   g_symbol = _Symbol;

   if(InpMaxGridPositions < 0)
   {
      Print("Init fail | max grid positions must be >= 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpUseTimeFilter || InpUseFridaySession ||
      (InpBasketStopLossMoney > 0.0 && InpStopTradingAfterBasketSL))
   {
      if(InpStartHourBroker < 0 || InpStartHourBroker > 23)
      {
         Print("Init fail | invalid start hour | start must be 0..23");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(InpUseTimeFilter || InpUseMondaySession)
   {
      if(InpPauseHourBroker < 0 || InpPauseHourBroker > 23)
      {
         Print("Init fail | invalid pause hour | pause must be 0..23");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(InpUseTimeFilter)
   {
      if(InpStartHourBroker >= InpPauseHourBroker)
      {
         Print("Init fail | session config invalid | need start_hour < pause_hour");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(InpUseMondaySession)
   {
      if(InpMondayStartHourBroker < 0 || InpMondayStartHourBroker > 23)
      {
         Print("Init fail | invalid monday start hour | start must be 0..23");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpMondayStartHourBroker >= InpPauseHourBroker)
      {
         Print("Init fail | monday session config invalid | need start_hour < pause_hour");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(InpUseFridaySession)
   {
      if(InpFridayPauseHourBroker < 0 || InpFridayPauseHourBroker > 23)
      {
         Print("Init fail | invalid friday pause hour | pause must be 0..23");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpStartHourBroker >= InpFridayPauseHourBroker)
      {
         Print("Init fail | friday session config invalid | need start_hour < pause_hour");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(!IsHedgingAccount())
   {
      Print("Init fail | account type must be HEDGING for max open positions and basket grid logic");
      return(INIT_FAILED);
   }

   if(!LoadLevelTableFromCsv(InpTableFile))
      return(INIT_FAILED);

   if(InpUseBasketTrail)
   {
      if(InpTrailStartMoney <= 0.0 ||
         InpTrailDistancePercent <= 0.0 ||
         InpTrailDistancePercent >= 100.0)
      {
         Print("Init fail | basket trail needs trail start > 0 and distance percent > 0 and < 100");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   if(InpUseTrendFilter)
   {
      if(InpTrendMAPeriod <= 1)
      {
         Print("Init fail | trend MA period must be > 1");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpTrendSlopeBars < 1)
      {
         Print("Init fail | trend slope bars must be >= 1");
         return(INIT_PARAMETERS_INCORRECT);
      }

      g_trendMaHandle = iMA(g_symbol, InpTrendTimeframe, InpTrendMAPeriod, 0, InpTrendMAMethod, PRICE_CLOSE);
      if(g_trendMaHandle == INVALID_HANDLE)
      {
         Print("Init fail | cannot create trend MA handle");
         return(INIT_FAILED);
      }
   }

   Print("Init ", __FILE__, " symbol=", g_symbol,
         " levels=", (string)g_levelCount,
         " | CSV=", InpTableFile,
         " | CommonFiles=", (InpUseCommonFiles ? "true" : "false"),
         " | GridMode=table_virtual",
         " | MaxGrid=", (string)InpMaxGridPositions,
         " | EffectiveMaxGrid=", (string)EffectiveMaxGridPositions(),
         " | ReverseGrid=", (InpReverseGrid ? "true" : "false"),
         " | BasketTP=table",
         " | BasketTrail=", (InpUseBasketTrail ? "true" : "false"),
         " | TrailStart=", DoubleToString(InpTrailStartMoney, 2),
         " | TrailDistance%=", DoubleToString(InpTrailDistancePercent, 2),
         " | BasketSL=", DoubleToString(InpBasketStopLossMoney, 2),
         " | StopAfterBasketSL=", (InpStopTradingAfterBasketSL ? "true" : "false"),
         " | UseTimeFilter=", (InpUseTimeFilter ? "true" : "false"),
         " | SessionTZ=", SessionTimeModeLabel(),
         " | StartHour=", (string)InpStartHourBroker,
         " | PauseHour=", (string)InpPauseHourBroker,
         " | UseMondaySession=", (InpUseMondaySession ? "true" : "false"),
         " | MondayStartHour=", (string)InpMondayStartHourBroker,
         " | UseFridaySession=", (InpUseFridaySession ? "true" : "false"),
         " | FridayPauseHour=", (string)InpFridayPauseHourBroker,
         " | UseTrendFilter=", (InpUseTrendFilter ? "true" : "false"),
         " | TrendTF=", EnumToString(InpTrendTimeframe),
         " | TrendMAPeriod=", (string)InpTrendMAPeriod,
         " | TrendSlopeBars=", (string)InpTrendSlopeBars,
         " | TrendBufferPips=", DoubleToString(InpTrendBufferPips, 1));
   return(INIT_SUCCEEDED);
}


void OnDeinit(const int reason)
{
   if(g_trendMaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_trendMaHandle);
      g_trendMaHandle = INVALID_HANDLE;
   }
}


void OnTick()
{
   ManageBasketExit();

   if(g_closeLockActive)
   {
      if(CountMyPositions() > 0 || CountMyPendingOrders() > 0)
      {
         ResetVirtualGrid();
         ResetBasketTrail();
         CloseAllMyPositions();
         DeleteAllMyPendingOrders();
      }
      else
      {
         g_closeLockActive = false;
      }
      return;
   }

   if(g_stopTradingByBasketSL)
   {
      const int posCount = CountMyPositions();
      if(!TryAutoRestartAfterBasketSL(posCount))
      {
         if(posCount > 0)
            CloseEverythingAndLock();
         return;
      }
   }

   ProcessVirtualGrid();
   RearmGridIfNeeded();
}
