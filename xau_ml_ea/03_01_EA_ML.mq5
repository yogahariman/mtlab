#property strict
#property version "1.00"
#include <Trade/Trade.mqh>
input string InpModelPrimary="model_xau_primary.onnx";
input string InpModelConfirm1="model_xau_confirm1.onnx";
input string InpMetaPrimary="model_xau_primary.meta";
input string InpMetaConfirm1="model_xau_confirm1.meta";
input bool InpUseMetadata=false;
input ENUM_TIMEFRAMES InpPrimaryTimeframe=PERIOD_M5;
input ENUM_TIMEFRAMES InpConfirmTimeframe1=PERIOD_M15;
input ENUM_TIMEFRAMES InpContextTimeframe=PERIOD_H1;
input double InpLot=0.01;
input long InpMagic=790102;
input double InpMaxSpreadPips=50.0;
input double InpMinProbability=0.60;
input int InpAtrPeriod=14;
input double InpSlAtrMultiplier=1.0;
input double InpRR=1.0;
input bool InpDebug=true;
CTrade trade;
long g_modelPrimary=INVALID_HANDLE, g_modelConfirm1=INVALID_HANDLE;
int g_atr=INVALID_HANDLE;
datetime g_last=0;
bool LoadMeta(const string file,double &threshold) {
   int f=FileOpen(file,FILE_READ|FILE_TXT|FILE_COMMON|FILE_ANSI);
   if(f==INVALID_HANDLE) {
      Print("Metadata missing: ",file);
      return false;
   }
   while(!FileIsEnding(f)) {
      string l=FileReadString(f),p[];
      if(StringSplit(l,'=',p)==2&&p[0]=="min_probability")threshold=StringToDouble(p[1]);
   }
   FileClose(f);
   return true;
}
bool Run(const long h,float &x[],float &o[]) {
   ArrayResize(o,3);
   return OnnxRun(h,ONNX_NO_CONVERSION,x,o)&&ArraySize(o)>=3;
}
int Signal(const float &o[],const double threshold) {
   int c=(o[1]>o[0]?1:0);
   if(o[2]>o[c])c=2;
   return(o[c]>=threshold?c:1);
}
bool HasPosition() {
   for(int i=PositionsTotal()-1;i>=0;i--)if(PositionGetSymbol(i)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==InpMagic)return true;
   return false;
}
double Ema(const MqlRates &r[],int n,int period,int shift) {
   double a=2.0/(period+1.0),e=r[n-1].close;
   for(int i=n-2;i>=shift;i--)e=a*r[i].close+(1-a)*e;
   return e;
}
bool Buf(int h,int b,int shift,double &v) {
   double a[];
   ArraySetAsSeries(a,true);
   if(CopyBuffer(h,b,shift,1,a)!=1)return false;
   v=a[0];
   return MathIsValidNumber(v);
}
bool Features(ENUM_TIMEFRAMES tf,float &x[]) {
   MqlRates r[],h[];
   ArraySetAsSeries(r,true);
   ArraySetAsSeries(h,true);
   if(CopyRates(_Symbol,tf,1,260,r)<230||CopyRates(_Symbol,InpContextTimeframe,1,260,h)<230)return false;
   int n=ArraySize(r),nh=ArraySize(h),s=0;
   double c=r[s].close,prev=r[s+1].close,atr=0,a=1.0/InpAtrPeriod;
   for(int i=n-1;i>=s;i--) {
      double pc=(i==n-1?r[i].close:r[i+1].close),tr=MathMax(r[i].high-r[i].low,MathMax(MathAbs(r[i].high-pc),MathAbs(r[i].low-pc)));
      atr=(i==n-1?tr:a*tr+(1-a)*atr);
   }
   double e20=Ema(r,n,20,s),e50=Ema(r,n,50,s),e200=Ema(r,n,200,s),e20old=Ema(r,n,20,s+20),avg=0,sd=0;
   for(int i=s;i<s+20;i++)avg+=r[i].close;
   avg/=20;
   for(int i=s;i<s+20;i++)sd+=MathPow(r[i].close-avg,2);
   sd=MathSqrt(sd/19);
   double range=MathMax(r[s].high-r[s].low,_Point),body=MathAbs(r[s].close-r[s].open),rv=0,av=0,hav=0;
   int rh=iRSI(_Symbol,tf,14,PRICE_CLOSE),ah=iADX(_Symbol,tf,14),hh=iADX(_Symbol,InpContextTimeframe,14);
   bool ok=Buf(rh,0,1,rv)&&Buf(ah,0,1,av)&&Buf(hh,0,1,hav);
   IndicatorRelease(rh);
   IndicatorRelease(ah);
   IndicatorRelease(hh);
   if(!ok)return false;
   MqlDateTime dt;
   TimeToStruct(r[s].time,dt);
   ArrayResize(x,18);
   x[0]=(float)(atr/c);
   x[1]=(float)(4*sd/avg);
   x[2]=(float)(body/range);
   x[3]=(float)((c-e50)/c);
   x[4]=(float)((c-e200)/c);
   x[5]=(float)(e20/e20old-1);
   x[6]=(float)(rv/100);
   x[7]=(float)(av/100);
   x[8]=(float)MathLog(c/prev);
   x[9]=(float)((r[s].high-MathMax(r[s].open,r[s].close))/range);
   x[10]=(float)((MathMin(r[s].open,r[s].close)-r[s].low)/range);
   x[11]=(float)MathSin(2*M_PI*dt.hour/24);
   x[12]=(float)MathCos(2*M_PI*dt.hour/24);
   x[13]=(float)(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)/c);
   x[14]=(float)((h[1].close-Ema(h,nh,50,1))/h[1].close);
   x[15]=(float)((h[1].close-Ema(h,nh,200,1))/h[1].close);
   x[16]=(float)(Ema(h,nh,20,1)/Ema(h,nh,20,21)-1);
   x[17]=(float)(hav/100);
   return true;
}
int Vote(const long h,ENUM_TIMEFRAMES tf,double threshold) {
   float x[],o[];
   if(!Features(tf,x)) {
      if(InpDebug)Print("MTF features failed tf=",EnumToString(tf)," error=",GetLastError());
      return 1;
   }
   if(!Run(h,x,o)) {
      if(InpDebug)Print("MTF ONNX failed tf=",EnumToString(tf)," error=",GetLastError());
      return 1;
   }
   int s=Signal(o,threshold);
   if(InpDebug)Print("MTF ",EnumToString(tf)," SELL=",DoubleToString(o[0],4)," NONE=",DoubleToString(o[1],4)," BUY=",DoubleToString(o[2],4)," signal=",s);
   return s;
}
int OnInit() {
   double t=InpMinProbability;
   if(InpUseMetadata&&(!LoadMeta(InpMetaPrimary,t)||!LoadMeta(InpMetaConfirm1,t)))return INIT_FAILED;
   g_modelPrimary=OnnxCreate(InpModelPrimary,ONNX_COMMON_FOLDER);
   g_modelConfirm1=OnnxCreate(InpModelConfirm1,ONNX_COMMON_FOLDER);
   g_atr=iATR(_Symbol,InpPrimaryTimeframe,InpAtrPeriod);
   if(g_modelPrimary==INVALID_HANDLE||g_modelConfirm1==INVALID_HANDLE||g_atr==INVALID_HANDLE)return INIT_FAILED;
   const ulong in_shape[] = {1, 18};
   const ulong out_shape[] = {1, 3};
   if(!OnnxSetInputShape(g_modelPrimary,0,in_shape)||!OnnxSetOutputShape(g_modelPrimary,0,out_shape)||!OnnxSetInputShape(g_modelConfirm1,0,in_shape)||!OnnxSetOutputShape(g_modelConfirm1,0,out_shape))return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r) {
   if(g_modelPrimary!=INVALID_HANDLE)OnnxRelease(g_modelPrimary);
   if(g_modelConfirm1!=INVALID_HANDLE)OnnxRelease(g_modelConfirm1);
   if(g_atr!=INVALID_HANDLE)IndicatorRelease(g_atr);
}
void OnTick() {
   datetime b=iTime(_Symbol,InpPrimaryTimeframe,0);
   if(b==0||b==g_last)return;
   g_last=b;
   if(HasPosition())return;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q))return;
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT),pip=(_Digits==3||_Digits==5?pt*10:pt);
   if((q.ask-q.bid)/pip>InpMaxSpreadPips)return;
   double th=InpMinProbability;
   if(InpUseMetadata) {
      if(!LoadMeta(InpMetaPrimary,th)||!LoadMeta(InpMetaConfirm1,th))return;
   }
   int a=Vote(g_modelPrimary,InpPrimaryTimeframe,th),c=Vote(g_modelConfirm1,InpConfirmTimeframe1,th);
   if(a!=c||a==1) {
      if(InpDebug)Print("MTF no trade: signals=",a,",",c);
      return;
   }
   double av;
   if(!Buf(g_atr,0,1,av))return;
   double dist=av*InpSlAtrMultiplier,price=(a==2?q.ask:q.bid),sl=(a==2?price-dist:price+dist),tp=(a==2?price+dist*InpRR:price-dist*InpRR);
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   sl=NormalizeDouble(sl,dg);
   tp=NormalizeDouble(tp,dg);
   if(a==2)trade.Buy(InpLot,_Symbol,0,sl,tp,"MTF BUY");
   else trade.Sell(InpLot,_Symbol,0,sl,tp,"MTF SELL");
}
