//+------------------------------------------------------------------+
//| MarketEngine.mqh                                                 |
//| Obtiene y valida datos de H1, M15 y M5; calcula EMA, RSI, ADX,   |
//| ATR, pivotes confirmados, estructura, volatilidad, momentum y    |
//| spread. NO ejecuta operaciones ni decide entradas.               |
//|                                                                  |
//| Convención: todas las series son "as series" e índice 0 = última |
//| vela CERRADA en el instante de decisión. La vela en formación    |
//| nunca se usa para indicadores ni estructura.                     |
//|                                                                  |
//| Instante de decisión = apertura de la vela M5 actual. Para cada  |
//| TF se copian, por posición (iBarShift), las velas abiertas en o  |
//| antes de (decisión - período): las ya cerradas en ese instante.  |
//| (CopyRates por fecha dio resultados incorrectos con símbolos     |
//| personalizados en pruebas; por posición es consistente.)         |
//| El mismo camino sirve en vivo (Update) y para reconstruir un     |
//| instante histórico (UpdateAt) sin mirar el futuro.               |
//+------------------------------------------------------------------+
#ifndef XAUUSD_MARKETENGINE_MQH
#define XAUUSD_MARKETENGINE_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "SessionClock.mqh"

#define ME_TF_COUNT 3
#define ME_MODULE   "MarketEngine"

