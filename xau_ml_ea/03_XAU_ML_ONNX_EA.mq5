#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

input string InpModelFile = "model_xau_single_shot.onnx";
input string InpMetadataFile = "model_xau_single_shot.meta";
input bool InpUseMetadata = true;
input double InpLot = 0.01;
input long InpMagic = 790102;
input double InpMinProbability = 0.80;
input int InpAtrPeriod = 14;
input double InpSlAtrMultiplier = 0.8;
input double InpRR = 0.8;
input double InpMaxSpreadPips = 50.0;
input ENUM_TIMEFRAMES InpEntryTimeframe = PERIOD_M5;
// Harus sama dengan 02_train_model_onnx.py
input int InpEmaFast = 50;
input int InpEmaSlow = 200;
input int InpEmaSlopePeriod = 20;
input int InpRsiPeriod = 14;
input int InpAdxPeriod = 14;
input int InpBbPeriod = 20;

double gMinProbability;
int gAtrPeriod;
double gSlAtrMultiplier;
double gRR;
int gEmaFast;
int gEmaSlow;
int gEmaSlopePeriod;
int gRsiPeriod;
int gAdxPeriod;
int gBbPeriod;

CTrade trade;
long g_model = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;
int g_rsiHandle = INVALID_HANDLE;
int g_adxM5Handle = INVALID_HANDLE;
int g_adxH1Handle = INVALID_HANDLE;
datetime g_lastBar = 0;


bool LoadModelMetadata()
{
   int f=FileOpen(InpMetadataFile,FILE_READ|FILE_TXT|FILE_COMMON|FILE_ANSI);
   if(f==INVALID_HANDLE){Print("Metadata file not found in COMMON\\Files: ",InpMetadataFile," | error=",GetLastError());return false;}
   bool ok=true;
   while(!FileIsEnding(f)){ string line=FileReadString(f); string p[]; if(StringSplit(line,'=',p)!=2) continue; string k=p[0],v=p[1];
      if(k=="feature_count" && (int)StringToInteger(v)!=18) ok=false;
      else if(k=="atr_period") gAtrPeriod=(int)StringToInteger(v);
      else if(k=="ema_fast") gEmaFast=(int)StringToInteger(v);
      else if(k=="ema_slow") gEmaSlow=(int)StringToInteger(v);
      else if(k=="ema_slope_period") gEmaSlopePeriod=(int)StringToInteger(v);
      else if(k=="rsi_period") gRsiPeriod=(int)StringToInteger(v);
      else if(k=="adx_period") gAdxPeriod=(int)StringToInteger(v);
      else if(k=="bb_period") gBbPeriod=(int)StringToInteger(v);
      else if(k=="sl_atr_multiplier") gSlAtrMultiplier=StringToDouble(v);
      else if(k=="rr") gRR=StringToDouble(v);
      else if(k=="min_probability") gMinProbability=StringToDouble(v);
   }
   FileClose(f); return ok;
}

bool ReadBuffer(const int handle,const int buffer,const int shift,double &value)
{ double v[]; ArraySetAsSeries(v,true); if(CopyBuffer(handle,buffer,shift,1,v)!=1) return false; value=v[0]; return MathIsValidNumber(value); }

double Ema(const MqlRates &r[],const int count,const int period,const int shift)
{ if(count<=shift) return 0.0; double a=2.0/(period+1.0),e=r[count-1].close; for(int i=count-2;i>=shift;i--) e=a*r[i].close+(1-a)*e; return e; }

bool BuildFeatures(float &x[])
{
 MqlRates m5[],h1[]; ArraySetAsSeries(m5,true); ArraySetAsSeries(h1,true); if(CopyRates(_Symbol,PERIOD_M5,1,260,m5)<230 || CopyRates(_Symbol,PERIOD_H1,1,260,h1)<230) return false; ArrayResize(x,18); int n=ArraySize(m5),nh=ArraySize(h1),s=0; double c=m5[s].close,prev=m5[s+1].close,atr=0,a=1.0/gAtrPeriod;
 for(int i=n-1;i>=s;i--){ double pc=(i==n-1?m5[i].close:m5[i+1].close),t=MathMax(m5[i].high-m5[i].low,MathMax(MathAbs(m5[i].high-pc),MathAbs(m5[i].low-pc))); atr=(i==n-1?t:a*t+(1-a)*atr); }
 double e20=Ema(m5,n,20,s),e50=Ema(m5,n,gEmaFast,s),e200=Ema(m5,n,gEmaSlow,s),e20o=Ema(m5,n,20,s+gEmaSlopePeriod),avg=0,sd=0; for(int i=s;i<s+gBbPeriod;i++) avg+=m5[i].close; avg/=gBbPeriod; for(int i=s;i<s+gBbPeriod;i++) sd+=MathPow(m5[i].close-avg,2); sd=MathSqrt(sd/(gBbPeriod-1)); double range=MathMax(m5[s].high-m5[s].low,_Point),body=MathAbs(m5[s].close-m5[s].open),rsi=0,adx=0,hadx=0; if(!ReadBuffer(g_rsiHandle,0,s,rsi) || !ReadBuffer(g_adxM5Handle,0,s,adx) || !ReadBuffer(g_adxH1Handle,0,1,hadx)) return false; MqlDateTime dt; TimeToStruct(m5[s].time,dt);
 x[0]=(float)(atr/c);x[1]=(float)(4*sd/avg);x[2]=(float)(body/range);x[3]=(float)((c-e50)/c);x[4]=(float)((c-e200)/c);x[5]=(float)(e20/e20o-1);x[6]=(float)(rsi/100.0);x[7]=(float)(adx/100.0);x[8]=(float)MathLog(c/prev);x[9]=(float)((m5[s].high-MathMax(m5[s].open,m5[s].close))/range);x[10]=(float)((MathMin(m5[s].open,m5[s].close)-m5[s].low)/range);x[11]=(float)MathSin(2*M_PI*dt.hour/24.0);x[12]=(float)MathCos(2*M_PI*dt.hour/24.0);x[13]=(float)(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)/c);x[14]=(float)((h1[1].close-Ema(h1,nh,gEmaFast,1))/h1[1].close);x[15]=(float)((h1[1].close-Ema(h1,nh,gEmaSlow,1))/h1[1].close);x[16]=(float)(Ema(h1,nh,20,1)/Ema(h1,nh,20,1+gEmaSlopePeriod)-1);x[17]=(float)(hadx/100.0); return true;
}

