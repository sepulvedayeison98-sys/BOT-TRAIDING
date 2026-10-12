//+------------------------------------------------------------------+
//| Types.mqh                                                        |
//| Enumeraciones, estructuras y constantes compartidas.             |
//| No contiene lógica de trading. Las estructuras de fases          |
//| posteriores (señales, riesgo, ejecución) se añadirán en su fase. |
//+------------------------------------------------------------------+
#ifndef XAUUSD_TYPES_MQH
#define XAUUSD_TYPES_MQH

#define XAU_PROJECT_NAME    "XAUUSD_Autonomous"
#define XAU_PROJECT_VERSION "0.2.0"
#define XAU_FILES_ROOT      "XAUUSD"

//--- Estado global del EA
enum ENUM_EA_STATE
  {
   EA_INIT = 0,
   EA_RUNNING,
   EA_PAUSED,
   EA_SAFE_MODE,
   EA_DAILY_LIMIT,
   EA_HALTED
  };

//--- Régimen de mercado (RegimeEngine, Fase 3)
enum ENUM_REGIME
  {
   REGIME_NO_TRADE = 0,
   REGIME_TREND_UP,
   REGIME_TREND_DOWN,
   REGIME_RANGE,
   REGIME_HIGH_VOLATILITY
  };

enum ENUM_DIRECTION
  {
   DIR_NONE = 0,
   DIR_LONG,
   DIR_SHORT
  };

enum ENUM_STRATEGY_ID
  {
   STRAT_NONE = 0,
   STRAT_SMC,
   STRAT_BREAKOUT,
   STRAT_REVERSAL
  };

//--- Sesión activa (SessionClock)
enum ENUM_SESSION_ID
  {
   SESSION_NONE = 0,
   SESSION_LONDON,
   SESSION_NEWYORK,
   SESSION_OVERLAP
  };

//--- Regla de horario de verano del servidor (solo Strategy Tester)
enum ENUM_DST_RULE
  {
   DST_RULE_NONE = 0,   // Sin horario de verano
   DST_RULE_EU   = 1,   // Regla UE/UK (último domingo mar → último domingo oct)
   DST_RULE_US   = 2    // Regla EE. UU. (2.º domingo mar → 1.er domingo nov)
  };

//--- Estructura de mercado a partir de pivotes confirmados
enum ENUM_MARKET_STRUCTURE
  {
   STRUCTURE_UNKNOWN = 0,   // Pivotes insuficientes
   STRUCTURE_BULLISH,       // HH + HL
   STRUCTURE_BEARISH,       // LH + LL
   STRUCTURE_MIXED          // Expansión o contracción
  };

//--- Niveles de log
enum ENUM_LOG_LEVEL
  {
   LOG_DEBUG = 0,
   LOG_INFO,
   LOG_WARN,
   LOG_ERROR,
   LOG_CRITICAL
  };

//--- Pivote confirmado (no repinta: requiere N velas cerradas a cada lado)
struct SwingPoint
  {
   datetime          time;
   double            price;
   bool              is_high;
   int               bar_index;   // índice en la serie (0 = última vela cerrada) en el momento del cálculo
  };

//--- Datos de una temporalidad. Todas las series son "as series":
//--- índice 0 = última vela CERRADA (shift 1 del gráfico).
struct TFData
  {
   ENUM_TIMEFRAMES   tf;
   bool              valid;
   string            invalid_reason;
   datetime          last_closed_time;
   int               bars;              // número de velas cerradas cargadas
   MqlRates          rates[];
   double            ema_fast[];
   double            ema_slow[];
   double            rsi[];
   double            adx[];
   double            plus_di[];
   double            minus_di[];
   double            atr[];
   SwingPoint        swings[];          // ordenados del más reciente al más antiguo
   int               swing_count;
   ENUM_MARKET_STRUCTURE structure;
   double            atr_ratio;         // atr[0] / media(atr, ventana)
   double            ema_slope;         // (ema_fast[0] - ema_fast[k]) / atr[0]
   double            ema_slope_prev;    // (ema_fast[k] - ema_fast[2k]) / atr[k]
   bool              momentum_shift;    // cambio de signo entre ema_slope_prev y ema_slope
   double            range_high;        // máximo de las velas cerradas cargadas
   double            range_low;         // mínimo de las velas cerradas cargadas
  };

//--- Instantánea completa del mercado entregada por MarketEngine
struct MarketSnapshot
  {
   bool              valid;
   string            invalid_reason;
   string            symbol;
   datetime          server_time;
   datetime          utc_time;
   datetime          tick_time;
   ENUM_SESSION_ID   session;
   double            bid;
   double            ask;
   double            point;
   int               digits;
   double            spread_points;
   double            spread_avg_points;   // 0 si no hay referencia disponible
   double            spread_ratio;        // spread_points / spread_avg_points (0 si no disponible)
   TFData            h1;
   TFData            m15;
   TFData            m5;
  };

//--- Utilidades de texto
string EnumSessionToString(const ENUM_SESSION_ID s)
  {
   switch(s)
     {
      case SESSION_LONDON:  return "LONDON";
      case SESSION_NEWYORK: return "NEWYORK";
      case SESSION_OVERLAP: return "OVERLAP";
      default:              return "NONE";
     }
  }

string EnumStructureToString(const ENUM_MARKET_STRUCTURE s)
  {
   switch(s)
     {
      case STRUCTURE_BULLISH: return "BULLISH";
      case STRUCTURE_BEARISH: return "BEARISH";
      case STRUCTURE_MIXED:   return "MIXED";
      default:                return "UNKNOWN";
     }
  }

string EnumLogLevelToString(const ENUM_LOG_LEVEL l)
  {
   switch(l)
     {
      case LOG_DEBUG:    return "DEBUG";
      case LOG_INFO:     return "INFO";
      case LOG_WARN:     return "WARN";
      case LOG_ERROR:    return "ERROR";
      default:           return "CRITICAL";
     }
  }

string EnumEAStateToString(const ENUM_EA_STATE s)
  {
   switch(s)
     {
      case EA_INIT:        return "INIT";
      case EA_RUNNING:     return "RUNNING";
      case EA_PAUSED:      return "PAUSED";
      case EA_SAFE_MODE:   return "SAFE_MODE";
      case EA_DAILY_LIMIT: return "DAILY_LIMIT";
      default:             return "HALTED";
     }
  }

#endif // XAUUSD_TYPES_MQH
