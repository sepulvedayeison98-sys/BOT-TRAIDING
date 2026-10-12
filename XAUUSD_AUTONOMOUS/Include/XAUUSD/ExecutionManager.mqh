//+------------------------------------------------------------------+
//| ExecutionManager.mqh                                             |
//| Responsable EXCLUSIVO de enviar órdenes de apertura.             |
//|  - Valida: decisión de riesgo aprobada, trading permitido,       |
//|    mercado abierto, spread, desvío de precio, volumen, stops     |
//|    level, sin solicitud pendiente sin resolver.                  |
//|  - OrderCheck antes de OrderSend.                                |
//|  - Reintenta SOLO cuando el servidor confirma que no ejecutó     |
//|    (recotización / precio cambiado), con límite.                 |
//|  - Resultado incierto (timeout, sin respuesta, conexión):        |
//|    NO reintenta; queda una solicitud pendiente que se reconcilia |
//|    con el servidor (posiciones, órdenes, historial) antes de     |
//|    permitir otra entrada.                                        |
//+------------------------------------------------------------------+
#ifndef XAUUSD_EXECUTIONMANAGER_MQH
#define XAUUSD_EXECUTIONMANAGER_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "TradeGateway.mqh"

#define EX_MODULE "ExecutionManager"

struct ExecutionConfig
  {
   long              magic;
   int               max_spread_points;     // spread máximo absoluto para abrir
   int               deviation_points;      // desvío permitido en la ejecución
   int               max_entry_drift_points;// diferencia máxima precio actual vs precio evaluado
   int               max_retries;           // reintentos solo en recotización / precio cambiado
   int               pending_timeout_sec;   // tras este tiempo sin rastro, la solicitud se da por no ejecutada
  };

void ExecutionDefaultConfig(ExecutionConfig &c)
  {
   c.magic = 26101201;
   c.max_spread_points = 60;
   c.deviation_points = 30;
   c.max_entry_drift_points = 50;
   c.max_retries = 2;
   c.pending_timeout_sec = 90;
  }

bool ExecutionValidateConfig(const ExecutionConfig &c, string &reason)
  {
   if(c.magic <= 0)                                    { reason = "magic debe ser > 0"; return false; }
   if(c.max_spread_points <= 0 || c.deviation_points < 0 || c.max_entry_drift_points < 0)
     { reason = "límites de spread/desvío inválidos"; return false; }
   if(c.max_retries < 0 || c.max_retries > 5)          { reason = "max_retries debe estar en [0, 5]"; return false; }
   if(c.pending_timeout_sec < 10)                      { reason = "pending_timeout_sec debe ser >= 10"; return false; }
   reason = "";
   return true;
  }

//--- Clasificación de códigos de retorno del servidor
enum ENUM_RETCODE_CLASS
  {
   RC_SUCCESS = 0,
   RC_RETRYABLE,     // el servidor confirma que NO ejecutó y se puede reintentar con precio nuevo
   RC_UNCERTAIN,     // no se sabe si ejecutó
   RC_REJECTED       // no ejecutó
  };

