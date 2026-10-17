//+------------------------------------------------------------------+
//| InstrumentProfile.mqh                                            |
//| Perfil por instrumento: qué filtros aplican y cómo se escalan    |
//| los umbrales que dependen del precio.                            |
//|                                                                  |
//|  - XAUUSD: sesiones Londres/Nueva York, noticias USD y umbrales  |
//|    de coste en puntos (inputs). Comportamiento de 1.1.x intacto. |
//|  - Sintético continuo (Volatility, Step, Jump de Deriv): cotiza  |
//|    24/7 y no depende de noticias macro (es un generador          |
//|    aleatorio del bróker), así que no hay filtro de sesión ni de  |
//|    noticias. Los puntos no son comparables entre índices, por    |
//|    eso spread, desviación, deriva de entrada y offset de         |
//|    break-even se expresan como fracción del ATR M15.             |
//|  - Sintético con spikes (Boom/Crash): como el continuo, más una  |
//|    restricción de lado. Un spike puede saltar por encima del SL  |
//|    y ejecutarlo mucho peor que lo calculado, lo que rompe el     |
//|    riesgo fijo por operación; por eso, por defecto, solo se      |
//|    opera en la dirección del spike (Boom: compras; Crash:        |
//|    ventas). Es un perfil experimental y exige activarlo.         |
//|                                                                  |
//| Funciones puras (sin llamadas al terminal) para poder probarlas. |
//+------------------------------------------------------------------+
#ifndef XAUUSD_INSTRUMENTPROFILE_MQH
#define XAUUSD_INSTRUMENTPROFILE_MQH

#include "Types.mqh"

enum ENUM_INSTRUMENT_PROFILE
  {
   PROFILE_AUTO = 0,            // Automático según el nombre del símbolo
   PROFILE_XAUUSD,              // Oro (XAUUSD)
   PROFILE_SYNTH_CONTINUOUS,    // Sintético continuo (Volatility, Step, Jump)
   PROFILE_SYNTH_SPIKE          // Sintético con spikes (Boom, Crash) - experimental
  };

string EnumProfileToString(const ENUM_INSTRUMENT_PROFILE p)
  {
   switch(p)
     {
      case PROFILE_XAUUSD:           return "XAUUSD";
      case PROFILE_SYNTH_CONTINUOUS: return "SINTETICO";
      case PROFILE_SYNTH_SPIKE:      return "SINTETICO_SPIKE";
      default:                       return "AUTO";
     }
  }

//--- Umbrales de coste para los perfiles sintéticos (fracción del ATR M15)
struct SyntheticCostConfig
  {
   double            max_spread_atr;     // spread máximo para abrir
   double            deviation_atr;      // desviación permitida en la orden
   double            entry_drift_atr;    // deriva máxima del precio desde la evaluación
   double            be_offset_atr;      // offset del break-even sobre la entrada
  };

void SyntheticCostDefaultConfig(SyntheticCostConfig &c)
  {
   // Hipótesis a calibrar con SymbolSpecDump y demo (equivalen aproximadamente a los valores
   // en puntos usados en XAUUSD con su ATR M15 típico); no son valores optimizados.
   c.max_spread_atr = 0.15;
   c.deviation_atr = 0.10;
   c.entry_drift_atr = 0.10;
   c.be_offset_atr = 0.02;
  }

bool SyntheticCostValidateConfig(const SyntheticCostConfig &c, string &reason)
  {
   if(c.max_spread_atr <= 0.0 || c.max_spread_atr > 1.0)
     { reason = "spread máximo sintético fuera de (0, 1] ATR"; return false; }
   if(c.deviation_atr < 0.0 || c.deviation_atr > 1.0 || c.entry_drift_atr < 0.0 || c.entry_drift_atr > 1.0)
     { reason = "desviación/deriva sintéticas fuera de [0, 1] ATR"; return false; }
   if(c.be_offset_atr < 0.0 || c.be_offset_atr > 0.5)
     { reason = "offset de break-even sintético fuera de [0, 0.5] ATR"; return false; }
   reason = "";
   return true;
  }

struct InstrumentProfile
  {
   ENUM_INSTRUMENT_PROFILE id;
   string            family;            // XAUUSD, Volatility, Step, Jump, Boom, Crash, OTRO
   bool              use_sessions;      // exigir Londres/Nueva York
   bool              use_news;          // filtro de noticias USD
   bool              use_asia_range;    // nivel de liquidez del rango asiático (SMC)
   bool              atr_costs;         // umbrales de coste relativos al ATR
   int               spike_dir;         // +1 spikes alcistas (Boom), -1 bajistas (Crash), 0 sin spikes
   ENUM_DIRECTION    only_dir;          // DIR_NONE = ambos lados
  };

//--- Límites de coste vigentes, en puntos del símbolo
struct CostLimits
  {
   int               max_spread_points;
   int               deviation_points;
   int               entry_drift_points;
   int               be_offset_points;
  };

