//+------------------------------------------------------------------+
//| Test_Phase2.mq5                                                  |
//| Pruebas unitarias de la Fase 2: SessionClock, algoritmos de      |
//| MarketEngine y Logger. Usa datos sintéticos: no requiere         |
//| conexión ni historial del bróker.                                |
//| Resultado: pestaña Expertos + MQL5/Files/XAUUSD/reports/         |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include "TestFramework.mqh"

//--- utilidades ---------------------------------------------------------
datetime D(const int y, const int mo, const int d, const int h = 0, const int mi = 0)
  {
   return CTimeRules::MakeDate(y, mo, d, h, mi);
  }

void SetBar(MqlRates &r, const datetime t, const double o, const double h, const double l,
            const double c, const int spread = 0)
  {
   r.time = t;
   r.open = o;
   r.high = h;
   r.low = l;
   r.close = c;
   r.tick_volume = 100;
   r.real_volume = 0;
   r.spread = spread;
  }

//--- construye una serie (índice 0 = más reciente) a partir de highs; low = high - 1
void BuildSeries(const double &highs[], MqlRates &r[])
  {
   int n = ArraySize(highs);
   ArrayResize(r, n);
   datetime t0 = D(2026, 1, 14, 12, 0);
   for(int i = 0; i < n; i++)
      SetBar(r[i], t0 - i * 300, highs[i] - 0.5, highs[i], highs[i] - 1.0, highs[i] - 0.5);
  }

//--- CTimeRules ---------------------------------------------------------
void TestCalendarRules(CTestRunner &t)
  {
   // Referencias calculadas de forma independiente (Python calendar)
   int years[4]     = {2024, 2025, 2026, 2027};
   int uk_mar[4]    = {31, 30, 29, 28};
   int uk_oct[4]    = {27, 26, 25, 31};
   int us_mar[4]    = {10, 9, 8, 14};
   int us_nov[4]    = {3, 2, 1, 7};
   for(int i = 0; i < 4; i++)
     {
      t.EqInt(CTimeRules::LastSunday(years[i], 3), uk_mar[i], StringFormat("último domingo marzo %d", years[i]));
      t.EqInt(CTimeRules::LastSunday(years[i], 10), uk_oct[i], StringFormat("último domingo octubre %d", years[i]));
      t.EqInt(CTimeRules::NthSunday(years[i], 3, 2), us_mar[i], StringFormat("2.º domingo marzo %d", years[i]));
      t.EqInt(CTimeRules::NthSunday(years[i], 11, 1), us_nov[i], StringFormat("1.er domingo noviembre %d", years[i]));
     }
   t.EqInt(CTimeRules::DaysInMonth(2024, 2), 29, "febrero bisiesto 2024");
   t.EqInt(CTimeRules::DaysInMonth(2026, 2), 28, "febrero 2026");
   t.EqInt(CTimeRules::DaysInMonth(2026, 12), 31, "diciembre 2026");

   // Transiciones UE/UK 2026 (01:00 UTC)
   t.True(!CTimeRules::IsEuDstUtc(D(2026, 3, 29, 0, 59)), "UE: sin DST 29-mar-2026 00:59 UTC");
   t.True(CTimeRules::IsEuDstUtc(D(2026, 3, 29, 1, 0)), "UE: DST 29-mar-2026 01:00 UTC");
   t.True(CTimeRules::IsEuDstUtc(D(2026, 10, 25, 0, 59)), "UE: DST 25-oct-2026 00:59 UTC");
   t.True(!CTimeRules::IsEuDstUtc(D(2026, 10, 25, 1, 0)), "UE: sin DST 25-oct-2026 01:00 UTC");
   // Transiciones EE. UU. 2026
   t.True(!CTimeRules::IsUsDstUtc(D(2026, 3, 8, 6, 59)), "US: sin DST 8-mar-2026 06:59 UTC");
   t.True(CTimeRules::IsUsDstUtc(D(2026, 3, 8, 7, 0)), "US: DST 8-mar-2026 07:00 UTC");
   t.True(CTimeRules::IsUsDstUtc(D(2026, 11, 1, 5, 59)), "US: DST 1-nov-2026 05:59 UTC");
   t.True(!CTimeRules::IsUsDstUtc(D(2026, 11, 1, 6, 0)), "US: sin DST 1-nov-2026 06:00 UTC");

   t.EqInt(CTimeRules::RoundOffset(7190, 900), 7200, "redondeo offset +2h");
   t.EqInt(CTimeRules::RoundOffset(-17990, 900), -18000, "redondeo offset -5h");
   t.EqInt(CTimeRules::RoundOffset(19800, 900), 19800, "offset +5:30 se conserva");

   // Ventana que cruza medianoche (miércoles)
   t.True(CTimeRules::InWindow(D(2026, 1, 14, 23, 0), 22 * 60, 2 * 60), "ventana nocturna 23:00");
   t.True(!CTimeRules::InWindow(D(2026, 1, 14, 3, 0), 22 * 60, 2 * 60), "ventana nocturna 03:00");
   t.True(!CTimeRules::InWindow(D(2026, 1, 17, 10, 0), 0, 1439), "sábado fuera de ventana");
  }

