//+------------------------------------------------------------------+
//| Dashboard.mqh                                                    |
//| Panel de control en el gráfico (objetos OBJ_RECTANGLE_LABEL,     |
//| OBJ_LABEL y OBJ_BUTTON). Solo muestra estado y devuelve          |
//| comandos: NO ejecuta trading (lo hace el EA a través de sus      |
//| módulos).                                                        |
//|  - Pausar/reanudar entradas (la gestión protectora sigue).       |
//|  - Activar modo seguro.                                          |
//|  - Salir del modo seguro: doble clic en 5 s.                     |
//|  - Cerrar todas las posiciones: doble clic en 5 s.               |
//|  - Ver ruta de los registros.                                    |
//| No usa MessageBox (bloquea el hilo del EA).                      |
//+------------------------------------------------------------------+
#ifndef XAUUSD_DASHBOARD_MQH
#define XAUUSD_DASHBOARD_MQH

#include "Types.mqh"

#define DB_LINES 26
#define DB_CONFIRM_SECONDS 5

enum ENUM_DASH_COMMAND
  {
   DASH_NONE = 0,
   DASH_TOGGLE_PAUSE,
   DASH_SAFE_MODE,
   DASH_EXIT_SAFE_MODE,
   DASH_CLOSE_ALL,
   DASH_SHOW_LOGS
  };

struct DashboardData
  {
   string            ea_state;
   string            symbol;
   string            account;          // DEMO / REAL / ... + Hedging/Netting
   string            times;            // servidor / UTC / Colombia
   string            session;
   string            regime;
   string            h1_trend;
   string            m15_structure;
   string            m5_confirmation;
   string            strategy;
   string            score;
   string            spread;
   string            atr;
   string            rsi;
   string            positions;
   string            risk_per_trade;
   string            exposure;
   string            daily_loss;
   string            daily_gain;
   string            drawdown;
   string            news;
   string            last_signal;
   string            last_trade;
   string            blocks;
  };

