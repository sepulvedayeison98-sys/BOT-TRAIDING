//+------------------------------------------------------------------+
//| LearningEngine.mqh                                               |
//| Parte "Champion" del aprendizaje controlado (dentro del EA):     |
//|  1. Diario de operaciones: cada operación cerrada con su         |
//|     contexto (estrategia, sesión, régimen, puntuación, riesgo,   |
//|     costos, slippage) -> CSV en la carpeta común.                |
//|  2. Estadísticas por estrategia, sesión, régimen y día.          |
//|  3. Carga del modelo Champion APROBADO:                          |
//|     - archivo clave=valor con approved=yes, approved_by,         |
//|       approved_at y sha256 del cuerpo (verificado),              |
//|     - solo claves de una lista blanca de parámetros de           |
//|       estrategia/régimen/puntuación; cualquier otra clave        |
//|       (riesgo, ejecución, posiciones, noticias) invalida el      |
//|       modelo completo,                                           |
//|     - ApplyChampion no recibe la configuración de riesgo: por    |
//|       construcción no puede modificarla.                         |
//| El "Challenger" (búsqueda, backtests, walk-forward, comparación) |
//| vive fuera del EA: Tools/challenger.py.                          |
//+------------------------------------------------------------------+
#ifndef XAUUSD_LEARNINGENGINE_MQH
#define XAUUSD_LEARNINGENGINE_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "RegimeEngine.mqh"
#include "AdaptiveEngine.mqh"
#include "StrategySMC.mqh"
#include "StrategyBreakout.mqh"
#include "StrategyReversal.mqh"
#include "StateStore.mqh"

#define LE_MODULE "LearningEngine"
#define LE_TRADES_HEADER "run_tag,identifier,signal_id,setup_key,strategy,direction,session,regime,score,open_time,close_time,volume,entry_price,exit_price,initial_sl,tp,risk_money,profit,commission,swap,net,r_multiple,slippage_points,spread_points"

