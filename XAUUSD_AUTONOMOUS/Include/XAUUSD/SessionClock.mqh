//+------------------------------------------------------------------+
//| SessionClock.mqh                                                 |
//| Conversión hora servidor <-> UTC y detección de sesiones         |
//| Londres / Nueva York con sus reglas de horario de verano.        |
//|                                                                  |
//| - Nunca asume la zona horaria de Colombia (UTC-5 solo display).  |
//| - En vivo: offset = TimeTradeServer() - TimeGMT(), redondeado a  |
//|   15 min. TimeGMT() depende del reloj y zona del PC: si el PC    |
//|   está mal configurado, el offset será incorrecto (se valida el  |
//|   rango y se registra).                                          |
//| - En el Strategy Tester TimeGMT() no permite medir el offset     |
//|   real del servidor, por lo que se usa offset estándar + regla   |
//|   DST configurables.                                             |
//+------------------------------------------------------------------+
#ifndef XAUUSD_SESSIONCLOCK_MQH
#define XAUUSD_SESSIONCLOCK_MQH

#include "Types.mqh"

#define SECONDS_PER_DAY   86400
#define SECONDS_PER_HOUR  3600
#define COLOMBIA_UTC_OFFSET_SEC (-5 * 3600)

//+------------------------------------------------------------------+
//| Reglas de calendario puras (sin dependencia del terminal).       |
//+------------------------------------------------------------------+
class CTimeRules
  {
public:
   //--- datetime 00:00 del día indicado
   static datetime   MakeDate(const int year, const int mon, const int day,
                              const int hour = 0, const int minute = 0)
     {
      MqlDateTime dt;
      ZeroMemory(dt);
      dt.year = year;
      dt.mon = mon;
      dt.day = day;
      dt.hour = hour;
      dt.min = minute;
      dt.sec = 0;
      return StructToTime(dt);
     }

   static int        DayOfWeek(const datetime t)
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      return dt.day_of_week;   // 0 = domingo
     }

   static int        DaysInMonth(const int year, const int mon)
     {
      int ny = (mon == 12) ? year + 1 : year;
      int nm = (mon == 12) ? 1 : mon + 1;
      return (int)((MakeDate(ny, nm, 1) - MakeDate(year, mon, 1)) / SECONDS_PER_DAY);
     }

   //--- Día del mes del n-ésimo domingo (n >= 1)
   static int        NthSunday(const int year, const int mon, const int n)
     {
      int dow = DayOfWeek(MakeDate(year, mon, 1));
      int first = 1 + (7 - dow) % 7;
      return first + 7 * (n - 1);
     }

   static int        LastSunday(const int year, const int mon)
     {
      int last = DaysInMonth(year, mon);
      int dow = DayOfWeek(MakeDate(year, mon, last));
      return last - dow;
     }

   //--- UE/UK: verano desde último domingo de marzo 01:00 UTC
   //--- hasta último domingo de octubre 01:00 UTC.
   static bool       IsEuDstUtc(const datetime utc)
     {
      MqlDateTime dt;
      TimeToStruct(utc, dt);
      datetime start = MakeDate(dt.year, 3, LastSunday(dt.year, 3), 1, 0);
      datetime end   = MakeDate(dt.year, 10, LastSunday(dt.year, 10), 1, 0);
      return (utc >= start && utc < end);
     }

   //--- EE. UU.: verano desde 2.º domingo de marzo 02:00 hora estándar (07:00 UTC)
   //--- hasta 1.er domingo de noviembre 02:00 hora de verano (06:00 UTC).
   static bool       IsUsDstUtc(const datetime utc)
     {
      MqlDateTime dt;
      TimeToStruct(utc, dt);
      datetime start = MakeDate(dt.year, 3, NthSunday(dt.year, 3, 2), 7, 0);
      datetime end   = MakeDate(dt.year, 11, NthSunday(dt.year, 11, 1), 6, 0);
      return (utc >= start && utc < end);
     }

   static int        LondonOffsetSec(const datetime utc)  { return IsEuDstUtc(utc) ? SECONDS_PER_HOUR : 0; }
   static int        NewYorkOffsetSec(const datetime utc) { return IsUsDstUtc(utc) ? -4 * SECONDS_PER_HOUR : -5 * SECONDS_PER_HOUR; }

   //--- Minuto del día y día de la semana en hora local
   static int        MinuteOfDay(const datetime local_time)
     {
      return (int)((local_time % SECONDS_PER_DAY) / 60);
     }

   //--- ¿Está local_time en [open_min, close_min) en un día laborable (lun-vie)?
   static bool       InWindow(const datetime local_time, const int open_min, const int close_min)
     {
      int dow = DayOfWeek(local_time);
      if(dow == 0 || dow == 6)
         return false;
      int m = MinuteOfDay(local_time);
      if(open_min <= close_min)
         return (m >= open_min && m < close_min);
      // ventana que cruza medianoche
      return (m >= open_min || m < close_min);
     }

   static int        RoundOffset(const int raw_sec, const int step_sec)
     {
      double q = MathRound((double)raw_sec / step_sec);
      return (int)q * step_sec;
     }

   //--- Offset del servidor según offset estándar + regla DST (evaluada en UTC)
   static int        RuleOffsetSec(const datetime utc, const int std_offset_sec, const ENUM_DST_RULE rule)
     {
      if(rule == DST_RULE_EU && IsEuDstUtc(utc))
         return std_offset_sec + SECONDS_PER_HOUR;
      if(rule == DST_RULE_US && IsUsDstUtc(utc))
         return std_offset_sec + SECONDS_PER_HOUR;
      return std_offset_sec;
     }
  };

