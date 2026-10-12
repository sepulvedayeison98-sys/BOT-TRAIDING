//+------------------------------------------------------------------+
//| NewsManager.mqh                                                  |
//| Bloqueo de nuevas entradas alrededor de eventos macro USD.       |
//|                                                                  |
//| Fuentes:                                                         |
//|  - En vivo: calendario económico de MT5 (CalendarValueHistory +  |
//|    CalendarEventById), moneda USD.                               |
//|  - Strategy Tester: el calendario no está disponible (según la   |
//|    documentación de MQL5); se usa un CSV exportado en vivo con   |
//|    Tests/Backtesting/ExportCalendar.mq5 (carpeta común).         |
//|  - Proveedor externo: no implementado (requiere API y            |
//|    credenciales); ver Documentation/ARCHITECTURE.md §13.         |
//|                                                                  |
//| Todas las horas están en hora del SERVIDOR del bróker (la misma  |
//| zona en vivo y en el historial del tester).                      |
//|                                                                  |
//| Política conservadora (decisión D3): si la fuente no puede       |
//| verificarse (error, vacía, desactualizada o fuera de cobertura), |
//| se bloquean TODAS las entradas nuevas y se registra el motivo.   |
//| Nunca se inventan eventos ni se usan datos viejos como actuales. |
//+------------------------------------------------------------------+
#ifndef XAUUSD_NEWSMANAGER_MQH
#define XAUUSD_NEWSMANAGER_MQH

#include "Types.mqh"
#include "Logger.mqh"

#define NM_MODULE "NewsManager"
#define NM_CSV_FILE "XAUUSD/calendar_usd.csv"

struct NewsConfig
  {
   int               major_before_min;     // NFP, CPI, PCE, FOMC, tasas, Fed
   int               major_after_min;
   int               usd_before_min;       // otros eventos USD importantes
   int               usd_after_min;
   int               min_importance;       // importancia mínima para NEWS_TIER_USD (3 = alta)
   int               refresh_minutes;      // frecuencia de recarga en vivo
   int               max_source_age_min;   // antigüedad máxima de la última carga correcta
   int               lookahead_days;       // horizonte de eventos cargados
   bool              block_if_unverified;  // D3: true (aprobado)
  };

void NewsDefaultConfig(NewsConfig &c)
  {
   c.major_before_min = 30;
   c.major_after_min = 30;
   c.usd_before_min = 20;
   c.usd_after_min = 20;
   c.min_importance = 3;
   c.refresh_minutes = 15;
   c.max_source_age_min = 60;
   c.lookahead_days = 7;
   c.block_if_unverified = true;
  }

bool NewsValidateConfig(const NewsConfig &c, string &reason)
  {
   if(c.major_before_min < 0 || c.major_after_min < 0 || c.usd_before_min < 0 || c.usd_after_min < 0 ||
      c.major_before_min > 240 || c.major_after_min > 240 || c.usd_before_min > 240 || c.usd_after_min > 240)
     { reason = "ventanas de noticias fuera de [0, 240] min"; return false; }
   if(c.min_importance < 1 || c.min_importance > 3)
     { reason = "min_importance debe estar en [1, 3]"; return false; }
   if(c.refresh_minutes < 1 || c.max_source_age_min < c.refresh_minutes || c.lookahead_days < 1)
     { reason = "frecuencia/antigüedad/horizonte inválidos"; return false; }
   reason = "";
   return true;
  }

