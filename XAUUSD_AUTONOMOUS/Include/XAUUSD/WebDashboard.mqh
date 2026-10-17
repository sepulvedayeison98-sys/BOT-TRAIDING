//+------------------------------------------------------------------+
//| WebDashboard.mqh                                                 |
//| Cliente del dashboard web (WebDashboard/server.py).              |
//|  - Solo conexiones SALIENTES (WebRequest). La URL debe estar en  |
//|    Herramientas > Opciones > Asesores Expertos > WebRequest.     |
//|  - WebRequest no funciona en el Strategy Tester: se desactiva.   |
//|  - Firma HMAC-SHA256 de cada petición con el token del dashboard |
//|    (NO es una credencial de trading): "ts\nnonce\nMÉTODO ruta\n  |
//|    cuerpo".                                                      |
//|  - Comandos recibidos: solo PAUSE, RESUME, SAFE_MODE; firmados   |
//|    por el servidor; se rechazan firmas inválidas, comandos con   |
//|    más de 10 min y identificadores ya procesados.                |
//|  - WebRequest es síncrono (timeout corto): se llama desde        |
//|    OnTimer cada InpWebIntervalSec, nunca desde OnTick. Si el     |
//|    servidor falla, el intervalo crece (hasta x10) para no        |
//|    bloquear la gestión protectora con esperas repetidas.         |
//|  - Varias instancias (un gráfico por símbolo, 1.2.0): cada una   |
//|    se identifica con su símbolo en la consulta de comandos y en  |
//|    la confirmación (?i=<símbolo>, dentro de la ruta firmada).    |
//+------------------------------------------------------------------+
#ifndef XAUUSD_WEBDASHBOARD_MQH
#define XAUUSD_WEBDASHBOARD_MQH

#include "Types.mqh"
#include "Logger.mqh"

#define WD_MODULE "WebDashboard"
#define WD_COMMAND_MAX_AGE_SEC 600

