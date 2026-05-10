//+------------------------------------------------------------------+
//|                                                03_XAU_ML_ONNX_EA.mq5 |
//|                  XAU multi-timeframe machine-learning ONNX EA      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "Runs a multi-timeframe ONNX model on every closed M5 candle."

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Indicators/Trend.mqh>
#include <Indicators/Oscilators.mqh>

#define ENTRY_TIMEFRAME PERIOD_M5
#define TIMEFRAME_COUNT 5
#define FEATURES_PER_TIMEFRAME 14
#define TIME_FEATURE_COUNT 4
#define FEATURE_COUNT 74

#resource "model_xau_ml.onnx" as uchar ModelBuffer[]

input string InpSymbol = "XAUUSD";
input double InpLots = 0.01;
input double InpThreshold = 0.50;
input int InpDirection = 1;
input int InpStopLossPoints = 800;
input int InpTakeProfitPoints = 1200;
input int InpMaxSpreadPoints = 80;
input ulong InpMagic = 26051001;

CTrade Trade;
CSymbolInfo Symb;
CiMA Sma12[TIMEFRAME_COUNT];
CiMA Sma48[TIMEFRAME_COUNT];
CiATR Atr14[TIMEFRAME_COUNT];
CiRSI Rsi14[TIMEFRAME_COUNT];
CiMACD Macd[TIMEFRAME_COUNT];

vector<float> Inputs(FEATURE_COUNT);
vector<float> Forecast(1);
long OnnxHandle = INVALID_HANDLE;

ENUM_TIMEFRAMES ModelTimeframes[TIMEFRAME_COUNT] = {
   PERIOD_M5,
   PERIOD_M15,
   PERIOD_H1,
   PERIOD_H4,
   PERIOD_D1
};

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Symb.Name(InpSymbol))
      return INIT_FAILED;
   Symb.Refresh();

   Trade.SetExpertMagicNumber(InpMagic);
   if(!Trade.SetTypeFillingBySymbol(Symb.Name()))
      return INIT_FAILED;

   OnnxHandle = OnnxCreateFromBuffer(ModelBuffer, ONNX_DEFAULT);
   if(OnnxHandle == INVALID_HANDLE)
     {
      Print("OnnxCreateFromBuffer error ", GetLastError());
      return INIT_FAILED;
     }

   const ulong input_shape[] = {1, FEATURE_COUNT};
   const ulong output_shape[] = {1, 1};
   if(!OnnxSetInputShape(OnnxHandle, 0, input_shape) ||
      !OnnxSetOutputShape(OnnxHandle, 0, output_shape))
     {
      Print("ONNX shape setup error ", GetLastError());
      OnnxRelease(OnnxHandle);
      return INIT_FAILED;
     }

   for(int i = 0; i < TIMEFRAME_COUNT; i++)
     {
      const ENUM_TIMEFRAMES tf = ModelTimeframes[i];
      if(!Sma12[i].Create(Symb.Name(), tf, 12, 0, MODE_SMA, PRICE_CLOSE) ||
         !Sma48[i].Create(Symb.Name(), tf, 48, 0, MODE_SMA, PRICE_CLOSE) ||
         !Atr14[i].Create(Symb.Name(), tf, 14) ||
         !Rsi14[i].Create(Symb.Name(), tf, 14, PRICE_CLOSE) ||
         !Macd[i].Create(Symb.Name(), tf, 12, 24, 9, PRICE_CLOSE))
        {
         PrintFormat("Indicator create error tf index %d error %d", i, GetLastError());
         OnnxRelease(OnnxHandle);
         return INIT_FAILED;
        }

      Sma12[i].BufferResize(3);
      Sma48[i].BufferResize(3);
      Atr14[i].BufferResize(3);
      Rsi14[i].BufferResize(3);
      Macd[i].BufferResize(3);
     }

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(OnnxHandle != INVALID_HANDLE)
      OnnxRelease(OnnxHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewEntryBar())
      return;

   Symb.Refresh();
   Symb.RefreshRates();
   if(Symb.Spread() > InpMaxSpreadPoints)
      return;

   if(!PrepareInputs())
      return;

   if(!OnnxRun(OnnxHandle, ONNX_NO_CONVERSION, Inputs, Forecast))
     {
      Print("OnnxRun error ", GetLastError());
      return;
     }

   const double signal = double(Forecast[0]) * InpDirection;
   if(signal >= InpThreshold)
      OpenOrFlip(POSITION_TYPE_BUY);
   else if(signal <= -InpThreshold)
      OpenOrFlip(POSITION_TYPE_SELL);
  }

