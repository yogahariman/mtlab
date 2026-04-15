//+------------------------------------------------------------------+
//| XAUUSD_EMA_Grid_Martingale.mq5                                    |
//| EMA trend-following grid martingale EA for XAUUSD (MT5 Hedging)   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input long   InpMagic                  = 260413;             // Magic number
input double InpGridPips               = 50.0;               // Grid step in pips
input double InpGridStepIncrementPips  = 0;               // Add grid pips every N positions
input int    InpLotStepPositions       = 5;                  // Increase lot every N positions
input double InpMaxLot                 = 0;                 // Max lot cap (0=disabled)
input int    InpMaxPositions           = 0;                  // Max grid positions (0=disabled)
input int    InpMinSecondsBetweenOrders= 10;                 // Min delay between orders
input int    InpMaxSpreadPoints        = 0;                  // Max spread in points (0=disabled)
input double InpBasketTPMoney          = 15.0;               // Close all when total profit >= value
input ENUM_TIMEFRAMES InpEmaTimeframe  = PERIOD_CURRENT;     // EMA timeframe
input int    InpEmaPeriod              = 100;                // EMA period
input ENUM_APPLIED_PRICE InpEmaAppliedPrice = PRICE_CLOSE;   // EMA applied price
input bool   InpEmaUseClosedBar        = true;               // Use closed bar for EMA

// Base lot is locked to 0.01 per requirement.
const double BASE_LOT = 0.01;
const double LOT_INCREMENT = 0.01;

CTrade  trade;
string  g_symbol = "";
bool    g_ready  = false;

// Trade timing guard
datetime g_lastTradeTime = 0;

// Validated settings (avoid modifying input constants)
int      g_lotStepPositions = 1;
double   g_maxLot = BASE_LOT;
int      g_maxPositions = 0;
double   g_gridPips = 100.0;
double   g_gridStepIncrementPips = 0.0;
int      g_emaPeriod = 100;
ENUM_APPLIED_PRICE g_emaAppliedPrice = PRICE_CLOSE;
ENUM_TIMEFRAMES g_emaTimeframe = PERIOD_CURRENT;

// EMA handle
int      g_emaHandle = INVALID_HANDLE;

enum TradeDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = 2
};

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
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
   // XAUUSD standard: 1 pip = 0.01 (so 100 pips = $1.00)
   string sym = symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") >= 0)
      return 0.01;

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   // For 5/3-digit symbols, 1 pip = 10 points. Otherwise 1 pip = 1 point.
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
   // Enforce 2 decimal places for lot sizing
   vol = MathFloor(vol * 100.0 + 1e-8) / 100.0;
   if(vol < vmin) vol = vmin;
   if(vol > vmax) vol = vmax;
   if(vstep > 0.0)
      vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin) vol = vmin;

   // Keep 2 decimals after step adjustment
   vol = MathFloor(vol * 100.0 + 1e-8) / 100.0;
   return vol;
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

int CountPositions(const string symbol, const long magic)
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

bool GetLatestPosition(const string symbol, const long magic, const ENUM_POSITION_TYPE type,
                       datetime &latest_time, double &latest_price)
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
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

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
      profit += PositionGetDouble(POSITION_PROFIT);
   }
   return profit;
}

void CloseAllPositions(const string symbol, const long magic)
{
   // Close in reverse order for safety
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      trade.PositionClose(ticket);
   }
}

double GetGridStepPips(const int current_positions)
{
   int step = g_lotStepPositions;
   if(step <= 0) step = 1;

   const int level = current_positions / step;
   double grid = g_gridPips + (double)level * g_gridStepIncrementPips;
   if(grid < g_gridPips)
      grid = g_gridPips;
   return grid;
}

double GetNextLot(const int current_positions)
{
   int step = g_lotStepPositions;
   if(step <= 0) step = 1;

   const int level = current_positions / step;
   double lot = BASE_LOT + (double)level * LOT_INCREMENT;
   if(g_maxLot > 0.0 && lot > g_maxLot)
      lot = g_maxLot;
   return lot;
}

