//+------------------------------------------------------------------+
//| XAUUSD_Autonomous.mq5                                            |
//| Expert Advisor autónomo e intradía para XAUUSD (H1/M15/M5),      |
//| sesiones de Londres y Nueva York. Ver Documentation/.            |
//|                                                                  |
//| Flujo en cada vela M5 cerrada:                                   |
//|  MarketEngine -> RegimeEngine -> estrategias (SMC, Breakout,     |
//|  Reversal) -> AdaptiveEngine -> gates -> RiskManager ->          |
//|  ExecutionManager. PositionManager gestiona en cada tick.        |
//|                                                                  |
//| Seguridad:                                                       |
//|  - Trading real DESHABILITADO por defecto (doble confirmación).  |
//|  - Ante errores críticos: modo seguro (sin entradas nuevas, con  |
//|    gestión protectora). La salida del modo seguro es manual.     |
//|  - El estado se reconstruye desde el servidor tras reiniciar.    |
//|  - No promete rentabilidad: validar en backtest y demo.          |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Autonomous Trading System"
#property version   "1.11"
#property strict
#property description "EA autónomo para XAUUSD con gestión estricta de riesgo. Trading real deshabilitado por defecto."

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include <XAUUSD/RegimeEngine.mqh>
#include <XAUUSD/StrategySMC.mqh>
#include <XAUUSD/StrategyBreakout.mqh>
#include <XAUUSD/StrategyReversal.mqh>
#include <XAUUSD/AdaptiveEngine.mqh>
#include <XAUUSD/RiskManager.mqh>
#include <XAUUSD/StateStore.mqh>
#include <XAUUSD/TradeGateway.mqh>
#include <XAUUSD/ExecutionManager.mqh>
#include <XAUUSD/PositionManager.mqh>
#include <XAUUSD/NewsManager.mqh>
#include <XAUUSD/LearningEngine.mqh>
#include <XAUUSD/Dashboard.mqh>
#include <XAUUSD/WebDashboard.mqh>

//+------------------------------------------------------------------+
//| Parámetros                                                       |
//+------------------------------------------------------------------+
input group "General"
input long           InpMagic                 = 26101201;   // Número mágico
input string         InpRunTag                = "live";     // Etiqueta de corrida (diario / Challenger)
input bool           InpAllowRealAccount      = false;      // Permitir cuenta real (NO recomendado)
input string         InpRealAccountConfirmation = "";       // Frase exacta: I UNDERSTAND THE RISK
input bool           InpAllowAnySymbol        = false;      // Permitir símbolos distintos de XAUUSD (solo pruebas)
input string         InpSymbolOverride        = "";         // Operar otro símbolo que el del gráfico (solo pruebas, requiere AllowAnySymbol)
input bool           InpUseChampion           = true;       // Cargar modelo Champion aprobado si existe
input bool           InpShowDashboard         = true;
input ENUM_LOG_LEVEL InpPrintLevel            = LOG_INFO;

input group "Riesgo (límites duros: riesgo<=2%, exposición<=5%, diario<=6%, R:R>=1)"
input double         InpRiskPct               = 1.0;        // Riesgo por operación (%)
input double         InpMaxExposurePct        = 2.0;        // Exposición agregada máxima (%)
input int            InpMaxPositions          = 3;          // Posiciones simultáneas (Hedging)
input double         InpDailyLossPct          = 3.0;        // Pérdida diaria máxima (%)
input int            InpDailyResetHour        = 0;          // Hora de reset diario (hora servidor)
input ENUM_DAILY_LOSS_SCOPE InpDailyLossScope = DAILY_SCOPE_EA; // Pérdida diaria: solo operaciones del EA / toda la cuenta
input double         InpMinRR                 = 2.0;        // R:R mínimo
input double         InpCommissionPerLot      = 0.0;        // Comisión ida y vuelta por lote (moneda cuenta)
input double         InpSlippagePoints        = 0.0;        // Colchón de slippage al SL (puntos)
input int            InpReduceAfterLosses     = 0;          // Reducir riesgo tras N pérdidas (0 = no)
input double         InpReductionFactor       = 0.5;        // Factor de reducción (solo reduce)

input group "Gestión de posiciones"
input double         InpBreakEvenR            = 1.0;
input int            InpBreakEvenOffsetPts    = 10;
input double         InpTrailStartR           = 1.5;
input int            InpTrailMode             = 0;          // 0 = ATR M5, 1 = pivote M5
input double         InpTrailAtrMult          = 1.5;
input bool           InpCloseOnInvalidation   = true;
input int            InpManageThrottleMs      = 250;        // gestión protectora como máximo cada N ms

input group "Ejecución"
input int            InpMaxSpreadPoints       = 60;
input int            InpDeviationPoints       = 30;
input int            InpMaxEntryDriftPoints   = 50;
input int            InpMaxRetries            = 2;

input group "Sesiones (hora local de cada plaza) y hora del servidor en tester"
input int            InpLondonOpenMin         = 480;
input int            InpLondonCloseMin        = 990;
input int            InpNewYorkOpenMin        = 480;
input int            InpNewYorkCloseMin       = 1020;
input int            InpTesterGmtOffsetMin    = 0;
input ENUM_DST_RULE  InpTesterDstRule         = DST_RULE_NONE;

input group "Noticias"
input int            InpMajorNewsBeforeMin    = 30;
input int            InpMajorNewsAfterMin     = 30;
input int            InpUsdNewsBeforeMin      = 20;
input int            InpUsdNewsAfterMin       = 20;
input bool           InpBlockIfNewsUnverified = true;       // D3: bloquear si el calendario no es verificable

input group "Estrategias y puntuación"
input bool           InpEnableSMC             = true;
input bool           InpEnableBreakout        = true;
input bool           InpEnableReversal        = true;
input double         InpMinScore              = 65.0;
input double         InpHighScore             = 80.0;

input group "Régimen (hipótesis a calibrar)"
input double         InpTrendAdxMin           = 22.0;
input double         InpRangeAdxMax           = 18.0;
input double         InpHighVolH1Ratio        = 1.8;
input double         InpHighVolM15Ratio       = 2.2;

input group "Dashboard web (opcional, ver WebDashboard/README.md)"
input bool           InpWebEnabled            = false;      // Enviar telemetría y aceptar PAUSE/RESUME/SAFE_MODE
input string         InpWebUrl                = "";         // https://tu-dominio (añadirla en Opciones > Asesores Expertos > WebRequest)
input string         InpWebToken              = "";         // Token del dashboard (>= 32 caracteres; NO es la contraseña de la cuenta)
input int            InpWebIntervalSec        = 30;         // Ciclo de telemetría/comandos (10-600 s)

//+------------------------------------------------------------------+
//| Módulos y estado                                                 |
//+------------------------------------------------------------------+
CLogger              g_log;
CSessionClock        g_clock;
CMarketEngine        g_market;
CRegimeEngine        g_regime;
CStrategySMC         g_smc;
CStrategyBreakout    g_bo;
CStrategyReversal    g_rv;
CAdaptiveEngine      g_adaptive;
CTerminalCalculator *g_calc = NULL;
CRiskManager         g_risk;
CDailyLossTracker    g_daily;
CTerminalGateway     g_gateway;
CExecutionManager    g_exec;
CPositionManager     g_pos;
CNewsManager         g_news;
CLearningEngine      g_learn;
CStateStore          g_store;
CDashboard           g_dash;
CWebDashboard        g_web;