//+------------------------------------------------------------------+
//| Algoritmos puros (sin dependencia del terminal) → testeables.    |
//+------------------------------------------------------------------+
class CMarketAlgo
  {
public:
   //--- Velas coherentes y ordenadas (índice 0 = más reciente).
   static bool       ValidateRates(const MqlRates &r[], const int count, string &reason)
     {
      if(count <= 0 || ArraySize(r) < count)
        {
         reason = "sin velas";
         return false;
        }
      for(int i = 0; i < count; i++)
        {
         if(r[i].open <= 0.0 || r[i].high <= 0.0 || r[i].low <= 0.0 || r[i].close <= 0.0)
           {
            reason = StringFormat("precio no positivo en vela %d", i);
            return false;
           }
         if(r[i].high < r[i].low ||
            r[i].high < MathMax(r[i].open, r[i].close) ||
            r[i].low > MathMin(r[i].open, r[i].close))
           {
            reason = StringFormat("OHLC incoherente en vela %d (%s)", i, TimeToString(r[i].time));
            return false;
           }
         if(i > 0 && r[i].time >= r[i - 1].time)
           {
            reason = StringFormat("orden temporal inválido en vela %d", i);
            return false;
           }
        }
      reason = "";
      return true;
     }

   //--- Valores finitos, distintos de EMPTY_VALUE y dentro de [min_v, max_v].
   static bool       ValidateSeries(const double &a[], const int count, const double min_v,
                                    const double max_v, string &reason)
     {
      if(ArraySize(a) < count)
        {
         reason = "serie incompleta";
         return false;
        }
      for(int i = 0; i < count; i++)
        {
         if(!MathIsValidNumber(a[i]) || a[i] == EMPTY_VALUE || a[i] < min_v || a[i] > max_v)
           {
            reason = StringFormat("valor inválido en índice %d: %g", i, a[i]);
            return false;
           }
        }
      reason = "";
      return true;
     }

   static double     Mean(const double &a[], const int from, const int count)
     {
      if(count <= 0 || from < 0 || from + count > ArraySize(a))
         return 0.0;
      double s = 0.0;
      for(int i = from; i < from + count; i++)
         s += a[i];
      return s / count;
     }

   //--- Pivotes confirmados. Un máximo en i es pivote si high[i] es ESTRICTAMENTE
   //--- mayor que los n highs a cada lado. Requiere i >= n (n velas cerradas más
   //--- recientes) e i + n < count. Resultado ordenado del más reciente al más antiguo.
   static int        FindSwings(const MqlRates &r[], const int count, const int n,
                                const int max_out, SwingPoint &out[])
     {
      ArrayResize(out, 0);
      if(n < 1 || count < 2 * n + 1 || ArraySize(r) < count)
         return 0;
      int found = 0;
      for(int i = n; i < count - n && found < max_out; i++)
        {
         bool is_high = true;
         bool is_low = true;
         for(int j = i - n; j <= i + n; j++)
           {
            if(j == i)
               continue;
            if(r[j].high >= r[i].high)
               is_high = false;
            if(r[j].low <= r[i].low)
               is_low = false;
            if(!is_high && !is_low)
               break;
           }
         if(is_high && found < max_out)
           {
            ArrayResize(out, found + 1);
            out[found].time = r[i].time;
            out[found].price = r[i].high;
            out[found].is_high = true;
            out[found].bar_index = i;
            found++;
           }
         if(is_low && found < max_out)
           {
            ArrayResize(out, found + 1);
            out[found].time = r[i].time;
            out[found].price = r[i].low;
            out[found].is_high = false;
            out[found].bar_index = i;
            found++;
           }
        }
      return found;
     }

   //--- Estructura con los dos pivotes altos y dos bajos más recientes.
   static ENUM_MARKET_STRUCTURE ClassifyStructure(const SwingPoint &sw[], const int count)
     {
      double highs[2], lows[2];
      int nh = 0, nl = 0;
      for(int i = 0; i < count && (nh < 2 || nl < 2); i++)
        {
         if(sw[i].is_high && nh < 2)
            highs[nh++] = sw[i].price;
         else
            if(!sw[i].is_high && nl < 2)
               lows[nl++] = sw[i].price;
        }
      if(nh < 2 || nl < 2)
         return STRUCTURE_UNKNOWN;
      // índice 0 = más reciente
      bool hh = highs[0] > highs[1];
      bool hl = lows[0] > lows[1];
      bool lh = highs[0] < highs[1];
      bool ll = lows[0] < lows[1];
      if(hh && hl)
         return STRUCTURE_BULLISH;
      if(lh && ll)
         return STRUCTURE_BEARISH;
      return STRUCTURE_MIXED;
     }

   //--- (a[from] - a[from+k]) / norm. Devuelve 0 si no hay datos o norm <= 0.
   static double     NormalizedSlope(const double &a[], const int from, const int k, const double norm)
     {
      if(k <= 0 || norm <= 0.0 || from < 0 || from + k >= ArraySize(a))
         return 0.0;
      return (a[from] - a[from + k]) / norm;
     }

   //--- Cambio de momentum: el signo de la pendiente cambió (ignora |pendiente| < umbral).
   static bool       MomentumShift(const double slope_prev, const double slope_now, const double min_abs)
     {
      if(MathAbs(slope_prev) < min_abs || MathAbs(slope_now) < min_abs)
         return false;
      return (slope_prev > 0.0) != (slope_now > 0.0);
     }

   //--- Spread medio (en puntos) de MqlRates.spread. 0 si el bróker no lo provee.
   static double     AverageRatesSpread(const MqlRates &r[], const int count)
     {
      int n = MathMin(count, ArraySize(r));
      if(n <= 0)
         return 0.0;
      double s = 0.0;
      int valid = 0;
      for(int i = 0; i < n; i++)
        {
         if(r[i].spread > 0)
           {
            s += r[i].spread;
            valid++;
           }
        }
      // si menos de la mitad de las velas tiene spread, no es una referencia fiable
      if(valid < n / 2 || valid == 0)
         return 0.0;
      return s / valid;
     }

   static void       RangeOf(const MqlRates &r[], const int count, double &hi, double &lo)
     {
      hi = 0.0;
      lo = 0.0;
      int n = MathMin(count, ArraySize(r));
      if(n <= 0)
         return;
      hi = r[0].high;
      lo = r[0].low;
      for(int i = 1; i < n; i++)
        {
         if(r[i].high > hi)
            hi = r[i].high;
         if(r[i].low < lo)
            lo = r[i].low;
        }
     }
  };

