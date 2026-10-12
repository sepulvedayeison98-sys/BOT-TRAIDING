//+------------------------------------------------------------------+
//| PatternLib.mqh                                                   |
//| Detección objetiva de patrones de precio sobre TFData            |
//| (series con índice 0 = última vela CERRADA). Funciones puras,    |
//| sin estado ni acceso al terminal: las comparten las tres         |
//| estrategias para no duplicar lógica.                             |
//|                                                                  |
//| Regla anti-lookahead: un pivote en el índice k se confirma al    |
//| cerrar la vela k - n. Un evento en la vela i solo puede usar     |
//| pivotes con k >= i + n + 1 (confirmados ANTES de la vela i).     |
//+------------------------------------------------------------------+
#ifndef XAUUSD_PATTERNLIB_MQH
#define XAUUSD_PATTERNLIB_MQH

#include "Types.mqh"

struct SweepInfo
  {
   bool              found;
   bool              of_highs;     // true = barrido de máximos (sesgo bajista)
   double            level;        // precio del pivote barrido
   double            wick;         // extremo de la vela de barrido
   int               bar;          // índice de la vela de barrido
   int               swing_bar;    // índice del pivote barrido
  };

struct BreakInfo
  {
   bool              found;
   ENUM_DIRECTION    dir;
   ENUM_STRUCT_EVENT type;
   double            level;
   int               bar;
   int               swing_bar;
  };

struct ZoneInfo
  {
   bool              found;
   ENUM_DIRECTION    dir;
   double            top;
   double            bottom;
   int               bar;          // vela que define la zona (FVG: vela central; OB: la vela del OB)
   bool              touched;      // el precio volvió a la zona después de formarse
  };

struct BoxInfo
  {
   bool              found;
   ENUM_DIRECTION    dir;
   double            top;
   double            bottom;
   int               break_bar;
   bool              volume_available;
   bool              volume_expansion;
  };

struct DivergenceInfo
  {
   bool              found;
   ENUM_DIRECTION    dir;          // dirección esperada del giro
   double            price_new;
   double            price_old;
   double            rsi_new;
   double            rsi_old;
   int               bar_new;
   int               bar_old;
  };

