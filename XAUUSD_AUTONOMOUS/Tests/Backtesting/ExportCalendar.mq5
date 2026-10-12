//+------------------------------------------------------------------+
//| ExportCalendar.mq5                                               |
//| Exporta el calendario económico de MT5 (USD) a un CSV en la      |
//| carpeta común para que NewsManager lo use en el Strategy Tester  |
//| (donde el calendario no está disponible).                        |
//| Ejecutar EN VIVO (cuenta demo conectada).                        |
//| Salida: <Common>/Files/XAUUSD/calendar_usd.csv                   |
//| Formato: #range;desde;hasta;exportado  y                         |
//|          time_server;currency;importance;name                    |
//| Las horas quedan en hora del servidor del bróker.                |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input int InpDaysBack    = 1100;   // días hacia atrás
input int InpDaysForward = 14;     // días hacia delante

void OnStart()
  {
   datetime now = TimeTradeServer();
   datetime from = now - (datetime)InpDaysBack * 86400;
   datetime to = now + (datetime)InpDaysForward * 86400;
   MqlCalendarValue values[];
   ResetLastError();
   int n = CalendarValueHistory(values, from, to, NULL, "USD");
   if(n <= 0)
     {
      PrintFormat("ExportCalendar: sin datos (n=%d, err=%d). ¿Terminal conectado?", n, GetLastError());
      return;
     }
   FolderCreate("XAUUSD", FILE_COMMON);
   int h = FileOpen("XAUUSD/calendar_usd.csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("ExportCalendar: no se pudo crear el archivo (err=%d)", GetLastError());
      return;
     }
   // la cobertura real termina en el último dato publicado por el calendario
   FileWriteString(h, StringFormat("#range;%s;%s;%s\r\n", TimeToString(from, TIME_DATE | TIME_MINUTES),
                                   TimeToString(to, TIME_DATE | TIME_MINUTES), TimeToString(now, TIME_DATE | TIME_MINUTES)));
   FileWriteString(h, "time_server;currency;importance;name\r\n");
   int written = 0;
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent e;
      if(!CalendarEventById(values[i].event_id, e))
         continue;
      int imp = (e.importance == CALENDAR_IMPORTANCE_HIGH) ? 3 : (e.importance == CALENDAR_IMPORTANCE_MODERATE ? 2 : 1);
      string name = e.name;
      StringReplace(name, ";", ",");
      FileWriteString(h, StringFormat("%s;USD;%d;%s\r\n", TimeToString(values[i].time, TIME_DATE | TIME_MINUTES), imp, name));
      written++;
     }
   FileClose(h);
   PrintFormat("ExportCalendar: %d eventos USD exportados (%s a %s) en Common/Files/XAUUSD/calendar_usd.csv",
               written, TimeToString(from, TIME_DATE), TimeToString(to, TIME_DATE));
  }
