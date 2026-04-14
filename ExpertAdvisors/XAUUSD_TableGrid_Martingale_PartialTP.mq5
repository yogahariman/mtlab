//+------------------------------------------------------------------+
//| XAUUSD_TableGrid_Martingale_PartialTP.mq5                       |
//| Buy-only table-driven grid EA with Partial Take Profit (OPTIMIZED)|
//| Features: Partial TP, Trailing, Max Loss, Volatility Filter     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUT PARAMETERS =====
input long   InpMagic                   = 260415; // Magic number
input string InpTableFile               = "files/xau_levels.csv"; // CSV in MQL5/Files
input bool   InpSkipFirstCsvRow         = true;   // Skip first row (header)
input bool   InpUseCommonFiles          = false;  // Read CSV from Terminal/Common/Files
input bool   InpUseLastLevelIfExceeded  = true;   // Use last table row when positions exceed table

// ===== TRADING CONTROL =====
input int    InpMaxPositions            = 5;      // Max grid positions (reduced for safety)
input int    InpMinSecondsBetweenOrders = 10;     // Min delay between orders
input double InpMaxSpreadPips           = 1.5;    // Max spread in pips

// ===== PARTIAL TAKE PROFIT (NEW) =====
input bool   InpUsePartialTP            = true;   // Enable partial TP
input double InpPartialTP_Step1         = 30.0;   // Close oldest at +$30 profit
input double InpPartialTP_Step2         = 60.0;   // Close another at +$60 profit
input double InpPartialTP_Step3         = 100.0;  // Close all at +$100 profit

// ===== TRAILING PROFIT =====
input bool   InpUseBasketTrail          = true;   // Enable basket profit trailing
input double InpTrailStartMoney         = 15.0;   // Activate trailing when profit >= value
input double InpTrailDistanceMoney      = 3.0;    // Close all when profit drops from peak

// ===== SAFETY =====
input double InpMaxLossAllowed          = -50.0;  // Stop trading if loss reaches this

// ===== INTERNAL STRUCTURES =====
struct SLevel
{
   double lot;
   double gridPips;
};

struct SPosition
{
   ulong   ticket;
   double  openPrice;
   datetime openTime;
   double  lot;
};

CTrade trade;
string g_symbol = "";
bool   g_ready  = false;
datetime g_lastTradeTime = 0;

SLevel g_levels[];
int    g_levelCount = 0;
int    g_maxPositions = 0;

bool g_trailActive = false;
double g_trailPeakProfit = 0.0;

bool g_partialTP_Step1Done = false;
bool g_partialTP_Step2Done = false;

// ===== UTILITY FUNCTIONS =====

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

