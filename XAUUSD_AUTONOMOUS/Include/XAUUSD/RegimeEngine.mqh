//+------------------------------------------------------------------+
//| RegimeEngine.mqh                                                 |
//| Clasifica el mercado en TREND_UP, TREND_DOWN, RANGE,             |
//| HIGH_VOLATILITY o NO_TRADE a partir del MarketSnapshot.          |
//| No lee datos del servidor ni ejecuta operaciones.                |
//|                                                                  |
//| Orden de evaluación (la primera regla que se cumple decide):     |
//|  1. Snapshot inválido            -> NO_TRADE                     |
//|  2. Spread anómalo               -> NO_TRADE                     |
//|  3. Volatilidad extrema          -> HIGH_VOLATILITY              |
//|  4. Volatilidad muy baja         -> NO_TRADE                     |
//|  5. ADX >= umbral de tendencia   -> TREND_UP / TREND_DOWN si     |
//|     todas las condiciones se alinean; si no, NO_TRADE            |
//|  6. ADX <= umbral de rango       -> RANGE si hay rango M15       |
//|     válido y el precio está dentro; si no, NO_TRADE              |
//|  7. ADX en zona neutral          -> NO_TRADE                     |
//|                                                                  |
//| Histéresis: pasar a NO_TRADE o HIGH_VOLATILITY es inmediato      |
//| (seguridad); cualquier otro cambio exige N evaluaciones          |
//| consecutivas con la misma clasificación.                         |
//|                                                                  |
//| Los umbrales por defecto son HIPÓTESIS INICIALES; deben          |
//| calibrarse con Tools/regime_report.py sobre datos reales.        |
//+------------------------------------------------------------------+
#ifndef XAUUSD_REGIMEENGINE_MQH
#define XAUUSD_REGIMEENGINE_MQH

#include "Types.mqh"
#include "Logger.mqh"

#define RE_MODULE "RegimeEngine"

struct RegimeConfig
  {
   double            trend_adx_min;            // ADX H1 mínimo para tendencia
   double            range_adx_max;            // ADX H1 máximo para rango
   double            high_vol_h1_atr_ratio;    // atr_ratio H1 que define volatilidad extrema
   double            high_vol_m15_atr_ratio;   // atr_ratio M15 que define volatilidad extrema
   double            low_vol_atr_ratio;        // atr_ratio H1 por debajo del cual no se opera
   double            max_spread_ratio;         // spread actual / spread medio máximo
   double            trend_min_slope;          // |pendiente EMA rápida H1| mínima en ATR
   bool              require_h1_structure;     // exigir estructura H1 HH/HL o LH/LL
   double            range_max_slope;          // |pendiente EMA rápida H1| máxima en rango
   double            range_min_width_atr;      // ancho mínimo del rango M15 en ATR M15
   double            range_max_width_atr;      // ancho máximo del rango M15 en ATR M15
   int               confirm_evaluations;      // evaluaciones consecutivas para confirmar un cambio
  };

void RegimeDefaultConfig(RegimeConfig &c)
  {
   c.trend_adx_min = 22.0;
   c.range_adx_max = 18.0;
   c.high_vol_h1_atr_ratio = 1.8;
   c.high_vol_m15_atr_ratio = 2.2;
   c.low_vol_atr_ratio = 0.5;
   c.max_spread_ratio = 3.0;
   c.trend_min_slope = 0.05;
   c.require_h1_structure = true;
   c.range_max_slope = 0.3;
   c.range_min_width_atr = 2.0;
   c.range_max_width_atr = 12.0;
   c.confirm_evaluations = 2;
  }

bool RegimeValidateConfig(const RegimeConfig &c, string &reason)
  {
   if(c.range_adx_max <= 0.0 || c.trend_adx_min <= c.range_adx_max || c.trend_adx_min > 100.0)
     { reason = "umbrales ADX inválidos (requiere 0 < rango < tendencia <= 100)"; return false; }
   if(c.high_vol_h1_atr_ratio <= 1.0 || c.high_vol_m15_atr_ratio <= 1.0)
     { reason = "umbral de alta volatilidad debe ser > 1.0"; return false; }
   if(c.low_vol_atr_ratio <= 0.0 || c.low_vol_atr_ratio >= 1.0)
     { reason = "umbral de baja volatilidad debe estar en (0, 1)"; return false; }
   if(c.max_spread_ratio <= 1.0)
     { reason = "max_spread_ratio debe ser > 1.0"; return false; }
   if(c.trend_min_slope < 0.0 || c.range_max_slope <= 0.0)
     { reason = "umbrales de pendiente inválidos"; return false; }
   if(c.range_min_width_atr <= 0.0 || c.range_max_width_atr <= c.range_min_width_atr)
     { reason = "anchos de rango inválidos"; return false; }
   if(c.confirm_evaluations < 1 || c.confirm_evaluations > 20)
     { reason = "confirm_evaluations debe estar en [1, 20]"; return false; }
   reason = "";
   return true;
  }

