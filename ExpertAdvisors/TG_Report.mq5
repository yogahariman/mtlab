//+------------------------------------------------------------------+
//| TG_Report.mq5                                                    |
//| Send Telegram notification when a position is closed              |
//| Tools -> Options -> Expert Advisors -> Allow WebRequest URL:     |
//| https://api.telegram.org                                         |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.06"
#property strict

input group "Telegram"
input string InpTelegramBotToken        = "8383407093:AAFGHJ6oBVHtvRsJel2NQUOklbeOwtxtdVk"; // Telegram bot token
input string InpTelegramChatId          = "1448627275"; // Telegram chat id
input int    InpTelegramDelaySeconds    = 5; // Delay before sending Telegram message

string g_pendingMessages[];
datetime g_pendingSendTimes[];

bool IsTesterRun()
{
   return (MQLInfoInteger(MQL_TESTER) != 0);
}

string UrlEncode(const string src)
{
   string out = "";
   char bytes[];
   const int copied = StringToCharArray(src, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(copied <= 1)
      return out;

   // copied includes null-terminator, encode only data bytes.
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
      else if(c <= 255)
         out += StringFormat("%%%02X", (int)c);
      else
         out += "%3F";
   }
   return out;
}

bool SendTelegramMessage(const string text)
{
   if(IsTesterRun())
      return false;

   string botToken = InpTelegramBotToken;
   StringTrimLeft(botToken);
   StringTrimRight(botToken);

   string chatId = InpTelegramChatId;
   StringTrimLeft(chatId);
   StringTrimRight(chatId);

   if(StringLen(botToken) == 0 || StringLen(chatId) == 0)
   {
      Print("Telegram skip | token/chat_id empty");
      return false;
   }

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
   const string responseBody = CharArrayToString(result, 0, -1, CP_UTF8);
   if(code == -1)
   {
      Print("Telegram fail | err=", GetLastError(),
            " | allow_url=https://api.telegram.org");
      return false;
   }

   if(code < 200 || code >= 300)
   {
      Print("Telegram fail | http_code=", code,
            " | response=", responseBody);
      return false;
   }

   Print("Telegram OK | message sent");
   return true;
}

void QueueTelegramMessage(const string text)
{
   const int index = ArraySize(g_pendingMessages);
   ArrayResize(g_pendingMessages, index + 1);
   ArrayResize(g_pendingSendTimes, index + 1);
   g_pendingMessages[index] = text;
   g_pendingSendTimes[index] = TimeLocal() + MathMax(0, InpTelegramDelaySeconds);
}

void ProcessPendingMessages()
{
   const datetime nowTime = TimeLocal();
   for(int i = ArraySize(g_pendingMessages) - 1; i >= 0; i--)
   {
      if(nowTime < g_pendingSendTimes[i])
         continue;
      SendTelegramMessage(g_pendingMessages[i]);
      const int last = ArraySize(g_pendingMessages) - 1;
      if(i != last)
      {
         g_pendingMessages[i] = g_pendingMessages[last];
         g_pendingSendTimes[i] = g_pendingSendTimes[last];
      }
      ArrayResize(g_pendingMessages, last);
      ArrayResize(g_pendingSendTimes, last);
   }
}

datetime DayStartFromTime(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

datetime WeekStartFromTime(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   dt.day -= (dt.day_of_week + 6) % 7;
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

double ClosedProfit(const datetime fromTime, const datetime toTime)
{
   double total = 0.0;
   if(!HistorySelect(fromTime, toTime))
      return 0.0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      const long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      const long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if((type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) ||
         (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT))
         continue;
      total += HistoryDealGetDouble(ticket, DEAL_PROFIT) +
               HistoryDealGetDouble(ticket, DEAL_SWAP) +
               HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return total;
}

datetime HeartbeatTime()
{
   datetime nowTime = TimeTradeServer();
   if(nowTime <= 0)
      nowTime = TimeLocal();
   return nowTime;
}

string PendingOrderTypeName(const ENUM_ORDER_TYPE type)
{
   switch(type)
   {
      case ORDER_TYPE_BUY_LIMIT:  return "BUY LIMIT";
      case ORDER_TYPE_SELL_LIMIT: return "SELL LIMIT";
      case ORDER_TYPE_BUY_STOP:   return "BUY STOP";
      case ORDER_TYPE_SELL_STOP:  return "SELL STOP";
      case ORDER_TYPE_BUY_STOP_LIMIT:  return "BUY STOP LIMIT";
      case ORDER_TYPE_SELL_STOP_LIMIT: return "SELL STOP LIMIT";
   }
   return "PENDING";
}

int OnInit()
{
   if(!EventSetTimer(1))
      return INIT_FAILED;
   Print("Telegram close reporter init OK | delay_seconds=",
         (string)MathMax(0, InpTelegramDelaySeconds),
         " | allow_url=https://api.telegram.org");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   ProcessPendingMessages();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(IsTesterRun())
      return;

   if(trans.type == TRADE_TRANSACTION_ORDER_ADD && trans.order > 0 &&
      OrderSelect(trans.order))
   {
      const ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT ||
         orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP ||
         orderType == ORDER_TYPE_BUY_STOP_LIMIT || orderType == ORDER_TYPE_SELL_STOP_LIMIT)
      {
         const string symbol = OrderGetString(ORDER_SYMBOL);
         const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         const double price = OrderGetDouble(ORDER_PRICE_OPEN);
         const double sl = OrderGetDouble(ORDER_SL);
         const double tp = OrderGetDouble(ORDER_TP);
         const string msg = "Broker: " + AccountInfoString(ACCOUNT_COMPANY) + "\n" +
            PendingOrderTypeName(orderType) + " @" + DoubleToString(price, digits) +
            " SL:" + DoubleToString(sl, digits) +
            " TP:" + DoubleToString(tp, digits);
         QueueTelegramMessage(msg);
      }
      return;
   }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   const ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal))
      return;

   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   const long type = HistoryDealGetInteger(deal, DEAL_TYPE);
   if((entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) ||
      (type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL))
      return;

   const string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
   const double dealNet = HistoryDealGetDouble(deal, DEAL_PROFIT) +
      HistoryDealGetDouble(deal, DEAL_SWAP) +
      HistoryDealGetDouble(deal, DEAL_COMMISSION);
   const string dealNetSign = (dealNet >= 0.0 ? "+" : "");
   const datetime nowTime = HeartbeatTime();
   const double daily = ClosedProfit(DayStartFromTime(nowTime), nowTime);
   const double weekly = ClosedProfit(WeekStartFromTime(nowTime), nowTime);
   const double all = ClosedProfit(0, nowTime);
   const string dailySign = (daily >= 0.0 ? "+" : "");
   const string weeklySign = (weekly >= 0.0 ? "+" : "");
   const string allSign = (all >= 0.0 ? "+" : "");
   const string msg = "Broker: " + AccountInfoString(ACCOUNT_COMPANY) + "\n" +
      "Close: " + dealNetSign +
      DoubleToString(dealNet, 2) + " " + accountCurrency + "\n" +
      "Profit: " + dailySign + DoubleToString(daily, 2) + " / " +
      weeklySign + DoubleToString(weekly, 2) + " / " +
      allSign + DoubleToString(all, 2);

   QueueTelegramMessage(msg);
}
