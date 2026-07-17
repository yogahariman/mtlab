//+------------------------------------------------------------------+
//|                                                     MAAngle.mq5  |
//|                EMA/SMA angle oscillator in a separate window     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hariman"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   1

//--- plot 1: MA angle line
#property indicator_label1  "MA Angle"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLime, clrTomato
#property indicator_style1  STYLE_SOLID
#property indicator_width1   2

enum EMAngleMaType
{
   MA_ANGLE_SMA = 0,
   MA_ANGLE_EMA = 1
};

input int           InpMAPeriod            = 20;     // MA period
input EMAngleMaType InpMAMethod            = MA_ANGLE_EMA; // MA type
input ENUM_APPLIED_PRICE InpAppliedPrice   = PRICE_CLOSE;   // Applied price
input int           InpLookbackBars        = 5;      // Bars used for slope
input double        InpScalePointsPerBar   = 100.0;   // Bigger = flatter angle
input bool          InpShowLevels          = true;    // Show reference levels
input double        InpLevel1              = 15.0;    // Level 1
input double        InpLevel2              = 30.0;    // Level 2

double g_angleBuffer[];
double g_colorIndexBuffer[];
int    g_maHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpMAPeriod < 1)
   {
      Print("Init fail | MA period must be >= 1");
      return INIT_FAILED;
   }

   if(InpLookbackBars < 1)
   {
      Print("Init fail | Lookback bars must be >= 1");
      return INIT_FAILED;
   }

   if(InpScalePointsPerBar <= 0.0)
   {
      Print("Init fail | Scale points per bar must be > 0");
      return INIT_FAILED;
   }

   SetIndexBuffer(0, g_angleBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, g_colorIndexBuffer, INDICATOR_COLOR_INDEX);

   ArraySetAsSeries(g_angleBuffer, true);
   ArraySetAsSeries(g_colorIndexBuffer, true);

   PlotIndexSetString(0, PLOT_LABEL, "MAAngle(" + (string)InpMAPeriod + "," + (string)InpLookbackBars + ")");
   PlotIndexSetInteger(0, PLOT_COLOR_INDEXES, 2);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, clrLime);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, clrTomato);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpMAPeriod + InpLookbackBars);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      "MAAngle(" + (string)InpMAPeriod + "," + (string)InpLookbackBars + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, 2);
   IndicatorSetDouble(INDICATOR_MINIMUM, -90.0);
   IndicatorSetDouble(INDICATOR_MAXIMUM, 90.0);

   if(InpShowLevels)
   {
      IndicatorSetInteger(INDICATOR_LEVELS, 5);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, 0.0);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, InpLevel1);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, -InpLevel1);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 3, InpLevel2);
      IndicatorSetDouble(INDICATOR_LEVELVALUE, 4, -InpLevel2);

      for(int i = 0; i < 5; i++)
      {
         IndicatorSetInteger(INDICATOR_LEVELCOLOR, i, clrSilver);
         IndicatorSetInteger(INDICATOR_LEVELSTYLE, i, STYLE_DASH);
         IndicatorSetInteger(INDICATOR_LEVELWIDTH, i, 1);
      }
   }
   else
   {
      IndicatorSetInteger(INDICATOR_LEVELS, 0);
   }

   ENUM_MA_METHOD maMethod = (InpMAMethod == MA_ANGLE_SMA ? MODE_SMA : MODE_EMA);
   g_maHandle = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriod, 0, maMethod, InpAppliedPrice);
   if(g_maHandle == INVALID_HANDLE)
   {
      Print("Init fail | cannot create MA handle");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_maHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_maHandle);
      g_maHandle = INVALID_HANDLE;
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
   if(rates_total < InpMAPeriod + InpLookbackBars)
      return 0;

   double ma[];
   ArrayResize(ma, rates_total);
   ArraySetAsSeries(ma, true);

   const int copied = CopyBuffer(g_maHandle, 0, 0, rates_total, ma);
   if(copied <= 0)
   {
      Print("Calculate WARN | CopyBuffer failed, err=", GetLastError());
      return prev_calculated;
   }

   const double radToDeg = 180.0 / 3.14159265358979323846;
   const int limit = MathMin(rates_total - 1, copied - 1);

   for(int i = rates_total - 1; i >= 0; --i)
   {
      if(i > limit || (i + InpLookbackBars) > limit)
      {
         g_angleBuffer[i] = EMPTY_VALUE;
         g_colorIndexBuffer[i] = 0;
         continue;
      }

      const double maNow = ma[i];
      const double maPast = ma[i + InpLookbackBars];
      if(maNow == EMPTY_VALUE || maPast == EMPTY_VALUE)
      {
         g_angleBuffer[i] = EMPTY_VALUE;
         g_colorIndexBuffer[i] = 0;
         continue;
      }

      const double deltaPointsPerBar = (maNow - maPast) / ((double)InpLookbackBars * _Point);
      const double normalizedSlope = deltaPointsPerBar / InpScalePointsPerBar;
      const double angleDeg = MathArctan(normalizedSlope) * radToDeg;

      g_angleBuffer[i] = angleDeg;
      g_colorIndexBuffer[i] = (angleDeg >= 0.0 ? 0 : 1);
   }

   return rates_total;
}
//+------------------------------------------------------------------+
