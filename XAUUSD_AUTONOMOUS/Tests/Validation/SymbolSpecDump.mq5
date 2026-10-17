//+------------------------------------------------------------------+
//| SymbolSpecDump.mq5                                               |
//| Exporta las especificaciones REALES del símbolo y de la cuenta   |
//| del bróker (no incluye número de cuenta ni credenciales).        |
//| Salida: MQL5/Files/XAUUSD/reports/symbol_spec_<símbolo>.txt      |
//| Ejecutar sobre un gráfico de XAUUSD en la cuenta demo de Deriv.  |
//| Solo lectura: no envía órdenes.                                  |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input string InpSymbol = "";   // Símbolo (vacío = símbolo del gráfico)

string g_lines[];

void Out(const string key, const string value)
  {
   int n = ArraySize(g_lines);
   ArrayResize(g_lines, n + 1);
   g_lines[n] = key + " = " + value;
  }

void OutD(const string key, const double v)  { Out(key, DoubleToString(v, 10)); }
void OutL(const string key, const long v)    { Out(key, IntegerToString(v)); }
void OutB(const string key, const bool v)    { Out(key, v ? "true" : "false"); }

string DayName(const int d)
  {
   string names[7] = {"SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"};
   return names[d];
  }

string FillingFlags(const long f)
  {
   string s = "";
   if((f & SYMBOL_FILLING_FOK) != 0) s += "FOK ";
   if((f & SYMBOL_FILLING_IOC) != 0) s += "IOC ";
   if(s == "") s = "(ninguno: solo RETURN)";
   return s;
  }

void DumpSessions(const string sym)
  {
   for(int d = 0; d < 7; d++)
     {
      string trade = "", quote = "";
      datetime from, to;
      for(uint i = 0; i < 16; i++)
        {
         if(!SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)d, i, from, to))
            break;
         trade += StringFormat("%s-%s ", TimeToString(from, TIME_MINUTES), TimeToString(to, TIME_MINUTES));
        }
      for(uint i = 0; i < 16; i++)
        {
         if(!SymbolInfoSessionQuote(sym, (ENUM_DAY_OF_WEEK)d, i, from, to))
            break;
         quote += StringFormat("%s-%s ", TimeToString(from, TIME_MINUTES), TimeToString(to, TIME_MINUTES));
        }
      Out("session.trade." + DayName(d), trade == "" ? "(cerrado)" : trade);
      Out("session.quote." + DayName(d), quote == "" ? "(cerrado)" : quote);
     }
  }

void DumpHistory(const string sym)
  {
   ENUM_TIMEFRAMES tfs[3] = {PERIOD_H1, PERIOD_M15, PERIOD_M5};
   for(int i = 0; i < 3; i++)
     {
      string p = "history." + EnumToString(tfs[i]);
      OutL(p + ".bars_terminal", Bars(sym, tfs[i]));
      Out(p + ".first_date_terminal", TimeToString((datetime)SeriesInfoInteger(sym, tfs[i], SERIES_FIRSTDATE)));
      Out(p + ".first_date_server", TimeToString((datetime)SeriesInfoInteger(sym, tfs[i], SERIES_SERVER_FIRSTDATE)));
      OutB(p + ".synchronized", SeriesInfoInteger(sym, tfs[i], SERIES_SYNCHRONIZED) != 0);
     }
   MqlTick ticks[];
   ulong to_msc = (ulong)TimeCurrent() * 1000;
   ulong from_msc = to_msc - 86400000;
   int nt = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, from_msc, to_msc);
   OutL("history.ticks_last_24h", nt);
  }

