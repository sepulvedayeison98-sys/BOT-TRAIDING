//+------------------------------------------------------------------+
//| RegimeLogger.mq5                                                 |
//| EA de VALIDACIÓN de la Fase 3. NO OPERA.                         |
//| En cada vela M5 cerrada registra el régimen y sus variables en   |
//| un CSV para analizarlo con Tools/regime_report.py.               |
//| Pensado para el Strategy Tester (modelo "OHLC 1 minuto" basta).  |
//| Salida (carpeta común de terminales, FILE_COMMON):               |
//|   <Common>/Files/XAUUSD/regime_<símbolo>_<inicio>.csv            |
//+------------------------------------------------------------------+
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include <XAUUSD/RegimeEngine.mqh>

input group "Hora del servidor en Strategy Tester"
input int            InpTesterGmtOffsetMin = 0;
input ENUM_DST_RULE  InpTesterDstRule      = DST_RULE_NONE;
input group "RegimeEngine (hipótesis a validar)"
input double         InpTrendAdxMin        = 22.0;
input double         InpRangeAdxMax        = 18.0;
input double         InpHighVolH1Ratio     = 1.8;
input double         InpHighVolM15Ratio    = 2.2;
input double         InpLowVolRatio        = 0.5;
input double         InpMaxSpreadRatio     = 3.0;
input double         InpTrendMinSlope      = 0.05;
input bool           InpRequireH1Structure = true;
input double         InpRangeMaxSlope      = 0.3;
input double         InpRangeMinWidthAtr   = 2.0;
input double         InpRangeMaxWidthAtr   = 12.0;
input int            InpConfirmEvaluations = 2;

CLogger        g_log;
CSessionClock  g_clock;
CMarketEngine  g_market;
CRegimeEngine  g_regime;
MarketSnapshot g_snap;
int            g_csv = INVALID_HANDLE;
long           g_rows = 0;

string Clean(const string s)
  {
   string r = s;
   StringReplace(r, ",", ";");
   StringReplace(r, "\"", "'");
   return r;
  }

int OnInit()
  {
   g_log.Init("RegimeLogger", LOG_INFO, LOG_WARN);
   SessionClockConfig ccfg;
   SessionClockDefaultConfig(ccfg);
   ccfg.tester_std_offset_sec = InpTesterGmtOffsetMin * 60;
   ccfg.tester_dst_rule = InpTesterDstRule;
   if(!g_clock.Init(ccfg, MQLInfoInteger(MQL_TESTER) != 0))
      return INIT_PARAMETERS_INCORRECT;

   MarketEngineConfig mcfg;
   MarketEngineDefaultConfig(mcfg, _Symbol);
   if(!g_market.Init(mcfg, &g_log, &g_clock))
      return INIT_FAILED;

   RegimeConfig rc;
   RegimeDefaultConfig(rc);
   rc.trend_adx_min = InpTrendAdxMin;
   rc.range_adx_max = InpRangeAdxMax;
   rc.high_vol_h1_atr_ratio = InpHighVolH1Ratio;
   rc.high_vol_m15_atr_ratio = InpHighVolM15Ratio;
   rc.low_vol_atr_ratio = InpLowVolRatio;
   rc.max_spread_ratio = InpMaxSpreadRatio;
   rc.trend_min_slope = InpTrendMinSlope;
   rc.require_h1_structure = InpRequireH1Structure;
   rc.range_max_slope = InpRangeMaxSlope;
   rc.range_min_width_atr = InpRangeMinWidthAtr;
   rc.range_max_width_atr = InpRangeMaxWidthAtr;
   rc.confirm_evaluations = InpConfirmEvaluations;
   if(!g_regime.Init(rc, &g_log))
      return INIT_PARAMETERS_INCORRECT;

   FolderCreate("XAUUSD", FILE_COMMON);
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   string fname = StringFormat("XAUUSD/regime_%s_%04d%02d%02d_%02d%02d%02d.csv", _Symbol,
                               dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   g_csv = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   if(g_csv == INVALID_HANDLE)
     {
      g_log.Critical("RegimeLogger", "CSV_OPEN_FAILED", fname);
      return INIT_FAILED;
     }
   FileWriteString(g_csv, "server_time,utc_time,session,m5_close,h1_atr,regime,raw_regime,h1_adx,"
                   "h1_atr_ratio,m15_atr_ratio,h1_slope,h1_structure,m15_structure,range_high,range_low,"
                   "spread_ratio,reason\r\n");
   // parámetros de la corrida en el log, para trazabilidad del reporte
   g_log.Info("RegimeLogger", "RUN_PARAMS",
              StringFormat("file=%s adx=%.1f/%.1f hv=%.2f/%.2f lv=%.2f slope=%.3f struct=%s rslope=%.2f "
                           "rwidth=%.1f-%.1f confirm=%d offset=%d dst=%d", fname, InpTrendAdxMin, InpRangeAdxMax,
                           InpHighVolH1Ratio, InpHighVolM15Ratio, InpLowVolRatio, InpTrendMinSlope,
                           (InpRequireH1Structure ? "yes" : "no"), InpRangeMaxSlope, InpRangeMinWidthAtr,
                           InpRangeMaxWidthAtr, InpConfirmEvaluations, InpTesterGmtOffsetMin, (int)InpTesterDstRule));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_csv != INVALID_HANDLE)
     {
      FileClose(g_csv);
      g_csv = INVALID_HANDLE;
     }
   g_market.Deinit();
   g_log.Info("RegimeLogger", "STOP", StringFormat("filas=%s reason=%d", IntegerToString(g_rows), reason));
   g_log.Close();
  }

void OnTick()
  {
   g_market.SampleTickSpread();
   if(!g_market.IsNewBar(PERIOD_M5))
      return;
   g_market.Update(g_snap);
   RegimeState st;
   g_regime.Evaluate(g_snap, st);
   if(!g_snap.valid || g_snap.m5.bars == 0 || ArraySize(g_snap.h1.atr) == 0)
      return;   // sin datos válidos no hay precio/ATR coherentes que registrar
   string line = StringFormat("%s,%s,%s,%.2f,%.4f,%s,%s,%.2f,%.3f,%.3f,%.4f,%s,%s,%.2f,%.2f,%.2f,\"%s\"\r\n",
                              TimeToString(g_snap.server_time, TIME_DATE | TIME_MINUTES),
                              TimeToString(g_snap.utc_time, TIME_DATE | TIME_MINUTES),
                              EnumSessionToString(g_snap.session), g_snap.m5.rates[0].close, g_snap.h1.atr[0],
                              EnumRegimeToString(st.regime), EnumRegimeToString(st.raw_regime), st.h1_adx,
                              st.h1_atr_ratio, st.m15_atr_ratio, st.h1_ema_slope,
                              EnumStructureToString(st.h1_structure), EnumStructureToString(st.m15_structure),
                              st.range_high, st.range_low, g_snap.spread_ratio, Clean(st.reason));
   FileWriteString(g_csv, line);
   g_rows++;
   if(g_rows % 500 == 0)
      FileFlush(g_csv);
  }
