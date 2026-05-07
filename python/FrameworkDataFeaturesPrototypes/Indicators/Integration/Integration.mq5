//+------------------------------------------------------------------+
//|                                                  Integration.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2000-2026, MetaQuotes Ltd."
#property link        "https://www.mql5.com"
#property version      "1.00"
#property description "ONNX RendomForestRegression"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4
//--- plot Buy
#property indicator_label1  "BuyIn"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3
#property indicator_label2  "BuyOut"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrBlue
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3
//--- plot Sell
#property indicator_label3  "SellIn"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_style3  STYLE_SOLID
#property indicator_width3  3
#property indicator_label4  "SellOut"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_style4  STYLE_SOLID
#property indicator_width4  3
//---
#include <Indicators\Trend.mqh>
#include <Indicators\Oscilators.mqh>
//--- indicator buffers
double         BuyInBuffer[];
double         SellInBuffer[];
double         BuyOutBuffer[];
double         SellOutBuffer[];
//---
CiMA                 ciSMA;
CiMACD               ciMACD[4];
//---
vector<float>        Rates;
vector<float>        Inputs(28);
vector<float>        Forecast(1);
long                 onnx;
double               dLastValue;
bool                 Buy, Sell;
//---
#define threshold   0.00014932
#define direction   1
#define BufferSize  10000
#define ArrowShift  100
#resource "rf_model.onnx" as uchar model[]
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- indicator buffers mapping
   SetIndexBuffer(0, BuyInBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, BuyOutBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, SellInBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, SellOutBuffer, INDICATOR_DATA);
//--- setting a code from the Wingdings charset as the property of PLOT_ARROW
   PlotIndexSetInteger(0, PLOT_ARROW, 216);
   PlotIndexSetInteger(1, PLOT_ARROW, 215);
   PlotIndexSetInteger(2, PLOT_ARROW, 216);
   PlotIndexSetInteger(3, PLOT_ARROW, 215);
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, ArrowShift+10);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, -ArrowShift);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT, -ArrowShift-10);
   PlotIndexSetInteger(3, PLOT_ARROW_SHIFT, ArrowShift);
   
//--- load models
   onnx = OnnxCreateFromBuffer(model, ONNX_DEFAULT);
   if(onnx == INVALID_HANDLE)
     {
      Print("OnnxCreateFromBuffer error ", GetLastError());
      return INIT_FAILED;
     }
