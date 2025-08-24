//+------------------------------------------------------------------+
//|                                                   Trap_trading.mq5
//| Trap Trading Strategy (MT5/MQL5)
//| - First H4 candle high/low of server day
//| - Trades traps on M5 within session window
//| - RRR 1:3, SL beyond last two candles, EMA(200) distance filter
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//--- Trading object
CTrade TradeObj;

//----------------------------- Inputs --------------------------------
input int      SessionStartHH   = 12;    // Session start hour (server time)
input int      SessionStartMM   = 30;    // Session start minute
input int      SessionEndHH     = 19;    // Session end hour (server time)
input int      SessionEndMM     = 5;     // Session end minute

input double   Lots             = 0.10;  // Fixed lot size
input int      SlippagePoints   = 20;    // Max deviation (points)
input int      Magic            = 20250822;

input int      MinH4RangePips   = 10;    // Min first H4 candle size (pips)
input int      EMADistancePips  = 3;     // Min distance from EMA200 (M5)
input int      EMA_Period       = 200;   // EMA period on M5
input bool     RestrictToEU_GU  = true;  // Trade only EURUSD & GBPUSD
//------------------------------------------------------------------------

//--- Internal state
int            emaHandle = INVALID_HANDLE;
datetime       lastM5BarTime = 0;
datetime       currentDayStart = 0;
double         H4FirstHigh = 0.0;
double         H4FirstLow  = 0.0;
bool           h4LevelsReady = false;
bool           dayRangeOK = false;
bool           daySideLocked = false;
int            lockedSide = 0;           // +1 = high side (sell trap), -1 = low side (buy trap)
bool           dayBlocked = false;
bool           tradePlacedToday = false;

string sym;
int    dig;
double pip;

//--------------------------- Utilities --------------------------------
double PipSize()
{
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double p = SymbolInfoDouble(sym, SYMBOL_POINT);
   return (d == 3 || d == 5) ? 10.0 * p : p;
}

double NormalizePrice(const double price){ return NormalizeDouble(price, dig); }

bool IsSymbolAllowed()
{
   if(!RestrictToEU_GU) return true;
   // Case-insensitive compare without StringToUpper (avoids warning)
   bool eu = (StringCompare(sym,"EURUSD",false)==0);
   bool gu = (StringCompare(sym,"GBPUSD",false)==0);
   return (eu || gu);
}

datetime GetDayStart(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

// Return index (shift) of the first H4 bar of server day
int FindFirstH4BarIndex(const datetime dayStart)
{
   MqlRates rates[];
   int copied = CopyRates(sym, PERIOD_H4, dayStart - 2*86400, 40, rates);
   if(copied <= 0) return -1;
   ArraySetAsSeries(rates, true);
   for(int i=0; i<copied; i++)
   {
      datetime t = rates[i].time;
      if(t >= dayStart && t < (dayStart + 4*3600))
         return i;
   }
   return -1;
}

bool UpdateH4LevelsForToday()
{
   datetime now = TimeCurrent();
   datetime dayStart = GetDayStart(now);
   if(dayStart == currentDayStart && h4LevelsReady) return true;

   // Reset daily state
   currentDayStart = dayStart;
   h4LevelsReady = false;
   dayRangeOK = false;
   daySideLocked = false;
   lockedSide = 0;
   dayBlocked = false;
   tradePlacedToday = false;

   // First H4 bar
   int idx = FindFirstH4BarIndex(dayStart);
   if(idx < 0) return false;

   MqlRates rH4[];
   int copied = CopyRates(sym, PERIOD_H4, 0, idx+2, rH4);
   if(copied <= idx) return false;
   ArraySetAsSeries(rH4, true);

   H4FirstHigh = rH4[idx].high;
   H4FirstLow  = rH4[idx].low;
   h4LevelsReady = true;

   double range = MathAbs(H4FirstHigh - H4FirstLow);
   dayRangeOK = (range >= MinH4RangePips * pip);

   // Draw/update lines
   string hName="TrapEA_H4High", lName="TrapEA_H4Low";
   if(ObjectFind(0,hName) == -1) ObjectCreate(0,hName,OBJ_HLINE,0,0,0);
   if(ObjectFind(0,lName) == -1) ObjectCreate(0,lName,OBJ_HLINE,0,0,0);
   ObjectSetInteger(0,hName,OBJPROP_COLOR,clrOrangeRed);
   ObjectSetInteger(0,hName,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetInteger(0,lName,OBJPROP_COLOR,clrDeepSkyBlue);
   ObjectSetInteger(0,lName,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetDouble(0,hName,OBJPROP_PRICE,H4FirstHigh);
   ObjectSetDouble(0,lName,OBJPROP_PRICE,H4FirstLow);

   return true;
}

bool InSession(const datetime t)
{
   datetime s = GetDayStart(t) + SessionStartHH*3600 + SessionStartMM*60;
   datetime e = GetDayStart(t) + SessionEndHH*3600 + SessionEndMM*60;
   return (t >= s && t <= e);
}

bool HasOpenPosition()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == sym &&
            (int)PositionGetInteger(POSITION_MAGIC) == Magic)
            return true;
      }
   }
   return false;
}