class CRegimeEngine
  {
private:
   RegimeConfig      m_cfg;
   CLogger          *m_log;
   bool              m_ready;
   ENUM_REGIME       m_stable;
   ENUM_REGIME       m_pending;
   int               m_pending_count;
   int               m_evals_in_regime;

   static bool       IsSafetyRegime(const ENUM_REGIME r)
     {
      return (r == REGIME_NO_TRADE || r == REGIME_HIGH_VOLATILITY);
     }

   //--- Pivote alto más reciente por encima y bajo por debajo del precio, en ATR.
   static void       SwingDistances(const TFData &d, const double price, double &dist_hi, double &dist_lo)
     {
      dist_hi = -1.0;
      dist_lo = -1.0;
      if(d.bars <= 0 || ArraySize(d.atr) < 1 || d.atr[0] <= 0.0)
         return;
      for(int i = 0; i < d.swing_count; i++)
        {
         if(d.swings[i].is_high && d.swings[i].price > price && dist_hi < 0.0)
            dist_hi = (d.swings[i].price - price) / d.atr[0];
         if(!d.swings[i].is_high && d.swings[i].price < price && dist_lo < 0.0)
            dist_lo = (price - d.swings[i].price) / d.atr[0];
         if(dist_hi >= 0.0 && dist_lo >= 0.0)
            break;
        }
     }

   //--- Pivote alto y bajo confirmados más recientes de M15.
   static bool       LatestSwingRange(const TFData &d, double &hi, double &lo)
     {
      hi = 0.0;
      lo = 0.0;
      bool has_hi = false, has_lo = false;
      for(int i = 0; i < d.swing_count && (!has_hi || !has_lo); i++)
        {
         if(d.swings[i].is_high && !has_hi)
           { hi = d.swings[i].price; has_hi = true; }
         if(!d.swings[i].is_high && !has_lo)
           { lo = d.swings[i].price; has_lo = true; }
        }
      return (has_hi && has_lo && hi > lo);
     }

public:
                     CRegimeEngine(void)
     {
      RegimeDefaultConfig(m_cfg);
      m_log = NULL;
      m_ready = false;
      m_stable = REGIME_NO_TRADE;
      m_pending = REGIME_NO_TRADE;
      m_pending_count = 0;
      m_evals_in_regime = 0;
     }

   bool              Init(const RegimeConfig &cfg, CLogger *log)
     {
      m_log = log;
      string reason;
      if(!RegimeValidateConfig(cfg, reason))
        {
         if(m_log != NULL)
            m_log.Critical(RE_MODULE, "CONFIG_INVALID", reason);
         else
            PrintFormat("[%s] CONFIG_INVALID %s", RE_MODULE, reason);
         m_ready = false;
         return false;
        }
      m_cfg = cfg;
      Reset();
      m_ready = true;
      return true;
     }

   //--- El régimen inicial es NO_TRADE: salir de él requiere confirmación.
   void              Reset(void)
     {
      m_stable = REGIME_NO_TRADE;
      m_pending = REGIME_NO_TRADE;
      m_pending_count = 0;
      m_evals_in_regime = 0;
     }

   ENUM_REGIME       Current(void) const { return m_stable; }

   //--- Clasificación instantánea, sin estado (pura → testeable). Sin histéresis:
   //--- st.regime = st.raw_regime y evaluations_in_regime = 0.
   static ENUM_REGIME Classify(const MarketSnapshot &s, const RegimeConfig &c, RegimeState &st)
     {
      ENUM_REGIME r = ClassifyRaw(s, c, st);
      st.raw_regime = r;
      st.regime = r;
      st.evaluations_in_regime = 0;
      st.evaluated_at = s.server_time;
      return r;
     }

private:
   static ENUM_REGIME ClassifyRaw(const MarketSnapshot &s, const RegimeConfig &c, RegimeState &st)
     {
      st.raw_regime = REGIME_NO_TRADE;
      st.h1_adx = 0.0;
      st.h1_atr_ratio = 0.0;
      st.m15_atr_ratio = 0.0;
      st.h1_ema_slope = 0.0;
      st.h1_structure = STRUCTURE_UNKNOWN;
      st.m15_structure = STRUCTURE_UNKNOWN;
      st.range_high = 0.0;
      st.range_low = 0.0;
      st.dist_swing_high_atr = -1.0;
      st.dist_swing_low_atr = -1.0;

      if(!s.valid || !s.h1.valid || !s.m15.valid || !s.m5.valid)
        {
         st.reason = "datos inválidos: " + s.invalid_reason;
         return REGIME_NO_TRADE;
        }
      const double h1_close = s.h1.rates[0].close;
      const double m5_close = s.m5.rates[0].close;
      st.h1_adx = s.h1.adx[0];
      st.h1_atr_ratio = s.h1.atr_ratio;
      st.m15_atr_ratio = s.m15.atr_ratio;
      st.h1_ema_slope = s.h1.ema_slope;
      st.h1_structure = s.h1.structure;
      st.m15_structure = s.m15.structure;
      SwingDistances(s.h1, m5_close, st.dist_swing_high_atr, st.dist_swing_low_atr);

      //--- 2. spread
      if(s.spread_ratio > 0.0 && s.spread_ratio > c.max_spread_ratio)
        {
         st.reason = StringFormat("spread anómalo: %.1fx la media (máx %.1fx)", s.spread_ratio, c.max_spread_ratio);
         return REGIME_NO_TRADE;
        }
      //--- 3. volatilidad extrema
      if(s.h1.atr_ratio >= c.high_vol_h1_atr_ratio || s.m15.atr_ratio >= c.high_vol_m15_atr_ratio)
        {
         st.raw_regime = REGIME_HIGH_VOLATILITY;
         st.reason = StringFormat("volatilidad extrema: atrR H1=%.2f (lím %.2f) M15=%.2f (lím %.2f)",
                                  s.h1.atr_ratio, c.high_vol_h1_atr_ratio, s.m15.atr_ratio, c.high_vol_m15_atr_ratio);
         return REGIME_HIGH_VOLATILITY;
        }
      //--- 4. volatilidad muy baja
      if(s.h1.atr_ratio < c.low_vol_atr_ratio)
        {
         st.reason = StringFormat("volatilidad muy baja: atrR H1=%.2f < %.2f", s.h1.atr_ratio, c.low_vol_atr_ratio);
         return REGIME_NO_TRADE;
        }
      //--- 5. tendencia
      const double adx = s.h1.adx[0];
      if(adx >= c.trend_adx_min)
        {
         bool up = (s.h1.ema_fast[0] > s.h1.ema_slow[0]);
         string fails = "";
         if(up)
           {
            if(h1_close <= s.h1.ema_fast[0])                       fails += "cierre H1 <= EMA rápida; ";
            if(s.h1.plus_di[0] <= s.h1.minus_di[0])                fails += "+DI <= -DI; ";
            if(s.h1.ema_slope < c.trend_min_slope)                 fails += StringFormat("pendiente %.3f < %.3f; ", s.h1.ema_slope, c.trend_min_slope);
            if(c.require_h1_structure && s.h1.structure != STRUCTURE_BULLISH)
               fails += "estructura H1 " + EnumStructureToString(s.h1.structure) + "; ";
           }
         else
           {
            if(s.h1.ema_fast[0] == s.h1.ema_slow[0])               fails += "EMAs iguales; ";
            if(h1_close >= s.h1.ema_fast[0])                       fails += "cierre H1 >= EMA rápida; ";
            if(s.h1.minus_di[0] <= s.h1.plus_di[0])                fails += "-DI <= +DI; ";
            if(s.h1.ema_slope > -c.trend_min_slope)                fails += StringFormat("pendiente %.3f > %.3f; ", s.h1.ema_slope, -c.trend_min_slope);
            if(c.require_h1_structure && s.h1.structure != STRUCTURE_BEARISH)
               fails += "estructura H1 " + EnumStructureToString(s.h1.structure) + "; ";
           }
         if(fails == "")
           {
            st.raw_regime = up ? REGIME_TREND_UP : REGIME_TREND_DOWN;
            st.reason = StringFormat("%s: ADX=%.1f EMA %s, pendiente=%.3f, estructura %s",
                                     (up ? "tendencia alcista" : "tendencia bajista"), adx,
                                     (up ? "rápida>lenta" : "rápida<lenta"), s.h1.ema_slope,
                                     EnumStructureToString(s.h1.structure));
            return st.raw_regime;
           }
         st.reason = StringFormat("ADX=%.1f sin alineación (%s): %s", adx, (up ? "alcista" : "bajista"), fails);
         return REGIME_NO_TRADE;
        }
      //--- 6. rango
      if(adx <= c.range_adx_max)
        {
         if(MathAbs(s.h1.ema_slope) > c.range_max_slope)
           {
            st.reason = StringFormat("ADX=%.1f bajo pero pendiente H1 %.3f > %.3f", adx, s.h1.ema_slope, c.range_max_slope);
            return REGIME_NO_TRADE;
           }
         double hi, lo;
         if(!LatestSwingRange(s.m15, hi, lo))
           {
            st.reason = StringFormat("ADX=%.1f bajo pero sin pivotes M15 que delimiten un rango", adx);
            return REGIME_NO_TRADE;
           }
         double width_atr = (hi - lo) / s.m15.atr[0];
         if(width_atr < c.range_min_width_atr || width_atr > c.range_max_width_atr)
           {
            st.reason = StringFormat("ancho de rango M15 %.1f ATR fuera de [%.1f, %.1f]", width_atr,
                                     c.range_min_width_atr, c.range_max_width_atr);
            return REGIME_NO_TRADE;
           }
         if(m5_close <= lo || m5_close >= hi)
           {
            st.reason = StringFormat("precio %.2f fuera del rango M15 [%.2f, %.2f]", m5_close, lo, hi);
            return REGIME_NO_TRADE;
           }
         st.range_high = hi;
         st.range_low = lo;
         st.raw_regime = REGIME_RANGE;
         st.reason = StringFormat("rango: ADX=%.1f, M15 [%.2f, %.2f] = %.1f ATR, pendiente %.3f",
                                  adx, lo, hi, width_atr, s.h1.ema_slope);
         return REGIME_RANGE;
        }
      //--- 7. zona neutral
      st.reason = StringFormat("ADX=%.1f en zona neutral (%.1f, %.1f)", adx, c.range_adx_max, c.trend_adx_min);
      return REGIME_NO_TRADE;
     }

public:
   //--- Clasificación con histéresis. Devuelve el régimen estable.
   ENUM_REGIME       Evaluate(const MarketSnapshot &s, RegimeState &st)
     {
      st.evaluated_at = s.server_time;
      if(!m_ready)
        {
         st.raw_regime = REGIME_NO_TRADE;
         st.regime = REGIME_NO_TRADE;
         st.reason = "RegimeEngine no inicializado";
         st.evaluations_in_regime = 0;
         return REGIME_NO_TRADE;
        }
      ENUM_REGIME raw = Classify(s, m_cfg, st);
      ENUM_REGIME previous = m_stable;
      if(raw == m_stable)
        {
         m_pending_count = 0;
        }
      else
         if(IsSafetyRegime(raw))
           {
            m_stable = raw;
            m_pending_count = 0;
           }
         else
           {
            if(raw == m_pending)
               m_pending_count++;
            else
              {
               m_pending = raw;
               m_pending_count = 1;
              }
            if(m_pending_count >= m_cfg.confirm_evaluations)
              {
               m_stable = raw;
               m_pending_count = 0;
              }
           }
      if(m_stable != previous)
        {
         m_evals_in_regime = 1;
         if(m_log != NULL)
            m_log.Info(RE_MODULE, "REGIME_CHANGE",
                       StringFormat("%s -> %s | %s", EnumRegimeToString(previous),
                                    EnumRegimeToString(m_stable), st.reason));
        }
      else
         m_evals_in_regime++;
      st.regime = m_stable;
      st.evaluations_in_regime = m_evals_in_regime;
      return m_stable;
     }

   static string     Describe(const RegimeState &st)
     {
      return StringFormat("regime=%s raw=%s n=%d adx=%.1f atrR(H1)=%.2f atrR(M15)=%.2f slope=%.3f "
                          "st(H1)=%s st(M15)=%s dHi=%.2f dLo=%.2f | %s",
                          EnumRegimeToString(st.regime), EnumRegimeToString(st.raw_regime),
                          st.evaluations_in_regime, st.h1_adx, st.h1_atr_ratio, st.m15_atr_ratio,
                          st.h1_ema_slope, EnumStructureToString(st.h1_structure),
                          EnumStructureToString(st.m15_structure), st.dist_swing_high_atr,
                          st.dist_swing_low_atr, st.reason);
     }
  };

#endif // XAUUSD_REGIMEENGINE_MQH
