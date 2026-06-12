//+------------------------------------------------------------------+
//| XAU_StochTrend.mq5                                               |
//| EMA trend + Stochastic crossing + XAU martingale grid basket      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.14"
#property strict

#include <Trade/Trade.mqh>

enum ETradeMode
{
   TRADE_BUY_ONLY = 0,
   TRADE_SELL_ONLY = 1,
   TRADE_BOTH_SINGLE = 2
};

enum EMaType
{
   MA_TYPE_SIMPLE = 0,
   MA_TYPE_EXPONENTIAL = 1
};

enum ETimeMode
{
   TIME_MODE_WIB = 0,
   TIME_MODE_BROKER = 1,
   TIME_MODE_UTC = 2
};

enum EMaxDdResumeMode
{
   MAX_DD_CONTINUE_TRADING = 0,
   MAX_DD_PAUSE_MANUAL = 1,
   MAX_DD_PAUSE_NEXT_DAY = 2
};

enum EBasketTpMode
{
   BASKET_TP_BASE_LOT = 0,
   BASKET_TP_TOTAL_LOT = 1
};

enum ETrendFilterMode
{
   TREND_FILTER_OFF = 0,
   TREND_FILTER_SINGLE_EMA = 1,
   TREND_FILTER_DOUBLE_EMA = 2
};

enum EStochEntryMode
{
   STOCH_ENTRY_ON_CROSS = 0,
   STOCH_ENTRY_AFTER_CANDLE_CLOSE = 1
};

input group "General"
input ETradeMode InpTradeMode             = TRADE_BOTH_SINGLE;
input long   InpBuyMagic                  = 333333;
input long   InpSellMagic                 = 444444;
input double InpMaxSpread                 = 0.40;  // Price distance XAU
input double InpMaxSlippage               = 0.30;  // Price distance XAU
input bool   InpUseCloseLock              = true;
input bool   InpUsePriorityCloseOrder     = true;
input bool   InpUseAsyncClose             = true;
input double InpCloseDeviation            = 0.30;  // Price distance XAU
input int    InpCloseAttemptsPerRun       = 1;
input int    InpCloseLockTimerMs          = 300;
input int    InpMinSecondsBetweenOrders   = 1;

input group "Trend Filter"
input ETrendFilterMode InpTrendFilterMode  = TREND_FILTER_SINGLE_EMA;
input EMaType InpMovingAverageType        = MA_TYPE_EXPONENTIAL;
input int    InpTrendEMAPeriod            = 120;
input int    InpFastMAPeriod              = 13;
input int    InpSlowMAPeriod              = 233;
input double InpEmaMinDistance            = 0.50;  // Price distance XAU

input group "Decision Indicator"
input EStochEntryMode InpStochEntryMode    = STOCH_ENTRY_ON_CROSS;
input int    InpKPeriod                   = 5;
input int    InpDPeriod                   = 3;
input int    InpSlowing                   = 3;
input double InpOverbought                = 80.0;
input double InpOversold                  = 20.0;

input group "Grid Martingale"
input string InpLotTable                  = "0.10;0.20;0.20;0.30";
input double InpGridDistance              = 8.00;  // Price distance XAU
input EBasketTpMode InpBasketTpMode       = BASKET_TP_BASE_LOT;
input double InpBasketTpPriceMove         = 1.00;  // Dynamic money target from initial lot
input double InpXauMoneyPerPriceUnit      = 100.0; // 1 lot profit for XAU move 1.00
input double InpMaxDrawdownMoney          = 3000.00;
input EMaxDdResumeMode InpMaxDdResumeMode = MAX_DD_PAUSE_NEXT_DAY;

input group "Telegram Alerts"
input bool   InpUseTelegramAlerts         = true;
input string InpTelegramBotToken          = "8383407093:AAFGHJ6oBVHtvRsJel2NQUOklbeOwtxtdVk";
input string InpTelegramChatId            = "1448627275";

input group "Manual Time Filter"
input bool   InpUseTimeFilter             = true;
input ETimeMode InpTimeMode               = TIME_MODE_WIB;
input string InpPauseWindows              = "4:00-9:00;12:00-13:00;19:00-22:00"; // Time windows to pause trading, format: "hh:mm-hh:mm;hh:mm-hh:mm"

CTrade trade;
string g_symbol = "";
datetime g_lastBarTime = 0;
datetime g_lastTradeTime = 0;
datetime g_lastFirstEntryBarTime = 0;
int g_fastMaHandle = INVALID_HANDLE;
int g_slowMaHandle = INVALID_HANDLE;
int g_stochHandle = INVALID_HANDLE;
bool g_pausedByMaxDd = false;
int g_maxDdPausedDayKey = 0;
bool g_stochBuyArmed = false;
bool g_stochSellArmed = false;
bool g_stochBuyZoneInside = false;
bool g_stochSellZoneInside = false;
bool g_pendingStochBuy = false;
bool g_pendingStochSell = false;
datetime g_pendingStochBuyBarTime = 0;
datetime g_pendingStochSellBarTime = 0;
bool g_closeLockActive = false;
long g_closeLockMagic = 0;
ENUM_POSITION_TYPE g_closeLockType = POSITION_TYPE_BUY;
bool g_closeLockPauseAfterClose = false;
int g_closeLockLastRemain = -1;
double g_lotTable[];