class CPatterns
  {
public:
   static void       ResetSweep(SweepInfo &s)         { s.found = false; s.of_highs = false; s.level = 0; s.wick = 0; s.bar = -1; s.swing_bar = -1; }
   static void       ResetBreak(BreakInfo &b)         { b.found = false; b.dir = DIR_NONE; b.type = SE_NONE; b.level = 0; b.bar = -1; b.swing_bar = -1; }
   static void       ResetZone(ZoneInfo &z)           { z.found = false; z.dir = DIR_NONE; z.top = 0; z.bottom = 0; z.bar = -1; z.touched = false; }
   static void       ResetBox(BoxInfo &b)             { b.found = false; b.dir = DIR_NONE; b.top = 0; b.bottom = 0; b.break_bar = -1; b.volume_available = false; b.volume_expansion = false; }
   static void       ResetDiv(DivergenceInfo &d)      { d.found = false; d.dir = DIR_NONE; d.price_new = d.price_old = d.rsi_new = d.rsi_old = 0; d.bar_new = d.bar_old = -1; }

   //--- Vela de rechazo: mecha del lado del rechazo >= ratio del rango y cierre
   //--- en la mitad favorable.
   static bool       IsRejection(const MqlRates &r, const ENUM_DIRECTION dir, const double min_wick_ratio)
     {
      double range = r.high - r.low;
      if(range <= 0.0)
         return false;
      if(dir == DIR_LONG)
        {
         double wick = MathMin(r.open, r.close) - r.low;
         return (wick / range >= min_wick_ratio && r.close >= r.low + 0.5 * range);
        }
      if(dir == DIR_SHORT)
        {
         double wick = r.high - MathMax(r.open, r.close);
         return (wick / range >= min_wick_ratio && r.close <= r.high - 0.5 * range);
        }
      return false;
     }

   //--- Barrido: la vela i supera un pivote confirmado y aún intacto por al menos
   //--- min_pen_atr * ATR y CIERRA de vuelta del lado previo. Busca de la vela 0 a max_bar.
   static bool       FindSweep(const TFData &d, const bool of_highs, const int max_bar, const int pivot_n,
                               const double min_pen_atr, SweepInfo &out)
     {
      ResetSweep(out);
      int last = MathMin(max_bar, d.bars - 1);
      for(int i = 0; i <= last; i++)
        {
         for(int s = 0; s < d.swing_count; s++)
           {
            if(d.swings[s].is_high != of_highs)
               continue;
            int k = d.swings[s].bar_index;
            if(k < i + pivot_n + 1 || k >= d.bars)
               continue;
            double level = d.swings[s].price;
            double pen = min_pen_atr * d.atr[i];
            bool intact = true;
            for(int j = i + 1; j < k && intact; j++)
               intact = of_highs ? (d.rates[j].high < level) : (d.rates[j].low > level);
            if(!intact)
               continue;
            bool swept = of_highs ? (d.rates[i].high >= level + pen && d.rates[i].close < level)
                                  : (d.rates[i].low <= level - pen && d.rates[i].close > level);
            if(swept)
              {
               out.found = true;
               out.of_highs = of_highs;
               out.level = level;
               out.wick = of_highs ? d.rates[i].high : d.rates[i].low;
               out.bar = i;
               out.swing_bar = k;
               return true;
              }
           }
        }
      return false;
     }

   //--- Ruptura de estructura por CIERRE: la vela i cierra más allá del pivote
   //--- confirmado más reciente y la vela i+1 no lo había hecho (ruptura fresca).
   //--- Busca en [min_bar, max_bar]. El tipo depende de la estructura del TF.
   static bool       FindBreak(const TFData &d, const ENUM_DIRECTION dir, const int min_bar, const int max_bar,
                               const int pivot_n, BreakInfo &out)
     {
      ResetBreak(out);
      if(dir == DIR_NONE)
         return false;
      bool up = (dir == DIR_LONG);
      int last = MathMin(max_bar, d.bars - 2);
      for(int i = MathMax(min_bar, 0); i <= last; i++)
        {
         int sidx = -1;
         for(int s = 0; s < d.swing_count; s++)
           {
            if(d.swings[s].is_high == up && d.swings[s].bar_index >= i + pivot_n + 1)
              {
               sidx = s;
               break;   // el más reciente confirmado antes de la vela i
              }
           }
         if(sidx < 0)
            continue;
         double level = d.swings[sidx].price;
         bool broke = up ? (d.rates[i].close > level && d.rates[i + 1].close <= level)
                         : (d.rates[i].close < level && d.rates[i + 1].close >= level);
         if(!broke)
            continue;
         out.found = true;
         out.dir = dir;
         out.level = level;
         out.bar = i;
         out.swing_bar = d.swings[sidx].bar_index;
         if((up && d.structure == STRUCTURE_BULLISH) || (!up && d.structure == STRUCTURE_BEARISH))
            out.type = SE_BOS;
         else
            if((up && d.structure == STRUCTURE_BEARISH) || (!up && d.structure == STRUCTURE_BULLISH))
               out.type = SE_CHOCH;
            else
               out.type = SE_BREAK;
         return true;
        }
      return false;
     }

   //--- FVG en velas (i, i+1, i+2) con i en [min_bar, max_bar]. Alcista: low[i] > high[i+2].
   //--- Se descarta si alguna vela posterior (índice < i) lo rellenó por completo.
   static bool       FindFVG(const TFData &d, const ENUM_DIRECTION dir, const int min_bar, const int max_bar,
                             const double min_size_atr, ZoneInfo &out)
     {
      ResetZone(out);
      int last = MathMin(max_bar, d.bars - 3);
      for(int i = MathMax(min_bar, 0); i <= last; i++)
        {
         double top, bottom;
         if(dir == DIR_LONG)
           {
            if(d.rates[i].low <= d.rates[i + 2].high)
               continue;
            bottom = d.rates[i + 2].high;
            top = d.rates[i].low;
           }
         else
            if(dir == DIR_SHORT)
              {
               if(d.rates[i].high >= d.rates[i + 2].low)
                  continue;
               top = d.rates[i + 2].low;
               bottom = d.rates[i].high;
              }
            else
               return false;
         if(top - bottom < min_size_atr * d.atr[i + 1])
            continue;
         bool filled = false, touched = false;
         for(int j = 0; j < i && !filled; j++)
           {
            if(dir == DIR_LONG)
              {
               filled = (d.rates[j].low <= bottom);
               touched = touched || (d.rates[j].low <= top);
              }
            else
              {
               filled = (d.rates[j].high >= top);
               touched = touched || (d.rates[j].high >= bottom);
              }
           }
         if(filled)
            continue;
         out.found = true;
         out.dir = dir;
         out.top = top;
         out.bottom = bottom;
         out.bar = i + 1;
         out.touched = touched;
         return true;
        }
      return false;
     }

   //--- Order Block: última vela contraria antes del desplazamiento que produjo la
   //--- ruptura en break_bar (busca hasta max_back velas atrás). Inválido si una vela
   //--- posterior cerró más allá de su extremo.
   static bool       FindOrderBlock(const TFData &d, const ENUM_DIRECTION dir, const int break_bar,
                                    const int max_back, ZoneInfo &out)
     {
      ResetZone(out);
      int last = MathMin(break_bar + max_back, d.bars - 1);
      for(int i = break_bar + 1; i <= last; i++)
        {
         bool opposite = (dir == DIR_LONG) ? (d.rates[i].close < d.rates[i].open)
                                           : (d.rates[i].close > d.rates[i].open);
         if(!opposite)
            continue;
         double top = d.rates[i].high, bottom = d.rates[i].low;
         bool broken = false, touched = false;
         for(int j = 0; j < i && !broken; j++)
           {
            if(dir == DIR_LONG)
              {
               broken = (d.rates[j].close < bottom);
               if(j < break_bar)
                  touched = touched || (d.rates[j].low <= top);
              }
            else
              {
               broken = (d.rates[j].close > top);
               if(j < break_bar)
                  touched = touched || (d.rates[j].high >= bottom);
              }
           }
         if(broken)
            return false;
         out.found = true;
         out.dir = dir;
         out.top = top;
         out.bottom = bottom;
         out.bar = i;
         out.touched = touched;
         return true;
        }
      return false;
     }

   //--- Consolidación + ruptura: caja = velas [k+1, k+box_bars] con altura <=
   //--- max_box_atr * ATR; la vela k cierra fuera por >= min_break_atr * ATR con cuerpo
   //--- >= min_body_ratio del rango; ninguna vela posterior (índice < k) volvió a cerrar
   //--- dentro de la caja. Busca k en [0, max_k].
   static bool       FindBoxBreakout(const TFData &d, const ENUM_DIRECTION dir, const int max_k, const int box_bars,
                                     const double max_box_atr, const double min_break_atr,
                                     const double min_body_ratio, const double min_vol_ratio, BoxInfo &out)
     {
      ResetBox(out);
      if(dir == DIR_NONE || box_bars < 2)
         return false;
      int last = MathMin(max_k, d.bars - box_bars - 1);
      for(int k = 0; k <= last; k++)
        {
         double hi = d.rates[k + 1].high, lo = d.rates[k + 1].low;
         double vol_sum = 0.0;
         for(int j = k + 1; j <= k + box_bars; j++)
           {
            hi = MathMax(hi, d.rates[j].high);
            lo = MathMin(lo, d.rates[j].low);
            vol_sum += (double)d.rates[j].tick_volume;
           }
         double atr = d.atr[k + 1];
         if(atr <= 0.0 || hi - lo > max_box_atr * atr)
            continue;
         const MqlRates b = d.rates[k];
         double range = b.high - b.low;
         if(range <= 0.0 || MathAbs(b.close - b.open) < min_body_ratio * range)
            continue;
         bool out_up = (b.close >= hi + min_break_atr * atr && b.close > b.open);
         bool out_dn = (b.close <= lo - min_break_atr * atr && b.close < b.open);
         if((dir == DIR_LONG && !out_up) || (dir == DIR_SHORT && !out_dn))
            continue;
         bool failed = false;
         for(int j = 0; j < k && !failed; j++)
            failed = (dir == DIR_LONG) ? (d.rates[j].close < hi) : (d.rates[j].close > lo);
         if(failed)
            continue;
         double vol_mean = vol_sum / box_bars;
         out.found = true;
         out.dir = dir;
         out.top = hi;
         out.bottom = lo;
         out.break_bar = k;
         out.volume_available = (vol_mean > 0.0);
         out.volume_expansion = out.volume_available && ((double)b.tick_volume >= min_vol_ratio * vol_mean);
         return true;
        }
      return false;
     }

   //--- Divergencia RSI con los dos pivotes más recientes del lado indicado.
   //--- Alcista: mínimo nuevo más bajo en precio y RSI más alto en >= min_rsi_diff.
   //--- El pivote nuevo debe estar a <= max_age velas.
   static bool       FindRsiDivergence(const TFData &d, const ENUM_DIRECTION dir, const double min_rsi_diff,
                                       const int max_age, DivergenceInfo &out)
     {
      ResetDiv(out);
      bool lows = (dir == DIR_LONG);
      int a = -1, b = -1;
      for(int s = 0; s < d.swing_count; s++)
        {
         if(d.swings[s].is_high == lows)
            continue;
         if(a < 0)
            a = s;
         else
           {
            b = s;
            break;
           }
        }
      if(a < 0 || b < 0)
         return false;
      int ka = d.swings[a].bar_index, kb = d.swings[b].bar_index;
      if(ka > max_age || ka >= ArraySize(d.rsi) || kb >= ArraySize(d.rsi))
         return false;
      double pa = d.swings[a].price, pb = d.swings[b].price;
      double ra = d.rsi[ka], rb = d.rsi[kb];
      bool div = lows ? (pa < pb && ra >= rb + min_rsi_diff) : (pa > pb && ra <= rb - min_rsi_diff);
      if(!div)
         return false;
      out.found = true;
      out.dir = dir;
      out.price_new = pa;
      out.price_old = pb;
      out.rsi_new = ra;
      out.rsi_old = rb;
      out.bar_new = ka;
      out.bar_old = kb;
      return true;
     }

   //--- Extremos de un tramo de velas [from, to] (ambos incluidos)
   static double     HighestHigh(const TFData &d, const int from, const int to)
     {
      double h = -DBL_MAX;
      for(int i = MathMax(from, 0); i <= MathMin(to, d.bars - 1); i++)
         h = MathMax(h, d.rates[i].high);
      return h;
     }

   static double     LowestLow(const TFData &d, const int from, const int to)
     {
      double l = DBL_MAX;
      for(int i = MathMax(from, 0); i <= MathMin(to, d.bars - 1); i++)
         l = MathMin(l, d.rates[i].low);
      return l;
     }

   //--- Rango de la sesión asiática más reciente (00:00-07:00 UTC) ya cerrada en el TF.
   //--- utc_offset_sec = hora servidor - UTC. Devuelve false si no hay velas.
   static bool       AsiaRange(const TFData &d, const int utc_offset_sec, double &hi, double &lo)
     {
      hi = -DBL_MAX;
      lo = DBL_MAX;
      int day = -1;
      for(int i = 0; i < d.bars; i++)
        {
         datetime utc = d.rates[i].time - utc_offset_sec;
         int sod = (int)(utc % 86400);
         int dkey = (int)(utc / 86400);
         if(sod >= 7 * 3600)
           {
            if(day >= 0)
               break;      // ya pasamos la sesión asiática más reciente
            continue;
           }
         if(day < 0)
            day = dkey;
         if(dkey != day)
            break;
         hi = MathMax(hi, d.rates[i].high);
         lo = MathMin(lo, d.rates[i].low);
        }
      return (day >= 0 && hi > lo);
     }
  };

#endif // XAUUSD_PATTERNLIB_MQH