string               g_symbol = "";
ENUM_EA_STATE        g_state = EA_INIT;
string               g_state_reason = "";
bool                 g_account_ok = false;
string               g_account_reason = "";
bool                 g_netting = false;
bool                 g_tester = false;
bool                 g_dash_on = false;
bool                 g_smc_on = true, g_bo_on = true, g_rv_on = true;
SymbolSpec           g_spec;
MarketSnapshot       g_snap;
bool                 g_snap_valid = false;
RegimeState          g_regime_state;
NewsState            g_news_state;
TradeProposal        g_last_proposal;
string               g_last_signal_text = "—";
string               g_last_trade_text = "—";
string               g_blocks = "—";
ulong                g_last_manage_ms = 0;
datetime             g_last_save = 0;
datetime             g_last_spec_check = 0;
datetime             g_last_clock_refresh = 0;
double               g_peak_equity = 0.0;
bool                 g_dirty = false;
//--- contexto de la entrada pendiente (para el diario al confirmarse la posición)
bool                 g_ctx_active = false;
TradeSignal          g_ctx_signal;
RiskDecision         g_ctx_risk;
ExecutionResult      g_ctx_exec;
double               g_ctx_score = 0.0;
ENUM_REGIME          g_ctx_regime = REGIME_NO_TRADE;
ENUM_SESSION_ID      g_ctx_session = SESSION_NONE;
double               g_ctx_spread = 0.0;

//+------------------------------------------------------------------+
//| Utilidades                                                       |
//+------------------------------------------------------------------+
void SetState(const ENUM_EA_STATE s, const string why)
  {
   if(s == g_state && why == g_state_reason)
      return;
   g_log.Log(s == EA_SAFE_MODE || s == EA_HALTED ? LOG_CRITICAL : LOG_INFO, "EA", "STATE",
             StringFormat("%s -> %s: %s", EnumEAStateToString(g_state), EnumEAStateToString(s), why));
   g_state = s;
   g_state_reason = why;
   g_dirty = true;
  }

void EnterSafeMode(const string why)
  {
   if(g_state == EA_HALTED)
      return;
   SetState(EA_SAFE_MODE, why);
  }

AccountSnapshot Account(void)
  {
   AccountSnapshot a;
   a.balance = AccountInfoDouble(ACCOUNT_BALANCE);
   a.equity = AccountInfoDouble(ACCOUNT_EQUITY);
   a.margin = AccountInfoDouble(ACCOUNT_MARGIN);
   a.free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   a.currency = AccountInfoString(ACCOUNT_CURRENCY);
   a.netting = g_netting;
   return a;
  }

//--- PnL realizado y depósitos netos de la cuenta desde `from` (todas las operaciones)
void AccountDayFlows(const datetime from, double &realized, double &deposits)
  {
   realized = 0.0;
   deposits = 0.0;
   if(!HistorySelect(from, TimeTradeServer() + 60))
      return;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      ENUM_DEAL_TYPE t = (ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE);
      double v = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_SWAP);
      if(t == DEAL_TYPE_BUY || t == DEAL_TYPE_SELL)
         realized += v;
      else
         if(t == DEAL_TYPE_BALANCE)
            deposits += v;
         else
            realized += v;   // créditos, cargos, comisiones de cuenta: afectan a la equity del día
     }
  }

//--- PnL propio del día (magic + símbolo): realizado desde `from` (beneficio, comisión y swap de
//--- cada deal) + flotante de las posiciones propias abiertas (beneficio + swap).
double OwnDayPnL(const datetime from)
  {
   double pnl = 0.0;
   if(HistorySelect(from, TimeTradeServer() + 60))
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0 || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic || HistoryDealGetString(d, DEAL_SYMBOL) != g_symbol)
            continue;
         pnl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_SWAP);
        }
   PositionInfo pos[];
   int n = g_gateway.Positions(g_symbol, InpMagic, pos);
   for(int i = 0; i < n; i++)
      pnl += pos[i].profit;
   return pnl;
  }

//--- Con alcance EA, actualiza el PnL propio del día antes de evaluar la pérdida diaria
void RefreshDailyOwnPnL(void)
  {
   if(g_daily.Scope() == DAILY_SCOPE_EA && g_daily.DayStart() > 0)
      g_daily.SetOwnPnL(OwnDayPnL(g_daily.DayStart()));
  }

