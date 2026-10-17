//+------------------------------------------------------------------+
//| Test_Phase6.mq5                                                  |
//| Pruebas del RiskManager, del seguimiento de pérdida diaria y     |
//| del StateStore. Calculadora simulada con especificación tipo     |
//| oro: contrato 100, tick 0.01 = 1 USD por lote (pérdida por lote  |
//| = distancia x 100), margen = volumen x precio (apalancamiento    |
//| 1:100). Valores esperados calculados a mano.                     |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/RiskManager.mqh>
#include <XAUUSD/StateStore.mqh>
#include "TestFramework.mqh"

class CFakeCalc : public CTradeCalculator
  {
public:
   double            scale;
   bool              fail;
                     CFakeCalc(void) { scale = 1.0; fail = false; }
   virtual bool      Loss(const ENUM_DIRECTION dir, const double volume, const double entry, const double sl, double &loss)
     {
      if(fail)
         return false;
      double dist = (dir == DIR_LONG) ? entry - sl : sl - entry;
      loss = dist * 100.0 * volume * scale;
      return true;
     }
   virtual bool      Margin(const ENUM_DIRECTION dir, const double volume, const double price, double &margin)
     {
      if(fail)
         return false;
      margin = volume * price;
      return true;
     }
  };

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

void Account(AccountSnapshot &a, const double balance, const double equity)
  {
   a.balance = balance;
   a.equity = equity;
   a.margin = 0;
   a.free_margin = equity;
   a.currency = "USD";
   a.netting = false;
  }

TradeSignal Sig(const ENUM_DIRECTION d, const double entry, const double sl, const double tp)
  {
   TradeSignal g;
   g.direction = d;
   g.entry_price = entry;
   g.sl = sl;
   g.tp = tp;
   g.signal_id = "T";
   g.setup_key = "T";
   g.reason = "test";
   return g;
  }

void AddPos(PositionRisk &p[], const ENUM_DIRECTION d, const double vol, const double open, const double sl)
  {
   int n = ArraySize(p);
   ArrayResize(p, n + 1);
   p[n].ticket = 1000 + n;
   p[n].direction = d;
   p[n].volume = vol;
   p[n].open_price = open;
   p[n].sl = sl;
  }

#define DAY D'2026.01.14 12:00'

