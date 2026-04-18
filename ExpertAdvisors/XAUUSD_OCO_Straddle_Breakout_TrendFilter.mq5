//+------------------------------------------------------------------+
//| XAUUSD_OCO_Straddle_Breakout_TrendFilter.mq5                     |
//| OCO breakout EA with Trend Filter (reduces false breakouts)      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

input group "General"
input long   InpMagic                     = 260417; // Magic number
input bool   InpOnlyXauusd                = true;   // Allow run only on symbols containing XAUUSD

input group "Entry (OCO Pending)"
input double InpLots                      = 0.01;   // Lot size per order
input double InpDistancePips              = 60.0;   // Distance from current price for BuyStop/SellStop
input int    InpPendingExpiryMinutes      = 30;     // Pending expiry in minutes (0=GTC)
input int    InpCooldownSecondsAfterClose = 0;     // Cooldown before re-place pending after a close deal

input group "Risk"
input double InpStopLossPips              = 300.0;  // Stop loss distance in pips per position (0=off)
input double InpTakeProfitPips            = 60.0;  // Take profit distance in pips per position (0=off)
input int    InpMaxSpreadPips             = 35;     // Max spread to place/re-place pending (0=off)

input group "Trailing (Pips)"
input bool   InpUseTrail                  = true;    // Enable pips-based trailing close
input double InpTrailStartPips            = 60;   // Activate trail after favorable move reaches this pips
input double InpTrailDistancePips         = 30;   // Close when favorable move drops from peak by this pips

input group "Trend Filter (NEW!)"
input bool   InpUseTrendFilter            = true;   // Enable trend filter to reduce false breakouts
input int    InpTrendFilterMaPeriod       = 20;     // EMA period for trend detection
input double InpTrendFilterMinDistance    = 0.5;    // Minimum distance between current price and EMA (in pips)
input int    InpTrendFilterMode           = 2;      // Filter mode: 1=AllowEither, 2=StrictBoth, 3=BuyOnly, 4=SellOnly, 0=Disabled

CTrade trade;
string g_symbol = "";
int g_prevPosCount = 0;
bool g_trailActive = false;
double g_trailPeakPips = 0.0;
datetime g_lastExitTime = 0;
int g_trendFilterMaHandle = INVALID_HANDLE;

string LineName(const string suffix)
{
   return "OCO_" + g_symbol + "_" + (string)InpMagic + "_" + suffix;
}

