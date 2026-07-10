//+------------------------------------------------------------------+
//|                                                MinuteCloseSymbol.mq5 |
//|               Marks closed bars at user-defined minute intervals   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1

#property indicator_label1  "MinuteClose"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDeepSkyBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

input int    InpMinuteStep           = 5;    // Mark every N-minute close (1..60)
input int    InpWingdingsCode        = 233;  // Common Wingdings arrow code (233 = up arrow)
input double InpOffsetPoints         = 20.0; // Vertical offset above candle high in points
input color  InpMarkerColor          = clrDeepSkyBlue;

double g_markerBuffer[];

//+------------------------------------------------------------------+
//| Check whether a bar close time matches the configured minute rule |
//+------------------------------------------------------------------+
bool IsTargetCloseMinute(const datetime close_time)
{
   if(InpMinuteStep <= 0 || InpMinuteStep > 60)
      return false;

   MqlDateTime dt;
   TimeToStruct(close_time, dt);

   return ((dt.min % InpMinuteStep) == 0);
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpMinuteStep <= 0 || InpMinuteStep > 60)
   {
      Print("Init fail | InpMinuteStep must be in range 1..60");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpWingdingsCode <= 0)
   {
      Print("Init fail | InpWingdingsCode must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, g_markerBuffer, INDICATOR_DATA);
   ArraySetAsSeries(g_markerBuffer, true);

   PlotIndexSetInteger(0, PLOT_ARROW, InpWingdingsCode);
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, 10);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, InpMarkerColor);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, 1);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      "MinuteCloseSymbol(" + (string)InpMinuteStep + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   return INIT_SUCCEEDED;
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
   if(rates_total < 2)
      return 0;

   const int period_seconds = PeriodSeconds(_Period);
   if(period_seconds <= 0)
      return prev_calculated;

   for(int i = rates_total - 1; i >= 0; --i)
   {
      g_markerBuffer[i] = EMPTY_VALUE;

      // Bar 0 is still forming, so we only mark bars that have already closed.
      if(i == 0)
         continue;

      const datetime close_time = time[i] + period_seconds;
      if(!IsTargetCloseMinute(close_time))
         continue;

      double mark_price = high[i] + (MathMax(InpOffsetPoints, 1.0) * _Point);

      g_markerBuffer[i] = mark_price;
   }

   return rates_total;
}
//+------------------------------------------------------------------+