//+------------------------------------------------------------------+
//| Configuración                                                    |
//+------------------------------------------------------------------+
struct SessionClockConfig
  {
   int               london_open_min;    // hora local de Londres, minutos desde 00:00
   int               london_close_min;
   int               newyork_open_min;   // hora local de Nueva York
   int               newyork_close_min;
   int               tester_std_offset_sec;
   ENUM_DST_RULE     tester_dst_rule;
   int               max_abs_offset_sec;
  };

void SessionClockDefaultConfig(SessionClockConfig &c)
  {
   c.london_open_min = 8 * 60;
   c.london_close_min = 16 * 60 + 30;
   c.newyork_open_min = 8 * 60;
   c.newyork_close_min = 17 * 60;
   c.tester_std_offset_sec = 0;
   c.tester_dst_rule = DST_RULE_NONE;
   c.max_abs_offset_sec = 14 * SECONDS_PER_HOUR;
  }

//+------------------------------------------------------------------+
//| Reloj de sesiones                                                |
//+------------------------------------------------------------------+
class CSessionClock
  {
private:
   SessionClockConfig m_cfg;
   bool              m_tester;
   bool              m_offset_valid;
   int               m_measured_offset_sec;
   string            m_last_error;

   bool              ValidWindow(const int open_min, const int close_min) const
     {
      return (open_min >= 0 && open_min < 1440 && close_min >= 0 && close_min < 1440 && open_min != close_min);
     }

public:
                     CSessionClock(void)
     {
      SessionClockDefaultConfig(m_cfg);
      m_tester = false;
      m_offset_valid = false;
      m_measured_offset_sec = 0;
      m_last_error = "";
     }

   bool              Init(const SessionClockConfig &cfg, const bool is_tester)
     {
      m_cfg = cfg;
      m_tester = is_tester;
      if(!ValidWindow(cfg.london_open_min, cfg.london_close_min) ||
         !ValidWindow(cfg.newyork_open_min, cfg.newyork_close_min))
        {
         m_last_error = "ventana de sesión inválida";
         return false;
        }
      if(MathAbs(cfg.tester_std_offset_sec) > cfg.max_abs_offset_sec || cfg.tester_std_offset_sec % 900 != 0)
        {
         m_last_error = "offset estándar del tester inválido (debe ser múltiplo de 15 min y <= 14 h)";
         return false;
        }
      return Refresh();
     }

   //--- Recalcula el offset en vivo. En el tester no mide (usa la regla).
   bool              Refresh(void)
     {
      if(m_tester)
        {
         m_offset_valid = true;
         return true;
        }
      int raw = (int)(TimeTradeServer() - TimeGMT());
      int rounded = CTimeRules::RoundOffset(raw, 900);
      if(MathAbs(rounded) > m_cfg.max_abs_offset_sec)
        {
         m_offset_valid = false;
         m_last_error = StringFormat("offset medido fuera de rango: %d s (¿reloj/zona del PC incorrectos?)", raw);
         return false;
        }
      m_measured_offset_sec = rounded;
      m_offset_valid = true;
      m_last_error = "";
      return true;
     }

   bool              OffsetValid(void) const { return m_offset_valid; }
   string            LastError(void) const   { return m_last_error; }
   bool              IsTester(void) const    { return m_tester; }

   //--- Offset (servidor - UTC) aplicable a una hora de servidor dada.
   int               ServerOffsetAt(const datetime server_time) const
     {
      if(!m_tester)
         return m_measured_offset_sec;
      // aproximación: la regla DST se evalúa en UTC estándar; error posible solo
      // dentro de la hora exacta de transición.
      datetime approx_utc = server_time - m_cfg.tester_std_offset_sec;
      return CTimeRules::RuleOffsetSec(approx_utc, m_cfg.tester_std_offset_sec, m_cfg.tester_dst_rule);
     }

   datetime          ServerToUtc(const datetime server_time) const { return server_time - ServerOffsetAt(server_time); }

   datetime          UtcToServer(const datetime utc) const
     {
      if(!m_tester)
         return utc + m_measured_offset_sec;
      return utc + CTimeRules::RuleOffsetSec(utc, m_cfg.tester_std_offset_sec, m_cfg.tester_dst_rule);
     }

   static datetime   UtcToLondon(const datetime utc)   { return utc + CTimeRules::LondonOffsetSec(utc); }
   static datetime   UtcToNewYork(const datetime utc)  { return utc + CTimeRules::NewYorkOffsetSec(utc); }
   static datetime   UtcToColombia(const datetime utc) { return utc + COLOMBIA_UTC_OFFSET_SEC; }

   bool              IsLondonOpenUtc(const datetime utc) const
     {
      return CTimeRules::InWindow(UtcToLondon(utc), m_cfg.london_open_min, m_cfg.london_close_min);
     }

   bool              IsNewYorkOpenUtc(const datetime utc) const
     {
      return CTimeRules::InWindow(UtcToNewYork(utc), m_cfg.newyork_open_min, m_cfg.newyork_close_min);
     }

   ENUM_SESSION_ID   SessionAtUtc(const datetime utc) const
     {
      bool lon = IsLondonOpenUtc(utc);
      bool ny = IsNewYorkOpenUtc(utc);
      if(lon && ny)
         return SESSION_OVERLAP;
      if(lon)
         return SESSION_LONDON;
      if(ny)
         return SESSION_NEWYORK;
      return SESSION_NONE;
     }

   ENUM_SESSION_ID   SessionAtServer(const datetime server_time) const
     {
      return SessionAtUtc(ServerToUtc(server_time));
     }

   //--- ¿El bróker permite operar el símbolo en este momento? (según SymbolInfoSessionTrade)
   static bool       SymbolTradeSessionOpen(const string symbol, const datetime server_time)
     {
      MqlDateTime dt;
      TimeToStruct(server_time, dt);
      uint sec_of_day = (uint)(dt.hour * 3600 + dt.min * 60 + dt.sec);
      datetime from, to;
      for(uint i = 0; i < 16; i++)
        {
         if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to))
            break;
         uint f = (uint)((ulong)from % SECONDS_PER_DAY);
         uint t = (uint)((ulong)to % SECONDS_PER_DAY);
         if((ulong)to >= SECONDS_PER_DAY)   // sesión hasta 24:00
            t = SECONDS_PER_DAY;
         if(sec_of_day >= f && sec_of_day < t)
            return true;
        }
      return false;
     }
  };

#endif // XAUUSD_SESSIONCLOCK_MQH