ENUM_MA_METHOD MaMethod()
{
   return (InpMovingAverageType == MA_TYPE_SIMPLE ? MODE_SMA : MODE_EMA);
}

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

int TradingDayKey(const datetime whenTime)
{
   MqlDateTime dt;
   ReferenceTimeStruct(whenTime, dt);
   return (dt.year * 10000 + dt.mon * 100 + dt.day);
}

bool UseTrendFilter()
{
   return (InpTrendFilterMode != TREND_FILTER_OFF);
}

bool UseSingleEmaTrend()
{
   return (InpTrendFilterMode == TREND_FILTER_SINGLE_EMA);
}

bool UseDoubleEmaTrend()
{
   return (InpTrendFilterMode == TREND_FILTER_DOUBLE_EMA);
}

bool UseStochasticDecision()
{
   return true;
}

int BrokerUtcOffsetHours()
{
   return (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);
}

void ResetStochasticPending()
{
   g_stochBuyArmed = false;
   g_stochSellArmed = false;
   g_pendingStochBuy = false;
   g_pendingStochSell = false;
   g_pendingStochBuyBarTime = 0;
   g_pendingStochSellBarTime = 0;
}

void UpdateStochasticPendingCross()
{
   if(!UseStochasticDecision())
      return;

   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime <= 0)
      return;

   double main0 = 0.0, main1 = 0.0, signal0 = 0.0, signal1 = 0.0;
   if(!GetBufferValue(g_stochHandle, 0, 0, main0)) return;
   if(!GetBufferValue(g_stochHandle, 0, 1, main1)) return;
   if(!GetBufferValue(g_stochHandle, 1, 0, signal0)) return;
   if(!GetBufferValue(g_stochHandle, 1, 1, signal1)) return;

   const bool buyZoneTouchedNow = (main0 < InpOversold && signal0 < InpOversold);
   const bool sellZoneTouchedNow = (main0 > InpOverbought && signal0 > InpOverbought);

   if(buyZoneTouchedNow)
   {
      g_stochBuyZoneInside = true;
      g_stochBuyArmed = true;
   }
   else
   {
      g_stochBuyZoneInside = false;
      g_stochBuyArmed = false;
      g_pendingStochBuy = false;
      g_pendingStochBuyBarTime = 0;
   }

   if(sellZoneTouchedNow)
   {
      g_stochSellZoneInside = true;
      g_stochSellArmed = true;
   }
   else
   {
      g_stochSellZoneInside = false;
      g_stochSellArmed = false;
      g_pendingStochSell = false;
      g_pendingStochSellBarTime = 0;
   }

   if(g_stochBuyArmed && main1 <= signal1 && main0 > signal0)
   {
      g_pendingStochBuy = true;
      g_pendingStochBuyBarTime = barTime;
      g_pendingStochSell = false;
      g_pendingStochSellBarTime = 0;
      g_stochBuyArmed = false;
      return;
   }

   if(g_stochSellArmed && main1 >= signal1 && main0 < signal0)
   {
      g_pendingStochSell = true;
      g_pendingStochSellBarTime = barTime;
      g_pendingStochBuy = false;
      g_pendingStochBuyBarTime = 0;
      g_stochSellArmed = false;
   }
}

bool StochasticLineTouchedOversold(const int bufferIndex)
{
   double value1 = 0.0, value2 = 0.0;
   if(!GetBufferValue(g_stochHandle, bufferIndex, 1, value1)) return false;
   if(!GetBufferValue(g_stochHandle, bufferIndex, 2, value2)) return false;

   return (value1 < InpOversold || value2 < InpOversold);
}

bool StochasticLineTouchedOverbought(const int bufferIndex)
{
   double value1 = 0.0, value2 = 0.0;
   if(!GetBufferValue(g_stochHandle, bufferIndex, 1, value1)) return false;
   if(!GetBufferValue(g_stochHandle, bufferIndex, 2, value2)) return false;

   return (value1 > InpOverbought || value2 > InpOverbought);
}

bool StochasticTouchedOversold()
{
   return (StochasticLineTouchedOversold(0) &&
           StochasticLineTouchedOversold(1));
}

bool StochasticTouchedOverbought()
{
   return (StochasticLineTouchedOverbought(0) &&
           StochasticLineTouchedOverbought(1));
}

bool StochasticBuyCrossNow()
{
   double main0 = 0.0, main1 = 0.0, signal0 = 0.0, signal1 = 0.0;
   if(!GetBufferValue(g_stochHandle, 0, 0, main0)) return false;
   if(!GetBufferValue(g_stochHandle, 0, 1, main1)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 0, signal0)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 1, signal1)) return false;

   return (main1 <= signal1 && main0 > signal0);
}