bool HasPosition(){for(int i=PositionsTotal()-1;i>=0;i--)if(PositionGetSymbol(i)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic)return true;return false;}

int OnInit()
{
   gMinProbability=InpMinProbability; gAtrPeriod=InpAtrPeriod; gSlAtrMultiplier=InpSlAtrMultiplier; gRR=InpRR;
   gEmaFast=InpEmaFast; gEmaSlow=InpEmaSlow; gEmaSlopePeriod=InpEmaSlopePeriod; gRsiPeriod=InpRsiPeriod; gAdxPeriod=InpAdxPeriod; gBbPeriod=InpBbPeriod;
   if(InpUseMetadata && !LoadModelMetadata()){ Print("OnInit failed: metadata could not be loaded"); return INIT_FAILED; }
   g_model = OnnxCreate(InpModelFile, ONNX_COMMON_FOLDER);
   if(g_model == INVALID_HANDLE)
   {
      Print("ONNX load failed | error=", GetLastError());
      Print("OnInit failed: ONNX model could not be loaded: ",InpModelFile," | error=",GetLastError());
      return INIT_FAILED;
   }
   g_atrHandle = iATR(_Symbol, PERIOD_M5, gAtrPeriod);
   g_rsiHandle = iRSI(_Symbol, PERIOD_M5, gRsiPeriod, PRICE_CLOSE);
   g_adxM5Handle = iADX(_Symbol, PERIOD_M5, gAdxPeriod);
   g_adxH1Handle = iADX(_Symbol, PERIOD_H1, gAdxPeriod);
   if(g_atrHandle == INVALID_HANDLE || g_rsiHandle == INVALID_HANDLE || g_adxM5Handle == INVALID_HANDLE || g_adxH1Handle == INVALID_HANDLE)
   {
      Print("OnInit failed: indicator handle creation failed | error=",GetLastError());
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   const ulong in_shape[]={1,18},out_shape[]={1,3};
   if(!OnnxSetInputShape(g_model,0,in_shape) || !OnnxSetOutputShape(g_model,0,out_shape))
   { Print("OnInit failed: ONNX shape setup failed | error=",GetLastError()); return INIT_FAILED; }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_adxM5Handle != INVALID_HANDLE) IndicatorRelease(g_adxM5Handle);
   if(g_adxH1Handle != INVALID_HANDLE) IndicatorRelease(g_adxH1Handle);
   if(g_model != INVALID_HANDLE) OnnxRelease(g_model);
}

void OnTick()
{
   datetime bar=iTime(_Symbol,InpEntryTimeframe,0); if(bar==0 || bar==g_lastBar) return; g_lastBar=bar;
   if(HasPosition()) return; MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT),pip=(_Digits==3||_Digits==5?point*10:point); if(pip<=0 || (tick.ask-tick.bid)/pip>InpMaxSpreadPips) return;
   float features[],output[]; ArrayResize(output,3); if(!BuildFeatures(features) || ArraySize(features)!=18 || !OnnxRun(g_model,ONNX_NO_CONVERSION,features,output) || ArraySize(output)<3) return;
   int cls=(output[1]>output[0]?1:0); if(output[2]>output[cls]) cls=2; if(cls==1 || output[cls]<gMinProbability) return;
   double atr; if(!ReadBuffer(g_atrHandle,0,1,atr) || atr<=0) return; double d=atr*gSlAtrMultiplier,price=(cls==2?tick.ask:tick.bid),sl=(cls==2?price-d:price+d),tp=(cls==2?price+d*gRR:price-d*gRR); int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); sl=NormalizeDouble(sl,digits);tp=NormalizeDouble(tp,digits);
   if(!(cls==2?trade.Buy(InpLot,_Symbol,0,sl,tp,"ONNX BUY"):trade.Sell(InpLot,_Symbol,0,sl,tp,"ONNX SELL"))) Print("Order failed | retcode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
}
