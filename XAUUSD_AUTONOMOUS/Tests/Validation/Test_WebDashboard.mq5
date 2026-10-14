//+------------------------------------------------------------------+
//| Test_WebDashboard.mq5                                            |
//| Cliente del dashboard web: HMAC-SHA256 con vectores conocidos    |
//| (idénticos a WebDashboard/tests/test_server.py y RFC 4231),      |
//| escape JSON y verificación de comandos. Con InpE2EUrl e          |
//| InpE2EToken hace además una prueba de extremo a extremo contra   |
//| el servidor real (requiere la URL permitida para WebRequest).    |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/WebDashboard.mqh>
#include "TestFramework.mqh"

input string InpE2EUrl   = "";
input string InpE2EToken = "";
input string InpReportName = "Test_WebDashboard";

void TestHmac(CTestRunner &t)
  {
   t.True(CWebDashboard::Hmac("Jefe", "what do ya want for nothing?") ==
          "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC RFC 4231 caso 2");
   string k32 = "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk";
   t.True(CWebDashboard::Hmac(k32, "1760000000\nabcdef0123456789\nPOST /api/ea/telemetry\n{\"equity\":1}") ==
          "c88d5f8b42836270ba6c1f859d8eb282b414c7fcc7e638a72d1405887a21bac7", "HMAC de una petición = Python");
   t.True(CWebDashboard::Hmac(k32, "7|PAUSE|1760000000") ==
          "d35b08c8a6c43c53c3151dadbdef9896c94c9481cb32de93f90f30fcf91614e7", "HMAC de un comando = Python");
   string k100 = "";
   for(int i = 0; i < 100; i++)
      k100 += "K";
   t.True(CWebDashboard::Hmac(k100, "mensaje con clave larga") ==
          "8995e873e48253cc25933f2443131857e2817e0c86908b52505fd11251b03503", "HMAC con clave > 64 bytes = Python");
  }

void TestJson(CTestRunner &t)
  {
   t.True(CWebDashboard::JsonEscape("a\"b\\c\nd\te") == "a\\\"b\\\\c\\nd\\te", "escape JSON de comillas, barras y controles");
   t.True(CWebDashboard::JsonStr("k", "señal ñ") == "\"k\":\"señal ñ\"", "texto UTF-8 sin alterar");
   t.True(CWebDashboard::JsonNum("x", 1.5, 2) == "\"x\":1.50", "número");
   t.True(CWebDashboard::JsonBool("b", true) == "\"b\":true", "booleano");
  }

