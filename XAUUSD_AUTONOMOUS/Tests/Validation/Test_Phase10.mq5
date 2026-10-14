//+------------------------------------------------------------------+
//| Test_Phase10.mq5                                                 |
//| Dashboard en el gráfico del script: creación de objetos,         |
//| actualización de textos, comandos y doble confirmación.          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Dashboard.mqh>
#include "TestFramework.mqh"

void OnStart()
  {
   CTestRunner t("Test_Phase10");
   CDashboard db;
   t.True(db.Init(0, "XADT_"), "Dashboard Init");
   t.True(ObjectFind(0, "XADT_BG") >= 0, "fondo creado");
   t.True(ObjectFind(0, "XADT_L0") >= 0 && ObjectFind(0, "XADT_L25") >= 0, "26 líneas creadas");
   t.True(ObjectFind(0, "XADT_BTN_CLOSE") >= 0 && ObjectFind(0, "XADT_BTN_PAUSE") >= 0, "botones creados");

   DashboardData d;
   d.ea_state = "RUNNING";
   d.symbol = "XAUUSD";
   d.account = "DEMO Hedging";
   d.times = "srv 12:00 / UTC 10:00 / COL 05:00";
   d.session = "LONDON";
   d.regime = "TREND_UP";
   d.h1_trend = "alcista";
   d.m15_structure = "BULLISH";
   d.m5_confirmation = "rechazo";
   d.strategy = "SMC";
   d.score = "82 (HIGH)";
   d.spread = "20";
   d.atr = "4.10";
   d.rsi = "55.0";
   d.positions = "1";
   d.risk_per_trade = "1.00%";
   d.exposure = "1.00%";
   d.daily_loss = "0.00%";
   d.daily_gain = "0.40%";
   d.drawdown = "0.00%";
   d.news = "libre (próximo CPI en 120 min)";
   d.last_signal = "SMC LONG";
   d.last_trade = "BUY 0.20";
   d.blocks = "ninguno";
   datetime now = D'2026.01.14 12:00:00';
   db.Update(d, false, now);
   t.True(StringFind(db.LineText(0), "RUNNING") >= 0, "estado mostrado");
   t.True(StringFind(ObjectGetString(0, "XADT_L4", OBJPROP_TEXT), "TREND_UP") >= 0, "régimen en el objeto del gráfico");
   t.True(StringFind(db.LineText(14), "CPI") >= 0, "noticias mostradas");
   t.True(ObjectGetString(0, "XADT_BTN_PAUSE", OBJPROP_TEXT) == "Pausar entradas", "botón de pausa");
   db.Update(d, true, now);
   t.True(ObjectGetString(0, "XADT_BTN_PAUSE", OBJPROP_TEXT) == "Reanudar entradas", "botón refleja la pausa");

   t.EqInt(db.OnClick("XADT_BTN_PAUSE", now), DASH_TOGGLE_PAUSE, "clic en pausa");
   t.EqInt(db.OnClick("XADT_BTN_SAFE", now), DASH_SAFE_MODE, "clic en modo seguro");
   t.EqInt(db.OnClick("XADT_BTN_LOGS", now), DASH_SHOW_LOGS, "clic en registros");
   t.EqInt(db.OnClick("OTRO_OBJETO", now), DASH_NONE, "objetos ajenos se ignoran");
   //--- doble confirmación para cerrar todo
   t.EqInt(db.OnClick("XADT_BTN_CLOSE", now), DASH_NONE, "1.er clic en cerrar todo solo arma");
   t.True(StringFind(ObjectGetString(0, "XADT_BTN_CLOSE", OBJPROP_TEXT), "CONFIRMAR") >= 0, "pide confirmación");
   t.EqInt(db.OnClick("XADT_BTN_CLOSE", now + 3), DASH_CLOSE_ALL, "2.º clic en 3 s confirma");
   t.EqInt(db.OnClick("XADT_BTN_CLOSE", now + 10), DASH_NONE, "tras confirmar, se vuelve a armar desde cero");
   t.EqInt(db.OnClick("XADT_BTN_CLOSE", now + 17), DASH_NONE, "2.º clic tras 7 s no confirma");
   db.Update(d, false, now + 30);
   t.True(ObjectGetString(0, "XADT_BTN_CLOSE", OBJPROP_TEXT) == "Cerrar todo", "la confirmación caduca");
   t.EqInt(db.OnClick("XADT_BTN_EXIT_SAFE", now + 40), DASH_NONE, "salir de modo seguro: 1.er clic arma");
   t.EqInt(db.OnClick("XADT_BTN_EXIT_SAFE", now + 41), DASH_EXIT_SAFE_MODE, "salir de modo seguro: 2.º clic confirma");
   db.Destroy();
   t.True(ObjectFind(0, "XADT_BG") < 0 && ObjectFind(0, "XADT_L0") < 0, "objetos eliminados");
   t.Finish();
  }