//--- Operación cerrada de una posición a partir de su historial
bool ClosedTradeFor(const long position_id, ClosedTrade &c)
  {
   ZeroMemory(c);
   c.identifier = position_id;
   c.comment = "";
   if(!HistorySelectByPosition(position_id))
      return false;
   bool has_in = false, has_out = false;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      c.commission += HistoryDealGetDouble(d, DEAL_COMMISSION);
      c.swap += HistoryDealGetDouble(d, DEAL_SWAP);
      c.profit += HistoryDealGetDouble(d, DEAL_PROFIT);
      if(e == DEAL_ENTRY_IN)
        {
         has_in = true;
         c.direction = ((ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
         c.volume = HistoryDealGetDouble(d, DEAL_VOLUME);
         c.entry_price = HistoryDealGetDouble(d, DEAL_PRICE);
         c.open_time = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         c.comment = HistoryDealGetString(d, DEAL_COMMENT);
        }
      else
        {
         has_out = true;
         c.exit_price = HistoryDealGetDouble(d, DEAL_PRICE);
         c.close_time = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
        }
     }
   return has_in && has_out;
  }

//+------------------------------------------------------------------+
//| Persistencia                                                     |
//+------------------------------------------------------------------+
string StateFile(void) { return StringFormat("XAUUSD/state_%s_%s.dat", g_symbol, IntegerToString(InpMagic)); }

void SaveState(void)
  {
   g_store.Clear();
   g_store.Set("version", XAU_PROJECT_VERSION);
   // solo se persisten los estados elegidos por el usuario o de seguridad
   string st = (g_state == EA_PAUSED || g_state == EA_SAFE_MODE) ? EnumEAStateToString(g_state) : "RUNNING";
   g_store.Set("ea.state", st);
   g_store.Set("ea.reason", g_state_reason);
   g_store.SetLong("daily.start", (long)g_daily.DayStart());
   g_store.SetDouble("daily.e0", g_daily.E0());
   g_store.SetDouble("daily.deposits", g_daily.NetDeposits());
   g_store.SetBool("daily.limit", g_daily.LimitHit());
   g_store.Set("daily.scope", EnumDailyScopeToString(g_daily.Scope()));
   g_store.SetDouble("equity.peak", g_peak_equity);
   g_store.SetLong("web.last_cmd", g_web.LastCommandId());
   string keys[];
   datetime times[];
   int n = g_adaptive.ConsumedKeys(keys, times);
   for(int i = 0; i < n; i++)
      g_store.SetLong("consumed." + keys[i], (long)times[i]);
   PendingRequest p = g_exec.Pending();
   g_store.SetBool("pending.active", p.active);
   if(p.active)
     {
      g_store.Set("pending.signal", p.signal_id);
      g_store.Set("pending.setup", p.setup_key);
      g_store.Set("pending.comment", p.comment);
      g_store.SetLong("pending.direction", (long)p.direction);
      g_store.SetDouble("pending.volume", p.volume);
      g_store.SetLong("pending.sent", (long)p.sent_at);
      g_store.SetLong("pending.strategy", (long)p.strategy);
      g_store.SetDouble("pending.sl", p.initial_sl);
      g_store.SetDouble("pending.invalidation", p.invalidation);
     }
   g_store.SetBool("ctx.active", g_ctx_active);
   if(g_ctx_active)
     {
      g_store.Set("ctx.signal", g_ctx_signal.signal_id);
      g_store.Set("ctx.setup", g_ctx_signal.setup_key);
      g_store.SetLong("ctx.strategy", (long)g_ctx_signal.strategy);
      g_store.SetLong("ctx.direction", (long)g_ctx_signal.direction);
      g_store.SetDouble("ctx.score", g_ctx_score);
      g_store.SetLong("ctx.regime", (long)g_ctx_regime);
      g_store.SetLong("ctx.session", (long)g_ctx_session);
      g_store.SetDouble("ctx.sl", g_ctx_risk.sl);
      g_store.SetDouble("ctx.tp", g_ctx_risk.tp);
      g_store.SetDouble("ctx.risk", g_ctx_risk.risk_money);
      g_store.SetDouble("ctx.slip", g_ctx_exec.slippage_points);
      g_store.SetDouble("ctx.spread", g_ctx_spread);
     }
   g_pos.SaveMeta(g_store);
   g_learn.SaveOpen(g_store);
   string why;
   if(!g_store.Save(why))
      g_log.LogOnChange("state.save", why, LOG_ERROR, "EA", "STATE_SAVE_FAILED", why);
   g_last_save = TimeTradeServer();
   g_dirty = false;
  }

//--- Devuelve false si el estado está corrupto (-> modo seguro)
bool LoadState(string &why)
  {
   if(!g_store.Load(why))
      return false;
   if(g_store.Count() == 0)
      return true;
   datetime now = TimeTradeServer();
   string st = g_store.Get("ea.state", "RUNNING");
   if(st == "PAUSED")
      SetState(EA_PAUSED, "restaurado: entradas pausadas por el usuario");
   else
      if(st == "SAFE_MODE")
         SetState(EA_SAFE_MODE, "restaurado: " + g_store.Get("ea.reason", "modo seguro previo"));
   // un bloqueo diario solo se restaura si se calculó con el mismo alcance (si cambió, se reevalúa)
   bool same_scope = (g_store.Get("daily.scope", "ACCOUNT") == EnumDailyScopeToString(g_daily.Scope()));
   if(g_store.GetBool("daily.limit") && !same_scope)
      g_log.Info("EA", "DAILY_SCOPE_CHANGED", "el alcance de la pérdida diaria cambió: el bloqueo guardado se reevalúa con el nuevo alcance");
   if(!g_daily.Restore(now, (datetime)g_store.GetLong("daily.start"), g_store.GetDouble("daily.e0"),
                       g_store.GetDouble("daily.deposits"), g_store.GetBool("daily.limit") && same_scope))
      g_log.Info("EA", "DAILY_NOT_RESTORED", "el estado diario guardado es de otro día o no existe");
   g_peak_equity = g_store.GetDouble("equity.peak", 0.0);
   g_web.SetLastCommandId(g_store.GetLong("web.last_cmd", 0));
   string ck[];
   int n = g_store.KeysWithPrefix("consumed.", ck);
   for(int i = 0; i < n; i++)
      g_adaptive.MarkConsumed(StringSubstr(ck[i], 9), (datetime)g_store.GetLong(ck[i]));
   if(g_store.GetBool("pending.active"))
     {
      PendingRequest p;
      ZeroMemory(p);
      p.active = true;
      p.signal_id = g_store.Get("pending.signal");
      p.setup_key = g_store.Get("pending.setup");
      p.comment = g_store.Get("pending.comment");
      p.direction = (ENUM_DIRECTION)g_store.GetLong("pending.direction");
      p.volume = g_store.GetDouble("pending.volume");
      p.sent_at = (datetime)g_store.GetLong("pending.sent");
      p.strategy = (ENUM_STRATEGY_ID)g_store.GetLong("pending.strategy");
      p.initial_sl = g_store.GetDouble("pending.sl");
      p.invalidation = g_store.GetDouble("pending.invalidation");
      g_exec.RestorePending(p);
      g_log.Warn("EA", "PENDING_RESTORED", "solicitud pendiente de antes del reinicio: se reconciliará con el servidor", p.signal_id);
     }
   if(g_store.GetBool("ctx.active"))
     {
      g_ctx_active = true;
      g_ctx_signal.signal_id = g_store.Get("ctx.signal");
      g_ctx_signal.setup_key = g_store.Get("ctx.setup");
      g_ctx_signal.strategy = (ENUM_STRATEGY_ID)g_store.GetLong("ctx.strategy");
      g_ctx_signal.direction = (ENUM_DIRECTION)g_store.GetLong("ctx.direction");
      g_ctx_score = g_store.GetDouble("ctx.score");
      g_ctx_regime = (ENUM_REGIME)g_store.GetLong("ctx.regime");
      g_ctx_session = (ENUM_SESSION_ID)g_store.GetLong("ctx.session");
      ZeroMemory(g_ctx_risk);
      g_ctx_risk.sl = g_store.GetDouble("ctx.sl");
      g_ctx_risk.tp = g_store.GetDouble("ctx.tp");
      g_ctx_risk.risk_money = g_store.GetDouble("ctx.risk");
      ZeroMemory(g_ctx_exec);
      g_ctx_exec.slippage_points = g_store.GetDouble("ctx.slip");
      g_ctx_spread = g_store.GetDouble("ctx.spread");
     }
   g_pos.LoadMeta(g_store);
   g_learn.LoadOpen(g_store);
   return true;
  }

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_tester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_symbol = _Symbol;
   if(InpSymbolOverride != "")
     {
      if(!InpAllowAnySymbol || !SymbolSelect(InpSymbolOverride, true))
        {
         Print("XAUUSD_Autonomous: InpSymbolOverride requiere InpAllowAnySymbol=true y un símbolo existente");
         return INIT_PARAMETERS_INCORRECT;
        }
      g_symbol = InpSymbolOverride;
     }
   g_log.Init("XAUUSD_Autonomous", LOG_DEBUG, InpPrintLevel);
   g_log.Info("EA", "START", StringFormat("versión %s símbolo %s magic %s tester=%s run=%s", XAU_PROJECT_VERSION,
                                          g_symbol, IntegerToString(InpMagic), (g_tester ? "sí" : "no"), InpRunTag));
   //--- símbolo
   string up = g_symbol;
   StringToUpper(up);
   if(StringFind(up, "XAUUSD") < 0 && !InpAllowAnySymbol)
     {
      g_log.Critical("EA", "WRONG_SYMBOL", "este EA es exclusivo para XAUUSD: " + g_symbol);
      return INIT_PARAMETERS_INCORRECT;
     }
   string why;
   if(!SymbolSpecLoad(g_symbol, g_spec, why))
     {
      g_log.Critical("EA", "SPEC_INVALID", why);
      return INIT_FAILED;
     }
   if(g_spec.tick_value_generic)
      g_log.Warn("EA", "SPEC_TICK_VALUE", "SYMBOL_TRADE_TICK_VALUE_LOSS no disponible: se usa SYMBOL_TRADE_TICK_VALUE (verificado contra OrderCalcProfit en cada operación)");
   g_log.Info("EA", "SPEC", StringFormat("digits=%d point=%g tick_size=%g tick_value_loss=%g contrato=%g vol=[%g, %g] paso=%g stops=%d freeze=%d",
                                         g_spec.digits, g_spec.point, g_spec.tick_size, g_spec.tick_value_loss, g_spec.contract_size,
                                         g_spec.volume_min, g_spec.volume_max, g_spec.volume_step, g_spec.stops_level, g_spec.freeze_level));
   //--- cuenta
   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_netting = (mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_account_ok = CRiskManager::AccountAllowed((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE),
                                               InpAllowRealAccount, InpRealAccountConfirmation, g_account_reason);
   g_log.Info("EA", "ACCOUNT", StringFormat("modo %s, %s, moneda %s. Entradas %s %s",
                                            EnumToString((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)),
                                            (g_netting ? "Netting" : "Hedging"), AccountInfoString(ACCOUNT_CURRENCY),
                                            (g_account_ok ? "permitidas" : "BLOQUEADAS:"), g_account_reason));
   //--- configuraciones
   SessionClockConfig ccfg;
   SessionClockDefaultConfig(ccfg);
   ccfg.london_open_min = InpLondonOpenMin;
   ccfg.london_close_min = InpLondonCloseMin;
   ccfg.newyork_open_min = InpNewYorkOpenMin;
   ccfg.newyork_close_min = InpNewYorkCloseMin;
   ccfg.tester_std_offset_sec = InpTesterGmtOffsetMin * 60;
   ccfg.tester_dst_rule = InpTesterDstRule;
   if(!g_clock.Init(ccfg, g_tester))
     { g_log.Critical("EA", "CLOCK_INVALID", g_clock.LastError()); return INIT_PARAMETERS_INCORRECT; }
   g_log.SetUtcOffset(g_clock.ServerOffsetAt(TimeTradeServer()));

   MarketEngineConfig mcfg;
   MarketEngineDefaultConfig(mcfg, g_symbol);
   RegimeConfig rcfg;
   RegimeDefaultConfig(rcfg);
   rcfg.trend_adx_min = InpTrendAdxMin;
   rcfg.range_adx_max = InpRangeAdxMax;
   rcfg.high_vol_h1_atr_ratio = InpHighVolH1Ratio;
   rcfg.high_vol_m15_atr_ratio = InpHighVolM15Ratio;
   StrategyCommonConfig common;
   StrategyCommonDefaultConfig(common);
   common.pivot_n_m15 = mcfg.pivot_n_m15;
   common.pivot_n_m5 = mcfg.pivot_n_m5;
   SMCConfig smc;          SMCDefaultConfig(smc);
   BreakoutConfig bo;      BreakoutDefaultConfig(bo);
   ReversalConfig rv;      ReversalDefaultConfig(rv);
   AdaptiveConfig acfg;
   AdaptiveDefaultConfig(acfg);
   acfg.min_score = InpMinScore;
   acfg.high_score = InpHighScore;
   g_smc_on = InpEnableSMC;
   g_bo_on = InpEnableBreakout;
   g_rv_on = InpEnableReversal;
   //--- modelo Champion (nunca toca riesgo)
   if(InpUseChampion)
     {
      string keys[], vals[], ver;
      if(CLearningEngine::LoadChampion("XAUUSD/champion.model", true, keys, vals, ver, why))
        {
         string why2;
         if(CLearningEngine::ApplyChampion(keys, vals, acfg, rcfg, smc, bo, rv, g_smc_on, g_bo_on, g_rv_on, why2))
            g_log.Info("EA", "CHAMPION_APPLIED", why);
         else
            g_log.Warn("EA", "CHAMPION_REJECTED", why2);
        }
      else
         g_log.Info("EA", "CHAMPION", why);
     }
   RiskConfig risk;
   RiskDefaultConfig(risk);
   risk.risk_pct = InpRiskPct;
   risk.max_exposure_pct = InpMaxExposurePct;
   risk.max_positions = InpMaxPositions;
   risk.daily_loss_pct = InpDailyLossPct;
   risk.min_rr = InpMinRR;
   risk.commission_per_lot = InpCommissionPerLot;
   risk.slippage_points = InpSlippagePoints;
   risk.reduce_after_losses = InpReduceAfterLosses;
   risk.reduction_factor = InpReductionFactor;
   ExecutionConfig ecfg;
   ExecutionDefaultConfig(ecfg);
   ecfg.magic = InpMagic;
   ecfg.max_spread_points = InpMaxSpreadPoints;
   ecfg.deviation_points = InpDeviationPoints;
   ecfg.max_entry_drift_points = InpMaxEntryDriftPoints;
   ecfg.max_retries = InpMaxRetries;
   PositionConfig pcfg;
   PositionDefaultConfig(pcfg);
   pcfg.magic = InpMagic;
   pcfg.be_trigger_r = InpBreakEvenR;
   pcfg.be_offset_points = InpBreakEvenOffsetPts;
   pcfg.trail_start_r = InpTrailStartR;
   pcfg.trail_mode = InpTrailMode;
   pcfg.trail_atr_mult = InpTrailAtrMult;
   pcfg.close_on_invalidation = InpCloseOnInvalidation;
   pcfg.deviation_points = InpDeviationPoints;
   NewsConfig ncfg;
   NewsDefaultConfig(ncfg);
   ncfg.major_before_min = InpMajorNewsBeforeMin;
   ncfg.major_after_min = InpMajorNewsAfterMin;
   ncfg.usd_before_min = InpUsdNewsBeforeMin;
   ncfg.usd_after_min = InpUsdNewsAfterMin;
   ncfg.block_if_unverified = InpBlockIfNewsUnverified;
   //--- módulos (cualquier configuración inválida impide arrancar)
   g_calc = new CTerminalCalculator(g_symbol);
   if(!g_market.Init(mcfg, &g_log, &g_clock) || !g_regime.Init(rcfg, &g_log) ||
      !g_smc.Init(common, smc, &g_log) || !g_bo.Init(common, bo, &g_log) || !g_rv.Init(common, rv, &g_log) ||
      !g_adaptive.Init(acfg, &g_log) || !g_risk.Init(risk, g_calc, &g_log) ||
      !g_exec.Init(g_symbol, ecfg, &g_gateway, &g_log) || !g_pos.Init(g_symbol, pcfg, &g_gateway, &g_log) ||
      !g_news.Init(ncfg, g_tester, &g_log) || !g_learn.Init(InpRunTag, g_symbol, &g_log))
     {
      g_log.Critical("EA", "INIT_FAILED", "configuración inválida en algún módulo (ver registros anteriores)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!g_web.Init(InpWebEnabled, InpWebUrl, InpWebToken, InpWebIntervalSec, g_tester, &g_log))
     {
      g_log.Critical("EA", "INIT_FAILED", "configuración inválida del dashboard web");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_daily.Configure(InpDailyResetHour, InpDailyLossPct);
   g_daily.SetScope(InpDailyLossScope);
   //--- estado persistente
   FolderCreate("XAUUSD");
   g_store.Init(StateFile(), false);
   SetState(EA_RUNNING, "inicializado");
   if(!LoadState(why))
      EnterSafeMode("estado persistente corrupto: " + why);
   //--- base diaria: restaurada o reconstruida
   datetime now = TimeTradeServer();
   if(g_daily.E0() <= 0.0)
     {
      double realized, deposits;
      AccountDayFlows(g_daily.DayStartFor(now), realized, deposits);
      g_daily.Reconstruct(now, AccountInfoDouble(ACCOUNT_BALANCE), realized, deposits);
      g_log.Info("EA", "DAILY_RECONSTRUCTED", StringFormat("E0 = %.2f (balance - realizado hoy %.2f - depósitos %.2f)",
                                                           g_daily.E0(), realized, deposits));
     }
   RefreshDailyOwnPnL();
   g_log.Info("EA", "DAILY_SCOPE", StringFormat("pérdida diaria: %s; hoy %.2f%% de %.2f%%",
                                                (g_daily.Scope() == DAILY_SCOPE_EA ? "solo operaciones del EA" : "toda la cuenta"),
                                                g_daily.LossPct(AccountInfoDouble(ACCOUNT_EQUITY)), InpDailyLossPct));
   g_peak_equity = MathMax(g_peak_equity, AccountInfoDouble(ACCOUNT_EQUITY));
   //--- reconciliación inicial con el servidor
   long pid;
   double fill;
   if(g_exec.Reconcile(pid, fill) == 1)
      OnPositionConfirmed(pid);
   PositionInfo pos[];
   int n = g_pos.Sync(pos);
   for(int i = 0; i < n; i++)
      if(pos[i].sl <= 0.0)
         EnterSafeMode("posición " + IntegerToString((long)pos[i].ticket) + " sin Stop Loss al iniciar");
   g_log.Info("EA", "RECOVERED", StringFormat("%d posiciones propias, %d metadatos, pendiente=%s", n, g_pos.MetaCount(),
                                              (g_exec.HasPending() ? "sí" : "no")));
   g_news.Refresh(now);
   g_dash_on = InpShowDashboard && (!g_tester || MQLInfoInteger(MQL_VISUAL_MODE) != 0) && MQLInfoInteger(MQL_OPTIMIZATION) == 0;
   if(g_dash_on)
      g_dash.Init(0, "XAD_");
   SaveState();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_store.File() != "")
      SaveState();
   g_learn.WriteReport(StringFormat("XAUUSD/report_%s_%s.txt", g_symbol, InpRunTag));
   g_market.Deinit();
   if(g_dash_on)
      g_dash.Destroy();
   if(g_calc != NULL)
     {
      delete g_calc;
      g_calc = NULL;
     }
   g_log.Info("EA", "STOP", StringFormat("reason=%d estado=%s (las posiciones abiertas NO se cierran)", reason, EnumEAStateToString(g_state)));
   g_log.Close();
  }

//+------------------------------------------------------------------+
//| Confirmación de una nueva posición propia                        |
//+------------------------------------------------------------------+
void OnPositionConfirmed(const long pid)
  {
   // tras Reconcile la solicitud ya no está activa, pero conserva sus datos (señal, SL inicial,
   // invalidación), que además se persisten: sirven también después de un reinicio
   PendingRequest p = g_exec.Pending();
   g_pos.RegisterPosition(pid, p);
   if(g_ctx_active)
     {
      g_learn.RecordEntry(pid, g_ctx_signal, g_ctx_score, g_ctx_regime, g_ctx_session, g_ctx_risk, g_ctx_exec, g_ctx_spread);
      g_ctx_active = false;
     }
   g_dirty = true;
  }

//+------------------------------------------------------------------+
//| Gates de entrada                                                 |
//+------------------------------------------------------------------+
bool EntryGates(string &reasons)
  {
   reasons = "";
   if(g_state != EA_RUNNING)
      reasons += "ESTADO " + EnumEAStateToString(g_state) + " (" + g_state_reason + "); ";
   if(!g_account_ok)
      reasons += "CUENTA: " + g_account_reason + "; ";
   string why;
   if(!g_gateway.TradeAllowed(why))
      reasons += "CONEXIÓN/PERMISOS: " + why + "; ";
   if(!g_snap_valid)
      reasons += "DATOS: " + g_snap.invalid_reason + "; ";
   else
     {
      if(g_snap.session == SESSION_NONE)
         reasons += "SESIÓN: fuera de Londres/Nueva York; ";
      if(g_snap.spread_points > InpMaxSpreadPoints)
         reasons += StringFormat("SPREAD: %.0f > %d puntos; ", g_snap.spread_points, InpMaxSpreadPoints);
     }
   if(!g_gateway.MarketOpen(g_symbol, why))
      reasons += "MERCADO: " + why + "; ";
   if(g_news_state.blocked)
      reasons += "NOTICIAS: " + g_news_state.reason + "; ";
   if(g_daily.LimitHit())
      reasons += StringFormat("LÍMITE DIARIO: %.2f%% alcanzado; ", g_daily.LossPct(AccountInfoDouble(ACCOUNT_EQUITY)));
   if(g_regime_state.regime == REGIME_NO_TRADE || g_regime_state.regime == REGIME_HIGH_VOLATILITY)
      reasons += "RÉGIMEN " + EnumRegimeToString(g_regime_state.regime) + ": " + g_regime_state.reason + "; ";
   if(g_exec.HasPending())
      reasons += "PENDIENTE: solicitud sin reconciliar; ";
   return (reasons == "");
  }

//+------------------------------------------------------------------+
//| Pipeline por vela M5 cerrada                                     |
//+------------------------------------------------------------------+
void Pipeline(void)
  {
   g_snap_valid = g_market.Update(g_snap);
   if(!g_snap_valid)
      g_log.LogOnChange("snapshot", g_snap.invalid_reason, LOG_WARN, "EA", "DATA_INVALID", g_snap.invalid_reason);
   else
      g_log.LogOnChange("snapshot", "ok", LOG_INFO, "EA", "DATA_OK", "datos válidos");
   g_regime.Evaluate(g_snap, g_regime_state);
   g_news_state = g_news.Evaluate(TimeTradeServer());
   if(!g_snap_valid)
     {
      EntryGates(g_blocks);
      g_log.Debug("EA", "BAR", "sin datos válidos: " + g_snap.invalid_reason);
      return;
     }
   //--- señales
   TradeSignal sigs[];
   if(g_smc_on) g_smc.Evaluate(g_snap, g_regime_state, sigs);
   if(g_bo_on)  g_bo.Evaluate(g_snap, g_regime_state, sigs);
   if(g_rv_on)  g_rv.Evaluate(g_snap, g_regime_state, sigs);
   for(int i = 0; i < ArraySize(sigs); i++)
      g_log.Info("EA", "SIGNAL", CStrategyBase::Describe(sigs[i]), sigs[i].signal_id);
   //--- coordinación
   PositionInfo pos[];
   g_pos.Sync(pos);
   PositionBrief briefs[];
   g_pos.Briefs(pos, briefs);
   AdaptiveContext ctx;
   ctx.news_clear = !g_news_state.blocked && (g_news_state.minutes_to_next < 0 || g_news_state.minutes_to_next > 60);
   ctx.minutes_to_session_end = -1;
   g_last_proposal = g_adaptive.Decide(sigs, g_snap, g_regime_state, briefs, ctx);
   bool gates_open = EntryGates(g_blocks);
   g_log.Debug("EA", "BAR", StringFormat("%s | señales=%d | %s | bloqueos: %s", CRegimeEngine::Describe(g_regime_state),
                                         ArraySize(sigs), g_last_proposal.decision, (gates_open ? "ninguno" : g_blocks)));
   if(ArraySize(sigs) > 0)
      g_last_signal_text = g_last_proposal.decision;
   if(!g_last_proposal.valid)
      return;
   if(!gates_open)
     {
      g_log.Info("EA", "PROPOSAL_BLOCKED", "propuesta bloqueada: " + g_blocks, g_last_proposal.signal.signal_id);
      return;
     }
   //--- riesgo con el precio actual
   TradeSignal sig = g_last_proposal.signal;
   MqlTick tk;
   if(!SymbolInfoTick(g_symbol, tk))
      return;
   sig.entry_price = (sig.direction == DIR_LONG) ? tk.ask : tk.bid;
   PositionRisk risks[];
   CPositionManager::Risks(pos, risks);
   AccountSnapshot acc = Account();
   int losses = g_pos.ConsecutiveLosses(TimeTradeServer() - 30 * 86400, TimeTradeServer() + 60);
   RefreshDailyOwnPnL();
   RiskDecision rd = g_risk.Assess(sig, g_spec, acc, risks, g_daily, (tk.ask - tk.bid) / g_spec.point, losses);
   if(!rd.approved)
     {
      g_last_signal_text = sig.signal_id + " rechazada por riesgo: " + rd.reject_reason;
      if(rd.critical)
         EnterSafeMode("riesgo crítico: " + rd.reject_reason);
      return;
     }
   //--- ejecución
   g_ctx_active = true;
   g_ctx_signal = sig;
   g_ctx_risk = rd;
   g_ctx_score = g_last_proposal.score.total;
   g_ctx_regime = g_regime_state.regime;
   g_ctx_session = g_snap.session;
   g_ctx_spread = (tk.ask - tk.bid) / g_spec.point;
   ExecutionResult ex = g_exec.Execute(rd, sig, g_spec);
   g_ctx_exec = ex;
   g_last_trade_text = StringFormat("%s %s: %s", EnumExecStatusToString(ex.status), sig.signal_id, ex.message);
   if(ex.status == EXEC_DONE || ex.status == EXEC_UNCERTAIN)
     {
      g_adaptive.MarkConsumed(sig.setup_key, TimeTradeServer());
      long pid;
      double fill;
      if(g_exec.Reconcile(pid, fill) == 1)
         OnPositionConfirmed(pid);
     }
   else
      g_ctx_active = false;
   SaveState();
  }

//+------------------------------------------------------------------+
//| Eventos                                                          |
//+------------------------------------------------------------------+
//--- Gestión protectora + detección de vela nueva. Se llama desde OnTick y también desde
//--- OnTimer: si el gráfico deja de recibir ticks, la protección y el análisis siguen.
void ProcessMarket(void)
  {
   ulong ms = GetTickCount64();
   if(InpManageThrottleMs <= 0 || ms - g_last_manage_ms >= (ulong)InpManageThrottleMs)
     {
      g_last_manage_ms = ms;
      g_pos.Manage(g_snap, g_snap_valid, g_spec);
      if(g_pos.CriticalFlag())
         EnterSafeMode(g_pos.CriticalReason());
     }
   if(g_market.IsNewBar(PERIOD_M5))
      Pipeline();
  }

void OnTick()
  {
   g_market.SampleTickSpread();
   ProcessMarket();
  }

void OnTimer()
  {
   ProcessMarket();
   datetime now = TimeTradeServer();
   if(now - g_last_clock_refresh >= 60)
     {
      g_last_clock_refresh = now;
      if(!g_clock.Refresh())
         g_log.LogOnChange("clock", g_clock.LastError(), LOG_ERROR, "EA", "CLOCK_INVALID", g_clock.LastError());
      g_log.SetUtcOffset(g_clock.ServerOffsetAt(now));
     }
   g_news.Refresh(now);
   //--- pérdida diaria
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily.Update(now, equity))
     {
      g_log.Info("EA", "DAILY_RESET", StringFormat("nuevo día de trading, E0 = %.2f", g_daily.E0()));
      if(g_state == EA_DAILY_LIMIT)
         SetState(EA_RUNNING, "reset diario");
      g_dirty = true;
     }
   RefreshDailyOwnPnL();   // después de un posible reset: el PnL propio se mide desde el nuevo día
   if(g_daily.LimitReached(equity) && g_state == EA_RUNNING)
      SetState(EA_DAILY_LIMIT, StringFormat("pérdida diaria %.2f%% >= %.2f%%", g_daily.LossPct(equity), InpDailyLossPct));
   g_peak_equity = MathMax(g_peak_equity, equity);
   //--- reconciliación
   if(g_exec.HasPending())
     {
      long pid;
      double fill;
      int r = g_exec.Reconcile(pid, fill);
      if(r == 1)
         OnPositionConfirmed(pid);
      else
         if(r == 0)
           {
            g_ctx_active = false;
            g_dirty = true;
           }
     }
   //--- protección ante cambios del símbolo
   if(now - g_last_spec_check >= 60)
     {
      g_last_spec_check = now;
      SymbolSpec cur;
      string why;
      if(SymbolSpecLoad(g_symbol, cur, why) && SymbolSpecChanged(g_spec, cur))
         EnterSafeMode("la especificación del símbolo cambió durante la ejecución");
     }
   if(g_pos.CriticalFlag())
      EnterSafeMode(g_pos.CriticalReason());
   if(g_dirty || now - g_last_save >= 30)
      SaveState();
   UpdateDashboard();
   WebCycle();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dtype == DEAL_TYPE_BALANCE)
     {
      double amount = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      g_daily.AddBalanceOperation(amount);
      g_log.Info("EA", "BALANCE_OPERATION", StringFormat("depósito/retiro %.2f excluido de la pérdida diaria", amount));
      g_dirty = true;
      return;
     }
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_symbol || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long pid = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   g_log.Info("EA", "DEAL", StringFormat("deal %s %s posición %s precio %.2f volumen %.2f comisión %.2f",
                                         IntegerToString((long)trans.deal), EnumToString(entry), IntegerToString(pid),
                                         HistoryDealGetDouble(trans.deal, DEAL_PRICE), HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
                                         HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)));
   if(entry == DEAL_ENTRY_IN)
     {
      long rp;
      double fill;
      if(g_exec.HasPending() && g_exec.Reconcile(rp, fill) == 1)
         OnPositionConfirmed(rp);
     }
   else
      if(!g_gateway.PositionAlive(pid))
        {
         ClosedTrade c;
         if(ClosedTradeFor(pid, c))
           {
            g_learn.RecordClose(c);
            g_last_trade_text = StringFormat("CERRADA posición %s neto %.2f", IntegerToString(pid), c.profit + c.commission + c.swap);
            g_log.Info("EA", "POSITION_CLOSED", g_last_trade_text);
           }
        }
   g_dirty = true;
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(!g_dash_on || id != CHARTEVENT_OBJECT_CLICK)
      return;
   ENUM_DASH_COMMAND cmd = g_dash.OnClick(sparam, TimeLocal());
   switch(cmd)
     {
      case DASH_TOGGLE_PAUSE:
         if(g_state == EA_RUNNING)
            SetState(EA_PAUSED, "pausa manual (la gestión protectora sigue activa)");
         else
            if(g_state == EA_PAUSED)
               SetState(EA_RUNNING, "reanudado manualmente");
         break;
      case DASH_SAFE_MODE:
         EnterSafeMode("activado manualmente desde el panel");
         break;
      case DASH_EXIT_SAFE_MODE:
        {
         PositionInfo pos[];
         int n = g_pos.Sync(pos);
         bool all_sl = true;
         for(int i = 0; i < n; i++)
            if(pos[i].sl <= 0.0)
               all_sl = false;
         if(g_state == EA_SAFE_MODE && all_sl && !g_exec.HasPending())
           {
            g_pos.ClearCritical();
            SetState(g_daily.LimitHit() ? EA_DAILY_LIMIT : EA_RUNNING, "salida manual del modo seguro (confirmada)");
           }
         else
            g_log.Warn("EA", "SAFE_MODE_KEPT", "no se sale del modo seguro: hay posiciones sin SL o una solicitud pendiente");
         break;
        }
      case DASH_CLOSE_ALL:
        {
         int closed = g_pos.CloseAll(g_spec, "cierre manual confirmado desde el panel");
         g_log.Warn("EA", "CLOSE_ALL", StringFormat("cierre manual confirmado: %d posiciones cerradas", closed));
         break;
        }
      case DASH_SHOW_LOGS:
         g_log.Info("EA", "LOGS", "registros en MQL5/Files/" + g_log.CurrentFile() + " y diario en <Common>/Files/" + g_learn.TradesFile());
         break;
      default:
         break;
     }
   UpdateDashboard();
  }

