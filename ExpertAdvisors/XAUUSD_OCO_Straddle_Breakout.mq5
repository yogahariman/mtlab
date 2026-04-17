//+------------------------------------------------------------------+
//| XAUUSD_OCO_Straddle_Breakout.mq5                                 |
//| OCO breakout EA: Buy Stop above + Sell Stop below                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "General"
input long   InpMagic                     = 260417; // Magic number
input bool   InpOnlyXauusd                = true;   // Allow run only on symbols containing XAUUSD

input group "Entry (OCO Pending)"
input double InpLots                      = 0.01;   // Lot size per order
input double InpDistancePips              = 50.0;   // Distance from current price for BuyStop/SellStop
input int    InpPendingExpiryMinutes      = 0;      // Pending expiry in minutes (0=GTC)

input group "Risk"
input double InpStopLossMoney             = 1.5;    // Approx stop loss in account currency per position (0=off)
input int    InpMaxSpreadPips             = 0;      // Max spread to place/re-place pending (0=off)

input group "Trailing Profit"
input bool   InpUseProfitTrail            = true;   // Enable money-based trailing close
input double InpTrailStartMoney           = 0.6;    // Activate trail after profit reaches this value
input double InpTrailDistanceMoney        = 0.5;    // Close when profit drops from peak by this value

CTrade trade;
string g_symbol = "";
int g_prevPosCount = 0;
bool g_trailActive = false;
double g_trailPeak = 0.0;

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
}

double PriceForTargetProfit(const string symbol, const ENUM_POSITION_TYPE pType, const double openPrice, const double volume, const double targetProfitMoney)
{
   if(volume <= 0.0 || openPrice <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   // target profit in money -> price distance from open price
   const double priceDist = (targetProfitMoney * tickSize) / (tickValue * volume);
   if(pType == POSITION_TYPE_BUY)
      return openPrice + priceDist;
   return openPrice - priceDist;
}

void UpdateVisualLines()
{
   double buyEntry = 0.0;
   double sellEntry = 0.0;
   double buySl = 0.0;
   double sellSl = 0.0;
   double trailStopPrice = 0.0;

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
         const double stopProfit = g_trailPeak - InpTrailDistanceMoney;
         trailStopPrice = PriceForTargetProfit(g_symbol, pType, pOpen, PositionGetDouble(POSITION_VOLUME), stopProfit);
      }
   }

   // Green = entry lines, Red = stop-loss lines. Use dotted style for cleaner chart.
   UpsertHLine(LineName("BUY_ENTRY"), buyEntry, clrLime, STYLE_DOT);
   UpsertHLine(LineName("SELL_ENTRY"), sellEntry, clrLime, STYLE_DOT);
   UpsertHLine(LineName("BUY_SL"), buySl, clrRed, STYLE_DOT);
   UpsertHLine(LineName("SELL_SL"), sellSl, clrRed, STYLE_DOT);
   UpsertHLine(LineName("TRAIL_STOP"), trailStopPrice, clrOrange, STYLE_DOT);
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

double MoneyToPriceDistance(const string symbol, const double volume, const double money)
{
   if(money <= 0.0 || volume <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   // money ~= (price_change / tick_size) * tick_value * volume
   return (money * tickSize) / (tickValue * volume);
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

bool GetSinglePosition(const string symbol, const long magic, ulong &ticket, ENUM_POSITION_TYPE &type, double &profit)
{
   ticket = 0;
   type = POSITION_TYPE_BUY;
   profit = 0.0;

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
      profit = PositionGetDouble(POSITION_PROFIT);
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
      else
      {
      }
   }
}

bool PlaceOcoPendings()
{
   if(!IsTradeAllowed())
      return false;

   if(!SpreadOK(g_symbol, (double)InpMaxSpreadPips))
      return false;

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

   double buyPrice = ask + userDist;
   double sellPrice = bid - userDist;

   if(buyPrice < ask + minDist)
      buyPrice = ask + minDist;
   if(sellPrice > bid - minDist)
      sellPrice = bid - minDist;

   buyPrice = NormalizeDouble(buyPrice, digits);
   sellPrice = NormalizeDouble(sellPrice, digits);

   const double slDist = MoneyToPriceDistance(g_symbol, vol, InpStopLossMoney);
   double slBuy = 0.0;
   double slSell = 0.0;
   if(slDist > 0.0)
   {
      slBuy = NormalizeDouble(buyPrice - slDist, digits);
      slSell = NormalizeDouble(sellPrice + slDist, digits);
   }

   datetime expiry = 0;
   ENUM_ORDER_TYPE_TIME typeTime = ORDER_TIME_GTC;
   if(InpPendingExpiryMinutes > 0)
   {
      typeTime = ORDER_TIME_SPECIFIED;
      expiry = TimeCurrent() + (InpPendingExpiryMinutes * 60);
   }

   bool okBuy = trade.BuyStop(vol, buyPrice, g_symbol, slBuy, 0.0, typeTime, expiry, "OCO-BuyStop");
   if(!okBuy)
   {
      Print("Place BuyStop fail | retcode=", (string)trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
      return false;
   }

   bool okSell = trade.SellStop(vol, sellPrice, g_symbol, slSell, 0.0, typeTime, expiry, "OCO-SellStop");
   if(!okSell)
   {
      Print("Place SellStop fail | retcode=", (string)trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
      return false;
   }

   Print("OCO placed | BuyStop=", DoubleToString(buyPrice, digits),
         " | SellStop=", DoubleToString(sellPrice, digits),
         " | SL$=", DoubleToString(InpStopLossMoney, 2));
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
      // OCO core: when one side triggers, remove opposite pending side.
      ulong pticket;
      ENUM_POSITION_TYPE ptype;
      double pprofit;
      if(GetSinglePosition(g_symbol, InpMagic, pticket, ptype, pprofit))
      {
         if(ptype == POSITION_TYPE_BUY && sellPend > 0)
            DeletePendings(sellStops);
         if(ptype == POSITION_TYPE_SELL && buyPend > 0)
            DeletePendings(buyStops);

         if(InpUseProfitTrail)
         {
            if(!g_trailActive && pprofit >= InpTrailStartMoney)
            {
               g_trailActive = true;
               g_trailPeak = pprofit;
               Print("Trail ON | profit=", DoubleToString(pprofit, 2));
            }

            if(g_trailActive)
            {
               if(pprofit > g_trailPeak)
                  g_trailPeak = pprofit;

               const double stopProfit = g_trailPeak - InpTrailDistanceMoney;
               if(pprofit <= stopProfit)
               {
                  if(trade.PositionClose(pticket))
                  {
                     Print("Trail close | profit=", DoubleToString(pprofit, 2),
                           " | peak=", DoubleToString(g_trailPeak, 2),
                           " | stop=", DoubleToString(stopProfit, 2));
                  }
                  else
                  {
                     Print("Trail close fail | retcode=", (string)trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
      return;
   }

   // Flat state
   g_trailActive = false;
   g_trailPeak = 0.0;

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

   trade.SetExpertMagicNumber(InpMagic);
   ClearVisualLines();
   Print("EA init OK | symbol=", g_symbol,
         " | distancePips=", DoubleToString(InpDistancePips, 1),
         " | lots=", DoubleToString(InpLots, 2),
         " | SL$=", DoubleToString(InpStopLossMoney, 2),
         " | trail=", (InpUseProfitTrail ? "true" : "false"));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ClearVisualLines();
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
