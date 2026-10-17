//+------------------------------------------------------------------+
//| Test_Phase9.mq5                                                  |
//| LearningEngine: SHA-256 igual que Python, carga/verificación del |
//| modelo Champion (aprobación, integridad, lista blanca, valores   |
//| válidos), métricas, diario de operaciones y persistencia.        |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/LearningEngine.mqh>
#include "TestFramework.mqh"

#define MODEL_FILE "XAUUSD/test_champion.model"

void WriteModel(const string body, const string sha)
  {
   FolderCreate("XAUUSD", FILE_COMMON);
   int h = FileOpen(MODEL_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   FileWriteString(h, body + "sha256=" + sha + "\n");
   FileClose(h);
  }

void TestModel(CTestRunner &t)
  {
   string body = "version=v1\napproved=yes\napproved_by=Tester\napproved_at=2026-10-12\nadaptive.min_score=70\n";
   t.True(CLearningEngine::Sha256Hex(body) == "7e40c42c224938bdb08d756d608c0ef0c1ef84773ae17d104e0765c435ede425",
          "SHA-256 idéntico al de Python (hashlib)");
   string keys[], vals[], ver, why;
   FileDelete(MODEL_FILE, FILE_COMMON);
   t.True(!CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why), "sin modelo -> parámetros por defecto: " + why);

   string full = body + "regime.trend_adx_min=24\nstrategy.reversal_enabled=0\n";
   WriteModel(full, CLearningEngine::Sha256Hex(full));
   t.True(CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why), "modelo aprobado e íntegro se carga: " + why);
   t.EqInt(ArraySize(keys), 3, "3 parámetros");
   t.True(ver == "v1", "versión");
   AdaptiveConfig ad; AdaptiveDefaultConfig(ad);
   RegimeConfig rg; RegimeDefaultConfig(rg);
   SMCConfig smc; SMCDefaultConfig(smc);
   BreakoutConfig bo; BreakoutDefaultConfig(bo);
   ReversalConfig rv; ReversalDefaultConfig(rv);
   bool e1 = true, e2 = true, e3 = true;
   t.True(CLearningEngine::ApplyChampion(keys, vals, ad, rg, smc, bo, rv, e1, e2, e3, why), "se aplica: " + why);
   t.EqDbl(ad.min_score, 70, 1e-9, "umbral mínimo 70");
   t.EqDbl(rg.trend_adx_min, 24, 1e-9, "ADX de tendencia 24");
   t.True(e1 && e2 && !e3, "Reversal desactivada por el modelo");

   //--- alterado sin recalcular el hash
   string altered = body + "regime.trend_adx_min=30\nstrategy.reversal_enabled=0\n";
   WriteModel(altered, CLearningEngine::Sha256Hex(full));
   t.True(!CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why) && StringFind(why, "sha256") >= 0,
          "modelo alterado -> rechazado: " + why);
   //--- sin aprobación
   string unapproved = "version=v2\napproved=no\napproved_by=X\napproved_at=2026-10-12\nadaptive.min_score=70\n";
   WriteModel(unapproved, CLearningEngine::Sha256Hex(unapproved));
   t.True(!CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why) && StringFind(why, "aprobación") >= 0,
          "modelo sin aprobación -> rechazado");
   //--- clave de riesgo, aunque el hash sea correcto
   string risky = body + "risk.risk_pct=5\n";
   WriteModel(risky, CLearningEngine::Sha256Hex(risky));
   t.True(!CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why) && StringFind(why, "risk.risk_pct") >= 0,
          "clave de riesgo -> modelo completo rechazado: " + why);
   string exec = body + "execution.max_spread_points=500\n";
   WriteModel(exec, CLearningEngine::Sha256Hex(exec));
   t.True(!CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why), "clave de ejecución -> rechazado");
   //--- valor que deja una configuración inválida: no se aplica nada
   string badval = "version=v3\napproved=yes\napproved_by=T\napproved_at=2026-10-12\nadaptive.min_score=40\nregime.trend_adx_min=25\n";
   WriteModel(badval, CLearningEngine::Sha256Hex(badval));
   t.True(CLearningEngine::LoadChampion(MODEL_FILE, true, keys, vals, ver, why), "modelo con valor inválido se lee");
   AdaptiveDefaultConfig(ad);
   RegimeDefaultConfig(rg);
   t.True(!CLearningEngine::ApplyChampion(keys, vals, ad, rg, smc, bo, rv, e1, e2, e3, why), "pero no se aplica: " + why);
   t.EqDbl(ad.min_score, 65, 1e-9, "configuración intacta tras el rechazo");
   t.EqDbl(rg.trend_adx_min, 22, 1e-9, "ninguna clave aplicada parcialmente");
   FileDelete(MODEL_FILE, FILE_COMMON);
  }

void AddRec(TradeRecord &a[], const double net, const double r, const ENUM_STRATEGY_ID st, const datetime t)
  {
   int n = ArraySize(a);
   ArrayResize(a, n + 1);
   ZeroMemory(a[n]);
   a[n].net = net;
   a[n].r_multiple = r;
   a[n].commission = -1;
   a[n].strategy = st;
   a[n].open_time = t;
   a[n].slippage_points = 2;
  }

