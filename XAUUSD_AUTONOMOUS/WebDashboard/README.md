# Dashboard web — instalación

Servidor en Python 3.8+ **sin dependencias externas** (`http.server` + `sqlite3`) y una página estática. El EA le envía telemetría firmada y recoge, como máximo, tres comandos: **PAUSE**, **RESUME** y **SAFE_MODE**. Desde la web no se puede abrir, cerrar ni modificar operaciones, cambiar el riesgo ni salir del modo seguro (eso queda solo en el panel de MT5). Diseño y seguridad: [Documentation/WEB_DASHBOARD.md](../Documentation/WEB_DASHBOARD.md).

## 1. Requisitos
- Un servidor Linux con Python 3.8+ y un **dominio con HTTPS** (el EA solo acepta `https://`, salvo `http://127.0.0.1` / `http://localhost` para pruebas en la misma máquina).
- Un proxy con TLS delante (el ejemplo usa Caddy, que obtiene el certificado automáticamente). El servidor Python escucha **solo en 127.0.0.1**.

## 2. Secretos (fuera del repositorio)
```bash
cd XAUUSD_AUTONOMOUS/WebDashboard
python3 server.py new-token        # -> XAD_TOKEN: se pone también en el EA (InpWebToken)
python3 server.py new-token        # -> XAD_SESSION_SECRET (otro valor distinto)
python3 server.py hash-password    # -> XAD_PASSWORD_HASH (contraseña de >= 12 caracteres para entrar a la web)
```
Guárdalos en un archivo de entorno con permisos restringidos, p. ej. `/etc/xad/xad.env` (`chmod 600`):
```
XAD_TOKEN=...
XAD_SESSION_SECRET=...
XAD_PASSWORD_HASH=pbkdf2$200000$...
XAD_DB=/var/lib/xad/dashboard.sqlite3
XAD_BIND=127.0.0.1
XAD_PORT=8080
XAD_COOKIE_SECURE=1
XAD_TRUST_PROXY=1
XAD_ALLOW_COMMANDS=1
```
| Variable | Significado |
|---|---|
| `XAD_TOKEN` | Clave HMAC compartida con el EA (≥ 32 caracteres). **No** es la contraseña de la cuenta de trading. |
| `XAD_SESSION_SECRET` | Firma de las cookies de sesión (≥ 32 caracteres). |
| `XAD_PASSWORD_HASH` | Hash PBKDF2-SHA256 de tu contraseña web. |
| `XAD_COOKIE_SECURE` | `1` en producción (cookie solo por HTTPS). `0` solo para pruebas locales sin TLS. |
| `XAD_TRUST_PROXY` | `1` si el servidor está detrás de un proxy local: el límite de intentos de login usa la última IP de `X-Forwarded-For`. Déjalo en `0` si el puerto es accesible sin pasar por el proxy. |
| `XAD_ALLOW_COMMANDS` | `0` = la web solo observa (los botones se desactivan y el servidor no entrega comandos). |

Si cambias `XAD_TOKEN`, cámbialo también en el EA.

## 3. Servicio (systemd) y TLS (Caddy)
`/etc/systemd/system/xad-dashboard.service`:
```ini
[Unit]
Description=XAUUSD Autonomous - dashboard web
After=network.target

[Service]
EnvironmentFile=/etc/xad/xad.env
ExecStart=/usr/bin/python3 /opt/xad/WebDashboard/server.py serve
User=xad
Restart=on-failure
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```
`/etc/caddy/Caddyfile`:
```
dashboard.tu-dominio.com {
    reverse_proxy 127.0.0.1:8080
}
```
Luego: `systemctl daemon-reload && systemctl enable --now xad-dashboard && systemctl reload caddy`. Comprueba en el navegador `https://dashboard.tu-dominio.com` (pantalla de acceso).

> Verifica estos pasos con la documentación de tu distribución y de tu versión de Caddy; son una plantilla, no se probaron en un servidor público desde este entorno.

## 4. Conectar el EA (MT5)
1. *Herramientas → Opciones → Asesores Expertos → Permitir WebRequest para las URL listadas* → añade `https://dashboard.tu-dominio.com`. Sin esto el EA registra `URL no permitida` (error 4014) y sigue operando normalmente.
2. Parámetros del EA (grupo *Dashboard web*): `InpWebEnabled=true`, `InpWebUrl=https://dashboard.tu-dominio.com`, `InpWebToken=<XAD_TOKEN>`, `InpWebIntervalSec=30`.
3. El token queda guardado en los parámetros del gráfico/perfil de tu terminal (texto plano en tu PC). No compartas esos archivos ni los subas al repositorio (`*.set` e `*.ini` están en `.gitignore`).

Comportamiento del EA:
- Cada `InpWebIntervalSec` (desde el temporizador, nunca en `OnTick`): envía la telemetría, recoge comandos, los verifica (firma HMAC, antigüedad ≤ 10 min, identificador nuevo), los aplica y confirma.
- Si el servidor no responde, el intervalo crece hasta ×10 (las peticiones son síncronas y no deben retrasar la gestión protectora) y vuelve al normal con el primer éxito. **El trading no depende del dashboard.**
- `PAUSE` solo actúa en `RUNNING`; `RESUME` solo en `PAUSED`; `SAFE_MODE` siempre. Cada comando queda en el log del EA (`WEB_COMMAND`) y en la tabla de auditoría del servidor.
- El último comando aplicado se guarda en el estado del EA: tras un reinicio no se vuelve a aplicar.
- Desactivado en el Strategy Tester (WebRequest no está disponible allí).

## 5. Pruebas
```bash
python3 -m unittest discover -s XAUUSD_AUTONOMOUS/WebDashboard/tests -v   # servidor (24 pruebas)
XAUUSD_AUTONOMOUS/Tools/run_web_e2e.sh           # cliente MQL5 real <-> servidor real (MT5 bajo Wine)
SMOKE_WEB=1 XAUUSD_AUTONOMOUS/Tools/run_ea_smoke.sh   # EA completo + servidor: telemetría, PAUSE aplicado y persistido
```
Las dos últimas requieren `http://127.0.0.1:8080` permitida para WebRequest en el terminal de pruebas.
