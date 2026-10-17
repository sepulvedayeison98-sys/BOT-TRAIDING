//+------------------------------------------------------------------+
//| PositionManager.mqh                                              |
//| Gestión protectora de las posiciones propias (magic + símbolo).  |
//|  - Fuente de verdad: el servidor (vía CTradeGateway). Los        |
//|    metadatos (SL inicial, invalidación, señal) se guardan en     |
//|    StateStore; una posición sin metadatos se adopta como         |
//|    "huérfana" con SL inicial = SL actual.                        |
//|  - Posición sin SL: se le pone un SL protector y se marca        |
//|    situación crítica (modo seguro).                              |
//|  - Break-even a 1R, trailing desde 1.5R (ATR o pivote M5).       |
//|  - El SL NUNCA se mueve en contra (no aumenta la pérdida).       |
//|  - Respeta stops level y freeze level.                           |
//|  - Cierre por invalidación estructural (cierre M15 más allá).    |
//|  - Funciona igual en Hedging y Netting (cierre por ticket).      |
//| La gestión protectora sigue activa en pausa, modo seguro y con   |
//| el límite diario alcanzado.                                      |
//+------------------------------------------------------------------+
#ifndef XAUUSD_POSITIONMANAGER_MQH
#define XAUUSD_POSITIONMANAGER_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "TradeGateway.mqh"
#include "StateStore.mqh"

#define PM_MODULE "PositionManager"
#define PM_TRAIL_ATR   0
#define PM_TRAIL_SWING 1

struct PositionConfig
  {
   long              magic;
   double            be_trigger_r;        // R alcanzado para mover a break-even
   int               be_offset_points;    // colchón sobre la entrada (además del spread actual) para cubrir costos
   double            trail_start_r;       // R alcanzado para activar el trailing
   int               trail_mode;          // PM_TRAIL_ATR o PM_TRAIL_SWING
   double            trail_atr_mult;      // distancia del trailing en ATR M5
   double            swing_buffer_atr;    // colchón bajo/sobre el pivote M5 (ATR M5)
   bool              close_on_invalidation;
   double            fallback_sl_atr;     // SL protector para posiciones sin SL (ATR M15)
   int               max_modify_failures; // fallos seguidos al modificar -> crítico
   int               deviation_points;
  };

void PositionDefaultConfig(PositionConfig &c)
  {
   c.magic = 26101201;
   c.be_trigger_r = 1.0;
   c.be_offset_points = 10;
   c.trail_start_r = 1.5;
   c.trail_mode = PM_TRAIL_ATR;
   c.trail_atr_mult = 1.5;
   c.swing_buffer_atr = 0.2;
   c.close_on_invalidation = true;
   c.fallback_sl_atr = 2.0;
   c.max_modify_failures = 3;
   c.deviation_points = 30;
  }

bool PositionValidateConfig(const PositionConfig &c, string &reason)
  {
   if(c.magic <= 0)                                       { reason = "magic debe ser > 0"; return false; }
   if(c.be_trigger_r <= 0.0)                              { reason = "be_trigger_r debe ser > 0"; return false; }
   if(c.trail_start_r < c.be_trigger_r)                   { reason = "el trailing debe empezar en o después del break-even"; return false; }
   if(c.be_offset_points < 0 || c.trail_atr_mult <= 0.0 || c.swing_buffer_atr < 0.0 || c.fallback_sl_atr <= 0.0)
     { reason = "distancias inválidas"; return false; }
   if(c.trail_mode != PM_TRAIL_ATR && c.trail_mode != PM_TRAIL_SWING) { reason = "trail_mode inválido"; return false; }
   if(c.max_modify_failures < 1)                          { reason = "max_modify_failures debe ser >= 1"; return false; }
   reason = "";
   return true;
  }

