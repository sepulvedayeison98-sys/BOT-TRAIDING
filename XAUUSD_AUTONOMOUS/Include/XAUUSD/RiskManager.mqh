//+------------------------------------------------------------------+
//| RiskManager.mqh                                                  |
//| Control de riesgo previo a TODA ejecución. Ver                   |
//| Documentation/RISK_MANAGEMENT.md.                                |
//|                                                                  |
//| - Volumen: pérdida al SL medida con OrderCalcProfit (verificada  |
//|   contra tick size/tick value), costos incluidos, redondeo       |
//|   SIEMPRE hacia abajo; si no alcanza el lote mínimo se rechaza.  |
//| - Margen con OrderCalcMargin.                                    |
//| - Exposición agregada = riesgo restante de posiciones propias +  |
//|   riesgo nuevo.                                                  |
//| - Pérdida diaria = Equity - Equity al reset - depósitos netos;   |
//|   chequeo de peor caso (pérdida actual + exposición).            |
//| - Sin martingala, grids ni promedios: el riesgo es fijo y solo   |
//|   puede REDUCIRSE tras rachas de pérdidas (opcional).            |
//| - Los parámetros de este módulo nunca los modifica el            |
//|   LearningEngine.                                                |
//+------------------------------------------------------------------+
#ifndef XAUUSD_RISKMANAGER_MQH
#define XAUUSD_RISKMANAGER_MQH

#include "Types.mqh"
#include "Logger.mqh"

#define RM_MODULE "RiskManager"

//--- Límites duros aprobados (RISK_MANAGEMENT.md §1). El EA no arranca si se superan.
#define RM_HARD_MAX_RISK_PCT        2.0
#define RM_HARD_MAX_EXPOSURE_PCT    5.0
#define RM_HARD_MAX_POSITIONS       5
#define RM_HARD_MAX_DAILY_LOSS_PCT  6.0
#define RM_HARD_MIN_RR              1.0

//+------------------------------------------------------------------+
//| Cálculo monetario (abstracto para poder probarlo sin terminal)   |
//+------------------------------------------------------------------+
class CTradeCalculator
  {
public:
   virtual          ~CTradeCalculator(void) {}
   //--- pérdida (positiva, en moneda de la cuenta) si la posición va de entry a sl
   virtual bool      Loss(const ENUM_DIRECTION dir, const double volume, const double entry, const double sl,
                          double &loss) = 0;
   virtual bool      Margin(const ENUM_DIRECTION dir, const double volume, const double price, double &margin) = 0;
  };

