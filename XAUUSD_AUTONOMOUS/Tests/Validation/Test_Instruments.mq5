//+------------------------------------------------------------------+
//| Test_Instruments.mq5                                             |
//| Perfiles por instrumento (1.2.0): detección por nombre,          |
//| resolución con las protecciones (símbolo no reconocido, perfil   |
//| forzado, Boom/Crash experimental), restricción de lado del spike |
//| y límites de coste relativos al ATR. Funciones puras: no         |
//| dependen de los símbolos del bróker.                             |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/InstrumentProfile.mqh>
#include "TestFramework.mqh"

void TestFamily(CTestRunner &t)
  {
   t.True(CInstrumentProfiles::Family("XAUUSD") == "XAUUSD", "XAUUSD");
   t.True(CInstrumentProfiles::Family("xauusd.m") == "XAUUSD", "sufijo y minúsculas");
   t.True(CInstrumentProfiles::Family("Volatility 75 Index") == "Volatility", "Volatility 75 Index");
   t.True(CInstrumentProfiles::Family("Volatility 75 (1s) Index") == "Volatility", "Volatility 75 (1s) Index");
   t.True(CInstrumentProfiles::Family("Boom 1000 Index") == "Boom", "Boom 1000 Index");
   t.True(CInstrumentProfiles::Family("Crash 500 Index") == "Crash", "Crash 500 Index");
   t.True(CInstrumentProfiles::Family("Step Index") == "Step", "Step Index");
   t.True(CInstrumentProfiles::Family("Jump 25 Index") == "Jump", "Jump 25 Index");
   t.True(CInstrumentProfiles::Family("EURUSD") == "", "EURUSD no reconocido");
  }

void TestResolve(CTestRunner &t)
  {
   InstrumentProfile p;
   string why;
   t.True(CInstrumentProfiles::Resolve("XAUUSD", PROFILE_AUTO, false, false, true, p, why), "XAUUSD automático: " + why);
   t.True(p.id == PROFILE_XAUUSD && p.use_sessions && p.use_news && p.use_asia_range && !p.atr_costs && p.only_dir == DIR_NONE,
          "XAUUSD: sesiones, noticias, rango asiático y costes en puntos (sin cambios respecto a 1.1.x)");

   t.True(CInstrumentProfiles::Resolve("Volatility 75 Index", PROFILE_AUTO, false, false, true, p, why), "V75 automático: " + why);
   t.True(p.id == PROFILE_SYNTH_CONTINUOUS && !p.use_sessions && !p.use_news && !p.use_asia_range && p.atr_costs,
          "V75: 24/7, sin noticias, sin rango asiático, costes relativos al ATR");
   t.True(p.only_dir == DIR_NONE && p.spike_dir == 0, "V75: ambos lados");

   t.True(!CInstrumentProfiles::Resolve("Boom 1000 Index", PROFILE_AUTO, false, false, true, p, why) &&
          StringFind(why, "InpAllowSpikeIndices") >= 0, "Boom sin activar el perfil experimental -> no arranca");
   t.True(CInstrumentProfiles::Resolve("Boom 1000 Index", PROFILE_AUTO, false, true, true, p, why), "Boom activado: " + why);
   t.True(p.id == PROFILE_SYNTH_SPIKE && p.spike_dir == 1 && p.only_dir == DIR_LONG, "Boom: spike alcista, solo compras");
   t.True(CInstrumentProfiles::Resolve("Crash 500 Index", PROFILE_AUTO, false, true, true, p, why), "Crash activado: " + why);
   t.True(p.spike_dir == -1 && p.only_dir == DIR_SHORT, "Crash: spike bajista, solo ventas");
   t.True(CInstrumentProfiles::Resolve("Crash 500 Index", PROFILE_AUTO, false, true, false, p, why) && p.only_dir == DIR_NONE,
          "Crash sin restricción de lado (elección explícita) -> ambos lados");

   t.True(!CInstrumentProfiles::Resolve("EURUSD", PROFILE_AUTO, false, false, true, p, why), "EURUSD -> no arranca: " + why);
   t.True(CInstrumentProfiles::Resolve("EURUSD", PROFILE_AUTO, true, false, true, p, why) && p.id == PROFILE_XAUUSD,
          "EURUSD con InpAllowAnySymbol (pruebas) -> reglas del oro, como antes");
   t.True(!CInstrumentProfiles::Resolve("XAUUSD", PROFILE_SYNTH_CONTINUOUS, false, false, true, p, why) &&
          StringFind(why, "InpAllowAnySymbol") >= 0, "perfil sintético forzado en XAUUSD -> rechazo");
   t.True(!CInstrumentProfiles::Resolve("Volatility 75 Index", PROFILE_XAUUSD, false, false, true, p, why),
          "perfil del oro forzado en V75 -> rechazo (sesiones/noticias no aplican)");
   t.True(CInstrumentProfiles::Resolve("Step Index", PROFILE_SYNTH_CONTINUOUS, false, false, true, p, why) && p.family == "Step",
          "perfil explícito coherente con el nombre -> aceptado");
   t.True(!CInstrumentProfiles::Resolve("Volatility 75 Index", PROFILE_SYNTH_SPIKE, true, true, true, p, why) &&
          StringFind(why, "Boom o Crash") >= 0, "perfil con spikes sin dirección conocida -> rechazo");
  }