class CWebDashboard
  {
private:
   string            m_url;
   string            m_token;
   int               m_interval;
   int               m_timeout_ms;
   bool              m_enabled;
   datetime          m_last_cycle;
   long              m_last_cmd_id;
   int               m_failures;
   CLogger          *m_log;
   ulong             m_nonce_counter;
   string            m_instance;

   static void       ToBytes(const string s, uchar &out[])
     {
      int n = StringToCharArray(s, out, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(out, MathMax(n - 1, 0));   // sin el terminador nulo
     }

   static string     Hex(const uchar &b[])
     {
      string h = "";
      for(int i = 0; i < ArraySize(b); i++)
         h += StringFormat("%02x", b[i]);
      return h;
     }

   static bool       Sha256(const uchar &data[], uchar &out[])
     {
      uchar key[];
      return CryptEncode(CRYPT_HASH_SHA256, data, key, out) == 32;
     }

public:
                     CWebDashboard(void)
     {
      m_url = "";
      m_token = "";
      m_interval = 30;
      m_timeout_ms = 2500;
      m_enabled = false;
      m_last_cycle = 0;
      m_last_cmd_id = 0;
      m_failures = 0;
      m_instance = "";
      m_log = NULL;
      m_nonce_counter = 0;
     }

   //--- HMAC-SHA256 (RFC 2104) en hexadecimal
   static string     Hmac(const string key, const string message)
     {
      uchar raw[], m[];
      ToBytes(key, raw);
      ToBytes(message, m);
      if(ArraySize(raw) > 64)
        {
         uchar hk[];
         Sha256(raw, hk);
         ArrayFree(raw);
         ArrayCopy(raw, hk);
        }
      //--- clave de 64 bytes con relleno de ceros explícito (ArrayResize no garantiza ceros)
      uchar k[64];
      ArrayInitialize(k, 0);
      ArrayCopy(k, raw, 0, 0, MathMin(ArraySize(raw), 64));
      uchar inner[], outer[];
      ArrayResize(inner, 64 + ArraySize(m));
      for(int i = 0; i < 64; i++)
         inner[i] = (uchar)(k[i] ^ 0x36);
      ArrayCopy(inner, m, 64, 0, WHOLE_ARRAY);
      uchar ih[];
      if(!Sha256(inner, ih))
         return "";
      ArrayResize(outer, 64 + 32);
      for(int i = 0; i < 64; i++)
         outer[i] = (uchar)(k[i] ^ 0x5c);
      ArrayCopy(outer, ih, 64, 0, 32);
      uchar oh[];
      if(!Sha256(outer, oh))
         return "";
      return Hex(oh);
     }

   static string     JsonEscape(const string s)
     {
      string r = "";
      for(int i = 0; i < StringLen(s); i++)
        {
         ushort c = StringGetCharacter(s, i);
         if(c == '"') r += "\\\"";
         else if(c == '\\') r += "\\\\";
         else if(c == '\n') r += "\\n";
         else if(c == '\r') r += "\\r";
         else if(c == '\t') r += "\\t";
         else if(c < 0x20) r += StringFormat("\\u%04x", c);
         else r += ShortToString(c);
        }
      return r;
     }

   static string     JsonStr(const string key, const string value) { return "\"" + key + "\":\"" + JsonEscape(value) + "\""; }
   static string     JsonNum(const string key, const double value, const int digits)
     {
      if(!MathIsValidNumber(value))
         return "\"" + key + "\":null";
      return "\"" + key + "\":" + DoubleToString(value, digits);
     }
   static string     JsonBool(const string key, const bool value) { return "\"" + key + "\":" + (value ? "true" : "false"); }

   //--- Verifica una línea "id|cmd|created|firma" del servidor (pura, testeable).
   static bool       ParseCommandLine(const string line, const string token, const long now_utc, const long last_id,
                                      long &id, string &cmd, string &why)
     {
      string f[];
      if(StringSplit(line, '|', f) != 4)
        { why = "formato inválido"; return false; }
      id = StringToInteger(f[0]);
      cmd = f[1];
      long created = StringToInteger(f[2]);
      if(id <= 0 || created <= 0)
        { why = "identificador o fecha inválidos"; return false; }
      string expected = Hmac(token, f[0] + "|" + f[1] + "|" + f[2]);
      if(expected == "" || expected != f[3])
        { why = "firma del comando inválida"; return false; }
      if(id <= last_id)
        { why = "comando ya procesado (posible reenvío)"; return false; }
      if(now_utc - created > WD_COMMAND_MAX_AGE_SEC || created - now_utc > 120)
        { why = "comando fuera de la ventana de tiempo"; return false; }
      if(cmd != "PAUSE" && cmd != "RESUME" && cmd != "SAFE_MODE")
        { why = "comando no permitido: " + cmd; return false; }
      why = "";
      return true;
     }

   bool              Init(const bool enabled, const string url, const string token, const int interval_sec,
                          const bool tester, CLogger *log)
     {
      m_log = log;
      m_enabled = false;
      if(!enabled)
         return true;
      if(tester)
        {
         if(m_log != NULL) m_log.Info(WD_MODULE, "DISABLED", "WebRequest no está disponible en el Strategy Tester");
         return true;
        }
      string u = url;
      while(StringLen(u) > 0 && StringGetCharacter(u, StringLen(u) - 1) == '/')
         u = StringSubstr(u, 0, StringLen(u) - 1);
      if(StringFind(u, "https://") != 0 && StringFind(u, "http://127.0.0.1") != 0 && StringFind(u, "http://localhost") != 0)
        {
         if(m_log != NULL) m_log.Error(WD_MODULE, "CONFIG_INVALID", "la URL del dashboard debe ser https:// (http solo para 127.0.0.1/localhost)");
         return false;
        }
      if(StringLen(token) < 32)
        {
         if(m_log != NULL) m_log.Error(WD_MODULE, "CONFIG_INVALID", "el token del dashboard debe tener al menos 32 caracteres");
         return false;
        }
      if(interval_sec < 10 || interval_sec > 600)
        {
         if(m_log != NULL) m_log.Error(WD_MODULE, "CONFIG_INVALID", "el intervalo debe estar entre 10 y 600 s");
         return false;
        }
      m_url = u;
      m_token = token;
      m_interval = interval_sec;
      m_enabled = true;
      MathSrand((uint)(GetMicrosecondCount() & 0x7FFFFFFF));
      if(m_log != NULL) m_log.Info(WD_MODULE, "ENABLED", "dashboard web: " + m_url + " cada " + IntegerToString(m_interval) + " s");
      return true;
     }

   bool              Enabled(void) const     { return m_enabled; }
   void              SetInstance(const string instance) { m_instance = instance; }
   string            Instance(void) const    { return m_instance; }

   //--- Codificación de URL (RFC 3986, bytes UTF-8; sin reservar solo A-Z a-z 0-9 - _ . ~)
   static string     UrlEncode(const string s)
     {
      uchar b[];
      ToBytes(s, b);
      string out = "";
      for(int i = 0; i < ArraySize(b); i++)
        {
         uchar c = b[i];
         if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
            out += CharToString(c);
         else
            out += StringFormat("%%%02X", c);
        }
      return out;
     }

   //--- Ruta con la instancia (vacía = cliente anterior a 1.2.0: el servidor lo trata igual)
   string            InstancePath(const string path) const
     {
      return (m_instance == "") ? path : path + "?i=" + UrlEncode(m_instance);
     }
   long              LastCommandId(void) const { return m_last_cmd_id; }
   void              SetLastCommandId(const long id) { m_last_cmd_id = id; }
   int               Failures(void) const    { return m_failures; }

   //--- Intervalo efectivo: crece con los fallos consecutivos (x2, x3 ... hasta x10)
   int               EffectiveInterval(void) const { return m_interval * (int)MathMin(1 + m_failures, 10); }

   //--- ¿Toca un ciclo (telemetría + comandos)?
   bool              Due(const datetime now)
     {
      if(!m_enabled || now - m_last_cycle < EffectiveInterval())
         return false;
      m_last_cycle = now;
      return true;
     }

   string            NewNonce(void)
     {
      m_nonce_counter++;
      return StringFormat("%08x%08x%04x", (uint)GetMicrosecondCount(), (uint)(MathRand() * 65536 + MathRand()),
                          (uint)(m_nonce_counter & 0xFFFF));
     }

   //--- Petición firmada. Devuelve el código HTTP (o -1) y el cuerpo de la respuesta.
   int               Request(const string method, const string path, const string body, string &response, string &why)
     {
      response = "";
      if(!m_enabled)
        { why = "deshabilitado"; return -1; }
      string ts = IntegerToString((long)TimeGMT());
      string nonce = NewNonce();
      string sig = Hmac(m_token, ts + "\n" + nonce + "\n" + method + " " + path + "\n" + body);
      string headers = "Content-Type: application/json\r\nX-XAD-Timestamp: " + ts + "\r\nX-XAD-Nonce: " + nonce +
                       "\r\nX-XAD-Signature: " + sig + "\r\n";
      char data[], result[];
      if(body != "")
        {
         int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
         ArrayResize(data, MathMax(n - 1, 0));
        }
      string result_headers;
      ResetLastError();
      int status = WebRequest(method, m_url + path, headers, m_timeout_ms, data, result, result_headers);
      if(status == -1)
        {
         int err = GetLastError();
         why = (err == 4014) ? "URL no permitida: añádela en Herramientas > Opciones > Asesores Expertos > WebRequest"
                             : StringFormat("WebRequest falló (err=%d)", err);
         m_failures++;
         return -1;
        }
      response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      if(status >= 200 && status < 300)
        { m_failures = 0; why = ""; }
      else
        { m_failures++; why = StringFormat("HTTP %d: %s", status, StringSubstr(response, 0, 120)); }
      return status;
     }

   bool              SendTelemetry(const string json, string &why)
     {
      string resp;
      return Request("POST", "/api/ea/telemetry", json, resp, why) == 200;
     }

   //--- Comandos verificados y nuevos (ids en orden). Los inválidos se registran y se ignoran.
   int               PollCommands(long &ids[], string &cmds[], string &why)
     {
      ArrayResize(ids, 0);
      ArrayResize(cmds, 0);
      string resp;
      if(Request("GET", InstancePath("/api/ea/commands"), "", resp, why) != 200)
         return -1;
      string lines[];
      int n = StringSplit(resp, '\n', lines);
      int k = 0;
      long last = m_last_cmd_id;
      for(int i = 0; i < n; i++)
        {
         string line = lines[i];
         StringTrimRight(line);
         StringTrimLeft(line);
         if(line == "")
            continue;
         long id;
         string cmd, reason;
         if(!ParseCommandLine(line, m_token, (long)TimeGMT(), last, id, cmd, reason))
           {
            // firma válida pero ya aplicado (la confirmación anterior no llegó): solo se re-confirma
            if(id > 0 && id <= m_last_cmd_id && StringFind(reason, "procesado") >= 0)
              {
               string w;
               Ack(id, w);
               continue;
              }
            if(m_log != NULL) m_log.Warn(WD_MODULE, "COMMAND_REJECTED", reason + ": " + StringSubstr(line, 0, 60));
            continue;
           }
         ArrayResize(ids, k + 1);
         ArrayResize(cmds, k + 1);
         ids[k] = id;
         cmds[k] = cmd;
         k++;
         last = id;
        }
      return k;
     }

   bool              Ack(const long id, string &why)
     {
      string resp;
      bool ok = (Request("POST", InstancePath("/api/ea/ack"), IntegerToString(id), resp, why) == 200);
      if(ok && id > m_last_cmd_id)
         m_last_cmd_id = id;
      return ok;
     }
  };

#endif // XAUUSD_WEBDASHBOARD_MQH
