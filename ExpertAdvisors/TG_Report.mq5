//+------------------------------------------------------------------+
//| TG_Report.mq5                                                    |
//| Standalone MT5 floating profit reporter for Telegram             |
//| Tools -> Options -> Expert Advisors -> Allow WebRequest URL:     |
//| https://api.telegram.org                                         |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

input group "Telegram"
input string InpTelegramBotToken        = "8383407093:AAFGHJ6oBVHtvRsJel2NQUOklbeOwtxtdVk"; // Telegram bot token
input string InpTelegramChatId          = "1448627275"; // Telegram chat id
input int    InpReportIntervalMinutes   = 15; // Report interval in minutes

datetime g_lastReportTime = 0;
datetime g_lastReportAttemptTime = 0;

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

datetime DayStartFromTime(const datetime whenTime)
{
   MqlDateTime dt;
   TimeToStruct(whenTime, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

double TodayClosedProfit(const datetime nowTime)
{
   const datetime dayStart = DayStartFromTime(nowTime);
   double total = 0.0;

   if(!HistorySelect(dayStart, nowTime))
   {
      Print("HistorySelect fail | from=", TimeToString(dayStart),
            " | to=", TimeToString(nowTime),
            " | err=", GetLastError());
      return 0.0;
   }

   const int dealsTotal = HistoryDealsTotal();
   for(int i = 0; i < dealsTotal; i++)
   {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      const long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;

      const long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      total += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      total += HistoryDealGetDouble(ticket, DEAL_SWAP);
      total += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
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

void TrySendFloatingReport()
{
   if(IsTesterRun())
      return;
   if(InpReportIntervalMinutes <= 0)
      return;

   const datetime nowTime = HeartbeatTime();
   const int intervalSec = InpReportIntervalMinutes * 60;
   const int attemptCooldownSec = 60;

   if(g_lastReportAttemptTime > 0 &&
      (nowTime - g_lastReportAttemptTime) < attemptCooldownSec)
      return;
   if(g_lastReportTime > 0 && (nowTime - g_lastReportTime) < intervalSec)
      return;

   g_lastReportAttemptTime = nowTime;

   const string accountName = AccountInfoString(ACCOUNT_NAME);
   const double floatingProfit = AccountInfoDouble(ACCOUNT_PROFIT);
   const double todayClosedProfit = TodayClosedProfit(nowTime);
   const string floatingSign = (floatingProfit >= 0.0 ? "+" : "");
   const string todayClosedSign = (todayClosedProfit >= 0.0 ? "+" : "");
   const string msg =
      "Account: " + accountName + "\n" +
      "Floating Profit: " + floatingSign + DoubleToString(floatingProfit, 2) + "\n" +
      "Today Closed Profit: " + todayClosedSign + DoubleToString(todayClosedProfit, 2);

   if(SendTelegramMessage(msg))
      g_lastReportTime = nowTime;
}

int OnInit()
{
   if(InpReportIntervalMinutes <= 0)
   {
      Print("Init fail | report interval must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!EventSetTimer(1))
   {
      Print("Init fail | timer setup failed");
      return INIT_FAILED;
   }

   Print("Telegram floating reporter init OK | interval_minutes=",
         (string)InpReportIntervalMinutes,
         " | allow_url=https://api.telegram.org");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   TrySendFloatingReport();
}

void OnTick()
{
   TrySendFloatingReport();
}
