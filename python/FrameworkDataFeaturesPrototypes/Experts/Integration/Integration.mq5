//+------------------------------------------------------------------+
//|                                                  Integration.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2000-2026, MetaQuotes Ltd."
#property link        "https://www.mql5.com"
#property version      "1.00"
#property description "ONNX RendomForestRegression"
//+------------------------------------------------------------------+
//| Includes                                                         |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Indicators\Trend.mqh>
#include <Indicators\Oscilators.mqh>
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
#define TimeFrame   PERIOD_H1
#define threshold   0.00014932
#define direction   1
#resource "rf_model.onnx" as uchar model[]
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CSymbolInfo          Symb;
CTrade               Trade;
CiMA                 ciSMA;
CiMACD               ciMACD[4];
//---
vector<float>        Rates;
vector<float>        Inputs(28);
vector<float>        Forecast(1);
long                 onnx;
double               Balance, Equity;
matrix<double>       macd_set = {{8, 16, 6}, {12, 24, 9}, {36, 72, 27}, {48, 96, 36} };
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   if(!Symb.Name("EURUSD_i"))
      return INIT_FAILED;
   Symb.Refresh();
//---
   if(!Trade.SetTypeFillingBySymbol(Symb.Name()))
      return INIT_FAILED;
//--- load models
   onnx = OnnxCreateFromBuffer(model, ONNX_DEFAULT);
   if(onnx == INVALID_HANDLE)
     {
      Print("OnnxCreateFromBuffer error ", GetLastError());
      return INIT_FAILED;
     }
   const ulong input_state[] = {1, Inputs.Size()};
   if(!OnnxSetInputShape(onnx, 0, input_state))
     {
      Print("OnnxSetInputShape error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   const ulong output_forecast[] = {1, Forecast.Size()};
   if(!OnnxSetOutputShape(onnx, 0, output_forecast))
     {
      Print("OnnxSetOutputShape error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
//--- Indicators
   if(!ciSMA.Create(Symb.Name(), TimeFrame, 12, 0, MODE_SMA, PRICE_CLOSE))
     {
      Print("SMA create error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   ciSMA.BufferResize(2);
   for(uint i = 0; i < ciMACD.Size(); i++)
     {
      if(!ciMACD[i].Create(Symb.Name(), TimeFrame, int(macd_set[i, 0]), int(macd_set[i, 1]), int(macd_set[i, 2]), PRICE_CLOSE))
        {
         PrintFormat("MACD %d create error %d", i, GetLastError());
         OnnxRelease(onnx);
         return INIT_FAILED;
        }
      ciMACD[i].BufferResize(4);
     }
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   OnnxRelease(onnx);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
   if(!IsNewBar())
      return;
//---
   double buy_value = 0, sell_value = 0, buy_profit = 0, sell_profit = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      if(PositionGetSymbol(i) != Symb.Name())
         continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      switch((int)PositionGetInteger(POSITION_TYPE))
        {
         case POSITION_TYPE_BUY:
            buy_value += PositionGetDouble(POSITION_VOLUME);
            buy_profit += profit;
            break;
         case POSITION_TYPE_SELL:
            sell_value += PositionGetDouble(POSITION_VOLUME);
            sell_profit += profit;
            break;
        }
     }
//--- prepare input data
   /*
      Columns: ['last', 'last_11', 'last_last_11', 'SMA_12',
         'MACD_MAIN_08,16,06', 'DMACD_MAIN_08,16,06', 'MACD_SIGNAL_08,16,06', 'DMACD_SIGNAL_08,16,06', 'MACD_Sig_Main_08,16,06', 'DMACD_Sig_Main_08,16,06',
         'MACD_MAIN_12,24,09', 'DMACD_MAIN_12,24,09', 'MACD_SIGNAL_12,24,09', 'DMACD_SIGNAL_12,24,09', 'MACD_Sig_Main_12,24,09', 'DMACD_Sig_Main_12,24,09',
         'MACD_MAIN_36,72,27', 'DMACD_MAIN_36,72,27', 'MACD_SIGNAL_36,72,27', 'DMACD_SIGNAL_36,72,27', 'MACD_Sig_Main_36,72,27', 'DMACD_Sig_Main_36,72,27',
         'MACD_MAIN_48,96,36', 'DMACD_MAIN_48,96,36', 'MACD_SIGNAL_48,96,36', 'DMACD_SIGNAL_48,96,36', 'MACD_Sig_Main_48,96,36', 'DMACD_Sig_Main_48,96,36']
   */
   ciSMA.Refresh();
   for(uint i = 0; i < ciMACD.Size(); i++)
      ciMACD[i].Refresh();
   if(!Rates.CopyRates(Symb.Name(), TimeFrame, COPY_RATES_CLOSE, 1, 12))
     {
      Print("CopyRates error ", GetLastError());
      return;
     }
   Inputs[0] = float(Rates[11] - Rates[10]);
   Inputs[1] = float(Rates[11] - Rates[0]) / 11;
   Inputs[2] = float(Inputs[1] - Inputs[0]);
   Inputs[3] = float(ciSMA.Main(1));
   for(uint i = 0; i < ciMACD.Size(); i++)
     {
      Inputs[4 + i * 6] = float(ciMACD[i].Main(1));
      Inputs[5 + i * 6] = float(Inputs[4 + i * 6] - ciMACD[i].Main(2));
      Inputs[6 + i * 6] = float(ciMACD[i].Signal(1));
      Inputs[7 + i * 6] = float(Inputs[6 + i * 6] - ciMACD[i].Signal(2));
      Inputs[8 + i * 6] = Inputs[6 + i * 6] - Inputs[4 + i * 6];
      Inputs[9 + i * 6] = Inputs[7 + i * 6] - Inputs[5 + i * 6];
     }
//--- run the inference
//input_data.Assign(Rates);
   if(!OnnxRun(onnx, ONNX_LOGLEVEL_INFO, Inputs, Forecast))
     {
      Print("OnnxRun error ", GetLastError());
      return;
     }
//---
   Symb.Refresh();
   Symb.RefreshRates();
   double min_lot = Symb.LotsMin();
   double step_lot = Symb.LotsStep();
   double stops = (MathMax(Symb.StopsLevel(), 1) + Symb.Spread()) * Symb.Point();
//--- buy control
   if(Forecast[0]*direction >= threshold)
     {
      double buy_lot = min_lot;
      if(buy_value <= 0)
         Trade.Buy(buy_lot, Symb.Name(), Symb.Ask(), 0, 0);
     }
   else
     {
      if(buy_value > 0)
         CloseByDirection(POSITION_TYPE_BUY);
     }
//--- sell control
   if(Forecast[0]*direction <= -threshold)
     {
      double sell_lot = min_lot;
      if(sell_value <= 0)
         Trade.Sell(sell_lot, Symb.Name(), Symb.Bid(), 0, 0);
     }
   else
     {
      if(sell_value > 0)
         CloseByDirection(POSITION_TYPE_SELL);
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBar(void)
  {
   static datetime last_bar = 0;
   if(last_bar >= iTime(Symb.Name(), TimeFrame, 0))
      return false;
//---
   last_bar = iTime(Symb.Name(), TimeFrame, 0);
   return true;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CloseByDirection(ENUM_POSITION_TYPE type)
  {
   int total = PositionsTotal();
   bool result = true;
   for(int i = total - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != Symb.Name())
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;
      result = (Trade.PositionClose(PositionGetInteger(POSITION_TICKET)) && result);
     }
//---
   return result;
  }
//+------------------------------------------------------------------+