//--- CSessionClock ------------------------------------------------------
void TestSessions(CTestRunner &t)
  {
   SessionClockConfig cfg;
   SessionClockDefaultConfig(cfg);
   cfg.tester_std_offset_sec = 2 * 3600;
   cfg.tester_dst_rule = DST_RULE_US;
   CSessionClock clk;
   t.True(clk.Init(cfg, true), "SessionClock Init (modo tester)");

   // Invierno: Londres 08:00 = 08:00 UTC; cierre 16:30
   t.True(clk.IsLondonOpenUtc(D(2026, 1, 14, 8, 0)), "Londres abre 08:00 UTC en invierno");
   t.True(!clk.IsLondonOpenUtc(D(2026, 1, 14, 7, 59)), "Londres cerrado 07:59 UTC en invierno");
   t.True(clk.IsLondonOpenUtc(D(2026, 1, 14, 16, 29)), "Londres abierto 16:29 UTC en invierno");
   t.True(!clk.IsLondonOpenUtc(D(2026, 1, 14, 16, 30)), "Londres cerrado 16:30 UTC en invierno");
   // Verano: Londres 08:00 BST = 07:00 UTC
   t.True(clk.IsLondonOpenUtc(D(2026, 7, 15, 7, 0)), "Londres abre 07:00 UTC en verano");
   t.True(!clk.IsLondonOpenUtc(D(2026, 7, 15, 6, 59)), "Londres cerrado 06:59 UTC en verano");
   // Nueva York invierno: 08:00 EST = 13:00 UTC; cierre 17:00 EST = 22:00 UTC
   t.True(clk.IsNewYorkOpenUtc(D(2026, 1, 14, 13, 0)), "NY abre 13:00 UTC en invierno");
   t.True(!clk.IsNewYorkOpenUtc(D(2026, 1, 14, 12, 59)), "NY cerrado 12:59 UTC en invierno");
   t.True(clk.IsNewYorkOpenUtc(D(2026, 1, 14, 21, 59)), "NY abierto 21:59 UTC en invierno");
   t.True(!clk.IsNewYorkOpenUtc(D(2026, 1, 14, 22, 0)), "NY cerrado 22:00 UTC en invierno");
   // Nueva York verano: 08:00 EDT = 12:00 UTC
   t.True(clk.IsNewYorkOpenUtc(D(2026, 7, 15, 12, 0)), "NY abre 12:00 UTC en verano");
   // Semana en que EE. UU. ya cambió y UK no (10-mar-2026)
   t.EqInt(clk.SessionAtUtc(D(2026, 3, 10, 12, 0)), SESSION_OVERLAP, "solape 12:00 UTC 10-mar-2026");
   t.EqInt(clk.SessionAtUtc(D(2026, 3, 10, 16, 30)), SESSION_NEWYORK, "solo NY 16:30 UTC 10-mar-2026");
   t.EqInt(clk.SessionAtUtc(D(2026, 3, 10, 9, 0)), SESSION_LONDON, "solo Londres 09:00 UTC 10-mar-2026");
   t.EqInt(clk.SessionAtUtc(D(2026, 1, 17, 10, 0)), SESSION_NONE, "sábado sin sesión");
   t.EqInt(clk.SessionAtUtc(D(2026, 1, 14, 3, 0)), SESSION_NONE, "madrugada sin sesión");

   // Conversión servidor <-> UTC con offset +2 y regla US
   t.EqTime(clk.UtcToServer(D(2026, 1, 14, 10, 0)), D(2026, 1, 14, 12, 0), "UTC->servidor invierno (+2)");
   t.EqTime(clk.UtcToServer(D(2026, 7, 15, 10, 0)), D(2026, 7, 15, 13, 0), "UTC->servidor verano (+3)");
   t.EqTime(clk.ServerToUtc(D(2026, 7, 15, 13, 0)), D(2026, 7, 15, 10, 0), "servidor->UTC verano");
   t.EqTime(clk.ServerToUtc(D(2026, 1, 14, 12, 0)), D(2026, 1, 14, 10, 0), "servidor->UTC invierno");
   t.EqTime(CSessionClock::UtcToColombia(D(2026, 7, 15, 10, 0)), D(2026, 7, 15, 5, 0), "UTC->Colombia (sin DST)");

   // Configuraciones inválidas
   SessionClockConfig bad = cfg;
   bad.london_open_min = 1500;
   CSessionClock c2;
   t.True(!c2.Init(bad, true), "rechaza ventana de sesión inválida");
   bad = cfg;
   bad.tester_std_offset_sec = 100;
   t.True(!c2.Init(bad, true), "rechaza offset no múltiplo de 15 min");
  }