void UpdateDashboard(void)
  {
   if(!g_dash_on)
      return;
   DashboardData d;
   datetime srv = TimeTradeServer();
   datetime utc = g_clock.ServerToUtc(srv);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   d.ea_state = EnumEAStateToString(g_state) + (g_state_reason != "" ? " (" + StringSubstr(g_state_reason, 0, 40) + ")" : "");
   d.symbol = g_symbol;
   d.account = EnumToString((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)) + (g_netting ? " Netting" : " Hedging");
   d.times = StringFormat("srv %s / UTC %s / COL %s", TimeToString(srv, TIME_MINUTES), TimeToString(utc, TIME_MINUTES),
                          TimeToString(CSessionClock::UtcToColombia(utc), TIME_MINUTES));
   d.session = g_snap_valid ? EnumSessionToString(g_snap.session) : "—";
   d.regime = EnumRegimeToString(g_regime_state.regime) + " (raw " + EnumRegimeToString(g_regime_state.raw_regime) + ")";
   d.h1_trend = g_snap_valid ? StringFormat("%s, ADX %.1f, EMA50 %s EMA200", EnumStructureToString(g_snap.h1.structure), g_snap.h1.adx[0],
                                            (g_snap.h1.ema_fast[0] > g_snap.h1.ema_slow[0] ? ">" : "<")) : "—";
   d.m15_structure = g_snap_valid ? EnumStructureToString(g_snap.m15.structure) : "—";
   d.m5_confirmation = g_snap_valid ? StringFormat("pendiente %.2f, cambio de momentum %s", g_snap.m5.ema_slope, (g_snap.m5.momentum_shift ? "sí" : "no")) : "—";
   d.strategy = g_last_proposal.valid ? EnumStrategyToString(g_last_proposal.signal.strategy) : "—";
   d.score = (g_last_proposal.candidates > 0) ? StringFormat("%.0f (%s)", g_last_proposal.score.total, EnumQualityToString(g_last_proposal.quality)) : "—";
   d.spread = g_snap_valid ? StringFormat("%.0f (media %.0f)", g_snap.spread_points, g_snap.spread_avg_points) : "—";
   d.atr = g_snap_valid ? StringFormat("%.2f (M15)", g_snap.m15.atr[0]) : "—";
   d.rsi = g_snap_valid ? StringFormat("%.1f (M15)", g_snap.m15.rsi[0]) : "—";
   PositionInfo pos[];
   int n = g_gateway.Positions(g_symbol, InpMagic, pos);
   d.positions = IntegerToString(n);
   PositionRisk risks[];
   CPositionManager::Risks(pos, risks);
   double exp_money = 0.0;
   string why;
   g_risk.ExistingExposure(risks, exp_money, why);
   double base = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), equity);
   d.risk_per_trade = StringFormat("%.2f%%", g_risk.EffectiveRiskPct(0));
   d.exposure = (base > 0) ? StringFormat("%.2f%%", exp_money / base * 100.0) : "—";
   d.daily_loss = StringFormat("%.2f%% / %.2f%% (%s)", g_daily.LossPct(equity), InpDailyLossPct,
                               (g_daily.Scope() == DAILY_SCOPE_EA ? "EA" : "cuenta"));
   d.daily_gain = StringFormat("%.2f%%", g_daily.GainPct(equity));
   d.drawdown = (g_peak_equity > 0) ? StringFormat("%.2f%% desde el máximo", (g_peak_equity - equity) / g_peak_equity * 100.0) : "—";
   d.news = g_news_state.blocked ? "BLOQUEO: " + g_news_state.reason :
            (g_news_state.minutes_to_next >= 0 ? StringFormat("libre (próximo: %s en %d min)", g_news_state.next_name, g_news_state.minutes_to_next) : "libre");
   d.last_signal = g_last_signal_text;
   d.last_trade = g_last_trade_text;
   d.blocks = (g_blocks == "") ? "ninguno" : g_blocks;
   g_dash.Update(d, g_state == EA_PAUSED, TimeLocal());
  }

