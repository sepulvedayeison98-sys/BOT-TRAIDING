//+------------------------------------------------------------------+
//| StateStore.mqh                                                   |
//| Persistencia clave=valor del estado del EA.                      |
//| - Escritura atómica: se escribe <archivo>.tmp y se renombra.     |
//| - Suma de verificación FNV-1a en la última línea: si no coincide |
//|   el estado se considera corrupto (el EA entra en modo seguro).  |
//| - NO es fuente de verdad de posiciones (lo es el servidor): solo |
//|   guarda metadatos (snapshot diario, setups consumidos,          |
//|   solicitudes pendientes, mapa posición -> señal).               |
//+------------------------------------------------------------------+
#ifndef XAUUSD_STATESTORE_MQH
#define XAUUSD_STATESTORE_MQH

#include "Types.mqh"

class CStateStore
  {
private:
   string            m_file;
   int               m_common;      // 0 o FILE_COMMON
   string            m_keys[];
   string            m_vals[];
   int               m_count;

   int               Find(const string key) const
     {
      for(int i = 0; i < m_count; i++)
         if(m_keys[i] == key)
            return i;
      return -1;
     }

   static string     Clean(const string s)
     {
      string r = s;
      StringReplace(r, "\r", " ");
      StringReplace(r, "\n", " ");
      return r;
     }

public:
                     CStateStore(void) { m_file = ""; m_common = 0; m_count = 0; }

   //--- FNV-1a de 32 bits sobre los caracteres del texto
   static uint       Checksum(const string text)
     {
      uint h = 2166136261;
      int n = StringLen(text);
      for(int i = 0; i < n; i++)
        {
         h ^= (uint)StringGetCharacter(text, i);
         h *= 16777619;
        }
      return h;
     }

   bool              Init(const string file, const bool common)
     {
      m_file = file;
      m_common = common ? FILE_COMMON : 0;
      Clear();
      return (StringLen(file) > 0);
     }

   void              Clear(void) { ArrayResize(m_keys, 0); ArrayResize(m_vals, 0); m_count = 0; }
   int               Count(void) const { return m_count; }
   string            File(void) const  { return m_file; }

   bool              Has(const string key) const { return Find(key) >= 0; }

   void              Set(const string key, const string value)
     {
      string k = Clean(key);
      StringReplace(k, "=", "_");
      int i = Find(k);
      if(i < 0)
        {
         i = m_count++;
         ArrayResize(m_keys, m_count);
         ArrayResize(m_vals, m_count);
         m_keys[i] = k;
        }
      m_vals[i] = Clean(value);
     }

   void              SetDouble(const string key, const double v) { Set(key, DoubleToString(v, 8)); }
   void              SetLong(const string key, const long v)     { Set(key, IntegerToString(v)); }
   void              SetBool(const string key, const bool v)     { Set(key, v ? "1" : "0"); }

   string            Get(const string key, const string def = "") const
     {
      int i = Find(key);
      return (i < 0) ? def : m_vals[i];
     }
   double            GetDouble(const string key, const double def = 0.0) const { int i = Find(key); return (i < 0) ? def : StringToDouble(m_vals[i]); }
   long              GetLong(const string key, const long def = 0) const       { int i = Find(key); return (i < 0) ? def : StringToInteger(m_vals[i]); }
   bool              GetBool(const string key, const bool def = false) const   { int i = Find(key); return (i < 0) ? def : (m_vals[i] == "1"); }

   bool              Remove(const string key)
     {
      int i = Find(key);
      if(i < 0)
         return false;
      for(int j = i; j < m_count - 1; j++)
        {
         m_keys[j] = m_keys[j + 1];
         m_vals[j] = m_vals[j + 1];
        }
      m_count--;
      ArrayResize(m_keys, m_count);
      ArrayResize(m_vals, m_count);
      return true;
     }

   //--- Claves que empiezan por un prefijo
   int               KeysWithPrefix(const string prefix, string &out[]) const
     {
      ArrayResize(out, 0);
      int n = 0;
      for(int i = 0; i < m_count; i++)
        {
         if(StringFind(m_keys[i], prefix) == 0)
           {
            ArrayResize(out, n + 1);
            out[n++] = m_keys[i];
           }
        }
      return n;
     }

   string            Serialize(void) const
     {
      string body = "";
      for(int i = 0; i < m_count; i++)
         body += m_keys[i] + "=" + m_vals[i] + "\n";
      return body;
     }

   //--- Guarda de forma atómica. false + motivo si falla.
   bool              Save(string &why)
     {
      string body = Serialize();
      string tmp = m_file + ".tmp";
      ResetLastError();
      int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI | m_common, '\t', CP_UTF8);
      if(h == INVALID_HANDLE)
        {
         why = StringFormat("no se pudo abrir %s (err=%d)", tmp, GetLastError());
         return false;
        }
      FileWriteString(h, body);
      FileWriteString(h, StringFormat("#checksum=%08X\n", Checksum(body)));
      FileFlush(h);
      FileClose(h);
      if(!FileMove(tmp, m_common, m_file, FILE_REWRITE | m_common))
        {
         why = StringFormat("no se pudo renombrar %s -> %s (err=%d)", tmp, m_file, GetLastError());
         return false;
        }
      why = "";
      return true;
     }

   //--- Carga. Archivo inexistente = estado vacío (true, why="sin estado previo").
   //--- Checksum inválido o formato roto = false (estado corrupto).
   bool              Load(string &why)
     {
      Clear();
      if(!FileIsExist(m_file, m_common))
        {
         why = "sin estado previo";
         return true;
        }
      int h = FileOpen(m_file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | m_common, '\t', CP_UTF8);
      if(h == INVALID_HANDLE)
        {
         why = StringFormat("no se pudo abrir %s (err=%d)", m_file, GetLastError());
         return false;
        }
      string body = "";
      string checksum_line = "";
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         if(StringLen(line) == 0)
            continue;
         if(StringFind(line, "#checksum=") == 0)
           {
            checksum_line = line;
            break;
           }
         body += line + "\n";
        }
      FileClose(h);
      if(checksum_line == "")
        {
         why = "estado sin suma de verificación (truncado o corrupto)";
         return false;
        }
      string expected = StringFormat("#checksum=%08X", Checksum(body));
      if(checksum_line != expected)
        {
         why = "suma de verificación no coincide (estado corrupto)";
         return false;
        }
      string lines[];
      int n = StringSplit(body, '\n', lines);
      for(int i = 0; i < n; i++)
        {
         if(StringLen(lines[i]) == 0)
            continue;
         int eq = StringFind(lines[i], "=");
         if(eq <= 0)
           {
            Clear();
            why = "línea sin formato clave=valor";
            return false;
           }
         Set(StringSubstr(lines[i], 0, eq), StringSubstr(lines[i], eq + 1));
        }
      why = "";
      return true;
     }
  };

#endif // XAUUSD_STATESTORE_MQH
