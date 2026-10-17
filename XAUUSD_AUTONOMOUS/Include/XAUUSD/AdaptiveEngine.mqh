//+------------------------------------------------------------------+
//| AdaptiveEngine.mqh                                               |
//| Coordinador de estrategias:                                      |
//|  1. recibe las señales de las estrategias,                       |
//|  2. descarta señales inválidas o expiradas,                      |
//|  3. detecta señales contradictorias (compra y venta a la vez ->  |
//|     se descartan todas),                                         |
//|  4. evita duplicados: setups ya consumidos, oportunidades sobre  |
//|     las que ya hay posición, y zonas solapadas (gana la mejor),  |
//|  5. puntúa cada señal (0-100) con 6 componentes,                 |
//|  6. selecciona la mejor que supere el umbral,                    |
//|  7. devuelve UNA propuesta para el RiskManager.                  |
//| No calcula volumen ni puede saltarse el RiskManager.             |
//|                                                                  |
//| Las puntuaciones NO son probabilidades de éxito: son una         |
//| ordenación heurística que debe calibrarse con backtesting y      |
//| datos fuera de muestra.                                          |
//+------------------------------------------------------------------+
#ifndef XAUUSD_ADAPTIVEENGINE_MQH
#define XAUUSD_ADAPTIVEENGINE_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "StrategyBase.mqh"

#define AE_MODULE "AdaptiveEngine"
#define AE_MAX_CONSUMED 256

struct AdaptiveConfig
  {
   double            min_score;             // < min_score: descartar (inicial 65)
   double            high_score;            // >= high_score: alta calidad (inicial 80)
   double            dedup_distance_atr;    // entradas a menos de esta distancia (ATR M15) = misma oportunidad
   int               consumed_ttl_hours;    // tiempo que un setup consumido bloquea repeticiones
   double            reversal_rsi_extreme;  // RSI H1 que cuenta como agotamiento para reversión
   double            reversal_zone_atr;     // distancia (ATR H1) a pivote H1 opuesto que cuenta como zona
   int               min_minutes_to_session_end;
  };

void AdaptiveDefaultConfig(AdaptiveConfig &c)
  {
   c.min_score = 65.0;
   c.high_score = 80.0;
   c.dedup_distance_atr = 0.5;
   c.consumed_ttl_hours = 24;
   c.reversal_rsi_extreme = 35.0;
   c.reversal_zone_atr = 1.0;
   c.min_minutes_to_session_end = 30;
  }

bool AdaptiveValidateConfig(const AdaptiveConfig &c, string &reason)
  {
   if(c.min_score < 50.0 || c.min_score > 95.0)
     { reason = "min_score debe estar en [50, 95]"; return false; }
   if(c.high_score < c.min_score || c.high_score > 100.0)
     { reason = "high_score debe estar en [min_score, 100]"; return false; }
   if(c.dedup_distance_atr < 0.0 || c.consumed_ttl_hours < 1)
     { reason = "parámetros de deduplicación inválidos"; return false; }
   if(c.reversal_rsi_extreme <= 0.0 || c.reversal_rsi_extreme >= 50.0 || c.reversal_zone_atr <= 0.0)
     { reason = "parámetros de reversión inválidos"; return false; }
   if(c.min_minutes_to_session_end < 0)
     { reason = "min_minutes_to_session_end negativo"; return false; }
   reason = "";
   return true;
  }

