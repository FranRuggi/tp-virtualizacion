# GRUPO 2

# RUGGIERO BELLONE, ZOIS ANDRES UZIEL
# ROMBOLÁ FIGUEROA, FACUNDO AGUSTÍN
# RUGGIERI, FRANCO
# CROTTI, TOMÁS BENJAMÍN
# RIVERA MAMANI, VICTOR LEONCIO

<#
.SYNOPSIS
Monitorea un directorio para detectar credenciales sensibles en archivos modificados.
.DESCRIPTION
Este script se ejecuta como un demonio en segundo plano, escaneando solo los archivos
modificados en el directorio especificado. Busca patrones definidos en un archivo de
configuración (palabras clave o regex). Si encuentra coincidencias nuevas, registra
una alerta en el log. Solo reacciona a cambios futuros. Puede iniciarse o detenerse.
.PARAMETER repo
Ruta absoluta o relativa al directorio a auditar. (Obligatorio).
.PARAMETER configuracion
Ruta al archivo de configuración con los patrones a buscar. (Obligatorio al iniciar).
.PARAMETER log
Ruta al archivo de log donde se registran las alertas. (Obligatorio al iniciar).
.PARAMETER kill
Flag booleano. Si se establece, detiene el demonio activo para el repositorio.
.EXAMPLE
.\ejercicio4.ps1 -repo "repo_prueba" -configuracion "patrones.conf" -log "logs/audit.log"
Inicia el monitoreo del directorio.
.EXAMPLE
.\ejercicio4.ps1 -kill -repo "repo_prueba"
Detiene el monitoreo del directorio.
#>
param(
    [Alias("r")][string]$repo,
    [Alias("c")][string]$configuracion,
    [Alias("l")][string]$log,
    [Alias("k")][switch]$kill
)
# === Funciones de ayuda ===
function Write-Uso {
    Write-Host @"
Uso: $($MyInvocation.MyCommand.Name) -repo <ruta> -configuracion <config> -log <logfile>
     $($MyInvocation.MyCommand.Name) -kill -repo <ruta>
"@
    exit 1
}
# === Parseo de parámetros ===
if (-not $repo) { Write-Uso }
$repo = (Resolve-Path $repo -ErrorAction Stop).Path
# Usar /tmp explícitamente y hash para nombre corto
$tempDir = '/tmp'
$repoHash = [math]::Abs($repo.GetHashCode()).ToString()
$pidFile = Join-Path $tempDir "audit_$repoHash.pid"
$alertDb = Join-Path $tempDir "audit_alerts_$repoHash.txt"
# === Modo Kill ===
if ($kill) {
    if (Test-Path $pidFile) {
        $jobId = Get-Content $pidFile
        $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
        if ($job) {
            Write-Host "Deteniendo demonio (Job ID: $jobId)..."
            Stop-Job -Id $jobId
            Remove-Job -Id $jobId -Force
            Remove-Item $pidFile, $alertDb -ErrorAction SilentlyContinue
            Write-Host "Demonio detenido."
        } else {
            Write-Host "No hay demonio activo. Limpiando archivos..."
            Remove-Item $pidFile, $alertDb -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "No hay demonio en ejecución para '$repo'"
    }
    exit 0
}
# === Validar resto ===
if (-not $configuracion -or -not $log) { Write-Uso }
$configuracion = (Resolve-Path $configuracion -ErrorAction Stop).Path
# Resolver ruta del log (puede no existir aún)
if (Test-Path $log) {
    $log = (Resolve-Path $log -ErrorAction Stop).Path
} else {
    $logDir = Split-Path $log -Parent
    if ($logDir) {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $logDir = (Resolve-Path $logDir -ErrorAction Stop).Path
        $log = Join-Path $logDir (Split-Path $log -Leaf)
    } else {
        $log = (Resolve-Path (Get-Location).Path -ErrorAction Stop).Path + "/" + (Split-Path $log -Leaf)  # Usar / para Linux
    }
}
if (-not (Test-Path $repo)) { Write-Error "Directorio no existe: $repo"; exit 1 }
if (-not (Test-Path $configuracion)) { Write-Error "Config no existe: $configuracion"; exit 1 }
# === Evitar múltiples instancias ===
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile
    if (Get-Job -Id $oldPid -ErrorAction SilentlyContinue) {
        Write-Error "Ya hay un demonio corriendo (Job ID: $oldPid)."
        exit 1
    } else {
        Remove-Item $pidFile, $alertDb -ErrorAction SilentlyContinue
    }
}
# === Preparar log y patrones ===
New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force | Out-Null
"" | Out-File -FilePath $log -Force -Encoding UTF8  # Usar Out-File en lugar de > para mayor control
$patterns = Get-Content $configuracion | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object { $_.Trim() }
if ($patterns.Count -eq 0) { Write-Error "No hay patrones válidos en $configuracion"; exit 1 }
"" | Out-File -FilePath $alertDb -Force -Encoding UTF8
# === Iniciar job en background (SIN SALIDA) ===
$jobScript = {
    param($repo, $log, $alertDb, $patterns)
    # Estado: mtime de cada archivo
    $fileMtime = @{}
    # Registrar mtime inicial (sin escanear)
    Get-ChildItem -Path $repo -Recurse -File | ForEach-Object {
        $fileMtime[$_.FullName] = $_.LastWriteTime.Ticks
    }
    while ($true) {
        $changed = $false
        Get-ChildItem -Path $repo -Recurse -File | ForEach-Object {
            $current = $_.LastWriteTime.Ticks
            $last = $fileMtime[$_.FullName]
            if (-not $last -or $current -gt $last) {
                try {
                    $lines = Get-Content $_.FullName -ErrorAction Stop
                    if ($null -eq $lines) { $lines = @() }
                } catch {
                    # No se puede leer el archivo, saltar
                    $fileMtime[$_.FullName] = $current
                    $changed = $true
                    return
                }
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    $lineNum = $i + 1
                    foreach ($p in $patterns) {
                        $match = $false
                        if ($p -like "regex:*") {
                            $regexPattern = $p.Substring(6)
                            if ($regexPattern.Length -gt 0) {
                                try {
                                    $match = $line -match $regexPattern
                                } catch {
                                    # Patrón regex inválido, ignorar
                                    $match = $false
                                }
                            }
                        } else {
                            $boundary = "(?<![\w\d_])$([regex]::Escape($p))(?!\w)"
                            $match = $line -match $boundary
                        }
                        if ($match) {
                            $key = "$($_.FullName):$lineNum`:$p"
                            if (-not (Test-Path $alertDb) -or -not (Select-String -Path $alertDb -Pattern ([regex]::Escape($key)) -Quiet)) {
                                $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                $name = $_.Name
                                "[{0}] Alerta: patrón '{1}' encontrado en el archivo '{2}' (línea {3})." -f $ts, $p, $name, $lineNum |
                                    Out-File -FilePath $log -Append -Encoding UTF8
                                $key | Out-File -FilePath $alertDb -Append -Encoding UTF8
                            }
                        }
                    }
                }
                $fileMtime[$_.FullName] = $current
                $changed = $true
            }
        }
        if (-not $changed) { Start-Sleep -Seconds 2 }
    }
}
$job = Start-Job -ScriptBlock $jobScript -ArgumentList $repo, $log, $alertDb, $patterns
$job.Id | Out-File -FilePath $pidFile -Encoding UTF8 -Force
# === Solo el script principal imprime ===
Write-Host "Demonio en segundo plano (Job ID: $($job.Id))"
Write-Host "Para detener: $($MyInvocation.MyCommand.Name) -kill -repo '$repo'"
Write-Host "Solo se alertará por cambios futuros."