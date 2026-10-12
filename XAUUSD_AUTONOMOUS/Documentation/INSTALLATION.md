# Instalación

> Estado: **Fase 1**. Aún no hay código instalable. Este documento lista los requisitos y el procedimiento previsto.

## Requisitos
- Windows con MetaTrader 5 instalado desde Deriv y MetaEditor (incluido con MT5).
- Cuenta **demo** de Deriv MT5. No usar cuenta real.
- Trading algorítmico habilitado en el terminal (*Herramientas → Opciones → Asesores Expertos*).

## Procedimiento previsto (a partir de la Fase 2)
1. En MT5: *Archivo → Abrir carpeta de datos* → carpeta `MQL5/`.
2. Copiar (o enlazar con `mklink /J`) el contenido:
   - `XAUUSD_AUTONOMOUS/Experts/` → `MQL5/Experts/XAUUSD_Autonomous/`
   - `XAUUSD_AUTONOMOUS/Include/XAUUSD/` → `MQL5/Include/XAUUSD/`
   - `XAUUSD_AUTONOMOUS/Tests/Validation/` → `MQL5/Scripts/XAUUSD_Tests/`
3. Compilar en MetaEditor (F7) y reportar errores/warnings.
4. Ejecutar el script de volcado de especificaciones (Fase 2) sobre el gráfico XAUUSD y compartir el resultado.

## Seguridad
- Nunca subir al repositorio: contraseñas, número de cuenta, servidor con credenciales, tokens de API, ficheros `.set` con tokens.
- El EA no necesita credenciales: opera con la sesión ya abierta del terminal.