class CExecutionManager
  {
private:
   ExecutionConfig   m_cfg;
   CTradeGateway    *m_gw;
   CLogger          *m_log;
   bool              m_ready;
   PendingRequest    m_pending;
   string            m_symbol;

   void              LogMsg(const ENUM_LOG_LEVEL l, const string ev, const string msg, const string id = "")
     {
      if(m_log != NULL)
         m_log.Log(l, EX_MODULE, ev, msg, id);
     }

   ENUM_ORDER_TYPE_FILLING Filling(void)
     {
      long f = m_gw.FillingFlags(m_symbol);
      if((f & SYMBOL_FILLING_FOK) != 0)
         return ORDER_FILLING_FOK;
      if((f & SYMBOL_FILLING_IOC) != 0)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }

public:
                     CExecutionManager(void)
     {
      ExecutionDefaultConfig(m_cfg);
      m_gw = NULL;
      m_log = NULL;
      m_ready = false;
      ZeroMemory(m_pending);
      m_pending.active = false;
      m_symbol = "";
     }

   bool              Init(const string symbol, const ExecutionConfig &cfg, CTradeGateway *gw, CLogger *log)
     {
      m_log = log;
      string reason;
      m_ready = false;
      if(gw == NULL)
         reason = "gateway no proporcionado";
      else
         if(ExecutionValidateConfig(cfg, reason))
           {
            m_cfg = cfg;
            m_gw = gw;
            m_symbol = symbol;
            m_ready = true;
            return true;
           }
      if(m_log != NULL) m_log.Critical(EX_MODULE, "CONFIG_INVALID", reason);
      else PrintFormat("[%s] CONFIG_INVALID %s", EX_MODULE, reason);
      return false;
     }

   static ENUM_RETCODE_CLASS Classify(const uint rc, const bool send_ok)
     {
      switch(rc)
        {
         case TRADE_RETCODE_DONE:
         case TRADE_RETCODE_DONE_PARTIAL:
         case TRADE_RETCODE_PLACED:
            return RC_SUCCESS;
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
            return RC_RETRYABLE;
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_CONNECTION:
         case TRADE_RETCODE_ERROR:
            return RC_UNCERTAIN;
         case 0:
            // sin código de retorno: no hay confirmación del servidor
            return RC_UNCERTAIN;
         default:
            return RC_REJECTED;
        }
     }

   //--- Comentario corto y estable para reconciliar (el bróker puede truncarlo: <= 24 caracteres)
   static string     CommentFor(const string signal_id)
     {
      uint h = 2166136261;
      for(int i = 0; i < StringLen(signal_id); i++)
        {
         h ^= (uint)StringGetCharacter(signal_id, i);
         h *= 16777619;
        }
      return StringFormat("XA|%08X", h);
     }

   bool              HasPending(void) const       { return m_pending.active; }
   PendingRequest    Pending(void) const          { return m_pending; }
   void              RestorePending(const PendingRequest &p) { m_pending = p; }

   //--- Ejecuta una decisión aprobada. sig aporta id/clave/estrategia/invalidación para trazabilidad.
   ExecutionResult   Execute(const RiskDecision &d, const TradeSignal &sig, const SymbolSpec &spec)
     {
      ExecutionResult r;
      ZeroMemory(r);
      r.status = EXEC_SKIPPED;
      r.message = "";
      r.comment = "";
      string why;
      if(!m_ready)                        { r.message = "ExecutionManager no inicializado"; return r; }
      if(!d.approved)                     { r.message = "decisión de riesgo no aprobada"; return r; }
      if(m_pending.active)                { r.message = "hay una solicitud pendiente sin reconciliar: " + m_pending.signal_id; return r; }
      if(!m_gw.TradeAllowed(why))         { r.message = why; return r; }
      if(!m_gw.MarketOpen(m_symbol, why)) { r.message = why; return r; }
      if(d.volume < spec.volume_min || d.volume > spec.volume_max)
        { r.message = StringFormat("volumen %.2f fuera de [%.2f, %.2f]", d.volume, spec.volume_min, spec.volume_max); return r; }
      double steps = d.volume / spec.volume_step;
      if(MathAbs(steps - MathRound(steps)) > 1e-6)
        { r.message = StringFormat("volumen %.4f no es múltiplo del paso %.4f", d.volume, spec.volume_step); return r; }

      bool lng = (d.direction == DIR_LONG);
      r.comment = CommentFor(sig.signal_id);
      for(int attempt = 0; attempt <= m_cfg.max_retries; attempt++)
        {
         r.attempts = attempt + 1;
         MqlTick tk;
         if(!m_gw.Tick(m_symbol, tk) || tk.bid <= 0 || tk.ask < tk.bid)
           { r.status = EXEC_SKIPPED; r.message = "sin precio válido"; return r; }
         double spread = (tk.ask - tk.bid) / spec.point;
         if(spread > m_cfg.max_spread_points)
           { r.status = EXEC_SKIPPED; r.message = StringFormat("spread %.0f > máximo %d puntos", spread, m_cfg.max_spread_points); return r; }
         double price = lng ? tk.ask : tk.bid;
         double drift = (price - d.entry) / spec.point * (lng ? 1.0 : -1.0);   // positivo = en contra
         if(drift > m_cfg.max_entry_drift_points)
           { r.status = EXEC_SKIPPED; r.message = StringFormat("precio se alejó %.0f puntos de la evaluación (máx %d)", drift, m_cfg.max_entry_drift_points); return r; }
         double min_dist = spec.stops_level * spec.point;
         if(MathAbs(price - d.sl) < min_dist || MathAbs(d.tp - price) < min_dist ||
            (lng && (d.sl >= tk.bid || d.tp <= price)) || (!lng && (d.sl <= tk.ask || d.tp >= price)))
           { r.status = EXEC_SKIPPED; r.message = "SL/TP inválidos respecto al precio actual o al stops level"; return r; }

         MqlTradeRequest req;
         ZeroMemory(req);
         req.action = TRADE_ACTION_DEAL;
         req.symbol = m_symbol;
         req.volume = d.volume;
         req.type = lng ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         req.price = NormalizeDouble(price, spec.digits);
         req.sl = NormalizeDouble(d.sl, spec.digits);
         req.tp = NormalizeDouble(d.tp, spec.digits);
         req.deviation = (ulong)m_cfg.deviation_points;
         req.magic = (ulong)m_cfg.magic;
         req.comment = r.comment;
         req.type_filling = Filling();
         req.type_time = ORDER_TIME_GTC;
         r.requested_price = req.price;

         MqlTradeCheckResult chk;
         if(!m_gw.Check(req, chk) || (chk.retcode != 0 && chk.retcode != TRADE_RETCODE_DONE))
           {
            r.status = EXEC_REJECTED;
            r.retcode = chk.retcode;
            r.message = StringFormat("OrderCheck rechazó: %u %s", chk.retcode, chk.comment);
            LogMsg(LOG_WARN, "CHECK_REJECTED", r.message, sig.signal_id);
            return r;
           }
         //--- se registra como pendiente ANTES de enviar: si el EA se cae a mitad, se reconcilia al reiniciar
         m_pending.active = true;
         m_pending.signal_id = sig.signal_id;
         m_pending.setup_key = sig.setup_key;
         m_pending.comment = r.comment;
         m_pending.direction = d.direction;
         m_pending.volume = d.volume;
         m_pending.sent_at = m_gw.ServerTime();
         m_pending.strategy = sig.strategy;
         m_pending.initial_sl = d.sl;
         m_pending.invalidation = sig.invalidation;

         MqlTradeResult res;
         bool ok = m_gw.Send(req, res);
         r.retcode = res.retcode;
         ENUM_RETCODE_CLASS cls = Classify(res.retcode, ok);
         if(cls == RC_SUCCESS)
           {
            r.status = EXEC_DONE;
            r.order = res.order;
            r.deal = res.deal;
            r.fill_price = (res.price > 0) ? res.price : req.price;
            r.slippage_points = (r.fill_price - req.price) / spec.point * (lng ? 1.0 : -1.0);
            r.message = StringFormat("ejecutada %s %.2f @ %.*f (solicitado %.*f, slippage %.1f pts) SL %.*f TP %.*f",
                                     (lng ? "BUY" : "SELL"), d.volume, spec.digits, r.fill_price, spec.digits, req.price,
                                     r.slippage_points, spec.digits, req.sl, spec.digits, req.tp);
            // queda pendiente hasta que la posición aparezca (OnTradeTransaction / Reconcile)
            LogMsg(LOG_INFO, "EXECUTED", r.message, sig.signal_id);
            return r;
           }
         if(cls == RC_UNCERTAIN)
           {
            r.status = EXEC_UNCERTAIN;
            r.message = StringFormat("resultado incierto (retcode %u %s): no se reintenta, se reconcilia", res.retcode, res.comment);
            LogMsg(LOG_ERROR, "UNCERTAIN", r.message, sig.signal_id);
            return r;
           }
         //--- el servidor confirma que no ejecutó
         m_pending.active = false;
         if(cls == RC_RETRYABLE && attempt < m_cfg.max_retries)
           {
            LogMsg(LOG_WARN, "RETRY", StringFormat("retcode %u %s, reintento %d", res.retcode, res.comment, attempt + 1), sig.signal_id);
            continue;
           }
         r.status = EXEC_REJECTED;
         r.message = StringFormat("rechazada: retcode %u %s", res.retcode, res.comment);
         LogMsg(LOG_WARN, "REJECTED", r.message, sig.signal_id);
         return r;
        }
      r.status = EXEC_REJECTED;
      r.message = "reintentos agotados";
      return r;
     }

   //--- Reconciliación con el servidor. Devuelve:
   //---  1 = la solicitud pendiente se ejecutó (position_id rellenado),
   //---  0 = se confirmó que no se ejecutó, o no había pendiente,
   //--- -1 = sigue sin resolverse (mantener bloqueadas las entradas).
   int               Reconcile(long &position_id, double &fill_price)
     {
      position_id = 0;
      fill_price = 0;
      if(!m_pending.active)
         return 0;
      PositionInfo pos[];
      int n = m_gw.Positions(m_symbol, m_cfg.magic, pos);
      for(int i = 0; i < n; i++)
        {
         if(pos[i].comment == m_pending.comment)
           {
            position_id = pos[i].identifier;
            fill_price = pos[i].open_price;
            LogMsg(LOG_INFO, "RECONCILED", "posición encontrada para " + m_pending.signal_id, m_pending.signal_id);
            m_pending.active = false;
            return 1;
           }
        }
      //--- respaldo si el bróker alteró el comentario: misma dirección y volumen, abierta tras el envío
      for(int i = 0; i < n; i++)
        {
         if(pos[i].direction == m_pending.direction && MathAbs(pos[i].volume - m_pending.volume) < 1e-8 &&
            pos[i].open_time >= m_pending.sent_at - 5)
           {
            position_id = pos[i].identifier;
            fill_price = pos[i].open_price;
            LogMsg(LOG_WARN, "RECONCILED_BY_MATCH", "posición asociada por dirección/volumen/hora (comentario distinto) a " +
                   m_pending.signal_id, m_pending.signal_id);
            m_pending.active = false;
            return 1;
           }
        }
      if(m_gw.FindEntryDeal(m_symbol, m_cfg.magic, m_pending.comment, m_pending.sent_at - 60, position_id, fill_price))
        {
         LogMsg(LOG_INFO, "RECONCILED", "deal de entrada encontrado en el historial para " + m_pending.signal_id, m_pending.signal_id);
         m_pending.active = false;
         return 1;
        }
      if(m_gw.HasOrderWithComment(m_symbol, m_cfg.magic, m_pending.comment))
         return -1;   // la orden sigue en proceso
      if(m_gw.ServerTime() - m_pending.sent_at >= m_cfg.pending_timeout_sec)
        {
         LogMsg(LOG_WARN, "RECONCILED_NOT_EXECUTED",
                StringFormat("sin rastro de %s tras %d s: se da por no ejecutada", m_pending.signal_id, m_cfg.pending_timeout_sec),
                m_pending.signal_id);
         m_pending.active = false;
         return 0;
        }
      return -1;
     }
  };

#endif // XAUUSD_EXECUTIONMANAGER_MQH