void TestVolume(CTestRunner &t)
  {
   CFakeCalc calc;
   RiskConfig cfg;
   RiskDefaultConfig(cfg);
   CRiskManager rm;
   t.True(rm.Init(cfg, &calc, NULL), "RiskManager Init");
   SymbolSpec spec;
   Spec(spec);
   AccountSnapshot acc;
   Account(acc, 10000, 10000);
   PositionRisk none[];
   CDailyLossTracker daily;
   daily.Configure(0, cfg.daily_loss_pct);
   daily.Update(DAY, 10000);

   RiskDecision d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(d.approved, "compra 1% aprobada: " + d.reject_reason);
   t.EqDbl(d.volume, 0.20, 1e-9, "volumen = 100 / (5 x 100) = 0.20");
   t.EqDbl(d.risk_money, 100.0, 1e-6, "riesgo 100 USD");
   t.EqDbl(d.risk_pct, 1.0, 1e-9, "riesgo 1%");
   t.EqDbl(d.margin_required, 480.0, 1e-6, "margen 0.20 x 2400");
   t.EqDbl(d.exposure_after_pct, 1.0, 1e-9, "exposición 0% -> 1%");
   t.EqDbl(d.rr, 2.0, 1e-9, "R:R 2");

   //--- comisión: 100 / 507 = 0.1972 -> 0.19 (hacia abajo)
   RiskConfig cc = cfg;
   cc.commission_per_lot = 7.0;
   CRiskManager rmc;
   rmc.Init(cc, &calc, NULL);
   d = rmc.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.EqDbl(d.volume, 0.19, 1e-9, "con comisión 7/lote: 0.19");
   t.EqDbl(d.risk_money, 0.19 * 507.0, 1e-6, "riesgo incluye comisión");
   t.True(d.risk_money <= 100.0, "nunca supera el 1%");

   //--- venta: el spread se suma al riesgo (30 puntos = 30 USD/lote)
   d = rm.Assess(Sig(DIR_SHORT, 2400, 2405, 2390), spec, acc, none, daily, 30, 0);
   t.True(d.approved, "venta aprobada");
   t.EqDbl(d.volume, 0.18, 1e-9, "venta con spread: 100 / 530 = 0.1886 -> 0.18");
   t.EqDbl(d.risk_money, 0.18 * 530.0, 1e-6, "riesgo de venta con spread");

   //--- equity menor que balance: base = equity
   AccountSnapshot low;
   Account(low, 10000, 9000);
   CDailyLossTracker dl;
   dl.Configure(0, 3.0);
   dl.Update(DAY, 9000);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, low, none, dl, 20, 0);
   t.EqDbl(d.volume, 0.18, 1e-9, "base = min(balance, equity) = 9000 -> 0.18");

   //--- volumen mínimo: nunca se redondea hacia arriba
   d = rm.Assess(Sig(DIR_LONG, 2400, 2340, 2520), spec, acc, none, daily, 20, 0);
   t.EqDbl(d.volume, 0.01, 1e-9, "SL de 60: 0.0166 -> 0.01");
   d = rm.Assess(Sig(DIR_LONG, 2400, 2280, 2640), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "mínimo") >= 0, "SL de 120: 0.0083 < 0.01 -> rechazo: " + d.reject_reason);

   //--- volumen máximo y límite
   SymbolSpec sm = spec;
   sm.volume_max = 0.10;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), sm, acc, none, daily, 20, 0);
   t.EqDbl(d.volume, 0.10, 1e-9, "limitado al volumen máximo");

   //--- R:R
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2407.5), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "R:R") >= 0, "R:R 1.5 < 2 -> rechazo");

   //--- stops level (6.00) mayor que la distancia del SL (5.00)
   SymbolSpec ss = spec;
   ss.stops_level = 600;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), ss, acc, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "stops level") >= 0, "SL dentro del stops level -> rechazo");

   //--- verificación cruzada
   calc.scale = 1.2;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && d.critical, "OrderCalcProfit incoherente con tick value -> rechazo crítico");
   calc.scale = 1.0;
   calc.fail = true;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved, "OrderCalcProfit falla -> rechazo");
   calc.fail = false;

   //--- margen
   AccountSnapshot nm;
   Account(nm, 10000, 10000);
   nm.free_margin = 500;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, nm, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "margen") >= 0, "margen libre insuficiente -> rechazo");
   Account(nm, 10000, 10000);
   nm.margin = 3000;
   nm.free_margin = 7000;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, nm, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "nivel de margen") >= 0, "nivel de margen < 300% -> rechazo");

   //--- precios incoherentes
   d = rm.Assess(Sig(DIR_LONG, 2400, 2405, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved, "compra con SL por encima -> rechazo");

   //--- reducción tras rachas de pérdidas (solo reduce)
   RiskConfig cr = cfg;
   cr.reduce_after_losses = 3;
   CRiskManager rmr;
   rmr.Init(cr, &calc, NULL);
   d = rmr.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 3);
   t.EqDbl(d.volume, 0.10, 1e-9, "3 pérdidas seguidas: riesgo 0.5% -> 0.10");
   d = rmr.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 2);
   t.EqDbl(d.volume, 0.20, 1e-9, "2 pérdidas: riesgo normal");
   t.True(rmr.EffectiveRiskPct(10) <= cr.risk_pct, "el riesgo nunca aumenta con las pérdidas");
  }

