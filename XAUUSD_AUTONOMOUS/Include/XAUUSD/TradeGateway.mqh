//+------------------------------------------------------------------+
//| TradeGateway.mqh                                                 |
//| Única puerta al servidor de trading. ExecutionManager y          |
//| PositionManager no llaman a OrderSend/PositionSelect directamente|
//| sino a esta interfaz, lo que permite probarlos con un servidor   |
//| simulado. CTerminalGateway es la implementación real (MT5).      |
//+------------------------------------------------------------------+
#ifndef XAUUSD_TRADEGATEWAY_MQH
#define XAUUSD_TRADEGATEWAY_MQH

#include "Types.mqh"

class CTradeGateway
  {
public:
   virtual          ~CTradeGateway(void) {}
   virtual bool      TradeAllowed(string &why) = 0;
   virtual bool      MarketOpen(const string symbol, string &why) = 0;
   virtual bool      Tick(const string symbol, MqlTick &t) = 0;
   virtual datetime  ServerTime(void) = 0;
   virtual bool      Check(MqlTradeRequest &req, MqlTradeCheckResult &res) = 0;
   virtual bool      Send(MqlTradeRequest &req, MqlTradeResult &res) = 0;
   virtual int       Positions(const string symbol, const long magic, PositionInfo &out[]) = 0;
   virtual bool      HasOrderWithComment(const string symbol, const long magic, const string comment) = 0;
   //--- Busca un deal de entrada propio con ese comentario desde `from`.
   virtual bool      FindEntryDeal(const string symbol, const long magic, const string comment, const datetime from,
                                   long &position_id, double &price) = 0;
   //--- Operaciones cerradas propias en [from, to]
   virtual int       ClosedTrades(const string symbol, const long magic, const datetime from, const datetime to,
                                  ClosedTrade &out[]) = 0;
   virtual long      FillingFlags(const string symbol) = 0;
   //--- ¿Sigue abierta la posición con este identificador?
   virtual bool      PositionAlive(const long identifier) = 0;
  };

