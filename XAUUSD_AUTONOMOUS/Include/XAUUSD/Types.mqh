//+------------------------------------------------------------------+
//| Types.mqh                                                        |
//| Enumeraciones, estructuras y constantes compartidas.             |
//| No contiene lógica de trading. Las estructuras de fases          |
//| posteriores (señales, riesgo, ejecución) se añadirán en su fase. |
//+------------------------------------------------------------------+
#ifndef XAUUSD_TYPES_MQH
#define XAUUSD_TYPES_MQH

#define XAU_PROJECT_NAME    "XAUUSD_Autonomous"
#define XAU_PROJECT_VERSION "1.0.0"
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

//--- Resultado del RegimeEngine
struct RegimeState
  {
   ENUM_REGIME       regime;             // régimen estable (tras histéresis)
   ENUM_REGIME       raw_regime;         // clasificación instantánea de esta evaluación
   string            reason;             // motivo de la clasificación instantánea
   datetime          evaluated_at;       // hora del servidor
   int               evaluations_in_regime;
   double            h1_adx;
   double            h1_atr_ratio;
   double            m15_atr_ratio;
   double            h1_ema_slope;
   ENUM_MARKET_STRUCTURE h1_structure;
   ENUM_MARKET_STRUCTURE m15_structure;
   double            range_high;         // límites del rango M15 (0 si no aplica)
   double            range_low;
   double            dist_swing_high_atr; // distancia al pivote alto H1 por encima del precio, en ATR H1 (-1 = no hay)
   double            dist_swing_low_atr;  // distancia al pivote bajo H1 por debajo del precio, en ATR H1 (-1 = no hay)
  };

//--- Evento de ruptura de estructura
enum ENUM_STRUCT_EVENT
  {
   SE_NONE = 0,
   SE_BOS,        // ruptura a favor de la estructura vigente
   SE_CHOCH,      // ruptura contra la estructura vigente (cambio de carácter)
   SE_BREAK       // ruptura con estructura previa mixta o desconocida
  };

//--- Evidencia técnica estructurada de una señal (la usa AdaptiveEngine para puntuar)
struct SignalEvidence
  {
   bool              sweep;                // barrido de liquidez
   double            sweep_level;          // nivel barrido
   double            sweep_extreme;        // extremo de la mecha del barrido
   bool              sweep_session_level;  // el nivel barrido coincide con un extremo de la sesión asiática
   ENUM_STRUCT_EVENT m15_event;            // ruptura de estructura en M15
   double            m15_event_level;
   bool              fvg;                  // zona de interés es un FVG
   bool              order_block;          // zona de interés es un Order Block
   bool              discount_premium_ok;  // compra en descuento / venta en premium
   bool              m5_rejection;         // vela M5 de rechazo
   bool              m5_break;             // ruptura de estructura en M5
   bool              m15_rejection;        // vela M15 de rechazo (reversión)
   bool              rsi_divergence;       // divergencia RSI M15
   bool              extension;            // sobreextensión respecto a la EMA rápida
   bool              consolidation;        // caja de consolidación detectada (breakout)
   bool              volume_expansion;     // tick volume de la ruptura sobre la media
   bool              volume_available;     // el bróker provee tick volume utilizable
   bool              retest;               // entrada por retest (breakout)
   int               confirmations;        // condiciones cumplidas (reversión)
   double            poi_low;              // zona de interés (OB/FVG/borde de caja)
   double            poi_high;
  };

//--- Señal estructurada y explicable producida por una estrategia
struct TradeSignal
  {
   string            signal_id;
   string            setup_key;      // identifica la oportunidad (no cambia entre velas) para deduplicar
   ENUM_STRATEGY_ID  strategy;
   ENUM_DIRECTION    direction;
   ENUM_TIMEFRAMES   origin_tf;      // temporalidad donde se forma el setup
   double            entry_low;      // zona de entrada
   double            entry_high;
   double            entry_price;    // referencia: cierre de la vela M5 de confirmación
   double            invalidation;   // nivel estructural que invalida la idea
   double            sl;
   double            tp;
   double            rr;             // |tp - entry| / |entry - sl|
   datetime          created;        // hora del servidor
   datetime          expires;
   string            reason;
   string            evidence_text;
   SignalEvidence    evidence;
  };

//--- Calidad de una propuesta según la puntuación (NO es una probabilidad)
enum ENUM_SIGNAL_QUALITY
  {
   QUALITY_DISCARD = 0,   // < umbral mínimo
   QUALITY_MODERATE,      // [umbral mínimo, umbral alto)
   QUALITY_HIGH           // >= umbral alto
  };

