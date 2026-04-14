//+------------------------------------------------------------------+
//| XAUUSD_TableGrid_Martingale_BuyOnly.mq5                          |
//| Buy-only table-driven grid EA for XAUUSD (MT5 Hedging)           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input long   InpMagic                   = 260414; // Magic number
input string InpTableFile               = "files/xau_levels.csv"; // CSV in MQL5/Files, format: lot,gridPips per line
input bool   InpSkipFirstCsvRow         = true;   // Skip first row (header)
input bool   InpUseCommonFiles          = false;  // Read CSV from Terminal/Common/Files using FILE_COMMON
input bool   InpUseLastLevelIfExceeded  = true;   // Use last table row when positions exceed table
input int    InpMaxPositions            = 0;      // Max grid positions (0=disabled)
input int    InpMinSecondsBetweenOrders = 10;     // Min delay between orders
input double InpMaxSpreadPips           = 0;      // Max spread in pips (0=disabled)
input double InpBasketTPMoney           = 0;   // Close all when total profit >= value
input bool   InpUseBasketTrail          = true;  // Enable basket profit trailing
input double InpTrailStartMoney         = 20.0;   // Activate trailing when basket profit >= value
input double InpTrailDistanceMoney      = 5.0;    // Close all when profit drops from peak by this value

struct SLevel
{
   double lot;
   double gridPips;
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

int CountBuyPositions(const string symbol, const long magic)
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
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      count++;
   }
   return count;
}

bool GetLatestBuyPosition(const string symbol, const long magic, datetime &latest_time, double &latest_price)
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
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

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
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      profit += PositionGetDouble(POSITION_PROFIT);
   }
   return profit;
}

void CloseAllBuyPositions(const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      trade.PositionClose(ticket);
   }
}

bool SpreadOK(const string symbol)
{
   if(InpMaxSpreadPips <= 0.0)
      return true;

   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double pipPoint = PipPoint(symbol);
   if(pipPoint <= 0.0) return true;

   const double spreadPips = (ask - bid) / pipPoint;
   return (spreadPips <= InpMaxSpreadPips);
}

bool OpenBuy(const string symbol, const double lot, const string comment)
{
   if(!IsTradeAllowed())
      return false;

   const double vol = NormalizeVolume(lot, symbol);
   const bool ok = trade.Buy(vol, symbol, 0.0, 0.0, 0.0, comment);
   if(ok)
      g_lastTradeTime = TimeCurrent();
   return ok;
}

void ResetTrailState()
{
   g_trailActive = false;
   g_trailPeakProfit = 0.0;
}

void PrintCsvLocationGuide(const string filename)
{
   const string dataPath = TerminalInfoString(TERMINAL_DATA_PATH);
   const string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   const bool isTester = (MQLInfoInteger(MQL_TESTER) != 0);

   Print("CSV input (relative path): ", filename);
   Print("Mode: ", (isTester ? "TESTER" : "LIVE"), " | UseCommonFiles: ", (InpUseCommonFiles ? "true" : "false"));

   if(InpUseCommonFiles)
   {
      Print("Place CSV here: ", commonPath, "\\Files\\", filename);
      Print("Note: FILE_COMMON works for both live and tester.");
   }
   else
   {
      Print("Place CSV here: ", dataPath, "\\MQL5\\Files\\", filename);
      if(isTester)
         Print("Tester mode detected: path above should point to the active tester agent data folder.");
   }
}

bool ParseCsvLevelRow(const string row, double &lot, double &gridPips)
{
   string text = row;
   StringTrimLeft(text);
   StringTrimRight(text);
   if(StringLen(text) == 0)
      return false;

   string cells[];
   int cellCount = StringSplit(text, ',', cells);
   if(cellCount != 2)
   {
      // Fallback support for semicolon-separated files.
      cellCount = StringSplit(text, ';', cells);
      if(cellCount != 2)
         return false;
   }

   string slot = cells[0];
   string sgrid = cells[1];
   StringTrimLeft(slot);
   StringTrimRight(slot);
   StringTrimLeft(sgrid);
   StringTrimRight(sgrid);

   lot = StringToDouble(slot);
   gridPips = StringToDouble(sgrid);
   if(lot <= 0.0 || gridPips <= 0.0)
      return false;

   return true;
}

bool LoadLevelTableFromCsv(const string filename)
{
   g_levelCount = 0;
   ArrayResize(g_levels, 0);

   int fileFlags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      fileFlags |= FILE_COMMON;

   ResetLastError();
   const int handle = FileOpen(filename, fileFlags);
   if(handle == INVALID_HANDLE)
   {
      const int err = GetLastError();
      Print("Failed to open CSV file: ", filename,
            " | Error: ", err,
            " | Use relative path only (no absolute path). ",
            "If InpUseCommonFiles=false place in MQL5/Files (or MQL5/Tester/Files in tester). ",
            "If InpUseCommonFiles=true place in Terminal/Common/Files.");
      PrintCsvLocationGuide(filename);
      return false;
   }

   int lineNo = 0;
   bool firstDataRowHandled = false;
   while(!FileIsEnding(handle))
   {
      lineNo++;
      string line = FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);

      if(StringLen(line) == 0)
         continue;

      if(StringGetCharacter(line, 0) == '#')
         continue;

      if(InpSkipFirstCsvRow && !firstDataRowHandled)
      {
         firstDataRowHandled = true;
         continue;
      }
      firstDataRowHandled = true;

      double lot = 0.0;
      double gridPips = 0.0;
      if(!ParseCsvLevelRow(line, lot, gridPips))
      {
         Print("Invalid CSV row #", lineNo, ": '", line, "'. Expected lot,gridPips with numeric values > 0");
         FileClose(handle);
         return false;
      }

      const int newSize = g_levelCount + 1;
      ArrayResize(g_levels, newSize);
      g_levels[g_levelCount].lot = lot;
      g_levels[g_levelCount].gridPips = gridPips;
      g_levelCount = newSize;
   }

   FileClose(handle);

   if(g_levelCount <= 0)
   {
      Print("CSV file has no valid levels: ", filename);
      return false;
   }

   ArrayResize(g_levels, g_levelCount);
   return true;
}

