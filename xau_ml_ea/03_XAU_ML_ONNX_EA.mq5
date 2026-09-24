#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

input string InpModelFile = "model_xau_single_shot.onnx";
input double InpLot = 0.01;
input long InpMagic = 790102;
input double InpMinProbability = 0.80;
input int InpAtrPeriod = 14;
input double InpSlAtrMultiplier = 0.8;
input double InpRR = 0.8;
input double InpMaxSpreadPips = 50.0;

CTrade trade;
long g_model = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;

int OnInit()
{
   g_model = OnnxCreate(InpModelFile, ONNX_COMMON_FOLDER);
   if(g_model == INVALID_HANDLE)
   {
      Print("ONNX load failed | error=", GetLastError());
      return INIT_FAILED;
   }
   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_model != INVALID_HANDLE) OnnxRelease(g_model);
}

void OnTick()
{
}
