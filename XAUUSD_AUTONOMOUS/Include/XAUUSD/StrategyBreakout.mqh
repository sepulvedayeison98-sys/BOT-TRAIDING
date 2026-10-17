//+------------------------------------------------------------------+
//| StrategyBreakout.mqh                                             |
//| Ruptura de consolidación (compra; venta es el espejo):           |
//|  1. Contexto: régimen TREND_UP o RANGE.                          |
//|  2. M15: caja de box_bars velas con altura <= max_box_atr ATR.   |
//|  3. M15: vela de ruptura que cierra fuera por >= min_break_atr   |
//|     ATR, cuerpo >= min_body_ratio del rango; sin cierres         |
//|     posteriores de vuelta dentro (falsa ruptura = descarte).     |
//|  4. Volumen: tick volume >= min_vol_ratio x media de la caja     |
//|     (proxy imperfecto; obligatorio solo si require_volume).      |
//|  5. Entrada M5: retest del borde roto con vela alcista que cierra|
//|     fuera, o continuación (ruptura M5) si pasaron                |
//|     >= continuation_min_bars velas M15 sin retest.               |
//| Invalidación: mitad de la caja (si el precio vuelve ahí, la      |
//| ruptura fracasó).                                                |
//| Filtros de volatilidad y spread: los aplica el régimen           |
//| (HIGH_VOLATILITY y spread anómalo -> sin señales).               |
//+------------------------------------------------------------------+
#ifndef XAUUSD_STRATEGYBREAKOUT_MQH
#define XAUUSD_STRATEGYBREAKOUT_MQH

#include "StrategyBase.mqh"

struct BreakoutConfig
  {
   int               box_bars;
   double            max_box_atr;
   double            min_break_atr;
   double            min_body_ratio;
   double            min_vol_ratio;
   bool              require_volume;
   int               max_bars_since_break;
   double            retest_tol_atr;
   int               continuation_min_bars;
   bool              allow_in_range;
  };

void BreakoutDefaultConfig(BreakoutConfig &c)
  {
   c.box_bars = 12;
   c.max_box_atr = 3.0;
   c.min_break_atr = 0.1;
   c.min_body_ratio = 0.6;
   c.min_vol_ratio = 1.2;
   c.require_volume = false;
   c.max_bars_since_break = 8;
   c.retest_tol_atr = 0.2;
   c.continuation_min_bars = 3;
   c.allow_in_range = true;
  }

bool BreakoutValidateConfig(const BreakoutConfig &c, string &reason)
  {
   if(c.box_bars < 4 || c.box_bars > 96)
     { reason = "box_bars debe estar en [4, 96]"; return false; }
   if(c.max_box_atr <= 0.0 || c.min_break_atr < 0.0 || c.retest_tol_atr < 0.0)
     { reason = "umbrales ATR inválidos"; return false; }
   if(c.min_body_ratio <= 0.0 || c.min_body_ratio >= 1.0)
     { reason = "min_body_ratio debe estar en (0, 1)"; return false; }
   if(c.min_vol_ratio < 1.0)
     { reason = "min_vol_ratio debe ser >= 1"; return false; }
   if(c.max_bars_since_break < 0 || c.continuation_min_bars < 0 || c.continuation_min_bars > c.max_bars_since_break)
     { reason = "ventanas de ruptura/continuación inválidas"; return false; }
   reason = "";
   return true;
  }