void TestExposure(CTestRunner &t)
  {
   CFakeCalc calc;
   RiskConfig cfg;
   RiskDefaultConfig(cfg);
   CRiskManager rm;
   rm.Init(cfg, &calc, NULL);
   SymbolSpec spec;
   Spec(spec);
   AccountSnapshot acc;
   Account(acc, 10000, 10000);
   CDailyLossTracker daily;
   daily.Configure(0, 3.0);
   daily.Update(DAY, 10000);
   PositionRisk pos[];

   AddPos(pos, DIR_LONG, 0.20, 2390, 2385);          // 1% en riesgo
   RiskDecision d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, pos, daily, 20, 0);
   t.True(d.approved, "1% existente + 1% nuevo = 2% -> aprobado");
   t.EqDbl(d.exposure_before_pct, 1.0, 1e-9, "exposición previa 1%");
   t.EqDbl(d.exposure_after_pct, 2.0, 1e-9, "exposición posterior 2%");
   AddPos(pos, DIR_SHORT, 0.20, 2410, 2415);         // otro 1%
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, pos, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "exposición") >= 0, "2% existente + 1% -> rechazo por exposición");
   pos[1].sl = 2410;                                  // en break-even
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, pos, daily, 20, 0);
   t.True(d.approved, "posición en break-even no cuenta como riesgo -> 3.ª permitida");
   pos[1].sl = 2405;                                  // SL en beneficio
   double money;
   string why;
   t.True(rm.ExistingExposure(pos, money, why), "exposición calculable");
   t.EqDbl(money, 100.0, 1e-6, "SL en beneficio = riesgo 0");
   AddPos(pos, DIR_LONG, 0.01, 2380, 2379.99);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, pos, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "máximo de posiciones") >= 0, "3 posiciones abiertas -> rechazo");
   ArrayResize(pos, 1);
   pos[0].sl = 0;
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, pos, daily, 20, 0);
   t.True(!d.approved && d.critical, "posición sin SL -> rechazo crítico (modo seguro)");

   //--- Netting
   AccountSnapshot net;
   Account(net, 10000, 10000);
   net.netting = true;
   ArrayResize(pos, 0);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, net, pos, daily, 20, 0);
   t.True(d.approved, "Netting sin posición -> aprobado");
   AddPos(pos, DIR_LONG, 0.10, 2390, 2400);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, net, pos, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "Netting") >= 0, "Netting con posición -> rechazo (no promedia)");
  }

