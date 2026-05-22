//+------------------------------------------------------------------+
//| XAU_EMA_SNR_ATR.mq5                                              |
//| Single-shot XAUUSD EA using EMA trend, SNR location, ATR risk      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.20"
#property strict

#include <Trade/Trade.mqh>

enum ETradeSide
{
   SIDE_BOTH = 0,
   SIDE_BUY_ONLY = 1,
   SIDE_SELL_ONLY = 2
};

input group "General"
input long   InpMagic                 = 260522; // Magic number
input bool   InpOnlyXauusd            = true;   // Allow run only on symbols containing XAUUSD
input ETradeSide InpTradeSide         = SIDE_BOTH; // Allowed trade side
input double InpLots                  = 0.01;   // Fixed lot size
input int    InpMinSecondsBetweenTrades = 60;   // Minimum seconds between entries
input double InpMaxSpreadPips         = 40.0;   // Max spread in XAU pips; 100 = $1

input group "EMA Trend"
input int    InpFastEmaPeriod         = 20;     // Fast EMA period
input int    InpSlowEmaPeriod         = 50;     // Slow EMA period
input bool   InpRequireCloseBeyondFastEma = true; // BUY close > fast EMA, SELL close < fast EMA

input group "SNR"
input int    InpSnrLookbackBars       = 20;     // Bars to find support/resistance, excluding signal candle
input double InpSnrTouchTolerancePips = 100.0;  // Max distance from SNR; 100 = $1
input bool   InpRequireCandleColor    = true;   // BUY needs bullish candle, SELL needs bearish candle
input double InpMinSignalRangePips    = 0.0;    // Minimum signal candle range; 0=off

input group "SNR Validation"
input bool   InpUseSnrValidation      = true;   // Require repeated touches and rejection
input int    InpMinSnrTouches         = 2;      // Minimum historical touches near SNR
input double InpSnrValidationZonePips = 100.0;  // Touch zone around SNR; 100 = $1
input int    InpMinBarsBetweenTouches = 3;      // Minimum bar gap between counted touches
input bool   InpRequireSnrRejection   = true;   // Require signal candle rejection wick
input double InpMinRejectWickRatio    = 1.2;    // Rejection wick must be >= body * ratio

input group "ATR Risk"
input int    InpAtrPeriod             = 14;     // ATR period
input double InpAtrStopMultiplier     = 1.5;    // SL distance = ATR * multiplier
input double InpMinStopPips           = 100.0;  // Minimum SL distance; 100 = $1
input double InpRewardRiskRatio       = 1.2;    // TP distance = SL distance * ratio

input group "Position Management"
input bool   InpUseBreakeven          = true;   // Move SL after profit reaches threshold
input double InpBreakevenStartPips    = 100.0;  // Start breakeven after this move; 100 = $1
input double InpBreakevenLockPips     = 10.0;   // Lock this many pips beyond entry
input bool   InpUseTrail              = true;   // Trail SL after profit reaches threshold
input double InpTrailStartPips        = 150.0;  // Start trailing after this move
input double InpTrailDistancePips     = 100.0;  // SL distance from current price while trailing

CTrade trade;
string g_symbol = "";
datetime g_lastBarTime = 0;
datetime g_lastEntryTime = 0;
int g_fastEmaHandle = INVALID_HANDLE;
int g_slowEmaHandle = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;

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