//+------------------------------------------------------------------+
//| Dashboard web: telemetría saliente y comandos remotos limitados  |
//+------------------------------------------------------------------+
double CurrentExposurePct(int &npos)
  {
   PositionInfo pos[];
   npos = g_gateway.Positions(g_symbol, InpMagic, pos);
   PositionRisk risks[];
   CPositionManager::Risks(pos, risks);
   double exp_money = 0.0;
   string why;
   g_risk.ExistingExposure(risks, exp_money, why);
   double base = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
   return (base > 0.0) ? exp_money / base * 100.0 : 0.0;
  }

string TelemetryJson(void)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   string mode = EnumToString((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE));
   StringReplace(mode, "ACCOUNT_TRADE_MODE_", "");
   int npos = 0;
   double exposure = CurrentExposurePct(npos);
   string news = g_news_state.blocked ? "BLOQUEO: " + g_news_state.reason :
                 (g_news_state.minutes_to_next >= 0 ? StringFormat("libre (próximo: %s en %d min)", g_news_state.next_name, g_news_state.minutes_to_next) : "libre");
   string j = "{";
   j += CWebDashboard::JsonStr("version", XAU_PROJECT_VERSION) + ",";
   j += CWebDashboard::JsonStr("symbol", g_symbol) + ",";
   j += CWebDashboard::JsonStr("run_tag", InpRunTag) + ",";
   j += CWebDashboard::JsonStr("account_mode", mode + (g_netting ? " Netting" : " Hedging")) + ",";
   j += CWebDashboard::JsonStr("currency", AccountInfoString(ACCOUNT_CURRENCY)) + ",";
   j += CWebDashboard::JsonNum("equity", equity, 2) + ",";
   j += CWebDashboard::JsonNum("balance", AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   j += CWebDashboard::JsonStr("state", EnumEAStateToString(g_state)) + ",";
   j += CWebDashboard::JsonStr("state_reason", g_state_reason) + ",";
   j += CWebDashboard::JsonNum("daily_loss_pct", g_daily.LossPct(equity), 2) + ",";
   j += CWebDashboard::JsonNum("daily_limit_pct", InpDailyLossPct, 2) + ",";
   j += CWebDashboard::JsonStr("daily_scope", EnumDailyScopeToString(g_daily.Scope())) + ",";
   j += CWebDashboard::JsonNum("daily_gain_pct", g_daily.GainPct(equity), 2) + ",";
   j += CWebDashboard::JsonNum("exposure_pct", exposure, 2) + ",";
   j += CWebDashboard::JsonNum("risk_pct", g_risk.EffectiveRiskPct(0), 2) + ",";
   j += CWebDashboard::JsonNum("positions", npos, 0) + ",";
   j += CWebDashboard::JsonNum("drawdown_pct", (g_peak_equity > 0) ? (g_peak_equity - equity) / g_peak_equity * 100.0 : 0.0, 2) + ",";
   j += CWebDashboard::JsonStr("regime", EnumRegimeToString(g_regime_state.regime)) + ",";
   j += CWebDashboard::JsonStr("session", g_snap_valid ? EnumSessionToString(g_snap.session) : "") + ",";
   if(g_snap_valid)
     {
      j += CWebDashboard::JsonNum("spread", g_snap.spread_points, 1) + ",";
      j += CWebDashboard::JsonNum("spread_avg", g_snap.spread_avg_points, 1) + ",";
      j += CWebDashboard::JsonNum("atr_m15", g_snap.m15.atr[0], 2) + ",";
      j += CWebDashboard::JsonNum("rsi_m15", g_snap.m15.rsi[0], 1) + ",";
     }
   j += CWebDashboard::JsonStr("news", news) + ",";
   j += CWebDashboard::JsonStr("last_signal", g_last_signal_text) + ",";
   j += CWebDashboard::JsonStr("last_trade", g_last_trade_text) + ",";
   j += CWebDashboard::JsonStr("blocks", (g_blocks == "") ? "ninguno" : g_blocks);
   j += "}";
   return j;
  }