class CAdaptiveEngine
  {
private:
   AdaptiveConfig    m_cfg;
   CLogger          *m_log;
   bool              m_ready;
   string            m_consumed_keys[AE_MAX_CONSUMED];
   datetime          m_consumed_time[AE_MAX_CONSUMED];
   int               m_consumed_next;

   void              LogMsg(const ENUM_LOG_LEVEL lvl, const string event, const string msg, const string id = "")
     {
      if(m_log != NULL)
         m_log.Log(lvl, AE_MODULE, event, msg, id);
     }

   static bool       Aligned(const ENUM_REGIME r, const ENUM_DIRECTION d)
     {
      return (d == DIR_LONG && r == REGIME_TREND_UP) || (d == DIR_SHORT && r == REGIME_TREND_DOWN);
     }

   static bool       Opposed(const ENUM_REGIME r, const ENUM_DIRECTION d)
     {
      return (d == DIR_LONG && r == REGIME_TREND_DOWN) || (d == DIR_SHORT && r == REGIME_TREND_UP);
     }

public:
                     CAdaptiveEngine(void)
     {
      AdaptiveDefaultConfig(m_cfg);
      m_log = NULL;
      m_ready = false;
      m_consumed_next = 0;
      for(int i = 0; i < AE_MAX_CONSUMED; i++)
        {
         m_consumed_keys[i] = "";
         m_consumed_time[i] = 0;
        }
     }

   bool              Init(const AdaptiveConfig &cfg, CLogger *log)
     {
      m_log = log;
      string reason;
      if(!AdaptiveValidateConfig(cfg, reason))
        {
         if(m_log != NULL) m_log.Critical(AE_MODULE, "CONFIG_INVALID", reason);
         else PrintFormat("[%s] CONFIG_INVALID %s", AE_MODULE, reason);
         m_ready = false;
         return false;
        }
      m_cfg = cfg;
      m_ready = true;
      return true;
     }

   //--- Ajuste de umbrales desde un modelo Champion aprobado (nunca parámetros de riesgo).
   bool              SetThresholds(const double min_score, const double high_score)
     {
      AdaptiveConfig c = m_cfg;
      c.min_score = min_score;
      c.high_score = high_score;
      string reason;
      if(!AdaptiveValidateConfig(c, reason))
         return false;
      m_cfg = c;
      return true;
     }

   AdaptiveConfig    Config(void) const { return m_cfg; }

   //--- Registro de setups ya usados (ejecutados o en curso) para no repetirlos.
   void              MarkConsumed(const string setup_key, const datetime t)
     {
      if(setup_key == "" || IsConsumed(setup_key, t))
         return;
      m_consumed_keys[m_consumed_next] = setup_key;
      m_consumed_time[m_consumed_next] = t;
      m_consumed_next = (m_consumed_next + 1) % AE_MAX_CONSUMED;
     }

   bool              IsConsumed(const string setup_key, const datetime now) const
     {
      datetime limit = now - (datetime)m_cfg.consumed_ttl_hours * 3600;
      for(int i = 0; i < AE_MAX_CONSUMED; i++)
         if(m_consumed_keys[i] == setup_key && m_consumed_time[i] >= limit)
            return true;
      return false;
     }

   int               ConsumedKeys(string &keys[], datetime &times[]) const
     {
      int n = 0;
      ArrayResize(keys, 0);
      ArrayResize(times, 0);
      for(int i = 0; i < AE_MAX_CONSUMED; i++)
        {
         if(m_consumed_keys[i] == "")
            continue;
         ArrayResize(keys, n + 1);
         ArrayResize(times, n + 1);
         keys[n] = m_consumed_keys[i];
         times[n] = m_consumed_time[i];
         n++;
        }
      return n;
     }

   //--- Puntuación de una señal (pura, testeable).
   ScoreBreakdown    Score(const TradeSignal &g, const MarketSnapshot &s, const RegimeState &r,
                           const AdaptiveContext &ctx) const
     {
      ScoreBreakdown b;
      ZeroMemory(b);
      const SignalEvidence e = g.evidence;
      bool lng = (g.direction == DIR_LONG);
      bool reversal = (g.strategy == STRAT_REVERSAL);

      //--- 1. contexto H1 (20)
      if(!reversal)
         b.h1_context = Aligned(r.regime, g.direction) ? 20.0 : (r.regime == REGIME_RANGE ? 10.0 : 0.0);
      else
        {
         // para reversión cuenta el agotamiento, no la alineación (ver ARCHITECTURE.md R5)
         if(Opposed(r.regime, g.direction) || r.regime == REGIME_RANGE)
            b.h1_context += 10.0;
         double rsi = s.h1.rsi[0];
         if((lng && rsi <= m_cfg.reversal_rsi_extreme) || (!lng && rsi >= 100.0 - m_cfg.reversal_rsi_extreme))
            b.h1_context += 5.0;
         double dist = lng ? r.dist_swing_low_atr : r.dist_swing_high_atr;
         if(dist >= 0.0 && dist <= m_cfg.reversal_zone_atr)
            b.h1_context += 5.0;
        }
      //--- 2. estructura M15 (20)
      if(e.consolidation)
         b.m15_structure = 20.0;
      else
         if(e.m15_event == SE_BOS || e.m15_event == SE_CHOCH)
            b.m15_structure = 20.0;
         else
            if(e.m15_event == SE_BREAK)
               b.m15_structure = 12.0;
      //--- 3. liquidez (20)
      if(g.strategy == STRAT_BREAKOUT)
         b.liquidity = (e.retest ? 10.0 : 0.0) + (e.volume_expansion ? 10.0 : 0.0);
      else
        {
         b.liquidity = (e.sweep ? 12.0 : 0.0) + (e.sweep_session_level ? 4.0 : 0.0);
         if(g.strategy == STRAT_SMC)
            b.liquidity += (e.discount_premium_ok ? 4.0 : 0.0);
         else
            b.liquidity += (e.rsi_divergence ? 4.0 : 0.0);
        }
      //--- 4. confirmación M5 (20)
      b.m5_confirmation = (e.m5_rejection ? 10.0 : 0.0) + (e.m5_break ? 10.0 : 0.0);
      //--- 5. momentum y volatilidad (10)
      double slope = s.m5.ema_slope;
      if(!reversal)
         b.momentum_volatility += ((lng && slope > 0.0) || (!lng && slope < 0.0)) ? 5.0 : 0.0;
      else
         b.momentum_volatility += (s.m5.momentum_shift || s.m15.momentum_shift) ? 5.0 : 0.0;
      if(s.h1.atr_ratio >= 0.7 && s.h1.atr_ratio <= 1.5)
         b.momentum_volatility += 5.0;
      //--- 6. calidad de ejecución (10)
      if(s.spread_ratio > 0.0 && s.spread_ratio <= 1.2)
         b.execution += 4.0;
      else
         if(s.spread_ratio > 0.0 && s.spread_ratio <= 2.0)
            b.execution += 2.0;
      if(g.rr >= 2.5)
         b.execution += 3.0;
      else
         if(g.rr >= 2.0)
            b.execution += 2.0;
      if(ctx.news_clear && (ctx.minutes_to_session_end < 0 || ctx.minutes_to_session_end >= m_cfg.min_minutes_to_session_end))
         b.execution += 3.0;

      b.total = b.h1_context + b.m15_structure + b.liquidity + b.m5_confirmation + b.momentum_volatility + b.execution;
      return b;
     }

   ENUM_SIGNAL_QUALITY Quality(const double total) const
     {
      if(total >= m_cfg.high_score)
         return QUALITY_HIGH;
      if(total >= m_cfg.min_score)
         return QUALITY_MODERATE;
      return QUALITY_DISCARD;
     }

   static string     DescribeScore(const ScoreBreakdown &b)
     {
      return StringFormat("total=%.0f [H1 %.0f, M15 %.0f, liq %.0f, M5 %.0f, mom/vol %.0f, ejec %.0f]",
                          b.total, b.h1_context, b.m15_structure, b.liquidity, b.m5_confirmation,
                          b.momentum_volatility, b.execution);
     }

   //--- Coordina las señales de una vela. Devuelve la propuesta (valid=false si no hay).
   TradeProposal     Decide(const TradeSignal &signals[], const MarketSnapshot &s, const RegimeState &r,
                            const PositionBrief &positions[], const AdaptiveContext &ctx)
     {
      TradeProposal p;
      p.valid = false;
      p.quality = QUALITY_DISCARD;
      ZeroMemory(p.score);
      p.candidates = ArraySize(signals);
      p.decision = "";
      if(!m_ready)
        { p.decision = "AdaptiveEngine no inicializado"; return p; }
      if(p.candidates == 0)
        { p.decision = "sin señales"; return p; }

      //--- 1. filtrado individual
      bool keep[];
      ArrayResize(keep, p.candidates);
      int has_long = 0, has_short = 0;
      string notes = "";
      for(int i = 0; i < p.candidates; i++)
        {
         string why;
         keep[i] = CStrategyBase::ValidateSignal(signals[i], why);
         if(!keep[i])
           { notes += StringFormat("%s inválida (%s); ", signals[i].signal_id, why); continue; }
         if(s.server_time > signals[i].expires)
           { keep[i] = false; notes += signals[i].signal_id + " expirada; "; continue; }
         if(IsConsumed(signals[i].setup_key, s.server_time))
           { keep[i] = false; notes += signals[i].signal_id + " setup ya consumido; "; continue; }
         double tol = m_cfg.dedup_distance_atr * s.m15.atr[0];
         for(int k = 0; k < ArraySize(positions) && keep[i]; k++)
           {
            if(positions[k].setup_key != "" && positions[k].setup_key == signals[i].setup_key)
              { keep[i] = false; notes += signals[i].signal_id + " ya hay posición de este setup; "; }
            else
               if(positions[k].direction == signals[i].direction &&
                  MathAbs(positions[k].open_price - signals[i].entry_price) <= tol)
                 { keep[i] = false; notes += signals[i].signal_id + " ya hay posición en la misma zona; "; }
           }
         if(!keep[i])
            continue;
         if(signals[i].direction == DIR_LONG) has_long++;
         else has_short++;
        }
      //--- 2. señales contradictorias
      if(has_long > 0 && has_short > 0)
        {
         p.decision = StringFormat("CONFLICTO: %d compra(s) y %d venta(s) en la misma vela -> se descartan todas. %s",
                                   has_long, has_short, notes);
         LogMsg(LOG_INFO, "CONFLICT", p.decision);
         return p;
        }
      //--- 3. puntuación y selección; las zonas solapadas cuentan como una oportunidad
      int best = -1;
      ScoreBreakdown best_score;
      ZeroMemory(best_score);
      double tol = m_cfg.dedup_distance_atr * s.m15.atr[0];
      for(int i = 0; i < p.candidates; i++)
        {
         if(!keep[i])
            continue;
         ScoreBreakdown sc = Score(signals[i], s, r, ctx);
         LogMsg(LOG_DEBUG, "SCORE", CStrategyBase::Describe(signals[i]) + " | " + DescribeScore(sc), signals[i].signal_id);
         if(best >= 0)
           {
            bool same_opportunity = MathAbs(signals[i].entry_price - signals[best].entry_price) <= tol ||
                                    (signals[i].entry_low <= signals[best].entry_high &&
                                     signals[best].entry_low <= signals[i].entry_high);
            notes += StringFormat("%s %s %s; ", signals[i].signal_id,
                                  (same_opportunity ? "duplica la oportunidad de" : "compite con"),
                                  signals[best].signal_id);
           }
         if(best < 0 || sc.total > best_score.total)
           {
            best = i;
            best_score = sc;
           }
        }
      if(best < 0)
        {
         p.decision = "todas las señales descartadas: " + notes;
         return p;
        }
      p.score = best_score;
      p.quality = Quality(best_score.total);
      p.signal = signals[best];
      if(p.quality == QUALITY_DISCARD)
        {
         p.decision = StringFormat("mejor señal %s con %s < umbral %.0f. %s", signals[best].signal_id,
                                   DescribeScore(best_score), m_cfg.min_score, notes);
         LogMsg(LOG_INFO, "DISCARD_SCORE", p.decision, signals[best].signal_id);
         return p;
        }
      p.valid = true;
      p.decision = StringFormat("seleccionada %s (%s, %s) %s. %s", signals[best].signal_id,
                                EnumStrategyToString(signals[best].strategy), EnumQualityToString(p.quality),
                                DescribeScore(best_score), notes);
      LogMsg(LOG_INFO, "PROPOSAL", p.decision, signals[best].signal_id);
      return p;
     }
  };

#endif // XAUUSD_ADAPTIVEENGINE_MQH
