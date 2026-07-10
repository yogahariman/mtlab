//+------------------------------------------------------------------+
//|                                                   Supertrend.mq5 |
//|                        ATR-based trend indicator for MT5         |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   3

//--- plot 1: color supertrend line
#property indicator_label1  "Supertrend"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLime, clrTomato
#property indicator_style1  STYLE_SOLID
#property indicator_width1   2

//--- plot 2: bullish flip arrow
#property indicator_label2  "Supertrend Buy"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrDodgerBlue
#property indicator_style2  STYLE_SOLID
#property indicator_width2   2

//--- plot 3: bearish flip arrow
#property indicator_label3  "Supertrend Sell"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrOrangeRed
#property indicator_style3   STYLE_SOLID
#property indicator_width3   2

input int    InpAtrPeriod        = 10;   // ATR period
input double InpMultiplier       = 3.0;  // ATR multiplier
input bool   InpShowArrows       = true; // Show flip arrows
input int    InpArrowOffsetPts   = 20;   // Arrow offset in points

double g_supertrendBuffer[];
double g_colorIndexBuffer[];
double g_buyArrowBuffer[];
double g_sellArrowBuffer[];

int g_atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpAtrPeriod < 1)
   {
      Print("Init fail | ATR period must be >= 1");
      return INIT_FAILED;
   }

   if(InpMultiplier <= 0.0)
   {
      Print("Init fail | ATR multiplier must be > 0");
      return INIT_FAILED;
   }

   SetIndexBuffer(0, g_supertrendBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, g_colorIndexBuffer, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, g_buyArrowBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, g_sellArrowBuffer, INDICATOR_DATA);

   ArraySetAsSeries(g_supertrendBuffer, true);
   ArraySetAsSeries(g_colorIndexBuffer, true);
   ArraySetAsSeries(g_buyArrowBuffer, true);
   ArraySetAsSeries(g_sellArrowBuffer, true);

   PlotIndexSetInteger(1, PLOT_ARROW, 233); // Wingdings up arrow
   PlotIndexSetInteger(2, PLOT_ARROW, 234); // Wingdings down arrow

   PlotIndexSetInteger(0, PLOT_COLOR_INDEXES, 2);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, clrLime);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, clrTomato);
   PlotIndexSetString(0, PLOT_LABEL, "Supertrend");
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, InpAtrPeriod);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, InpAtrPeriod);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      "Supertrend(" + (string)InpAtrPeriod + "," + DoubleToString(InpMultiplier, 2) + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Init fail | cannot create ATR handle");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
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
   if(rates_total < InpAtrPeriod + 2)
      return 0;

   double atr[];
   double finalUpper[];
   double finalLower[];
   int    trend[];

   ArrayResize(atr, rates_total);
   ArrayResize(finalUpper, rates_total);
   ArrayResize(finalLower, rates_total);
   ArrayResize(trend, rates_total);

   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(finalUpper, true);
   ArraySetAsSeries(finalLower, true);
   ArraySetAsSeries(trend, true);

   const int copied = CopyBuffer(g_atrHandle, 0, 0, rates_total, atr);
   if(copied <= 0)
   {
      Print("Calculate WARN | CopyBuffer failed, err=", GetLastError());
      return prev_calculated;
   }

   if(copied < rates_total)
   {
      Print("Calculate WARN | ATR buffer is shorter than rates_total");
      return prev_calculated;
   }

   for(int i = rates_total - 1; i >= 0; --i)
   {
      g_supertrendBuffer[i] = EMPTY_VALUE;
      g_colorIndexBuffer[i] = 0;
      g_buyArrowBuffer[i] = EMPTY_VALUE;
      g_sellArrowBuffer[i] = EMPTY_VALUE;

      const double middle = (high[i] + low[i]) * 0.5;
      const double basicUpper = middle + InpMultiplier * atr[i];
      const double basicLower = middle - InpMultiplier * atr[i];

      if(i == rates_total - 1)
      {
         finalUpper[i] = basicUpper;
         finalLower[i] = basicLower;
         trend[i] = (close[i] >= middle ? 1 : -1);
      }
      else
      {
         const int prev = i + 1;

         if(basicUpper < finalUpper[prev] || close[prev] > finalUpper[prev])
            finalUpper[i] = basicUpper;
         else
            finalUpper[i] = finalUpper[prev];

         if(basicLower > finalLower[prev] || close[prev] < finalLower[prev])
            finalLower[i] = basicLower;
         else
            finalLower[i] = finalLower[prev];

         trend[i] = trend[prev];
         if(trend[prev] < 0 && close[i] > finalUpper[prev])
            trend[i] = 1;
         else if(trend[prev] > 0 && close[i] < finalLower[prev])
            trend[i] = -1;
      }

      if(trend[i] > 0)
      {
         g_supertrendBuffer[i] = finalLower[i];
         g_colorIndexBuffer[i] = 0;
      }
      else
      {
         g_supertrendBuffer[i] = finalUpper[i];
         g_colorIndexBuffer[i] = 1;
      }

      if(InpShowArrows && i < rates_total - 1)
      {
         if(trend[i] > 0 && trend[i + 1] < 0)
            g_buyArrowBuffer[i] = low[i] - (InpArrowOffsetPts * _Point);
         else if(trend[i] < 0 && trend[i + 1] > 0)
            g_sellArrowBuffer[i] = high[i] + (InpArrowOffsetPts * _Point);
      }
   }

   if(!InpShowArrows)
   {
      for(int i = rates_total - 1; i >= 0; --i)
      {
         g_buyArrowBuffer[i] = EMPTY_VALUE;
         g_sellArrowBuffer[i] = EMPTY_VALUE;
      }
   }

   return rates_total;
}
//+------------------------------------------------------------------+
