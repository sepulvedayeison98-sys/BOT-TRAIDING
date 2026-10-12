//+------------------------------------------------------------------+
//| SyntheticSymbol.mqh                                              |
//| Crea símbolos personalizados con historial M1 sintético para     |
//| pruebas de integración sin bróker. Solo para pruebas.            |
//+------------------------------------------------------------------+
#ifndef XAUUSD_SYNTHETICSYMBOL_MQH
#define XAUUSD_SYNTHETICSYMBOL_MQH

//--- Precio sintético en función del índice de minuto (0 = más antiguo)
typedef double (*TSynthPriceFunc)(const int i);

//--- Elimina el símbolo personalizado si existe.
void SyntheticSymbolDelete(const string name)
  {
   if(SymbolInfoInteger(name, SYMBOL_CUSTOM))
     {
      SymbolSelect(name, false);
      CustomSymbolDelete(name);
     }
  }

//--- Crea el símbolo con `minutes` velas M1 que terminan en el minuto actual
//--- (hora del servidor) y añade un tick con spread `spread_price`.
//--- Devuelve "" si todo fue bien o el motivo del fallo.
string SyntheticSymbolCreate(const string name, const int minutes, TSynthPriceFunc price_func,
                             const double spread_price, const int rates_spread_points)
  {
   SyntheticSymbolDelete(name);
   if(!CustomSymbolCreate(name, "XAUUSD_Tests"))
      return StringFormat("CustomSymbolCreate falló (err=%d)", GetLastError());
   CustomSymbolSetInteger(name, SYMBOL_DIGITS, 2);
   CustomSymbolSetDouble(name, SYMBOL_POINT, 0.01);
   CustomSymbolSetDouble(name, SYMBOL_TRADE_TICK_SIZE, 0.01);

   datetime now = TimeTradeServer();
   datetime end = now - (now % 60);
   datetime start = end - (datetime)(minutes - 1) * 60;
   MqlRates r[];
   ArrayResize(r, minutes);
   double prev = price_func(0);
   for(int i = 0; i < minutes; i++)
     {
      double c = price_func(i + 1);
      r[i].time = start + (datetime)i * 60;
      r[i].open = NormalizeDouble(prev, 2);
      r[i].close = NormalizeDouble(c, 2);
      r[i].high = NormalizeDouble(MathMax(prev, c) + 0.30, 2);
      r[i].low = NormalizeDouble(MathMin(prev, c) - 0.30, 2);
      r[i].tick_volume = 50 + (i % 17);
      r[i].real_volume = 0;
      r[i].spread = rates_spread_points;
      prev = c;
     }
   int upd = CustomRatesUpdate(name, r);
   if(upd != minutes)
      return StringFormat("CustomRatesUpdate cargó %d de %d velas", upd, minutes);
   if(!SymbolSelect(name, true))
      return "SymbolSelect falló";
   MqlTick tk[1];
   ZeroMemory(tk);
   tk[0].time = r[minutes - 1].time + 30;
   tk[0].time_msc = (long)tk[0].time * 1000;
   tk[0].bid = r[minutes - 1].close;
   tk[0].ask = NormalizeDouble(r[minutes - 1].close + spread_price, 2);
   tk[0].flags = TICK_FLAG_BID | TICK_FLAG_ASK;
   if(CustomTicksAdd(name, tk) <= 0)
      return "CustomTicksAdd falló";
   return "";
  }

#endif // XAUUSD_SYNTHETICSYMBOL_MQH
