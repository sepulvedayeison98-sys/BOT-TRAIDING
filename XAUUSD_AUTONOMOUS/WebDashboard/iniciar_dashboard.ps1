# iniciar_dashboard.ps1 - arranca el dashboard web en este PC (http://127.0.0.1:8080).
#
# Primera vez: genera el token, el secreto y el hash de tu contrasena y los guarda en
# %USERPROFILE%\.xad\xad.env (FUERA del repositorio). Despues solo arranca el servidor y
# abre el navegador. Detener: Ctrl+C en esta ventana (o cerrarla).
#
# Uso: doble clic en iniciar_dashboard.bat, o en PowerShell:
#   powershell -ExecutionPolicy Bypass -File iniciar_dashboard.ps1 [-Reset] [-Port 8080] [-NoBrowser]
#   -Reset: genera claves nuevas (habra que cambiar InpWebToken en el EA).
param(
    [switch]$Reset,
    [int]$Port = 8080,
    [switch]$NoBrowser,
    [string]$ConfigDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.xad')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # sin barra de progreso en Invoke-WebRequest (mas rapido en PowerShell 5.1)
$here = $PSScriptRoot
$server = Join-Path $here 'server.py'
$envFile = Join-Path $ConfigDir 'xad.env'
$url = "http://127.0.0.1:$Port"

function Fail([string]$msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

# --- 1. Python 3 (el lanzador "py" de python.org, o "python"/"python3" si funcionan de verdad)
$py = $null
$pyArgs = @()
foreach ($cand in @(@('py', '-3'), @('python'), @('python3'))) {
    if (Get-Command $cand[0] -ErrorAction SilentlyContinue) {
        $extra = @($cand | Select-Object -Skip 1)
        try {
            $v = & $cand[0] @extra -c "import sys; print(sys.version_info[0] * 100 + sys.version_info[1])" 2>$null
            if ($LASTEXITCODE -eq 0 -and [int]$v -ge 308) { $py = $cand[0]; $pyArgs = $extra; break }
        } catch { }
    }
}
if (-not $py) {
    Fail "No se encontro Python 3.8 o superior. Instalalo desde https://www.python.org/downloads/ marcando 'Add python.exe to PATH' y vuelve a ejecutar este archivo."
}
if (-not (Test-Path $server)) { Fail "No se encontro server.py junto a este script ($here)." }

# --- 2. Claves (solo la primera vez o con -Reset)
if ($Reset -or -not (Test-Path $envFile)) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Write-Host "Configuracion inicial del dashboard" -ForegroundColor Cyan
    Write-Host "Elige la contrasena para entrar a la web (minimo 12 caracteres; no se muestra al escribir)."
    $token = (& $py @pyArgs $server new-token | Out-String).Trim()
    $secret = (& $py @pyArgs $server new-token | Out-String).Trim()
    $hash = $null
    for ($i = 0; $i -lt 3 -and -not $hash; $i++) {
        $out = (& $py @pyArgs $server hash-password | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $out.StartsWith('pbkdf2$')) { $hash = $out }
        else { Write-Host "Las contrasenas no coinciden o tienen menos de 12 caracteres. Intenta de nuevo." -ForegroundColor Yellow }
    }
    if (-not $hash) { Fail "No se pudo crear la contrasena." }
    if ($token.Length -lt 32 -or $secret.Length -lt 32) { Fail "No se pudieron generar las claves." }
    $lines = @(
        "XAD_TOKEN=$token",
        "XAD_SESSION_SECRET=$secret",
        "XAD_PASSWORD_HASH=$hash"
    )
    Set-Content -Path $envFile -Value $lines -Encoding ASCII
    Write-Host "Claves guardadas en $envFile (no lo compartas ni lo subas a GitHub)." -ForegroundColor Green
}

# --- 3. Cargar la configuracion
foreach ($line in Get-Content -Path $envFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $kv = $line -split '=', 2
    Set-Item -Path ("Env:" + $kv[0].Trim()) -Value $kv[1].Trim()
}
if (-not $env:XAD_TOKEN -or -not $env:XAD_PASSWORD_HASH -or -not $env:XAD_SESSION_SECRET) {
    Fail "El archivo $envFile esta incompleto. Ejecuta de nuevo con -Reset."
}
$env:XAD_BIND = '127.0.0.1'
$env:XAD_PORT = "$Port"
$env:XAD_COOKIE_SECURE = '0'   # sin TLS: solo valido porque escucha en 127.0.0.1 (este PC)
$env:XAD_DB = Join-Path $ConfigDir 'dashboard.sqlite3'

function Test-Up {
    try { Invoke-WebRequest -Uri "$url/" -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

# --- 4. Datos para MT5 (el token tambien queda en el portapapeles)
Write-Host ""
Write-Host "=== Configuracion del EA en MT5 ===" -ForegroundColor Cyan
Write-Host "1) Herramientas > Opciones > Asesores Expertos > 'Permitir WebRequest para las URL listadas': $url"
Write-Host "2) Parametros del EA (grupo Dashboard web):"
Write-Host "   InpWebEnabled     = true"
Write-Host "   InpWebUrl         = $url"
Write-Host "   InpWebToken       = $($env:XAD_TOKEN)"
Write-Host "   InpWebIntervalSec = 30"
try { Set-Clipboard -Value $env:XAD_TOKEN; Write-Host "   (el token esta copiado en el portapapeles)" -ForegroundColor Green } catch { }
Write-Host ""

# --- 5. Arrancar el servidor y abrir el navegador
if (Test-Up) {
    Write-Host "Ya hay un servidor respondiendo en $url." -ForegroundColor Yellow
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
}
$proc = Start-Process -FilePath $py -ArgumentList ($pyArgs + @("`"$server`"", 'serve')) -NoNewWindow -PassThru
$up = $false
for ($i = 0; $i -lt 40; $i++) {
    if ($proc.HasExited) { break }
    if (Test-Up) { $up = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $up) { Fail "El servidor no arranco (mira el mensaje de arriba). Si el puerto $Port esta ocupado usa -Port 8081 y esa URL en MT5." }
Write-Host "Dashboard funcionando en $url  -  deja esta ventana abierta; Ctrl+C para detenerlo." -ForegroundColor Green
if (-not $NoBrowser) { Start-Process $url }
Wait-Process -Id $proc.Id