void TestDirection(CTestRunner &t)
  {
   InstrumentProfile p;
   CInstrumentProfiles::Build(PROFILE_SYNTH_SPIKE, "Boom", true, p);
   t.True(CInstrumentProfiles::DirectionAllowed(p, DIR_LONG) && !CInstrumentProfiles::DirectionAllowed(p, DIR_SHORT),
          "Boom: compra sí, venta no");
   CInstrumentProfiles::Build(PROFILE_SYNTH_CONTINUOUS, "Volatility", true, p);
   t.True(CInstrumentProfiles::DirectionAllowed(p, DIR_LONG) && CInstrumentProfiles::DirectionAllowed(p, DIR_SHORT),
          "V75: ambos lados");
  }

void TestLimits(CTestRunner &t)
  {
   CostLimits fixed;
   fixed.max_spread_points = 60;
   fixed.deviation_points = 30;
   fixed.entry_drift_points = 50;
   fixed.be_offset_points = 10;
   SyntheticCostConfig sc;
   SyntheticCostDefaultConfig(sc);
   string why;
   t.True(SyntheticCostValidateConfig(sc, why), "configuración sintética por defecto válida");
   InstrumentProfile gold, v75;
   CInstrumentProfiles::Build(PROFILE_XAUUSD, "XAUUSD", true, gold);
   CInstrumentProfiles::Build(PROFILE_SYNTH_CONTINUOUS, "Volatility", true, v75);
   CostLimits out;
   t.True(CInstrumentProfiles::Limits(gold, fixed, sc, 3.5, 0.01, out) && out.max_spread_points == 60 &&
          out.deviation_points == 30 && out.entry_drift_points == 50 && out.be_offset_points == 10,
          "XAUUSD: límites fijos de los inputs");
   //--- ATR M15 = 100 con punto 0.01 -> 10 000 puntos
   t.True(CInstrumentProfiles::Limits(v75, fixed, sc, 100.0, 0.01, out), "V75 con ATR");
   t.EqInt(out.max_spread_points, 1500, "spread máx = 0.15 x 10 000");
   t.EqInt(out.deviation_points, 1000, "desviación = 0.10 x 10 000");
   t.EqInt(out.entry_drift_points, 1000, "deriva = 0.10 x 10 000");
   t.EqInt(out.be_offset_points, 200, "offset BE = 0.02 x 10 000");
   CostLimits prev = out;
   t.True(!CInstrumentProfiles::Limits(v75, fixed, sc, 0.0, 0.01, out), "sin ATR -> no se calculan límites");
   t.True(out.max_spread_points == prev.max_spread_points, "sin ATR -> se conservan los anteriores");
   t.EqInt(CInstrumentProfiles::AtrPoints(0.001, 0.01, 0.15, 1), 1, "spread mínimo 1 punto");
   t.EqInt(CInstrumentProfiles::AtrPoints(1e12, 1e-5, 1.0, 0), 2000000000, "acotado a 2e9 (sin desbordar int)");
   SyntheticCostConfig bad = sc;
   bad.max_spread_atr = 0.0;
   t.True(!SyntheticCostValidateConfig(bad, why), "spread máximo 0 -> inválido");
   bad = sc;
   bad.be_offset_atr = 0.9;
   t.True(!SyntheticCostValidateConfig(bad, why), "offset BE 0.9 ATR -> inválido");
  }

void TestFiles(CTestRunner &t)
  {
   InstrumentProfile gold, v75;
   CInstrumentProfiles::Build(PROFILE_XAUUSD, "XAUUSD", true, gold);
   CInstrumentProfiles::Build(PROFILE_SYNTH_CONTINUOUS, "Volatility", true, v75);
   t.True(CInstrumentProfiles::ChampionFile(gold, "XAUUSD") == "XAUUSD/champion.model", "Champion del oro: ruta histórica");
   t.True(CInstrumentProfiles::ChampionFile(v75, "Volatility 75 (1s) Index") == "XAUUSD/champion_Volatility_75__1s__Index.model",
          "Champion por símbolo con nombre seguro: " + CInstrumentProfiles::ChampionFile(v75, "Volatility 75 (1s) Index"));
   t.True(EnumProfileToString(PROFILE_SYNTH_SPIKE) == "SINTETICO_SPIKE", "nombre del perfil");
  }

void OnStart()
  {
   CTestRunner t("Test_Instruments");
   TestFamily(t);
   TestResolve(t);
   TestDirection(t);
   TestLimits(t);
   TestFiles(t);
   t.Finish();
  }