void TestCommands(CTestRunner &t)
  {
   string tok = "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk";
   long now = 1760000100;
   string good = "7|PAUSE|1760000000|" + CWebDashboard::Hmac(tok, "7|PAUSE|1760000000");
   long id;
   string cmd, why;
   t.True(CWebDashboard::ParseCommandLine(good, tok, now, 0, id, cmd, why) && id == 7 && cmd == "PAUSE", "comando válido: " + why);
   t.True(!CWebDashboard::ParseCommandLine(good, tok, now, 7, id, cmd, why) && StringFind(why, "procesado") >= 0, "id ya procesado -> rechazo");
   t.True(!CWebDashboard::ParseCommandLine(good, tok, now + 3600, 0, id, cmd, why) && StringFind(why, "ventana") >= 0, "comando viejo -> rechazo");
   string tampered = "7|SAFE_MODE|1760000000|" + CWebDashboard::Hmac(tok, "7|PAUSE|1760000000");
   t.True(!CWebDashboard::ParseCommandLine(tampered, tok, now, 0, id, cmd, why) && StringFind(why, "firma") >= 0, "comando alterado -> rechazo");
   t.True(!CWebDashboard::ParseCommandLine(good, "otro-token-otro-token-otro-token", now, 0, id, cmd, why), "otro token -> rechazo");
   string close_all = "8|CLOSE_ALL|1760000000|" + CWebDashboard::Hmac(tok, "8|CLOSE_ALL|1760000000");
   t.True(!CWebDashboard::ParseCommandLine(close_all, tok, now, 0, id, cmd, why) && StringFind(why, "no permitido") >= 0, "CLOSE_ALL firmado -> rechazo igualmente");
   t.True(!CWebDashboard::ParseCommandLine("basura", tok, now, 0, id, cmd, why), "línea mal formada -> rechazo");

   CWebDashboard wd;
   t.True(wd.Init(false, "", "", 30, false, NULL) && !wd.Enabled(), "deshabilitado por defecto");
   t.True(!wd.Init(true, "http://ejemplo.com", tok, 30, false, NULL), "rechaza http fuera de localhost");
   t.True(!wd.Init(true, "https://ejemplo.com", "corto", 30, false, NULL), "rechaza token corto");
   t.True(wd.Init(true, "https://ejemplo.com", tok, 30, true, NULL) && !wd.Enabled(), "en el tester se desactiva");
   t.True(wd.Init(true, "https://ejemplo.com/", tok, 30, false, NULL) && wd.Enabled(), "https válido");
   string n1 = wd.NewNonce(), n2 = wd.NewNonce();
   t.True(n1 != n2 && StringLen(n1) >= 16 && StringLen(n1) <= 64, "nonces distintos y de longitud válida");
   t.True(wd.Due(D'2026.01.14 12:00:00') && !wd.Due(D'2026.01.14 12:00:10') && wd.Due(D'2026.01.14 12:00:30'), "intervalo de 30 s");
   //--- backoff: una URL no permitida falla al instante (error 4014, sin red) y duplica el intervalo
   CWebDashboard wb;
   t.True(wb.Init(true, "https://servidor-no-permitido.invalid", tok, 30, false, NULL), "Init para backoff");
   string resp;
   t.EqInt(wb.Request("GET", "/api/ea/commands", "", resp, why), -1, "petición a URL no permitida -> -1");
   t.True(StringFind(why, "no permitida") >= 0 || StringFind(why, "falló") >= 0, "motivo informado: " + why);
   t.EqInt(wb.Failures(), 1, "fallo contado");
   t.EqInt(wb.EffectiveInterval(), 60, "intervalo efectivo x2 tras un fallo");
   t.True(wb.Due(D'2026.01.14 12:00:00') && !wb.Due(D'2026.01.14 12:00:59') && wb.Due(D'2026.01.14 12:01:00'), "Due respeta el backoff");
  }

void TestE2E(CTestRunner &t)
  {
   if(InpE2EUrl == "")
     {
      t.Note("prueba de extremo a extremo omitida (sin InpE2EUrl)");
      return;
     }
   CWebDashboard wd;
   t.True(wd.Init(true, InpE2EUrl, InpE2EToken, 10, false, NULL), "E2E: Init");
   string why;
   string json = "{" + CWebDashboard::JsonStr("symbol", "XAUUSD") + "," + CWebDashboard::JsonNum("equity", 10050.25, 2) + "," +
                 CWebDashboard::JsonStr("state", "RUNNING") + "," + CWebDashboard::JsonStr("last_signal", "prueba \"E2E\" ñ") + "}";
   string resp;
   int st = wd.Request("POST", "/api/ea/telemetry", json, resp, why);
   t.EqInt(st, 200, "E2E: telemetría aceptada por el servidor: " + why);
   long ids[];
   string cmds[];
   int n = wd.PollCommands(ids, cmds, why);
   t.True(n >= 1, "E2E: comando(s) recibidos y verificados: " + IntegerToString(n) + " " + why);
   if(n >= 1)
     {
      t.True(cmds[0] == "PAUSE", "E2E: el comando es PAUSE");
      t.True(wd.Ack(ids[0], why), "E2E: confirmación aceptada: " + why);
      long ids2[];
      string cmds2[];
      t.EqInt(wd.PollCommands(ids2, cmds2, why), 0, "E2E: tras confirmar no se repite");
     }
  }

void OnStart()
  {
   CTestRunner t(InpReportName);
   TestHmac(t);
   TestJson(t);
   TestCommands(t);
   TestE2E(t);
   t.Finish();
  }