void DumpCalendar(void)
  {
   MqlCalendarValue values[];
   datetime now = TimeTradeServer();
   ResetLastError();
   int past = CalendarValueHistory(values, now - 7 * 86400, now, NULL, "USD");
   int err = GetLastError();
   OutL("calendar.usd_values_last_7d", past);
   OutL("calendar.last_error", err);
   int high = 0;
   for(int i = 0; i < past && i < 2000; i++)
     {
      MqlCalendarEvent ev;
      if(CalendarEventById(values[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
         high++;
     }
   OutL("calendar.usd_high_importance_last_7d", high);
   int future = CalendarValueHistory(values, now, now + 7 * 86400, NULL, "USD");
   OutL("calendar.usd_values_next_7d", future);
  }

void DumpCalc(const string sym)
  {
   MqlTick t;
   if(!SymbolInfoTick(sym, t) || t.ask <= 0.0)
     {
      Out("calc", "sin tick disponible");
      return;
     }
   double profit = 0.0, margin = 0.0;
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(OrderCalcProfit(ORDER_TYPE_BUY, sym, 1.0, t.ask, t.ask - 1.0, profit))
      OutD("calc.loss_1lot_per_1.00_price_move", -profit);
   else
      OutL("calc.loss_1lot_error", GetLastError());
   if(OrderCalcProfit(ORDER_TYPE_BUY, sym, vmin, t.ask, t.ask - 1.0, profit))
      OutD("calc.loss_minlot_per_1.00_price_move", -profit);
   if(OrderCalcMargin(ORDER_TYPE_BUY, sym, 1.0, t.ask, margin))
      OutD("calc.margin_buy_1lot", margin);
   else
      OutL("calc.margin_1lot_error", GetLastError());
   if(OrderCalcMargin(ORDER_TYPE_BUY, sym, vmin, t.ask, margin))
      OutD("calc.margin_buy_minlot", margin);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tvl = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(ts > 0.0)
      OutD("calc.crosscheck_tickvalue_loss_1lot_per_1.00", 1.0 / ts * tvl);
  }

void OnStart()
  {
   string sym = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(sym, true))
     {
      PrintFormat("SymbolSpecDump: símbolo %s no disponible", sym);
      return;
     }
   Out("generated_server_time", TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS));
   Out("generated_gmt_time", TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS));
   Out("generated_local_time", TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS));
   OutL("server_gmt_offset_sec_raw", (long)(TimeTradeServer() - TimeGMT()));
   OutL("terminal.build", TerminalInfoInteger(TERMINAL_BUILD));
   OutB("terminal.connected", TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
   OutB("terminal.trade_allowed", TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);

   //--- cuenta (sin número de cuenta)
   Out("account.company", AccountInfoString(ACCOUNT_COMPANY));
   Out("account.server", AccountInfoString(ACCOUNT_SERVER));
   Out("account.currency", AccountInfoString(ACCOUNT_CURRENCY));
   Out("account.trade_mode", EnumToString((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)));
   Out("account.margin_mode", EnumToString((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)));
   OutL("account.leverage", AccountInfoInteger(ACCOUNT_LEVERAGE));
   OutL("account.limit_orders", AccountInfoInteger(ACCOUNT_LIMIT_ORDERS));
   OutB("account.trade_allowed", AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) != 0);
   OutB("account.trade_expert", AccountInfoInteger(ACCOUNT_TRADE_EXPERT) != 0);
   Out("account.margin_so_mode", EnumToString((ENUM_ACCOUNT_STOPOUT_MODE)AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)));
   OutD("account.margin_so_call", AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL));
   OutD("account.margin_so_so", AccountInfoDouble(ACCOUNT_MARGIN_SO_SO));

   //--- símbolo
   Out("symbol.name", sym);
   Out("symbol.description", SymbolInfoString(sym, SYMBOL_DESCRIPTION));
   Out("symbol.path", SymbolInfoString(sym, SYMBOL_PATH));
   Out("symbol.currency_base", SymbolInfoString(sym, SYMBOL_CURRENCY_BASE));
   Out("symbol.currency_profit", SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT));
   Out("symbol.currency_margin", SymbolInfoString(sym, SYMBOL_CURRENCY_MARGIN));
   OutL("symbol.digits", SymbolInfoInteger(sym, SYMBOL_DIGITS));
   OutD("symbol.point", SymbolInfoDouble(sym, SYMBOL_POINT));
   OutD("symbol.contract_size", SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE));
   OutD("symbol.tick_size", SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE));
   OutD("symbol.tick_value", SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE));
   OutD("symbol.tick_value_profit", SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_PROFIT));
   OutD("symbol.tick_value_loss", SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS));
   OutD("symbol.volume_min", SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));
   OutD("symbol.volume_max", SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX));
   OutD("symbol.volume_step", SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP));
   OutD("symbol.volume_limit", SymbolInfoDouble(sym, SYMBOL_VOLUME_LIMIT));
   OutL("symbol.stops_level_points", SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL));
   OutL("symbol.freeze_level_points", SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL));
   OutL("symbol.spread_points_now", SymbolInfoInteger(sym, SYMBOL_SPREAD));
   OutB("symbol.spread_float", SymbolInfoInteger(sym, SYMBOL_SPREAD_FLOAT) != 0);
   Out("symbol.trade_mode", EnumToString((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE)));
   Out("symbol.execution_mode", EnumToString((ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(sym, SYMBOL_TRADE_EXEMODE)));
   Out("symbol.calc_mode", EnumToString((ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_CALC_MODE)));
   Out("symbol.filling_modes", FillingFlags(SymbolInfoInteger(sym, SYMBOL_FILLING_MODE)));
   OutL("symbol.order_mode_flags", SymbolInfoInteger(sym, SYMBOL_ORDER_MODE));
   OutD("symbol.margin_initial", SymbolInfoDouble(sym, SYMBOL_MARGIN_INITIAL));
   OutD("symbol.margin_maintenance", SymbolInfoDouble(sym, SYMBOL_MARGIN_MAINTENANCE));
   Out("symbol.swap_mode", EnumToString((ENUM_SYMBOL_SWAP_MODE)SymbolInfoInteger(sym, SYMBOL_SWAP_MODE)));
   OutD("symbol.swap_long", SymbolInfoDouble(sym, SYMBOL_SWAP_LONG));
   OutD("symbol.swap_short", SymbolInfoDouble(sym, SYMBOL_SWAP_SHORT));
   Out("symbol.swap_rollover3days", EnumToString((ENUM_DAY_OF_WEEK)SymbolInfoInteger(sym, SYMBOL_SWAP_ROLLOVER3DAYS)));
   OutD("symbol.bid", SymbolInfoDouble(sym, SYMBOL_BID));
   OutD("symbol.ask", SymbolInfoDouble(sym, SYMBOL_ASK));

   DumpSessions(sym);
   DumpCalc(sym);
   DumpHistory(sym);
   DumpCalendar();

   FolderCreate("XAUUSD");
   FolderCreate("XAUUSD/reports");
   string fname = "XAUUSD/reports/symbol_spec_" + sym + ".txt";
   int h = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI, '\t', CP_UTF8);
   for(int i = 0; i < ArraySize(g_lines); i++)
     {
      Print(g_lines[i]);
      if(h != INVALID_HANDLE)
         FileWriteString(h, g_lines[i] + "\r\n");
     }
   if(h != INVALID_HANDLE)
     {
      FileClose(h);
      PrintFormat("SymbolSpecDump: escrito MQL5/Files/%s", fname);
     }
   else
      PrintFormat("SymbolSpecDump: no se pudo escribir %s (err=%d)", fname, GetLastError());
  }