bool StochasticSellCrossNow()
{
   double main0 = 0.0, main1 = 0.0, signal0 = 0.0, signal1 = 0.0;
   if(!GetBufferValue(g_stochHandle, 0, 0, main0)) return false;
   if(!GetBufferValue(g_stochHandle, 0, 1, main1)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 0, signal0)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 1, signal1)) return false;

   return (main1 >= signal1 && main0 < signal0);
}

bool StochasticBuyConfirmedAfterClose()
{
   double main1 = 0.0, main2 = 0.0, signal1 = 0.0, signal2 = 0.0;
   if(!GetBufferValue(g_stochHandle, 0, 1, main1)) return false;
   if(!GetBufferValue(g_stochHandle, 0, 2, main2)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 1, signal1)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 2, signal2)) return false;

   if(main2 >= signal2)
      return false;
   if(main1 <= signal1)
      return false;
   return true;
}

bool StochasticSellConfirmedAfterClose()
{
   double main1 = 0.0, main2 = 0.0, signal1 = 0.0, signal2 = 0.0;
   if(!GetBufferValue(g_stochHandle, 0, 1, main1)) return false;
   if(!GetBufferValue(g_stochHandle, 0, 2, main2)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 1, signal1)) return false;
   if(!GetBufferValue(g_stochHandle, 1, 2, signal2)) return false;

   if(main2 <= signal2)
      return false;
   if(main1 >= signal1)
      return false;
   return true;
}

bool BuyTrendSideOK(const int shift)
{
   if(!UseTrendFilter())
      return true;

   double fast = 0.0, slow = 0.0;
   if(!GetBufferValue(g_fastMaHandle, 0, shift, fast))
      return false;

   if(UseSingleEmaTrend())
   {
      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice > fast);
   }

   if(UseDoubleEmaTrend())
   {
      if(!GetBufferValue(g_slowMaHandle, 0, shift, slow))
         return false;
      if(fast <= slow)
         return false;
      if(InpEmaMinDistance > 0.0 && MathAbs(fast - slow) < InpEmaMinDistance)
         return false;

      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice > fast);
   }

   return true;
}

bool SellTrendSideOK(const int shift)
{
   if(!UseTrendFilter())
      return true;

   double fast = 0.0, slow = 0.0;
   if(!GetBufferValue(g_fastMaHandle, 0, shift, fast))
      return false;

   if(UseSingleEmaTrend())
   {
      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice < fast);
   }

   if(UseDoubleEmaTrend())
   {
      if(!GetBufferValue(g_slowMaHandle, 0, shift, slow))
         return false;
      if(fast >= slow)
         return false;
      if(InpEmaMinDistance > 0.0 && MathAbs(fast - slow) < InpEmaMinDistance)
         return false;

      const double closePrice = iClose(g_symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         return false;
      return (closePrice < fast);
   }

   return true;
}

bool BuyDecisionOK_Stochastic()
{
   if(!g_pendingStochBuy)
      return false;

   if(InpStochEntryMode == STOCH_ENTRY_ON_CROSS)
      return StochasticBuyCrossNow();

   if(g_pendingStochBuyBarTime != iTime(g_symbol, PERIOD_CURRENT, 1))
      return false;

   return StochasticBuyConfirmedAfterClose();
}

bool SellDecisionOK_Stochastic()
{
   if(!g_pendingStochSell)
      return false;

   if(InpStochEntryMode == STOCH_ENTRY_ON_CROSS)
      return StochasticSellCrossNow();

   if(g_pendingStochSellBarTime != iTime(g_symbol, PERIOD_CURRENT, 1))
      return false;

   return StochasticSellConfirmedAfterClose();
}