class CNewsManager
  {
private:
   NewsConfig        m_cfg;
   CLogger          *m_log;
   bool              m_ready;
   bool              m_tester;
   NewsEvent         m_events[];
   bool              m_source_ok;
   string            m_source_reason;
   datetime          m_last_ok;          // última carga correcta (hora servidor)
   datetime          m_last_attempt;
   datetime          m_cover_from;       // cobertura del CSV
   datetime          m_cover_to;

   static bool       Has(const string lower, const string word) { return StringFind(lower, word) >= 0; }

   void              Fail(const string why)
     {
      m_source_ok = false;
      m_source_reason = why;
      if(m_log != NULL)
         m_log.LogOnChange("news.source", why, LOG_WARN, NM_MODULE, "SOURCE_UNVERIFIED", why);
     }

   //--- Carga desde el calendario de MT5 (en vivo)
   bool              LoadFromCalendar(const datetime now)
     {
      MqlCalendarValue values[];
      ResetLastError();
      datetime from = now - 86400;
      datetime to = now + (datetime)m_cfg.lookahead_days * 86400;
      int n = CalendarValueHistory(values, from, to, NULL, "USD");
      int err = GetLastError();
      if(n < 0 || (n == 0 && err != 0))
        { Fail(StringFormat("calendario MT5 no disponible (err=%d)", err)); return false; }
      if(n == 0)
        { Fail("el calendario MT5 no devolvió eventos USD para los próximos días (no verificable)"); return false; }
      NewsEvent ev[];
      int k = 0;
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent e;
         if(!CalendarEventById(values[i].event_id, e))
            continue;
         int imp = (e.importance == CALENDAR_IMPORTANCE_HIGH) ? 3 : (e.importance == CALENDAR_IMPORTANCE_MODERATE ? 2 : 1);
         ENUM_NEWS_TIER tier = Classify(e.name, imp, m_cfg.min_importance);
         if(tier == NEWS_TIER_NONE)
            continue;
         ArrayResize(ev, k + 1);
         ev[k].time = values[i].time;
         ev[k].currency = "USD";
         ev[k].importance = imp;
         ev[k].name = e.name;
         ev[k].tier = tier;
         k++;
        }
      SetEvents(ev, now, true, "MT5");
      m_cover_from = from;
      m_cover_to = to;
      return true;
     }

   //--- Carga desde el CSV exportado (Strategy Tester)
   bool              LoadFromCsv(const datetime now)
     {
      if(!FileIsExist(NM_CSV_FILE, FILE_COMMON))
        { Fail("CSV de calendario no encontrado en la carpeta común: " + NM_CSV_FILE); return false; }
      int h = FileOpen(NM_CSV_FILE, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, '\t', CP_UTF8);
      if(h == INVALID_HANDLE)
        { Fail(StringFormat("no se pudo abrir el CSV de calendario (err=%d)", GetLastError())); return false; }
      NewsEvent ev[];
      int k = 0;
      datetime cf = 0, ct = 0;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         if(StringLen(line) == 0)
            continue;
         string f[];
         int nf = StringSplit(line, ';', f);
         if(StringFind(line, "#range") == 0 && nf >= 3)
           {
            cf = StringToTime(f[1]);
            ct = StringToTime(f[2]);
            continue;
           }
         if(StringGetCharacter(line, 0) == '#' || nf < 4 || f[0] == "time_server")
            continue;
         int imp = (int)StringToInteger(f[2]);
         ENUM_NEWS_TIER tier = Classify(f[3], imp, m_cfg.min_importance);
         if(tier == NEWS_TIER_NONE)
            continue;
         ArrayResize(ev, k + 1);
         ev[k].time = StringToTime(f[0]);
         ev[k].currency = f[1];
         ev[k].importance = imp;
         ev[k].name = f[3];
         ev[k].tier = tier;
         k++;
        }
      FileClose(h);
      if(cf <= 0 || ct <= cf)
        { Fail("CSV de calendario sin línea #range válida"); return false; }
      m_cover_from = cf;
      m_cover_to = ct;
      SetEvents(ev, now, true, "CSV");
      return true;
     }

