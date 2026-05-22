//+------------------------------------------------------------------+
//| XAU_CandleClose_WickScalp.mq5                                    |
//| Wick setup on candle close, market entry after trigger confirms   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ESignalDirection
{
   SIGNAL_NONE = 0,
   SIGNAL_BUY = 1,
   SIGNAL_SELL = 2
};

enum EStopLossMode
{
   SL_FIXED_PIPS = 0,
   SL_CANDLE_EXTREME = 1
};

enum ESetupInvalidationMode
{
   INVALIDATE_SETUP_EXTREME = 0,
   INVALIDATE_SETUP_MIDPOINT = 1
};

input group "General"
input long   InpMagic                     = 260519; // Magic number
input bool   InpOnlyXauusd                = true;   // Allow run only on symbols containing XAUUSD

input group "Entry"
input double InpLots                      = 0.01;   // Lot size
input int    InpCooldownSecondsAfterClose = 60;     // Cooldown after close deal
input int    InpMaxSpreadPips             = 40;     // Max spread in EA pips (0=off)
input bool   InpAllowBuy                  = true;   // Allow BUY signals
input bool   InpAllowSell                 = true;   // Allow SELL signals
input bool   InpUseTriggerConfirmation    = true;   // Wait for price to break setup high/low
input double InpTriggerBufferPips         = 5.0;    // Trigger buffer beyond setup high/low
input int    InpSetupExpiryBars           = 1;      // Bars to keep setup alive after detection
input bool   InpCancelSetupOnInvalidation = true;   // Cancel setup if price moves against it first
input ESetupInvalidationMode InpInvalidationMode = INVALIDATE_SETUP_EXTREME; // Setup cancel level
input double InpInvalidationBufferPips    = 0.0;    // Extra buffer for setup invalidation

input group "Candle Signal"
input double InpWickBodyRatio             = 2.0;    // Wick must be >= body * ratio
input double InpCloseZonePercent          = 60.0;   // BUY close >= this %, SELL close <= 100-this %
input double InpMinCandleRangePips        = 50.0;   // Minimum previous candle range
input double InpMaxCandleRangePips        = 0.0;    // Maximum previous candle range (0=off)
input bool   InpRequireCandleColor        = true;   // BUY needs bullish candle, SELL needs bearish candle
input bool   InpUseLiquiditySweep         = true;   // Require sweep of recent high/low before rejection
input int    InpSweepLookbackBars         = 5;      // Bars used to define recent high/low
input double InpSweepBufferPips           = 0.0;    // Extra distance beyond recent high/low
input bool   InpUseEmaTrendFilter         = false;  // Optional EMA direction filter
input int    InpEmaPeriod                 = 50;     // EMA period for optional trend filter

input group "Risk"
input EStopLossMode InpStopLossMode       = SL_FIXED_PIPS; // Stop-loss mode
input double InpStopLossPips              = 150.0;  // Fixed stop loss distance
input double InpTakeProfitPips            = 150.0;  // Take profit distance; 150 = $1.50 XAU movement
input double InpCandleStopBufferPips      = 10.0;   // Buffer beyond candle high/low for candle SL

input group "Breakeven (Pips)"
input bool   InpUseBreakeven              = true;   // Move SL to breakeven after profit reaches threshold
input double InpBreakevenStartPips        = 75.0;   // Start breakeven after this favorable move
input double InpBreakevenLockPips         = 5.0;    // Lock this many pips beyond entry

input group "Trailing (Pips)"
input bool   InpUseTrail                  = false;  // Enable pips-based trailing stop
input double InpTrailStartPips            = 70.0;   // Activate trail after this profit
input double InpTrailDistancePips         = 35.0;   // SL distance from current market after trail starts

CTrade trade;
string g_symbol = "";
datetime g_lastBarTime = 0;
datetime g_lastExitTime = 0;
bool g_setupActive = false;
ESignalDirection g_setupSignal = SIGNAL_NONE;
double g_setupHigh = 0.0;
double g_setupLow = 0.0;
datetime g_setupBarTime = 0;
int g_setupBarsElapsed = 0;
int g_emaHandle = INVALID_HANDLE;

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

