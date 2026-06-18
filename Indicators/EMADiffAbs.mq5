//+------------------------------------------------------------------+
//|                                                  EMADiffAbs.mq5  |
//|                 absolute EMA fast - EMA slow subwindow          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#property indicator_separate_window
#property indicator_buffers 1
#property indicator_plots   1
#property indicator_label1  "EMADiffAbs"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDeepSkyBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

input int    InpFastEmaPeriod   = 3;      // Fast EMA period
input int    InpSlowEmaPeriod   = 120;    // Slow EMA period
input bool   InpShowLevels      = true;   // Show dashed levels like RSI
input double InpLevel1          = 8.0;    // Level 1 in price
input double InpLevel2          = 21.0;   // Level 2 in price
input double InpLevel3          = 34.0;   // Level 3 in price
input double InpLevel4          = 55.0;   // Level 4 in price

double g_diffBuffer[];
int    g_fastHandle = INVALID_HANDLE;
int    g_slowHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEmaPeriod < 1 || InpSlowEmaPeriod < 1)
   {
      Print("Init fail | EMA periods must be >= 1");
      return INIT_FAILED;
   }

   if(InpFastEmaPeriod >= InpSlowEmaPeriod)
   {
      Print("Init fail | Fast EMA must be smaller than Slow EMA");
      return INIT_FAILED;
   }

   SetIndexBuffer(0, g_diffBuffer, INDICATOR_DATA);
   ArraySetAsSeries(g_diffBuffer, true);

   PlotIndexSetString(0, PLOT_LABEL, "EMADiffAbs(" + (string)InpFastEmaPeriod + "," + (string)InpSlowEmaPeriod + ")");
   IndicatorSetString(INDICATOR_SHORTNAME, "EMADiffAbs(" + (string)InpFastEmaPeriod + "," + (string)InpSlowEmaPeriod + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, 1);
   IndicatorSetDouble(INDICATOR_MINIMUM, 0.0);

   if(InpShowLevels)
   {
      IndicatorSetInteger(INDICATOR_LEVELS, 4);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, 0.0);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, InpLevel1);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, InpLevel2);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 3, InpLevel3);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 4, InpLevel4);
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrSilver);
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrSilver);
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrSilver);
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, 3, clrSilver);
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, 4, clrSilver);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DASH);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DASH);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_DASH);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, 3, STYLE_DASH);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, 4, STYLE_DASH);
      IndicatorSetInteger(INDICATOR_LEVELWIDTH, 0, 1);
      IndicatorSetInteger(INDICATOR_LEVELWIDTH, 1, 1);
      IndicatorSetInteger(INDICATOR_LEVELWIDTH, 2, 1);
      IndicatorSetInteger(INDICATOR_LEVELWIDTH, 3, 1);
      IndicatorSetInteger(INDICATOR_LEVELWIDTH, 4, 1);
   }
   else
   {
      IndicatorSetInteger(INDICATOR_LEVELS, 0);
   }

   g_fastHandle = iMA(_Symbol, PERIOD_CURRENT, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_fastHandle == INVALID_HANDLE)
   {
      Print("Init fail | cannot create fast EMA handle");
      return INIT_FAILED;
   }

   g_slowHandle = iMA(_Symbol, PERIOD_CURRENT, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_slowHandle == INVALID_HANDLE)
   {
      Print("Init fail | cannot create slow EMA handle");
      IndicatorRelease(g_fastHandle);
      g_fastHandle = INVALID_HANDLE;
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_fastHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_fastHandle);
      g_fastHandle = INVALID_HANDLE;
   }

   if(g_slowHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_slowHandle);
      g_slowHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Custom indicator calculation function                            |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < InpSlowEmaPeriod)
      return 0;

   double fastEma[];
   double slowEma[];
   ArrayResize(fastEma, rates_total);
   ArrayResize(slowEma, rates_total);
   ArraySetAsSeries(fastEma, true);
   ArraySetAsSeries(slowEma, true);

   const int fastCopied = CopyBuffer(g_fastHandle, 0, 0, rates_total, fastEma);
   const int slowCopied = CopyBuffer(g_slowHandle, 0, 0, rates_total, slowEma);
   if(fastCopied <= 0 || slowCopied <= 0)
   {
      Print("Calculate WARN | CopyBuffer failed, err=", GetLastError());
      return prev_calculated;
   }

   const int available = MathMin(fastCopied, slowCopied);
   const int limit = (prev_calculated == 0 ? available - 1 : MathMin(available - 1, rates_total - prev_calculated));
   for(int i = limit; i >= 0; --i)
   {
      if(i >= available)
      {
         g_diffBuffer[i] = EMPTY_VALUE;
         continue;
      }

      g_diffBuffer[i] = MathAbs(fastEma[i] - slowEma[i]);
   }

   return rates_total;
}
//+------------------------------------------------------------------+
