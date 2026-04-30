//+------------------------------------------------------------------+
//| XAU_BiGrid_Basket.mq5                                            |
//| BuyStop grid above + SellStop grid below + basket close all      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "2.10"
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
input double InpFixedLot                = 0.01;

input group "Grid"
input double InpGridDistancePips        = 250.0;
input int    InpGridLevelsPerSide       = 8;
input int    InpMinSecondsBetweenRearm  = 30;

input group "Basket Exit"
input double InpBasketTPMoney           = 8.0;
input double InpBasketStopLossMoney     = 0.0; // Basket Stop Loss (Account Currency, 0=Off)
input double InpEquityStopPercent       = 0.0;  // Equity Drawdown Stop (% of Balance, 0=Off)

input group "Trading Session"
input bool   InpUseTimeFilter           = true;   // Enable trading session filter
input ESessionTimeMode InpSessionTimeMode = SESSION_TIME_BROKER; // Session input timezone: broker/UTC/WIB(UTC+7)
input int    InpStartHourBroker         = 2;      // Start first entries from this hour in selected session timezone (00-23)
input int    InpPauseHourBroker         = 20;     // Pause-prep starts from this hour in selected session timezone (00-23)

input group "Trend Filter"
input bool   InpUseTrendFilter          = false;  // Enable MA trend filter for new grid placement
input ENUM_TIMEFRAMES InpTrendTimeframe = PERIOD_M15; // Trend timeframe
input int    InpTrendMAPeriod           = 100;    // MA period for trend
input ENUM_MA_METHOD InpTrendMAMethod   = MODE_EMA; // MA method
input double InpTrendBufferPips         = 30.0;   // Neutral zone around MA (pips)

input group "Filter"
input double InpMaxSpreadPips           = 40.0; // Max Allowed Spread (Pips, 0=Off)

CTrade trade;
string g_symbol = "";
datetime g_lastRearmTime = 0;
bool g_closeLockActive = false;
bool g_sessionPauseUntilStart = false;
int  g_trendMaHandle = INVALID_HANDLE;

int NormalizeHour(const int hour)
{
   int h = hour % 24;
   if(h < 0)
      h += 24;
   return h;
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


bool IsWithinTradingWindow(const datetime whenTime)
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
   const bool inStartWindow = IsWithinTradingWindow(now);

   if(g_sessionPauseUntilStart && inStartWindow)
   {
      g_sessionPauseUntilStart = false;
      Print("Session pause OFF | resumed at ", SessionTimeModeLabel(), " hour=", hourNow);
   }

   if(hourNow >= InpPauseHourBroker && posCount <= 0 && !g_sessionPauseUntilStart)
   {
      g_sessionPauseUntilStart = true;
      Print("Session pause ON | reason=flat_after_pause_hour | ",
            SessionTimeModeLabel(), " hour=", hourNow);
   }
}


bool IsNewGridAllowedNow(const int posCount)
{
   if(!InpUseTimeFilter)
      return true;

   if(g_sessionPauseUntilStart)
      return false;

   return (IsWithinTradingWindow(TimeCurrent()) || posCount > 0);
}


int TrendDirectionNow()
{
   if(!InpUseTrendFilter)
      return 0;

   if(g_trendMaHandle == INVALID_HANDLE)
      return 0;

   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   if(CopyBuffer(g_trendMaHandle, 0, 0, 1, maBuf) < 1)
      return 0;

   const double ma = maBuf[0];
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double pipPoint = PipPoint(g_symbol);
   if(ma <= 0.0 || bid <= 0.0 || ask <= 0.0 || pipPoint <= 0.0)
      return 0;

   const double buffer = InpTrendBufferPips * pipPoint;
   if(bid > ma + buffer)
      return 1;  // uptrend
   if(ask < ma - buffer)
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

   return ((ask - bid) / pipPoint <= InpMaxSpreadPips);
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
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         count++;
   }
   return count;
}


double BasketProfit()
{
   double totalProfit = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      totalProfit += PositionGetDouble(POSITION_PROFIT);
   }
   return totalProfit;
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
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      if(!trade.OrderDelete(ticket))
      {
         Print("Delete pending failed ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " msg=", trade.ResultRetcodeDescription());
      }
   }
}