bool GetNextLevelByPosition(const int current_positions, int &levelIndex, double &lot, double &gridPips)
{
   if(g_levelCount <= 0)
      return false;

   int idx = current_positions;
   if(idx >= g_levelCount)
   {
      if(!InpUseLastLevelIfExceeded)
         return false;
      idx = g_levelCount - 1;
   }

   levelIndex = idx;
   lot = g_levels[idx].lot;
   gridPips = g_levels[idx].gridPips;
   return true;
}

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

   PrintCsvLocationGuide(InpTableFile);

   if(!LoadLevelTableFromCsv(InpTableFile))
      return INIT_FAILED;

   if(InpMaxPositions <= 0)
      g_maxPositions = 0;
   else
      g_maxPositions = InpMaxPositions;

   if(InpBasketTPMoney <= 0.0)
      Print("Basket TP is disabled (InpBasketTPMoney <= 0). Positions will not auto-close.");
   if(InpUseBasketTrail)
   {
      if(InpTrailStartMoney <= 0.0)
         Print("Trailing start is <= 0. Trailing may activate too early.");
      if(InpTrailDistanceMoney <= 0.0)
         Print("Trailing distance is <= 0. Trailing may close immediately after activation.");
   }

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;
   ResetTrailState();

   Print("EA initialized for symbol: ", g_symbol,
         " | Levels: ", g_levelCount,
         " | CSV: ", InpTableFile,
         " | CommonFiles: ", (InpUseCommonFiles ? "true" : "false"),
         " | Use last level on exceed: ", (InpUseLastLevelIfExceeded ? "true" : "false"),
         " | Basket TP money: ", DoubleToString(InpBasketTPMoney, 2),
         " | Basket trail: ", (InpUseBasketTrail ? "true" : "false"),
         " | Trail start: ", DoubleToString(InpTrailStartMoney, 2),
         " | Trail distance: ", DoubleToString(InpTrailDistanceMoney, 2),
         " | Max positions: ", g_maxPositions);

   for(int i = 0; i < g_levelCount; i++)
   {
      Print("Level ", (i + 1), ": lot=", DoubleToString(g_levels[i].lot, 2),
            " gridPips=", DoubleToString(g_levels[i].gridPips, 1));
   }

   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(!g_ready)
      return;

   if(_Symbol != g_symbol)
      return;

   if(!IsTradeAllowed())
      return;

   if(!SpreadOK(g_symbol))
      return;

   const int posCount = CountBuyPositions(g_symbol, InpMagic);

   if(posCount <= 0)
      ResetTrailState();

   if(posCount > 0)
   {
      const double profit = TotalProfit(g_symbol, InpMagic);

      // Optional fixed basket TP
      if(InpBasketTPMoney > 0.0 && profit >= InpBasketTPMoney)
      {
         CloseAllBuyPositions(g_symbol, InpMagic);
         ResetTrailState();
         return;
      }

      // Optional basket trailing profit
      if(InpUseBasketTrail && InpTrailDistanceMoney > 0.0)
      {
         if(!g_trailActive && profit >= InpTrailStartMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = profit;
            Print("Basket trail activated at profit ", DoubleToString(profit, 2));
         }

         if(g_trailActive)
         {
            if(profit > g_trailPeakProfit)
               g_trailPeakProfit = profit;

            const double trailStopProfit = g_trailPeakProfit - InpTrailDistanceMoney;
            if(profit <= trailStopProfit)
            {
               Print("Basket trail hit. Profit=", DoubleToString(profit, 2),
                     " Peak=", DoubleToString(g_trailPeakProfit, 2),
                     " Stop=", DoubleToString(trailStopProfit, 2));
               CloseAllBuyPositions(g_symbol, InpMagic);
               ResetTrailState();
               return;
            }
         }
      }
   }

   if(g_maxPositions > 0 && posCount >= g_maxPositions)
      return;

   if(InpMinSecondsBetweenOrders > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
      return;

   int levelIndex;
   double lot;
   double gridPips;
   if(!GetNextLevelByPosition(posCount, levelIndex, lot, gridPips))
      return;

   if(posCount == 0)
   {
      Print("Open initial buy using level ", (levelIndex + 1), " | lot=", DoubleToString(lot, 2));
      OpenBuy(g_symbol, lot, "TableGridBuy");
      return;
   }

   datetime latest_time;
   double latest_price;
   if(!GetLatestBuyPosition(g_symbol, InpMagic, latest_time, latest_price))
      return;

   const double gridPrice = gridPips * PipPoint(g_symbol);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid <= (latest_price - gridPrice))
   {
      Print("Open grid buy using level ", (levelIndex + 1),
            " | lot=", DoubleToString(lot, 2),
            " | gridPips=", DoubleToString(gridPips, 1));
      OpenBuy(g_symbol, lot, "TableGridBuy");
   }
}
