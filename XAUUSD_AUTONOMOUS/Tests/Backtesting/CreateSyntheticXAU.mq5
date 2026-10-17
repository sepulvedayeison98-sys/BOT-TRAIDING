//+------------------------------------------------------------------+
//| CreateSyntheticXAU.mq5                                           |
//| Crea (o recrea) el símbolo personalizado XAUSYN con ~120 días de |
//| historial M1 sintético y regímenes alternos conocidos            |
//| (alcista, lateral, bajista, lateral, choque de volatilidad).     |
//| Sirve para ensayar el pipeline Strategy Tester -> CSV -> reporte |
//| SIN bróker. Los resultados NO dicen nada del mercado real.       |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include "../Validation/SyntheticSymbol.mqh"

input string InpName = "XAUSYN";
input int    InpDays = 120;
input int    InpSeed = 42;
input bool   InpCloseTerminal = false;   // cerrar el terminal al terminar (automatización: guarda el símbolo)

double g_prices[];

double PriceAt(const int i) { return g_prices[i]; }

//--- normal estándar (Box-Muller) con el generador de MQL5
double Gauss(void)
  {
   double u1 = (MathRand() + 1.0) / 32768.0;
   double u2 = (MathRand() + 1.0) / 32768.0;
   return MathSqrt(-2.0 * MathLog(u1)) * MathCos(2.0 * M_PI * u2);
  }

void OnStart()
  {
   int minutes = InpDays * 1440;
   ArrayResize(g_prices, minutes + 1);
   MathSrand(InpSeed);
   double p = 2400.0, center = 2400.0;
   int block = 10 * 1440;   // bloques de 10 días
   for(int i = 0; i <= minutes; i++)
     {
      int phase = (i / block) % 5;
      if(i % block == 0)
         center = p;
      double noise = 0.25 * Gauss();
      switch(phase)
        {
         case 0: p += 0.006 + noise; break;                          // alcista
         case 1: p += 0.002 * (center - p) + noise; break;           // lateral (revierte al centro)
         case 2: p += -0.006 + noise; break;                         // bajista
         case 3: p += 0.002 * (center - p) + noise; break;           // lateral
         default: p += 0.002 * (center - p) + 4.0 * 0.25 * Gauss(); // volatilidad x4
        }
      if(p < 100.0)
         p = 100.0;
      g_prices[i] = p;
     }
   string err = SyntheticSymbolCreate(InpName, minutes, PriceAt, 0.25, 20);
   if(err != "")
      PrintFormat("CreateSyntheticXAU: ERROR %s", err);
   else
      PrintFormat("CreateSyntheticXAU: %s creado con %d velas M1", InpName, minutes);
   // Marca de finalización para automatización
   FolderCreate("XAUUSD");
   FolderCreate("XAUUSD/reports");
   int h = FileOpen("XAUUSD/reports/CreateSyntheticXAU.txt", FILE_WRITE | FILE_TXT | FILE_ANSI, '\t', CP_UTF8);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, (err == "" ? "OK " : "ERROR ") + err + "\r\n");
      FileClose(h);
     }
   // la definición del símbolo personalizado se guarda al cerrar el terminal de forma ordenada
   if(InpCloseTerminal)
      TerminalClose(0);
  }
