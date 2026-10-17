//+------------------------------------------------------------------+
//| Test_Phase7.mq5                                                  |
//| ExecutionManager y PositionManager contra un servidor simulado:  |
//| éxito, recotizaciones, resultados inciertos (sin reintento +     |
//| reconciliación), rechazos, validaciones previas, break-even,     |
//| trailing, invariante del SL, stops/freeze level, posición sin    |
//| SL, invalidación, fallos repetidos, persistencia y rachas.       |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/ExecutionManager.mqh>
#include <XAUUSD/PositionManager.mqh>
#include "TestFramework.mqh"
#include "TestSnapshots.mqh"
#include "FakeGateway.mqh"

#define MAGIC 26101201

void Spec(SymbolSpec &s)
  {
   s.name = "XAUUSD";
   s.digits = 2;
   s.point = 0.01;
   s.tick_size = 0.01;
   s.tick_value_loss = 1.0;
   s.contract_size = 100;
   s.volume_min = 0.01;
   s.volume_max = 50;
   s.volume_step = 0.01;
   s.volume_limit = 0;
   s.stops_level = 0;
   s.freeze_level = 0;
  }

RiskDecision Decision(const ENUM_DIRECTION d)
  {
   RiskDecision r;
   ZeroMemory(r);
   r.approved = true;
   r.direction = d;
   r.entry = (d == DIR_LONG) ? 2400.20 : 2400.00;
   r.sl = (d == DIR_LONG) ? 2395.20 : 2405.00;
   r.tp = (d == DIR_LONG) ? 2410.20 : 2390.00;
   r.volume = 0.20;
   return r;
  }

TradeSignal Signal(const string id)
  {
   TradeSignal g;
   g.signal_id = id;
   g.setup_key = "KEY-" + id;
   g.strategy = STRAT_SMC;
   g.invalidation = 2395.50;
   g.reason = "test";
   return g;
  }

