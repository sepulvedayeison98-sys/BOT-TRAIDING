//+------------------------------------------------------------------+
//| StrategyBase.mqh                                                 |
//| Base común de las estrategias: confirmación M5, construcción de  |
//| SL/TP, invariantes de la señal e identificadores.                |
//| Las estrategias NO calculan volumen, NO conocen la cuenta y NO   |
//| envían órdenes: solo producen TradeSignal.                       |
//|                                                                  |
//| SL: más allá de la invalidación estructural + colchón ATR M15;   |
//|     si queda más cerca que min_sl_atr se aleja hasta ese mínimo; |
//|     si queda más lejos que max_sl_atr la señal se descarta.      |
//| TP: nivel de liquidez opuesto más cercano (pivotes M15/H1 y      |
//|     niveles extra de la estrategia) a >= min_tp_atr de la        |
//|     entrada y <= max_tp_atr_h1. El R:R mínimo lo exige el        |
//|     RiskManager (Fase 6); aquí solo se calcula.                  |
//+------------------------------------------------------------------+
#ifndef XAUUSD_STRATEGYBASE_MQH
#define XAUUSD_STRATEGYBASE_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "PatternLib.mqh"

struct StrategyCommonConfig
  {
   int               pivot_n_m15;          // DEBE coincidir con MarketEngineConfig.pivot_n_m15
   int               pivot_n_m5;           // DEBE coincidir con MarketEngineConfig.pivot_n_m5
   double            sl_buffer_atr;        // colchón más allá de la invalidación (ATR M15)
   double            min_sl_atr;           // distancia mínima del SL (ATR M15)
   double            max_sl_atr;           // distancia máxima del SL (ATR M15)
   double            min_tp_atr;           // distancia mínima del TP (ATR M15)
   double            max_tp_atr_h1;        // distancia máxima del TP (ATR H1)
   double            rejection_wick_ratio; // mecha mínima / rango para vela de rechazo
   int               m5_confirm_bars;      // velas M5 cerradas donde buscar la ruptura de confirmación
  };

void StrategyCommonDefaultConfig(StrategyCommonConfig &c)
  {
   c.pivot_n_m15 = 3;
   c.pivot_n_m5 = 3;
   c.sl_buffer_atr = 0.2;
   c.min_sl_atr = 0.5;
   c.max_sl_atr = 4.0;
   c.min_tp_atr = 1.0;
   c.max_tp_atr_h1 = 8.0;
   c.rejection_wick_ratio = 0.6;
   c.m5_confirm_bars = 2;
  }

bool StrategyCommonValidateConfig(const StrategyCommonConfig &c, string &reason)
  {
   if(c.pivot_n_m15 < 1 || c.pivot_n_m5 < 1)
     { reason = "pivot_n debe ser >= 1"; return false; }
   if(c.sl_buffer_atr < 0.0 || c.min_sl_atr <= 0.0 || c.max_sl_atr <= c.min_sl_atr)
     { reason = "parámetros de SL inválidos (0 < min < max, colchón >= 0)"; return false; }
   if(c.min_tp_atr <= 0.0 || c.max_tp_atr_h1 <= 0.0)
     { reason = "parámetros de TP inválidos"; return false; }
   if(c.rejection_wick_ratio <= 0.0 || c.rejection_wick_ratio >= 1.0)
     { reason = "rejection_wick_ratio debe estar en (0, 1)"; return false; }
   if(c.m5_confirm_bars < 1 || c.m5_confirm_bars > 6)
     { reason = "m5_confirm_bars debe estar en [1, 6]"; return false; }
   reason = "";
   return true;
  }

//--- Añade una señal al arreglo de salida
void AppendSignal(TradeSignal &arr[], const TradeSignal &sig)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = sig;
  }