//--- since not all sizes defined in the input tensor we must set them explicitly
//--- first index - batch size, second index - series size, third index - number of series (OHLC)
   const ulong input_state[] = {1, Inputs.Size()};
   if(!OnnxSetInputShape(onnx, 0, input_state))
     {
      Print("OnnxSetInputShape error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
//--- since not all sizes defined in the output tensor we must set them explicitly
//--- first index - batch size, must match the batch size of the input tensor
//--- second index - number of predicted prices (we only predict Close)
   const ulong output_forecast[] = {1, Forecast.Size()};
   if(!OnnxSetOutputShape(onnx, 0, output_forecast))
     {
      Print("OnnxSetOutputShape error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
//--- Indicators
   if(!ciSMA.Create(_Symbol, PERIOD_CURRENT, 12, 0, MODE_SMA, PRICE_CLOSE))
     {
      Print("SMA create error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   ciSMA.BufferResize(BufferSize + 1);
   if(!ciMACD[0].Create(_Symbol, PERIOD_CURRENT, 8, 16, 6, PRICE_CLOSE))
     {
      Print("MACD 0 create error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   if(!ciMACD[1].Create(_Symbol, PERIOD_CURRENT, 12, 24, 9, PRICE_CLOSE))
     {
      Print("MACD 1 create error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   if(!ciMACD[2].Create(_Symbol, PERIOD_CURRENT, 36, 72, 27, PRICE_CLOSE))
     {
      Print("MACD 2 create error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   if(!ciMACD[3].Create(_Symbol, PERIOD_CURRENT, 48, 96, 36, PRICE_CLOSE))
     {
      Print("MACD 2 create error ", GetLastError());
      OnnxRelease(onnx);
      return INIT_FAILED;
     }
   for(uint i = 0; i < ciMACD.Size(); i++)
      ciMACD[i].BufferResize(BufferSize + 3);
   dLastValue = 0;
   Buy=Sell=false;
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   OnnxRelease(onnx);
  }
//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int32_t rates_total,
                const int32_t prev_calculated,
                const int32_t begin,
                const double &price[])
  {
//---
   if(rates_total == prev_calculated || rates_total <= 12)
      return prev_calculated;
//---
   ciSMA.Refresh();
   for(uint i = 0; i < ciMACD.Size(); i++)
      ciMACD[i].Refresh();
   int32_t total = MathMin(BufferSize, rates_total - 13 - prev_calculated);
   /*
      Columns: ['last', 'last_11', 'last_last_11', 'SMA_12',
         'MACD_MAIN_08,16,06', 'DMACD_MAIN_08,16,06', 'MACD_SIGNAL_08,16,06', 'DMACD_SIGNAL_08,16,06', 'MACD_Sig_Main_08,16,06', 'DMACD_Sig_Main_08,16,06',
         'MACD_MAIN_12,24,09', 'DMACD_MAIN_12,24,09', 'MACD_SIGNAL_12,24,09', 'DMACD_SIGNAL_12,24,09', 'MACD_Sig_Main_12,24,09', 'DMACD_Sig_Main_12,24,09',
         'MACD_MAIN_36,72,27', 'DMACD_MAIN_36,72,27', 'MACD_SIGNAL_36,72,27', 'DMACD_SIGNAL_36,72,27', 'MACD_Sig_Main_36,72,27', 'DMACD_Sig_Main_36,72,27',
         'MACD_MAIN_48,96,36', 'DMACD_MAIN_48,96,36', 'MACD_SIGNAL_48,96,36', 'DMACD_SIGNAL_48,96,36', 'MACD_Sig_Main_48,96,36', 'DMACD_Sig_Main_48,96,36']
   */
   for(int32_t b = total; b > 0; b--)
     {
      Inputs[0] = float(price[rates_total - b - 1] - price[rates_total - b - 2]);
      Inputs[1] = float(price[rates_total - b - 1] - price[rates_total - b - 12]) / 11;
      Inputs[2] = float(Inputs[1] - Inputs[0]);
      Inputs[3] = float(ciSMA.Main(b));
      for(uint i = 0; i < ciMACD.Size(); i++)
        {
         Inputs[4 + i*6] = float(ciMACD[i].Main(b));
         Inputs[5 + i*6] = float(Inputs[4 + i*6] - ciMACD[i].Main(b + 1));
         Inputs[6 + i*6] = float(ciMACD[i].Signal(b));
         Inputs[7 + i*6] = float(Inputs[6 + i*6] - ciMACD[i].Signal(b + 1));
         Inputs[8 + i*6] = Inputs[6 + i*6] - Inputs[4 + i*6];
         Inputs[9 + i*6] = Inputs[7 + i*6] - Inputs[5 + i*6];
        }
      //--- run the inference
      if(!OnnxRun(onnx, ONNX_LOGLEVEL_INFO, Inputs, Forecast))
        {
         Print("OnnxRun error ", GetLastError());
         return prev_calculated;
        }
      //---
      double value = Forecast[0] * direction;
//--- Buy
      if(value >= threshold && dLastValue < threshold)
        {
         BuyInBuffer[rates_total - b] =  price[ rates_total - b];
         Buy=true;
        }
      else
         BuyInBuffer[rates_total - b] =  0;
      if(Buy && value<dLastValue)
        {
         BuyOutBuffer[rates_total - b] = price[ rates_total - b];
         Buy=false;
        }
      else
         BuyOutBuffer[rates_total - b] = 0;
//--- Sell
      if(value <= -threshold && dLastValue > -threshold)
        {
         SellInBuffer[rates_total - b] =  price[ rates_total - b];
         Sell=true;
        }
      else
         SellInBuffer[rates_total - b] =  0;
      if(Sell && value>dLastValue)
        {
         SellOutBuffer[rates_total - b] = price[ rates_total - b];
         Sell=false;
        }
      else
         SellOutBuffer[rates_total - b] = 0;
      dLastValue = value;
     }
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