bool IsHedgingAccount()
{
   const long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

double NormalizePrice(const string symbol, const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
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

bool ParseLotTable()
{
   ArrayResize(g_lotTable, 0);

   string table = InpLotTable;
   StringTrimLeft(table);
   StringTrimRight(table);
   if(StringLen(table) <= 0)
      return false;

   string cells[];
   const int count = StringSplit(table, ';', cells);
   if(count <= 0)
      return false;

   for(int i = 0; i < count; i++)
   {
      string cell = cells[i];
      StringTrimLeft(cell);
      StringTrimRight(cell);
      if(StringLen(cell) <= 0)
         return false;

      const double lot = StringToDouble(cell);
      if(lot <= 0.0)
         return false;

      const int n = ArraySize(g_lotTable) + 1;
      ArrayResize(g_lotTable, n);
      g_lotTable[n - 1] = NormalizeVolume(g_symbol, lot);
   }

   return (ArraySize(g_lotTable) > 0);
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

string UrlEncode(const string src)
{
   string out = "";
   char bytes[];
   const int copied = StringToCharArray(src, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(copied <= 1)
      return out;

   for(int i = 0; i < copied - 1; i++)
   {
      const int c = ((int)bytes[i]) & 0xFF;
      const bool safe = ((c >= 'a' && c <= 'z') ||
                         (c >= 'A' && c <= 'Z') ||
                         (c >= '0' && c <= '9') ||
                         c == '-' || c == '_' || c == '.' || c == '~');
      if(safe)
         out += CharToString((uchar)c);
      else if(c == ' ')
         out += "%20";
      else
         out += StringFormat("%%%02X", c);
   }
   return out;
}

bool SendTelegramMessage(const string text)
{
   if(IsTesterRun() || !InpUseTelegramAlerts)
      return false;

   string botToken = InpTelegramBotToken;
   StringTrimLeft(botToken);
   StringTrimRight(botToken);

   string chatId = InpTelegramChatId;
   StringTrimLeft(chatId);
   StringTrimRight(chatId);

   if(StringLen(botToken) == 0 || StringLen(chatId) == 0)
      return false;

   const string url = "https://api.telegram.org/bot" + botToken + "/sendMessage";
   const string body = "chat_id=" + UrlEncode(chatId) + "&text=" + UrlEncode(text);
   const string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   char data[];
   char result[];
   string result_headers = "";

   int copied = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(copied > 0)
      ArrayResize(data, copied - 1);
   else
      ArrayResize(data, 0);

   ResetLastError();
   const int code = WebRequest("POST", url, headers, 5000, data, result, result_headers);
   if(code < 200 || code >= 300)
   {
      Print("Telegram fail | code=", code,
            " | err=", GetLastError(),
            " | allow_url=https://api.telegram.org");
      return false;
   }

   return true;
}

void SendTelegramEvent(const string action, const double lot)
{
   if(IsTesterRun() || !InpUseTelegramAlerts)
      return;

   const string broker = AccountInfoString(ACCOUNT_COMPANY);
   const string msg =
      "Broker: " + broker + "\n" +
      "Action: " + action + "\n" +
      "Lot: " + DoubleToString(lot, 2);

   SendTelegramMessage(msg);
}

string PositionTypeLabel(const ENUM_POSITION_TYPE type)
{
   return (type == POSITION_TYPE_BUY ? "BUY" : "SELL");
}

void ReferenceTimeStruct(const datetime whenTime, MqlDateTime &dt)
{
   datetime refTime = whenTime;
   if(InpTimeMode == TIME_MODE_BROKER)
   {
      refTime = whenTime;
   }
   else
   {
      const int brokerUtcOffset = BrokerUtcOffsetHours();
      refTime = whenTime - brokerUtcOffset * 3600;
      if(InpTimeMode == TIME_MODE_WIB)
         refTime += 7 * 3600;
   }
   TimeToStruct(refTime, dt);
}

int MinutesOfDay(const datetime whenTime)
{
   MqlDateTime dt;
   ReferenceTimeStruct(whenTime, dt);
   return dt.hour * 60 + dt.min;
}

bool ParseTimeToMinutes(const string text, int &minutes)
{
   minutes = -1;

   string value = text;
   StringTrimLeft(value);
   StringTrimRight(value);

   string cells[];
   if(StringSplit(value, ':', cells) != 2)
      return false;

   string hourText = cells[0];
   string minuteText = cells[1];
   StringTrimLeft(hourText);
   StringTrimRight(hourText);
   StringTrimLeft(minuteText);
   StringTrimRight(minuteText);

   const int hour = (int)StringToInteger(hourText);
   const int minute = (int)StringToInteger(minuteText);
   if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
      return false;

   minutes = hour * 60 + minute;
   return true;
}

bool IsInPauseWindowText(const int nowMinutes, const string windowText)
{
   string value = windowText;
   StringTrimLeft(value);
   StringTrimRight(value);
   if(StringLen(value) <= 0)
      return false;

   string parts[];
   if(StringSplit(value, '-', parts) != 2)
      return false;

   int startMinutes = -1;
   int endMinutes = -1;
   if(!ParseTimeToMinutes(parts[0], startMinutes))
      return false;
   if(!ParseTimeToMinutes(parts[1], endMinutes))
      return false;

   if(startMinutes <= endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes <= endMinutes);

   return (nowMinutes >= startMinutes || nowMinutes <= endMinutes);
}

bool IsFirstEntryPausedByTime()
{
   if(!InpUseTimeFilter)
      return false;

   string windows = InpPauseWindows;
   StringTrimLeft(windows);
   StringTrimRight(windows);
   if(StringLen(windows) <= 0)
      return false;

   const int nowMinutes = MinutesOfDay(TimeCurrent());
   string ranges[];
   const int count = StringSplit(windows, ';', ranges);
   for(int i = 0; i < count; i++)
   {
      if(IsInPauseWindowText(nowMinutes, ranges[i]))
         return true;
   }

   return false;
}

bool TryResumeAfterMaxDd()
{
   if(!g_pausedByMaxDd)
      return true;

   if(InpMaxDdResumeMode != MAX_DD_PAUSE_NEXT_DAY)
      return false;

   if(g_maxDdPausedDayKey <= 0)
      return false;

   if(TradingDayKey(TimeCurrent()) == g_maxDdPausedDayKey)
      return false;

   g_pausedByMaxDd = false;
   g_maxDdPausedDayKey = 0;
   Print("Max DD pause lifted | resume=next_day");
   return (!g_pausedByMaxDd);
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

int CountPositions(const long magic, const ENUM_POSITION_TYPE type)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      count++;
   }
   return count;
}

int CountBasketPositions(const long magic, const ENUM_POSITION_TYPE type)
{
   return CountPositions(magic, type);
}

int CountAllManagedPositions()
{
   return CountPositions(InpBuyMagic, POSITION_TYPE_BUY) + CountPositions(InpSellMagic, POSITION_TYPE_SELL);
}

int CountFirstEntryPositionsForCurrentMode()
{
   if(InpTradeMode == TRADE_BUY_ONLY)
      return CountPositions(InpBuyMagic, POSITION_TYPE_BUY);
   if(InpTradeMode == TRADE_SELL_ONLY)
      return CountPositions(InpSellMagic, POSITION_TYPE_SELL);

   return CountAllManagedPositions();
}

double BasketProfit(const long magic, const ENUM_POSITION_TYPE type)
{
   double profit = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      profit += PositionGetDouble(POSITION_PROFIT);
      profit += PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

double BasketTotalVolume(const long magic, const ENUM_POSITION_TYPE type)
{
   double totalVolume = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      totalVolume += PositionGetDouble(POSITION_VOLUME);
   }
   return totalVolume;
}

double MoneyPerPriceUnitPerLot(const string symbol)
{
   string sym = symbol;
   StringToUpper(sym);
   if((StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0) && InpXauMoneyPerPriceUnit > 0.0)
      return InpXauMoneyPerPriceUnit;

   const double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize > 0.0 && tickValue > 0.0)
      return tickValue / tickSize;

   const double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize > 0.0)
      return contractSize;

   return 0.0;
}

double BasketTpMoneyTarget(const long magic, const ENUM_POSITION_TYPE type)
{
   const double moneyPerPriceUnit = MoneyPerPriceUnitPerLot(g_symbol);
   if(moneyPerPriceUnit <= 0.0 || InpBasketTpPriceMove <= 0.0 || ArraySize(g_lotTable) <= 0)
      return 0.0;

   double basisLot = g_lotTable[0];
   if(InpBasketTpMode == BASKET_TP_TOTAL_LOT)
      basisLot = BasketTotalVolume(magic, type);

   if(basisLot <= 0.0)
      return 0.0;

   return basisLot * moneyPerPriceUnit * InpBasketTpPriceMove;
}

bool BasketTpHit(const long magic, const ENUM_POSITION_TYPE type)
{
   const double targetMoney = BasketTpMoneyTarget(magic, type);
   if(targetMoney <= 0.0)
      return false;

   return (BasketProfit(magic, type) >= targetMoney);
}

void ResetCloseLock()
{
   g_closeLockActive = false;
   g_closeLockMagic = 0;
   g_closeLockType = POSITION_TYPE_BUY;
   g_closeLockPauseAfterClose = false;
   g_closeLockLastRemain = -1;
}

void ActivateCloseLock(const long magic, const ENUM_POSITION_TYPE type,
                       const string reason, const bool pauseAfterClose)
{
   if(!g_closeLockActive)
   {
      Print("Close lock ON | reason=", reason,
            " | side=", PositionTypeLabel(type),
            " | magic=", (string)magic);
   }

   g_closeLockActive = true;
   g_closeLockMagic = magic;
   g_closeLockType = type;
   g_closeLockPauseAfterClose = pauseAfterClose;
   g_closeLockLastRemain = -1;
}

int CloseBasketOnce(const long magic, const ENUM_POSITION_TYPE type)
{
   const ulong closeDeviation = DeviationPointsFromPriceDistance(g_symbol, InpCloseDeviation);
   const bool useCustomDeviation = (closeDeviation > 0);
   const bool useAsyncClose = InpUseAsyncClose;

   if(useAsyncClose)
      trade.SetAsyncMode(true);

   if(InpUsePriorityCloseOrder)
   {
      ulong tickets[];
      double volumes[];
      double profits[];
      int q = 0;

      for(int i = 0; i < PositionsTotal(); i++)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

         const int n = q + 1;
         ArrayResize(tickets, n);
         ArrayResize(volumes, n);
         ArrayResize(profits, n);
         tickets[q] = ticket;
         volumes[q] = PositionGetDouble(POSITION_VOLUME);
         profits[q] = PositionGetDouble(POSITION_PROFIT);
         q = n;
      }

      for(int i = 0; i < q - 1; i++)
      {
         int best = i;
         for(int j = i + 1; j < q; j++)
         {
            bool better = false;
            if(volumes[j] > volumes[best])
               better = true;
            else if(volumes[j] == volumes[best] && profits[j] < profits[best])
               better = true;

            if(better)
               best = j;
         }

         if(best != i)
         {
            const ulong tTicket = tickets[i];
            tickets[i] = tickets[best];
            tickets[best] = tTicket;

            const double tVolume = volumes[i];
            volumes[i] = volumes[best];
            volumes[best] = tVolume;

            const double tProfit = profits[i];
            profits[i] = profits[best];
            profits[best] = tProfit;
         }
      }

      for(int i = 0; i < q; i++)
      {
         const ulong ticket = tickets[i];
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

         const bool closeOk = (useCustomDeviation
            ? trade.PositionClose(ticket, closeDeviation)
            : trade.PositionClose(ticket));
         if(!closeOk)
         {
            Print("Close fail | ticket=", (string)ticket,
                  " | retcode=", (string)trade.ResultRetcode(),
                  " | desc=", trade.ResultRetcodeDescription());
         }
      }
   }
   else
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

         const bool closeOk = (useCustomDeviation
            ? trade.PositionClose(ticket, closeDeviation)
            : trade.PositionClose(ticket));
         if(!closeOk)
         {
            Print("Close fail | ticket=", (string)ticket,
                  " | retcode=", (string)trade.ResultRetcode(),
                  " | desc=", trade.ResultRetcodeDescription());
         }
      }
   }

   if(useAsyncClose)
      trade.SetAsyncMode(false);

   return CountBasketPositions(magic, type);
}