double PipsToPriceDistance(const string symbol, const double pips)
{
   if(pips <= 0.0)
      return 0.0;

   const double pip = PipPoint(symbol);
   if(pip <= 0.0)
      return 0.0;
   return pips * pip;
}

double NormalizeVolume(const string symbol, const double lot)
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

bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   return true;
}

bool SpreadOK(const string symbol, const double maxSpreadPips)
{
   if(maxSpreadPips <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double pip = PipPoint(symbol);
   if(ask <= 0.0 || bid <= 0.0 || pip <= 0.0)
      return false;

   const double spreadPips = (ask - bid) / pip;
   return (spreadPips <= maxSpreadPips);
}

int CountPositionsByMagic(const string symbol, const long magic)
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

bool IsNewBar()
{
   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime <= 0)
      return false;

   if(g_lastBarTime == 0)
   {
      g_lastBarTime = barTime;
      return false;
   }

   if(barTime == g_lastBarTime)
      return false;

   g_lastBarTime = barTime;
   return true;
}

void ClearSetup()
{
   g_setupActive = false;
   g_setupSignal = SIGNAL_NONE;
   g_setupHigh = 0.0;
   g_setupLow = 0.0;
   g_setupBarTime = 0;
   g_setupBarsElapsed = 0;
}

void StoreSetup(const ESignalDirection signal, const double setupHigh, const double setupLow)
{
   if(signal == SIGNAL_NONE)
   {
      ClearSetup();
      return;
   }

   g_setupActive = true;
   g_setupSignal = signal;
   g_setupHigh = setupHigh;
   g_setupLow = setupLow;
   g_setupBarTime = iTime(g_symbol, PERIOD_CURRENT, 1);
   g_setupBarsElapsed = 0;

   Print("Setup detected | signal=", (signal == SIGNAL_BUY ? "BUY" : "SELL"),
         " | high=", DoubleToString(g_setupHigh, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
         " | low=", DoubleToString(g_setupLow, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
}

void AgeSetupOnNewBar()
{
   if(!g_setupActive)
      return;

   g_setupBarsElapsed++;
   if(InpSetupExpiryBars > 0 && g_setupBarsElapsed >= InpSetupExpiryBars)
   {
      Print("Setup expired | signal=", (g_setupSignal == SIGNAL_BUY ? "BUY" : "SELL"),
            " | barsElapsed=", (string)g_setupBarsElapsed);
      ClearSetup();
   }
}

double LowestLowBeforeSetup(const int lookbackBars)
{
   double lowest = 0.0;
   for(int shift = 2; shift < 2 + lookbackBars; shift++)
   {
      const double low = iLow(g_symbol, PERIOD_CURRENT, shift);
      if(low <= 0.0)
         return 0.0;
      if(lowest <= 0.0 || low < lowest)
         lowest = low;
   }
   return lowest;
}

double HighestHighBeforeSetup(const int lookbackBars)
{
   double highest = 0.0;
   for(int shift = 2; shift < 2 + lookbackBars; shift++)
   {
      const double high = iHigh(g_symbol, PERIOD_CURRENT, shift);
      if(high <= 0.0)
         return 0.0;
      if(highest <= 0.0 || high > highest)
         highest = high;
   }
   return highest;
}

bool LiquiditySweepOK(const ESignalDirection signal,
                      const double high,
                      const double low,
                      const double close)
{
   if(!InpUseLiquiditySweep)
      return true;
   if(InpSweepLookbackBars <= 0)
      return true;

   const double buffer = PipsToPriceDistance(g_symbol, InpSweepBufferPips);
   if(signal == SIGNAL_BUY)
   {
      const double recentLow = LowestLowBeforeSetup(InpSweepLookbackBars);
      if(recentLow <= 0.0)
         return false;
      return (low < recentLow - buffer && close > recentLow);
   }

   if(signal == SIGNAL_SELL)
   {
      const double recentHigh = HighestHighBeforeSetup(InpSweepLookbackBars);
      if(recentHigh <= 0.0)
         return false;
      return (high > recentHigh + buffer && close < recentHigh);
   }

   return false;
}

bool EmaTrendOK(const ESignalDirection signal, const double close)
{
   if(!InpUseEmaTrendFilter)
      return true;
   if(g_emaHandle == INVALID_HANDLE)
      return false;

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_emaHandle, 0, 1, 1, ema) != 1)
      return false;
   if(ema[0] <= 0.0)
      return false;

   if(signal == SIGNAL_BUY)
      return (close > ema[0]);
   if(signal == SIGNAL_SELL)
      return (close < ema[0]);

   return false;
}

double ClampSlToMinDistance(const string symbol, const ENUM_POSITION_TYPE pType, const double slPrice)
{
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(point <= 0.0 || bid <= 0.0 || ask <= 0.0)
      return NormalizeDouble(slPrice, digits);

   const int stopsLevelPoints = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = stopsLevelPoints * point;
   double out = slPrice;

   if(pType == POSITION_TYPE_BUY)
   {
      const double maxSl = bid - minDist;
      if(out > maxSl)
         out = maxSl;
   }
   else if(pType == POSITION_TYPE_SELL)
   {
      const double minSl = ask + minDist;
      if(out < minSl)
         out = minSl;
   }

   return NormalizeDouble(out, digits);
}

double ClampTpToMinDistance(const string symbol, const ENUM_POSITION_TYPE pType, const double tpPrice)
{
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(point <= 0.0 || bid <= 0.0 || ask <= 0.0)
      return NormalizeDouble(tpPrice, digits);

   const int stopsLevelPoints = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = stopsLevelPoints * point;
   double out = tpPrice;

   if(pType == POSITION_TYPE_BUY)
   {
      const double minTp = ask + minDist;
      if(out < minTp)
         out = minTp;
   }
   else if(pType == POSITION_TYPE_SELL)
   {
      const double maxTp = bid - minDist;
      if(out > maxTp)
         out = maxTp;
   }

   return NormalizeDouble(out, digits);
}

ESignalDirection PreviousCandleSignal(double &prevHigh, double &prevLow)
{
   prevHigh = iHigh(g_symbol, PERIOD_CURRENT, 1);
   prevLow = iLow(g_symbol, PERIOD_CURRENT, 1);
   const double open = iOpen(g_symbol, PERIOD_CURRENT, 1);
   const double close = iClose(g_symbol, PERIOD_CURRENT, 1);

   if(open <= 0.0 || prevHigh <= 0.0 || prevLow <= 0.0 || close <= 0.0)
      return SIGNAL_NONE;
   if(prevHigh <= prevLow)
      return SIGNAL_NONE;

   const double pip = PipPoint(g_symbol);
   if(pip <= 0.0)
      return SIGNAL_NONE;

   const double range = prevHigh - prevLow;
   const double rangePips = range / pip;
   if(rangePips < InpMinCandleRangePips)
      return SIGNAL_NONE;
   if(InpMaxCandleRangePips > 0.0 && rangePips > InpMaxCandleRangePips)
      return SIGNAL_NONE;

   double body = MathAbs(close - open);
   const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(body < point)
      body = point;

   const double upperWick = prevHigh - MathMax(open, close);
   const double lowerWick = MathMin(open, close) - prevLow;
   const double closePositionPercent = ((close - prevLow) / range) * 100.0;

   const bool buyColorOk = (!InpRequireCandleColor || close > open);
   const bool sellColorOk = (!InpRequireCandleColor || close < open);

   if(InpAllowBuy &&
      buyColorOk &&
      lowerWick >= (body * InpWickBodyRatio) &&
      closePositionPercent >= InpCloseZonePercent &&
      LiquiditySweepOK(SIGNAL_BUY, prevHigh, prevLow, close) &&
      EmaTrendOK(SIGNAL_BUY, close))
      return SIGNAL_BUY;

   if(InpAllowSell &&
      sellColorOk &&
      upperWick >= (body * InpWickBodyRatio) &&
      closePositionPercent <= (100.0 - InpCloseZonePercent) &&
      LiquiditySweepOK(SIGNAL_SELL, prevHigh, prevLow, close) &&
      EmaTrendOK(SIGNAL_SELL, close))
      return SIGNAL_SELL;

   return SIGNAL_NONE;
}

bool BuildStops(const ESignalDirection signal,
                const double entryPrice,
                const double prevHigh,
                const double prevLow,
                double &sl,
                double &tp)
{
   const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const double slDist = PipsToPriceDistance(g_symbol, InpStopLossPips);
   const double tpDist = PipsToPriceDistance(g_symbol, InpTakeProfitPips);
   const double buffer = PipsToPriceDistance(g_symbol, InpCandleStopBufferPips);

   sl = 0.0;
   tp = 0.0;

   if(signal == SIGNAL_BUY)
   {
      if(InpStopLossMode == SL_CANDLE_EXTREME)
         sl = prevLow - buffer;
      else if(slDist > 0.0)
         sl = entryPrice - slDist;

      if(tpDist > 0.0)
         tp = entryPrice + tpDist;

      if(sl > 0.0)
         sl = ClampSlToMinDistance(g_symbol, POSITION_TYPE_BUY, sl);
      if(tp > 0.0)
         tp = ClampTpToMinDistance(g_symbol, POSITION_TYPE_BUY, tp);
   }
   else if(signal == SIGNAL_SELL)
   {
      if(InpStopLossMode == SL_CANDLE_EXTREME)
         sl = prevHigh + buffer;
      else if(slDist > 0.0)
         sl = entryPrice + slDist;

      if(tpDist > 0.0)
         tp = entryPrice - tpDist;

      if(sl > 0.0)
         sl = ClampSlToMinDistance(g_symbol, POSITION_TYPE_SELL, sl);
      if(tp > 0.0)
         tp = ClampTpToMinDistance(g_symbol, POSITION_TYPE_SELL, tp);
   }
   else
   {
      return false;
   }

   sl = (sl > 0.0 ? NormalizeDouble(sl, digits) : 0.0);
   tp = (tp > 0.0 ? NormalizeDouble(tp, digits) : 0.0);
   return true;
}

bool OpenSignalPosition(const ESignalDirection signal, const double prevHigh, const double prevLow)
{
   if(!IsTradeAllowed())
      return false;
   if(!SpreadOK(g_symbol, (double)InpMaxSpreadPips))
      return false;

   const double vol = NormalizeVolume(g_symbol, InpLots);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   double sl = 0.0;
   double tp = 0.0;
   bool ok = false;

   if(signal == SIGNAL_BUY)
   {
      if(!BuildStops(signal, ask, prevHigh, prevLow, sl, tp))
         return false;
      ok = trade.Buy(vol, g_symbol, 0.0, sl, tp, "WickCloseBuy");
   }
   else if(signal == SIGNAL_SELL)
   {
      if(!BuildStops(signal, bid, prevHigh, prevLow, sl, tp))
         return false;
      ok = trade.Sell(vol, g_symbol, 0.0, sl, tp, "WickCloseSell");
   }

   if(!ok)
   {
      Print("Open signal fail | signal=", (string)signal,
            " | retcode=", (string)trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription());
      return false;
   }

   Print("Open signal OK | signal=", (signal == SIGNAL_BUY ? "BUY" : "SELL"),
         " | lot=", DoubleToString(vol, 2),
         " | sl=", DoubleToString(sl, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
         " | tp=", DoubleToString(tp, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
   return true;
}

bool SetupTriggerReached()
{
   if(!g_setupActive)
      return false;
   if(!InpUseTriggerConfirmation)
      return true;

   const double triggerBuffer = PipsToPriceDistance(g_symbol, InpTriggerBufferPips);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   if(g_setupSignal == SIGNAL_BUY)
      return (ask >= g_setupHigh + triggerBuffer);
   if(g_setupSignal == SIGNAL_SELL)
      return (bid <= g_setupLow - triggerBuffer);

   return false;
}

bool SetupInvalidated()
{
   if(!g_setupActive || !InpCancelSetupOnInvalidation)
      return false;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return false;

   const double buffer = PipsToPriceDistance(g_symbol, InpInvalidationBufferPips);
   const double midpoint = (g_setupHigh + g_setupLow) * 0.5;

   if(g_setupSignal == SIGNAL_BUY)
   {
      const double level = (InpInvalidationMode == INVALIDATE_SETUP_MIDPOINT ? midpoint : g_setupLow);
      return (bid <= level - buffer);
   }

   if(g_setupSignal == SIGNAL_SELL)
   {
      const double level = (InpInvalidationMode == INVALIDATE_SETUP_MIDPOINT ? midpoint : g_setupHigh);
      return (ask >= level + buffer);
   }

   return false;
}

bool TryOpenSetupTrigger()
{
   if(!g_setupActive)
      return false;
   if(SetupInvalidated())
   {
      Print("Setup invalidated | signal=", (g_setupSignal == SIGNAL_BUY ? "BUY" : "SELL"));
      ClearSetup();
      return false;
   }
   if(!SetupTriggerReached())
      return false;

   const ESignalDirection signal = g_setupSignal;
   const double setupHigh = g_setupHigh;
   const double setupLow = g_setupLow;
   if(OpenSignalPosition(signal, setupHigh, setupLow))
   {
      ClearSetup();
      return true;
   }

   return false;
}

void ManageBreakeven()
{
   if(!InpUseBreakeven || InpBreakevenStartPips <= 0.0)
      return;

   const double pip = PipPoint(g_symbol);
   if(pip <= 0.0)
      return;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSl = PositionGetDouble(POSITION_SL);
      const double currentTp = PositionGetDouble(POSITION_TP);
      const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      if(openPrice <= 0.0 || bid <= 0.0 || ask <= 0.0)
         continue;

      double favorablePips = 0.0;
      double targetSl = 0.0;
      if(pType == POSITION_TYPE_BUY)
      {
         favorablePips = (bid - openPrice) / pip;
         if(favorablePips < InpBreakevenStartPips)
            continue;
         targetSl = ClampSlToMinDistance(g_symbol, pType, openPrice + PipsToPriceDistance(g_symbol, InpBreakevenLockPips));
         if(currentSl > 0.0 && targetSl <= currentSl)
            continue;
      }
      else if(pType == POSITION_TYPE_SELL)
      {
         favorablePips = (openPrice - ask) / pip;
         if(favorablePips < InpBreakevenStartPips)
            continue;
         targetSl = ClampSlToMinDistance(g_symbol, pType, openPrice - PipsToPriceDistance(g_symbol, InpBreakevenLockPips));
         if(currentSl > 0.0 && targetSl >= currentSl)
            continue;
      }
      else
      {
         continue;
      }

      if(!trade.PositionModify(ticket, targetSl, currentTp))
      {
         Print("Breakeven modify fail | ticket=", (string)ticket,
               " | retcode=", (string)trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      }
   }
}

void ManageTrailing()
{
   if(!InpUseTrail || InpTrailStartPips <= 0.0 || InpTrailDistancePips <= 0.0)
      return;

   const double pip = PipPoint(g_symbol);
   if(pip <= 0.0)
      return;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSl = PositionGetDouble(POSITION_SL);
      const double currentTp = PositionGetDouble(POSITION_TP);
      const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      if(openPrice <= 0.0 || bid <= 0.0 || ask <= 0.0)
         continue;

      double favorablePips = 0.0;
      double targetSl = 0.0;
      if(pType == POSITION_TYPE_BUY)
      {
         favorablePips = (bid - openPrice) / pip;
         if(favorablePips < InpTrailStartPips)
            continue;
         targetSl = ClampSlToMinDistance(g_symbol, pType, bid - PipsToPriceDistance(g_symbol, InpTrailDistancePips));
         if(currentSl > 0.0 && targetSl <= currentSl)
            continue;
      }
      else if(pType == POSITION_TYPE_SELL)
      {
         favorablePips = (openPrice - ask) / pip;
         if(favorablePips < InpTrailStartPips)
            continue;
         targetSl = ClampSlToMinDistance(g_symbol, pType, ask + PipsToPriceDistance(g_symbol, InpTrailDistancePips));
         if(currentSl > 0.0 && targetSl >= currentSl)
            continue;
      }
      else
      {
         continue;
      }

      if(!trade.PositionModify(ticket, targetSl, currentTp))
      {
         Print("Trail modify fail | ticket=", (string)ticket,
               " | retcode=", (string)trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      }
   }
}

int OnInit()
{
   g_symbol = _Symbol;
   if(!SymbolSelect(g_symbol, true))
   {
      Print("Init fail | cannot select symbol: ", g_symbol);
      return INIT_FAILED;
   }

   if(InpOnlyXauusd)
   {
      string sym = g_symbol;
      StringToUpper(sym);
      if(StringFind(sym, "XAUUSD") < 0)
      {
         Print("Init fail | symbol must contain XAUUSD");
         return INIT_FAILED;
      }
   }

   if(InpLots <= 0.0)
   {
      Print("Init fail | lots must be > 0");
      return INIT_FAILED;
   }
   if(InpWickBodyRatio <= 0.0)
   {
      Print("Init fail | wick/body ratio must be > 0");
      return INIT_FAILED;
   }
   if(InpCloseZonePercent <= 50.0 || InpCloseZonePercent >= 100.0)
   {
      Print("Init fail | close zone percent must be > 50 and < 100");
      return INIT_FAILED;
   }
   if(!InpAllowBuy && !InpAllowSell)
   {
      Print("Init fail | at least one direction must be enabled");
      return INIT_FAILED;
   }
   if(InpSetupExpiryBars < 1)
   {
      Print("Init fail | setup expiry bars must be >= 1");
      return INIT_FAILED;
   }
   if(InpTriggerBufferPips < 0.0)
   {
      Print("Init fail | trigger buffer pips must be >= 0");
      return INIT_FAILED;
   }
   if(InpSweepLookbackBars < 1)
   {
      Print("Init fail | sweep lookback bars must be >= 1");
      return INIT_FAILED;
   }
   if(InpEmaPeriod < 1)
   {
      Print("Init fail | EMA period must be >= 1");
      return INIT_FAILED;
   }
   if(InpBreakevenStartPips < 0.0 || InpBreakevenLockPips < 0.0)
   {
      Print("Init fail | breakeven pips must be >= 0");
      return INIT_FAILED;
   }

   if(InpUseEmaTrendFilter)
   {
      g_emaHandle = iMA(g_symbol, PERIOD_CURRENT, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandle == INVALID_HANDLE)
      {
         Print("Init fail | cannot create EMA handle");
         return INIT_FAILED;
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   g_lastBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   ClearSetup();

   Print("EA init OK | symbol=", g_symbol,
         " | pipPoint=", DoubleToString(PipPoint(g_symbol), 5),
         " | TPpips=", DoubleToString(InpTakeProfitPips, 1),
         " | SLpips=", DoubleToString(InpStopLossPips, 1),
         " | maxSpreadPips=", (string)InpMaxSpreadPips,
         " | triggerConfirm=", (InpUseTriggerConfirmation ? "true" : "false"),
         " | triggerBufferPips=", DoubleToString(InpTriggerBufferPips, 1),
         " | liquiditySweep=", (InpUseLiquiditySweep ? "true" : "false"),
         " | breakeven=", (InpUseBreakeven ? "true" : "false"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaHandle);
      g_emaHandle = INVALID_HANDLE;
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;

   const string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   const long dealMagic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   const ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(dealSymbol != g_symbol || dealMagic != InpMagic)
      return;

   if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
   {
      const double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      const double dealCommission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      const double dealSwap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
      const double dealFee = HistoryDealGetDouble(trans.deal, DEAL_FEE);
      const double dealNet = dealProfit + dealCommission + dealSwap + dealFee;
      Print("Deal OUT | deal=", (string)trans.deal,
            " | net=", DoubleToString(dealNet, 2));
      g_lastExitTime = TimeCurrent();
   }
}

void OnTick()
{
   if(_Symbol != g_symbol)
      return;
   if(!IsTradeAllowed())
      return;

   ManageBreakeven();
   ManageTrailing();

   if(CountPositionsByMagic(g_symbol, InpMagic) > 0)
   {
      ClearSetup();
      return;
   }

   if(InpCooldownSecondsAfterClose > 0 && g_lastExitTime > 0)
   {
      const int elapsed = (int)(TimeCurrent() - g_lastExitTime);
      if(elapsed < InpCooldownSecondsAfterClose)
         return;
   }

   if(IsNewBar())
   {
      AgeSetupOnNewBar();

      if(!g_setupActive)
      {
         double prevHigh = 0.0;
         double prevLow = 0.0;
         const ESignalDirection signal = PreviousCandleSignal(prevHigh, prevLow);
         if(signal != SIGNAL_NONE)
            StoreSetup(signal, prevHigh, prevLow);
      }
   }

   TryOpenSetupTrigger();
}