void TestExecution(CTestRunner &t)
  {
   SymbolSpec spec;
   Spec(spec);
   ExecutionConfig cfg;
   ExecutionDefaultConfig(cfg);
   long pid;
   double fill;

   //--- éxito
     {
      CFakeGateway gw;
      CExecutionManager ex;
      t.True(ex.Init("XAUUSD", cfg, &gw, NULL), "ExecutionManager Init");
      gw.fill_offset = 0.05;
      ExecutionResult r = ex.Execute(Decision(DIR_LONG), Signal("S1"), spec);
      t.EqInt(r.status, EXEC_DONE, "ejecución aceptada: " + r.message);
      t.EqInt(gw.checks, 1, "OrderCheck antes de OrderSend");
      t.EqInt(gw.sends, 1, "un solo envío");
      t.EqDbl(r.slippage_points, 5.0, 1e-6, "slippage 0.05 = 5 puntos en contra");
      t.True(gw.last.type == ORDER_TYPE_BUY && gw.last.volume == 0.20 && gw.last.sl == 2395.20 && gw.last.tp == 2410.20,
             "solicitud con tipo, volumen, SL y TP correctos");
      t.True(gw.last.magic == MAGIC && gw.last.comment == CExecutionManager::CommentFor("S1"), "magic y comentario");
      t.True(gw.last.type_filling == ORDER_FILLING_FOK, "filling según el símbolo");
      t.True(ex.HasPending(), "queda pendiente hasta ver la posición");
      ExecutionResult r2 = ex.Execute(Decision(DIR_LONG), Signal("S2"), spec);
      t.EqInt(r2.status, EXEC_SKIPPED, "con solicitud pendiente no se envía otra (anti-duplicado)");
      t.EqInt(ex.Reconcile(pid, fill), 1, "reconciliación encuentra la posición");
      t.True(pid > 0 && !ex.HasPending(), "pendiente resuelta");
     }
   //--- recotización y reintento
     {
      CFakeGateway gw;
      CExecutionManager ex;
      ex.Init("XAUUSD", cfg, &gw, NULL);
      gw.Queue(TRADE_RETCODE_REQUOTE);
      ExecutionResult r = ex.Execute(Decision(DIR_LONG), Signal("S3"), spec);
      t.EqInt(r.status, EXEC_DONE, "recotización -> reintento -> éxito");
      t.EqInt(r.attempts, 2, "2 intentos");
     }
   //--- recotizaciones agotadas
     {
      CFakeGateway gw;
      CExecutionManager ex;
      ex.Init("XAUUSD", cfg, &gw, NULL);
      gw.Queue(TRADE_RETCODE_REQUOTE); gw.Queue(TRADE_RETCODE_PRICE_CHANGED); gw.Queue(TRADE_RETCODE_REQUOTE);
      ExecutionResult r = ex.Execute(Decision(DIR_LONG), Signal("S4"), spec);
      t.EqInt(r.status, EXEC_REJECTED, "3 recotizaciones con máximo 2 reintentos -> rechazo");
      t.EqInt(gw.sends, 3, "exactamente 1 + 2 envíos");
      t.True(!ex.HasPending() && ArraySize(gw.positions) == 0, "sin pendiente ni posición");
     }
   //--- incierto con ejecución real: no se reintenta y se reconcilia
     {
      CFakeGateway gw;
      CExecutionManager ex;
      ex.Init("XAUUSD", cfg, &gw, NULL);
      gw.exec_on_uncertain = true;
      gw.Queue(TRADE_RETCODE_TIMEOUT);
      ExecutionResult r = ex.Execute(Decision(DIR_LONG), Signal("S5"), spec);
      t.EqInt(r.status, EXEC_UNCERTAIN, "timeout -> incierto");
      t.EqInt(gw.sends, 1, "NO se reintenta con estado incierto");
      t.True(ex.HasPending(), "queda pendiente");
      t.EqInt(ArraySize(gw.positions), 1, "(el servidor sí abrió la posición)");
      t.EqInt(ex.Reconcile(pid, fill), 1, "reconciliación descubre la posición abierta");
     }
   //--- incierto sin ejecución: bloqueo hasta el timeout de reconciliación
     {
      CFakeGateway gw;
      CExecutionManager ex;
      ex.Init("XAUUSD", cfg, &gw, NULL);
      gw.Queue(TRADE_RETCODE_CONNECTION);
      ExecutionResult r = ex.Execute(Decision(DIR_LONG), Signal("S6"), spec);
      t.EqInt(r.status, EXEC_UNCERTAIN, "sin conexión -> incierto");
      t.EqInt(ex.Reconcile(pid, fill), -1, "sin rastro y sin timeout -> sigue sin resolver");
      gw.order_in_process = true;
      gw.now += 200;
      t.EqInt(ex.Reconcile(pid, fill), -1, "orden aún en proceso -> sin resolver aunque pase el tiempo");
      gw.order_in_process = false;
      t.EqInt(ex.Reconcile(pid, fill), 0, "sin rastro tras el timeout -> no ejecutada");
      t.True(!ex.HasPending(), "se libera el bloqueo");
     }
   //--- comentario alterado por el bróker
     {
      CFakeGateway gw;
      CExecutionManager ex;
      ex.Init("XAUUSD", cfg, &gw, NULL);
      gw.alter_comment = true;
      ex.Execute(Decision(DIR_SHORT), Signal("S7"), spec);
      t.EqInt(ex.Reconcile(pid, fill), 1, "reconciliación por dirección/volumen/hora si el comentario cambió");
     }
   //--- rechazos y validaciones previas
     {
      CFakeGateway gw;
      CExecutionManager ex;
      ex.Init("XAUUSD", cfg, &gw, NULL);
      gw.Queue(TRADE_RETCODE_NO_MONEY);
      ExecutionResult r = ex.Execute(Decision(DIR_LONG), Signal("S8"), spec);
      t.True(r.status == EXEC_REJECTED && !ex.HasPending() && gw.sends == 1, "sin dinero -> rechazo sin reintento");
      gw.check_code = TRADE_RETCODE_INVALID_STOPS;
      int before = gw.sends;
      r = ex.Execute(Decision(DIR_LONG), Signal("S9"), spec);
      t.True(r.status == EXEC_REJECTED && gw.sends == before, "OrderCheck rechaza -> no se envía");
      gw.check_code = 0;
      gw.SetPrice(2400.00, 2400.80);
      r = ex.Execute(Decision(DIR_LONG), Signal("S10"), spec);
      t.True(r.status == EXEC_SKIPPED && StringFind(r.message, "spread") >= 0, "spread 80 > 60 -> no se envía");
      gw.SetPrice(2401.00, 2401.20);
      r = ex.Execute(Decision(DIR_LONG), Signal("S11"), spec);
      t.True(r.status == EXEC_SKIPPED && StringFind(r.message, "alejó") >= 0, "precio 100 puntos en contra -> no se envía");
      gw.SetPrice(2400.00, 2400.20);
      gw.open = false;
      r = ex.Execute(Decision(DIR_LONG), Signal("S12"), spec);
      t.EqInt(r.status, EXEC_SKIPPED, "mercado cerrado -> no se envía");
      gw.open = true;
      gw.allowed = false;
      r = ex.Execute(Decision(DIR_LONG), Signal("S13"), spec);
      t.EqInt(r.status, EXEC_SKIPPED, "trading no permitido -> no se envía");
      gw.allowed = true;
      RiskDecision bad = Decision(DIR_LONG);
      bad.volume = 0.205;
      r = ex.Execute(bad, Signal("S14"), spec);
      t.True(r.status == EXEC_SKIPPED && StringFind(r.message, "múltiplo") >= 0, "volumen fuera del paso -> no se envía");
      bad = Decision(DIR_LONG);
      bad.approved = false;
      r = ex.Execute(bad, Signal("S15"), spec);
      t.EqInt(r.status, EXEC_SKIPPED, "decisión no aprobada -> no se envía");
      gw.filling = SYMBOL_FILLING_IOC;
      ex.Execute(Decision(DIR_LONG), Signal("S16"), spec);
      t.True(gw.last.type_filling == ORDER_FILLING_IOC, "filling IOC si FOK no está permitido");
     }
   //--- clasificación
   t.EqInt(CExecutionManager::Classify(TRADE_RETCODE_DONE, true), RC_SUCCESS, "DONE = éxito");
   t.EqInt(CExecutionManager::Classify(TRADE_RETCODE_PLACED, true), RC_SUCCESS, "PLACED = éxito");
   t.EqInt(CExecutionManager::Classify(TRADE_RETCODE_REQUOTE, false), RC_RETRYABLE, "REQUOTE = reintentable");
   t.EqInt(CExecutionManager::Classify(TRADE_RETCODE_TIMEOUT, false), RC_UNCERTAIN, "TIMEOUT = incierto");
   t.EqInt(CExecutionManager::Classify(0, false), RC_UNCERTAIN, "sin código = incierto");
   t.EqInt(CExecutionManager::Classify(TRADE_RETCODE_MARKET_CLOSED, false), RC_REJECTED, "MARKET_CLOSED = rechazo");
   t.True(CExecutionManager::CommentFor("abc") == CExecutionManager::CommentFor("abc") &&
          CExecutionManager::CommentFor("abc") != CExecutionManager::CommentFor("abd") &&
          StringLen(CExecutionManager::CommentFor("abc")) <= 24, "comentario estable, distinto por señal y corto");
  }

