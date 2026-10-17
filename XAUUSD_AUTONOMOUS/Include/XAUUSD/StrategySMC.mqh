//+------------------------------------------------------------------+
//| StrategySMC.mqh                                                  |
//| Setup Smart Money Concepts (compra; venta es el espejo):         |
//|  1. Contexto: régimen TREND_UP o RANGE.                          |
//|  2. M15: barrido de un mínimo confirmado (cierra de vuelta).     |
//|  3. M15: ruptura de estructura alcista por cierre DESPUÉS del    |
//|     barrido (BOS, CHoCH o ruptura con estructura previa mixta).  |
//|  4. Zona de interés en el desplazamiento: FVG alcista sin        |
//|     rellenar (preferente) u Order Block alcista sin invalidar.   |
//|  5. Descuento: el centro de la zona está bajo el 50 % del tramo  |
//|     mínimo del barrido -> máximo posterior.                      |
//|  6. M5: la última vela cerrada toca la zona sin cerrar debajo y  |
//|     hay confirmación (rechazo o ruptura M5).                     |
//| Invalidación: el extremo del barrido o el borde de la zona, el   |
//| que esté más lejos.                                              |
//+------------------------------------------------------------------+
#ifndef XAUUSD_STRATEGYSMC_MQH
#define XAUUSD_STRATEGYSMC_MQH

#include "StrategyBase.mqh"

struct SMCConfig
  {
   int               lookback_m15;        // velas M15 donde buscar el barrido
   double            sweep_min_pen_atr;   // penetración mínima del barrido (ATR)
   double            fvg_min_atr;         // tamaño mínimo del FVG (ATR)
   bool              use_fvg;
   bool              use_order_block;
   bool              require_discount;    // compras solo en descuento / ventas en premium
   bool              allow_in_range;
   bool              use_asia_range;      // rango asiático como liquidez (sin sentido en mercados 24/7 sin sesiones)
  };

void SMCDefaultConfig(SMCConfig &c)
  {
   c.lookback_m15 = 16;
   c.sweep_min_pen_atr = 0.05;
   c.fvg_min_atr = 0.1;
   c.use_fvg = true;
   c.use_order_block = true;
   c.require_discount = true;
   c.allow_in_range = true;
   c.use_asia_range = true;
  }

bool SMCValidateConfig(const SMCConfig &c, string &reason)
  {
   if(c.lookback_m15 < 3 || c.lookback_m15 > 100)
     { reason = "lookback_m15 debe estar en [3, 100]"; return false; }
   if(c.sweep_min_pen_atr < 0.0 || c.fvg_min_atr < 0.0)
     { reason = "umbrales ATR negativos"; return false; }
   if(!c.use_fvg && !c.use_order_block)
     { reason = "se requiere al menos FVG u Order Block"; return false; }
   reason = "";
   return true;
  }