void TestStats(CTestRunner &t)
  {
   TradeRecord a[];
   AddRec(a, 200, 2, STRAT_SMC, D'2026.01.12 10:00');      // lunes
   AddRec(a, -100, -1, STRAT_SMC, D'2026.01.13 10:00');
   AddRec(a, -100, -1, STRAT_BREAKOUT, D'2026.01.14 10:00');
   AddRec(a, 300, 3, STRAT_REVERSAL, D'2026.01.15 10:00');
   PerfStats s = CLearningEngine::Compute(a);
   t.EqInt(s.trades, 4, "4 operaciones");
   t.EqDbl(s.net, 300, 1e-9, "neto 300");
   t.EqDbl(s.profit_factor, 2.5, 1e-9, "PF = 500 / 200");
   t.EqDbl(s.win_rate, 0.5, 1e-9, "acierto 50%");
   t.EqDbl(s.expectancy_r, 0.75, 1e-9, "esperanza 0.75R");
   t.EqDbl(s.max_drawdown, 200, 1e-9, "drawdown máximo 200");
   t.EqInt(s.max_loss_streak, 2, "racha de 2 pérdidas");
   t.EqDbl(s.commission, -4, 1e-9, "comisiones");
   t.EqDbl(s.avg_rr_realized, 2.5, 1e-9, "ganancia media 250 / pérdida media 100");
   TradeRecord sub[];
   t.EqInt(CLearningEngine::Filter(a, 0, STRAT_SMC, sub), 2, "filtro por estrategia");
   t.EqInt(CLearningEngine::Filter(a, 3, 1, sub), 1, "filtro por día (lunes)");
   TradeRecord none[];
   t.EqInt(CLearningEngine::Compute(none).trades, 0, "sin operaciones");
  }

void TestJournal(CTestRunner &t)
  {
   CLearningEngine le;
   le.Init("unittest", "TESTSYM", NULL);
   FileDelete(le.TradesFile(), FILE_COMMON);
   TradeSignal sig;
   sig.signal_id = "SIG-1";
   sig.setup_key = "SMC|LONG|x";
   sig.strategy = STRAT_SMC;
   sig.direction = DIR_LONG;
   RiskDecision rd;
   ZeroMemory(rd);
   rd.sl = 2395;
   rd.tp = 2410;
   rd.risk_money = 100;
   ExecutionResult ex;
   ZeroMemory(ex);
   ex.slippage_points = 3;
   le.RecordEntry(777, sig, 82, REGIME_TREND_UP, SESSION_LONDON, rd, ex, 20);
   t.EqInt(le.OpenCount(), 1, "entrada registrada");
   CStateStore st;
   st.Init("XAUUSD/test_le.dat", false);
   le.SaveOpen(st);
   CLearningEngine le2;
   le2.Init("unittest", "TESTSYM", NULL);
   t.EqInt(le2.LoadOpen(st), 1, "contexto de entrada restaurado tras reinicio");
   ClosedTrade c;
   ZeroMemory(c);
   c.identifier = 777;
   c.direction = DIR_LONG;
   c.volume = 0.2;
   c.entry_price = 2400;
   c.exit_price = 2410;
   c.open_time = D'2026.01.14 10:00';
   c.close_time = D'2026.01.14 12:00';
   c.profit = 201.4;
   c.commission = -1.4;
   t.True(le2.RecordClose(c), "cierre escrito en el diario");
   t.EqInt(le2.OpenCount(), 0, "ya no está abierta");
   TradeRecord recs[];
   le2.ClosedRecords(recs);
   t.EqInt(ArraySize(recs), 1, "registro cerrado");
   t.EqDbl(recs[0].net, 200, 1e-9, "neto = beneficio + comisión + swap");
   t.EqDbl(recs[0].r_multiple, 2.0, 1e-9, "R = 200 / 100");
   t.True(recs[0].strategy == STRAT_SMC && recs[0].regime == REGIME_TREND_UP && recs[0].session == SESSION_LONDON,
          "contexto conservado (estrategia, régimen, sesión)");
   int h = FileOpen(le2.TradesFile(), FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   string header = FileReadString(h);
   string row = FileReadString(h);
   FileClose(h);
   t.True(header == LE_TRADES_HEADER, "cabecera del CSV = la que lee challenger.py");
   t.True(StringFind(row, "unittest,777,SIG-1,SMC|LONG|x,SMC,LONG,LONDON,TREND_UP,82.0") == 0, "fila del CSV: " + row);
   //--- cierre sin contexto (posición huérfana)
   ClosedTrade c2 = c;
   c2.identifier = 888;
   le2.RecordClose(c2);
   le2.ClosedRecords(recs);
   t.True(recs[1].strategy == STRAT_NONE && recs[1].r_multiple == 0.0, "huérfana: sin estrategia ni R");
   t.True(le2.WriteReport("XAUUSD/test_report.txt"), "reporte escrito");
   FileDelete(le2.TradesFile(), FILE_COMMON);
   FileDelete("XAUUSD/test_report.txt", FILE_COMMON);
   FileDelete("XAUUSD/test_le.dat");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase9");
   TestModel(t);
   TestStats(t);
   TestJournal(t);
   t.Finish();
  }