//--- Componentes de la puntuación (máximos: 20, 20, 20, 20, 10, 10)
struct ScoreBreakdown
  {
   double            h1_context;
   double            m15_structure;
   double            liquidity;
   double            m5_confirmation;
   double            momentum_volatility;
   double            execution;
   double            total;
  };

//--- Resumen de una posición propia abierta (lo aporta PositionManager)
struct PositionBrief
  {
   ulong             ticket;
   ENUM_DIRECTION    direction;
   double            open_price;
   string            setup_key;
  };

//--- Contexto externo que el coordinador no calcula por sí mismo
struct AdaptiveContext
  {
   bool              news_clear;              // sin ventana de noticias próxima (NewsManager)
   int               minutes_to_session_end;  // minutos hasta el cierre de la sesión activa (-1 = desconocido)
  };

//--- Propuesta enviada al RiskManager
struct TradeProposal
  {
   bool              valid;
   TradeSignal       signal;
   ScoreBreakdown    score;
   ENUM_SIGNAL_QUALITY quality;
   int               candidates;     // señales recibidas
   string            decision;       // explicación de la selección o del descarte
  };

//--- Estado de la cuenta usado por el RiskManager
struct AccountSnapshot
  {
   double            balance;
   double            equity;
   double            margin;          // margen usado
   double            free_margin;
   string            currency;
   bool              netting;         // true = Netting/Exchange, false = Hedging
  };

//--- Riesgo de una posición propia abierta
struct PositionRisk
  {
   ulong             ticket;
   ENUM_DIRECTION    direction;
   double            volume;
   double            open_price;
   double            sl;              // 0 = sin SL (error crítico)
  };

//--- Especificación del símbolo relevante para riesgo y ejecución
struct SymbolSpec
  {
   string            name;
   int               digits;
   double            point;
   double            tick_size;
   double            tick_value_loss;
   double            contract_size;
   double            volume_min;
   double            volume_max;
   double            volume_step;
   double            volume_limit;    // 0 = sin límite
   int               stops_level;     // puntos
   int               freeze_level;    // puntos
   bool              tick_value_generic; // SYMBOL_TRADE_TICK_VALUE_LOSS no disponible: se usó SYMBOL_TRADE_TICK_VALUE
  };

//--- Resultado del RiskManager
struct RiskDecision
  {
   bool              approved;
   bool              critical;        // el rechazo exige modo seguro (p. ej. posición sin SL)
   string            reject_reason;
   ENUM_DIRECTION    direction;
   double            entry;
   double            sl;
   double            tp;
   double            volume;
   double            risk_money;      // pérdida estimada al SL con costos
   double            risk_pct;        // sobre la base de riesgo
   double            rr;
   double            margin_required;
   double            exposure_before_pct;
   double            exposure_after_pct;
   double            daily_loss_pct;  // pérdida del día al decidir (positivo = pérdida)
   string            detail;
  };

//--- Resultado de un intento de ejecución
enum ENUM_EXEC_STATUS
  {
   EXEC_DONE = 0,       // aceptada por el servidor
   EXEC_REJECTED,       // rechazada (no hay operación)
   EXEC_UNCERTAIN,      // estado desconocido: NO reintentar, reconciliar con el servidor
   EXEC_SKIPPED         // no enviada (validación previa)
  };

struct ExecutionResult
  {
   ENUM_EXEC_STATUS  status;
   uint              retcode;
   string            message;
   ulong             order;
   ulong             deal;
   double            requested_price;
   double            fill_price;
   double            slippage_points;   // positivo = en contra
   int               attempts;
   string            comment;           // comentario enviado (para reconciliar)
  };

//--- Posición tal como la reporta el servidor
struct PositionInfo
  {
   ulong             ticket;
   long              identifier;
   ENUM_DIRECTION    direction;
   double            volume;
   double            open_price;
   double            sl;
   double            tp;
   double            profit;
   datetime          open_time;
   string            comment;
   long              magic;
  };

//--- Metadatos propios de una posición (persistidos en StateStore)
struct PositionMeta
  {
   long              identifier;
   string            signal_id;
   string            setup_key;
   ENUM_STRATEGY_ID  strategy;
   double            initial_sl;
   double            invalidation;
   bool              be_done;
   bool              orphan;            // posición encontrada sin metadatos
  };

//--- Solicitud enviada cuyo resultado aún no se confirmó
struct PendingRequest
  {
   bool              active;
   string            signal_id;
   string            setup_key;
   string            comment;
   ENUM_DIRECTION    direction;
   double            volume;
   datetime          sent_at;
   ENUM_STRATEGY_ID  strategy;
   double            initial_sl;
   double            invalidation;
  };