//--- Solo PAUSE / RESUME / SAFE_MODE (ya verificados por firma, antigüedad e id). Nada remoto
//--- abre, cierra ni modifica posiciones, ni saca del modo seguro.
void ApplyWebCommand(const string cmd, const long id)
  {
   string tag = "comando web #" + IntegerToString(id) + " " + cmd;
   if(cmd == "PAUSE")
     {
      if(g_state == EA_RUNNING)
         SetState(EA_PAUSED, "pausa remota desde el dashboard web (la gestión protectora sigue activa)");
      else
         g_log.Info("EA", "WEB_COMMAND_IGNORED", tag + ": el estado " + EnumEAStateToString(g_state) + " ya bloquea entradas");
     }
   else
      if(cmd == "RESUME")
        {
         if(g_state == EA_PAUSED)
            SetState(EA_RUNNING, "reanudado desde el dashboard web");
         else
            g_log.Info("EA", "WEB_COMMAND_IGNORED", tag + ": solo se reanuda desde PAUSED (estado " + EnumEAStateToString(g_state) + ")");
        }
      else
         if(cmd == "SAFE_MODE")
            EnterSafeMode("activado remotamente desde el dashboard web");
   g_log.Warn("EA", "WEB_COMMAND", tag + " -> estado " + EnumEAStateToString(g_state));
  }