//--- CMarketAlgo --------------------------------------------------------
void TestMarketAlgo(CTestRunner &t)
  {
   string reason;
   MqlRates r[];
   double highs[11] = {10, 11, 12, 11, 10, 11, 13, 12, 11, 10, 9};
   BuildSeries(highs, r);
   t.True(CMarketAlgo::ValidateRates(r, 11, reason), "ValidateRates acepta serie válida");

   SwingPoint sw[];
   int n = CMarketAlgo::FindSwings(r, 11, 2, 30, sw);
   t.EqInt(n, 3, "FindSwings encuentra 3 pivotes");
   if(n == 3)
     {
      t.True(sw[0].is_high && sw[0].bar_index == 2 && sw[0].price == 12.0, "pivote alto en índice 2");
      t.True(!sw[1].is_high && sw[1].bar_index == 4 && sw[1].price == 9.0, "pivote bajo en índice 4");
      t.True(sw[2].is_high && sw[2].bar_index == 6 && sw[2].price == 13.0, "pivote alto en índice 6");
     }
   // No repintado: un máximo en la última vela cerrada no es pivote (falta confirmación)
   double highs2[11] = {20, 11, 12, 11, 10, 11, 13, 12, 11, 10, 9};
   BuildSeries(highs2, r);
   n = CMarketAlgo::FindSwings(r, 11, 2, 30, sw);
   bool any_unconfirmed = false;
   for(int i = 0; i < n; i++)
      if(sw[i].bar_index < 2)
         any_unconfirmed = true;
   t.True(!any_unconfirmed, "sin pivotes en velas no confirmadas (índice < N)");
   // Máximos iguales no son pivote (comparación estricta)
   double highs3[7] = {10, 11, 12, 12, 11, 10, 9};
   BuildSeries(highs3, r);
   n = CMarketAlgo::FindSwings(r, 7, 2, 30, sw);
   bool eq_pivot = false;
   for(int i = 0; i < n; i++)
      if(sw[i].is_high)
         eq_pivot = true;
   t.True(!eq_pivot, "máximos iguales no generan pivote");
   t.EqInt(CMarketAlgo::FindSwings(r, 4, 2, 30, sw), 0, "serie demasiado corta: 0 pivotes");

   // Validación de velas inválidas
   BuildSeries(highs, r);
   r[3].low = r[3].high + 1.0;
   t.True(!CMarketAlgo::ValidateRates(r, 11, reason), "ValidateRates rechaza high < low");
   BuildSeries(highs, r);
   r[5].time = r[4].time + 60;
   t.True(!CMarketAlgo::ValidateRates(r, 11, reason), "ValidateRates rechaza orden temporal");
   BuildSeries(highs, r);
   r[0].close = 0.0;
   t.True(!CMarketAlgo::ValidateRates(r, 11, reason), "ValidateRates rechaza precio 0");

   // Estructura
   SwingPoint s[4];
   s[0].is_high = true;  s[0].price = 15;
   s[1].is_high = false; s[1].price = 10;
   s[2].is_high = true;  s[2].price = 14;
   s[3].is_high = false; s[3].price = 9;
   t.EqInt(CMarketAlgo::ClassifyStructure(s, 4), STRUCTURE_BULLISH, "HH+HL = alcista");
   s[0].price = 13; s[1].price = 8;
   t.EqInt(CMarketAlgo::ClassifyStructure(s, 4), STRUCTURE_BEARISH, "LH+LL = bajista");
   s[0].price = 16; s[1].price = 8;
   t.EqInt(CMarketAlgo::ClassifyStructure(s, 4), STRUCTURE_MIXED, "HH+LL = mixta");
   t.EqInt(CMarketAlgo::ClassifyStructure(s, 2), STRUCTURE_UNKNOWN, "pivotes insuficientes = desconocida");

   // Pendiente, momentum, medias
   double a[6] = {10, 9, 8, 7, 6, 5};
   t.EqDbl(CMarketAlgo::NormalizedSlope(a, 0, 5, 2.0), 2.5, 1e-12, "pendiente normalizada");
   t.EqDbl(CMarketAlgo::NormalizedSlope(a, 1, 5, 2.0), 0.0, 1e-12, "pendiente fuera de rango = 0");
   t.EqDbl(CMarketAlgo::NormalizedSlope(a, 0, 5, 0.0), 0.0, 1e-12, "pendiente con norma 0 = 0");
   t.True(CMarketAlgo::MomentumShift(0.2, -0.2, 0.05), "cambio de momentum detectado");
   t.True(!CMarketAlgo::MomentumShift(0.2, 0.1, 0.05), "sin cambio de momentum");
   t.True(!CMarketAlgo::MomentumShift(0.01, -0.2, 0.05), "pendiente previa insignificante ignorada");
   t.EqDbl(CMarketAlgo::Mean(a, 0, 6), 7.5, 1e-12, "media");
   t.EqDbl(CMarketAlgo::Mean(a, 4, 5), 0.0, 1e-12, "media fuera de rango = 0");

   // Series de indicadores
   double ok[3] = {50, 60, 70};
   double bad1[3] = {50, EMPTY_VALUE, 70};
   double bad2[3] = {50, 101, 70};
   t.True(CMarketAlgo::ValidateSeries(ok, 3, 0, 100, reason), "serie válida");
   t.True(!CMarketAlgo::ValidateSeries(bad1, 3, 0, 100, reason), "rechaza EMPTY_VALUE");
   t.True(!CMarketAlgo::ValidateSeries(bad2, 3, 0, 100, reason), "rechaza fuera de rango");
   t.True(!CMarketAlgo::ValidateSeries(ok, 4, 0, 100, reason), "rechaza serie incompleta");

   // Spread medio desde velas
   MqlRates sr[4];
   SetBar(sr[0], D(2026, 1, 14, 12, 0), 1, 2, 0.5, 1.5, 10);
   SetBar(sr[1], D(2026, 1, 14, 11, 55), 1, 2, 0.5, 1.5, 20);
   SetBar(sr[2], D(2026, 1, 14, 11, 50), 1, 2, 0.5, 1.5, 0);
   SetBar(sr[3], D(2026, 1, 14, 11, 45), 1, 2, 0.5, 1.5, 30);
   t.EqDbl(CMarketAlgo::AverageRatesSpread(sr, 4), 20.0, 1e-12, "spread medio ignora ceros");
   for(int i = 0; i < 4; i++)
      sr[i].spread = 0;
   t.EqDbl(CMarketAlgo::AverageRatesSpread(sr, 4), 0.0, 1e-12, "spread no disponible = 0");

   double hi, lo;
   BuildSeries(highs, r);
   CMarketAlgo::RangeOf(r, 11, hi, lo);
   t.EqDbl(hi, 13.0, 1e-12, "máximo del rango");
   t.EqDbl(lo, 8.0, 1e-12, "mínimo del rango");

   // Configuración
   MarketEngineConfig mc;
   MarketEngineDefaultConfig(mc, "XAUUSD");
   t.True(MarketEngineValidateConfig(mc, reason), "config por defecto válida: " + reason);
   MarketEngineConfig mb = mc;
   mb.ema_fast_period = 200;
   t.True(!MarketEngineValidateConfig(mb, reason), "rechaza EMA rápida >= lenta");
   mb = mc;
   mb.min_history_bars = 100;
   t.True(!MarketEngineValidateConfig(mb, reason), "rechaza historial mínimo insuficiente");
   mb = mc;
   mb.analysis_bars = 50;
   t.True(!MarketEngineValidateConfig(mb, reason), "rechaza analysis_bars < ventana ATR");
  }