double NormalizePrice(const string symbol, const double price)
{
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double NormalizeVolume(const string symbol, const double lot)
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

ulong DeviationPointsFromPips(const string symbol, const double pips)
{
   if(pips <= 0.0)
      return 0;

   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const double priceDistance = PipsToPriceDistance(symbol, pips);
   if(point <= 0.0 || priceDistance <= 0.0)
      return 0;

   const long points = (long)MathRound(priceDistance / point);
   if(points <= 0)
      return 1;
   return (ulong)points;
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

bool SelectManagedPosition(ulong &ticket)
{
   ticket = 0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      if(!PositionSelectByTicket(posTicket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ticket = posTicket;
      return true;
   }

   return false;
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

bool GetBufferValue(const int handle, const int shift, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE)
      return false;

   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;

   value = buffer[0];
   return (value > 0.0);
}

bool GetSnrLevels(double &support, double &resistance)
{
   support = 0.0;
   resistance = 0.0;

   if(InpSnrLookbackBars < 2)
      return false;

   const int lowShift = iLowest(g_symbol, PERIOD_CURRENT, MODE_LOW, InpSnrLookbackBars, 2);
   const int highShift = iHighest(g_symbol, PERIOD_CURRENT, MODE_HIGH, InpSnrLookbackBars, 2);
   if(lowShift < 0 || highShift < 0)
      return false;

   support = iLow(g_symbol, PERIOD_CURRENT, lowShift);
   resistance = iHigh(g_symbol, PERIOD_CURRENT, highShift);
   return (support > 0.0 && resistance > 0.0 && resistance > support);
}

int CountSnrTouches(const bool isSupport, const double level, const double zone)
{
   if(level <= 0.0 || zone <= 0.0)
      return 0;

   int touches = 0;
   int lastTouchShift = -100000;
   const int minGap = MathMax(1, InpMinBarsBetweenTouches);

   for(int shift = 2; shift < 2 + InpSnrLookbackBars; shift++)
   {
      const double high = iHigh(g_symbol, PERIOD_CURRENT, shift);
      const double low = iLow(g_symbol, PERIOD_CURRENT, shift);
      if(high <= 0.0 || low <= 0.0)
         continue;

      const bool touched = (isSupport
         ? (low <= level + zone && high >= level)
         : (high >= level - zone && low <= level));

      if(!touched)
         continue;

      if(lastTouchShift < 0 || MathAbs(shift - lastTouchShift) >= minGap)
      {
         touches++;
         lastTouchShift = shift;
      }
   }

   return touches;
}

bool HasRejectionWick(const bool isBuy)
{
   const double open1 = iOpen(g_symbol, PERIOD_CURRENT, 1);
   const double high1 = iHigh(g_symbol, PERIOD_CURRENT, 1);
   const double low1 = iLow(g_symbol, PERIOD_CURRENT, 1);
   const double close1 = iClose(g_symbol, PERIOD_CURRENT, 1);
   if(open1 <= 0.0 || high1 <= 0.0 || low1 <= 0.0 || close1 <= 0.0)
      return false;

   const double body = MathAbs(close1 - open1);
   const double lowerWick = MathMin(open1, close1) - low1;
   const double upperWick = high1 - MathMax(open1, close1);
   const double bodyForRatio = MathMax(body, SymbolInfoDouble(g_symbol, SYMBOL_POINT));

   if(isBuy)
      return (lowerWick >= bodyForRatio * InpMinRejectWickRatio);

   return (upperWick >= bodyForRatio * InpMinRejectWickRatio);
}

bool SnrValidationOK(const bool isSupport, const double level)
{
   if(!InpUseSnrValidation)
      return true;

   const double zone = PipsToPriceDistance(g_symbol, InpSnrValidationZonePips);
   if(zone <= 0.0)
      return false;

   if(InpMinSnrTouches > 0)
   {
      const int touches = CountSnrTouches(isSupport, level, zone);
      if(touches < InpMinSnrTouches)
         return false;
   }

   if(InpRequireSnrRejection && !HasRejectionWick(isSupport))
      return false;

   return true;
}

double BrokerMinStopDistance(const string symbol)
{
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(point <= 0.0 || stopsLevel <= 0)
      return 0.0;

   return (double)stopsLevel * point;
}

bool IsStopFarEnough(const bool isBuy, const double newSl)
{
   const double minDistance = BrokerMinStopDistance(g_symbol);
   if(minDistance <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   if(isBuy)
      return ((bid - newSl) >= minDistance);

   return ((newSl - ask) >= minDistance);
}

bool BuildStops(const bool isBuy, const double entryPrice, const double atrValue, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   const double minStop = PipsToPriceDistance(g_symbol, InpMinStopPips);
   double stopDistance = atrValue * InpAtrStopMultiplier;
   if(stopDistance < minStop)
      stopDistance = minStop;

   const double brokerMin = BrokerMinStopDistance(g_symbol);
   if(brokerMin > 0.0 && stopDistance < brokerMin)
      stopDistance = brokerMin;

   const double tpDistance = stopDistance * InpRewardRiskRatio;
   if(stopDistance <= 0.0 || tpDistance <= 0.0)
      return false;

   if(isBuy)
   {
      sl = NormalizePrice(g_symbol, entryPrice - stopDistance);
      tp = NormalizePrice(g_symbol, entryPrice + tpDistance);
   }
   else
   {
      sl = NormalizePrice(g_symbol, entryPrice + stopDistance);
      tp = NormalizePrice(g_symbol, entryPrice - tpDistance);
   }

   return true;
}

void ManageOpenPosition()
{
   ulong ticket = 0;
   if(!SelectManagedPosition(ticket))
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   const long type = PositionGetInteger(POSITION_TYPE);
   const bool isBuy = (type == POSITION_TYPE_BUY);
   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const double currentSl = PositionGetDouble(POSITION_SL);
   const double currentTp = PositionGetDouble(POSITION_TP);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double marketPrice = (isBuy ? bid : ask);
   if(openPrice <= 0.0 || marketPrice <= 0.0)
      return;

   const double profitDistance = (isBuy ? marketPrice - openPrice : openPrice - marketPrice);
   if(profitDistance <= 0.0)
      return;

   double targetSl = currentSl;

   if(InpUseBreakeven)
   {
      const double beStart = PipsToPriceDistance(g_symbol, InpBreakevenStartPips);
      const double beLock = PipsToPriceDistance(g_symbol, InpBreakevenLockPips);
      if(beStart > 0.0 && profitDistance >= beStart)
      {
         const double beSl = NormalizePrice(g_symbol, (isBuy ? openPrice + beLock : openPrice - beLock));
         if(isBuy)
         {
            if(targetSl <= 0.0 || beSl > targetSl)
               targetSl = beSl;
         }
         else
         {
            if(targetSl <= 0.0 || beSl < targetSl)
               targetSl = beSl;
         }
      }
   }

   if(InpUseTrail)
   {
      const double trailStart = PipsToPriceDistance(g_symbol, InpTrailStartPips);
      const double trailDistance = PipsToPriceDistance(g_symbol, InpTrailDistancePips);
      if(trailStart > 0.0 && trailDistance > 0.0 && profitDistance >= trailStart)
      {
         const double trailSl = NormalizePrice(g_symbol, (isBuy ? marketPrice - trailDistance : marketPrice + trailDistance));
         if(isBuy)
         {
            if(targetSl <= 0.0 || trailSl > targetSl)
               targetSl = trailSl;
         }
         else
         {
            if(targetSl <= 0.0 || trailSl < targetSl)
               targetSl = trailSl;
         }
      }
   }

   if(targetSl <= 0.0 || targetSl == currentSl)
      return;

   if(isBuy && currentSl > 0.0 && targetSl <= currentSl)
      return;
   if(!isBuy && currentSl > 0.0 && targetSl >= currentSl)
      return;
   if(!IsStopFarEnough(isBuy, targetSl))
      return;

   if(!trade.PositionModify(ticket, targetSl, currentTp))
   {
      Print("Position modify failed | ticket=", ticket,
            " | sl=", DoubleToString(targetSl, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
            " | retcode=", trade.ResultRetcode(),
            " | desc=", trade.ResultRetcodeDescription());
   }
}

bool OpenMarket(const bool isBuy, const double atrValue, const string reason)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double entry = (isBuy ? ask : bid);
   if(entry <= 0.0)
      return false;

   double sl = 0.0;
   double tp = 0.0;
   if(!BuildStops(isBuy, entry, atrValue, sl, tp))
      return false;

   const double lot = NormalizeVolume(g_symbol, InpLots);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(DeviationPointsFromPips(g_symbol, InpMaxSpreadPips));

   const bool ok = (isBuy
      ? trade.Buy(lot, g_symbol, 0.0, sl, tp, reason)
      : trade.Sell(lot, g_symbol, 0.0, sl, tp, reason));

   if(ok)
   {
      g_lastEntryTime = TimeCurrent();
      Print("Entry opened | side=", (isBuy ? "BUY" : "SELL"),
            " | lot=", DoubleToString(lot, 2),
            " | sl=", DoubleToString(sl, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
            " | tp=", DoubleToString(tp, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
            " | atr=", DoubleToString(atrValue, 3));
   }
   else
   {
      Print("Entry failed | side=", (isBuy ? "BUY" : "SELL"),
            " | retcode=", trade.ResultRetcode(),
            " | desc=", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool BuySignal(const double support, const double fastEma, const double slowEma)
{
   if(InpTradeSide == SIDE_SELL_ONLY)
      return false;

   const double open1 = iOpen(g_symbol, PERIOD_CURRENT, 1);
   const double high1 = iHigh(g_symbol, PERIOD_CURRENT, 1);
   const double low1 = iLow(g_symbol, PERIOD_CURRENT, 1);
   const double close1 = iClose(g_symbol, PERIOD_CURRENT, 1);
   const double tolerance = PipsToPriceDistance(g_symbol, InpSnrTouchTolerancePips);
   const double minRange = PipsToPriceDistance(g_symbol, InpMinSignalRangePips);

   if(fastEma <= slowEma)
      return false;
   if(InpRequireCloseBeyondFastEma && close1 <= fastEma)
      return false;
   if(InpRequireCandleColor && close1 <= open1)
      return false;
   if(minRange > 0.0 && (high1 - low1) < minRange)
      return false;

   if(!(low1 <= support + tolerance && close1 > support))
      return false;

   return SnrValidationOK(true, support);
}

bool SellSignal(const double resistance, const double fastEma, const double slowEma)
{
   if(InpTradeSide == SIDE_BUY_ONLY)
      return false;

   const double open1 = iOpen(g_symbol, PERIOD_CURRENT, 1);
   const double high1 = iHigh(g_symbol, PERIOD_CURRENT, 1);
   const double low1 = iLow(g_symbol, PERIOD_CURRENT, 1);
   const double close1 = iClose(g_symbol, PERIOD_CURRENT, 1);
   const double tolerance = PipsToPriceDistance(g_symbol, InpSnrTouchTolerancePips);
   const double minRange = PipsToPriceDistance(g_symbol, InpMinSignalRangePips);

   if(fastEma >= slowEma)
      return false;
   if(InpRequireCloseBeyondFastEma && close1 >= fastEma)
      return false;
   if(InpRequireCandleColor && close1 >= open1)
      return false;
   if(minRange > 0.0 && (high1 - low1) < minRange)
      return false;

   if(!(high1 >= resistance - tolerance && close1 < resistance))
      return false;

   return SnrValidationOK(false, resistance);
}

void CheckEntryOnNewBar()
{
   if(!IsTradeAllowed())
      return;

   if(CountPositionsByMagic(g_symbol, InpMagic) > 0)
      return;

   if(InpMinSecondsBetweenTrades > 0 && g_lastEntryTime > 0 &&
      (TimeCurrent() - g_lastEntryTime) < InpMinSecondsBetweenTrades)
      return;

   if(!SpreadOK(g_symbol, InpMaxSpreadPips))
      return;

   double fastEma = 0.0;
   double slowEma = 0.0;
   double atrValue = 0.0;
   if(!GetBufferValue(g_fastEmaHandle, 1, fastEma)) return;
   if(!GetBufferValue(g_slowEmaHandle, 1, slowEma)) return;
   if(!GetBufferValue(g_atrHandle, 1, atrValue)) return;

   double support = 0.0;
   double resistance = 0.0;
   if(!GetSnrLevels(support, resistance))
      return;

   if(BuySignal(support, fastEma, slowEma))
   {
      OpenMarket(true, atrValue, "EMA_SNR_ATR_BUY");
      return;
   }

   if(SellSignal(resistance, fastEma, slowEma))
      OpenMarket(false, atrValue, "EMA_SNR_ATR_SELL");
}

int OnInit()
{
   g_symbol = _Symbol;

   if(InpOnlyXauusd)
   {
      string sym = g_symbol;
      StringToUpper(sym);
      if(StringFind(sym, "XAUUSD") < 0)
      {
         Print("Init fail | this EA is configured for XAUUSD symbols only");
         return INIT_FAILED;
      }
   }

   if(InpLots <= 0.0)
   {
      Print("Init fail | lot size must be > 0");
      return INIT_FAILED;
   }
   if(InpFastEmaPeriod < 1 || InpSlowEmaPeriod < 2 || InpFastEmaPeriod >= InpSlowEmaPeriod)
   {
      Print("Init fail | EMA periods must satisfy fast >= 1, slow >= 2, fast < slow");
      return INIT_FAILED;
   }
   if(InpSnrLookbackBars < 2)
   {
      Print("Init fail | SNR lookback must be >= 2");
      return INIT_FAILED;
   }
   if(InpMinSnrTouches < 0 || InpMinBarsBetweenTouches < 1 ||
      InpSnrValidationZonePips <= 0.0 || InpMinRejectWickRatio <= 0.0)
   {
      Print("Init fail | SNR validation inputs must be valid");
      return INIT_FAILED;
   }
   if(InpAtrPeriod < 1 || InpAtrStopMultiplier <= 0.0 || InpRewardRiskRatio <= 0.0)
   {
      Print("Init fail | ATR period, ATR multiplier, and RR must be valid");
      return INIT_FAILED;
   }

   g_fastEmaHandle = iMA(g_symbol, PERIOD_CURRENT, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(g_symbol, PERIOD_CURRENT, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle = iATR(g_symbol, PERIOD_CURRENT, InpAtrPeriod);

   if(g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("Init fail | cannot create indicator handles");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(DeviationPointsFromPips(g_symbol, InpMaxSpreadPips));

   Print("EA ready | symbol=", g_symbol,
         " | pipPoint=", DoubleToString(PipPoint(g_symbol), 3),
         " | rule=100 means $1 on XAU",
         " | EMA=", InpFastEmaPeriod, "/", InpSlowEmaPeriod,
         " | SNR lookback=", InpSnrLookbackBars,
         " | SNR validation=", (InpUseSnrValidation ? "on" : "off"),
         " | ATR=", InpAtrPeriod);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowEmaHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

void OnTick()
{
   ManageOpenPosition();

   if(!IsNewBar())
      return;

   CheckEntryOnNewBar();
}