//--- Operación cerrada (agregada por identificador de posición) para estadísticas
struct ClosedTrade
  {
   long              identifier;
   ENUM_DIRECTION    direction;
   double            volume;
   double            entry_price;
   double            exit_price;
   datetime          open_time;
   datetime          close_time;
   double            profit;            // sin comisión ni swap
   double            commission;
   double            swap;
   string            comment;
  };

//--- Prioridad de un evento macro para el oro
enum ENUM_NEWS_TIER
  {
   NEWS_TIER_NONE = 0,   // no bloquea
   NEWS_TIER_USD,        // otros eventos USD importantes (ventana corta)
   NEWS_TIER_MAJOR       // NFP, CPI, PCE, FOMC, tasas, Reserva Federal (ventana larga)
  };

struct NewsEvent
  {
   datetime          time;          // hora del SERVIDOR del bróker
   string            currency;
   int               importance;    // 1 baja, 2 moderada, 3 alta
   string            name;
   ENUM_NEWS_TIER    tier;
  };

struct NewsState
  {
   bool              blocked;
   bool              source_ok;
   string            reason;
   string            source;        // "MT5" o "CSV"
   datetime          last_refresh;
   string            next_name;
   datetime          next_time;
   int               minutes_to_next;   // -1 si no hay próximo evento relevante
  };

//--- Registro completo de una operación (diario de operaciones)
struct TradeRecord
  {
   string            run_tag;
   long              identifier;
   string            signal_id;
   string            setup_key;
   ENUM_STRATEGY_ID  strategy;
   ENUM_DIRECTION    direction;
   ENUM_SESSION_ID   session;
   ENUM_REGIME       regime;
   double            score;
   datetime          open_time;
   datetime          close_time;
   double            volume;
   double            entry_price;
   double            exit_price;
   double            initial_sl;
   double            tp;
   double            risk_money;
   double            profit;
   double            commission;
   double            swap;
   double            net;
   double            r_multiple;
   double            slippage_points;
   double            spread_points;
  };

//--- Métricas de rendimiento de un conjunto de operaciones
struct PerfStats
  {
   int               trades;
   int               wins;
   int               losses;
   double            gross_profit;
   double            gross_loss;      // positivo
   double            net;
   double            profit_factor;   // 0 si no hay pérdidas ni ganancias; DBL_MAX si no hay pérdidas
   double            win_rate;
   double            expectancy;      // neto medio por operación (moneda)
   double            expectancy_r;    // R medio por operación
   double            max_drawdown;    // máximo retroceso de la curva acumulada (moneda)
   int               max_loss_streak;
   double            commission;
   double            swap;
   double            avg_slippage;
   double            avg_rr_realized; // ganancia media / pérdida media
  };

//--- Utilidades de texto
string EnumExecStatusToString(const ENUM_EXEC_STATUS s)
  {
   switch(s)
     {
      case EXEC_DONE:      return "DONE";
      case EXEC_REJECTED:  return "REJECTED";
      case EXEC_UNCERTAIN: return "UNCERTAIN";
      default:             return "SKIPPED";
     }
  }

string EnumQualityToString(const ENUM_SIGNAL_QUALITY q)
  {
   switch(q)
     {
      case QUALITY_HIGH:     return "HIGH";
      case QUALITY_MODERATE: return "MODERATE";
      default:               return "DISCARD";
     }
  }

string EnumStrategyToString(const ENUM_STRATEGY_ID s)
  {
   switch(s)
     {
      case STRAT_SMC:      return "SMC";
      case STRAT_BREAKOUT: return "BREAKOUT";
      case STRAT_REVERSAL: return "REVERSAL";
      default:             return "NONE";
     }
  }

string EnumDirectionToString(const ENUM_DIRECTION d)
  {
   switch(d)
     {
      case DIR_LONG:  return "LONG";
      case DIR_SHORT: return "SHORT";
      default:        return "NONE";
     }
  }

string EnumStructEventToString(const ENUM_STRUCT_EVENT e)
  {
   switch(e)
     {
      case SE_BOS:   return "BOS";
      case SE_CHOCH: return "CHOCH";
      case SE_BREAK: return "BREAK";
      default:       return "NONE";
     }
  }

string EnumRegimeToString(const ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND_UP:        return "TREND_UP";
      case REGIME_TREND_DOWN:      return "TREND_DOWN";
      case REGIME_RANGE:           return "RANGE";
      case REGIME_HIGH_VOLATILITY: return "HIGH_VOLATILITY";
      default:                     return "NO_TRADE";
     }
  }

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