int CloseBasketWithRetries(const long magic, const ENUM_POSITION_TYPE type, const int maxAttempts)
{
   int attempts = maxAttempts;
   if(attempts <= 0)
      attempts = 1;
   if(InpUseAsyncClose && attempts > 1)
      attempts = 1;

   int remain = CountBasketPositions(magic, type);
   int prevRemain = remain + 1;
   for(int attempt = 0; attempt < attempts && remain > 0; attempt++)
   {
      remain = CloseBasketOnce(magic, type);
      if(remain >= prevRemain)
         break;
      prevRemain = remain;
   }

   return remain;
}

bool ProcessCloseLock()
{
   if(!InpUseCloseLock || !g_closeLockActive)
      return false;

   int remain = CountBasketPositions(g_closeLockMagic, g_closeLockType);
   if(remain <= 0)
   {
      if(g_closeLockPauseAfterClose)
      {
         g_pausedByMaxDd = true;
         g_maxDdPausedDayKey = (InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY ? TradingDayKey(TimeCurrent()) : 0);
      }
      Print("Close lock OFF | all positions closed");
      ResetCloseLock();
      return true;
   }

   if(!IsTradeAllowed())
      return true;

   remain = CloseBasketWithRetries(g_closeLockMagic, g_closeLockType, InpCloseAttemptsPerRun);
   if(remain <= 0)
   {
      if(g_closeLockPauseAfterClose)
      {
         g_pausedByMaxDd = true;
         g_maxDdPausedDayKey = (InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY ? TradingDayKey(TimeCurrent()) : 0);
      }
      Print("Close lock OFF | all positions closed");
      ResetCloseLock();
   }
   else if(remain != g_closeLockLastRemain)
   {
      Print("Close lock running | remain=", remain,
            " | side=", PositionTypeLabel(g_closeLockType));
      g_closeLockLastRemain = remain;
   }

   return true;
}

