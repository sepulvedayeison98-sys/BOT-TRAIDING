//+------------------------------------------------------------------+
//| StrategyReversal.mqh                                             |
//| Reversión (compra; venta es el espejo):                          |
//|  - Contexto: régimen TREND_DOWN o RANGE (contra el movimiento    |
//|    previo). Nunca en HIGH_VOLATILITY ni NO_TRADE.                |
//|  - OBLIGATORIO: CHoCH alcista M15 (ruptura contra una estructura |
//|    bajista vigente) y que el precio M5 siga por encima del nivel |
//|    roto.                                                         |
//|  - Confirmaciones (se exigen min_confirmations, CHoCH incluido): |
//|      CHoCH, divergencia RSI M15, barrido de un mínimo M15,       |
//|      vela M15 de rechazo en el extremo del tramo, sobreextensión |
//|      del extremo respecto a la EMA rápida M15.                   |
//|  - Confirmación M5 obligatoria (rechazo o ruptura M5).           |
//| Sobrecompra/sobreventa por sí sola nunca genera señal.           |
//| Invalidación: extremo del tramo (mínimo más bajo del lookback).  |
//+------------------------------------------------------------------+
#ifndef XAUUSD_STRATEGYREVERSAL_MQH
#define XAUUSD_STRATEGYREVERSAL_MQH

#include "StrategyBase.mqh"

struct ReversalConfig
  {
   int               lookback_m15;
   double            sweep_min_pen_atr;
   double            rsi_min_diff;        // diferencia mínima de RSI para la divergencia
   int               divergence_max_age;  // antigüedad máxima (velas M15) del pivote nuevo
   double            extension_atr;       // distancia mínima del extremo a la EMA rápida (ATR)
   int               min_confirmations;   // incluye el CHoCH
   bool              allow_in_range;
  };

void ReversalDefaultConfig(ReversalConfig &c)
  {
   c.lookback_m15 = 16;
   c.sweep_min_pen_atr = 0.05;
   c.rsi_min_diff = 3.0;
   c.divergence_max_age = 12;
   c.extension_atr = 2.0;
   c.min_confirmations = 3;
   c.allow_in_range = true;
  }

bool ReversalValidateConfig(const ReversalConfig &c, string &reason)
  {
   if(c.lookback_m15 < 3 || c.lookback_m15 > 100)
     { reason = "lookback_m15 debe estar en [3, 100]"; return false; }
   if(c.rsi_min_diff < 0.0 || c.extension_atr < 0.0 || c.sweep_min_pen_atr < 0.0)
     { reason = "umbrales negativos"; return false; }
   if(c.divergence_max_age < 1)
     { reason = "divergence_max_age debe ser >= 1"; return false; }
   if(c.min_confirmations < 3 || c.min_confirmations > 5)
     { reason = "min_confirmations debe estar en [3, 5] (el plan exige al menos 3)"; return false; }
   reason = "";
   return true;
  }

