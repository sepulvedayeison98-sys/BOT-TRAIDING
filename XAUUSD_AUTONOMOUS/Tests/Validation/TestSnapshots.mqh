//+------------------------------------------------------------------+
//| TestSnapshots.mqh                                                |
//| Constructores de MarketSnapshot sintéticos para pruebas          |
//| unitarias (sin terminal ni historial).                           |
//+------------------------------------------------------------------+
#ifndef XAUUSD_TESTSNAPSHOTS_MQH
#define XAUUSD_TESTSNAPSHOTS_MQH

#include <XAUUSD/Types.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include <XAUUSD/StrategyBase.mqh>

#define T_M15_LAST D'2026.01.14 12:00'
#define T_M5_LAST  D'2026.01.14 12:10'

//--- construye un TFData a partir de OHLC cronológicos (aplanados o,h,l,c).
//--- mirror_k > 0 refleja precios: p -> k - p (y RSI -> 100 - RSI).
void BuildTF(TFData &d, const ENUM_TIMEFRAMES tf, const double &ohlc[], const double atr, const int pivot_n,
             const datetime last_time, const double ema, const double mirror_k)
  {
   int n = ArraySize(ohlc) / 4;
   d.tf = tf;
   d.valid = true;
   d.invalid_reason = "";
   d.bars = n;
   ArrayResize(d.rates, n);
   ArrayResize(d.ema_fast, n);
   ArrayResize(d.ema_slow, n);
   ArrayResize(d.rsi, n);
   ArrayResize(d.adx, n);
   ArrayResize(d.plus_di, n);
   ArrayResize(d.minus_di, n);
   ArrayResize(d.atr, n);
   for(int c = 0; c < n; c++)
     {
      int i = n - 1 - c;   // índice serie
      double o = ohlc[4 * c], h = ohlc[4 * c + 1], l = ohlc[4 * c + 2], cl = ohlc[4 * c + 3];
      if(mirror_k > 0)
        {
         double mo = mirror_k - o, mh = mirror_k - l, ml = mirror_k - h, mc = mirror_k - cl;
         o = mo; h = mh; l = ml; cl = mc;
        }
      d.rates[i].time = last_time - (datetime)(i * PeriodSeconds(tf));
      d.rates[i].open = o;
      d.rates[i].high = h;
      d.rates[i].low = l;
      d.rates[i].close = cl;
      d.rates[i].tick_volume = 100;
      d.rates[i].real_volume = 0;
      d.rates[i].spread = 20;
      d.ema_fast[i] = (mirror_k > 0) ? mirror_k - ema : ema;
      d.ema_slow[i] = d.ema_fast[i];
      d.rsi[i] = 50.0;
      d.adx[i] = 25.0;
      d.plus_di[i] = 20.0;
      d.minus_di[i] = 20.0;
      d.atr[i] = atr;
     }
   d.swing_count = CMarketAlgo::FindSwings(d.rates, n, pivot_n, 30, d.swings);
   d.structure = CMarketAlgo::ClassifyStructure(d.swings, d.swing_count);
   d.last_closed_time = d.rates[0].time;
   d.atr_ratio = 1.0;
   d.ema_slope = 0.0;
   d.ema_slope_prev = 0.0;
   d.momentum_shift = false;
   CMarketAlgo::RangeOf(d.rates, n, d.range_high, d.range_low);
  }

//--- M5: 6 velas planas (sin pivotes) + la vela de confirmación
void BuildM5(TFData &d, const double o, const double h, const double l, const double c, const double mirror_k)
  {
   double flat = (o + c) / 2.0;
   double arr[];
   ArrayResize(arr, 28);
   for(int i = 0; i < 6; i++)
     {
      arr[4 * i] = flat; arr[4 * i + 1] = flat + 0.5; arr[4 * i + 2] = flat - 0.5; arr[4 * i + 3] = flat;
     }
   arr[24] = o; arr[25] = h; arr[26] = l; arr[27] = c;
   BuildTF(d, PERIOD_M5, arr, 1.0, 3, T_M5_LAST, flat, mirror_k);
  }

void BuildH1Flat(TFData &d, const double price, const double mirror_k)
  {
   double arr[];
   ArrayResize(arr, 40);
   for(int i = 0; i < 10; i++)
     {
      arr[4 * i] = price; arr[4 * i + 1] = price + 1; arr[4 * i + 2] = price - 1; arr[4 * i + 3] = price;
     }
   BuildTF(d, PERIOD_H1, arr, 5.0, 2, D'2026.01.14 11:00', price, mirror_k);
  }

void FinishSnapshot(MarketSnapshot &s)
  {
   s.valid = true;
   s.invalid_reason = "";
   s.symbol = "TEST";
   s.server_time = D'2026.01.14 12:15:30';
   s.utc_time = s.server_time;
   s.digits = 2;
   s.point = 0.01;
   s.bid = s.m5.rates[0].close;
   s.ask = s.bid + 0.2;
   s.spread_points = 20;
   s.spread_avg_points = 20;
   s.spread_ratio = 1.0;
  }

void SetRegime(RegimeState &r, const ENUM_REGIME reg)
  {
   r.regime = reg;
   r.raw_regime = reg;
   r.reason = "test";
  }

StrategyCommonConfig TestCommon(void)
  {
   StrategyCommonConfig c;
   StrategyCommonDefaultConfig(c);
   c.pivot_n_m15 = 2;
   c.pivot_n_m5 = 3;
   return c;
  }

int FindDir(const TradeSignal &arr[], const ENUM_DIRECTION d)
  {
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i].direction == d)
         return i;
   return -1;
  }

#endif // XAUUSD_TESTSNAPSHOTS_MQH