void UpsertHLine(const string name, const double price, const color clr, const ENUM_LINE_STYLE style)
{
   if(price <= 0.0)
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
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void ClearVisualLines()
{
   ObjectDelete(0, LineName("BUY_ENTRY"));
   ObjectDelete(0, LineName("SELL_ENTRY"));
   ObjectDelete(0, LineName("BUY_SL"));
   ObjectDelete(0, LineName("SELL_SL"));
   ObjectDelete(0, LineName("TRAIL_STOP"));
   ObjectDelete(0, LineName("TREND_EMA"));
}

void UpdateVisualLines()
{
   const double pip = PipPoint(g_symbol);
   double buyEntry = 0.0;
   double sellEntry = 0.0;
   double buySl = 0.0;
   double sellSl = 0.0;
   double trailStopPrice = 0.0;
   double trendEmaPrice = 0.0;

   const int oTotal = OrdersTotal();
   for(int i = 0; i < oTotal; i++)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)
      {
         buyEntry = OrderGetDouble(ORDER_PRICE_OPEN);
         buySl = OrderGetDouble(ORDER_SL);
      }
      else if(type == ORDER_TYPE_SELL_STOP)
      {
         sellEntry = OrderGetDouble(ORDER_PRICE_OPEN);
         sellSl = OrderGetDouble(ORDER_SL);
      }
   }

   const int pTotal = PositionsTotal();
   for(int i = 0; i < pTotal; i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double pOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      const double pSl = PositionGetDouble(POSITION_SL);

      if(pType == POSITION_TYPE_BUY)
      {
         buyEntry = pOpen;
         if(pSl > 0.0) buySl = pSl;
      }
      else if(pType == POSITION_TYPE_SELL)
      {
         sellEntry = pOpen;
         if(pSl > 0.0) sellSl = pSl;
      }

      if(g_trailActive)
      {
         const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
         const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
         if(pType == POSITION_TYPE_BUY && bid > 0.0)
            trailStopPrice = NormalizeDouble(bid - (InpTrailDistancePips * pip), (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
         else if(pType == POSITION_TYPE_SELL && ask > 0.0)
            trailStopPrice = NormalizeDouble(ask + (InpTrailDistancePips * pip), (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
      }
   }

   // Draw trend EMA line
   if(InpUseTrendFilter && g_trendFilterMaHandle != INVALID_HANDLE)
   {
      double emaBuf[];
      ArrayResize(emaBuf, 1);
      ArraySetAsSeries(emaBuf, true);
      if(CopyBuffer(g_trendFilterMaHandle, 0, 0, 1, emaBuf) == 1)
         trendEmaPrice = emaBuf[0];
   }

   // Green = entry lines, Red = stop-loss lines. Yellow = EMA trend line
   UpsertHLine(LineName("BUY_ENTRY"), buyEntry, clrLime, STYLE_DOT);
   UpsertHLine(LineName("SELL_ENTRY"), sellEntry, clrLime, STYLE_DOT);
   UpsertHLine(LineName("BUY_SL"), buySl, clrRed, STYLE_DOT);
   UpsertHLine(LineName("SELL_SL"), sellSl, clrRed, STYLE_DOT);
   UpsertHLine(LineName("TRAIL_STOP"), trailStopPrice, clrOrange, STYLE_DOT);
   UpsertHLine(LineName("TREND_EMA"), trendEmaPrice, clrGoldenrod, STYLE_SOLID);
}

bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   return true;
}

double PipPoint(const string symbol)
{
   string s = symbol;
   StringToUpper(s);
   if(StringFind(s, "XAUUSD") >= 0)
      return 0.01;

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

double NormalizeVolume(const string symbol, const double lot)
{
   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double vol = lot;
   if(vol < vmin) vol = vmin;
   if(vol > vmax) vol = vmax;
   if(vstep > 0.0)
      vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin) vol = vmin;
   return vol;
}

bool SpreadOK(const string symbol, const double maxSpreadPips)
{
   if(maxSpreadPips <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double pip = PipPoint(symbol);
   if(pip <= 0.0)
      return true;

   const double spreadPips = (ask - bid) / pip;
   return (spreadPips <= maxSpreadPips);
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

double EffectiveTakeProfitPips()
{
   if(InpUseTrail)
      return 0.0;
   return InpTakeProfitPips;
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

void ApplyTrailingStopFromMarket(const ulong ticket,
                                 const string symbol,
                                 const ENUM_POSITION_TYPE pType,
                                 const double marketRefPrice,
                                 const double trailDistancePips)
{
   if(ticket == 0 || marketRefPrice <= 0.0 || trailDistancePips <= 0.0)
      return;
   if(!PositionSelectByTicket(ticket))
      return;

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double pip = PipPoint(symbol);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits <= 0 || pip <= 0.0 || point <= 0.0)
      return;

   const double currentSl = PositionGetDouble(POSITION_SL);
   const double currentTp = PositionGetDouble(POSITION_TP);

   double targetSl = 0.0;
   if(pType == POSITION_TYPE_BUY)
      targetSl = marketRefPrice - (trailDistancePips * pip);
   else if(pType == POSITION_TYPE_SELL)
      targetSl = marketRefPrice + (trailDistancePips * pip);
   else
      return;

   targetSl = ClampSlToMinDistance(symbol, pType, targetSl);

   // Tighten only.
   if(currentSl > 0.0)
   {
      if(pType == POSITION_TYPE_BUY && targetSl <= currentSl + (point * 0.5))
         return;
      if(pType == POSITION_TYPE_SELL && targetSl >= currentSl - (point * 0.5))
         return;
   }

   if(!trade.PositionModify(ticket, targetSl, currentTp))
   {
      Print("Trail SL modify fail | ticket=", (string)ticket,
            " | retcode=", (string)trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("Trail SL move | ticket=", (string)ticket,
            " | distancePips=", DoubleToString(trailDistancePips, 1),
            " | newSL=", DoubleToString(targetSl, digits));
   }
}

void SyncPositionStopsByPips(const string symbol, const long magic)
{
   const double tpPips = EffectiveTakeProfitPips();
   if(InpStopLossPips <= 0.0 && tpPips <= 0.0)
      return;

   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits <= 0 || point <= 0.0)
      return;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      const ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSl = PositionGetDouble(POSITION_SL);
      const double currentTp = PositionGetDouble(POSITION_TP);
      if(openPrice <= 0.0)
         continue;

      double targetSl = currentSl;
      if(InpStopLossPips > 0.0)
      {
         const double slDist = PipsToPriceDistance(symbol, InpStopLossPips);
         if(slDist <= 0.0)
            continue;
         if(pType == POSITION_TYPE_BUY)
            targetSl = openPrice - slDist;
         else if(pType == POSITION_TYPE_SELL)
            targetSl = openPrice + slDist;
         else
            continue;
         targetSl = ClampSlToMinDistance(symbol, pType, targetSl);

         // Never loosen SL after it is already set:
         // - BUY: lower SL means bigger loss -> forbidden
         // - SELL: higher SL means bigger loss -> forbidden
         if(currentSl > 0.0)
         {
            if(pType == POSITION_TYPE_BUY && targetSl < currentSl)
               targetSl = currentSl;
            else if(pType == POSITION_TYPE_SELL && targetSl > currentSl)
               targetSl = currentSl;
         }
      }

      double targetTp = currentTp;
      if(tpPips > 0.0)
      {
         const double tpDist = PipsToPriceDistance(symbol, tpPips);
         if(tpDist <= 0.0)
            continue;
         if(pType == POSITION_TYPE_BUY)
            targetTp = openPrice + tpDist;
         else if(pType == POSITION_TYPE_SELL)
            targetTp = openPrice - tpDist;
         else
            continue;
         targetTp = ClampTpToMinDistance(symbol, pType, targetTp);
      }
      else
      {
         targetTp = 0.0;
      }

      if(MathAbs(targetSl - currentSl) < (point * 0.5) &&
         MathAbs(targetTp - currentTp) < (point * 0.5))
         continue;

      if(!trade.PositionModify(ticket, targetSl, targetTp))
      {
         Print("Sync stops fail | ticket=", (string)ticket,
               " | retcode=", (string)trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      }
   }
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

void ResolveDualFillCollision(const string symbol, const long magic)
{
   ulong tickets[];
   ENUM_POSITION_TYPE types[];
   long times[];
   int count = 0;
   bool hasBuy = false;
   bool hasSell = false;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      const ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pType == POSITION_TYPE_BUY) hasBuy = true;
      if(pType == POSITION_TYPE_SELL) hasSell = true;

      ArrayResize(tickets, count + 1);
      ArrayResize(types, count + 1);
      ArrayResize(times, count + 1);
      tickets[count] = t;
      types[count] = pType;
      times[count] = (long)PositionGetInteger(POSITION_TIME_MSC);
      count++;
   }

   // Only enforce when both directions are open at the same time.
   if(count <= 1 || !hasBuy || !hasSell)
      return;

   // Keep earliest filled position and close the rest to restore single-side OCO.
   int keepIdx = 0;
   for(int i = 1; i < count; i++)
   {
      if(times[i] < times[keepIdx])
         keepIdx = i;
   }

   for(int i = 0; i < count; i++)
   {
      if(i == keepIdx)
         continue;

      if(!trade.PositionClose(tickets[i]))
      {
         Print("Dual-fill resolve fail | close_ticket=", (string)tickets[i],
               " | keep_ticket=", (string)tickets[keepIdx],
               " | retcode=", (string)trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      }
      else
      {
         Print("Dual-fill resolved | close_ticket=", (string)tickets[i],
               " | keep_ticket=", (string)tickets[keepIdx]);
      }
   }
}

bool GetSinglePosition(const string symbol, const long magic, ulong &ticket, ENUM_POSITION_TYPE &type)
{
   ticket = 0;
   type = POSITION_TYPE_BUY;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      ticket = t;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

int CollectPendingTickets(const string symbol, const long magic, const ENUM_ORDER_TYPE typeFilter, ulong &tickets[])
{
   ArrayResize(tickets, 0);
   int count = 0;

   const int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != typeFilter) continue;

      ArrayResize(tickets, count + 1);
      tickets[count] = t;
      count++;
   }

   return count;
}

void DeletePendings(const ulong &tickets[])
{
   const int n = ArraySize(tickets);
   for(int i = 0; i < n; i++)
   {
      if(!trade.OrderDelete(tickets[i]))
      {
         Print("Delete pending fail | ticket=", (string)tickets[i],
               " | retcode=", (string)trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      }
   }
}

// NEW: Trend filter check with multiple modes
// Mode 0: Disabled (always OK)
// Mode 1: AllowEither (buy OR sell, not AND)
// Mode 2: StrictBoth (buy AND sell both conditions checked)
// Mode 3: BuyOnly (only check buy condition)
// Mode 4: SellOnly (only check sell condition)
bool IsTrendFilterOK(const string symbol)
{
   if(!InpUseTrendFilter || InpTrendFilterMode == 0)
      return true;

   if(g_trendFilterMaHandle == INVALID_HANDLE)
   {
      Print("Trend filter WARN | MA handle invalid");
      return true; // Fallback: allow entry if indicator fails
   }

   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double pip = PipPoint(symbol);
   if(bid <= 0.0 || ask <= 0.0 || pip <= 0.0)
      return false;

   double emaBuf[];
   ArrayResize(emaBuf, 1);
   ArraySetAsSeries(emaBuf, true);
   if(CopyBuffer(g_trendFilterMaHandle, 0, 0, 1, emaBuf) != 1)
   {
      Print("Trend filter WARN | CopyBuffer fail");
      return true; // Fallback: allow entry if buffer copy fails
   }

   const double emaPrice = emaBuf[0];
   const double minDistPrice = InpTrendFilterMinDistance * pip;
   
   bool buyOK = (bid > emaPrice + minDistPrice);
   bool sellOK = (ask < emaPrice - minDistPrice);

   bool result = false;
   
   if(InpTrendFilterMode == 1)
   {
      // Mode 1: Allow if EITHER buy OR sell is OK
      result = (buyOK || sellOK);
      Print("Trend filter | mode=AllowEither | buyOK=", (buyOK?"yes":"no"),
            " | sellOK=", (sellOK?"yes":"no"), " | result=", (result?"ALLOW":"REJECT"));
   }
   else if(InpTrendFilterMode == 2)
   {
      // Mode 2: Strict - both must be OK
      result = (buyOK && sellOK);
      Print("Trend filter | mode=StrictBoth | buyOK=", (buyOK?"yes":"no"),
            " | sellOK=", (sellOK?"yes":"no"), " | result=", (result?"ALLOW":"REJECT"));
   }
   else if(InpTrendFilterMode == 3)
   {
      // Mode 3: Buy only
      result = buyOK;
      Print("Trend filter | mode=BuyOnly | buyOK=", (buyOK?"yes":"no"), " | result=", (result?"ALLOW":"REJECT"));
   }
   else if(InpTrendFilterMode == 4)
   {
      // Mode 4: Sell only
      result = sellOK;
      Print("Trend filter | mode=SellOnly | sellOK=", (sellOK?"yes":"no"), " | result=", (result?"ALLOW":"REJECT"));
   }

   if(result)
   {
      Print("Trend filter OK | bid=", DoubleToString(bid, 2),
            " | ask=", DoubleToString(ask, 2),
            " | ema=", DoubleToString(emaPrice, 2),
            " | minDist=", DoubleToString(minDistPrice, 4));
   }
   
   return result;
}

bool PlaceOcoPendings()
{
   if(!IsTradeAllowed())
      return false;

   if(!SpreadOK(g_symbol, (double)InpMaxSpreadPips))
      return false;

   // NEW: Trend filter check
   if(!IsTrendFilterOK(g_symbol))
   {
      Print("OCO placement skipped | trend_filter_reject");
      return false;
   }

   const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double pip = PipPoint(g_symbol);
   if(point <= 0.0 || pip <= 0.0 || ask <= 0.0 || bid <= 0.0)
      return false;

   const double vol = NormalizeVolume(g_symbol, InpLots);
   const double userDist = InpDistancePips * pip;

   const int stopsLevelPoints = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = stopsLevelPoints * point;

   // breakout mode: above=buy stop, below=sell stop
   double buyPrice = ask + userDist;
   double sellPrice = bid - userDist;

   if(buyPrice < ask + minDist)
      buyPrice = ask + minDist;
   if(sellPrice > bid - minDist)
      sellPrice = bid - minDist;

   buyPrice = NormalizeDouble(buyPrice, digits);
   sellPrice = NormalizeDouble(sellPrice, digits);

   double slBuy = 0.0;
   double slSell = 0.0;
   double tpBuy = 0.0;
   double tpSell = 0.0;
   const double slDist = PipsToPriceDistance(g_symbol, InpStopLossPips);
   const double tpDist = PipsToPriceDistance(g_symbol, EffectiveTakeProfitPips());
   if(slDist > 0.0)
   {
      slBuy = NormalizeDouble(buyPrice - slDist, digits);
      slSell = NormalizeDouble(sellPrice + slDist, digits);
   }
   if(tpDist > 0.0)
   {
      tpBuy = NormalizeDouble(buyPrice + tpDist, digits);
      tpSell = NormalizeDouble(sellPrice - tpDist, digits);
   }

   datetime expiry = 0;
   ENUM_ORDER_TYPE_TIME typeTime = ORDER_TIME_GTC;
   if(InpPendingExpiryMinutes > 0)
   {
      typeTime = ORDER_TIME_SPECIFIED;
      expiry = TimeCurrent() + (InpPendingExpiryMinutes * 60);
   }

   bool okBuy = trade.BuyStop(vol, buyPrice, g_symbol, slBuy, tpBuy, typeTime, expiry, "OCO-BuyStop");
   if(!okBuy)
   {
      Print("Place buy pending fail | retcode=", (string)trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
      return false;
   }
   const ulong buyTicket = trade.ResultOrder();

   bool okSell = trade.SellStop(vol, sellPrice, g_symbol, slSell, tpSell, typeTime, expiry, "OCO-SellStop");
   if(!okSell)
   {
      Print("Place sell pending fail | retcode=", (string)trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());

      // Roll back already-created BUY_STOP so OCO pair remains balanced.
      if(buyTicket > 0)
      {
         if(!trade.OrderDelete(buyTicket))
         {
            Print("Rollback buy pending fail | ticket=", (string)buyTicket,
                  " | retcode=", (string)trade.ResultRetcode(),
                  " | ", trade.ResultRetcodeDescription());
         }
         else
         {
            Print("Rollback buy pending OK | ticket=", (string)buyTicket);
         }
      }

      return false;
   }

   Print("OCO placed | BuyPending=", DoubleToString(buyPrice, digits),
         " | SellPending=", DoubleToString(sellPrice, digits),
         " | SLPips=", DoubleToString(InpStopLossPips, 1),
         " | TPPips=", DoubleToString(EffectiveTakeProfitPips(), 1),
         " | TrendFilter=", (InpUseTrendFilter ? "ON" : "OFF"));
   return true;
}

void ManageOcoAndTrailing(const int posCount)
{
   ulong buyStops[];
   ulong sellStops[];
   const int buyPend = CollectPendingTickets(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, buyStops);
   const int sellPend = CollectPendingTickets(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, sellStops);

   if(posCount > 0)
   {
      ResolveDualFillCollision(g_symbol, InpMagic);
      SyncPositionStopsByPips(g_symbol, InpMagic);

      // OCO core: when one side triggers, remove opposite pending side.
      ulong pticket;
      ENUM_POSITION_TYPE ptype;
      if(GetSinglePosition(g_symbol, InpMagic, pticket, ptype))
      {
         if(ptype == POSITION_TYPE_BUY && sellPend > 0)
            DeletePendings(sellStops);
         if(ptype == POSITION_TYPE_SELL && buyPend > 0)
            DeletePendings(buyStops);

         if(InpUseTrail)
         {
            if(PositionSelectByTicket(pticket))
            {
               const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
               const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
               const double pip = PipPoint(g_symbol);
               if(openPrice > 0.0 && bid > 0.0 && ask > 0.0 && pip > 0.0)
               {
                  double favorablePips = 0.0;
                  if(ptype == POSITION_TYPE_BUY)
                     favorablePips = (bid - openPrice) / pip;
                  else if(ptype == POSITION_TYPE_SELL)
                     favorablePips = (openPrice - ask) / pip;

                  if(!g_trailActive && favorablePips >= InpTrailStartPips)
                  {
                     g_trailActive = true;
                     g_trailPeakPips = favorablePips;
                     Print("Trail ON | favorablePips=", DoubleToString(favorablePips, 1));
                  }

                  if(g_trailActive)
                  {
                     if(favorablePips > g_trailPeakPips)
                        g_trailPeakPips = favorablePips;
                     const double marketRefPrice = (ptype == POSITION_TYPE_BUY ? bid : ask);
                     ApplyTrailingStopFromMarket(pticket, g_symbol, ptype, marketRefPrice, InpTrailDistancePips);
                  }
               }
            }
         }
      }
      return;
   }

   // Flat state
   g_trailActive = false;
   g_trailPeakPips = 0.0;

   if(InpCooldownSecondsAfterClose > 0 && g_lastExitTime > 0)
   {
      const int elapsed = (int)(TimeCurrent() - g_lastExitTime);
      if(elapsed < InpCooldownSecondsAfterClose)
         return;
   }

   // Clean inconsistent pending state then place fresh pair.
   if(buyPend != 1 || sellPend != 1)
   {
      if(buyPend > 0) DeletePendings(buyStops);
      if(sellPend > 0) DeletePendings(sellStops);
      PlaceOcoPendings();
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
      string s = g_symbol;
      StringToUpper(s);
      if(StringFind(s, "XAUUSD") < 0)
      {
         Print("Init fail | symbol must contain XAUUSD");
         return INIT_FAILED;
      }
   }

   if(InpDistancePips <= 0.0)
   {
      Print("Init fail | InpDistancePips must be > 0");
      return INIT_FAILED;
   }

   // NEW: Create trend filter MA handle
   if(InpUseTrendFilter)
   {
      if(InpTrendFilterMaPeriod <= 0)
      {
         Print("Init fail | trend filter MA period must be > 0");
         return INIT_FAILED;
      }
      g_trendFilterMaHandle = iMA(g_symbol, PERIOD_CURRENT, InpTrendFilterMaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_trendFilterMaHandle == INVALID_HANDLE)
      {
         Print("Init fail | cannot create trend filter MA handle");
         return INIT_FAILED;
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   ClearVisualLines();
   
   Print("EA init OK | symbol=", g_symbol,
         " | distancePips=", DoubleToString(InpDistancePips, 1),
         " | lots=", DoubleToString(InpLots, 2),
         " | SLPips=", DoubleToString(InpStopLossPips, 1),
         " | TPPips=", DoubleToString(EffectiveTakeProfitPips(), 1),
         " | trail=", (InpUseTrail ? "true" : "false"));
   
   if(InpUseTrendFilter)
   {
      string modeStr = "Unknown";
      if(InpTrendFilterMode == 0) modeStr = "Disabled";
      else if(InpTrendFilterMode == 1) modeStr = "AllowEither (buy OR sell)";
      else if(InpTrendFilterMode == 2) modeStr = "StrictBoth (buy AND sell)";
      else if(InpTrendFilterMode == 3) modeStr = "BuyOnly";
      else if(InpTrendFilterMode == 4) modeStr = "SellOnly";
      
      Print("Trend filter | enabled=true | mode=", modeStr,
            " | MaPeriod=", (string)InpTrendFilterMaPeriod,
            " | MinDistance=", DoubleToString(InpTrendFilterMinDistance, 1), " pips");
   }
   else
   {
      Print("Trend filter | enabled=false");
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ClearVisualLines();
   
   if(g_trendFilterMaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_trendFilterMaHandle);
      g_trendFilterMaHandle = INVALID_HANDLE;
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   const string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   const long dealMagic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   const ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(dealSymbol != g_symbol)
      return;
   if(dealMagic != InpMagic)
      return;
   if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
   {
      const double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      const double dealCommission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      const double dealSwap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
      const double dealFee = HistoryDealGetDouble(trans.deal, DEAL_FEE);
      const double dealNet = dealProfit + dealCommission + dealSwap + dealFee;
      const ENUM_DEAL_REASON dealReason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
      Print("Deal OUT | deal=", (string)trans.deal,
            " | reason=", (string)dealReason,
            " | gross=", DoubleToString(dealProfit, 2),
            " | comm=", DoubleToString(dealCommission, 2),
            " | swap=", DoubleToString(dealSwap, 2),
            " | fee=", DoubleToString(dealFee, 2),
            " | net=", DoubleToString(dealNet, 2));
      g_lastExitTime = TimeCurrent();
      return;
   }

   if(dealEntry != DEAL_ENTRY_IN)
      return;

   // Cancel opposite pending immediately on fill (faster than waiting next tick).
   const ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   ulong opposite[];
   if(dealType == DEAL_TYPE_BUY)
   {
      if(CollectPendingTickets(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, opposite) > 0)
         DeletePendings(opposite);
   }
   else if(dealType == DEAL_TYPE_SELL)
   {
      if(CollectPendingTickets(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, opposite) > 0)
         DeletePendings(opposite);
   }

   // Immediately re-sync SL/TP from actual fill price of new position.
   ResolveDualFillCollision(g_symbol, InpMagic);
   SyncPositionStopsByPips(g_symbol, InpMagic);
}

void OnTick()
{
   if(_Symbol != g_symbol)
      return;

   const int posCount = CountPositionsByMagic(g_symbol, InpMagic);
   g_prevPosCount = posCount;
   UpdateVisualLines();

   if(!IsTradeAllowed())
      return;

   ManageOcoAndTrailing(posCount);
   UpdateVisualLines();
}