//+------------------------------------------------------------------+
//| Configuración                                                    |
//+------------------------------------------------------------------+
struct MarketEngineConfig
  {
   string            symbol;
   int               ema_fast_period;
   int               ema_slow_period;
   int               rsi_period;
   int               adx_period;
   int               atr_period;
   int               analysis_bars;       // velas cerradas cargadas por TF
   int               min_history_bars;    // historial mínimo exigido en el terminal
   int               pivot_n_h1;
   int               pivot_n_m15;
   int               pivot_n_m5;
   int               max_swings;
   int               atr_avg_window;
   int               slope_lookback;
   double            momentum_min_slope;  // |pendiente| mínima (en ATR) para considerar cambio de momentum
   int               spread_avg_bars;
   int               max_tick_age_sec;
   double            stale_bar_factor;    // vela considerada desactualizada si supera factor x período
  };

void MarketEngineDefaultConfig(MarketEngineConfig &c, const string symbol)
  {
   c.symbol = symbol;
   c.ema_fast_period = 50;
   c.ema_slow_period = 200;
   c.rsi_period = 14;
   c.adx_period = 14;
   c.atr_period = 14;
   c.analysis_bars = 200;
   c.min_history_bars = 700;
   c.pivot_n_h1 = 2;
   c.pivot_n_m15 = 3;
   c.pivot_n_m5 = 3;
   c.max_swings = 30;
   c.atr_avg_window = 100;
   c.slope_lookback = 5;
   c.momentum_min_slope = 0.05;
   c.spread_avg_bars = 50;
   c.max_tick_age_sec = 120;
   c.stale_bar_factor = 2.0;
  }