class CPositionManager
  {
private:
   PositionConfig    m_cfg;
   CTradeGateway    *m_gw;
   CLogger          *m_log;
   string            m_symbol;
   bool              m_ready;
   PositionMeta      m_meta[];
   ulong             m_fail_ticket[];
   int               m_fail_count[];
   bool              m_critical;
   string            m_critical_reason;

   void              LogMsg(const ENUM_LOG_LEVEL l, const string ev, const string msg, const string id = "")
     {
      if(m_log != NULL)
         m_log.Log(l, PM_MODULE, ev, msg, id);
     }

   int               FindMeta(const long id) const
     {
      for(int i = 0; i < ArraySize(m_meta); i++)
         if(m_meta[i].identifier == id)
            return i;
      return -1;
     }

   void              Critical(const string why)
     {
      m_critical = true;
      m_critical_reason = why;
      LogMsg(LOG_CRITICAL, "CRITICAL", why);
     }

   int               FailIndex(const ulong ticket)
     {
      for(int i = 0; i < ArraySize(m_fail_ticket); i++)
         if(m_fail_ticket[i] == ticket)
            return i;
      int n = ArraySize(m_fail_ticket);
      ArrayResize(m_fail_ticket, n + 1);
      ArrayResize(m_fail_count, n + 1);
      m_fail_ticket[n] = ticket;
      m_fail_count[n] = 0;
      return n;
     }

   bool              ModifySL(const PositionInfo &p, const double new_sl, const SymbolSpec &spec, const string why)
     {
      MqlTradeRequest req;
      MqlTradeResult res;
      ZeroMemory(req);
      req.action = TRADE_ACTION_SLTP;
      req.symbol = m_symbol;
      req.position = p.ticket;
      req.sl = NormalizeDouble(new_sl, spec.digits);
      req.tp = p.tp;
      req.magic = (ulong)m_cfg.magic;
      bool ok = m_gw.Send(req, res);
      int fi = FailIndex(p.ticket);
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_NO_CHANGES)
        {
         m_fail_count[fi] = 0;
         LogMsg(LOG_INFO, "SL_MODIFIED", StringFormat("ticket %s SL %.*f -> %.*f (%s)", IntegerToString((long)p.ticket),
                                                      spec.digits, p.sl, spec.digits, req.sl, why));
         return true;
        }
      m_fail_count[fi]++;
      LogMsg(LOG_WARN, "SL_MODIFY_FAILED", StringFormat("ticket %s retcode %u %s (fallo %d)", IntegerToString((long)p.ticket),
                                                        res.retcode, res.comment, m_fail_count[fi]));
      if(m_fail_count[fi] >= m_cfg.max_modify_failures)
         Critical(StringFormat("no se pudo modificar el SL de %s tras %d intentos", IntegerToString((long)p.ticket), m_fail_count[fi]));
      return false;
     }

   bool              ClosePosition(const PositionInfo &p, const SymbolSpec &spec, const string why)
     {
      MqlTick tk;
      if(!m_gw.Tick(m_symbol, tk))
         return false;
      MqlTradeRequest req;
      MqlTradeResult res;
      ZeroMemory(req);
      req.action = TRADE_ACTION_DEAL;
      req.symbol = m_symbol;
      req.position = p.ticket;
      req.volume = p.volume;
      req.type = (p.direction == DIR_LONG) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = (p.direction == DIR_LONG) ? tk.bid : tk.ask;
      req.deviation = (ulong)m_cfg.deviation_points;
      req.magic = (ulong)m_cfg.magic;
      long f = m_gw.FillingFlags(m_symbol);
      req.type_filling = ((f & SYMBOL_FILLING_FOK) != 0) ? ORDER_FILLING_FOK : (((f & SYMBOL_FILLING_IOC) != 0) ? ORDER_FILLING_IOC : ORDER_FILLING_RETURN);
      m_gw.Send(req, res);
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL || res.retcode == TRADE_RETCODE_PLACED)
        {
         LogMsg(LOG_INFO, "CLOSED", StringFormat("ticket %s cerrado: %s", IntegerToString((long)p.ticket), why));
         return true;
        }
      LogMsg(LOG_ERROR, "CLOSE_FAILED", StringFormat("ticket %s retcode %u %s (%s)", IntegerToString((long)p.ticket), res.retcode, res.comment, why));
      return false;
     }