//+------------------------------------------------------------------+
//| Implementación real                                              |
//+------------------------------------------------------------------+
class CTerminalGateway : public CTradeGateway
  {
public:
   virtual bool      TradeAllowed(string &why)
     {
      if(TerminalInfoInteger(TERMINAL_CONNECTED) == 0)                { why = "terminal desconectado"; return false; }
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)            { why = "trading algorítmico deshabilitado en el terminal"; return false; }
      if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)                      { why = "trading deshabilitado para este EA"; return false; }
      if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)              { why = "la cuenta no permite operar"; return false; }
      if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)               { why = "la cuenta no permite asesores expertos"; return false; }
      why = "";
      return true;
     }

   virtual bool      MarketOpen(const string symbol, string &why)
     {
      ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
      if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
        { why = "símbolo sin aperturas permitidas (" + EnumToString(mode) + ")"; return false; }
      MqlDateTime dt;
      datetime now = TimeTradeServer();
      TimeToStruct(now, dt);
      uint sod = (uint)(dt.hour * 3600 + dt.min * 60 + dt.sec);
      datetime from, to;
      for(uint i = 0; i < 16; i++)
        {
         if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to))
            break;
         uint f = (uint)((ulong)from % 86400);
         uint t = ((ulong)to >= 86400) ? 86400 : (uint)((ulong)to % 86400);
         if(sod >= f && sod < t)
           { why = ""; return true; }
        }
      why = "fuera de la sesión de trading del bróker";
      return false;
     }

   virtual bool      Tick(const string symbol, MqlTick &t) { return SymbolInfoTick(symbol, t); }
   virtual datetime  ServerTime(void)                     { return TimeTradeServer(); }
   virtual bool      Check(MqlTradeRequest &req, MqlTradeCheckResult &res) { ZeroMemory(res); return OrderCheck(req, res); }
   virtual bool      Send(MqlTradeRequest &req, MqlTradeResult &res)       { ZeroMemory(res); return OrderSend(req, res); }
   virtual long      FillingFlags(const string symbol)                     { return SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE); }

   virtual bool      PositionAlive(const long identifier)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t != 0 && PositionSelectByTicket(t) && PositionGetInteger(POSITION_IDENTIFIER) == identifier)
            return true;
        }
      return false;
     }

   virtual int       Positions(const string symbol, const long magic, PositionInfo &out[])
     {
      ArrayResize(out, 0);
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol || PositionGetInteger(POSITION_MAGIC) != magic)
            continue;
         ArrayResize(out, n + 1);
         out[n].ticket = ticket;
         out[n].identifier = PositionGetInteger(POSITION_IDENTIFIER);
         out[n].direction = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
         out[n].volume = PositionGetDouble(POSITION_VOLUME);
         out[n].open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         out[n].sl = PositionGetDouble(POSITION_SL);
         out[n].tp = PositionGetDouble(POSITION_TP);
         out[n].profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         out[n].open_time = (datetime)PositionGetInteger(POSITION_TIME);
         out[n].comment = PositionGetString(POSITION_COMMENT);
         out[n].magic = magic;
         n++;
        }
      return n;
     }

   virtual bool      HasOrderWithComment(const string symbol, const long magic, const string comment)
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0)
            continue;
         if(OrderGetString(ORDER_SYMBOL) == symbol && OrderGetInteger(ORDER_MAGIC) == magic &&
            OrderGetString(ORDER_COMMENT) == comment)
            return true;
        }
      return false;
     }

   virtual bool      FindEntryDeal(const string symbol, const long magic, const string comment, const datetime from,
                                   long &position_id, double &price)
     {
      if(!HistorySelect(from, TimeTradeServer() + 60))
         return false;
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != magic)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
         if(HistoryDealGetString(d, DEAL_COMMENT) != comment)
            continue;
         position_id = HistoryDealGetInteger(d, DEAL_POSITION_ID);
         price = HistoryDealGetDouble(d, DEAL_PRICE);
         return true;
        }
      return false;
     }

   virtual int       ClosedTrades(const string symbol, const long magic, const datetime from, const datetime to,
                                  ClosedTrade &out[])
     {
      ArrayResize(out, 0);
      if(!HistorySelect(from, to))
         return 0;
      int n = 0;
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != magic)
            continue;
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
         long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
         int k = -1;
         for(int j = 0; j < n; j++)
            if(out[j].identifier == pid) { k = j; break; }
         if(k < 0)
           {
            k = n++;
            ArrayResize(out, n);
            ZeroMemory(out[k]);
            out[k].identifier = pid;
            out[k].comment = "";
           }
         double vol = HistoryDealGetDouble(d, DEAL_VOLUME);
         double price = HistoryDealGetDouble(d, DEAL_PRICE);
         out[k].commission += HistoryDealGetDouble(d, DEAL_COMMISSION);
         out[k].swap += HistoryDealGetDouble(d, DEAL_SWAP);
         out[k].profit += HistoryDealGetDouble(d, DEAL_PROFIT);
         if(entry == DEAL_ENTRY_IN)
           {
            out[k].direction = ((ENUM_DEAL_TYPE)HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
            out[k].volume = vol;
            out[k].entry_price = price;
            out[k].open_time = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            out[k].comment = HistoryDealGetString(d, DEAL_COMMENT);
           }
         else
           {
            out[k].exit_price = price;
            out[k].close_time = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
           }
        }
      //--- solo operaciones con entrada y salida
      int m = 0;
      for(int j = 0; j < n; j++)
        {
         if(out[j].open_time > 0 && out[j].close_time > 0)
           {
            if(m != j)
               out[m] = out[j];
            m++;
           }
        }
      ArrayResize(out, m);
      return m;
     }
  };

#endif // XAUUSD_TRADEGATEWAY_MQH
