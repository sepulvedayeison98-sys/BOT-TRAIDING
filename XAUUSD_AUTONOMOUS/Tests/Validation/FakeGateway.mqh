//+------------------------------------------------------------------+
//| FakeGateway.mqh                                                  |
//| Servidor de trading simulado para pruebas: códigos de retorno    |
//| programables, posiciones en memoria, historial de deals.         |
//+------------------------------------------------------------------+
#ifndef XAUUSD_FAKEGATEWAY_MQH
#define XAUUSD_FAKEGATEWAY_MQH

#include <XAUUSD/TradeGateway.mqh>

class CFakeGateway : public CTradeGateway
  {
public:
   bool              allowed;
   bool              open;
   MqlTick           tick;
   datetime          now;
   uint              codes[];          // cola de retcodes para Send (vacía = DONE)
   int               code_idx;
   uint              check_code;
   bool              exec_on_uncertain; // con TIMEOUT/CONNECTION la operación sí se crea
   bool              alter_comment;     // el "bróker" cambia el comentario
   bool              order_in_process;
   double            fill_offset;       // diferencia precio de ejecución vs solicitado
   long              filling;
   PositionInfo      positions[];
   ClosedTrade       closed[];
   string            deal_comment[];
   long              deal_pid[];
   double            deal_price[];
   long              next_id;
   int               sends;
   int               checks;
   MqlTradeRequest   last;

                     CFakeGateway(void)
     {
      allowed = true;
      open = true;
      ZeroMemory(tick);
      tick.bid = 2400.00;
      tick.ask = 2400.20;
      now = D'2026.01.14 12:00';
      code_idx = 0;
      check_code = 0;
      exec_on_uncertain = false;
      alter_comment = false;
      order_in_process = false;
      fill_offset = 0.0;
      filling = SYMBOL_FILLING_FOK;
      next_id = 5000;
      sends = 0;
      checks = 0;
     }

   void              Queue(const uint c) { int n = ArraySize(codes); ArrayResize(codes, n + 1); codes[n] = c; }
   void              SetPrice(const double bid, const double ask) { tick.bid = bid; tick.ask = ask; tick.time = now; }

   void              AddPosition(const ENUM_DIRECTION d, const double vol, const double open_price, const double sl,
                                 const double tp, const string comment, const long magic)
     {
      int n = ArraySize(positions);
      ArrayResize(positions, n + 1);
      positions[n].ticket = (ulong)next_id;
      positions[n].identifier = next_id;
      next_id++;
      positions[n].direction = d;
      positions[n].volume = vol;
      positions[n].open_price = open_price;
      positions[n].sl = sl;
      positions[n].tp = tp;
      positions[n].profit = 0;
      positions[n].open_time = now;
      positions[n].comment = comment;
      positions[n].magic = magic;
     }

   int               FindTicket(const ulong t) const
     {
      for(int i = 0; i < ArraySize(positions); i++)
         if(positions[i].ticket == t)
            return i;
      return -1;
     }

   virtual bool      TradeAllowed(string &why)                       { why = allowed ? "" : "trading no permitido (simulado)"; return allowed; }
   virtual bool      MarketOpen(const string symbol, string &why)    { why = open ? "" : "mercado cerrado (simulado)"; return open; }
   virtual bool      Tick(const string symbol, MqlTick &t)          { t = tick; return true; }
   virtual datetime  ServerTime(void)                               { return now; }
   virtual long      FillingFlags(const string symbol)               { return filling; }
   virtual bool      Check(MqlTradeRequest &req, MqlTradeCheckResult &res)
     {
      checks++;
      ZeroMemory(res);
      res.retcode = check_code;
      return (check_code == 0);
     }

   virtual bool      Send(MqlTradeRequest &req, MqlTradeResult &res)
     {
      sends++;
      last = req;
      ZeroMemory(res);
      uint code = (code_idx < ArraySize(codes)) ? codes[code_idx++] : TRADE_RETCODE_DONE;
      res.retcode = code;
      bool uncertain = (code == TRADE_RETCODE_TIMEOUT || code == TRADE_RETCODE_CONNECTION || code == 0);
      if(req.action == TRADE_ACTION_SLTP)
        {
         int i = FindTicket(req.position);
         if(code == TRADE_RETCODE_DONE && i >= 0)
           {
            positions[i].sl = req.sl;
            positions[i].tp = req.tp;
           }
         return (code == TRADE_RETCODE_DONE);
        }
      if(req.action == TRADE_ACTION_DEAL && req.position > 0)
        {
         int i = FindTicket(req.position);
         if(code == TRADE_RETCODE_DONE && i >= 0)
           {
            for(int j = i; j < ArraySize(positions) - 1; j++)
               positions[j] = positions[j + 1];
            ArrayResize(positions, ArraySize(positions) - 1);
           }
         return (code == TRADE_RETCODE_DONE);
        }
      if(req.action == TRADE_ACTION_DEAL && (code == TRADE_RETCODE_DONE || (uncertain && exec_on_uncertain)))
        {
         double px = req.price + fill_offset * (req.type == ORDER_TYPE_BUY ? 1.0 : -1.0);
         AddPosition(req.type == ORDER_TYPE_BUY ? DIR_LONG : DIR_SHORT, req.volume, px, req.sl, req.tp,
                     alter_comment ? "altered by broker" : req.comment, (long)req.magic);
         int k = ArraySize(deal_comment);
         ArrayResize(deal_comment, k + 1);
         ArrayResize(deal_pid, k + 1);
         ArrayResize(deal_price, k + 1);
         deal_comment[k] = alter_comment ? "altered by broker" : req.comment;
         deal_pid[k] = next_id - 1;
         deal_price[k] = px;
         if(code == TRADE_RETCODE_DONE)
           {
            res.deal = (ulong)(next_id - 1);
            res.order = (ulong)(next_id - 1);
            res.price = px;
            res.volume = req.volume;
           }
        }
      return (code == TRADE_RETCODE_DONE);
     }

   virtual int       Positions(const string symbol, const long magic, PositionInfo &out[])
     {
      ArrayResize(out, 0);
      int n = 0;
      for(int i = 0; i < ArraySize(positions); i++)
        {
         if(positions[i].magic != magic)
            continue;
         ArrayResize(out, n + 1);
         out[n++] = positions[i];
        }
      return n;
     }

   virtual bool      HasOrderWithComment(const string symbol, const long magic, const string comment) { return order_in_process; }

   virtual bool      FindEntryDeal(const string symbol, const long magic, const string comment, const datetime from,
                                   long &position_id, double &price)
     {
      for(int i = 0; i < ArraySize(deal_comment); i++)
        {
         if(deal_comment[i] == comment)
           {
            position_id = deal_pid[i];
            price = deal_price[i];
            return true;
           }
        }
      return false;
     }

   virtual int       ClosedTrades(const string symbol, const long magic, const datetime from, const datetime to,
                                  ClosedTrade &out[])
     {
      ArrayResize(out, 0);
      int n = 0;
      for(int i = 0; i < ArraySize(closed); i++)
        {
         if(closed[i].close_time < from || closed[i].close_time > to)
            continue;
         ArrayResize(out, n + 1);
         out[n++] = closed[i];
        }
      return n;
     }

   void              AddClosed(const double profit, const datetime close_time, const ENUM_DIRECTION d = DIR_LONG,
                               const string comment = "")
     {
      int n = ArraySize(closed);
      ArrayResize(closed, n + 1);
      ZeroMemory(closed[n]);
      closed[n].identifier = 9000 + n;
      closed[n].direction = d;
      closed[n].volume = 0.1;
      closed[n].profit = profit;
      closed[n].commission = -0.7;
      closed[n].open_time = close_time - 3600;
      closed[n].close_time = close_time;
      closed[n].comment = comment;
     }
  };

#endif // XAUUSD_FAKEGATEWAY_MQH
