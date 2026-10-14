# Dashboard web — arquitectura propuesta (no implementada)

> Estado: **solo diseño**. No existe ninguna conexión web en el EA. Construirla requiere un servidor propio y decisiones tuyas (ver §6). No se incluye ninguna simulación presentada como funcional.

## 1. Objetivo
Ver en el navegador/teléfono el mismo estado que el panel de MT5 y, como máximo, **pausar entradas o activar el modo seguro**. Nunca abrir operaciones, cambiar riesgo ni ver credenciales de trading.

## 2. Arquitectura
```
MT5 (EA)  --HTTPS POST (telemetría firmada, cada 30-60 s)-->  Backend propio  <--HTTPS--  Navegador
   ^                                                              |
   └--HTTPS GET (polling de comandos firmados, cada 30-60 s)------┘
```
- **Solo conexiones salientes desde el EA** (`WebRequest`). El terminal no abre puertos.
- `WebRequest` exige añadir la URL en *Herramientas → Opciones → Asesores Expertos → Permitir WebRequest*; **no funciona en el Strategy Tester** (según la documentación de MQL5) ni desde indicadores.

## 3. Mensajes
- **Telemetría** (EA → backend): estado del EA, régimen, sesión, posiciones (sin número de cuenta), exposición, pérdida diaria, bloqueos, última señal/operación, hora del servidor, versión. JSON firmado con **HMAC-SHA256** (`CryptEncode(CRYPT_HASH_SHA256)` permite implementar HMAC; verificar al implementar) usando un *token de dashboard*, más `timestamp` y `nonce` para evitar repeticiones.
- **Comandos** (backend → EA, por polling): lista cerrada `PAUSE`, `RESUME`, `SAFE_MODE`. Firmados igual; el EA rechaza firmas inválidas, comandos con más de 2 minutos o nonces repetidos. `CLOSE_ALL` y `EXIT_SAFE_MODE` quedan **solo** en el panel local de MT5.

## 4. Seguridad
- El token del dashboard no da acceso a la cuenta de trading (el EA no conoce ni envía credenciales).
- El token se configura como input del EA en la máquina del usuario; no se guarda en el repositorio.
- Backend con HTTPS, autenticación del usuario (p. ej. OAuth o contraseña + 2FA), registro de auditoría de cada comando.
- Si el backend no responde, el EA sigue funcionando igual (el dashboard es solo observación/pausa).

## 5. Requisitos de despliegue
- Servidor con dominio y certificado TLS válido (p. ej. Let's Encrypt).
- Backend sencillo (FastAPI/Node) + base de datos pequeña (SQLite/PostgreSQL) para telemetría e historial de comandos.
- Frontend estático (tablero de KPIs: equity, pérdida diaria, exposición, régimen, operaciones).
- Monitorización de caídas y alerta si el EA deja de reportar (latido).

## 6. Decisiones pendientes para construirlo
1. ¿Dónde se aloja el backend (VPS propio, servicio gestionado)?
2. ¿Método de autenticación para ti en la web?
3. ¿Frecuencia de telemetría y retención de datos?
4. ¿Se acepta que la web pueda pausar el EA, o solo observar?
