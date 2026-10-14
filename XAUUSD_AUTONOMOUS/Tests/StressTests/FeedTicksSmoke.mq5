//+------------------------------------------------------------------+
//| FeedTicksSmoke.mq5                                               |
//| Alimenta el símbolo personalizado XAUSYN con ticks acelerados    |
//| para la prueba de humo del EA completo (Tools/run_ea_smoke.sh).  |
//| 1) completa velas M1 desde el último dato hasta ahora,           |
//| 2) añade ticks cada InpStepSec segundos de "tiempo simulado",    |
//| 3) cierra el terminal (OnDeinit del EA se ejecuta).              |
//| Solo para pruebas: no usar en cuentas reales.                    |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input string InpSymbol  = "XAUSYN";
input int    InpTicks   = 3000;
input int    InpStepSec = 10;
input int    InpSleepMs = 40;
input bool   InpClose   = true;

double Gauss(void)
  {
   double u1 = (MathRand() + 1.0) / 32768.0, u2 = (MathRand() + 1.0) / 32768.0;
   return MathSqrt(-2.0 * MathLog(u1)) * MathCos(2.0 * M_PI * u2);
  }

void Report(const string text, const bool ok)
  {
   FolderCreate("XAUUSD");
   FolderCreate("XAUUSD/reports");
   int h = FileOpen("XAUUSD/reports/FeedTicksSmoke.txt", FILE_WRITE | FILE_TXT | FILE_ANSI, '\t', CP_UTF8);
   FileWriteString(h, "NOTE: " + text + "\r\n");
   FileWriteString(h, StringFormat("RESULT FeedTicksSmoke: %d passed, %d failed\r\n", ok ? 1 : 0, ok ? 0 : 1));
   FileClose(h);
  }

void OnStart()
  {
   MathSrand(77);
   if(!SymbolInfoInteger(InpSymbol, SYMBOL_CUSTOM))
     { Report("el símbolo " + InpSymbol + " no existe (ejecutar CreateSyntheticXAU)", false); return; }
   datetime last = iTime(InpSymbol, PERIOD_M1, 0);
   double p = iClose(InpSymbol, PERIOD_M1, 0);
   datetime now = TimeTradeServer();
   datetime now_min = now - (now % 60);
   //--- 1) velas M1 que faltan hasta el minuto actual
   int gap = (int)((now_min - last) / 60);
   int filled = 0;
   if(gap > 1)
     {
      MqlRates r[];
      ArrayResize(r, gap - 1);
      for(int i = 0; i < gap - 1; i++)
        {
         double o = p;
         p += 0.3 * Gauss();
         r[i].time = last + (datetime)(i + 1) * 60;
         r[i].open = NormalizeDouble(o, 2);
         r[i].close = NormalizeDouble(p, 2);
         r[i].high = NormalizeDouble(MathMax(o, p) + 0.3, 2);
         r[i].low = NormalizeDouble(MathMin(o, p) - 0.3, 2);
         r[i].tick_volume = 50;
         r[i].real_volume = 0;
         r[i].spread = 20;
        }
      filled = CustomRatesUpdate(InpSymbol, r);
     }
   //--- 2) ticks acelerados desde ahora
   int added = 0;
   datetime t = now_min + 1;
   for(int i = 0; i < InpTicks && !IsStopped(); i++)
     {
      MqlTick tk[1];
      ZeroMemory(tk);
      p += 0.12 * Gauss() + 0.002 * MathSin(i / 300.0);
      t += InpStepSec;
      tk[0].time = t;
      tk[0].time_msc = (long)t * 1000;
      tk[0].bid = NormalizeDouble(p, 2);
      tk[0].ask = NormalizeDouble(p + 0.20, 2);
      tk[0].flags = TICK_FLAG_BID | TICK_FLAG_ASK;
      if(CustomTicksAdd(InpSymbol, tk) > 0)
         added++;
      Sleep(InpSleepMs);
     }
   Sleep(3000);   // margen para el último temporizador del EA
   Report(StringFormat("velas M1 completadas=%d, ticks añadidos=%d de %d (simulado %s -> %s)", filled, added, InpTicks,
                       TimeToString(now_min), TimeToString(t)), added > InpTicks / 2);
   if(InpClose)
      TerminalClose(0);
  }