void CloseBasket(const long magic, const ENUM_POSITION_TYPE type, const string reason, const bool pauseAfterClose)
{
   if(InpUseCloseLock)
   {
      ActivateCloseLock(magic, type, reason, pauseAfterClose);
      ProcessCloseLock();
      return;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Close failed | ticket=", ticket,
               " | retcode=", trade.ResultRetcode(),
               " | desc=", trade.ResultRetcodeDescription());
      }
   }

   if(pauseAfterClose)
   {
      g_pausedByMaxDd = true;
      g_maxDdPausedDayKey = (InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY ? TradingDayKey(TimeCurrent()) : 0);
   }
}

bool GridAnchorPrice(const long magic, const ENUM_POSITION_TYPE type, double &price)
{
   bool found = false;
   price = 0.0;
   datetime latestTime = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openPrice <= 0.0) continue;

      if(!found || openTime > latestTime)
      {
         found = true;
         latestTime = openTime;
         price = openPrice;
      }
   }

   return found;
}

bool GetLayerLot(const int layerIndex, double &lot)
{
   lot = 0.0;
   if(layerIndex < 0 || layerIndex >= ArraySize(g_lotTable))
      return false;

   lot = g_lotTable[layerIndex];
   return (lot > 0.0);
}

bool OpenMarket(const bool isBuy, const double lot, const string comment)
{
   if(!IsTradeAllowed() || !SpreadOK())
      return false;

   if(InpMinSecondsBetweenOrders > 0 && g_lastTradeTime > 0)
   {
      if((TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetweenOrders)
         return false;
   }

   trade.SetExpertMagicNumber(isBuy ? InpBuyMagic : InpSellMagic);
   trade.SetDeviationInPoints(DeviationPointsFromPriceDistance(g_symbol, InpMaxSlippage));

   const double volume = NormalizeVolume(g_symbol, lot);
   const bool ok = (isBuy
      ? trade.Buy(volume, g_symbol, 0.0, 0.0, 0.0, comment)
      : trade.Sell(volume, g_symbol, 0.0, 0.0, 0.0, comment));

   if(!ok)
   {
      Print("Order failed | side=", (isBuy ? "BUY" : "SELL"),
            " | lot=", DoubleToString(volume, 2),
            " | retcode=", trade.ResultRetcode(),
            " | desc=", trade.ResultRetcodeDescription());
      return false;
   }

   Print("Order opened | side=", (isBuy ? "BUY" : "SELL"),
         " | lot=", DoubleToString(volume, 2),
         " | comment=", comment);
   g_lastTradeTime = TimeCurrent();

   string action = "Order Open";
   if(StringFind(comment, "First") >= 0)
   {
      action = "First Entry Open";
      g_lastFirstEntryBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
      ResetStochasticPending();
   }
   else if(StringFind(comment, "Grid") >= 0)
      action = "Grid Layer Add";

   SendTelegramEvent(action, volume);
   return true;
}

void ManageBasketRiskAndExit()
{
   const int buyCount = CountPositions(InpBuyMagic, POSITION_TYPE_BUY);
   if(buyCount > 0)
   {
      const double profit = BasketProfit(InpBuyMagic, POSITION_TYPE_BUY);
      if(BasketTpHit(InpBuyMagic, POSITION_TYPE_BUY))
      {
         CloseBasket(InpBuyMagic, POSITION_TYPE_BUY, "basket_tp", false);
         SendTelegramEvent("Basket TP Close", 0.0);
         return;
      }
      if(InpMaxDrawdownMoney > 0.0 && profit <= -InpMaxDrawdownMoney)
      {
         const bool pauseAfterClose = (InpMaxDdResumeMode != MAX_DD_CONTINUE_TRADING);
         const string ddAction = (InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY
            ? "close_and_pause_next_day"
            : "close_and_pause_manual");
         CloseBasket(InpBuyMagic, POSITION_TYPE_BUY, "max_dd", pauseAfterClose);
         SendTelegramEvent("Max DD Hit", 0.0);
         Print("Max DD hit on BUY basket. Action=", (pauseAfterClose ? ddAction : "close_and_continue"));
         return;
      }
   }

   const int sellCount = CountPositions(InpSellMagic, POSITION_TYPE_SELL);
   if(sellCount > 0)
   {
      const double profit = BasketProfit(InpSellMagic, POSITION_TYPE_SELL);
      if(BasketTpHit(InpSellMagic, POSITION_TYPE_SELL))
      {
         CloseBasket(InpSellMagic, POSITION_TYPE_SELL, "basket_tp", false);
         SendTelegramEvent("Basket TP Close", 0.0);
         return;
      }
      if(InpMaxDrawdownMoney > 0.0 && profit <= -InpMaxDrawdownMoney)
      {
         const bool pauseAfterClose = (InpMaxDdResumeMode != MAX_DD_CONTINUE_TRADING);
         const string ddAction = (InpMaxDdResumeMode == MAX_DD_PAUSE_NEXT_DAY
            ? "close_and_pause_next_day"
            : "close_and_pause_manual");
         CloseBasket(InpSellMagic, POSITION_TYPE_SELL, "max_dd", pauseAfterClose);
         SendTelegramEvent("Max DD Hit", 0.0);
         Print("Max DD hit on SELL basket. Action=", (pauseAfterClose ? ddAction : "close_and_continue"));
         return;
      }
   }
}

void ManageGrid()
{
   if(!TryResumeAfterMaxDd())
      return;
   if(g_pausedByMaxDd)
      return;
   if(!IsNewBar())
      return;

   if(!SpreadOK())
      return;

   const int buyCount = CountPositions(InpBuyMagic, POSITION_TYPE_BUY);
   const int sellCount = CountPositions(InpSellMagic, POSITION_TYPE_SELL);

   if(buyCount > 0 && sellCount > 0)
      return;

   if(buyCount > 0)
   {
      double nextLot = 0.0;
      if(!GetLayerLot(buyCount, nextLot))
         return;

      double anchorPrice = 0.0;
      if(!GridAnchorPrice(InpBuyMagic, POSITION_TYPE_BUY, anchorPrice))
         return;

      const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      if(bid > 0.0 && bid <= anchorPrice - InpGridDistance)
         OpenMarket(true, nextLot, "XAU_StochTrendGridBuy");
      return;
   }

   if(sellCount > 0)
   {
      double nextLot = 0.0;
      if(!GetLayerLot(sellCount, nextLot))
         return;

      double anchorPrice = 0.0;
      if(!GridAnchorPrice(InpSellMagic, POSITION_TYPE_SELL, anchorPrice))
         return;

      const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      if(ask > 0.0 && ask >= anchorPrice + InpGridDistance)
         OpenMarket(false, nextLot, "XAU_StochTrendGridSell");
   }
}

bool BuySignal()
{
   if(InpTradeMode == TRADE_SELL_ONLY)
      return false;

   if(!BuyTrendSideOK(1))
      return false;
   if(!BuyTrendSideOK(0))
      return false;
   if(UseStochasticDecision())
      return BuyDecisionOK_Stochastic();

   return false;
}

bool SellSignal()
{
   if(InpTradeMode == TRADE_BUY_ONLY)
      return false;

   if(!SellTrendSideOK(1))
      return false;
   if(!SellTrendSideOK(0))
      return false;
   if(UseStochasticDecision())
      return SellDecisionOK_Stochastic();

   return false;
}

void CheckFirstEntryOnNewBar()
{
   if(!TryResumeAfterMaxDd())
      return;
   if(IsFirstEntryPausedByTime())
      return;
   if(!SpreadOK())
      return;
   if(CountFirstEntryPositionsForCurrentMode() > 0)
      return;

   const datetime currentBarTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(currentBarTime <= 0)
      return;
   if(g_lastFirstEntryBarTime == currentBarTime)
      return;

   double firstLot = 0.0;
   if(!GetLayerLot(0, firstLot))
      return;

   if(BuySignal())
   {
      OpenMarket(true, firstLot, "XAU_StochTrendFirstBuy");
      return;
   }

   if(SellSignal())
      OpenMarket(false, firstLot, "XAU_StochTrendFirstSell");
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
      Print("XAU_StochTrend requires an MT5 hedging account.");
      return INIT_FAILED;
   }

   if(InpTrendEMAPeriod <= 0 || InpFastMAPeriod <= 0 || InpSlowMAPeriod <= 0 || InpKPeriod <= 0 || InpDPeriod <= 0 || InpSlowing <= 0)
   {
      Print("Invalid indicator period input.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpGridDistance <= 0.0)
   {
      Print("Invalid money management or grid input.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!ParseLotTable())
   {
      Print("Invalid lot table. Use format like: 0.10;0.20;0.40;0.80");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!UseTrendFilter())
      Print("Warning: Trend Filter is disabled. Decision Indicator will be used without trend direction filter.");

   const int trendPeriod = (UseSingleEmaTrend() ? InpTrendEMAPeriod : InpFastMAPeriod);
   g_fastMaHandle = iMA(g_symbol, PERIOD_CURRENT, trendPeriod, 0, MaMethod(), PRICE_CLOSE);
   g_slowMaHandle = iMA(g_symbol, PERIOD_CURRENT, InpSlowMAPeriod, 0, MaMethod(), PRICE_CLOSE);
   if(UseStochasticDecision())
      g_stochHandle = iStochastic(g_symbol, PERIOD_CURRENT, InpKPeriod, InpDPeriod, InpSlowing, MODE_SMA, STO_LOWHIGH);

   const bool indicatorHandlesOK =
      (g_fastMaHandle != INVALID_HANDLE &&
       g_slowMaHandle != INVALID_HANDLE &&
       (!UseStochasticDecision() || g_stochHandle != INVALID_HANDLE));

   if(!indicatorHandlesOK)
   {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   Print("XAU_StochTrend initialized | symbol=", g_symbol,
         " | MA type=", (InpMovingAverageType == MA_TYPE_EXPONENTIAL ? "EMA" : "SMA"),
         " | trendMode=", (InpTrendFilterMode == TREND_FILTER_OFF ? "OFF" : (InpTrendFilterMode == TREND_FILTER_SINGLE_EMA ? "SINGLE_EMA" : "DOUBLE_EMA")),
         " | trendPeriod=", DoubleToString(trendPeriod, 0),
         " | stochEntryMode=", (InpStochEntryMode == STOCH_ENTRY_ON_CROSS ? "ON_CROSS" : "AFTER_CANDLE_CLOSE"),
         " | grid=", DoubleToString(InpGridDistance, 2),
         " | lotLayers=", (string)ArraySize(g_lotTable),
         " | basketTPMode=", (InpBasketTpMode == BASKET_TP_TOTAL_LOT ? "TOTAL_LOT" : "BASE_LOT"),
         " | basketTPPriceMove=", DoubleToString(InpBasketTpPriceMove, 2));

   if(InpUseCloseLock && InpCloseLockTimerMs > 0)
      EventSetMillisecondTimer(InpCloseLockTimerMs);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(InpUseCloseLock && InpCloseLockTimerMs > 0)
      EventKillTimer();

   if(g_fastMaHandle != INVALID_HANDLE) IndicatorRelease(g_fastMaHandle);
   if(g_slowMaHandle != INVALID_HANDLE) IndicatorRelease(g_slowMaHandle);
   if(g_stochHandle != INVALID_HANDLE) IndicatorRelease(g_stochHandle);
}

void OnTimer()
{
   ProcessCloseLock();
}

void OnTick()
{
   if(_Symbol != g_symbol)
      return;
   if(!IsTradeAllowed())
      return;

   UpdateStochasticPendingCross();

   if(ProcessCloseLock())
      return;

   ManageBasketRiskAndExit();
   if(ProcessCloseLock())
      return;

   ManageGrid();

   CheckFirstEntryOnNewBar();
}
