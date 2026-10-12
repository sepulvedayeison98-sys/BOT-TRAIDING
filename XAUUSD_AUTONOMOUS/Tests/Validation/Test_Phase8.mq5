//+------------------------------------------------------------------+
//| Test_Phase8.mq5                                                  |
//| NewsManager: clasificación, ventanas, próximo evento, política   |
//| conservadora (fuente no verificable, desactualizada, fuera de    |
//| cobertura), carga de CSV y calendario no disponible.             |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/NewsManager.mqh>
#include "TestFramework.mqh"

void Add(NewsEvent &ev[], const datetime t, const string name, const int imp)
  {
   int n = ArraySize(ev);
   ArrayResize(ev, n + 1);
   ev[n].time = t;
   ev[n].currency = "USD";
   ev[n].importance = imp;
   ev[n].name = name;
   ev[n].tier = CNewsManager::Classify(name, imp, 3);
  }

void TestClassify(CTestRunner &t)
  {
   t.EqInt(CNewsManager::Classify("Nonfarm Payrolls", 3, 3), NEWS_TIER_MAJOR, "NFP = mayor");
   t.EqInt(CNewsManager::Classify("Core CPI m/m", 3, 3), NEWS_TIER_MAJOR, "CPI = mayor");
   t.EqInt(CNewsManager::Classify("Core PCE Price Index m/m", 3, 3), NEWS_TIER_MAJOR, "PCE = mayor");
   t.EqInt(CNewsManager::Classify("FOMC Meeting Minutes", 2, 3), NEWS_TIER_MAJOR, "FOMC = mayor aunque la importancia sea moderada");
   t.EqInt(CNewsManager::Classify("Fed Interest Rate Decision", 3, 3), NEWS_TIER_MAJOR, "tasas = mayor");
   t.EqInt(CNewsManager::Classify("Fed Chair Powell Speech", 3, 3), NEWS_TIER_MAJOR, "comunicado Fed = mayor");
   t.EqInt(CNewsManager::Classify("Initial Jobless Claims", 2, 3), NEWS_TIER_USD, "empleo moderado = USD");
   t.EqInt(CNewsManager::Classify("ISM Manufacturing PMI", 3, 3), NEWS_TIER_USD, "otro USD de alto impacto = USD");
   t.EqInt(CNewsManager::Classify("ISM Manufacturing PMI", 2, 3), NEWS_TIER_NONE, "otro USD moderado = no bloquea");
   t.EqInt(CNewsManager::Classify("Crude Oil Inventories", 1, 3), NEWS_TIER_NONE, "baja importancia = no bloquea");
  }

//--- evalúa con una carga "reciente" (1 min antes), como haría el refresco periódico en vivo
NewsState EvalFresh(CNewsManager &nm, const NewsEvent &ev[], const datetime now)
  {
   nm.SetEvents(ev, now - 60, true, "TEST");
   return nm.Evaluate(now);
  }

void TestWindows(CTestRunner &t)
  {
   NewsConfig cfg;
   NewsDefaultConfig(cfg);
   CNewsManager nm;
   t.True(nm.Init(cfg, false, NULL), "NewsManager Init");
   NewsEvent ev[];
   Add(ev, D'2026.01.14 15:30', "Core CPI m/m", 3);
   Add(ev, D'2026.01.14 17:00', "ISM Services PMI", 3);
   Add(ev, D'2026.01.14 18:00', "Crude Oil Inventories", 1);
   nm.SetEvents(ev, D'2026.01.14 12:00', true, "TEST");
   NewsState st;
   st = EvalFresh(nm, ev, D'2026.01.14 14:59');
   t.True(!st.blocked && st.source_ok, "31 min antes del CPI: libre");
   t.EqInt(st.minutes_to_next, 31, "minutos al próximo evento");
   t.True(st.next_name == "Core CPI m/m", "próximo evento");
   st = EvalFresh(nm, ev, D'2026.01.14 15:00');
   t.True(st.blocked && StringFind(st.reason, "mayor") >= 0, "30 min antes del CPI: bloqueado");
   st = EvalFresh(nm, ev, D'2026.01.14 16:00');
   t.True(st.blocked, "30 min después del CPI: bloqueado");
   st = EvalFresh(nm, ev, D'2026.01.14 16:01');
   t.True(!st.blocked, "31 min después del CPI: libre");
   st = EvalFresh(nm, ev, D'2026.01.14 16:39');
   t.True(!st.blocked, "21 min antes de ISM: libre");
   st = EvalFresh(nm, ev, D'2026.01.14 16:40');
   t.True(st.blocked && StringFind(st.reason, "USD") >= 0, "20 min antes de evento USD: bloqueado");
   st = EvalFresh(nm, ev, D'2026.01.14 17:21');
   t.True(!st.blocked, "21 min después de evento USD: libre");
   st = EvalFresh(nm, ev, D'2026.01.14 18:00');
   t.True(!st.blocked, "evento de baja importancia no bloquea");

   //--- fuente no verificable / desactualizada / fuera de cobertura
   nm.SetEvents(ev, D'2026.01.14 12:00', false, "TEST");
   st = nm.Evaluate(D'2026.01.14 12:10');
   t.True(st.blocked && !st.source_ok && StringFind(st.reason, "conservadora") >= 0, "fuente no válida -> bloqueo conservador");
   nm.SetEvents(ev, D'2026.01.14 12:00', true, "TEST");
   st = nm.Evaluate(D'2026.01.14 13:01');
   t.True(st.blocked && StringFind(st.reason, "desactualizado") >= 0, "última carga hace 61 min -> bloqueo");
   nm.SetEvents(ev, D'2026.01.14 12:00', true, "TEST");
   nm.SetCoverage(D'2026.01.13 00:00', D'2026.01.14 12:30');
   st = nm.Evaluate(D'2026.01.14 12:40');
   t.True(st.blocked && StringFind(st.reason, "cobertura") >= 0, "fuera de la cobertura -> bloqueo");

   NewsConfig lax = cfg;
   lax.block_if_unverified = false;
   CNewsManager nl;
   nl.Init(lax, false, NULL);
   nl.SetEvents(ev, D'2026.01.14 12:00', false, "TEST");
   st = nl.Evaluate(D'2026.01.14 12:10');
   t.True(!st.blocked && !st.source_ok, "sin política conservadora: informa pero no bloquea");

   CNewsManager not_init;
   t.True(not_init.Evaluate(D'2026.01.14 12:00').blocked, "sin Init: bloqueado");
   NewsConfig bad = cfg;
   bad.major_before_min = 300;
   string why;
   t.True(!NewsValidateConfig(bad, why), "rechaza ventana > 240 min");
  }