public:
                     CPositionManager(void)
     {
      PositionDefaultConfig(m_cfg);
      m_gw = NULL;
      m_log = NULL;
      m_symbol = "";
      m_ready = false;
      m_critical = false;
      m_critical_reason = "";
     }

   bool              Init(const string symbol, const PositionConfig &cfg, CTradeGateway *gw, CLogger *log)
     {
      m_log = log;
      string reason;
      m_ready = false;
      if(gw == NULL)
         reason = "gateway no proporcionado";
      else
         if(PositionValidateConfig(cfg, reason))
           {
            m_cfg = cfg;
            m_gw = gw;
            m_symbol = symbol;
            m_ready = true;
            return true;
           }
      if(m_log != NULL) m_log.Critical(PM_MODULE, "CONFIG_INVALID", reason);
      else PrintFormat("[%s] CONFIG_INVALID %s", PM_MODULE, reason);
      return false;
     }

   //--- Offset de break-even y desviación en puntos (perfiles sintéticos: relativos al ATR)
   bool              SetCostLimits(const int be_offset_points, const int deviation_points)
     {
      if(be_offset_points < 0 || deviation_points < 0)
         return false;
      m_cfg.be_offset_points = be_offset_points;
      m_cfg.deviation_points = deviation_points;
      return true;
     }

   bool              CriticalFlag(void) const      { return m_critical; }
   string            CriticalReason(void) const    { return m_critical_reason; }
   void              ClearCritical(void)           { m_critical = false; m_critical_reason = ""; }
   int               MetaCount(void) const         { return ArraySize(m_meta); }

   bool              GetMeta(const long id, PositionMeta &out) const
     {
      int i = FindMeta(id);
      if(i < 0)
         return false;
      out = m_meta[i];
      return true;
     }

   //--- Registra una posición nueva propia (tras reconciliar la ejecución)
   void              RegisterPosition(const long identifier, const PendingRequest &p)
     {
      int i = FindMeta(identifier);
      if(i < 0)
        {
         i = ArraySize(m_meta);
         ArrayResize(m_meta, i + 1);
        }
      m_meta[i].identifier = identifier;
      m_meta[i].signal_id = p.signal_id;
      m_meta[i].setup_key = p.setup_key;
      m_meta[i].strategy = p.strategy;
      m_meta[i].initial_sl = p.initial_sl;
      m_meta[i].invalidation = p.invalidation;
      m_meta[i].be_done = false;
      m_meta[i].orphan = false;
      LogMsg(LOG_INFO, "REGISTERED", StringFormat("posición %s <- señal %s", IntegerToString(identifier), p.signal_id), p.signal_id);
     }

   //--- Posiciones propias actuales y sincronización de metadatos (adopta huérfanas, purga cerradas).
   int               Sync(PositionInfo &pos[])
     {
      int n = m_gw.Positions(m_symbol, m_cfg.magic, pos);
      for(int i = 0; i < n; i++)
        {
         if(FindMeta(pos[i].identifier) >= 0)
            continue;
         int k = ArraySize(m_meta);
         ArrayResize(m_meta, k + 1);
         ZeroMemory(m_meta[k]);
         m_meta[k].identifier = pos[i].identifier;
         m_meta[k].signal_id = "";
         m_meta[k].setup_key = "";
         m_meta[k].strategy = STRAT_NONE;
         m_meta[k].initial_sl = pos[i].sl;
         m_meta[k].invalidation = 0.0;
         m_meta[k].be_done = false;
         m_meta[k].orphan = true;
         LogMsg(LOG_WARN, "ORPHAN_ADOPTED", StringFormat("posición %s sin metadatos: SL inicial = SL actual %.2f",
                                                         IntegerToString(pos[i].identifier), pos[i].sl));
        }
      //--- purga de metadatos de posiciones que ya no existen
      int w = 0;
      for(int j = 0; j < ArraySize(m_meta); j++)
        {
         bool alive = false;
         for(int i = 0; i < n && !alive; i++)
            alive = (pos[i].identifier == m_meta[j].identifier);
         if(alive)
           {
            if(w != j)
               m_meta[w] = m_meta[j];
            w++;
           }
        }
      ArrayResize(m_meta, w);
      return n;
     }

   //--- Gestión protectora. snapshot_valid=false: solo se gestiona lo que no depende de indicadores.
   int               Manage(const MarketSnapshot &s, const bool snapshot_valid, const SymbolSpec &spec)
     {
      if(!m_ready)
         return 0;
      PositionInfo pos[];
      int n = Sync(pos);
      MqlTick tk;
      if(n == 0 || !m_gw.Tick(m_symbol, tk) || tk.bid <= 0)
         return n;
      double spread_pts = (tk.ask - tk.bid) / spec.point;
      double stops = spec.stops_level * spec.point;
      double freeze = spec.freeze_level * spec.point;
      double atr15 = (snapshot_valid && s.m15.bars > 0) ? s.m15.atr[0] : 0.0;
      double atr5 = (snapshot_valid && s.m5.bars > 0) ? s.m5.atr[0] : 0.0;
      for(int i = 0; i < n; i++)
        {
         PositionInfo p = pos[i];
         int mi = FindMeta(p.identifier);
         bool lng = (p.direction == DIR_LONG);
         double px = lng ? tk.bid : tk.ask;   // precio al que se cerraría

         //--- 1. posición sin SL
         if(p.sl <= 0.0)
           {
            double ref = (mi >= 0 && m_meta[mi].initial_sl > 0) ? m_meta[mi].initial_sl : 0.0;
            if(ref <= 0.0 && atr15 > 0.0)
               ref = lng ? p.open_price - m_cfg.fallback_sl_atr * atr15 : p.open_price + m_cfg.fallback_sl_atr * atr15;
            if(ref > 0.0)
              {
               // nunca más cerca que el stops level
               if(lng) ref = MathMin(ref, px - stops - spec.point);
               else    ref = MathMax(ref, px + stops + spec.point);
               ModifySL(p, ref, spec, "SL protector: la posición no tenía SL");
               if(mi >= 0 && m_meta[mi].initial_sl <= 0)
                  m_meta[mi].initial_sl = ref;
              }
            Critical(StringFormat("posición %s sin Stop Loss", IntegerToString((long)p.ticket)));
            continue;
           }
         //--- 2. invalidación estructural
         if(m_cfg.close_on_invalidation && snapshot_valid && mi >= 0 && m_meta[mi].invalidation > 0.0 && s.m15.bars > 0)
           {
            double c15 = s.m15.rates[0].close;
            bool invalid = lng ? (c15 < m_meta[mi].invalidation) : (c15 > m_meta[mi].invalidation);
            if(invalid)
              {
               ClosePosition(p, spec, StringFormat("invalidación estructural: cierre M15 %.2f más allá de %.2f", c15, m_meta[mi].invalidation));
               continue;
              }
           }
         //--- 3. break-even y trailing
         double initial_sl = (mi >= 0 && m_meta[mi].initial_sl > 0) ? m_meta[mi].initial_sl : p.sl;
         double R = MathAbs(p.open_price - initial_sl);
         if(R <= 0.0)
            continue;
         double progress = (lng ? px - p.open_price : p.open_price - px) / R;
         double desired = p.sl;
         string why = "";
         if(progress >= m_cfg.be_trigger_r)
           {
            double be = lng ? p.open_price + (m_cfg.be_offset_points + spread_pts) * spec.point
                            : p.open_price - (m_cfg.be_offset_points + spread_pts) * spec.point;
            if((lng && be > desired) || (!lng && be < desired))
              { desired = be; why = StringFormat("break-even a %.2fR", progress); }
           }
         if(progress >= m_cfg.trail_start_r && snapshot_valid)
           {
            double cand = 0.0;
            if(m_cfg.trail_mode == PM_TRAIL_ATR && atr5 > 0.0)
               cand = lng ? px - m_cfg.trail_atr_mult * atr5 : px + m_cfg.trail_atr_mult * atr5;
            else
               if(m_cfg.trail_mode == PM_TRAIL_SWING)
                 {
                  for(int k = 0; k < s.m5.swing_count; k++)
                    {
                     if(s.m5.swings[k].is_high == lng)
                        continue;
                     double lvl = s.m5.swings[k].price;
                     if((lng && lvl < px) || (!lng && lvl > px))
                       {
                        cand = lng ? lvl - m_cfg.swing_buffer_atr * atr5 : lvl + m_cfg.swing_buffer_atr * atr5;
                        break;
                       }
                    }
                 }
            if(cand > 0.0 && ((lng && cand > desired) || (!lng && cand < desired)))
              { desired = cand; why = StringFormat("trailing a %.2fR", progress); }
           }
         if(why == "")
            continue;
         //--- límites del bróker
         if(lng) desired = MathMin(desired, px - stops - spec.point);
         else    desired = MathMax(desired, px + stops + spec.point);
         desired = NormalizeDouble(desired, spec.digits);
         bool improves = lng ? (desired > p.sl + spec.point / 2.0) : (desired < p.sl - spec.point / 2.0);
         if(!improves)
            continue;   // invariante: nunca se aleja el SL
         if(MathAbs(px - p.sl) <= freeze || (p.tp > 0 && MathAbs(p.tp - px) <= freeze))
           {
            LogMsg(LOG_DEBUG, "FROZEN", StringFormat("ticket %s dentro del freeze level", IntegerToString((long)p.ticket)));
            continue;
           }
         if(ModifySL(p, desired, spec, why) && mi >= 0 && ((lng && desired >= p.open_price) || (!lng && desired <= p.open_price)))
            m_meta[mi].be_done = true;
        }
      return n;
     }

   //--- Cierre de todas las posiciones propias (solo con confirmación explícita del usuario)
   int               CloseAll(const SymbolSpec &spec, const string why)
     {
      PositionInfo pos[];
      int n = m_gw.Positions(m_symbol, m_cfg.magic, pos);
      int closed = 0;
      for(int i = 0; i < n; i++)
         if(ClosePosition(pos[i], spec, why))
            closed++;
      return closed;
     }

   void              Briefs(const PositionInfo &pos[], PositionBrief &out[]) const
     {
      int n = ArraySize(pos);
      ArrayResize(out, n);
      for(int i = 0; i < n; i++)
        {
         out[i].ticket = pos[i].ticket;
         out[i].direction = pos[i].direction;
         out[i].open_price = pos[i].open_price;
         int mi = FindMeta(pos[i].identifier);
         out[i].setup_key = (mi >= 0) ? m_meta[mi].setup_key : "";
        }
     }

   static void       Risks(const PositionInfo &pos[], PositionRisk &out[])
     {
      int n = ArraySize(pos);
      ArrayResize(out, n);
      for(int i = 0; i < n; i++)
        {
         out[i].ticket = pos[i].ticket;
         out[i].direction = pos[i].direction;
         out[i].volume = pos[i].volume;
         out[i].open_price = pos[i].open_price;
         out[i].sl = pos[i].sl;
        }
     }

   //--- Racha de pérdidas cerradas más reciente (para la reducción opcional de riesgo)
   int               ConsecutiveLosses(const datetime from, const datetime to)
     {
      ClosedTrade t[];
      int n = m_gw.ClosedTrades(m_symbol, m_cfg.magic, from, to, t);
      // orden por hora de cierre
      for(int i = 1; i < n; i++)
        {
         ClosedTrade x = t[i];
         int j = i - 1;
         while(j >= 0 && t[j].close_time > x.close_time)
           {
            t[j + 1] = t[j];
            j--;
           }
         t[j + 1] = x;
        }
      int streak = 0;
      for(int i = n - 1; i >= 0; i--)
        {
         if(t[i].profit + t[i].commission + t[i].swap < 0.0)
            streak++;
         else
            break;
        }
      return streak;
     }

   //--- Persistencia de metadatos
   void              SaveMeta(CStateStore &st) const
     {
      string keys[];
      int k = st.KeysWithPrefix("pos.", keys);
      for(int i = 0; i < k; i++)
         st.Remove(keys[i]);
      for(int i = 0; i < ArraySize(m_meta); i++)
        {
         string p = "pos." + IntegerToString(m_meta[i].identifier) + ".";
         st.Set(p + "signal", m_meta[i].signal_id);
         st.Set(p + "setup", m_meta[i].setup_key);
         st.SetLong(p + "strategy", (long)m_meta[i].strategy);
         st.SetDouble(p + "initial_sl", m_meta[i].initial_sl);
         st.SetDouble(p + "invalidation", m_meta[i].invalidation);
         st.SetBool(p + "be_done", m_meta[i].be_done);
         st.SetBool(p + "orphan", m_meta[i].orphan);
        }
     }

   int               LoadMeta(const CStateStore &st)
     {
      ArrayResize(m_meta, 0);
      string keys[];
      int k = st.KeysWithPrefix("pos.", keys);
      for(int i = 0; i < k; i++)
        {
         int last = StringFind(keys[i], ".signal");
         if(last < 0 || last + 7 != StringLen(keys[i]))
            continue;
         string idtxt = StringSubstr(keys[i], 4, last - 4);
         long id = StringToInteger(idtxt);
         string p = "pos." + idtxt + ".";
         int n = ArraySize(m_meta);
         ArrayResize(m_meta, n + 1);
         m_meta[n].identifier = id;
         m_meta[n].signal_id = st.Get(p + "signal");
         m_meta[n].setup_key = st.Get(p + "setup");
         m_meta[n].strategy = (ENUM_STRATEGY_ID)st.GetLong(p + "strategy");
         m_meta[n].initial_sl = st.GetDouble(p + "initial_sl");
         m_meta[n].invalidation = st.GetDouble(p + "invalidation");
         m_meta[n].be_done = st.GetBool(p + "be_done");
         m_meta[n].orphan = st.GetBool(p + "orphan");
        }
      return ArraySize(m_meta);
     }
  };

#endif // XAUUSD_POSITIONMANAGER_MQH