bool GetEMA(const int shift, double &emaOut)
{
   double buf[1];                                     // fixed-size buffer (no warning)
   if(CopyBuffer(emaHandle,0,shift,1,buf) != 1) return false;
   emaOut = buf[0];
   return true;
}

void BuildSLTP(const bool isBuy, const double entry, const double slRaw, const double rr,
               double &slOut, double &tpOut)
{
   slOut = NormalizePrice(slRaw);
   double risk = MathAbs(entry - slOut);
   tpOut = isBuy ? entry + rr*risk : entry - rr*risk;
   slOut = NormalizePrice(slOut);
   tpOut = NormalizePrice(tpOut);
}

bool PlaceTrade(const bool isBuy, const double sl, const double tp)
{
   // CTrade places at market using Ask/Bid automatically
   bool ok = isBuy ? TradeObj.Buy(Lots, sym, 0.0, sl, tp, "TrapEA")
                   : TradeObj.Sell(Lots, sym, 0.0, sl, tp, "TrapEA");
   if(!ok)
   {
      int err = _LastError;
      Print("Trade send failed. Error=", err);
      return false;
   }
   return true;
}

//--------------------------- Lifecycle --------------------------------
int OnInit()
{
   sym = _Symbol;
   dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   pip = PipSize();

   // Configure CTrade
   TradeObj.SetExpertMagicNumber(Magic);
   TradeObj.SetDeviationInPoints(SlippagePoints);

   if(!IsSymbolAllowed())
      Print("Notice: RestrictToEU_GU=true and symbol is not EURUSD/GBPUSD.");

   emaHandle = iMA(sym, PERIOD_M5, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE) return INIT_FAILED;

   UpdateH4LevelsForToday();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
}

void OnTick()
{
   UpdateH4LevelsForToday();

   // Work only on new closed M5 bar
   MqlRates m5[];                                      // dynamic array (no warning)
   if(CopyRates(sym, PERIOD_M5, 0, 3, m5) < 3) return;
   ArraySetAsSeries(m5, true);

   if(m5[0].time == lastM5BarTime) return;            // same bar
   lastM5BarTime = m5[0].time;                        // new bar formed; m5[1] closed

   if(!InSession(m5[1].time)) return;
   if(!IsSymbolAllowed()) return;
   if(HasOpenPosition()) return;
   if(!h4LevelsReady || !dayRangeOK) return;
   if(dayBlocked || tradePlacedToday) return;

   double ema;
   if(!GetEMA(1, ema)) return;

   MqlRates sig = m5[1];
   MqlRates prev = m5[2];

   bool sellTrap = (sig.high > H4FirstHigh && sig.close < H4FirstHigh);
   bool buyTrap  = (sig.low  < H4FirstLow  && sig.close > H4FirstLow );

   // Lock the first side that traps
   if(daySideLocked)
   {
      if(lockedSide == +1) buyTrap = false;   // only sell allowed
      if(lockedSide == -1) sellTrap = false;  // only buy allowed
   }
   else
   {
      if(sellTrap){ daySideLocked = true; lockedSide = +1; }
      else if(buyTrap){ daySideLocked = true; lockedSide = -1; }
   }

   if(!(sellTrap || buyTrap)) return;

   // EMA distance filter
   double emaDist = MathAbs(sig.close - ema);
   if(emaDist < EMADistancePips * pip){ dayBlocked = true; return; }

   // Build SL/TP (1:3 RRR) from last two candles
   double slRaw, sl, tp;
   double entryForRisk = sig.close;

   if(buyTrap)
   {
      slRaw = MathMin(sig.low, prev.low);
      BuildSLTP(true, entryForRisk, slRaw, 3.0, sl, tp);
      if(PlaceTrade(true, sl, tp)) tradePlacedToday = true;
   }
   else if(sellTrap)
   {
      slRaw = MathMax(sig.high, prev.high);
      BuildSLTP(false, entryForRisk, slRaw, 3.0, sl, tp);
      if(PlaceTrade(false, sl, tp)) tradePlacedToday = true;
   }
}
//+------------------------------------------------------------------+