bool SpreadOK(const string symbol)
{
   if(InpMaxSpreadPoints <= 0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) return true;

   const double spreadPoints = (ask - bid) / point;
   return (spreadPoints <= InpMaxSpreadPoints);
}

bool GetEmaValue(const int handle, const int shift, double &value)
{
   double buffer[];
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   value = buffer[0];
   return true;
}

double GetAppliedPriceValue(const string symbol, const ENUM_TIMEFRAMES tf,
                            const ENUM_APPLIED_PRICE price_type, const int shift)
{
   double open = 0.0, high = 0.0, low = 0.0, close = 0.0;
   switch(price_type)
   {
      case PRICE_CLOSE:   return iClose(symbol, tf, shift);
      case PRICE_OPEN:    return iOpen(symbol, tf, shift);
      case PRICE_HIGH:    return iHigh(symbol, tf, shift);
      case PRICE_LOW:     return iLow(symbol, tf, shift);
      case PRICE_MEDIAN:
         high = iHigh(symbol, tf, shift);
         low  = iLow(symbol, tf, shift);
         return (high + low) * 0.5;
      case PRICE_TYPICAL:
         high  = iHigh(symbol, tf, shift);
         low   = iLow(symbol, tf, shift);
         close = iClose(symbol, tf, shift);
         return (high + low + close) / 3.0;
      case PRICE_WEIGHTED:
         high  = iHigh(symbol, tf, shift);
         low   = iLow(symbol, tf, shift);
         close = iClose(symbol, tf, shift);
         return (high + low + close + close) / 4.0;
      default:
         return iClose(symbol, tf, shift);
   }
}

TradeDirection GetTrendDirection()
{
   if(g_emaHandle == INVALID_HANDLE)
      return DIR_NONE;

   const int shift = (InpEmaUseClosedBar ? 1 : 0);
   double ema = 0.0;
   if(!GetEmaValue(g_emaHandle, shift, ema)) return DIR_NONE;

   const double price = GetAppliedPriceValue(g_symbol, g_emaTimeframe, g_emaAppliedPrice, shift);
   if(price <= 0.0) return DIR_NONE;

   if(price > ema) return DIR_BUY;
   if(price < ema) return DIR_SELL;
   return DIR_NONE;
}