bool PlaceBiGrid(const double anchorPrice, const int trendDir)
{
   const double pipPoint = PipPoint(g_symbol);
   if(pipPoint <= 0.0)
      return false;

   const double step = InpGridDistancePips * pipPoint;
   if(step <= 0.0 || InpGridLevelsPerSide <= 0)
      return false;

   const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const double lot = NormalizeVolume(InpFixedLot, g_symbol);

   bool allOk = true;
   bool anyPlaced = false;
   for(int level = 1; level <= InpGridLevelsPerSide; level++)
   {
      const double buyStopPrice = NormalizeDouble(anchorPrice + (level * step), digits);
      const double sellStopPrice = NormalizeDouble(anchorPrice - (level * step), digits);

      if(trendDir >= 0)
      {
         if(!trade.BuyStop(lot, buyStopPrice, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BiGrid BuyStop"))
         {
            allOk = false;
            Print("BuyStop failed level=", level,
                  " retcode=", trade.ResultRetcode(),
                  " msg=", trade.ResultRetcodeDescription());
         }
         else
         {
            anyPlaced = true;
         }
      }

      if(trendDir <= 0)
      {
         if(!trade.SellStop(lot, sellStopPrice, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BiGrid SellStop"))
         {
            allOk = false;
            Print("SellStop failed level=", level,
                  " retcode=", trade.ResultRetcode(),
                  " msg=", trade.ResultRetcodeDescription());
         }
         else
         {
            anyPlaced = true;
         }
      }
   }

   return (allOk && anyPlaced);
}


void CloseEverythingAndLock()
{
   g_closeLockActive = true;
   CloseAllMyPositions();
   DeleteAllMyPendingOrders();
}


void ManageBasketExit()
{
   if(CountMyPositions() <= 0)
   {
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

   const double profit = BasketProfit();
   if(profit >= InpBasketTPMoney)
   {
      Print("Basket TP hit. Profit=", DoubleToString(profit, 2), " -> close all.");
      CloseEverythingAndLock();
      return;
   }

   if(InpBasketStopLossMoney > 0.0 && profit <= -InpBasketStopLossMoney)
   {
      Print("Basket SL hit. Profit=", DoubleToString(profit, 2), " -> close all.");
      CloseEverythingAndLock();
   }
}


void RearmGridIfNeeded()
{
   if(!IsSpreadOk())
      return;

   if((TimeCurrent() - g_lastRearmTime) < InpMinSecondsBetweenRearm)
      return;

   const int posCount = CountMyPositions();
   const int pendingCount = CountMyPendingOrders();
   UpdateSessionPauseState(posCount);

   if(!IsNewGridAllowedNow(posCount))
      return;

   int trendDir = 0;
   if(InpUseTrendFilter)
   {
      trendDir = TrendDirectionNow();
      if(trendDir == 0)
      {
         if(pendingCount <= 0)
            Print("Trend filter: neutral zone, skip new grid.");
         return;
      }
   }

   if(pendingCount > 0)
      return;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   const double anchor = (bid + ask) * 0.5;
   if(PlaceBiGrid(anchor, trendDir))
   {
      g_lastRearmTime = TimeCurrent();
      if(posCount == 0)
         Print("Grid armed at anchor=", DoubleToString(anchor, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
      else
         Print("Grid replenished at anchor=", DoubleToString(anchor, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
   }
}


int OnInit()
{
   g_symbol = _Symbol;
   if(InpUseTimeFilter)
   {
      if(InpStartHourBroker < 0 || InpStartHourBroker > 23 ||
         InpPauseHourBroker < 0 || InpPauseHourBroker > 23)
      {
         Print("Init fail | invalid session hour | start/pause must be 0..23");
         return(INIT_PARAMETERS_INCORRECT);
      }

      if(InpStartHourBroker >= InpPauseHourBroker)
      {
         Print("Init fail | session config invalid | need start_hour < pause_hour");
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

      g_trendMaHandle = iMA(g_symbol, InpTrendTimeframe, InpTrendMAPeriod, 0, InpTrendMAMethod, PRICE_CLOSE);
      if(g_trendMaHandle == INVALID_HANDLE)
      {
         Print("Init fail | cannot create trend MA handle");
         return(INIT_FAILED);
      }
   }

   Print("Init ", __FILE__, " symbol=", g_symbol,
         " lot=", DoubleToString(InpFixedLot, 2),
         " gridPips=", DoubleToString(InpGridDistancePips, 1),
         " levels=", (string)InpGridLevelsPerSide,
         " | UseTimeFilter=", (InpUseTimeFilter ? "true" : "false"),
         " | SessionTZ=", SessionTimeModeLabel(),
         " | StartHour=", (string)InpStartHourBroker,
         " | PauseHour=", (string)InpPauseHourBroker,
         " | UseTrendFilter=", (InpUseTrendFilter ? "true" : "false"));
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
         CloseAllMyPositions();
         DeleteAllMyPendingOrders();
      }
      else
      {
         g_closeLockActive = false;
      }
      return;
   }

   RearmGridIfNeeded();
}
