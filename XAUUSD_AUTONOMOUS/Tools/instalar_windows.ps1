# instalar_windows.ps1 - instala el EA en tu MetaTrader 5 (Windows) y arranca el dashboard web.
#
#  1. Busca la carpeta de datos de MT5 (%APPDATA%\MetaQuotes\Terminal\<id>), prefiriendo la de Deriv.
#  2. Copia Include\XAUUSD, el EA, RegimeLogger (validacion, no opera) y los scripts SymbolSpecDump / ExportCalendar
#     (si ya existia una version anterior, la guarda como copia de seguridad).
#  3. Compila con MetaEditor y muestra el resultado (debe ser 0 errores).
#  4. Arranca el dashboard web (iniciar_dashboard.ps1).
# No toca la configuracion de MT5, ni otros EA, ni tus cuentas.
#
# Uso: powershell -ExecutionPolicy Bypass -File instalar_windows.ps1 [-DataDir <carpeta de datos>] [-NoDashboard]
param(
    [string]$DataDir = '',
    [switch]$NoDashboard
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$project = Split-Path -Parent $PSScriptRoot          # ...\XAUUSD_AUTONOMOUS
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Fail([string]$msg) { Write-Host ""; Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step([string]$msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

# --- 1. Carpeta de datos de MT5 y su instalacion
Step "Buscando MetaTrader 5"
$cands = @()
if ($DataDir) {
    $origin = ''
    $of = Join-Path $DataDir 'origin.txt'
    if (Test-Path $of) { $origin = (Get-Content -Path $of -Raw).Trim() }
    $cands += [pscustomobject]@{ Data = $DataDir; Install = $origin }
} else {
    $root = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    if (Test-Path $root) {
        foreach ($d in Get-ChildItem -Path $root -Directory) {
            $of = Join-Path $d.FullName 'origin.txt'
            if (-not (Test-Path $of) -or -not (Test-Path (Join-Path $d.FullName 'MQL5'))) { continue }
            $origin = (Get-Content -Path $of -Raw).Trim()
            if (Test-Path (Join-Path $origin 'terminal64.exe')) {
                $cands += [pscustomobject]@{ Data = $d.FullName; Install = $origin }
            }
        }
    }
}
if ($cands.Count -eq 0) {
    Fail "No encontre ninguna instalacion de MT5. En MT5 usa Archivo > Abrir carpeta de datos, copia esa ruta y ejecuta: instalar_windows.ps1 -DataDir '<ruta>'"
}
$deriv = @($cands | Where-Object { $_.Install -match 'Deriv' })
if ($cands.Count -gt 1 -and $deriv.Count -eq 1) { $cands = $deriv }
if ($cands.Count -gt 1) {
    Write-Host "Hay varias instalaciones de MT5:"
    for ($i = 0; $i -lt $cands.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $cands[$i].Install) }
    $n = Read-Host "Numero de la instalacion de Deriv"
    if (-not ($n -match '^\d+$') -or [int]$n -lt 1 -or [int]$n -gt $cands.Count) { Fail "Opcion no valida." }
    $sel = $cands[[int]$n - 1]
} else { $sel = $cands[0] }
$mql5 = Join-Path $sel.Data 'MQL5'
Write-Host "MT5:              $($sel.Install)"
Write-Host "Carpeta de datos: $($sel.Data)"

# --- 2. Copiar archivos (con copia de seguridad de versiones anteriores)
Step "Copiando el EA y sus modulos"
$copies = @(
    @{ Src = 'Include\XAUUSD';                           Dst = 'Include\XAUUSD';                       Dir = $true },
    @{ Src = 'Experts\XAUUSD_Autonomous.mq5';            Dst = 'Experts\XAUUSD\XAUUSD_Autonomous.mq5'; Dir = $false },
    @{ Src = 'Tests\Backtesting\RegimeLogger.mq5';       Dst = 'Experts\XAUUSD\RegimeLogger.mq5';      Dir = $false },
    @{ Src = 'Tests\Validation\SymbolSpecDump.mq5';      Dst = 'Scripts\XAUUSD\SymbolSpecDump.mq5';    Dir = $false },
    @{ Src = 'Tests\Backtesting\ExportCalendar.mq5';     Dst = 'Scripts\XAUUSD\ExportCalendar.mq5';    Dir = $false }
)
foreach ($c in $copies) {
    $src = Join-Path $project $c.Src
    $dst = Join-Path $mql5 $c.Dst
    if (-not (Test-Path $src)) { Fail "Falta $src en el proyecto descargado." }
    if (Test-Path $dst) {
        $bak = "$dst.bak_$stamp"
        Move-Item -Path $dst -Destination $bak
        Write-Host "  copia de seguridad: $bak"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    if ($c.Dir) { Copy-Item -Path $src -Destination $dst -Recurse } else { Copy-Item -Path $src -Destination $dst }
    Write-Host "  $($c.Dst)"
}

# --- 3. Compilar
Step "Compilando con MetaEditor"
$editor = Join-Path $sel.Install 'MetaEditor64.exe'
$compiled = $true
if (-not (Test-Path $editor)) {
    Write-Host "No encontre MetaEditor64.exe en $($sel.Install). Compila a mano: IDE (F4) > Experts\XAUUSD\XAUUSD_Autonomous.mq5 > F7." -ForegroundColor Yellow
    $compiled = $false
} else {
    foreach ($rel in @('Experts\XAUUSD\XAUUSD_Autonomous.mq5', 'Experts\XAUUSD\RegimeLogger.mq5', 'Scripts\XAUUSD\SymbolSpecDump.mq5', 'Scripts\XAUUSD\ExportCalendar.mq5')) {
        $file = Join-Path $mql5 $rel
        $log = Join-Path $env:TEMP ("xad_compile_{0}.log" -f [IO.Path]::GetFileNameWithoutExtension($file))
        Remove-Item -Path $log -ErrorAction SilentlyContinue
        $edArgs = @("/compile:`"$file`"", "/log:`"$log`"")
        if ($mql5 -notmatch ' ') { $edArgs += "/include:`"$mql5`"" }
        $sp = @{ FilePath = $editor; ArgumentList = $edArgs; Wait = $true }
        if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { $sp.WindowStyle = 'Hidden' }
        Start-Process @sp | Out-Null
        if (-not (Test-Path $log)) { Write-Host "  $rel : MetaEditor no genero el registro" -ForegroundColor Yellow; $compiled = $false; continue }
        $text = Get-Content -Path $log -Encoding Unicode
        $text | Where-Object { $_ -match ': (error|warning) ' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        $result = ($text | Where-Object { $_ -match '^Result:' } | Select-Object -Last 1)
        if ($result -match '^Result: 0 errors') { Write-Host "  $rel : $result" -ForegroundColor Green }
        else { Write-Host "  $rel : $result" -ForegroundColor Red; $compiled = $false }
    }
}

# --- 4. Siguientes pasos y dashboard
Step "Listo"
if ($compiled) { Write-Host "EA instalado y compilado sin errores." -ForegroundColor Green }
else { Write-Host "Revisa los mensajes de compilacion de arriba (o compila a mano con F7) y mandaselos a Claude." -ForegroundColor Yellow }
Write-Host @"

Lo que falta lo tienes que hacer tu en MT5 (son clics de la interfaz):
  1. Navegador (Ctrl+N): clic derecho en 'Asesores Expertos' > Actualizar.
  2. Herramientas > Opciones > Asesores Expertos: marcar 'Permitir WebRequest para las URL listadas'
     y anadir http://127.0.0.1:8080 . Aceptar.
  3. Boton 'Trading algoritmico' en verde.
  4. Arrastrar XAUUSD > XAUUSD_Autonomous al grafico de XAUUSD. En 'Parametros de entrada':
     InpWebEnabled=true, InpWebUrl=http://127.0.0.1:8080, InpWebToken=(se copia al portapapeles abajo).
"@
if ($NoDashboard) { exit 0 }
Step "Arrancando el dashboard web"
& (Join-Path $project 'WebDashboard\iniciar_dashboard.ps1')