void WebCycle(void)
  {
   if(!g_web.Due(TimeGMT()))
      return;
   string why;
   if(!g_web.SendTelemetry(TelemetryJson(), why))
     {
      g_log.LogOnChange("web", why, LOG_WARN, "WebDashboard", "UNREACHABLE", "telemetría no enviada: " + why);
      return;   // sin conexión no se consultan comandos en este ciclo (no bloquear más el hilo)
     }
   g_log.LogOnChange("web", "", LOG_INFO, "WebDashboard", "CONNECTED", "telemetría enviada");
   long ids[];
   string cmds[];
   int n = g_web.PollCommands(ids, cmds, why);
   for(int i = 0; i < n; i++)
     {
      ApplyWebCommand(cmds[i], ids[i]);
      // se registra como aplicado ANTES de confirmar: si la confirmación falla no se re-aplica
      g_web.SetLastCommandId(ids[i]);
      g_dirty = true;
      string ack_why;
      if(!g_web.Ack(ids[i], ack_why))
         g_log.Warn("WebDashboard", "ACK_FAILED", "comando #" + IntegerToString(ids[i]) + " aplicado, confirmación pendiente: " + ack_why);
     }
   if(n > 0)
     {
      SaveState();
      UpdateDashboard();
     }
  }

//--- Criterio de optimización: esperanza en R × raíz del número de operaciones, penalizada por el
//--- drawdown en R. Pocas operaciones (< 30) -> 0 (no concluyente).
double OnTester()
  {
   TradeRecord recs[];
   g_learn.ClosedRecords(recs);
   PerfStats s = CLearningEngine::Compute(recs);
   if(s.trades < 30)
      return 0.0;
   double eq = 0, peak = 0, dd_r = 0;
   for(int i = 0; i < ArraySize(recs); i++)
     {
      eq += recs[i].r_multiple;
      peak = MathMax(peak, eq);
      dd_r = MathMax(dd_r, peak - eq);
     }
   return s.expectancy_r * MathSqrt((double)s.trades) - 0.1 * dd_r;
  }
