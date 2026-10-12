//+------------------------------------------------------------------+
//| TestFramework.mqh                                                |
//| Aserciones mínimas para scripts de prueba MQL5.                  |
//| Resultado: Print() + fichero MQL5/Files/XAUUSD/reports/<name>.txt|
//+------------------------------------------------------------------+
#ifndef XAUUSD_TESTFRAMEWORK_MQH
#define XAUUSD_TESTFRAMEWORK_MQH

class CTestRunner
  {
private:
   string            m_name;
   int               m_passed;
   int               m_failed;
   string            m_lines[];

   void              Add(const string line)
     {
      int n = ArraySize(m_lines);
      ArrayResize(m_lines, n + 1);
      m_lines[n] = line;
      Print(line);
     }

public:
                     CTestRunner(const string name) { m_name = name; m_passed = 0; m_failed = 0; }

   bool              True(const bool cond, const string what)
     {
      if(cond) { m_passed++; return true; }
      m_failed++;
      Add("FAIL: " + what);
      return false;
     }

   bool              EqInt(const long actual, const long expected, const string what)
     {
      return True(actual == expected, what + " (esperado " + IntegerToString(expected) + ", obtenido " + IntegerToString(actual) + ")");
     }

   bool              EqDbl(const double actual, const double expected, const double tol, const string what)
     {
      return True(MathAbs(actual - expected) <= tol,
                  StringFormat("%s (esperado %.10g, obtenido %.10g)", what, expected, actual));
     }

   bool              EqTime(const datetime actual, const datetime expected, const string what)
     {
      return True(actual == expected, StringFormat("%s (esperado %s, obtenido %s)", what,
                  TimeToString(expected, TIME_DATE | TIME_MINUTES), TimeToString(actual, TIME_DATE | TIME_MINUTES)));
     }

   int               Failed(void) const { return m_failed; }

   //--- Línea informativa en el reporte (no cuenta como prueba)
   void              Note(const string line) { Add("NOTE: " + line); }

   //--- Escribe el resumen. Devuelve true si no hubo fallos.
   bool              Finish(void)
     {
      string summary = StringFormat("RESULT %s: %d passed, %d failed", m_name, m_passed, m_failed);
      Add(summary);
      FolderCreate("XAUUSD");
      FolderCreate("XAUUSD/reports");
      int h = FileOpen("XAUUSD/reports/" + m_name + ".txt", FILE_WRITE | FILE_TXT | FILE_ANSI, '\t', CP_UTF8);
      if(h != INVALID_HANDLE)
        {
         for(int i = 0; i < ArraySize(m_lines); i++)
            FileWriteString(h, m_lines[i] + "\r\n");
         FileClose(h);
        }
      return m_failed == 0;
     }
  };

#endif // XAUUSD_TESTFRAMEWORK_MQH