void Snap(MarketSnapshot &s, const double m15_close, const double atr5)
  {
   double arr[];
   ArrayResize(arr, 40);
   for(int i = 0; i < 10; i++)
     {
      arr[4 * i] = m15_close; arr[4 * i + 1] = m15_close + 0.5; arr[4 * i + 2] = m15_close - 0.5; arr[4 * i + 3] = m15_close;
     }
   BuildTF(s.m15, PERIOD_M15, arr, 2.0, 2, T_M15_LAST, m15_close, 0);
   BuildTF(s.m5, PERIOD_M5, arr, atr5, 3, T_M5_LAST, m15_close, 0);
   BuildH1Flat(s.h1, m15_close, 0);
   FinishSnapshot(s);
  }

double SLof(CFakeGateway &gw) { return ArraySize(gw.positions) > 0 ? gw.positions[0].sl : -1; }

void TestPositions(CTestRunner &t)
  {
   SymbolSpec spec;
   Spec(spec);
   PositionConfig cfg;
   PositionDefaultConfig(cfg);
   MarketSnapshot s;
   Snap(s, 2401.0, 1.0);

   //--- break-even y trailing (compra; entrada 2400, SL inicial 2395 -> R = 5)
     {
      CFakeGateway gw;
      CPositionManager pm;
      t.True(pm.Init("XAUUSD", cfg, &gw, NULL), "PositionManager Init");
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 2395.0, 2410.0, "XA|1", MAGIC);
      PendingRequest p;
      ZeroMemory(p);
      p.signal_id = "SIG"; p.setup_key = "KEY"; p.strategy = STRAT_SMC; p.initial_sl = 2395.0; p.invalidation = 2390.0;
      pm.RegisterPosition(gw.positions[0].identifier, p);
      gw.SetPrice(2404.0, 2404.2);                  // 0.8R
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2395.0, 1e-9, "0.8R: sin cambios");
      gw.SetPrice(2405.1, 2405.3);                  // 1.02R
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2400.30, 1e-9, "1R: break-even = entrada + (10 + spread 20) puntos");
      PositionMeta m;
      t.True(pm.GetMeta(gw.positions[0].identifier, m) && m.be_done, "break-even registrado");
      gw.SetPrice(2408.0, 2408.2);                  // 1.6R
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2406.50, 1e-9, "1.6R: trailing = 2408 - 1.5 x ATR M5 1.0");
      gw.SetPrice(2407.0, 2407.2);                  // retroceso
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2406.50, 1e-9, "retroceso: el SL nunca se aleja");
      gw.SetPrice(2410.0, 2410.2);
      Snap(s, 2401.0, 1.0);
      pm.Manage(s, false, spec);
      t.EqDbl(SLof(gw), 2406.50, 1e-9, "sin datos válidos: no hay trailing por ATR (solo break-even)");
     }
   //--- venta en espejo
     {
      CFakeGateway gw;
      CPositionManager pm;
      pm.Init("XAUUSD", cfg, &gw, NULL);
      gw.AddPosition(DIR_SHORT, 0.2, 2400.0, 2405.0, 2390.0, "XA|2", MAGIC);
      gw.SetPrice(2394.7, 2394.9);                  // ask 2394.9 -> 1.02R
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2399.70, 1e-9, "venta 1R: break-even = entrada - 30 puntos");
      gw.SetPrice(2391.8, 2392.0);                  // 1.6R
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2393.50, 1e-9, "venta trailing = 2392.0 + 1.5");
     }
   //--- stops level y freeze level
     {
      CFakeGateway gw;
      CPositionManager pm;
      pm.Init("XAUUSD", cfg, &gw, NULL);
      SymbolSpec st = spec;
      st.stops_level = 300;
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 2395.0, 2420.0, "XA|3", MAGIC);
      gw.SetPrice(2408.0, 2408.2);
      pm.Manage(s, true, st);
      t.EqDbl(SLof(gw), 2404.99, 1e-9, "trailing limitado por stops level (2408 - 3.00 - 0.01)");
      SymbolSpec fz = spec;
      fz.freeze_level = 1500;
      gw.positions[0].sl = 2395.0;
      int before = gw.sends;
      pm.Manage(s, true, fz);
      t.True(gw.sends == before && SLof(gw) == 2395.0, "dentro del freeze level: no se modifica");
     }
   //--- posición sin SL y huérfana
     {
      CFakeGateway gw;
      CPositionManager pm;
      pm.Init("XAUUSD", cfg, &gw, NULL);
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 0.0, 0.0, "manual", MAGIC);
      gw.SetPrice(2400.5, 2400.7);
      pm.Manage(s, true, spec);
      t.EqDbl(SLof(gw), 2396.0, 1e-9, "SL protector = entrada - 2 x ATR M15 (2.0)");
      t.True(pm.CriticalFlag(), "posición sin SL -> crítico (modo seguro)");
      PositionMeta m;
      t.True(pm.GetMeta(gw.positions[0].identifier, m) && m.orphan, "adoptada como huérfana");
     }
   //--- invalidación estructural
     {
      CFakeGateway gw;
      CPositionManager pm;
      pm.Init("XAUUSD", cfg, &gw, NULL);
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 2395.0, 2410.0, "XA|4", MAGIC);
      PendingRequest p;
      ZeroMemory(p);
      p.initial_sl = 2395.0; p.invalidation = 2398.0; p.signal_id = "S"; p.setup_key = "K";
      pm.RegisterPosition(gw.positions[0].identifier, p);
      Snap(s, 2397.5, 1.0);
      gw.SetPrice(2397.6, 2397.8);
      pm.Manage(s, true, spec);
      t.EqInt(ArraySize(gw.positions), 0, "cierre M15 bajo la invalidación -> posición cerrada");
      Snap(s, 2401.0, 1.0);
     }
   //--- fallos repetidos al modificar
     {
      CFakeGateway gw;
      CPositionManager pm;
      pm.Init("XAUUSD", cfg, &gw, NULL);
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 2395.0, 2410.0, "XA|5", MAGIC);
      gw.SetPrice(2405.5, 2405.7);
      gw.Queue(TRADE_RETCODE_REJECT); gw.Queue(TRADE_RETCODE_REJECT); gw.Queue(TRADE_RETCODE_REJECT);
      pm.Manage(s, true, spec);
      t.True(!pm.CriticalFlag(), "1 fallo: aún no crítico");
      pm.Manage(s, true, spec);
      pm.Manage(s, true, spec);
      t.True(pm.CriticalFlag(), "3 fallos seguidos al modificar el SL -> crítico");
     }
   //--- trailing por pivote M5
     {
      CFakeGateway gw;
      PositionConfig cs = cfg;
      cs.trail_mode = PM_TRAIL_SWING;
      CPositionManager pm;
      pm.Init("XAUUSD", cs, &gw, NULL);
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 2395.0, 2420.0, "XA|6", MAGIC);
      MarketSnapshot sw;
      Snap(sw, 2401.0, 1.0);
      ArrayResize(sw.m5.swings, 2);
      sw.m5.swing_count = 2;
      sw.m5.swings[0].is_high = true;  sw.m5.swings[0].price = 2409.0;
      sw.m5.swings[1].is_high = false; sw.m5.swings[1].price = 2406.0;
      gw.SetPrice(2408.0, 2408.2);
      pm.Manage(sw, true, spec);
      t.EqDbl(SLof(gw), 2405.80, 1e-9, "trailing bajo el último pivote bajo M5 (2406 - 0.2 x ATR)");
     }
   //--- persistencia, cierre total y racha de pérdidas
     {
      CFakeGateway gw;
      CPositionManager pm;
      pm.Init("XAUUSD", cfg, &gw, NULL);
      gw.AddPosition(DIR_LONG, 0.2, 2400.0, 2395.0, 2410.0, "XA|7", MAGIC);
      gw.AddPosition(DIR_SHORT, 0.1, 2402.0, 2407.0, 2392.0, "XA|8", MAGIC);
      gw.AddPosition(DIR_SHORT, 0.1, 2402.0, 2407.0, 2392.0, "otro EA", MAGIC + 1);
      PendingRequest p;
      ZeroMemory(p);
      p.signal_id = "SIGP"; p.setup_key = "KEYP"; p.strategy = STRAT_BREAKOUT; p.initial_sl = 2395.0; p.invalidation = 2397.0;
      pm.RegisterPosition(gw.positions[0].identifier, p);
      PositionInfo pos[];
      t.EqInt(pm.Sync(pos), 2, "solo cuenta posiciones con su magic");
      CStateStore st;
      st.Init("XAUUSD/test_pm.dat", false);
      pm.SaveMeta(st);
      CPositionManager pm2;
      pm2.Init("XAUUSD", cfg, &gw, NULL);
      t.EqInt(pm2.LoadMeta(st), 2, "metadatos restaurados");
      PositionMeta m;
      t.True(pm2.GetMeta(gw.positions[0].identifier, m) && m.setup_key == "KEYP" && m.strategy == STRAT_BREAKOUT &&
             m.invalidation == 2397.0, "metadatos íntegros tras reiniciar");
      PositionBrief br[];
      pm2.Briefs(pos, br);
      t.True(br[0].setup_key == "KEYP" || br[1].setup_key == "KEYP", "resumen incluye la clave del setup");
      PositionRisk rk[];
      CPositionManager::Risks(pos, rk);
      t.EqInt(ArraySize(rk), 2, "riesgos para el RiskManager");
      t.EqInt(pm2.CloseAll(spec, "prueba"), 2, "cierre total de las posiciones propias");
      t.EqInt(ArraySize(gw.positions), 1, "la posición de otro EA no se toca");
      gw.AddClosed(50, D'2026.01.10 10:00');
      gw.AddClosed(-30, D'2026.01.11 10:00');
      gw.AddClosed(-20, D'2026.01.12 10:00');
      gw.AddClosed(-10, D'2026.01.13 10:00');
      t.EqInt(pm2.ConsecutiveLosses(D'2026.01.01', D'2026.01.31'), 3, "racha de 3 pérdidas");
      gw.AddClosed(0.5, D'2026.01.09 10:00');
      t.EqInt(pm2.ConsecutiveLosses(D'2026.01.01', D'2026.01.31'), 3, "orden por fecha de cierre");
      gw.AddClosed(0.5, D'2026.01.14 10:00');
      t.EqInt(pm2.ConsecutiveLosses(D'2026.01.01', D'2026.01.31'), 4, "comisión incluida: +0.5 - 0.7 = pérdida que alarga la racha");
      gw.AddClosed(5.0, D'2026.01.15 10:00');
      t.EqInt(pm2.ConsecutiveLosses(D'2026.01.01', D'2026.01.31'), 0, "una ganancia neta corta la racha");
      FileDelete("XAUUSD/test_pm.dat");
     }
   PositionConfig bad = cfg;
   bad.trail_start_r = 0.5;
   string why;
   t.True(!PositionValidateConfig(bad, why), "rechaza trailing antes del break-even");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase7");
   TestExecution(t);
   TestPositions(t);
   t.Finish();
  }