//+------------------------------------------------------------------+
bool PrepareInputs()
  {
   int k = 0;
   datetime entry_closed_time = 0;

   for(int i = 0; i < TIMEFRAME_COUNT; i++)
     {
      if(!AppendTimeframeFeatures(i, k, entry_closed_time))
         return false;
     }

   MqlDateTime dt;
   TimeToStruct(entry_closed_time, dt);
   Inputs[k++] = float(MathSin(2.0 * M_PI * dt.hour / 24.0));
   Inputs[k++] = float(MathCos(2.0 * M_PI * dt.hour / 24.0));
   Inputs[k++] = float(MathSin(2.0 * M_PI * dt.day_of_week / 7.0));
   Inputs[k++] = float(MathCos(2.0 * M_PI * dt.day_of_week / 7.0));

   return k == FEATURE_COUNT;
  }

//+------------------------------------------------------------------+
bool AppendTimeframeFeatures(const int tf_index, int &k, datetime &entry_closed_time)
  {
   const ENUM_TIMEFRAMES tf = ModelTimeframes[tf_index];
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(Symb.Name(), tf, 1, 64, rates) < 64)
     {
      PrintFormat("CopyRates error tf index %d error %d", tf_index, GetLastError());
      return false;
     }

   Sma12[tf_index].Refresh();
   Sma48[tf_index].Refresh();
   Atr14[tf_index].Refresh();
   Rsi14[tf_index].Refresh();
   Macd[tf_index].Refresh();

   const double close1 = rates[0].close;
   const double open1 = rates[0].open;
   const double high1 = rates[0].high;
   const double low1 = rates[0].low;

   if(tf == ENTRY_TIMEFRAME)
      entry_closed_time = rates[0].time + PeriodSeconds(tf);

   double last_sum_3 = 0.0;
   for(int i = 0; i < 3; i++)
      last_sum_3 += rates[i].close - rates[i + 1].close;

   double last_sum_11 = 0.0;
   for(int i = 0; i < 11; i++)
      last_sum_11 += rates[i].close - rates[i + 1].close;

   double volume_sum_20 = 0.0;
   for(int i = 0; i < 20; i++)
      volume_sum_20 += double(rates[i].tick_volume);

   const double macd_main = Macd[tf_index].Main(1);
   const double macd_signal = Macd[tf_index].Signal(1);

   Inputs[k++] = float(rates[0].close - rates[1].close);
   Inputs[k++] = float(last_sum_3 / 3.0);
   Inputs[k++] = float(last_sum_11 / 11.0);
   Inputs[k++] = float(high1 - low1);
   Inputs[k++] = float(close1 - open1);
   Inputs[k++] = float(Atr14[tf_index].Main(1));
   Inputs[k++] = float(double(rates[0].tick_volume) / MathMax(volume_sum_20 / 20.0, 1.0));
   Inputs[k++] = float(close1 - Sma12[tf_index].Main(1));
   Inputs[k++] = float(close1 - Sma48[tf_index].Main(1));
   Inputs[k++] = float(Sma12[tf_index].Main(1) - Sma12[tf_index].Main(2));
   Inputs[k++] = float(Rsi14[tf_index].Main(1));
   Inputs[k++] = float(macd_main);
   Inputs[k++] = float(macd_signal);
   Inputs[k++] = float(macd_signal - macd_main);

   return true;
  }

//+------------------------------------------------------------------+
bool IsNewEntryBar()
  {
   static datetime last_bar_time = 0;
   const datetime bar_time = iTime(Symb.Name(), ENTRY_TIMEFRAME, 0);
   if(bar_time <= last_bar_time)
      return false;

   last_bar_time = bar_time;
   return true;
  }

//+------------------------------------------------------------------+
void OpenOrFlip(const ENUM_POSITION_TYPE desired_type)
  {
   bool has_desired = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != Symb.Name())
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pos_type == desired_type)
         has_desired = true;
      else
         Trade.PositionClose(PositionGetInteger(POSITION_TICKET));
     }

   if(has_desired)
      return;

   const double point = Symb.Point();
   if(desired_type == POSITION_TYPE_BUY)
     {
      const double sl = InpStopLossPoints > 0 ? Symb.Bid() - InpStopLossPoints * point : 0.0;
      const double tp = InpTakeProfitPoints > 0 ? Symb.Bid() + InpTakeProfitPoints * point : 0.0;
      Trade.Buy(InpLots, Symb.Name(), Symb.Ask(), sl, tp);
     }
   else
     {
      const double sl = InpStopLossPoints > 0 ? Symb.Ask() + InpStopLossPoints * point : 0.0;
      const double tp = InpTakeProfitPoints > 0 ? Symb.Ask() - InpTakeProfitPoints * point : 0.0;
      Trade.Sell(InpLots, Symb.Name(), Symb.Bid(), sl, tp);
     }
  }
//+------------------------------------------------------------------+