void TestDaily(CTestRunner &t)
  {
   CFakeCalc calc;
   RiskConfig cfg;
   RiskDefaultConfig(cfg);
   CRiskManager rm;
   rm.Init(cfg, &calc, NULL);
   SymbolSpec spec;
   Spec(spec);
   PositionRisk none[];
   CDailyLossTracker daily;
   daily.Configure(0, 3.0);
   t.True(daily.Update(DAY, 10000), "primer Update inicia el día");
   t.True(!daily.Update(DAY + 3600, 9900), "mismo día: no reinicia");
   t.EqDbl(daily.E0(), 10000, 1e-9, "E0 = equity al reset");

   AccountSnapshot acc;
   Account(acc, 10000, 9750);
   RiskDecision d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   // pérdida 2.5% + nuevo riesgo 95/10000 = 0.95% -> 3.45% > 3%
   t.True(!d.approved && StringFind(d.reject_reason, "peor caso") >= 0, "peor caso del día > 3% -> rechazo");
   t.EqDbl(d.daily_loss_pct, 2.5, 1e-9, "pérdida del día 2.5%");
   Account(acc, 10000, 9700);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "límite de pérdida diaria") >= 0, "pérdida 3% -> bloqueo diario");
   Account(acc, 10000, 9950);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && daily.LimitHit(), "el bloqueo se mantiene aunque la equity se recupere");
   t.True(daily.Update(DAY + 86400, 9950), "nuevo día: reset");
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(d.approved, "tras el reset se vuelve a operar: " + d.reject_reason);

   //--- depósitos y retiros no cuentan como ganancia/pérdida
   CDailyLossTracker dd;
   dd.Configure(0, 3.0);
   dd.Update(DAY, 10000);
   dd.AddBalanceOperation(1000);
   t.EqDbl(dd.PnL(11000), 0.0, 1e-9, "depósito de 1000 no es ganancia");
   dd.AddBalanceOperation(-500);
   t.EqDbl(dd.PnL(10300), -200.0, 1e-9, "retiro neto ajustado");

   //--- hora de reset distinta de medianoche
   CDailyLossTracker d22;
   d22.Configure(22, 3.0);
   t.EqTime(d22.DayStartFor(D'2026.01.14 21:59'), D'2026.01.13 22:00', "reset 22:00: 21:59 pertenece al día anterior");
   t.EqTime(d22.DayStartFor(D'2026.01.14 22:00'), D'2026.01.14 22:00', "reset 22:00: 22:00 inicia día");

   //--- restauración y reconstrucción
   CDailyLossTracker dr;
   dr.Configure(0, 3.0);
   t.True(dr.Restore(DAY, D'2026.01.14 00:00', 10000, 0, true), "restaura el estado del mismo día");
   t.True(dr.LimitHit(), "restaura el bloqueo");
   t.True(!dr.Restore(DAY, D'2026.01.13 00:00', 10000, 0, true), "no restaura el estado de otro día");
   dr.Reconstruct(DAY, 10200, 300, 0);
   t.EqDbl(dr.E0(), 9900, 1e-9, "reconstrucción: balance 10200 - realizado 300");
   t.True(dr.Reconstructed(), "marca la base como reconstruida");

   //--- alcance: solo operaciones del EA (1.1.1)
   CDailyLossTracker de;
   de.Configure(0, 3.0);
   de.Update(DAY, 10000);
   t.True(de.Scope() == DAILY_SCOPE_ACCOUNT, "alcance por defecto del objeto: toda la cuenta");
   t.EqDbl(de.LossPct(9216), 7.84, 1e-9, "cuenta: pérdida manual de 7.84% cuenta");
   de.SetScope(DAILY_SCOPE_EA);
   de.SetOwnPnL(0.0);
   t.EqDbl(de.LossPct(9216), 0.0, 1e-9, "EA: la pérdida manual no cuenta");
   t.True(!de.LimitReached(9216), "EA: sin bloqueo por pérdidas ajenas");
   de.SetOwnPnL(-200.0);
   t.EqDbl(de.LossPct(9216), 2.0, 1e-9, "EA: pérdida propia 200 / E0 10000 = 2%");
   de.AddBalanceOperation(5000);
   t.EqDbl(de.PnL(20000), -200.0, 1e-9, "EA: depósitos y equity ajena no alteran el PnL propio");
   de.SetOwnPnL(150.0);
   t.EqDbl(de.GainPct(0), 1.5, 1e-9, "EA: ganancia propia 1.5%");
   de.SetOwnPnL(-300.0);
   t.True(de.LimitReached(9216), "EA: pérdida propia 3% -> bloqueo");
   de.SetOwnPnL(100.0);
   t.True(de.LimitHit(), "EA: el bloqueo se mantiene hasta el reset");
   t.True(de.Update(DAY + 86400, 9300) && !de.LimitHit() && de.OwnPnL() == 0.0, "EA: el reset limpia bloqueo y PnL propio");
   t.EqDbl(de.E0(), 9300, 1e-9, "EA: E0 sigue siendo la equity de la cuenta al reset");
   //--- RiskManager con alcance EA: la pérdida ajena no entra en el peor caso
   Account(acc, 9300, 8800);
   de.SetOwnPnL(-50.0);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, de, 20, 0);
   t.True(d.approved, "EA: pérdida ajena de 5.4% no bloquea; propia 0.54% + riesgo dentro del límite: " + d.reject_reason);
   t.EqDbl(d.daily_loss_pct, 50.0 / 9300.0 * 100.0, 1e-9, "EA: pérdida diaria informada = la propia");

   //--- sin inicializar
   CDailyLossTracker empty;
   empty.Configure(0, 3.0);
   Account(acc, 10000, 10000);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, empty, 20, 0);
   t.True(!d.approved, "seguimiento diario sin inicializar -> rechazo");
  }

