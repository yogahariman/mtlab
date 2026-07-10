//+------------------------------------------------------------------+
//| XAU_StochFullCycle.mq5                                           |
//| Stochastic full cycle: entry on cross, exit on opposite level    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ETradeMode
{
   TRADE_BUY_ONLY = 0,
   TRADE_SELL_ONLY = 1,
   TRADE_BOTH = 2
};

enum EEntryMode
{
   ENTRY_CROSS_D = 0,
   ENTRY_CROSS_LEVEL = 1
};

input group "General"
input ETradeMode InpTradeMode          = TRADE_BOTH;
input long       InpMagic              = 333333;
input double     InpLots               = 0.10;
input double     InpMaxSpread          = 0.40;  // Price distance XAU
input double     InpMaxSlippage        = 0.30;  // Price distance XAU
input double     InpStopLoss           = 30.00;   // Price distance XAU

input group "Stochastic"
input EEntryMode InpEntryMode          = ENTRY_CROSS_D;
input int        InpKPeriod            = 5;
input int        InpDPeriod            = 3;
input int        InpSlowing            = 3;
input double     InpEntryBuyLevel      = 20.0;
input double     InpEntrySellLevel     = 80.0;
input double     InpExitBuyLevel       = 80.0;
input double     InpExitSellLevel      = 20.0;

CTrade trade;
string g_symbol = "";
int g_stochHandle = INVALID_HANDLE;
datetime g_lastEntryBarTime = 0;

bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   return true;
}

bool IsTesterRun()
{
   return ((bool)MQLInfoInteger(MQL_TESTER) || (bool)MQLInfoInteger(MQL_OPTIMIZATION));
}

bool IsHedgingAccount()
{
   const long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
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

ulong DeviationPointsFromPriceDistance(const string symbol, const double priceDistance)
{
   if(priceDistance <= 0.0)
      return 0;

   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0;

   const long points = (long)MathRound(priceDistance / point);
   if(points <= 0)
      return 1;
   return (ulong)points;
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   return ((ask - bid) <= InpMaxSpread);
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

bool GetStochasticValues(const int shift, double &k, double &d)
{
   k = 0.0;
   d = 0.0;

   if(!GetBufferValue(g_stochHandle, 0, shift, k))
      return false;
   if(!GetBufferValue(g_stochHandle, 1, shift, d))
      return false;

   return true;
}

int CountManagedPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      count++;
   }
   return count;
}

bool GetManagedPositionType(ENUM_POSITION_TYPE &type)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return true;
   }

   return false;
}

double GetManagedPositionProfit()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      return PositionGetDouble(POSITION_PROFIT);
   }

   return 0.0;
}

bool CloseManagedPositions()
{
   bool closedAny = false;
   const ulong closeDeviation = DeviationPointsFromPriceDistance(g_symbol, InpMaxSlippage);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const bool ok = (closeDeviation > 0
         ? trade.PositionClose(ticket, closeDeviation)
         : trade.PositionClose(ticket));
      if(!ok)
      {
         Print("Close failed | ticket=", (string)ticket,
               " | retcode=", (string)trade.ResultRetcode(),
               " | desc=", trade.ResultRetcodeDescription());
      }
      else
      {
         closedAny = true;
      }
   }

   return closedAny;
}

double ManagedPositionProfit()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      return PositionGetDouble(POSITION_PROFIT);
   }

   return 0.0;
}

bool OpenMarket(const bool isBuy)
{
   if(!IsTradeAllowed() || !SpreadOK())
      return false;

   if(InpLots <= 0.0)
      return false;

   if(CountManagedPositions() > 0)
      return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(DeviationPointsFromPriceDistance(g_symbol, InpMaxSlippage));

   double sl = 0.0;
   if(InpStopLoss > 0.0)
   {
      const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
      const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      if(isBuy && ask > 0.0)
         sl = NormalizeDouble(ask - InpStopLoss, digits);
      else if(!isBuy && bid > 0.0)
         sl = NormalizeDouble(bid + InpStopLoss, digits);
   }

   const double volume = NormalizeVolume(g_symbol, InpLots);
   const bool ok = (isBuy
      ? trade.Buy(volume, g_symbol, 0.0, sl, 0.0, "XAU_StochFullCycleBuy")
      : trade.Sell(volume, g_symbol, 0.0, sl, 0.0, "XAU_StochFullCycleSell"));

   if(!ok)
   {
      Print("Order failed | side=", (isBuy ? "BUY" : "SELL"),
            " | lot=", DoubleToString(volume, 2),
            " | retcode=", trade.ResultRetcode(),
            " | desc=", trade.ResultRetcodeDescription());
      return false;
   }

   Print("Order opened | side=", (isBuy ? "BUY" : "SELL"),
         " | lot=", DoubleToString(volume, 2));
   g_lastEntryBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   return true;
}

