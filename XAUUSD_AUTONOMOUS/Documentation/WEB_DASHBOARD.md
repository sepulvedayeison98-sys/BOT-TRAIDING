# Dashboard web — arquitectura y seguridad (implementado en 1.1.0)

> Instalación paso a paso: [WebDashboard/README.md](../WebDashboard/README.md). El dashboard es **opcional** (`InpWebEnabled=false` por defecto) y el EA opera igual sin él.

## 1. Objetivo
Ver en el navegador o el teléfono el mismo estado que el panel de MT5 y, como máximo, **pausar o reanudar las entradas nuevas y activar el modo seguro**. Desde la web no se puede abrir, cerrar ni modificar operaciones, cambiar el riesgo, salir del modo seguro ni ver credenciales.

## 2. Arquitectura
```
MT5 (EA) --HTTPS POST /api/ea/telemetry (firmado)--> proxy TLS --> server.py (127.0.0.1) <-- navegador (HTTPS, sesión)
    ^                                                                   |
    └------- HTTPS GET /api/ea/commands + POST /api/ea/ack (firmados) ---┘
```
- **Solo conexiones salientes desde el EA** (`WebRequest`); el terminal no abre puertos.
- `WebRequest` es síncrono: el EA lo llama desde `OnTimer` cada `InpWebIntervalSec` (10–600 s, por defecto 30), nunca en `OnTick`, con un tiempo de espera de 2,5 s y **backoff** (el intervalo crece hasta ×10 mientras el servidor falle) para no retrasar la gestión protectora.
- No funciona en el Strategy Tester: el cliente se desactiva allí.
- Servidor: `WebDashboard/server.py` (Python estándar: `http.server` con HTTP/1.1 persistente, `sqlite3`, `hmac`). Frontend estático sin dependencias (`static/`).

| Pieza | Archivo |
|---|---|
| Cliente MQL5 (HMAC, JSON, verificación de comandos) | `Include/XAUUSD/WebDashboard.mqh` |
| Integración en el EA (telemetría, aplicación de comandos, persistencia `web.last_cmd`) | `Experts/XAUUSD_Autonomous.mq5` (`WebCycle`, `TelemetryJson`, `ApplyWebCommand`) |
| Servidor | `WebDashboard/server.py` |
| Interfaz | `WebDashboard/static/index.html`, `app.js`, `style.css` |

## 3. Protocolo
**Peticiones del EA.** Cabeceras `X-XAD-Timestamp` (UTC, segundos), `X-XAD-Nonce` y `X-XAD-Signature` = HMAC-SHA256 en hexadecimal, con el token del dashboard como clave, sobre:
```
<timestamp>\n<nonce>\n<MÉTODO> <ruta>\n<cuerpo>
```
El servidor rechaza (401) firmas inválidas, timestamps con más de 120 s de diferencia y nonces repetidos; limita el cuerpo a 64 KB.

**Telemetría** (`POST /api/ea/telemetry`, JSON): versión, símbolo, etiqueta de corrida, modo de cuenta (demo/real, Hedging/Netting — sin número de cuenta), moneda, equity, balance, estado y motivo, pérdida/ganancia diaria y su límite, exposición, riesgo por operación, posiciones, drawdown desde el máximo, régimen, sesión, spread y media, ATR y RSI M15, noticias, última señal, última operación y bloqueos.

**Comandos** (`GET /api/ea/commands`): una línea por comando pendiente `id|CMD|creado|firma`, con firma = HMAC(token, `id|CMD|creado`). El EA acepta un comando solo si la firma es válida, el `id` es mayor que el último aplicado, tiene ≤ 10 min de antigüedad y es `PAUSE`, `RESUME` o `SAFE_MODE` (cualquier otro se rechaza aunque esté firmado). Tras aplicarlo guarda el `id` en su estado (sobrevive a reinicios) y lo confirma con `POST /api/ea/ack`; si la confirmación falla, en el siguiente ciclo solo se re-confirma, no se re-aplica. El servidor deja de entregar comandos no confirmados a los 10 min.

| Comando | Efecto en el EA |
|---|---|
| `PAUSE` | `RUNNING → PAUSED` (sin entradas nuevas; la gestión protectora sigue). En otros estados se ignora y se registra. |
| `RESUME` | `PAUSED → RUNNING`. No saca del límite diario ni del modo seguro. |
| `SAFE_MODE` | Modo seguro. Salir de él solo es posible desde el panel de MT5 (doble confirmación). |

## 4. Seguridad
- El token del dashboard no da acceso a la cuenta de trading: el EA no conoce ni envía credenciales. Se configura como input del EA en tu terminal y como variable de entorno del servidor; nunca en el repositorio.
- Acceso web: contraseña (hash PBKDF2-SHA256, 200.000 iteraciones) → cookie de sesión firmada, `HttpOnly`, `SameSite=Strict`, `Secure` detrás de TLS, 12 h; token CSRF en una cabecera para cada comando; máximo 5 intentos de acceso por minuto e IP (`XAD_TRUST_PROXY=1` para usar la IP real detrás del proxy).
- Cabeceras: CSP sin scripts ni estilos en línea, `X-Frame-Options: DENY`, `nosniff`, `no-referrer`, `no-store`. Solo se sirven los archivos estáticos de la lista blanca.
- Auditoría: cada comando queda en la tabla `audit` (hora, IP, comando) y en el log del EA.
- `XAD_ALLOW_COMMANDS=0` convierte la web en solo lectura.
- Retención: la telemetría se borra a los 30 días. El gráfico muestra 3 días agregados a ~720 puntos.

## 5. Verificación realizada (entorno de desarrollo)
- `WebDashboard/tests/test_server.py`: 24 pruebas (firma, cuerpo alterado, repetición, timestamp viejo, JSON inválido, tamaño, sesión alterada/caducada, CSRF, comandos no permitidos, flujo completo de comando, caducidad, recorrido de rutas, conexión persistente, IP detrás del proxy, agregación de la serie).
- Vectores HMAC idénticos en Python y MQL5 (RFC 4231 caso 2, firma de petición, firma de comando y clave de más de 64 bytes) en `Test_WebDashboard.mq5` y `test_server.py`.
- Extremo a extremo con MT5 real bajo Wine (`Tools/run_web_e2e.sh`): el script MQL5 envía telemetría UTF-8 firmada, recibe, verifica y confirma un `PAUSE` → 28/28.
- EA completo + servidor (`SMOKE_WEB=1 Tools/run_ea_smoke.sh`): 8 envíos de telemetría, `PAUSE` aplicado, confirmado, visible en el servidor, entradas bloqueadas por `PAUSED` y `web.last_cmd=1` persistido.
- Interfaz revisada en Chromium (claro, oscuro, 390 px de ancho): sin errores de consola ni desplazamiento horizontal.

No se probó con un servidor público ni con un certificado real: esa parte depende de tu despliegue.

## 6. Límites conocidos
- La URL debe añadirse a mano en las opciones de MT5 (la lista se guarda cifrada en la configuración del terminal; no se puede configurar desde un `.ini` de arranque).
- `WebRequest` bloquea el hilo del EA hasta 2,5 s por petición si el servidor es lento; por eso el backoff y la omisión de la consulta de comandos cuando la telemetría falla.
- El indicador "EA en línea" se basa en el último reporte (≤ 120 s); no distingue entre EA detenido y problema de red.