public:
   string            m_source_name;

                     CNewsManager(void)
     {
      NewsDefaultConfig(m_cfg);
      m_log = NULL;
      m_ready = false;
      m_tester = false;
      m_source_ok = false;
      m_source_reason = "sin cargar";
      m_last_ok = 0;
      m_last_attempt = 0;
      m_cover_from = 0;
      m_cover_to = 0;
      m_source_name = "";
     }

   bool              Init(const NewsConfig &cfg, const bool tester, CLogger *log)
     {
      m_log = log;
      string reason;
      if(!NewsValidateConfig(cfg, reason))
        {
         if(m_log != NULL) m_log.Critical(NM_MODULE, "CONFIG_INVALID", reason);
         else PrintFormat("[%s] CONFIG_INVALID %s", NM_MODULE, reason);
         m_ready = false;
         return false;
        }
      m_cfg = cfg;
      m_tester = tester;
      m_ready = true;
      return true;
     }

   //--- Clasificación por nombre (inglés, como lo publica el calendario de MT5) e importancia
   static ENUM_NEWS_TIER Classify(const string name, const int importance, const int min_importance)
     {
      string s = name;
      StringToLower(s);
      if(Has(s, "nonfarm") || Has(s, "non-farm") || Has(s, "cpi") || Has(s, "consumer price") ||
         Has(s, "pce") || Has(s, "personal consumption") || Has(s, "fomc") || Has(s, "fed interest rate") ||
         Has(s, "interest rate decision") || Has(s, "federal funds") || Has(s, "fed chair") ||
         Has(s, "powell") || Has(s, "federal reserve"))
         return NEWS_TIER_MAJOR;
      bool employment = Has(s, "unemployment") || Has(s, "jobless") || Has(s, "adp") || Has(s, "jolts") ||
                        Has(s, "employment") || Has(s, "payroll");
      if(employment && importance >= 2)
         return NEWS_TIER_USD;
      if(importance >= min_importance)
         return NEWS_TIER_USD;
      return NEWS_TIER_NONE;
     }

   //--- Inyección directa (pruebas y proveedores adicionales)
   void              SetEvents(const NewsEvent &ev[], const datetime fetched_at, const bool ok, const string source)
     {
      int n = ArraySize(ev);
      ArrayResize(m_events, n);
      for(int i = 0; i < n; i++)
         m_events[i] = ev[i];
      m_source_ok = ok;
      m_source_reason = ok ? "" : "fuente marcada como no válida";
      m_source_name = source;
      if(ok)
        {
         m_last_ok = fetched_at;
         m_cover_from = fetched_at - 86400;
         m_cover_to = fetched_at + (datetime)m_cfg.lookahead_days * 86400;
        }
     }

   void              SetCoverage(const datetime from, const datetime to) { m_cover_from = from; m_cover_to = to; }

   //--- Recarga si toca. En el tester el CSV se carga una vez.
   void              Refresh(const datetime now)
     {
      if(!m_ready)
         return;
      if(m_tester)
        {
         if(m_last_attempt == 0)
           {
            m_last_attempt = now;
            LoadFromCsv(now);
           }
         return;
        }
      if(m_last_attempt != 0 && now - m_last_attempt < (datetime)m_cfg.refresh_minutes * 60)
         return;
      m_last_attempt = now;
      if(LoadFromCalendar(now) && m_log != NULL)
         m_log.LogOnChange("news.source", "ok", LOG_INFO, NM_MODULE, "SOURCE_OK",
                           StringFormat("calendario cargado: %d eventos relevantes", ArraySize(m_events)));
     }

   int               EventCount(void) const { return ArraySize(m_events); }

   //--- Estado de bloqueo en el instante now (hora servidor)
   NewsState         Evaluate(const datetime now)
     {
      NewsState st;
      st.blocked = false;
      st.source_ok = m_source_ok;
      st.reason = "";
      st.source = m_source_name;
      st.last_refresh = m_last_ok;
      st.next_name = "";
      st.next_time = 0;
      st.minutes_to_next = -1;
      if(!m_ready)
        { st.blocked = true; st.source_ok = false; st.reason = "NewsManager no inicializado"; return st; }
      //--- verificación de la fuente
      string unverified = "";
      if(!m_source_ok)
         unverified = m_source_reason;
      else
         if(!m_tester && now - m_last_ok > (datetime)m_cfg.max_source_age_min * 60)
            unverified = StringFormat("calendario desactualizado: última carga correcta %s", TimeToString(m_last_ok));
         else
            if(now < m_cover_from || now > m_cover_to)
               unverified = StringFormat("instante %s fuera de la cobertura del calendario [%s, %s]", TimeToString(now),
                                         TimeToString(m_cover_from), TimeToString(m_cover_to));
      if(unverified != "")
        {
         st.source_ok = false;
         if(m_cfg.block_if_unverified)
           {
            st.blocked = true;
            st.reason = "política conservadora: " + unverified;
            return st;
           }
        }
      //--- ventanas
      for(int i = 0; i < ArraySize(m_events); i++)
        {
         const NewsEvent e = m_events[i];
         if(e.tier == NEWS_TIER_NONE)
            continue;   // no relevante (las cargas ya lo filtran; defensa ante inyección directa)
         int before = (e.tier == NEWS_TIER_MAJOR) ? m_cfg.major_before_min : m_cfg.usd_before_min;
         int after = (e.tier == NEWS_TIER_MAJOR) ? m_cfg.major_after_min : m_cfg.usd_after_min;
         if(now >= e.time - (datetime)before * 60 && now <= e.time + (datetime)after * 60)
           {
            st.blocked = true;
            st.reason = StringFormat("ventana de noticia %s: %s a las %s (-%d/+%d min)",
                                     (e.tier == NEWS_TIER_MAJOR ? "mayor" : "USD"), e.name,
                                     TimeToString(e.time, TIME_DATE | TIME_MINUTES), before, after);
           }
         if(e.time > now && (st.next_time == 0 || e.time < st.next_time))
           {
            st.next_time = e.time;
            st.next_name = e.name;
           }
        }
      if(st.next_time > 0)
         st.minutes_to_next = (int)((st.next_time - now) / 60);
      return st;
     }
  };

#endif // XAUUSD_NEWSMANAGER_MQH