bool BuyEntrySignal()
{
   if(InpTradeMode == TRADE_SELL_ONLY)
      return false;

   double k0 = 0.0, k1 = 0.0, d0 = 0.0, d1 = 0.0;
   if(!GetStochasticValues(0, k0, d0))
      return false;
   if(!GetStochasticValues(1, k1, d1))
      return false;

   if(InpEntryMode == ENTRY_CROSS_D)
   {
      if(k1 > InpEntryBuyLevel)
         return false;
      return (k1 <= d1 && k0 > d0);
   }

   return (k1 <= InpEntryBuyLevel && k0 > InpEntryBuyLevel);
}

bool SellEntrySignal()
{
   if(InpTradeMode == TRADE_BUY_ONLY)
      return false;

   double k0 = 0.0, k1 = 0.0, d0 = 0.0, d1 = 0.0;
   if(!GetStochasticValues(0, k0, d0))
      return false;
   if(!GetStochasticValues(1, k1, d1))
      return false;

   if(InpEntryMode == ENTRY_CROSS_D)
   {
      if(k1 < InpEntrySellLevel)
         return false;
      return (k1 >= d1 && k0 < d0);
   }

   return (k1 >= InpEntrySellLevel && k0 < InpEntrySellLevel);
}

bool BuyExitSignal()
{
   double k0 = 0.0, k1 = 0.0, d0 = 0.0, d1 = 0.0;
   if(!GetStochasticValues(0, k0, d0))
      return false;
   if(!GetStochasticValues(1, k1, d1))
      return false;

   return (k1 < InpExitBuyLevel && k0 >= InpExitBuyLevel);
}

bool SellExitSignal()
{
   double k0 = 0.0, k1 = 0.0, d0 = 0.0, d1 = 0.0;
   if(!GetStochasticValues(0, k0, d0))
      return false;
   if(!GetStochasticValues(1, k1, d1))
      return false;

   return (k1 > InpExitSellLevel && k0 <= InpExitSellLevel);
}

void ManageExit()
{
   ENUM_POSITION_TYPE posType;
   if(!GetManagedPositionType(posType))
      return;

   if(posType == POSITION_TYPE_BUY && BuyExitSignal() && ManagedPositionProfit() > 0.0)
   {
      if(CloseManagedPositions())
      {
         g_lastEntryBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
         Print("Exit buy cycle on stochastic upper level");
      }
      return;
   }

   if(posType == POSITION_TYPE_SELL && SellExitSignal() && ManagedPositionProfit() > 0.0)
   {
      if(CloseManagedPositions())
      {
         g_lastEntryBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
         Print("Exit sell cycle on stochastic lower level");
      }
      return;
   }
}

void ManageEntry()
{
   if(!IsTradeAllowed())
      return;
   if(!SpreadOK())
      return;
   if(CountManagedPositions() > 0)
      return;

   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime <= 0)
      return;
   if(barTime == g_lastEntryBarTime)
      return;

   if(BuyEntrySignal())
   {
      OpenMarket(true);
      return;
   }

   if(SellEntrySignal())
   {
      OpenMarket(false);
      return;
   }
}

int OnInit()
{
   g_symbol = _Symbol;
   if(!SymbolSelect(g_symbol, true))
   {
      Print("Failed to select symbol: ", g_symbol);
      return INIT_FAILED;
   }

   if(!IsHedgingAccount())
   {
      Print("XAU_StochFullCycle requires an MT5 hedging account.");
      return INIT_FAILED;
   }

   if(InpKPeriod <= 0 || InpDPeriod <= 0 || InpSlowing <= 0)
   {
      Print("Invalid stochastic periods.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLots <= 0.0)
   {
      Print("Invalid lot size.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_stochHandle = iStochastic(g_symbol, PERIOD_CURRENT, InpKPeriod, InpDPeriod, InpSlowing, MODE_SMA, STO_LOWHIGH);
   if(g_stochHandle == INVALID_HANDLE)
   {
      Print("Failed to create stochastic handle.");
      return INIT_FAILED;
   }

   Print("XAU_StochFullCycle initialized | symbol=", g_symbol,
         " | mode=", (InpEntryMode == ENTRY_CROSS_D ? "CROSS_D" : "CROSS_LEVEL"),
         " | entryBuyLevel=", DoubleToString(InpEntryBuyLevel, 2),
         " | entrySellLevel=", DoubleToString(InpEntrySellLevel, 2),
         " | exitBuyLevel=", DoubleToString(InpExitBuyLevel, 2),
         " | exitSellLevel=", DoubleToString(InpExitSellLevel, 2),
         " | stopLoss=", DoubleToString(InpStopLoss, 2),
         " | lots=", DoubleToString(InpLots, 2));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_stochHandle != INVALID_HANDLE)
      IndicatorRelease(g_stochHandle);
}

void OnTick()
{
   if(_Symbol != g_symbol)
      return;
   if(!IsTradeAllowed())
      return;

   ManageExit();
   ManageEntry();
}