class CDashboard
  {
private:
   long              m_chart;
   string            m_prefix;
   bool              m_ready;
   int               m_x;
   int               m_y;
   datetime          m_close_armed;
   datetime          m_exit_armed;
   string            m_lines[DB_LINES];

   string            Name(const string s) const { return m_prefix + s; }

   void              Label(const int i)
     {
      string n = Name("L" + IntegerToString(i));
      if(ObjectFind(m_chart, n) < 0)
        {
         ObjectCreate(m_chart, n, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(m_chart, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, m_x + 8);
         ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, m_y + 6 + i * 15);
         ObjectSetString(m_chart, n, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(m_chart, n, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(m_chart, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, n, OBJPROP_HIDDEN, true);
        }
     }

   void              Button(const string id, const string text, const int col, const int row, const color bg)
     {
      string n = Name(id);
      if(ObjectFind(m_chart, n) < 0)
        {
         ObjectCreate(m_chart, n, OBJ_BUTTON, 0, 0, 0);
         ObjectSetInteger(m_chart, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart, n, OBJPROP_XSIZE, 150);
         ObjectSetInteger(m_chart, n, OBJPROP_YSIZE, 20);
         ObjectSetString(m_chart, n, OBJPROP_FONT, "Arial");
         ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(m_chart, n, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(m_chart, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, n, OBJPROP_HIDDEN, true);
        }
      ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, m_x + 8 + col * 156);
      ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, m_y + 10 + DB_LINES * 15 + row * 24);
      ObjectSetInteger(m_chart, n, OBJPROP_BGCOLOR, bg);
      ObjectSetString(m_chart, n, OBJPROP_TEXT, text);
     }

   void              SetLine(const int i, const string text)
     {
      if(i < 0 || i >= DB_LINES || m_lines[i] == text)
         return;
      m_lines[i] = text;
      ObjectSetString(m_chart, Name("L" + IntegerToString(i)), OBJPROP_TEXT, text);
     }

public:
                     CDashboard(void)
     {
      m_chart = 0;
      m_prefix = "XAD_";
      m_ready = false;
      m_x = 10;
      m_y = 20;
      m_close_armed = 0;
      m_exit_armed = 0;
     }

   bool              Init(const long chart, const string prefix)
     {
      m_chart = chart;
      m_prefix = prefix;
      string bg = Name("BG");
      if(ObjectFind(m_chart, bg) < 0 && !ObjectCreate(m_chart, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0))
         return false;
      ObjectSetInteger(m_chart, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart, bg, OBJPROP_XDISTANCE, m_x);
      ObjectSetInteger(m_chart, bg, OBJPROP_YDISTANCE, m_y);
      ObjectSetInteger(m_chart, bg, OBJPROP_XSIZE, 480);
      ObjectSetInteger(m_chart, bg, OBJPROP_YSIZE, DB_LINES * 15 + 70);
      ObjectSetInteger(m_chart, bg, OBJPROP_BGCOLOR, C'20,24,32');
      ObjectSetInteger(m_chart, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chart, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart, bg, OBJPROP_HIDDEN, true);
      for(int i = 0; i < DB_LINES; i++)
        {
         m_lines[i] = "";
         Label(i);
        }
      Button("BTN_PAUSE", "Pausar entradas", 0, 0, C'60,90,140');
      Button("BTN_SAFE", "Modo seguro", 1, 0, C'140,100,40');
      Button("BTN_CLOSE", "Cerrar todo", 2, 0, C'150,40,40');
      Button("BTN_LOGS", "Ver registros", 0, 1, C'70,70,70');
      Button("BTN_EXIT_SAFE", "Salir de modo seguro", 1, 1, C'40,110,60');
      m_ready = true;
      ChartRedraw(m_chart);
      return true;
     }

   void              Destroy(void)
     {
      ObjectsDeleteAll(m_chart, m_prefix);
      ChartRedraw(m_chart);
      m_ready = false;
     }

   bool              Ready(void) const { return m_ready; }

   void              Update(const DashboardData &d, const bool paused, const datetime now)
     {
      if(!m_ready)
         return;
      string L[DB_LINES];
      L[0] = "XAUUSD Autonomous " + XAU_PROJECT_VERSION + "  |  " + d.ea_state;
      L[1] = "Símbolo: " + d.symbol + "   Cuenta: " + d.account;
      L[2] = "Hora: " + d.times;
      L[3] = "Sesión: " + d.session;
      L[4] = "Régimen: " + d.regime;
      L[5] = "Tendencia H1: " + d.h1_trend;
      L[6] = "Estructura M15: " + d.m15_structure;
      L[7] = "Confirmación M5: " + d.m5_confirmation;
      L[8] = "Estrategia: " + d.strategy + "   Puntuación: " + d.score;
      L[9] = "Spread: " + d.spread + "   ATR: " + d.atr + "   RSI: " + d.rsi;
      L[10] = "Posiciones: " + d.positions;
      L[11] = "Riesgo/operación: " + d.risk_per_trade + "   Exposición: " + d.exposure;
      L[12] = "Día: pérdida " + d.daily_loss + "  ganancia " + d.daily_gain;
      L[13] = "Drawdown: " + d.drawdown;
      L[14] = "Noticias: " + d.news;
      L[15] = "Última señal: " + StringSubstr(d.last_signal, 0, 70);
      L[16] = "  " + StringSubstr(d.last_signal, 70, 70);
      L[17] = "Última operación: " + StringSubstr(d.last_trade, 0, 66);
      L[18] = "  " + StringSubstr(d.last_trade, 66, 70);
      L[19] = "Bloqueos:";
      string b = d.blocks;
      for(int i = 0; i < 6; i++)
         L[20 + i] = "  " + StringSubstr(b, i * 72, 72);
      for(int i = 0; i < DB_LINES; i++)
         SetLine(i, L[i]);
      ObjectSetString(m_chart, Name("BTN_PAUSE"), OBJPROP_TEXT, paused ? "Reanudar entradas" : "Pausar entradas");
      if(m_close_armed > 0 && now - m_close_armed > DB_CONFIRM_SECONDS)
        {
         m_close_armed = 0;
         ObjectSetString(m_chart, Name("BTN_CLOSE"), OBJPROP_TEXT, "Cerrar todo");
        }
      if(m_exit_armed > 0 && now - m_exit_armed > DB_CONFIRM_SECONDS)
        {
         m_exit_armed = 0;
         ObjectSetString(m_chart, Name("BTN_EXIT_SAFE"), OBJPROP_TEXT, "Salir de modo seguro");
        }
      ChartRedraw(m_chart);
     }

   string            LineText(const int i) const { return (i >= 0 && i < DB_LINES) ? m_lines[i] : ""; }

   //--- Procesa un clic. `now` en segundos (TimeLocal en vivo).
   ENUM_DASH_COMMAND OnClick(const string object, const datetime now)
     {
      if(!m_ready || StringFind(object, m_prefix) != 0)
         return DASH_NONE;
      ObjectSetInteger(m_chart, object, OBJPROP_STATE, false);
      if(object == Name("BTN_PAUSE"))
         return DASH_TOGGLE_PAUSE;
      if(object == Name("BTN_SAFE"))
         return DASH_SAFE_MODE;
      if(object == Name("BTN_LOGS"))
         return DASH_SHOW_LOGS;
      if(object == Name("BTN_CLOSE"))
        {
         if(m_close_armed > 0 && now - m_close_armed <= DB_CONFIRM_SECONDS)
           {
            m_close_armed = 0;
            ObjectSetString(m_chart, object, OBJPROP_TEXT, "Cerrar todo");
            return DASH_CLOSE_ALL;
           }
         m_close_armed = now;
         ObjectSetString(m_chart, object, OBJPROP_TEXT, "¿CONFIRMAR? clic otra vez (5 s)");
         return DASH_NONE;
        }
      if(object == Name("BTN_EXIT_SAFE"))
        {
         if(m_exit_armed > 0 && now - m_exit_armed <= DB_CONFIRM_SECONDS)
           {
            m_exit_armed = 0;
            ObjectSetString(m_chart, object, OBJPROP_TEXT, "Salir de modo seguro");
            return DASH_EXIT_SAFE_MODE;
           }
         m_exit_armed = now;
         ObjectSetString(m_chart, object, OBJPROP_TEXT, "¿CONFIRMAR? clic otra vez (5 s)");
         return DASH_NONE;
        }
      return DASH_NONE;
     }
  };

#endif // XAUUSD_DASHBOARD_MQH