bool GetOldestBuyPosition(const string symbol, const long magic, ulong &oldest_ticket, datetime &oldest_time)
{
   bool found = false;
   oldest_ticket = 0;
   oldest_time = UINT_MAX;

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
      if(!found || t < oldest_time)
      {
         oldest_time = t;
         oldest_ticket = ticket;
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

bool CloseOldestBuyPosition(const string symbol, const long magic)
{
   ulong oldest_ticket;
   datetime oldest_time;
   
   if(!GetOldestBuyPosition(symbol, magic, oldest_ticket, oldest_time))
      return false;

   return trade.PositionClose(oldest_ticket);
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

void ResetPartialTPState()
{
   g_partialTP_Step1Done = false;
   g_partialTP_Step2Done = false;
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
   }
   else
   {
      Print("Place CSV here: ", dataPath, "\\MQL5\\Files\\", filename);
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
      Print("Failed to open CSV file: ", filename, " | Error: ", err);
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
         Print("Invalid CSV row #", lineNo, ": '", line, "'");
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

// ===== PARTIAL TAKE PROFIT LOGIC =====
void HandlePartialTP(double totalProfit)
{
   if(!InpUsePartialTP)
      return;

   // Step 3: Close all at highest target
   if(totalProfit >= InpPartialTP_Step3)
   {
      Print("Partial TP Step 3 TRIGGERED | Total Profit: $", DoubleToString(totalProfit, 2), " >= $", DoubleToString(InpPartialTP_Step3, 2));
      CloseAllBuyPositions(g_symbol, InpMagic);
      ResetPartialTPState();
      ResetTrailState();
      return;
   }

   // Step 2: Close oldest at mid target
   if(totalProfit >= InpPartialTP_Step2 && !g_partialTP_Step2Done)
   {
      if(CloseOldestBuyPosition(g_symbol, InpMagic))
      {
         Print("Partial TP Step 2 TRIGGERED | Total Profit: $", DoubleToString(totalProfit, 2), " >= $", DoubleToString(InpPartialTP_Step2, 2));
         g_partialTP_Step2Done = true;
      }
      return;
   }

   // Step 1: Close oldest at first target
   if(totalProfit >= InpPartialTP_Step1 && !g_partialTP_Step1Done)
   {
      if(CloseOldestBuyPosition(g_symbol, InpMagic))
      {
         Print("Partial TP Step 1 TRIGGERED | Total Profit: $", DoubleToString(totalProfit, 2), " >= $", DoubleToString(InpPartialTP_Step1, 2));
         g_partialTP_Step1Done = true;
      }
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

   string sym = g_symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") < 0)
   {
      Print("This EA is optimized for XAUUSD. Please attach it to an XAUUSD chart.");
      return INIT_FAILED;
   }

   if(!IsHedgingAccount())
   {
      Print("This EA requires a Hedging account type.");
      return INIT_FAILED;
   }

   PrintCsvLocationGuide(InpTableFile);

   if(!LoadLevelTableFromCsv(InpTableFile))
      return INIT_FAILED;

   if(InpMaxPositions <= 0)
      g_maxPositions = 0;
   else
      g_maxPositions = InpMaxPositions;

   trade.SetExpertMagicNumber(InpMagic);
   g_ready = true;
   ResetTrailState();
   ResetPartialTPState();

   Print("=== EA INITIALIZED (OPTIMIZED v2.00) ===");
   Print("Symbol: ", g_symbol, " | Levels: ", g_levelCount, " | CSV: ", InpTableFile);
   Print("Max Positions: ", g_maxPositions, " | Min Spread: ", DoubleToString(InpMaxSpreadPips, 2), " pips");
   Print("--- Partial TP Settings ---");
   Print("Enabled: ", (InpUsePartialTP ? "YES" : "NO"));
   Print("  Step1: Close oldest at +$", DoubleToString(InpPartialTP_Step1, 2));
   Print("  Step2: Close another at +$", DoubleToString(InpPartialTP_Step2, 2));
   Print("  Step3: Close all at +$", DoubleToString(InpPartialTP_Step3, 2));
   Print("--- Basket Trailing Settings ---");
   Print("Enabled: ", (InpUseBasketTrail ? "YES" : "NO"));
   Print("  Start Trailing at: +$", DoubleToString(InpTrailStartMoney, 2));
   Print("  Trail Distance: $", DoubleToString(InpTrailDistanceMoney, 2));
   Print("--- Safety Settings ---");
   Print("Max Loss Allowed: $", DoubleToString(InpMaxLossAllowed, 2));
   Print("Time Filter: MANUAL (user control)");

   for(int i = 0; i < g_levelCount; i++)
   {
      Print("  Level", (i + 1), ": lot=", DoubleToString(g_levels[i].lot, 2), " | gridPips=", DoubleToString(g_levels[i].gridPips, 1));
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
   const double totalProfit = TotalProfit(g_symbol, InpMagic);

   // ===== SAFETY: Maximum Loss Check =====
   if(totalProfit <= InpMaxLossAllowed)
   {
      Print("⚠️ MAX LOSS REACHED | Profit: $", DoubleToString(totalProfit, 2), " <= Limit: $", DoubleToString(InpMaxLossAllowed, 2));
      CloseAllBuyPositions(g_symbol, InpMagic);
      ResetTrailState();
      ResetPartialTPState();
      return;
   }

   // ===== NO POSITIONS =====
   if(posCount <= 0)
   {
      ResetTrailState();
      ResetPartialTPState();
   }

   // ===== POSITIONS EXIST =====
   if(posCount > 0)
   {
      // Handle Partial TP (NEW)
      HandlePartialTP(totalProfit);
      if(CountBuyPositions(g_symbol, InpMagic) <= 0)
         return;  // Positions were closed by Partial TP, exit

      // Handle Basket Trailing
      if(InpUseBasketTrail && InpTrailDistanceMoney > 0.0)
      {
         if(!g_trailActive && totalProfit >= InpTrailStartMoney)
         {
            g_trailActive = true;
            g_trailPeakProfit = totalProfit;
            Print("🔔 Basket Trailing ACTIVATED at Profit: $", DoubleToString(totalProfit, 2));
         }

         if(g_trailActive)
         {
            if(totalProfit > g_trailPeakProfit)
               g_trailPeakProfit = totalProfit;

            const double trailStopProfit = g_trailPeakProfit - InpTrailDistanceMoney;
            if(totalProfit <= trailStopProfit)
            {
               Print("🔔 Basket Trailing STOP HIT | Current: $", DoubleToString(totalProfit, 2),
                     " | Peak: $", DoubleToString(g_trailPeakProfit, 2),
                     " | Trail Level: $", DoubleToString(trailStopProfit, 2));
               CloseAllBuyPositions(g_symbol, InpMagic);
               ResetTrailState();
               ResetPartialTPState();
               return;
            }
         }
      }
   }

   // ===== POSITION LIMIT CHECK =====
   if(g_maxPositions > 0 && posCount >= g_maxPositions)
      return;

   // ===== DELAY BETWEEN ORDERS =====
   if(InpMinSecondsBetweenOrders > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
      return;

   // ===== GET NEXT LEVEL =====
   int levelIndex;
   double lot;
   double gridPips;
   if(!GetNextLevelByPosition(posCount, levelIndex, lot, gridPips))
      return;

   // ===== OPEN INITIAL BUY =====
   if(posCount == 0)
   {
      Print("📈 OPEN INITIAL BUY | Level ", (levelIndex + 1), " | Lot: ", DoubleToString(lot, 2));
      OpenBuy(g_symbol, lot, "PartialTP_Grid");
      return;
   }

   // ===== OPEN GRID BUY =====
   datetime latest_time;
   double latest_price;
   if(!GetLatestBuyPosition(g_symbol, InpMagic, latest_time, latest_price))
      return;

   const double gridPrice = gridPips * PipPoint(g_symbol);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid <= (latest_price - gridPrice))
   {
      Print("📈 OPEN GRID BUY | Level ", (levelIndex + 1),
            " | Lot: ", DoubleToString(lot, 2),
            " | GridPips: ", DoubleToString(gridPips, 1),
            " | Price Grid: ", DoubleToString(gridPrice, 2));
      OpenBuy(g_symbol, lot, "PartialTP_Grid");
   }
}

void OnDeinit(const int reason)
{
   Print("EA DEINITILIZED | Reason: ", reason);
}