//--- CLogger ------------------------------------------------------------
void TestLogger(CTestRunner &t)
  {
   CLogger log;
   t.True(log.Init("TEST_Logger", LOG_DEBUG, LOG_ERROR), "Logger Init");
   log.Info("Test", "EVENT", "mensaje con\ttab y\nsalto", "ID-1");
   t.True(log.FileOk(), "Logger escribe en fichero");
   t.True(FileIsExist(log.CurrentFile()), "fichero de log existe: " + log.CurrentFile());
   string id1 = log.NewId("SIG");
   string id2 = log.NewId("SIG");
   t.True(id1 != id2, "NewId genera identificadores distintos");
   t.True(StringFind(id1, "SIG-") == 0, "NewId respeta prefijo");
   t.True(log.LogOnChange("gate.news", "closed", LOG_INFO, "Test", "GATE", "cerrado"), "LogOnChange registra primer valor");
   t.True(!log.LogOnChange("gate.news", "closed", LOG_INFO, "Test", "GATE", "cerrado"), "LogOnChange omite valor repetido");
   t.True(log.LogOnChange("gate.news", "open", LOG_INFO, "Test", "GATE", "abierto"), "LogOnChange registra cambio");
   log.Close();
  }

void OnStart()
  {
   CTestRunner t("Test_Phase2");
   TestCalendarRules(t);
   TestSessions(t);
   TestMarketAlgo(t);
   TestLogger(t);
   t.Finish();
  }