void TestCsv(CTestRunner &t)
  {
   NewsConfig cfg;
   NewsDefaultConfig(cfg);
   FolderCreate("XAUUSD", FILE_COMMON);
   string backup = "";
   bool had = FileIsExist(NM_CSV_FILE, FILE_COMMON);
   if(had)
      FileMove(NM_CSV_FILE, FILE_COMMON, NM_CSV_FILE + ".bak", FILE_REWRITE | FILE_COMMON);
   int h = FileOpen(NM_CSV_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   FileWriteString(h, "#range;2025.01.01 00:00;2026.02.01 00:00;2026.01.20 00:00\r\n");
   FileWriteString(h, "time_server;currency;importance;name\r\n");
   FileWriteString(h, "2026.01.09 15:30;USD;3;Nonfarm Payrolls\r\n");
   FileWriteString(h, "2026.01.14 15:30;USD;3;Core CPI m/m\r\n");
   FileWriteString(h, "2026.01.14 18:00;USD;1;Crude Oil Inventories\r\n");
   FileClose(h);
   CNewsManager nm;
   nm.Init(cfg, true, NULL);
   nm.Refresh(D'2026.01.09 12:00');
   t.EqInt(nm.EventCount(), 2, "CSV: 2 eventos relevantes (el de baja importancia se ignora)");
   t.True(nm.Evaluate(D'2026.01.09 15:10').blocked, "CSV: bloqueo por NFP en el tester");
   t.True(!nm.Evaluate(D'2026.01.12 10:00').blocked, "CSV: día sin eventos libre (sin control de antigüedad en el tester)");
   t.True(nm.Evaluate(D'2026.03.01 10:00').blocked, "CSV: fecha fuera del rango exportado -> bloqueo conservador");

   h = FileOpen(NM_CSV_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   FileWriteString(h, "time_server;currency;importance;name\r\n2026.01.14 15:30;USD;3;Core CPI m/m\r\n");
   FileClose(h);
   CNewsManager n2;
   n2.Init(cfg, true, NULL);
   n2.Refresh(D'2026.01.09 12:00');
   t.True(n2.Evaluate(D'2026.01.12 10:00').blocked, "CSV sin #range -> bloqueo conservador");
   FileDelete(NM_CSV_FILE, FILE_COMMON);
   CNewsManager n3;
   n3.Init(cfg, true, NULL);
   n3.Refresh(D'2026.01.09 12:00');
   t.True(n3.Evaluate(D'2026.01.12 10:00').blocked, "sin CSV en el tester -> bloqueo conservador");
   if(had)
      FileMove(NM_CSV_FILE + ".bak", FILE_COMMON, NM_CSV_FILE, FILE_REWRITE | FILE_COMMON);

   //--- en vivo sin conexión el calendario no es verificable
   CNewsManager live;
   live.Init(cfg, false, NULL);
   live.Refresh(TimeTradeServer());
   NewsState st = live.Evaluate(TimeTradeServer());
   t.True(st.blocked, "terminal sin conexión: calendario no verificable -> bloqueo (" + st.reason + ")");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase8");
   TestClassify(t);
   TestWindows(t);
   TestCsv(t);
   t.Finish();
  }