class CLearningEngine
  {
private:
   CLogger          *m_log;
   string            m_run_tag;
   string            m_trades_file;
   TradeRecord       m_open[];     // operaciones abiertas con contexto de entrada
   TradeRecord       m_closed[];   // historial cargado + cerradas en esta sesión

   int               FindOpen(const long id) const
     {
      for(int i = 0; i < ArraySize(m_open); i++)
         if(m_open[i].identifier == id)
            return i;
      return -1;
     }

   static string     Csv(const string s)
     {
      string r = s;
      StringReplace(r, ",", ";");
      StringReplace(r, "\r", " ");
      StringReplace(r, "\n", " ");
      return r;
     }

public:
                     CLearningEngine(void) { m_log = NULL; m_run_tag = ""; m_trades_file = ""; }

   bool              Init(const string run_tag, const string symbol, CLogger *log)
     {
      m_log = log;
      m_run_tag = (run_tag == "") ? "live" : run_tag;
      m_trades_file = "XAUUSD/trades_" + symbol + "_" + m_run_tag + ".csv";
      FolderCreate("XAUUSD", FILE_COMMON);
      return true;
     }

   string            TradesFile(void) const { return m_trades_file; }
   int               ClosedCount(void) const { return ArraySize(m_closed); }
   int               OpenCount(void) const   { return ArraySize(m_open); }

   //--- Contexto de entrada de una posición recién abierta
   void              RecordEntry(const long identifier, const TradeSignal &sig, const double score,
                                 const ENUM_REGIME regime, const ENUM_SESSION_ID session, const RiskDecision &rd,
                                 const ExecutionResult &ex, const double spread_points)
     {
      int i = FindOpen(identifier);
      if(i < 0)
        {
         i = ArraySize(m_open);
         ArrayResize(m_open, i + 1);
        }
      ZeroMemory(m_open[i]);
      m_open[i].run_tag = m_run_tag;
      m_open[i].identifier = identifier;
      m_open[i].signal_id = sig.signal_id;
      m_open[i].setup_key = sig.setup_key;
      m_open[i].strategy = sig.strategy;
      m_open[i].direction = sig.direction;
      m_open[i].session = session;
      m_open[i].regime = regime;
      m_open[i].score = score;
      m_open[i].initial_sl = rd.sl;
      m_open[i].tp = rd.tp;
      m_open[i].risk_money = rd.risk_money;
      m_open[i].slippage_points = ex.slippage_points;
      m_open[i].spread_points = spread_points;
     }

   //--- Cierre: completa el registro, lo agrega al CSV y a las estadísticas
   bool              RecordClose(const ClosedTrade &c)
     {
      int i = FindOpen(c.identifier);
      TradeRecord r;
      ZeroMemory(r);
      if(i >= 0)
         r = m_open[i];
      else
        {
         r.run_tag = m_run_tag;
         r.identifier = c.identifier;
         r.signal_id = "";
         r.setup_key = "";
         r.strategy = STRAT_NONE;
         r.direction = c.direction;
        }
      r.open_time = c.open_time;
      r.close_time = c.close_time;
      r.volume = c.volume;
      r.entry_price = c.entry_price;
      r.exit_price = c.exit_price;
      r.profit = c.profit;
      r.commission = c.commission;
      r.swap = c.swap;
      r.net = c.profit + c.commission + c.swap;
      r.r_multiple = (r.risk_money > 0.0) ? r.net / r.risk_money : 0.0;
      int n = ArraySize(m_closed);
      ArrayResize(m_closed, n + 1);
      m_closed[n] = r;
      if(i >= 0)
        {
         for(int j = i; j < ArraySize(m_open) - 1; j++)
            m_open[j] = m_open[j + 1];
         ArrayResize(m_open, ArraySize(m_open) - 1);
        }
      return AppendCsv(r);
     }

   bool              AppendCsv(const TradeRecord &r)
     {
      bool exists = FileIsExist(m_trades_file, FILE_COMMON);
      int h = FileOpen(m_trades_file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, '\t', CP_UTF8);
      if(h == INVALID_HANDLE)
        {
         if(m_log != NULL) m_log.Error(LE_MODULE, "JOURNAL_FAILED", StringFormat("no se pudo abrir %s (err=%d)", m_trades_file, GetLastError()));
         return false;
        }
      FileSeek(h, 0, SEEK_END);
      if(!exists || FileTell(h) == 0)
         FileWriteString(h, LE_TRADES_HEADER + "\r\n");
      FileWriteString(h, StringFormat("%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s,%s,%.2f,%.5f,%.5f,%.5f,%.5f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.1f,%.1f\r\n",
                                      Csv(r.run_tag), IntegerToString(r.identifier), Csv(r.signal_id), Csv(r.setup_key),
                                      EnumStrategyToString(r.strategy), EnumDirectionToString(r.direction),
                                      EnumSessionToString(r.session), EnumRegimeToString(r.regime), r.score,
                                      TimeToString(r.open_time, TIME_DATE | TIME_SECONDS), TimeToString(r.close_time, TIME_DATE | TIME_SECONDS),
                                      r.volume, r.entry_price, r.exit_price, r.initial_sl, r.tp, r.risk_money, r.profit,
                                      r.commission, r.swap, r.net, r.r_multiple, r.slippage_points, r.spread_points));
      FileClose(h);
      return true;
     }

   //--- Persistencia del contexto de las operaciones abiertas (reinicios)
   void              SaveOpen(CStateStore &st) const
     {
      string keys[];
      int k = st.KeysWithPrefix("jr.", keys);
      for(int i = 0; i < k; i++)
         st.Remove(keys[i]);
      for(int i = 0; i < ArraySize(m_open); i++)
        {
         string p = "jr." + IntegerToString(m_open[i].identifier) + ".";
         st.Set(p + "signal", m_open[i].signal_id);
         st.Set(p + "setup", m_open[i].setup_key);
         st.SetLong(p + "strategy", (long)m_open[i].strategy);
         st.SetLong(p + "direction", (long)m_open[i].direction);
         st.SetLong(p + "session", (long)m_open[i].session);
         st.SetLong(p + "regime", (long)m_open[i].regime);
         st.SetDouble(p + "score", m_open[i].score);
         st.SetDouble(p + "sl", m_open[i].initial_sl);
         st.SetDouble(p + "tp", m_open[i].tp);
         st.SetDouble(p + "risk", m_open[i].risk_money);
         st.SetDouble(p + "slip", m_open[i].slippage_points);
         st.SetDouble(p + "spread", m_open[i].spread_points);
        }
     }

   int               LoadOpen(const CStateStore &st)
     {
      ArrayResize(m_open, 0);
      string keys[];
      int k = st.KeysWithPrefix("jr.", keys);
      for(int i = 0; i < k; i++)
        {
         int pos = StringFind(keys[i], ".signal");
         if(pos < 0 || pos + 7 != StringLen(keys[i]))
            continue;
         string idtxt = StringSubstr(keys[i], 3, pos - 3);
         string p = "jr." + idtxt + ".";
         int n = ArraySize(m_open);
         ArrayResize(m_open, n + 1);
         ZeroMemory(m_open[n]);
         m_open[n].run_tag = m_run_tag;
         m_open[n].identifier = StringToInteger(idtxt);
         m_open[n].signal_id = st.Get(p + "signal");
         m_open[n].setup_key = st.Get(p + "setup");
         m_open[n].strategy = (ENUM_STRATEGY_ID)st.GetLong(p + "strategy");
         m_open[n].direction = (ENUM_DIRECTION)st.GetLong(p + "direction");
         m_open[n].session = (ENUM_SESSION_ID)st.GetLong(p + "session");
         m_open[n].regime = (ENUM_REGIME)st.GetLong(p + "regime");
         m_open[n].score = st.GetDouble(p + "score");
         m_open[n].initial_sl = st.GetDouble(p + "sl");
         m_open[n].tp = st.GetDouble(p + "tp");
         m_open[n].risk_money = st.GetDouble(p + "risk");
         m_open[n].slippage_points = st.GetDouble(p + "slip");
         m_open[n].spread_points = st.GetDouble(p + "spread");
        }
      return ArraySize(m_open);
     }

   void              AddClosedForStats(const TradeRecord &r)
     {
      int n = ArraySize(m_closed);
      ArrayResize(m_closed, n + 1);
      m_closed[n] = r;
     }

   //--- Métricas de un conjunto (pura)
   static PerfStats  Compute(const TradeRecord &t[])
     {
      PerfStats s;
      ZeroMemory(s);
      int n = ArraySize(t);
      double equity = 0.0, peak = 0.0, sum_r = 0.0, slip = 0.0;
      int streak = 0;
      for(int i = 0; i < n; i++)
        {
         s.trades++;
         s.net += t[i].net;
         s.commission += t[i].commission;
         s.swap += t[i].swap;
         sum_r += t[i].r_multiple;
         slip += t[i].slippage_points;
         if(t[i].net > 0.0)
           { s.wins++; s.gross_profit += t[i].net; streak = 0; }
         else
           {
            s.losses++;
            s.gross_loss += -t[i].net;
            streak++;
            s.max_loss_streak = MathMax(s.max_loss_streak, streak);
           }
         equity += t[i].net;
         peak = MathMax(peak, equity);
         s.max_drawdown = MathMax(s.max_drawdown, peak - equity);
        }
      if(n > 0)
        {
         s.win_rate = (double)s.wins / n;
         s.expectancy = s.net / n;
         s.expectancy_r = sum_r / n;
         s.avg_slippage = slip / n;
        }
      if(s.gross_loss > 0.0)
         s.profit_factor = s.gross_profit / s.gross_loss;
      else
         s.profit_factor = (s.gross_profit > 0.0) ? DBL_MAX : 0.0;
      if(s.wins > 0 && s.losses > 0 && s.gross_loss > 0.0)
         s.avg_rr_realized = (s.gross_profit / s.wins) / (s.gross_loss / s.losses);
      return s;
     }

   //--- Subconjunto por grupo: field 0=estrategia, 1=sesión, 2=régimen, 3=día de la semana (0=domingo)
   static int        Filter(const TradeRecord &t[], const int field, const int value, TradeRecord &out[])
     {
      ArrayResize(out, 0);
      int n = 0;
      for(int i = 0; i < ArraySize(t); i++)
        {
         int v;
         if(field == 0) v = (int)t[i].strategy;
         else if(field == 1) v = (int)t[i].session;
         else if(field == 2) v = (int)t[i].regime;
         else
           {
            MqlDateTime dt;
            TimeToStruct(t[i].open_time, dt);
            v = dt.day_of_week;
           }
         if(v != value)
            continue;
         ArrayResize(out, n + 1);
         out[n++] = t[i];
        }
      return n;
     }

   static string     DescribeStats(const PerfStats &s)
     {
      string pf = (s.profit_factor == DBL_MAX) ? "inf" : DoubleToString(s.profit_factor, 2);
      return StringFormat("n=%d acierto=%.1f%% PF=%s neto=%.2f esperanza=%.2f (%.2fR) DDmax=%.2f racha-=%d comisión=%.2f swap=%.2f slippage=%.1f",
                          s.trades, 100.0 * s.win_rate, pf, s.net, s.expectancy, s.expectancy_r, s.max_drawdown,
                          s.max_loss_streak, s.commission, s.swap, s.avg_slippage);
     }

   //--- Reporte de texto por grupos (archivo en la carpeta común)
   bool              WriteReport(const string file)
     {
      int h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
      if(h == INVALID_HANDLE)
         return false;
      FileWriteString(h, "TOTAL: " + DescribeStats(Compute(m_closed)) + "\r\n");
      string gnames[4] = {"ESTRATEGIA", "SESION", "REGIMEN", "DIA"};
      int gmax[4] = {3, 3, 4, 6};
      for(int g = 0; g < 4; g++)
        {
         for(int v = (g == 3 ? 0 : 0); v <= gmax[g]; v++)
           {
            TradeRecord sub[];
            if(Filter(m_closed, g, v, sub) == 0)
               continue;
            string label = (g == 0) ? EnumStrategyToString((ENUM_STRATEGY_ID)v) :
                           (g == 1) ? EnumSessionToString((ENUM_SESSION_ID)v) :
                           (g == 2) ? EnumRegimeToString((ENUM_REGIME)v) : IntegerToString(v);
            FileWriteString(h, StringFormat("%s %s: %s\r\n", gnames[g], label, DescribeStats(Compute(sub))));
           }
        }
      FileWriteString(h, "Nota: con pocas operaciones estas cifras no son estadísticamente concluyentes.\r\n");
      FileClose(h);
      return true;
     }

   void              ClosedRecords(TradeRecord &out[]) const
     {
      int n = ArraySize(m_closed);
      ArrayResize(out, n);
      for(int i = 0; i < n; i++)
         out[i] = m_closed[i];
     }

   //=================================================================
   // Modelo Champion
   //=================================================================
   static string     Sha256Hex(const string text)
     {
      uchar data[], key[], res[];
      int len = StringToCharArray(text, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(len > 0)
         ArrayResize(data, len - 1);   // sin el terminador nulo
      if(CryptEncode(CRYPT_HASH_SHA256, data, key, res) <= 0)
         return "";
      string hex = "";
      for(int i = 0; i < ArraySize(res); i++)
         hex += StringFormat("%02x", res[i]);
      return hex;
     }

   //--- Claves permitidas (parámetros de estrategia, régimen y puntuación; nunca riesgo)
   static bool       AllowedKey(const string k)
     {
      string allowed[] =
        {
         "adaptive.min_score", "adaptive.high_score",
         "regime.trend_adx_min", "regime.range_adx_max", "regime.high_vol_h1_atr_ratio", "regime.high_vol_m15_atr_ratio",
         "regime.low_vol_atr_ratio", "regime.trend_min_slope", "regime.range_max_slope", "regime.confirm_evaluations",
         "smc.lookback_m15", "smc.sweep_min_pen_atr", "smc.fvg_min_atr", "smc.require_discount",
         "breakout.box_bars", "breakout.max_box_atr", "breakout.min_break_atr", "breakout.min_body_ratio",
         "breakout.require_volume", "breakout.max_bars_since_break",
         "reversal.lookback_m15", "reversal.rsi_min_diff", "reversal.extension_atr", "reversal.min_confirmations",
         "strategy.smc_enabled", "strategy.breakout_enabled", "strategy.reversal_enabled"
        };
      for(int i = 0; i < ArraySize(allowed); i++)
         if(allowed[i] == k)
            return true;
      return false;
     }

   //--- Carga y verifica el modelo. keys/values solo contienen claves permitidas.
   static bool       LoadChampion(const string file, const bool common, string &keys[], string &values[],
                                  string &version, string &why)
     {
      ArrayResize(keys, 0);
      ArrayResize(values, 0);
      version = "";
      int flag = common ? FILE_COMMON : 0;
      if(!FileIsExist(file, flag))
        { why = "no hay modelo Champion: se usan los parámetros por defecto"; return false; }
      int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | flag, '\t', CP_UTF8);
      if(h == INVALID_HANDLE)
        { why = "no se pudo abrir el modelo"; return false; }
      string body = "", sha = "", approved = "", by = "", at = "";
      string lk[], lv[];
      int n = 0;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         if(StringLen(line) == 0)
            continue;
         int eq = StringFind(line, "=");
         if(eq <= 0)
           { FileClose(h); why = "línea inválida en el modelo: " + line; return false; }
         string k = StringSubstr(line, 0, eq), v = StringSubstr(line, eq + 1);
         if(k == "sha256")
           { sha = v; continue; }
         body += line + "\n";
         if(k == "approved")         { approved = v; continue; }
         if(k == "approved_by")      { by = v; continue; }
         if(k == "approved_at")      { at = v; continue; }
         if(k == "version")          { version = v; continue; }
         if(StringGetCharacter(k, 0) == '#')
            continue;
         if(!AllowedKey(k))
           { FileClose(h); why = "clave no permitida en el modelo (posible intento de tocar riesgo/ejecución): " + k; return false; }
         ArrayResize(lk, n + 1);
         ArrayResize(lv, n + 1);
         lk[n] = k;
         lv[n] = v;
         n++;
        }
      FileClose(h);
      if(approved != "yes" || by == "" || at == "")
        { why = "modelo sin aprobación explícita (approved=yes, approved_by, approved_at)"; return false; }
      string actual = Sha256Hex(body);
      if(actual == "" || sha != actual)
        { why = "sha256 del modelo no coincide: archivo alterado o corrupto"; return false; }
      ArrayCopy(keys, lk);
      ArrayCopy(values, lv);
      why = StringFormat("modelo %s aprobado por %s el %s (%d parámetros)", version, by, at, n);
      return true;
     }

   //--- Aplica el modelo a las configuraciones de estrategia. No recibe riesgo: no puede tocarlo.
   //--- Devuelve false (sin aplicar nada) si algún valor deja una configuración inválida.
   static bool       ApplyChampion(const string &keys[], const string &values[], AdaptiveConfig &ad, RegimeConfig &rg,
                                   SMCConfig &smc, BreakoutConfig &bo, ReversalConfig &rv, bool &smc_on, bool &bo_on,
                                   bool &rv_on, string &why)
     {
      AdaptiveConfig a2 = ad;
      RegimeConfig r2 = rg;
      SMCConfig s2 = smc;
      BreakoutConfig b2 = bo;
      ReversalConfig v2 = rv;
      bool e1 = smc_on, e2 = bo_on, e3 = rv_on;
      for(int i = 0; i < ArraySize(keys); i++)
        {
         string k = keys[i];
         double d = StringToDouble(values[i]);
         int n = (int)StringToInteger(values[i]);
         bool b = (values[i] == "1" || values[i] == "true" || values[i] == "yes");
         if(k == "adaptive.min_score") a2.min_score = d;
         else if(k == "adaptive.high_score") a2.high_score = d;
         else if(k == "regime.trend_adx_min") r2.trend_adx_min = d;
         else if(k == "regime.range_adx_max") r2.range_adx_max = d;
         else if(k == "regime.high_vol_h1_atr_ratio") r2.high_vol_h1_atr_ratio = d;
         else if(k == "regime.high_vol_m15_atr_ratio") r2.high_vol_m15_atr_ratio = d;
         else if(k == "regime.low_vol_atr_ratio") r2.low_vol_atr_ratio = d;
         else if(k == "regime.trend_min_slope") r2.trend_min_slope = d;
         else if(k == "regime.range_max_slope") r2.range_max_slope = d;
         else if(k == "regime.confirm_evaluations") r2.confirm_evaluations = n;
         else if(k == "smc.lookback_m15") s2.lookback_m15 = n;
         else if(k == "smc.sweep_min_pen_atr") s2.sweep_min_pen_atr = d;
         else if(k == "smc.fvg_min_atr") s2.fvg_min_atr = d;
         else if(k == "smc.require_discount") s2.require_discount = b;
         else if(k == "breakout.box_bars") b2.box_bars = n;
         else if(k == "breakout.max_box_atr") b2.max_box_atr = d;
         else if(k == "breakout.min_break_atr") b2.min_break_atr = d;
         else if(k == "breakout.min_body_ratio") b2.min_body_ratio = d;
         else if(k == "breakout.require_volume") b2.require_volume = b;
         else if(k == "breakout.max_bars_since_break") b2.max_bars_since_break = n;
         else if(k == "reversal.lookback_m15") v2.lookback_m15 = n;
         else if(k == "reversal.rsi_min_diff") v2.rsi_min_diff = d;
         else if(k == "reversal.extension_atr") v2.extension_atr = d;
         else if(k == "reversal.min_confirmations") v2.min_confirmations = n;
         else if(k == "strategy.smc_enabled") e1 = b;
         else if(k == "strategy.breakout_enabled") e2 = b;
         else if(k == "strategy.reversal_enabled") e3 = b;
         else
           { why = "clave no aplicable: " + k; return false; }
        }
      if(!AdaptiveValidateConfig(a2, why) || !RegimeValidateConfig(r2, why) || !SMCValidateConfig(s2, why) ||
         !BreakoutValidateConfig(b2, why) || !ReversalValidateConfig(v2, why))
        { why = "el modelo deja una configuración inválida: " + why; return false; }
      ad = a2; rg = r2; smc = s2; bo = b2; rv = v2;
      smc_on = e1; bo_on = e2; rv_on = e3;
      why = "";
      return true;
     }
  };

#endif // XAUUSD_LEARNINGENGINE_MQH
