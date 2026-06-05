//+------------------------------------------------------------------+
//| XAU_BrokerProbe.mq5                                              |
//| Broker and symbol diagnostics for XAU/GOLD instruments          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

input group "Probe"
input bool   InpRunOnInitOnly          = true;
input bool   InpUseTimer               = false;
input int    InpTimerSeconds           = 60;
input string InpLotsToProbe            = "0.01;0.10;1.00";
input string InpMovesToProbe           = "0.10;1.00;8.00;10.00";
input bool   InpPrintToExpertsLog      = true;

string g_symbol = "";

bool IsLikelyGoldSymbol(const string symbol)
{
   string sym = symbol;
   StringToUpper(sym);
   return (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
}

bool ParseDoubleList(const string text, double &values[])
{
   ArrayResize(values, 0);

   string src = text;
   StringTrimLeft(src);
   StringTrimRight(src);
   if(StringLen(src) <= 0)
      return false;

   string parts[];
   const int count = StringSplit(src, ';', parts);
   if(count <= 0)
      return false;

   for(int i = 0; i < count; i++)
   {
      string cell = parts[i];
      StringTrimLeft(cell);
      StringTrimRight(cell);
      if(StringLen(cell) <= 0)
         return false;

      const double v = StringToDouble(cell);
      if(v <= 0.0)
         return false;

      const int n = ArraySize(values) + 1;
      ArrayResize(values, n);
      values[n - 1] = v;
   }

   return (ArraySize(values) > 0);
}

void LogLine(const string text)
{
   if(InpPrintToExpertsLog)
      Print(text);
}

void PrintSymbolBasics()
{
   const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double spread = (ask > 0.0 && bid > 0.0 ? (ask - bid) : 0.0);

   LogLine("=== XAU Broker Probe ===");
   LogLine("Symbol: " + g_symbol);
   LogLine("Likely Gold: " + (IsLikelyGoldSymbol(g_symbol) ? "yes" : "no"));
   LogLine("Digits: " + (string)digits);
   LogLine("Point: " + DoubleToString(point, digits > 0 ? digits : 6));
   LogLine("Bid: " + DoubleToString(bid, digits));
   LogLine("Ask: " + DoubleToString(ask, digits));
   LogLine("Spread: " + DoubleToString(spread, digits));
   LogLine("Spread points: " + (string)(point > 0.0 ? (long)MathRound(spread / point) : 0));
   LogLine("Tick size: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE), digits > 0 ? digits : 6));
   LogLine("Tick value: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE), 4));
   LogLine("Contract size: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE), 4));
   LogLine("Volume min: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN), 4));
   LogLine("Volume step: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP), 4));
   LogLine("Volume max: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX), 4));
   LogLine("Swap long: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_SWAP_LONG), 4));
   LogLine("Swap short: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_SWAP_SHORT), 4));
   LogLine("Margin initial: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_MARGIN_INITIAL), 4));
   LogLine("Margin hedged: " + DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_MARGIN_HEDGED), 4));
}

void PrintProfitProbe()
{
   double lots[];
   if(!ParseDoubleList(InpLotsToProbe, lots))
   {
      LogLine("Lot probe skipped: invalid InpLotsToProbe");
      return;
   }

   double moves[];
   if(!ParseDoubleList(InpMovesToProbe, moves))
   {
      LogLine("Move probe skipped: invalid InpMovesToProbe");
      return;
   }

   const int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double baseBuy = (bid > 0.0 ? bid : ask);
   const double baseSell = (ask > 0.0 ? ask : bid);
   double oneLotProfit = 0.0;

   LogLine("=== Profit Probe ===");
   for(int i = 0; i < ArraySize(lots); i++)
   {
      const double lot = lots[i];
      for(int j = 0; j < ArraySize(moves); j++)
      {
         const double move = moves[j];
         double buyProfit = 0.0;
         double sellProfit = 0.0;

         if(baseBuy > 0.0 && OrderCalcProfit(ORDER_TYPE_BUY, g_symbol, lot, baseBuy, baseBuy + move, buyProfit))
         {
            LogLine("BUY lot " + DoubleToString(lot, 2) +
                    " move +" + DoubleToString(move, 2) +
                    " => profit " + DoubleToString(buyProfit, 2));
         }

         if(baseSell > 0.0 && OrderCalcProfit(ORDER_TYPE_SELL, g_symbol, lot, baseSell, baseSell - move, sellProfit))
         {
            LogLine("SELL lot " + DoubleToString(lot, 2) +
                    " move +" + DoubleToString(move, 2) +
                    " => profit " + DoubleToString(sellProfit, 2));
         }
      }
   }

   if(baseBuy > 0.0 && OrderCalcProfit(ORDER_TYPE_BUY, g_symbol, 1.0, baseBuy, baseBuy + 1.0, oneLotProfit))
   {
      const double moneyPerPriceUnit = oneLotProfit;
      LogLine("Estimated money per 1.00 move for 1.00 lot: " + DoubleToString(moneyPerPriceUnit, 2));
   }
}

void PrintReferenceSummary()
{
   PrintSymbolBasics();
   PrintProfitProbe();
}

int OnInit()
{
   g_symbol = _Symbol;
   if(!SymbolSelect(g_symbol, true))
      return INIT_FAILED;

   PrintReferenceSummary();

   if(InpUseTimer && InpTimerSeconds > 0)
      EventSetTimer(InpTimerSeconds);

   if(InpRunOnInitOnly)
      return INIT_SUCCEEDED;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(InpUseTimer && InpTimerSeconds > 0)
      EventKillTimer();
}

void OnTimer()
{
   if(InpUseTimer && InpTimerSeconds > 0)
      PrintReferenceSummary();
}

void OnTick()
{
   // Intentionally empty. This EA is for diagnostics only.
}