bool MarketEngineValidateConfig(const MarketEngineConfig &c, string &reason)
  {
   if(StringLen(c.symbol) == 0)
     { reason = "símbolo vacío"; return false; }
   if(c.ema_fast_period < 2 || c.ema_slow_period <= c.ema_fast_period)
     { reason = "períodos EMA inválidos (requiere 2 <= rápida < lenta)"; return false; }
   if(c.rsi_period < 2 || c.adx_period < 2 || c.atr_period < 2)
     { reason = "períodos RSI/ADX/ATR deben ser >= 2"; return false; }
   if(c.pivot_n_h1 < 1 || c.pivot_n_m15 < 1 || c.pivot_n_m5 < 1)
     { reason = "N de pivotes debe ser >= 1"; return false; }
   if(c.atr_avg_window < 2 || c.slope_lookback < 1)
     { reason = "ventana ATR o lookback de pendiente inválidos"; return false; }
   if(c.analysis_bars < c.atr_avg_window || c.analysis_bars < 2 * c.slope_lookback + 1 ||
      c.analysis_bars < c.spread_avg_bars)
     { reason = "analysis_bars insuficiente para ventanas configuradas"; return false; }
   if(c.min_history_bars < c.analysis_bars + c.ema_slow_period)
     { reason = "min_history_bars debe ser >= analysis_bars + EMA lenta"; return false; }
   if(c.max_swings < 4)
     { reason = "max_swings debe ser >= 4"; return false; }
   if(c.max_tick_age_sec < 1 || c.stale_bar_factor < 1.0)
     { reason = "umbrales de frescura inválidos"; return false; }
   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Motor de mercado                                                 |
//+------------------------------------------------------------------+
class CMarketEngine
  {
private:
   MarketEngineConfig m_cfg;
   CLogger          *m_log;
   CSessionClock    *m_clock;
   bool              m_ready;
   ENUM_TIMEFRAMES   m_tfs[ME_TF_COUNT];
   int               m_pivot_n[ME_TF_COUNT];
   int               m_h_ema_fast[ME_TF_COUNT];
   int               m_h_ema_slow[ME_TF_COUNT];
   int               m_h_rsi[ME_TF_COUNT];
   int               m_h_adx[ME_TF_COUNT];
   int               m_h_atr[ME_TF_COUNT];
   datetime          m_last_bar[ME_TF_COUNT];
   int               m_init_digits;
   double            m_init_point;
   double            m_tick_spread_ema;
   int               m_tick_spread_samples;

   void              ReleaseHandles(void)
     {
      for(int i = 0; i < ME_TF_COUNT; i++)
        {
         if(m_h_ema_fast[i] != INVALID_HANDLE) IndicatorRelease(m_h_ema_fast[i]);
         if(m_h_ema_slow[i] != INVALID_HANDLE) IndicatorRelease(m_h_ema_slow[i]);
         if(m_h_rsi[i] != INVALID_HANDLE)      IndicatorRelease(m_h_rsi[i]);
         if(m_h_adx[i] != INVALID_HANDLE)      IndicatorRelease(m_h_adx[i]);
         if(m_h_atr[i] != INVALID_HANDLE)      IndicatorRelease(m_h_atr[i]);
         m_h_ema_fast[i] = m_h_ema_slow[i] = m_h_rsi[i] = m_h_adx[i] = m_h_atr[i] = INVALID_HANDLE;
        }
     }

   void              LogMsg(const ENUM_LOG_LEVEL lvl, const string event, const string msg)
     {
      if(m_log != NULL)
         m_log.Log(lvl, ME_MODULE, event, msg);
      else
         PrintFormat("[%s][%s] %s", ME_MODULE, event, msg);
     }

   bool              CopySeries(const int handle, const int buffer, const int shift, const int count,
                                double &dst[], string &reason)
     {
      ArraySetAsSeries(dst, true);
      ResetLastError();
      int got = CopyBuffer(handle, buffer, shift, count, dst);
      if(got != count)
        {
         reason = StringFormat("CopyBuffer devolvió %d de %d (err=%d)", got, count, GetLastError());
         return false;
        }
      return true;
     }

   bool              IndicatorReady(const int handle, const int needed, const string name, string &reason)
     {
      int calc = BarsCalculated(handle);
      if(calc < needed)
        {
         reason = StringFormat("%s no calculado (%d/%d)", name, calc, needed);
         return false;
        }
      return true;
     }

   //--- decision_time: apertura de la vela M5 en la que se decide.
   //--- freshness_ref: hora contra la que se mide la frescura (en vivo, la hora del servidor).
   bool              FillTF(const int idx, TFData &d, const datetime decision_time, const datetime freshness_ref)
     {
      string reason = "";
      ENUM_TIMEFRAMES tf = m_tfs[idx];
      string tfname = EnumToString(tf);
      int need = m_cfg.analysis_bars;
      d.tf = tf;
      d.valid = false;
      d.bars = 0;
      d.swing_count = 0;
      d.structure = STRUCTURE_UNKNOWN;
      d.atr_ratio = 0.0;
      d.ema_slope = 0.0;
      d.ema_slope_prev = 0.0;
      d.momentum_shift = false;

      if(SeriesInfoInteger(m_cfg.symbol, tf, SERIES_SYNCHRONIZED) == 0)
        {
         d.invalid_reason = tfname + ": historial no sincronizado";
         return false;
        }
      long period = PeriodSeconds(tf);
      datetime start = decision_time - (datetime)period;   // última vela que ya cerró en decision_time
      datetime first = (datetime)SeriesInfoInteger(m_cfg.symbol, tf, SERIES_FIRSTDATE);
      int bars = (first > 0 && first <= start) ? Bars(m_cfg.symbol, tf, first, start) : 0;
      if(bars < m_cfg.min_history_bars)
        {
         // Pide al terminal las velas que faltan: copiar datos ausentes inicia su descarga desde el
         // servidor (asíncrona). Se reintenta en cada evaluación hasta completar el historial.
         datetime req[];
         CopyTime(m_cfg.symbol, tf, start, m_cfg.min_history_bars, req);
         datetime server_first = (datetime)SeriesInfoInteger(m_cfg.symbol, tf, SERIES_SERVER_FIRSTDATE);
         d.invalid_reason = StringFormat("%s: historial insuficiente antes de %s (%d < %d; descargando, servidor desde %s)", tfname,
                                         TimeToString(start), bars, m_cfg.min_history_bars,
                                         (server_first > 0 ? TimeToString(server_first, TIME_DATE) : "?"));
         return false;
        }
      //--- velas cerradas: índice de la última vela abierta en o antes de `start`.
      //--- Se copia por posición (precios e indicadores con el mismo índice).
      int shift = iBarShift(m_cfg.symbol, tf, start, false);
      if(shift < 0)
        {
         d.invalid_reason = StringFormat("%s: iBarShift falló para %s (err=%d)", tfname, TimeToString(start), GetLastError());
         return false;
        }
      ArraySetAsSeries(d.rates, true);
      ResetLastError();
      int got = CopyRates(m_cfg.symbol, tf, shift, need, d.rates);
      if(got != need)
        {
         d.invalid_reason = StringFormat("%s: CopyRates %d/%d (err=%d)", tfname, got, need, GetLastError());
         return false;
        }
      if(d.rates[0].time > start)
        {
         d.invalid_reason = StringFormat("%s: vela no cerrada en el instante de decisión", tfname);
         return false;
        }
      if(!CMarketAlgo::ValidateRates(d.rates, need, reason))
        {
         d.invalid_reason = tfname + ": " + reason;
         return false;
        }
      //--- frescura: la última vela cerrada debe terminar cerca del instante de referencia
      datetime expected_close = d.rates[0].time + (datetime)period;
      if((double)(freshness_ref - expected_close) > m_cfg.stale_bar_factor * (double)period)
        {
         d.invalid_reason = StringFormat("%s: datos desactualizados (última vela cerrada %s, referencia %s)",
                                         tfname, TimeToString(d.rates[0].time), TimeToString(freshness_ref));
         return false;
        }
      //--- indicadores
      int ind_needed = m_cfg.min_history_bars;
      if(!IndicatorReady(m_h_ema_fast[idx], ind_needed, "EMA rápida", reason) ||
         !IndicatorReady(m_h_ema_slow[idx], ind_needed, "EMA lenta", reason) ||
         !IndicatorReady(m_h_rsi[idx], ind_needed, "RSI", reason) ||
         !IndicatorReady(m_h_adx[idx], ind_needed, "ADX", reason) ||
         !IndicatorReady(m_h_atr[idx], ind_needed, "ATR", reason))
        {
         d.invalid_reason = tfname + ": " + reason;
         return false;
        }
      if(!CopySeries(m_h_ema_fast[idx], 0, shift, need, d.ema_fast, reason) ||
         !CopySeries(m_h_ema_slow[idx], 0, shift, need, d.ema_slow, reason) ||
         !CopySeries(m_h_rsi[idx], 0, shift, need, d.rsi, reason) ||
         !CopySeries(m_h_adx[idx], 0, shift, need, d.adx, reason) ||       // MAIN_LINE
         !CopySeries(m_h_adx[idx], 1, shift, need, d.plus_di, reason) ||   // PLUSDI_LINE
         !CopySeries(m_h_adx[idx], 2, shift, need, d.minus_di, reason) ||  // MINUSDI_LINE
         !CopySeries(m_h_atr[idx], 0, shift, need, d.atr, reason))
        {
         d.invalid_reason = tfname + ": " + reason;
         return false;
        }
      double big = 1e9;
      if(!CMarketAlgo::ValidateSeries(d.ema_fast, need, 1e-9, big, reason) ||
         !CMarketAlgo::ValidateSeries(d.ema_slow, need, 1e-9, big, reason) ||
         !CMarketAlgo::ValidateSeries(d.rsi, need, 0.0, 100.0, reason) ||
         !CMarketAlgo::ValidateSeries(d.adx, need, 0.0, 100.0, reason) ||
         !CMarketAlgo::ValidateSeries(d.plus_di, need, 0.0, 100.0, reason) ||
         !CMarketAlgo::ValidateSeries(d.minus_di, need, 0.0, 100.0, reason) ||
         !CMarketAlgo::ValidateSeries(d.atr, need, 1e-9, big, reason))
        {
         d.invalid_reason = tfname + ": indicador " + reason;
         return false;
        }
      //--- derivados
      d.bars = need;
      d.last_closed_time = d.rates[0].time;
      d.swing_count = CMarketAlgo::FindSwings(d.rates, need, m_pivot_n[idx], m_cfg.max_swings, d.swings);
      d.structure = CMarketAlgo::ClassifyStructure(d.swings, d.swing_count);
      double atr_avg = CMarketAlgo::Mean(d.atr, 0, m_cfg.atr_avg_window);
      d.atr_ratio = (atr_avg > 0.0) ? d.atr[0] / atr_avg : 0.0;
      int k = m_cfg.slope_lookback;
      d.ema_slope = CMarketAlgo::NormalizedSlope(d.ema_fast, 0, k, d.atr[0]);
      d.ema_slope_prev = CMarketAlgo::NormalizedSlope(d.ema_fast, k, k, d.atr[k]);
      d.momentum_shift = CMarketAlgo::MomentumShift(d.ema_slope_prev, d.ema_slope, m_cfg.momentum_min_slope);
      CMarketAlgo::RangeOf(d.rates, need, d.range_high, d.range_low);
      d.valid = true;
      d.invalid_reason = "";
      return true;
     }

   bool              BeginSnapshot(MarketSnapshot &snap)
     {
      snap.valid = false;
      snap.symbol = m_cfg.symbol;
      snap.invalid_reason = "";
      if(!m_ready)
        {
         snap.invalid_reason = "MarketEngine no inicializado";
         return false;
        }
      //--- protección ante cambio de especificación del símbolo
      int digits = (int)SymbolInfoInteger(m_cfg.symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(m_cfg.symbol, SYMBOL_POINT);
      if(digits != m_init_digits || point != m_init_point)
        {
         snap.invalid_reason = StringFormat("especificación del símbolo cambió (digits %d->%d, point %g->%g)",
                                            m_init_digits, digits, m_init_point, point);
         LogMsg(LOG_CRITICAL, "SYMBOL_SPEC_CHANGED", snap.invalid_reason);
         return false;
        }
      snap.digits = digits;
      snap.point = point;
      return true;
     }

   bool              SetTime(MarketSnapshot &snap)
     {
      if(!m_clock.OffsetValid())
        {
         snap.invalid_reason = "offset horario inválido: " + m_clock.LastError();
         return false;
        }
      snap.utc_time = m_clock.ServerToUtc(snap.server_time);
      snap.session = m_clock.SessionAtUtc(snap.utc_time);
      return true;
     }

   bool              FillAll(MarketSnapshot &snap, const datetime decision, const datetime freshness_ref,
                             const bool live)
     {
      bool ok_h1 = FillTF(0, snap.h1, decision, freshness_ref);
      bool ok_m15 = FillTF(1, snap.m15, decision, freshness_ref);
      bool ok_m5 = FillTF(2, snap.m5, decision, freshness_ref);
      //--- spread de referencia
      snap.spread_avg_points = CMarketAlgo::AverageRatesSpread(snap.m5.rates, MathMin(m_cfg.spread_avg_bars, snap.m5.bars));
      if(live && snap.spread_avg_points <= 0.0 && m_tick_spread_samples >= 100)
         snap.spread_avg_points = m_tick_spread_ema;
      snap.spread_ratio = (snap.spread_avg_points > 0.0) ? snap.spread_points / snap.spread_avg_points : 0.0;
      if(!ok_h1 || !ok_m15 || !ok_m5)
        {
         snap.invalid_reason = (!ok_h1 ? snap.h1.invalid_reason :
                                (!ok_m15 ? snap.m15.invalid_reason : snap.m5.invalid_reason));
         return false;
        }
      snap.valid = true;
      return true;
     }

public:
                     CMarketEngine(void)
     {
      m_log = NULL;
      m_clock = NULL;
      m_ready = false;
      m_tfs[0] = PERIOD_H1;
      m_tfs[1] = PERIOD_M15;
      m_tfs[2] = PERIOD_M5;
      for(int i = 0; i < ME_TF_COUNT; i++)
        {
         m_h_ema_fast[i] = m_h_ema_slow[i] = m_h_rsi[i] = m_h_adx[i] = m_h_atr[i] = INVALID_HANDLE;
         m_last_bar[i] = 0;
         m_pivot_n[i] = 3;
        }
      m_init_digits = 0;
      m_init_point = 0.0;
      m_tick_spread_ema = 0.0;
      m_tick_spread_samples = 0;
     }

                    ~CMarketEngine(void) { ReleaseHandles(); }

   bool              Init(const MarketEngineConfig &cfg, CLogger *log, CSessionClock *clock)
     {
      m_log = log;
      m_clock = clock;
      m_ready = false;
      string reason;
      if(!MarketEngineValidateConfig(cfg, reason))
        {
         LogMsg(LOG_CRITICAL, "CONFIG_INVALID", reason);
         return false;
        }
      if(m_clock == NULL)
        {
         LogMsg(LOG_CRITICAL, "INIT_FAILED", "SessionClock no proporcionado");
         return false;
        }
      m_cfg = cfg;
      if(!SymbolSelect(m_cfg.symbol, true))
        {
         LogMsg(LOG_CRITICAL, "SYMBOL_INVALID", "no se pudo seleccionar " + m_cfg.symbol);
         return false;
        }
      m_init_digits = (int)SymbolInfoInteger(m_cfg.symbol, SYMBOL_DIGITS);
      m_init_point = SymbolInfoDouble(m_cfg.symbol, SYMBOL_POINT);
      if(m_init_point <= 0.0)
        {
         LogMsg(LOG_CRITICAL, "SYMBOL_INVALID", "SYMBOL_POINT inválido");
         return false;
        }
      m_pivot_n[0] = cfg.pivot_n_h1;
      m_pivot_n[1] = cfg.pivot_n_m15;
      m_pivot_n[2] = cfg.pivot_n_m5;
      ReleaseHandles();
      for(int i = 0; i < ME_TF_COUNT; i++)
        {
         ENUM_TIMEFRAMES tf = m_tfs[i];
         m_h_ema_fast[i] = iMA(m_cfg.symbol, tf, m_cfg.ema_fast_period, 0, MODE_EMA, PRICE_CLOSE);
         m_h_ema_slow[i] = iMA(m_cfg.symbol, tf, m_cfg.ema_slow_period, 0, MODE_EMA, PRICE_CLOSE);
         m_h_rsi[i] = iRSI(m_cfg.symbol, tf, m_cfg.rsi_period, PRICE_CLOSE);
         m_h_adx[i] = iADX(m_cfg.symbol, tf, m_cfg.adx_period);
         m_h_atr[i] = iATR(m_cfg.symbol, tf, m_cfg.atr_period);
         if(m_h_ema_fast[i] == INVALID_HANDLE || m_h_ema_slow[i] == INVALID_HANDLE ||
            m_h_rsi[i] == INVALID_HANDLE || m_h_adx[i] == INVALID_HANDLE || m_h_atr[i] == INVALID_HANDLE)
           {
            LogMsg(LOG_CRITICAL, "HANDLE_FAILED",
                   StringFormat("no se pudo crear indicador en %s (err=%d)", EnumToString(tf), GetLastError()));
            ReleaseHandles();
            return false;
           }
        }
      m_ready = true;
      LogMsg(LOG_INFO, "INIT_OK",
             StringFormat("%s digits=%d point=%g bars=%d EMA%d/%d RSI%d ADX%d ATR%d",
                          m_cfg.symbol, m_init_digits, m_init_point, m_cfg.analysis_bars,
                          m_cfg.ema_fast_period, m_cfg.ema_slow_period, m_cfg.rsi_period,
                          m_cfg.adx_period, m_cfg.atr_period));
      return true;
     }

   void              Deinit(void) { ReleaseHandles(); m_ready = false; }
   bool              Ready(void) const { return m_ready; }
   string            GetSymbol(void) const { return m_cfg.symbol; }

   //--- true una vez por cada nueva vela abierta en tf (es decir, la anterior acaba de cerrar).
   bool              IsNewBar(const ENUM_TIMEFRAMES tf)
     {
      for(int i = 0; i < ME_TF_COUNT; i++)
        {
         if(m_tfs[i] != tf)
            continue;
         datetime t = (datetime)SeriesInfoInteger(m_cfg.symbol, tf, SERIES_LASTBAR_DATE);
         if(t == 0)
            return false;
         if(t != m_last_bar[i])
           {
            bool first = (m_last_bar[i] == 0);
            m_last_bar[i] = t;
            return !first;   // la primera lectura tras Init no cuenta como vela nueva
           }
         return false;
        }
      return false;
     }

   //--- Muestreo de spread por tick (EMA). Referencia de respaldo si MqlRates.spread no está disponible.
   void              SampleTickSpread(void)
     {
      MqlTick t;
      if(!SymbolInfoTick(m_cfg.symbol, t) || t.bid <= 0.0 || t.ask < t.bid || m_init_point <= 0.0)
         return;
      double sp = (t.ask - t.bid) / m_init_point;
      const double alpha = 0.01;
      if(m_tick_spread_samples == 0)
         m_tick_spread_ema = sp;
      else
         m_tick_spread_ema = alpha * sp + (1.0 - alpha) * m_tick_spread_ema;
      m_tick_spread_samples++;
     }

   //--- Instantánea en vivo. Instante de decisión = apertura de la vela M5 actual.
   bool              Update(MarketSnapshot &snap)
     {
      if(!BeginSnapshot(snap))
         return false;
      snap.server_time = TimeTradeServer();
      if(!SetTime(snap))
         return false;
      //--- precio actual
      MqlTick tick;
      if(!SymbolInfoTick(m_cfg.symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0 || tick.ask < tick.bid)
        {
         snap.invalid_reason = "tick inválido o no disponible";
         return false;
        }
      snap.tick_time = tick.time;
      snap.bid = tick.bid;
      snap.ask = tick.ask;
      long tick_age = (long)(snap.server_time - tick.time);
      if(tick_age > m_cfg.max_tick_age_sec)
        {
         snap.invalid_reason = StringFormat("último tick con %d s de antigüedad", tick_age);
         return false;
        }
      snap.spread_points = (tick.ask - tick.bid) / snap.point;
      datetime decision = (datetime)SeriesInfoInteger(m_cfg.symbol, PERIOD_M5, SERIES_LASTBAR_DATE);
      if(decision <= 0)
        {
         snap.invalid_reason = "sin vela M5 actual";
         return false;
        }
      return FillAll(snap, decision, snap.server_time, true);
     }

   //--- Instantánea histórica tal como se habría visto al abrir la vela M5 de
   //--- decision_time (solo velas cerradas antes de ese instante). Precio = cierre de
   //--- la última vela M5 cerrada; spread = MqlRates.spread de esa vela. Para análisis
   //--- y pruebas: no sustituye al Strategy Tester (no simula ticks ni ejecución).
   bool              UpdateAt(const datetime decision_time, MarketSnapshot &snap)
     {
      if(!BeginSnapshot(snap))
         return false;
      snap.server_time = decision_time;
      if(!SetTime(snap))
         return false;
      if(!FillAll(snap, decision_time, decision_time, false))
         return false;
      snap.tick_time = decision_time;
      snap.bid = snap.m5.rates[0].close;
      snap.spread_points = (double)snap.m5.rates[0].spread;
      snap.ask = snap.bid + snap.spread_points * snap.point;
      snap.spread_ratio = (snap.spread_avg_points > 0.0) ? snap.spread_points / snap.spread_avg_points : 0.0;
      return true;
     }

   //--- Resumen de una línea para logs/diagnóstico
   static string     Describe(const MarketSnapshot &s)
     {
      if(!s.valid)
         return "INVALID: " + s.invalid_reason;
      return StringFormat("srv=%s utc=%s ses=%s bid=%.*f spread=%.1f(avg %.1f) | "
                          "H1 ema%.2f/%.2f rsi=%.1f adx=%.1f atr=%.2f atrR=%.2f st=%s | "
                          "M15 rsi=%.1f adx=%.1f atr=%.2f st=%s sw=%d | "
                          "M5 rsi=%.1f atr=%.2f slope=%.3f shift=%s st=%s",
                          TimeToString(s.server_time, TIME_DATE | TIME_MINUTES),
                          TimeToString(s.utc_time, TIME_MINUTES), EnumSessionToString(s.session),
                          s.digits, s.bid, s.spread_points, s.spread_avg_points,
                          s.h1.ema_fast[0], s.h1.ema_slow[0], s.h1.rsi[0], s.h1.adx[0], s.h1.atr[0],
                          s.h1.atr_ratio, EnumStructureToString(s.h1.structure),
                          s.m15.rsi[0], s.m15.adx[0], s.m15.atr[0], EnumStructureToString(s.m15.structure),
                          s.m15.swing_count,
                          s.m5.rsi[0], s.m5.atr[0], s.m5.ema_slope, (s.m5.momentum_shift ? "yes" : "no"),
                          EnumStructureToString(s.m5.structure));
     }
  };

#endif // XAUUSD_MARKETENGINE_MQH