class CStrategyBreakout : public CStrategyBase
  {
private:
   BreakoutConfig    m_cfg;

protected:
   virtual bool      EvaluateDir(const MarketSnapshot &s, const RegimeState &regime, const ENUM_DIRECTION dir,
                                 TradeSignal &sig)
     {
      bool lng = (dir == DIR_LONG);
      if(!RegimeAllows(regime.regime, dir, REGIME_TREND_UP, REGIME_TREND_DOWN, m_cfg.allow_in_range))
        { Reject(dir, "régimen " + EnumRegimeToString(regime.regime) + " incompatible"); return false; }

      BoxInfo box;
      if(!CPatterns::FindBoxBreakout(s.m15, dir, m_cfg.max_bars_since_break, m_cfg.box_bars, m_cfg.max_box_atr,
                                     m_cfg.min_break_atr, m_cfg.min_body_ratio, m_cfg.min_vol_ratio, box))
        { Reject(dir, "sin ruptura válida de consolidación M15"); return false; }
      if(m_cfg.require_volume && !box.volume_expansion)
        { Reject(dir, box.volume_available ? "ruptura sin expansión de volumen" : "volumen requerido pero no disponible"); return false; }

      double edge = lng ? box.top : box.bottom;
      double tol = m_cfg.retest_tol_atr * s.m15.atr[0];
      const MqlRates m5 = s.m5.rates[0];
      bool outside = lng ? (m5.close > edge) : (m5.close < edge);
      if(!outside)
        { Reject(dir, StringFormat("precio M5 %.2f volvió a la caja (borde %.2f)", m5.close, edge)); return false; }
      bool retest = lng ? (m5.low <= edge + tol && m5.close > m5.open)
                        : (m5.high >= edge - tol && m5.close < m5.open);
      bool rej, m5brk;
      bool confirmed = M5Confirmation(s, dir, rej, m5brk);
      bool continuation = (!retest && box.break_bar >= m_cfg.continuation_min_bars && m5brk);
      if(!retest && !continuation)
        { Reject(dir, StringFormat("sin retest del borde %.2f ni continuación confirmada", edge)); return false; }

      double entry = m5.close;
      double invalidation = (box.top + box.bottom) / 2.0;
      double sl;
      string why;
      if(!BuildStop(s, dir, entry, invalidation, sl, why))
        { Reject(dir, why); return false; }

      double height = box.top - box.bottom;
      double extra[];
      ArrayResize(extra, 1);
      extra[0] = lng ? box.top + height : box.bottom - height;   // proyección de la caja
      double tp = SelectTarget(s, dir, entry, extra);
      if(tp <= 0.0)
        { Reject(dir, "sin objetivo a distancia válida para el TP"); return false; }

      ResetEvidence(sig.evidence);
      sig.evidence.consolidation = true;
      sig.evidence.m15_event = SE_BREAK;
      sig.evidence.m15_event_level = edge;
      sig.evidence.volume_available = box.volume_available;
      sig.evidence.volume_expansion = box.volume_expansion;
      sig.evidence.retest = retest;
      sig.evidence.m5_rejection = rej;
      sig.evidence.m5_break = m5brk;
      sig.evidence.poi_low = lng ? edge : edge - tol;
      sig.evidence.poi_high = lng ? edge + tol : edge;

      sig.direction = dir;
      sig.origin_tf = PERIOD_M15;
      sig.entry_low = sig.evidence.poi_low;
      sig.entry_high = sig.evidence.poi_high;
      sig.entry_price = entry;
      sig.invalidation = invalidation;
      sig.sl = sl;
      sig.tp = tp;
      sig.setup_key = StringFormat("BO|%s|%s", EnumDirectionToString(dir),
                                   TimeToString(s.m15.rates[box.break_bar].time, TIME_DATE | TIME_MINUTES));
      sig.reason = StringFormat("Breakout %s: caja [%.2f, %.2f] (%.1f ATR) rota hace %d velas M15, entrada por %s",
                                (lng ? "alcista" : "bajista"), box.bottom, box.top, height / s.m15.atr[0],
                                box.break_bar, (retest ? "retest" : "continuación"));
      sig.evidence_text = StringFormat("box=[%.2f,%.2f] break_bar=%d vol=%s volexp=%s retest=%s m5rej=%s m5bos=%s confirmed=%s",
                                       box.bottom, box.top, box.break_bar, (box.volume_available ? "yes" : "no"),
                                       (box.volume_expansion ? "yes" : "no"), (retest ? "yes" : "no"),
                                       (rej ? "yes" : "no"), (m5brk ? "yes" : "no"), (confirmed ? "yes" : "no"));
      if(!Finalize(s, sig, why))
        { Reject(dir, "señal inválida: " + why); return false; }
      return true;
     }

public:
                     CStrategyBreakout(void) { m_id = STRAT_BREAKOUT; m_name = "BO"; BreakoutDefaultConfig(m_cfg); }

   bool              Init(const StrategyCommonConfig &common, const BreakoutConfig &cfg, CLogger *log)
     {
      string reason;
      m_log = log;
      m_ready = false;
      if(!StrategyCommonValidateConfig(common, reason) || !BreakoutValidateConfig(cfg, reason))
        {
         if(m_log != NULL) m_log.Critical("StrategyBreakout", "CONFIG_INVALID", reason);
         else PrintFormat("[StrategyBreakout] CONFIG_INVALID %s", reason);
         return false;
        }
      m_common = common;
      m_cfg = cfg;
      m_ready = true;
      return true;
     }
  };

#endif // XAUUSD_STRATEGYBREAKOUT_MQH