void TestConfigAndGuards(CTestRunner &t)
  {
   RiskConfig c;
   RiskDefaultConfig(c);
   string why;
   t.True(RiskValidateConfig(c, why), "config por defecto válida");
   RiskConfig b = c; b.risk_pct = 2.5;
   t.True(!RiskValidateConfig(b, why), "rechaza riesgo > 2%");
   b = c; b.risk_pct = 10;
   t.True(!RiskValidateConfig(b, why), "rechaza riesgo 10 (error de tipeo)");
   b = c; b.max_exposure_pct = 0.5;
   t.True(!RiskValidateConfig(b, why), "rechaza exposición < riesgo");
   b = c; b.max_exposure_pct = 6;
   t.True(!RiskValidateConfig(b, why), "rechaza exposición > 5%");
   b = c; b.daily_loss_pct = 7;
   t.True(!RiskValidateConfig(b, why), "rechaza pérdida diaria > 6%");
   b = c; b.min_rr = 0.8;
   t.True(!RiskValidateConfig(b, why), "rechaza R:R < 1");
   b = c; b.max_positions = 6;
   t.True(!RiskValidateConfig(b, why), "rechaza más de 5 posiciones");
   b = c; b.reduction_factor = 1.5;
   t.True(!RiskValidateConfig(b, why), "rechaza factor de 'reducción' > 1 (sería aumentar)");
   CRiskManager rm;
   t.True(!rm.Init(c, NULL, NULL), "Init sin calculadora falla");

   t.True(CRiskManager::AccountAllowed(ACCOUNT_TRADE_MODE_DEMO, false, "", why), "demo permitida");
   t.True(!CRiskManager::AccountAllowed(ACCOUNT_TRADE_MODE_REAL, false, "I UNDERSTAND THE RISK", why), "real sin autorización -> bloqueada");
   t.True(!CRiskManager::AccountAllowed(ACCOUNT_TRADE_MODE_REAL, true, "si", why), "real sin frase exacta -> bloqueada");
   t.True(CRiskManager::AccountAllowed(ACCOUNT_TRADE_MODE_REAL, true, "I UNDERSTAND THE RISK", why), "real con ambas -> permitida");
   t.True(!CRiskManager::AccountAllowed(ACCOUNT_TRADE_MODE_CONTEST, false, "", why), "concurso tratado como no demo");

   SymbolSpec a, b2;
   Spec(a);
   Spec(b2);
   t.True(!SymbolSpecChanged(a, b2), "especificación igual");
   b2.volume_step = 0.1;
   t.True(SymbolSpecChanged(a, b2), "detecta cambio de especificación");
  }

void TestStateStore(CTestRunner &t)
  {
   string file = "XAUUSD/test_state.dat";
   FolderCreate("XAUUSD");
   FileDelete(file);
   CStateStore st;
   t.True(st.Init(file, false), "StateStore Init");
   string why;
   t.True(st.Load(why) && why == "sin estado previo", "sin archivo = estado vacío");
   st.Set("ea.state", "RUNNING");
   st.SetDouble("daily.e0", 10000.5);
   st.SetLong("daily.start", (long)D'2026.01.14 00:00');
   st.SetBool("daily.limit", true);
   st.Set("consumed.SMC|LONG|x", "123");
   st.Set("consumed.BO|SHORT|y", "456");
   st.Set("raro", "valor con = y\nsalto");
   t.True(st.Save(why), "guarda: " + why);
   t.True(FileIsExist(file) && !FileIsExist(file + ".tmp"), "archivo final existe y el temporal no");
   CStateStore st2;
   st2.Init(file, false);
   t.True(st2.Load(why), "carga: " + why);
   t.True(st2.Get("ea.state") == "RUNNING", "recupera texto");
   t.EqDbl(st2.GetDouble("daily.e0"), 10000.5, 1e-9, "recupera double");
   t.EqInt(st2.GetLong("daily.start"), (long)D'2026.01.14 00:00', "recupera entero");
   t.True(st2.GetBool("daily.limit"), "recupera bool");
   t.True(st2.Get("raro") == "valor con = y salto", "valor con '=' y salto de línea saneado");
   string keys[];
   t.EqInt(st2.KeysWithPrefix("consumed.", keys), 2, "claves por prefijo");
   t.True(st2.Remove("raro") && !st2.Has("raro"), "eliminar clave");
   t.True(st2.Get("no.existe", "def") == "def", "valor por defecto");

   //--- corrupción: se altera el contenido sin actualizar la suma
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   FileSeek(h, 0, SEEK_SET);
   FileWriteString(h, "ea.state=HALTED_");
   FileClose(h);
   CStateStore st3;
   st3.Init(file, false);
   t.True(!st3.Load(why), "estado alterado detectado como corrupto: " + why);
   //--- truncado (sin suma)
   h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI);
   FileWriteString(h, "ea.state=RUNNING\n");
   FileClose(h);
   t.True(!st3.Load(why), "estado truncado detectado: " + why);
   FileDelete(file);
  }