//--- Implementación real con las funciones de MT5
class CTerminalCalculator : public CTradeCalculator
  {
private:
   string            m_symbol;
public:
                     CTerminalCalculator(const string symbol) { m_symbol = symbol; }
   virtual bool      Loss(const ENUM_DIRECTION dir, const double volume, const double entry, const double sl,
                          double &loss)
     {
      double profit = 0.0;
      ENUM_ORDER_TYPE t = (dir == DIR_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ResetLastError();
      if(!OrderCalcProfit(t, m_symbol, volume, entry, sl, profit))
         return false;
      loss = -profit;
      return true;
     }
   virtual bool      Margin(const ENUM_DIRECTION dir, const double volume, const double price, double &margin)
     {
      ENUM_ORDER_TYPE t = (dir == DIR_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ResetLastError();
      return OrderCalcMargin(t, m_symbol, volume, price, margin);
     }
  };

//--- Lee la especificación real del símbolo
bool SymbolSpecLoad(const string symbol, SymbolSpec &s, string &reason)
  {
   s.name = symbol;
   s.digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   s.point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   s.tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   s.tick_value_loss = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   s.contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   s.volume_min = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   s.volume_max = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   s.volume_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   s.volume_limit = SymbolInfoDouble(symbol, SYMBOL_VOLUME_LIMIT);
   s.stops_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   s.freeze_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(s.point <= 0 || s.tick_size <= 0 || s.tick_value_loss <= 0 || s.volume_min <= 0 ||
      s.volume_step <= 0 || s.volume_max < s.volume_min)
     {
      reason = StringFormat("especificación inválida: point=%g tick_size=%g tick_value_loss=%g vmin=%g step=%g vmax=%g",
                            s.point, s.tick_size, s.tick_value_loss, s.volume_min, s.volume_step, s.volume_max);
      return false;
     }
   reason = "";
   return true;
  }

//--- ¿Cambió algo que afecte al cálculo de riesgo? (protección ante cambios de símbolo)
bool SymbolSpecChanged(const SymbolSpec &a, const SymbolSpec &b)
  {
   return a.digits != b.digits || a.point != b.point || a.tick_size != b.tick_size ||
          a.contract_size != b.contract_size || a.volume_min != b.volume_min ||
          a.volume_step != b.volume_step || a.volume_max != b.volume_max;
  }

//+------------------------------------------------------------------+
//| Configuración                                                    |
//+------------------------------------------------------------------+
struct RiskConfig
  {
   double            risk_pct;                 // riesgo por operación (% de min(balance, equity))
   double            max_exposure_pct;         // exposición agregada máxima
   int               max_positions;            // posiciones simultáneas (Hedging)
   double            daily_loss_pct;           // pérdida diaria máxima (% de la equity al reset)
   double            min_rr;                   // relación riesgo-beneficio mínima
   double            commission_per_lot;       // comisión ida y vuelta por lote (moneda de la cuenta)
   double            slippage_points;          // colchón de slippage al SL (puntos)
   double            sell_spread_factor;       // spread esperado al ejecutarse el SL de una venta (x spread actual)
   double            min_margin_level_pct;     // nivel de margen mínimo tras abrir
   double            free_margin_reserve_pct;  // margen libre que debe quedar (% de la equity)
   double            crosscheck_tolerance;     // diferencia máxima OrderCalcProfit vs tick value (fracción)
   int               reduce_after_losses;      // 0 = desactivado; N pérdidas seguidas -> reducir riesgo
   double            reduction_factor;         // factor de reducción (0, 1)
   bool              worst_case_daily_check;   // pérdida del día + exposición <= límite diario
  };

void RiskDefaultConfig(RiskConfig &c)
  {
   c.risk_pct = 1.0;
   c.max_exposure_pct = 2.0;
   c.max_positions = 3;
   c.daily_loss_pct = 3.0;
   c.min_rr = 2.0;
   c.commission_per_lot = 0.0;
   c.slippage_points = 0.0;
   c.sell_spread_factor = 1.0;
   c.min_margin_level_pct = 300.0;
   c.free_margin_reserve_pct = 10.0;
   c.crosscheck_tolerance = 0.05;
   c.reduce_after_losses = 0;
   c.reduction_factor = 0.5;
   c.worst_case_daily_check = true;
  }

bool RiskValidateConfig(const RiskConfig &c, string &reason)
  {
   if(c.risk_pct <= 0.0 || c.risk_pct > RM_HARD_MAX_RISK_PCT)
     { reason = StringFormat("riesgo por operación %.2f%% fuera de (0, %.1f%%]", c.risk_pct, RM_HARD_MAX_RISK_PCT); return false; }
   if(c.max_exposure_pct < c.risk_pct || c.max_exposure_pct > RM_HARD_MAX_EXPOSURE_PCT)
     { reason = StringFormat("exposición máxima %.2f%% fuera de [riesgo, %.1f%%]", c.max_exposure_pct, RM_HARD_MAX_EXPOSURE_PCT); return false; }
   if(c.max_positions < 1 || c.max_positions > RM_HARD_MAX_POSITIONS)
     { reason = StringFormat("posiciones simultáneas %d fuera de [1, %d]", c.max_positions, RM_HARD_MAX_POSITIONS); return false; }
   if(c.daily_loss_pct < c.risk_pct || c.daily_loss_pct > RM_HARD_MAX_DAILY_LOSS_PCT)
     { reason = StringFormat("pérdida diaria %.2f%% fuera de [riesgo, %.1f%%]", c.daily_loss_pct, RM_HARD_MAX_DAILY_LOSS_PCT); return false; }
   if(c.min_rr < RM_HARD_MIN_RR)
     { reason = StringFormat("R:R mínimo %.2f < %.1f", c.min_rr, RM_HARD_MIN_RR); return false; }
   if(c.commission_per_lot < 0.0 || c.slippage_points < 0.0 || c.sell_spread_factor < 1.0)
     { reason = "costos inválidos (comisión y slippage >= 0, factor de spread >= 1)"; return false; }
   if(c.min_margin_level_pct < 100.0 || c.free_margin_reserve_pct < 0.0 || c.free_margin_reserve_pct >= 100.0)
     { reason = "parámetros de margen inválidos"; return false; }
   if(c.crosscheck_tolerance <= 0.0 || c.crosscheck_tolerance > 0.2)
     { reason = "tolerancia de verificación cruzada fuera de (0, 0.2]"; return false; }
   if(c.reduce_after_losses < 0 || c.reduction_factor <= 0.0 || c.reduction_factor >= 1.0)
     { reason = "reducción tras pérdidas inválida (factor en (0,1))"; return false; }
   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Seguimiento de la pérdida diaria                                 |
//| Base E0 = Equity al reset (hora del servidor). PnL del día =     |
//| Equity - E0 - depósitos netos del día. Incluye realizado,        |
//| flotante, comisiones y swaps. El bloqueo se mantiene hasta el    |
//| siguiente reset.                                                 |
//+------------------------------------------------------------------+
class CDailyLossTracker
  {
private:
   int               m_reset_hour;
   double            m_limit_pct;
   datetime          m_day_start;
   double            m_e0;
   double            m_net_deposits;
   bool              m_limit_hit;
   bool              m_reconstructed;

public:
                     CDailyLossTracker(void)
     {
      m_reset_hour = 0;
      m_limit_pct = 3.0;
      m_day_start = 0;
      m_e0 = 0.0;
      m_net_deposits = 0.0;
      m_limit_hit = false;
      m_reconstructed = false;
     }

   void              Configure(const int reset_hour, const double limit_pct)
     {
      m_reset_hour = MathMax(0, MathMin(23, reset_hour));
      m_limit_pct = limit_pct;
     }

   //--- Inicio del día de trading que contiene server_time
   datetime          DayStartFor(const datetime server_time) const
     {
      datetime shifted = server_time - (datetime)m_reset_hour * 3600;
      return (shifted - (shifted % 86400)) + (datetime)m_reset_hour * 3600;
     }

   //--- Devuelve true si se produjo un reset (nuevo día).
   bool              Update(const datetime server_time, const double equity)
     {
      datetime ds = DayStartFor(server_time);
      if(ds == m_day_start && m_e0 > 0.0)
         return false;
      m_day_start = ds;
      m_e0 = equity;
      m_net_deposits = 0.0;
      m_limit_hit = false;
      m_reconstructed = false;
      return true;
     }

   //--- Restaura el estado persistido si corresponde al día en curso.
   bool              Restore(const datetime server_time, const datetime day_start, const double e0,
                             const double net_deposits, const bool limit_hit)
     {
      if(day_start != DayStartFor(server_time) || e0 <= 0.0)
         return false;
      m_day_start = day_start;
      m_e0 = e0;
      m_net_deposits = net_deposits;
      m_limit_hit = limit_hit;
      m_reconstructed = false;
      return true;
     }

   //--- Sin snapshot del día: E0 = balance actual - PnL realizado hoy (aproximación documentada)
   void              Reconstruct(const datetime server_time, const double balance, const double realized_today,
                                 const double net_deposits_today)
     {
      m_day_start = DayStartFor(server_time);
      m_e0 = balance - realized_today - net_deposits_today;
      m_net_deposits = net_deposits_today;
      m_limit_hit = false;
      m_reconstructed = true;
     }

   void              AddBalanceOperation(const double amount) { m_net_deposits += amount; }

   double            PnL(const double equity) const   { return equity - m_e0 - m_net_deposits; }
   double            LossPct(const double equity) const
     {
      if(m_e0 <= 0.0)
         return 0.0;
      return MathMax(0.0, -PnL(equity)) / m_e0 * 100.0;
     }
   double            GainPct(const double equity) const
     {
      if(m_e0 <= 0.0)
         return 0.0;
      return MathMax(0.0, PnL(equity)) / m_e0 * 100.0;
     }

   //--- Evalúa y "engancha" el límite hasta el próximo reset
   bool              LimitReached(const double equity)
     {
      if(!m_limit_hit && LossPct(equity) >= m_limit_pct)
         m_limit_hit = true;
      return m_limit_hit;
     }

   bool              LimitHit(void) const       { return m_limit_hit; }
   datetime          DayStart(void) const       { return m_day_start; }
   double            E0(void) const             { return m_e0; }
   double            NetDeposits(void) const    { return m_net_deposits; }
   bool              Reconstructed(void) const  { return m_reconstructed; }
   double            LimitPct(void) const       { return m_limit_pct; }
  };

//+------------------------------------------------------------------+
//| RiskManager                                                      |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   RiskConfig        m_cfg;
   CTradeCalculator *m_calc;
   CLogger          *m_log;
   bool              m_ready;

   bool              Reject(RiskDecision &d, const string why, const bool critical = false)
     {
      d.approved = false;
      d.critical = critical;
      d.reject_reason = why;
      if(m_log != NULL)
         m_log.Log(critical ? LOG_CRITICAL : LOG_INFO, RM_MODULE, critical ? "REJECT_CRITICAL" : "REJECT", why);
      return false;
     }

public:
                     CRiskManager(void) { RiskDefaultConfig(m_cfg); m_calc = NULL; m_log = NULL; m_ready = false; }

   bool              Init(const RiskConfig &cfg, CTradeCalculator *calc, CLogger *log)
     {
      m_log = log;
      string reason;
      m_ready = false;
      if(calc == NULL)
         reason = "calculadora no proporcionada";
      else
         if(RiskValidateConfig(cfg, reason))
           {
            m_cfg = cfg;
            m_calc = calc;
            m_ready = true;
            return true;
           }
      if(m_log != NULL) m_log.Critical(RM_MODULE, "CONFIG_INVALID", reason);
      else PrintFormat("[%s] CONFIG_INVALID %s", RM_MODULE, reason);
      return false;
     }

   RiskConfig        Config(void) const { return m_cfg; }

   //--- Base de riesgo: el menor entre balance y equity (conservador)
   static double     RiskBase(const AccountSnapshot &a) { return MathMin(a.balance, a.equity); }

   //--- Riesgo vigente: fijo; opcionalmente reducido tras N pérdidas seguidas. Nunca aumenta.
   double            EffectiveRiskPct(const int consecutive_losses) const
     {
      if(m_cfg.reduce_after_losses > 0 && consecutive_losses >= m_cfg.reduce_after_losses)
         return m_cfg.risk_pct * m_cfg.reduction_factor;
      return m_cfg.risk_pct;
     }

   //--- Riesgo restante de las posiciones propias. false si alguna no tiene SL (crítico).
   bool              ExistingExposure(const PositionRisk &pos[], double &money, string &why)
     {
      money = 0.0;
      for(int i = 0; i < ArraySize(pos); i++)
        {
         if(pos[i].sl <= 0.0)
           {
            why = "posición " + IntegerToString((long)pos[i].ticket) + " sin Stop Loss";
            return false;
           }
         double loss = 0.0;
         if(!m_calc.Loss(pos[i].direction, pos[i].volume, pos[i].open_price, pos[i].sl, loss))
           {
            why = "no se pudo calcular el riesgo de la posición " + IntegerToString((long)pos[i].ticket);
            return false;
           }
         money += MathMax(0.0, loss);   // SL en break-even o en beneficio = 0
        }
      why = "";
      return true;
     }

   //--- Evaluación completa de una propuesta.
   //--- spread_points: spread actual del símbolo; consecutive_losses: racha de pérdidas cerradas.
   RiskDecision      Assess(const TradeSignal &sig, const SymbolSpec &spec, const AccountSnapshot &acc,
                            const PositionRisk &positions[], CDailyLossTracker &daily, const double spread_points,
                            const int consecutive_losses)
     {
      RiskDecision d;
      ZeroMemory(d);
      d.approved = false;
      d.direction = sig.direction;
      d.entry = sig.entry_price;
      d.sl = sig.sl;
      d.tp = sig.tp;
      d.reject_reason = "";
      d.detail = "";
      if(!m_ready)
        { Reject(d, "RiskManager no inicializado", true); return d; }
      bool lng = (sig.direction == DIR_LONG);
      if(sig.direction != DIR_LONG && sig.direction != DIR_SHORT)
        { Reject(d, "dirección inválida"); return d; }
      if((lng && !(sig.sl < sig.entry_price && sig.entry_price < sig.tp)) ||
         (!lng && !(sig.tp < sig.entry_price && sig.entry_price < sig.sl)))
        { Reject(d, "precios de entrada/SL/TP incoherentes"); return d; }
      if(acc.equity <= 0.0 || acc.balance <= 0.0)
        { Reject(d, "cuenta sin balance/equity", true); return d; }

      //--- límite diario
      //--- el EA mantiene el seguimiento diario (Update en cada temporizador)
      if(daily.E0() <= 0.0)
        { Reject(d, "seguimiento de pérdida diaria sin inicializar"); return d; }
      d.daily_loss_pct = daily.LossPct(acc.equity);
      if(daily.LimitReached(acc.equity))
        { Reject(d, StringFormat("límite de pérdida diaria alcanzado (%.2f%% >= %.2f%%)", d.daily_loss_pct, daily.LimitPct())); return d; }

      //--- R:R
      double sl_dist = MathAbs(sig.entry_price - sig.sl);
      d.rr = MathAbs(sig.tp - sig.entry_price) / sl_dist;
      if(d.rr < m_cfg.min_rr - 1e-9)
        { Reject(d, StringFormat("R:R %.2f < mínimo %.2f", d.rr, m_cfg.min_rr)); return d; }

      //--- distancias mínimas del bróker
      double min_dist = spec.stops_level * spec.point;
      if(sl_dist < min_dist + spread_points * spec.point || MathAbs(sig.tp - sig.entry_price) < min_dist)
        { Reject(d, StringFormat("SL/TP más cerca que el stops level (%d puntos + spread)", spec.stops_level)); return d; }

      //--- número de posiciones / modo de cuenta
      int npos = ArraySize(positions);
      if(acc.netting && npos > 0)
        { Reject(d, "cuenta Netting con posición abierta: no se añade ni se invierte (evita promediar)"); return d; }
      if(npos >= m_cfg.max_positions)
        { Reject(d, StringFormat("máximo de posiciones simultáneas alcanzado (%d)", m_cfg.max_positions)); return d; }

      //--- exposición existente
      double base = RiskBase(acc);
      double existing = 0.0;
      string why;
      if(!ExistingExposure(positions, existing, why))
        { Reject(d, why, true); return d; }
      d.exposure_before_pct = existing / base * 100.0;

      //--- pérdida por lote con verificación cruzada
      double loss1 = 0.0;
      if(!m_calc.Loss(sig.direction, 1.0, sig.entry_price, sig.sl, loss1) || loss1 <= 0.0)
        { Reject(d, "OrderCalcProfit falló o devolvió pérdida no positiva"); return d; }
      double loss_ticks = sl_dist / spec.tick_size * spec.tick_value_loss;
      if(loss_ticks <= 0.0 || MathAbs(loss1 - loss_ticks) / loss_ticks > m_cfg.crosscheck_tolerance)
        { Reject(d, StringFormat("verificación cruzada falló: OrderCalcProfit %.2f vs tick value %.2f", loss1, loss_ticks), true); return d; }
      double money_per_point = spec.point / spec.tick_size * spec.tick_value_loss;   // por lote
      double cost1 = m_cfg.commission_per_lot + m_cfg.slippage_points * money_per_point;
      if(!lng)
         cost1 += spread_points * m_cfg.sell_spread_factor * money_per_point;   // el SL de una venta se ejecuta al ask
      double per_lot = loss1 + cost1;

      //--- volumen
      double risk_pct = EffectiveRiskPct(consecutive_losses);
      double target = base * risk_pct / 100.0;
      double step = spec.volume_step;
      double vol = MathFloor(target / per_lot / step + 1e-9) * step;
      double vmax = spec.volume_max;
      if(spec.volume_limit > 0.0)
         vmax = MathMin(vmax, spec.volume_limit);
      vol = MathMin(vol, vmax);
      vol = NormalizeDouble(vol, 8);
      if(vol < spec.volume_min - 1e-12)
        { Reject(d, StringFormat("volumen %.4f < mínimo %.4f: el riesgo superaría el %.2f%% (no se redondea hacia arriba)", target / per_lot, spec.volume_min, risk_pct)); return d; }
      double loss_vol = 0.0;
      if(!m_calc.Loss(sig.direction, vol, sig.entry_price, sig.sl, loss_vol))
        { Reject(d, "OrderCalcProfit falló con el volumen final"); return d; }
      d.volume = vol;
      d.risk_money = loss_vol + cost1 * vol;
      d.risk_pct = d.risk_money / base * 100.0;
      if(d.risk_money > target + 1e-6)
        { Reject(d, StringFormat("riesgo final %.2f > objetivo %.2f", d.risk_money, target)); return d; }

      //--- exposición agregada
      d.exposure_after_pct = (existing + d.risk_money) / base * 100.0;
      if(d.exposure_after_pct > m_cfg.max_exposure_pct + 1e-9)
        { Reject(d, StringFormat("exposición %.2f%% > máximo %.2f%%", d.exposure_after_pct, m_cfg.max_exposure_pct)); return d; }

      //--- peor caso del día
      if(m_cfg.worst_case_daily_check)
        {
         double worst = d.daily_loss_pct + (existing + d.risk_money) / daily.E0() * 100.0;
         if(worst > daily.LimitPct() + 1e-9)
           { Reject(d, StringFormat("peor caso del día %.2f%% > límite %.2f%%", worst, daily.LimitPct())); return d; }
        }

      //--- margen
      double margin = 0.0;
      if(!m_calc.Margin(sig.direction, vol, sig.entry_price, margin) || margin < 0.0)
        { Reject(d, "OrderCalcMargin falló"); return d; }
      d.margin_required = margin;
      if(acc.free_margin - margin < acc.equity * m_cfg.free_margin_reserve_pct / 100.0)
        { Reject(d, StringFormat("margen insuficiente: libre %.2f, requerido %.2f, reserva %.0f%%", acc.free_margin, margin, m_cfg.free_margin_reserve_pct)); return d; }
      double used = acc.margin + margin;
      if(used > 0.0 && acc.equity / used * 100.0 < m_cfg.min_margin_level_pct)
        { Reject(d, StringFormat("nivel de margen tras abrir %.0f%% < %.0f%%", acc.equity / used * 100.0, m_cfg.min_margin_level_pct)); return d; }

      d.approved = true;
      d.detail = StringFormat("vol=%.2f riesgo=%.2f (%.2f%%) R:R=%.2f margen=%.2f exposición %.2f%% -> %.2f%% día %.2f%%",
                              d.volume, d.risk_money, d.risk_pct, d.rr, d.margin_required,
                              d.exposure_before_pct, d.exposure_after_pct, d.daily_loss_pct);
      if(m_log != NULL)
         m_log.Info(RM_MODULE, "APPROVED", d.detail, sig.signal_id);
      return d;
     }

   //--- Protección de cuenta real: solo con autorización explícita y frase de confirmación.
   static bool       AccountAllowed(const ENUM_ACCOUNT_TRADE_MODE mode, const bool allow_real,
                                    const string confirmation, string &why)
     {
      if(mode == ACCOUNT_TRADE_MODE_DEMO)
        { why = ""; return true; }
      if(!allow_real)
        { why = "cuenta no demo y trading real no autorizado (InpAllowRealAccount=false)"; return false; }
      if(confirmation != "I UNDERSTAND THE RISK")
        { why = "falta la frase de confirmación exacta para cuenta real"; return false; }
      why = "";
      return true;
     }
  };

#endif // XAUUSD_RISKMANAGER_MQH
