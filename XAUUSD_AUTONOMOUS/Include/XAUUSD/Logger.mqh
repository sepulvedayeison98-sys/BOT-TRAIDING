//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| Registro estructurado y persistente. Nunca detiene el EA:        |
//| si el fichero falla, degrada a Print() y lo reporta.             |
//|                                                                  |
//| Formato (TSV, una línea por evento):                             |
//| server_time  utc_time  level  module  event  corr_id  message    |
//| Ruta: MQL5/Files/XAUUSD/logs/<prefix>_<YYYYMMDD>.log             |
//| (en el Strategy Tester: sandbox del agente)                      |
//+------------------------------------------------------------------+
#ifndef XAUUSD_LOGGER_MQH
#define XAUUSD_LOGGER_MQH

#include "Types.mqh"

#define LOGGER_MAX_THROTTLE_KEYS 128

class CLogger
  {
private:
   string            m_prefix;
   string            m_folder;
   ENUM_LOG_LEVEL    m_min_file_level;
   ENUM_LOG_LEVEL    m_min_print_level;
   int               m_handle;
   string            m_current_file;
   int               m_current_day;      // YYYYMMDD del fichero abierto
   bool              m_file_ok;
   bool              m_file_error_reported;
   int               m_utc_offset_sec;   // servidor - UTC, lo actualiza el EA vía SetUtcOffset
   ulong             m_id_counter;
   //--- registro "solo al cambiar" (evita saturar el log con gates repetidos)
   string            m_keys[];
   string            m_values[];
   int               m_key_count;

   int               DayKey(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      return dt.year * 10000 + dt.mon * 100 + dt.day;
     }

   bool              EnsureFile(const datetime server_time)
     {
      int day = DayKey(server_time);
      if(m_handle != INVALID_HANDLE && day == m_current_day)
         return true;
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
      m_current_day = day;
      m_current_file = StringFormat("%s/%s_%d.log", m_folder, m_prefix, day);
      ResetLastError();
      m_handle = FileOpen(m_current_file,
                          FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ, '\t', CP_UTF8);
      if(m_handle == INVALID_HANDLE)
        {
         m_file_ok = false;
         if(!m_file_error_reported)
           {
            PrintFormat("[%s][Logger] ERROR no se pudo abrir %s (err=%d). Se degrada a Print().",
                        m_prefix, m_current_file, GetLastError());
            m_file_error_reported = true;
           }
         return false;
        }
      FileSeek(m_handle, 0, SEEK_END);
      if(FileTell(m_handle) == 0)
         FileWriteString(m_handle, "server_time\tutc_time\tlevel\tmodule\tevent\tcorr_id\tmessage\r\n");
      m_file_ok = true;
      m_file_error_reported = false;
      return true;
     }

   string            Sanitize(const string s) const
     {
      string r = s;
      StringReplace(r, "\t", " ");
      StringReplace(r, "\r", " ");
      StringReplace(r, "\n", " | ");
      return r;
     }

public:
                     CLogger(void)
     {
      m_prefix = XAU_PROJECT_NAME;
      m_folder = XAU_FILES_ROOT + "/logs";
      m_min_file_level = LOG_DEBUG;
      m_min_print_level = LOG_INFO;
      m_handle = INVALID_HANDLE;
      m_current_file = "";
      m_current_day = 0;
      m_file_ok = false;
      m_file_error_reported = false;
      m_utc_offset_sec = 0;
      m_id_counter = 0;
      m_key_count = 0;
     }

                    ~CLogger(void) { Close(); }

   bool              Init(const string prefix, const ENUM_LOG_LEVEL min_file_level,
                          const ENUM_LOG_LEVEL min_print_level)
     {
      if(StringLen(prefix) > 0)
         m_prefix = prefix;
      m_min_file_level = min_file_level;
      m_min_print_level = min_print_level;
      // FolderCreate devuelve false si ya existe; no es error.
      FolderCreate(XAU_FILES_ROOT);
      FolderCreate(m_folder);
      MathSrand((uint)(GetMicrosecondCount() & 0x7FFFFFFF));
      return EnsureFile(TimeTradeServer());
     }

   void              Close(void)
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileFlush(m_handle);
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
     }

   void              SetUtcOffset(const int offset_sec) { m_utc_offset_sec = offset_sec; }
   bool              FileOk(void) const               { return m_file_ok; }
   string            CurrentFile(void) const          { return m_current_file; }

   //--- Identificador único: PREFIJO-YYYYMMDDhhmmss-contador-aleatorio
   string            NewId(const string prefix)
     {
      m_id_counter++;
      MqlDateTime dt;
      TimeToStruct(TimeTradeServer(), dt);
      return StringFormat("%s-%04d%02d%02d%02d%02d%02d-%s-%04X", prefix,
                          dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec,
                          IntegerToString((long)m_id_counter), MathRand() & 0xFFFF);
     }

   void              Log(const ENUM_LOG_LEVEL level, const string module, const string event,
                         const string message, const string corr_id = "")
     {
      datetime server_time = TimeTradeServer();
      if(level >= m_min_print_level)
         PrintFormat("[%s][%s][%s] %s %s%s", EnumLogLevelToString(level), module, event,
                     message, (corr_id == "" ? "" : "id="), corr_id);
      if(level < m_min_file_level)
         return;
      if(!EnsureFile(server_time))
        {
         // Degradación: si no se imprimió arriba, imprimir errores graves igualmente.
         if(level < m_min_print_level && level >= LOG_WARN)
            PrintFormat("[%s][%s][%s] %s", EnumLogLevelToString(level), module, event, message);
         return;
        }
      string line = StringFormat("%s\t%s\t%s\t%s\t%s\t%s\t%s\r\n",
                                 TimeToString(server_time, TIME_DATE | TIME_SECONDS),
                                 TimeToString(server_time - m_utc_offset_sec, TIME_DATE | TIME_SECONDS),
                                 EnumLogLevelToString(level), Sanitize(module), Sanitize(event),
                                 Sanitize(corr_id), Sanitize(message));
      if(FileWriteString(m_handle, line) == 0)
        {
         m_file_ok = false;
         return;
        }
      FileFlush(m_handle);
     }

   //--- Registra solo si el valor asociado a la clave cambió desde la última vez.
   //--- Devuelve true si se registró.
   bool              LogOnChange(const string key, const string value, const ENUM_LOG_LEVEL level,
                                 const string module, const string event, const string message)
     {
      for(int i = 0; i < m_key_count; i++)
        {
         if(m_keys[i] == key)
           {
            if(m_values[i] == value)
               return false;
            m_values[i] = value;
            Log(level, module, event, message);
            return true;
           }
        }
      if(m_key_count < LOGGER_MAX_THROTTLE_KEYS)
        {
         ArrayResize(m_keys, m_key_count + 1);
         ArrayResize(m_values, m_key_count + 1);
         m_keys[m_key_count] = key;
         m_values[m_key_count] = value;
         m_key_count++;
        }
      Log(level, module, event, message);
      return true;
     }

   void              Debug(const string module, const string event, const string msg, const string id = "")    { Log(LOG_DEBUG, module, event, msg, id); }
   void              Info(const string module, const string event, const string msg, const string id = "")     { Log(LOG_INFO, module, event, msg, id); }
   void              Warn(const string module, const string event, const string msg, const string id = "")     { Log(LOG_WARN, module, event, msg, id); }
   void              Error(const string module, const string event, const string msg, const string id = "")    { Log(LOG_ERROR, module, event, msg, id); }
   void              Critical(const string module, const string event, const string msg, const string id = "") { Log(LOG_CRITICAL, module, event, msg, id); }
  };

#endif // XAUUSD_LOGGER_MQH