//--- 1.2.0: cartera compartida entre símbolos (misma magic)
void TestPortfolio(CTestRunner &t)
  {
   CFakeCalc calc;
   RiskConfig cfg;
   RiskDefaultConfig(cfg);
   CRiskManager rm;
   rm.Init(cfg, &calc, NULL);
   SymbolSpec spec;
   Spec(spec);
   AccountSnapshot acc;
   Account(acc, 10000, 10000);
   CDailyLossTracker daily;
   daily.Configure(0, 3.0);
   daily.Update(DAY, 10000);
   PositionRisk none[];

   t.EqDbl(rm.ExternalMoney(), 0.0, 1e-12, "sin cartera externa por defecto");
   rm.SetExternalExposure(100.0, 1);                  // 1% abierto en otro símbolo
   RiskDecision d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(d.approved, "1% en otro símbolo + 1% nuevo = 2% -> aprobado: " + d.reject_reason);
   t.EqDbl(d.exposure_before_pct, 1.0, 1e-9, "la exposición previa incluye el otro símbolo");
   t.EqDbl(d.exposure_after_pct, 2.0, 1e-9, "exposición posterior 2%");
   rm.SetExternalExposure(150.0, 1);                  // 1.5% fuera
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "exposición") >= 0, "1.5% en otro símbolo + 1% -> rechazo por exposición");
   rm.SetExternalExposure(0.0, 3);                    // 3 posiciones en break-even en otros símbolos
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "otros símbolos") >= 0, "3 posiciones en otros símbolos -> máximo de posiciones");
   PositionRisk pos[];
   AddPos(pos, DIR_LONG, 0.01, 2390, 2400);           // propia en break-even
   rm.SetExternalExposure(0.0, 2);
   d = rm.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, acc, pos, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "máximo de posiciones") >= 0, "1 propia + 2 externas = 3 -> rechazo");
   rm.SetExternalExposure(-5.0, -1);
   t.True(rm.ExternalMoney() == 0.0 && rm.ExternalPositions() == 0, "valores negativos se acotan a 0");
   rm.SetExternalExposure(150.0, 0);                  // peor caso del día: 1.5% + 1% < 3%
   AccountSnapshot a2;
   Account(a2, 10000, 10000);
   RiskConfig c2 = cfg;
   c2.max_exposure_pct = 5.0;
   CRiskManager rm2;
   rm2.Init(c2, &calc, NULL);
   rm2.SetExternalExposure(250.0, 0);                 // 2.5% fuera + 1% = 3.5% > 3% diario
   d = rm2.Assess(Sig(DIR_LONG, 2400, 2395, 2410), spec, a2, none, daily, 20, 0);
   t.True(!d.approved && StringFind(d.reject_reason, "peor caso") >= 0, "el peor caso del día cuenta el riesgo de otros símbolos");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase6");
   TestVolume(t);
   TestExposure(t);
   TestDaily(t);
   TestPortfolio(t);
   TestConfigAndGuards(t);
   TestStateStore(t);
   t.Finish();
  }