class CInstrumentProfiles
  {
private:
   static bool       Has(const string upper, const string word) { return StringFind(upper, word) >= 0; }

public:
   //--- Familia por nombre (mayúsculas indiferentes). "" si no se reconoce.
   static string     Family(const string symbol)
     {
      string u = symbol;
      StringToUpper(u);
      if(Has(u, "XAUUSD"))
         return "XAUUSD";
      if(Has(u, "BOOM"))
         return "Boom";
      if(Has(u, "CRASH"))
         return "Crash";
      if(Has(u, "VOLATILITY"))
         return "Volatility";
      if(Has(u, "STEP"))
         return "Step";
      if(Has(u, "JUMP"))
         return "Jump";
      return "";
     }

   static ENUM_INSTRUMENT_PROFILE ProfileForFamily(const string family)
     {
      if(family == "XAUUSD")
         return PROFILE_XAUUSD;
      if(family == "Boom" || family == "Crash")
         return PROFILE_SYNTH_SPIKE;
      if(family == "Volatility" || family == "Step" || family == "Jump")
         return PROFILE_SYNTH_CONTINUOUS;
      return PROFILE_AUTO;
     }

   //--- Construye el perfil de un perfil concreto (sin validar el símbolo)
   static void       Build(const ENUM_INSTRUMENT_PROFILE id, const string family, const bool spike_side_only,
                           InstrumentProfile &p)
     {
      p.id = id;
      p.family = (family == "") ? "OTRO" : family;
      p.use_sessions = (id == PROFILE_XAUUSD);
      p.use_news = (id == PROFILE_XAUUSD);
      p.use_asia_range = (id == PROFILE_XAUUSD);
      p.atr_costs = (id != PROFILE_XAUUSD);
      p.spike_dir = 0;
      p.only_dir = DIR_NONE;
      if(id == PROFILE_SYNTH_SPIKE)
        {
         p.spike_dir = (family == "Crash") ? -1 : 1;
         if(spike_side_only)
            p.only_dir = (p.spike_dir > 0) ? DIR_LONG : DIR_SHORT;
        }
     }

   //--- Resuelve el perfil del símbolo. false (con motivo) si no debe arrancar.
   //--- allow_any: permite símbolos no reconocidos (solo pruebas); allow_spike: activa Boom/Crash.
   static bool       Resolve(const string symbol, const ENUM_INSTRUMENT_PROFILE requested, const bool allow_any,
                             const bool allow_spike, const bool spike_side_only, InstrumentProfile &p, string &why)
     {
      string family = Family(symbol);
      ENUM_INSTRUMENT_PROFILE detected = ProfileForFamily(family);
      ENUM_INSTRUMENT_PROFILE id = (requested == PROFILE_AUTO) ? detected : requested;
      why = "";
      if(id == PROFILE_AUTO)
        {
         if(!allow_any)
           {
            why = "símbolo no reconocido (" + symbol + "): este EA opera XAUUSD e índices sintéticos Volatility/Step/Jump/Boom/Crash";
            return false;
           }
         id = PROFILE_XAUUSD;   // modo de pruebas histórico: símbolo cualquiera con reglas del oro
        }
      if(id != detected && !allow_any)
        {
         why = StringFormat("el perfil %s no corresponde al símbolo %s (detectado %s); requiere InpAllowAnySymbol=true",
                            EnumProfileToString(id), symbol, EnumProfileToString(detected));
         return false;
        }
      if(id == PROFILE_SYNTH_SPIKE && !allow_spike)
        {
         why = "Boom/Crash es un perfil experimental (los spikes pueden saltar el SL): actívalo con InpAllowSpikeIndices=true";
         return false;
        }
      if(id == PROFILE_SYNTH_SPIKE && family != "Boom" && family != "Crash")
        {
         why = "el perfil con spikes necesita saber la dirección del spike: el nombre debe contener Boom o Crash";
         return false;
        }
      Build(id, family, spike_side_only, p);
      return true;
     }

   //--- Una señal en esta dirección, ¿está permitida por el perfil?
   static bool       DirectionAllowed(const InstrumentProfile &p, const ENUM_DIRECTION d)
     {
      return (p.only_dir == DIR_NONE || p.only_dir == d);
     }

   //--- Convierte una fracción de ATR en puntos (mínimo `floor_pts`)
   static int        AtrPoints(const double atr, const double point, const double frac, const int floor_pts)
     {
      if(atr <= 0.0 || point <= 0.0 || frac <= 0.0)
         return floor_pts;
      double v = MathRound(atr * frac / point);
      if(v > 2000000000.0)
         v = 2000000000.0;
      return MathMax(floor_pts, (int)v);
     }

   //--- Límites vigentes: fijos (XAUUSD) o relativos al ATR M15 (sintéticos).
   //--- false si el perfil es relativo y aún no hay ATR (se mantienen los anteriores).
   static bool       Limits(const InstrumentProfile &p, const CostLimits &fixed, const SyntheticCostConfig &sc,
                            const double atr_m15, const double point, CostLimits &out)
     {
      if(!p.atr_costs)
        {
         out = fixed;
         return true;
        }
      if(atr_m15 <= 0.0 || point <= 0.0)
         return false;
      out.max_spread_points = AtrPoints(atr_m15, point, sc.max_spread_atr, 1);
      out.deviation_points = AtrPoints(atr_m15, point, sc.deviation_atr, 0);
      out.entry_drift_points = AtrPoints(atr_m15, point, sc.entry_drift_atr, 0);
      out.be_offset_points = AtrPoints(atr_m15, point, sc.be_offset_atr, 0);
      return true;
     }

   //--- Nombre de archivo seguro para el símbolo (modelos Champion por instrumento)
   static string     FileKey(const string symbol)
     {
      string s = symbol;
      int n = StringLen(s);
      for(int i = 0; i < n; i++)
        {
         ushort c = StringGetCharacter(s, i);
         bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
         if(!ok)
            StringSetCharacter(s, i, '_');
        }
      return s;
     }

   //--- Ruta del modelo Champion: la histórica para XAUUSD, una por símbolo para el resto
   static string     ChampionFile(const InstrumentProfile &p, const string symbol)
     {
      if(p.id == PROFILE_XAUUSD)
         return XAU_FILES_ROOT + "/champion.model";
      return XAU_FILES_ROOT + "/champion_" + FileKey(symbol) + ".model";
     }
  };

#endif // XAUUSD_INSTRUMENTPROFILE_MQH