bool OpenPosition(const string symbol, const TradeDirection dir, const double lot)
{
   if(!IsTradeAllowed())
      return false;

   const double vol = NormalizeVolume(lot, symbol);
   bool ok = false;
   if(dir == DIR_BUY)
      ok = trade.Buy(vol, symbol, 0.0, 0.0, 0.0, "MartingaleGridBuy");
   else if(dir == DIR_SELL)
      ok = trade.Sell(vol, symbol, 0.0, 0.0, 0.0, "MartingaleGridSell");
   if(ok)
      g_lastTradeTime = TimeCurrent();
   return ok;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
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

   if(InpLotStepPositions <= 0)
   {
      Print("Lot step positions must be >= 1. Using 1.");
      g_lotStepPositions = 1;
   }
   else
      g_lotStepPositions = InpLotStepPositions;

   if(InpMaxPositions <= 0)
   {
      Print("Max positions disabled (InpMaxPositions <= 0).");
      g_maxPositions = 0;
   }
   else
      g_maxPositions = InpMaxPositions;

   if(InpMaxLot > 0.0 && InpMaxLot < BASE_LOT)
   {
      Print("Max lot is below base lot. Using base lot.");
      g_maxLot = BASE_LOT;
   }
   else if(InpMaxLot > 0.0)
      g_maxLot = InpMaxLot;
   else
      g_maxLot = 0.0;

   if(InpGridPips <= 0.0)
   {
      Print("Grid pips must be > 0. Using 100.");
      g_gridPips = 100.0;
   }
   else
      g_gridPips = InpGridPips;

   if(InpGridStepIncrementPips < 0.0)
   {
      Print("Grid step increment must be >= 0. Using 0.");
      g_gridStepIncrementPips = 0.0;
   }
   else
      g_gridStepIncrementPips = InpGridStepIncrementPips;

   if(InpEmaPeriod <= 0)
   {
      Print("EMA period must be > 0. Using 100.");
      g_emaPeriod = 100;
   }
   else
      g_emaPeriod = InpEmaPeriod;

   g_emaAppliedPrice = InpEmaAppliedPrice;
   g_emaTimeframe = InpEmaTimeframe;

   g_emaHandle = iMA(g_symbol, g_emaTimeframe, g_emaPeriod, 0, MODE_EMA, g_emaAppliedPrice);
   if(g_emaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle.");
      return INIT_FAILED;
   }

   if(InpBasketTPMoney <= 0.0)
      Print("Basket TP is disabled (InpBasketTPMoney <= 0). Positions will not auto-close.");

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;

   Print("EA initialized for symbol: ", g_symbol,
         " | Base lot locked at 0.01 | Grid pips: ", DoubleToString(g_gridPips, 1),
         " | Grid step increment: ", DoubleToString(g_gridStepIncrementPips, 1),
         " | Basket TP money: ", DoubleToString(InpBasketTPMoney, 2),
         " | Lot step positions: ", g_lotStepPositions,
         " | Max lot: ", DoubleToString(g_maxLot, 2),
         " | Max positions: ", g_maxPositions,
         " | EMA: ", g_emaPeriod);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
}

//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_ready)
      return;

   // Run only on the intended symbol's chart
   if(_Symbol != g_symbol)
      return;

   if(!IsTradeAllowed())
      return;

   if(!SpreadOK(g_symbol))
      return;

   const TradeDirection trendDir = GetTrendDirection();
   if(trendDir == DIR_NONE)
      return;

   const int buyCount  = CountPositionsByType(g_symbol, InpMagic, POSITION_TYPE_BUY);
   const int sellCount = CountPositionsByType(g_symbol, InpMagic, POSITION_TYPE_SELL);
   const int posCount  = buyCount + sellCount;

   // Avoid mixed directions
   if(buyCount > 0 && sellCount > 0)
      return;

   // Optional basket TP
   if(InpBasketTPMoney > 0.0 && posCount > 0)
   {
      const double profit = TotalProfit(g_symbol, InpMagic);
      if(profit >= InpBasketTPMoney)
      {
         CloseAllPositions(g_symbol, InpMagic);
         return;
      }
   }

   if(g_maxPositions > 0 && posCount >= g_maxPositions)
      return;

   // Time guard between orders
   if(InpMinSecondsBetweenOrders > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
      return;

   if(posCount == 0)
   {
      OpenPosition(g_symbol, trendDir, BASE_LOT);
      return;
   }

   const TradeDirection openDir = (buyCount > 0 ? DIR_BUY : DIR_SELL);
   if(trendDir != openDir)
      return;

   datetime latest_time;
   double latest_price;
   if(!GetLatestPosition(g_symbol, InpMagic,
                         (openDir == DIR_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL),
                         latest_time, latest_price))
      return;

   const double gridPips = GetGridStepPips(posCount);
   const double gridPrice = gridPips * PipPoint(g_symbol);

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   if(openDir == DIR_BUY)
   {
      if(bid <= (latest_price - gridPrice))
      {
         const double lot = GetNextLot(posCount);
         OpenPosition(g_symbol, DIR_BUY, lot);
      }
   }
   else if(openDir == DIR_SELL)
   {
      if(ask >= (latest_price + gridPrice))
      {
         const double lot = GetNextLot(posCount);
         OpenPosition(g_symbol, DIR_SELL, lot);
      }
   }
}