class CStrategyReversal : public CStrategyBase
  {
private:
   ReversalConfig    m_cfg;

protected:
   virtual bool      EvaluateDir(const MarketSnapshot &s, const RegimeState &regime, const ENUM_DIRECTION dir,
                                 TradeSignal &sig)
     {
      bool lng = (dir == DIR_LONG);
      // reversión: compras contra una tendencia bajista, ventas contra una alcista
      if(!RegimeAllows(regime.regime, dir, REGIME_TREND_DOWN, REGIME_TREND_UP, m_cfg.allow_in_range))
        { Reject(dir, "régimen " + EnumRegimeToString(regime.regime) + " incompatible"); return false; }
      int n15 = m_common.pivot_n_m15;

      BreakInfo choch;
      if(!CPatterns::FindBreak(s.m15, dir, 0, m_cfg.lookback_m15, n15, choch) || choch.type != SE_CHOCH)
        { Reject(dir, "sin CHoCH M15 (obligatorio)"); return false; }
      const MqlRates m5 = s.m5.rates[0];
      if((lng && m5.close <= choch.level) || (!lng && m5.close >= choch.level))
        { Reject(dir, StringFormat("precio M5 %.2f volvió del otro lado del CHoCH %.2f", m5.close, choch.level)); return false; }

      //--- extremo del tramo y su vela
      int ext_bar = 0;
      double ext = lng ? DBL_MAX : -DBL_MAX;
      int last = MathMin(m_cfg.lookback_m15, s.m15.bars - 1);
      for(int i = 0; i <= last; i++)
        {
         if(lng && s.m15.rates[i].low < ext)   { ext = s.m15.rates[i].low;  ext_bar = i; }
         if(!lng && s.m15.rates[i].high > ext) { ext = s.m15.rates[i].high; ext_bar = i; }
        }
      if(ext_bar <= choch.bar)
        { Reject(dir, "el extremo del tramo es posterior al CHoCH"); return false; }

      DivergenceInfo div;
      bool has_div = CPatterns::FindRsiDivergence(s.m15, dir, m_cfg.rsi_min_diff, m_cfg.divergence_max_age, div);
      SweepInfo sw;
      bool has_sweep = CPatterns::FindSweep(s.m15, !lng, m_cfg.lookback_m15, n15, m_cfg.sweep_min_pen_atr, sw) &&
                       sw.bar >= choch.bar;
      bool has_rej = CPatterns::IsRejection(s.m15.rates[ext_bar], dir, m_common.rejection_wick_ratio);
      double ema_at_ext = s.m15.ema_fast[ext_bar];
      double atr_at_ext = s.m15.atr[ext_bar];
      bool has_ext = lng ? (ext <= ema_at_ext - m_cfg.extension_atr * atr_at_ext)
                         : (ext >= ema_at_ext + m_cfg.extension_atr * atr_at_ext);
      int confirmations = 1 + (has_div ? 1 : 0) + (has_sweep ? 1 : 0) + (has_rej ? 1 : 0) + (has_ext ? 1 : 0);
      if(confirmations < m_cfg.min_confirmations)
        {
         Reject(dir, StringFormat("confirmaciones %d < %d (div=%s sweep=%s rechazo=%s extensión=%s)", confirmations,
                                  m_cfg.min_confirmations, (has_div ? "sí" : "no"), (has_sweep ? "sí" : "no"),
                                  (has_rej ? "sí" : "no"), (has_ext ? "sí" : "no")));
         return false;
        }

      bool rej, m5brk;
      if(!M5Confirmation(s, dir, rej, m5brk))
        { Reject(dir, "sin confirmación M5 (rechazo o ruptura)"); return false; }

      double entry = m5.close;
      double sl;
      string why;
      if(!BuildStop(s, dir, entry, ext, sl, why))
        { Reject(dir, why); return false; }
      double extra[];
      ArrayResize(extra, 1);
      extra[0] = lng ? CPatterns::HighestHigh(s.m15, ext_bar, last) : CPatterns::LowestLow(s.m15, ext_bar, last);  // origen del tramo
      double tp = SelectTarget(s, dir, entry, extra);
      if(tp <= 0.0)
        { Reject(dir, "sin nivel de liquidez opuesto a distancia válida para el TP"); return false; }

      ResetEvidence(sig.evidence);
      sig.evidence.m15_event = SE_CHOCH;
      sig.evidence.m15_event_level = choch.level;
      sig.evidence.rsi_divergence = has_div;
      sig.evidence.sweep = has_sweep;
      sig.evidence.sweep_level = has_sweep ? sw.level : 0.0;
      sig.evidence.sweep_extreme = has_sweep ? sw.wick : 0.0;
      sig.evidence.m15_rejection = has_rej;
      sig.evidence.extension = has_ext;
      sig.evidence.confirmations = confirmations;
      sig.evidence.m5_rejection = rej;
      sig.evidence.m5_break = m5brk;
      sig.evidence.poi_low = lng ? ext : choch.level;
      sig.evidence.poi_high = lng ? choch.level : ext;

      sig.direction = dir;
      sig.origin_tf = PERIOD_M15;
      sig.entry_low = sig.evidence.poi_low;
      sig.entry_high = sig.evidence.poi_high;
      sig.entry_price = entry;
      sig.invalidation = ext;
      sig.sl = sl;
      sig.tp = tp;
      sig.setup_key = StringFormat("RV|%s|%s", EnumDirectionToString(dir),
                                   TimeToString(s.m15.rates[choch.bar].time, TIME_DATE | TIME_MINUTES));
      sig.reason = StringFormat("Reversión %s: CHoCH M15 en %.2f con %d/5 confirmaciones, extremo %.2f",
                                (lng ? "alcista" : "bajista"), choch.level, confirmations, ext);
      sig.evidence_text = StringFormat("choch=%.2f ext=%.2f div=%s(%.1f->%.1f) sweep=%s rej15=%s extension=%s m5rej=%s m5bos=%s",
                                       choch.level, ext, (has_div ? "yes" : "no"), div.rsi_old, div.rsi_new,
                                       (has_sweep ? "yes" : "no"), (has_rej ? "yes" : "no"), (has_ext ? "yes" : "no"),
                                       (rej ? "yes" : "no"), (m5brk ? "yes" : "no"));
      if(!Finalize(s, sig, why))
        { Reject(dir, "señal inválida: " + why); return false; }
      return true;
     }

public:
                     CStrategyReversal(void) { m_id = STRAT_REVERSAL; m_name = "RV"; ReversalDefaultConfig(m_cfg); }

   bool              Init(const StrategyCommonConfig &common, const ReversalConfig &cfg, CLogger *log)
     {
      string reason;
      m_log = log;
      m_ready = false;
      if(!StrategyCommonValidateConfig(common, reason) || !ReversalValidateConfig(cfg, reason))
        {
         if(m_log != NULL) m_log.Critical("StrategyReversal", "CONFIG_INVALID", reason);
         else PrintFormat("[StrategyReversal] CONFIG_INVALID %s", reason);
         return false;
        }
      m_common = common;
      m_cfg = cfg;
      m_ready = true;
      return true;
     }
  };

#endif // XAUUSD_STRATEGYREVERSAL_MQH