class CStrategyBase
  {
protected:
   StrategyCommonConfig m_common;
   CLogger          *m_log;
   ENUM_STRATEGY_ID  m_id;
   string            m_name;
   bool              m_ready;
   string            m_last_reject;
   ulong             m_counter;

   void              Reject(const ENUM_DIRECTION dir, const string why)
     {
      m_last_reject = EnumDirectionToString(dir) + ": " + why;
     }

   string            NewSignalId(const datetime t)
     {
      m_counter++;
      if(m_log != NULL)
         return m_log.NewId(m_name);
      return StringFormat("%s-%s-%s", m_name, TimeToString(t, TIME_DATE | TIME_MINUTES),
                          IntegerToString((long)m_counter));
     }

   static bool       RegimeAllows(const ENUM_REGIME r, const ENUM_DIRECTION dir,
                                  const ENUM_REGIME trend_long, const ENUM_REGIME trend_short, const bool allow_range)
     {
      if(r == REGIME_NO_TRADE || r == REGIME_HIGH_VOLATILITY)
         return false;
      if(r == REGIME_RANGE)
         return allow_range;
      return (dir == DIR_LONG) ? (r == trend_long) : (r == trend_short);
     }

   //--- Confirmación en M5: vela de rechazo en la última vela cerrada o ruptura
   //--- de estructura M5 en las últimas m5_confirm_bars velas.
   bool              M5Confirmation(const MarketSnapshot &s, const ENUM_DIRECTION dir, bool &rejection, bool &brk)
     {
      rejection = CPatterns::IsRejection(s.m5.rates[0], dir, m_common.rejection_wick_ratio);
      BreakInfo b;
      brk = CPatterns::FindBreak(s.m5, dir, 0, m_common.m5_confirm_bars - 1, m_common.pivot_n_m5, b);
      return (rejection || brk);
     }

   //--- Nivel de liquidez opuesto más cercano a una distancia válida. 0 si no hay.
   double            SelectTarget(const MarketSnapshot &s, const ENUM_DIRECTION dir, const double entry,
                                  const double &extra[])
     {
      double min_d = m_common.min_tp_atr * s.m15.atr[0];
      double max_d = m_common.max_tp_atr_h1 * s.h1.atr[0];
      double best = 0.0, best_d = DBL_MAX;
      bool want_high = (dir == DIR_LONG);
      for(int pass = 0; pass < 3; pass++)
        {
         int n = (pass == 0) ? s.m15.swing_count : (pass == 1 ? s.h1.swing_count : ArraySize(extra));
         for(int i = 0; i < n; i++)
           {
            double lvl;
            if(pass == 0)
              {
               if(s.m15.swings[i].is_high != want_high) continue;
               lvl = s.m15.swings[i].price;
              }
            else
               if(pass == 1)
                 {
                  if(s.h1.swings[i].is_high != want_high) continue;
                  lvl = s.h1.swings[i].price;
                 }
               else
                  lvl = extra[i];
            if(lvl <= 0.0)
               continue;
            double d = want_high ? lvl - entry : entry - lvl;
            if(d >= min_d && d <= max_d && d < best_d)
              {
               best_d = d;
               best = lvl;
              }
           }
        }
      return best;
     }

   //--- SL a partir de la invalidación estructural. false si es imposible o excesivo.
   bool              BuildStop(const MarketSnapshot &s, const ENUM_DIRECTION dir, const double entry,
                               const double invalidation, double &sl, string &why)
     {
      double atr = s.m15.atr[0];
      if(dir == DIR_LONG)
        {
         if(invalidation >= entry)
           { why = StringFormat("invalidación %.2f >= entrada %.2f", invalidation, entry); return false; }
         sl = invalidation - m_common.sl_buffer_atr * atr;
         if(entry - sl < m_common.min_sl_atr * atr)
            sl = entry - m_common.min_sl_atr * atr;
         if(entry - sl > m_common.max_sl_atr * atr)
           { why = StringFormat("SL estructural a %.1f ATR > máximo %.1f", (entry - sl) / atr, m_common.max_sl_atr); return false; }
        }
      else
        {
         if(invalidation <= entry)
           { why = StringFormat("invalidación %.2f <= entrada %.2f", invalidation, entry); return false; }
         sl = invalidation + m_common.sl_buffer_atr * atr;
         if(sl - entry < m_common.min_sl_atr * atr)
            sl = entry + m_common.min_sl_atr * atr;
         if(sl - entry > m_common.max_sl_atr * atr)
           { why = StringFormat("SL estructural a %.1f ATR > máximo %.1f", (sl - entry) / atr, m_common.max_sl_atr); return false; }
        }
      sl = NormalizeDouble(sl, s.digits);
      return true;
     }

   //--- Lógica propia de cada estrategia para una dirección.
   virtual bool      EvaluateDir(const MarketSnapshot &s, const RegimeState &regime, const ENUM_DIRECTION dir,
                                 TradeSignal &sig) = 0;

   //--- Completa identificadores, tiempos, R:R y valida invariantes.
   bool              Finalize(const MarketSnapshot &s, TradeSignal &sig, string &why)
     {
      sig.strategy = m_id;
      sig.created = s.server_time;
      sig.expires = s.m5.rates[0].time + 2 * PeriodSeconds(PERIOD_M5);   // válida solo durante la vela M5 siguiente
      sig.signal_id = NewSignalId(s.server_time);
      double risk = MathAbs(sig.entry_price - sig.sl);
      sig.rr = (risk > 0.0) ? MathAbs(sig.tp - sig.entry_price) / risk : 0.0;
      return ValidateSignal(sig, why);
     }

public:
                     CStrategyBase(void)
     {
      StrategyCommonDefaultConfig(m_common);
      m_log = NULL;
      m_id = STRAT_NONE;
      m_name = "STRAT";
      m_ready = false;
      m_last_reject = "";
      m_counter = 0;
     }

   virtual          ~CStrategyBase(void) {}

   //--- Evalúa la última vela M5 cerrada en ambas direcciones. Devuelve el número de
   //--- señales añadidas a out[]. LastRejection() explica por qué no hubo señal.
   int               Evaluate(const MarketSnapshot &s, const RegimeState &regime, TradeSignal &out[])
     {
      m_last_reject = "";
      if(!m_ready || !s.valid)
        { m_last_reject = "estrategia no inicializada o snapshot inválido"; return 0; }
      int added = 0;
      string rejects = "";
      ENUM_DIRECTION dirs[2] = {DIR_LONG, DIR_SHORT};
      for(int i = 0; i < 2; i++)
        {
         TradeSignal sig;
         m_last_reject = "";
         if(EvaluateDir(s, regime, dirs[i], sig))
           {
            AppendSignal(out, sig);
            added++;
           }
         else
            rejects += (rejects == "" ? "" : " | ") + m_last_reject;
        }
      m_last_reject = rejects;
      return added;
     }

   string            LastRejection(void) const { return m_last_reject; }
   ENUM_STRATEGY_ID  Id(void) const            { return m_id; }
   string            Name(void) const          { return m_name; }
   bool              Ready(void) const         { return m_ready; }

   //--- Invariantes que toda señal debe cumplir.
   static bool       ValidateSignal(const TradeSignal &g, string &why)
     {
      if(g.direction != DIR_LONG && g.direction != DIR_SHORT)
        { why = "dirección inválida"; return false; }
      if(g.entry_price <= 0.0 || g.sl <= 0.0 || g.tp <= 0.0)
        { why = "precios no positivos"; return false; }
      if(g.direction == DIR_LONG && !(g.sl < g.entry_price && g.entry_price < g.tp))
        { why = StringFormat("compra requiere SL < entrada < TP (%.2f, %.2f, %.2f)", g.sl, g.entry_price, g.tp); return false; }
      if(g.direction == DIR_SHORT && !(g.tp < g.entry_price && g.entry_price < g.sl))
        { why = StringFormat("venta requiere TP < entrada < SL (%.2f, %.2f, %.2f)", g.tp, g.entry_price, g.sl); return false; }
      if(g.direction == DIR_LONG && g.sl >= g.invalidation)
        { why = "SL de compra debe quedar bajo la invalidación"; return false; }
      if(g.direction == DIR_SHORT && g.sl <= g.invalidation)
        { why = "SL de venta debe quedar sobre la invalidación"; return false; }
      if(g.entry_low > g.entry_high)
        { why = "zona de entrada invertida"; return false; }
      if(g.signal_id == "" || g.setup_key == "" || g.reason == "")
        { why = "faltan identificador, clave de setup o motivo"; return false; }
      if(g.expires <= g.created - 2 * PeriodSeconds(PERIOD_M5))
        { why = "expiración inválida"; return false; }
      why = "";
      return true;
     }

   static string     Describe(const TradeSignal &g)
     {
      return StringFormat("%s %s %s entry=%.2f zone=[%.2f,%.2f] inv=%.2f SL=%.2f TP=%.2f RR=%.2f key=%s | %s | %s",
                          g.signal_id, EnumStrategyToString(g.strategy), EnumDirectionToString(g.direction),
                          g.entry_price, g.entry_low, g.entry_high, g.invalidation, g.sl, g.tp, g.rr,
                          g.setup_key, g.reason, g.evidence_text);
     }
  };

void ResetEvidence(SignalEvidence &e)
  {
   ZeroMemory(e);
   e.m15_event = SE_NONE;
  }

#endif // XAUUSD_STRATEGYBASE_MQH