class CStrategySMC : public CStrategyBase
  {
private:
   SMCConfig         m_cfg;

protected:
   virtual bool      EvaluateDir(const MarketSnapshot &s, const RegimeState &regime, const ENUM_DIRECTION dir,
                                 TradeSignal &sig)
     {
      bool lng = (dir == DIR_LONG);
      if(!RegimeAllows(regime.regime, dir, REGIME_TREND_UP, REGIME_TREND_DOWN, m_cfg.allow_in_range))
        { Reject(dir, "régimen " + EnumRegimeToString(regime.regime) + " incompatible"); return false; }
      int n15 = m_common.pivot_n_m15;

      SweepInfo sw;
      if(!CPatterns::FindSweep(s.m15, !lng, m_cfg.lookback_m15, n15, m_cfg.sweep_min_pen_atr, sw))
        { Reject(dir, "sin barrido de liquidez M15"); return false; }
      if(sw.bar < 1)
        { Reject(dir, "barrido en la última vela: falta la ruptura"); return false; }

      BreakInfo br;
      if(!CPatterns::FindBreak(s.m15, dir, 0, sw.bar - 1, n15, br))
        { Reject(dir, "sin ruptura de estructura M15 tras el barrido"); return false; }

      ZoneInfo fvg, ob;
      bool has_fvg = m_cfg.use_fvg &&
                     CPatterns::FindFVG(s.m15, dir, MathMax(br.bar - 1, 0), sw.bar - 2, m_cfg.fvg_min_atr, fvg);
      bool has_ob = m_cfg.use_order_block &&
                    CPatterns::FindOrderBlock(s.m15, dir, br.bar, sw.bar - br.bar, ob);
      if(!has_fvg && !has_ob)
        { Reject(dir, "sin FVG ni Order Block válidos en el desplazamiento"); return false; }
      double poi_top = has_fvg ? fvg.top : ob.top;
      double poi_bot = has_fvg ? fvg.bottom : ob.bottom;

      //--- descuento / premium respecto al tramo barrido -> extremo posterior
      double leg_ext = lng ? CPatterns::HighestHigh(s.m15, 0, sw.bar) : CPatterns::LowestLow(s.m15, 0, sw.bar);
      double eq = (sw.wick + leg_ext) / 2.0;
      double poi_mid = (poi_top + poi_bot) / 2.0;
      bool dp_ok = lng ? (poi_mid < eq) : (poi_mid > eq);
      if(m_cfg.require_discount && !dp_ok)
        { Reject(dir, StringFormat("zona %.2f fuera de %s (equilibrio %.2f)", poi_mid, (lng ? "descuento" : "premium"), eq)); return false; }

      //--- precio en la zona (última vela M5 cerrada)
      const MqlRates m5 = s.m5.rates[0];
      bool at_poi = lng ? (m5.low <= poi_top && m5.close >= poi_bot) : (m5.high >= poi_bot && m5.close <= poi_top);
      if(!at_poi)
        { Reject(dir, StringFormat("precio M5 %.2f no está en la zona [%.2f, %.2f]", m5.close, poi_bot, poi_top)); return false; }

      bool rej, m5brk;
      if(!M5Confirmation(s, dir, rej, m5brk))
        { Reject(dir, "sin confirmación M5 (rechazo o ruptura)"); return false; }

      double entry = m5.close;
      double invalidation = lng ? MathMin(sw.wick, poi_bot) : MathMax(sw.wick, poi_top);
      double sl;
      string why;
      if(!BuildStop(s, dir, entry, invalidation, sl, why))
        { Reject(dir, why); return false; }

      double extra[];
      ArrayResize(extra, 2);
      extra[0] = leg_ext;
      double ahi = 0.0, alo = 0.0;
      bool asia = m_cfg.use_asia_range && CPatterns::AsiaRange(s.m15, (int)(s.server_time - s.utc_time), ahi, alo);
      extra[1] = asia ? (lng ? ahi : alo) : 0.0;
      double tp = SelectTarget(s, dir, entry, extra);
      if(tp <= 0.0)
        { Reject(dir, "sin nivel de liquidez opuesto a distancia válida para el TP"); return false; }

      ResetEvidence(sig.evidence);
      sig.evidence.sweep = true;
      sig.evidence.sweep_level = sw.level;
      sig.evidence.sweep_extreme = sw.wick;
      sig.evidence.sweep_session_level = asia && MathAbs(sw.level - (lng ? alo : ahi)) <= 0.25 * s.m15.atr[0];
      sig.evidence.m15_event = br.type;
      sig.evidence.m15_event_level = br.level;
      sig.evidence.fvg = has_fvg;
      sig.evidence.order_block = has_ob;
      sig.evidence.discount_premium_ok = dp_ok;
      sig.evidence.m5_rejection = rej;
      sig.evidence.m5_break = m5brk;
      sig.evidence.poi_low = poi_bot;
      sig.evidence.poi_high = poi_top;

      sig.direction = dir;
      sig.origin_tf = PERIOD_M15;
      sig.entry_low = poi_bot;
      sig.entry_high = poi_top;
      sig.entry_price = entry;
      sig.invalidation = invalidation;
      sig.sl = sl;
      sig.tp = tp;
      sig.setup_key = StringFormat("SMC|%s|%s|%s", EnumDirectionToString(dir),
                                   TimeToString(s.m15.rates[sw.bar].time, TIME_DATE | TIME_MINUTES),
                                   TimeToString(s.m15.rates[br.bar].time, TIME_DATE | TIME_MINUTES));
      sig.reason = StringFormat("SMC %s: barrido %.2f, %s M15 en %.2f, retorno a %s en %s",
                                (lng ? "compra" : "venta"), sw.level, EnumStructEventToString(br.type), br.level,
                                (has_fvg ? "FVG" : "OB"), (lng ? "descuento" : "premium"));
      sig.evidence_text = StringFormat("sweep=%.2f wick=%.2f event=%s@%.2f fvg=%s ob=%s poi=[%.2f,%.2f] eq=%.2f m5rej=%s m5bos=%s asia=%s",
                                       sw.level, sw.wick, EnumStructEventToString(br.type), br.level,
                                       (has_fvg ? "yes" : "no"), (has_ob ? "yes" : "no"), poi_bot, poi_top, eq,
                                       (rej ? "yes" : "no"), (m5brk ? "yes" : "no"),
                                       (sig.evidence.sweep_session_level ? "yes" : "no"));
      if(!Finalize(s, sig, why))
        { Reject(dir, "señal inválida: " + why); return false; }
      return true;
     }

public:
                     CStrategySMC(void) { m_id = STRAT_SMC; m_name = "SMC"; SMCDefaultConfig(m_cfg); }

   bool              Init(const StrategyCommonConfig &common, const SMCConfig &cfg, CLogger *log)
     {
      string reason;
      m_log = log;
      m_ready = false;
      if(!StrategyCommonValidateConfig(common, reason) || !SMCValidateConfig(cfg, reason))
        {
         if(m_log != NULL) m_log.Critical("StrategySMC", "CONFIG_INVALID", reason);
         else PrintFormat("[StrategySMC] CONFIG_INVALID %s", reason);
         return false;
        }
      m_common = common;
      m_cfg = cfg;
      m_ready = true;
      return true;
     }
  };

#endif // XAUUSD_STRATEGYSMC_MQH
