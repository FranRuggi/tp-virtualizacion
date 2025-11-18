
#!/usr/bin/env pwsh



# GRUPO 2
# RUGGIERO BELLONE, ZOIS ANDRES UZIEL
# ROMBOLÁ FIGUEROA, FACUNDO AGUSTÍN
# RUGGIERI, FRANCO
# CROTTI, TOMÁS BENJAMÍN
# RIVERA MAMANI, VICTOR LEONCIO

<#
.SYNOPSIS
    Monitor de archivos en segundo plano (Demonio) que busca patrones prohibidos.

.DESCRIPTION
    Este script implementa un servicio de monitoreo (daemon) compatible con Windows y Linux/WSL.
    Supervisa recursivamente un directorio específico detectando la creación o modificación de archivos.
    Si el contenido de un archivo coincide con alguno de los patrones definidos en la configuración,
    se genera una alerta en el archivo de log especificado.

    Características principales:
    - Ejecución en segundo plano (detached) usando nohup/Start-Process.
    - Soporte para Texto plano y Expresiones Regulares (prefijo 'regex:').
    - Log con escritura concurrente (FileShare.ReadWrite) y auto-recuperación.
    - Bajo consumo de recursos (Event-driven con FileSystemWatcher).

.PARAMETER Repo
    (Alias: -r) Ruta del directorio que se va a monitorear recursivamente.

.PARAMETER Configuracion
    (Alias: -c) Ruta del archivo que contiene los patrones a buscar.
    Formato del archivo:
    - Una palabra por línea para búsqueda exacta.
    - Usar 'regex:' al inicio para expresiones regulares (ej: regex:^COD_\d{4}).

.PARAMETER Log
    (Alias: -l) Ruta del archivo donde se escribirán las auditorías y alertas.

.PARAMETER Kill
    (Alias: -k) Interruptor para DETENER el demonio asociado al repositorio indicado.

.PARAMETER DaemonMode
    (Interno) Switch utilizado por el script para ejecutarse en segundo plano. No usar manualmente.

.EXAMPLE
    Lanzar el monitoreo:
    ./ejercicio4.ps1 -r ./lotes_de_prueba -c ./patterns.conf -l ./audit.log

.EXAMPLE
    Detener el monitoreo:
    ./ejercicio4.ps1 -k -r ./lotes_de_prueba

.NOTES
    Versión: Final Optimizada (WSL/Concurrency Support)
    Fecha: Noviembre 2025
#>

param(
    [Alias('r')][string]$Repo,
    [Alias('c')][string]$Configuracion,
    [Alias('l')][string]$Log,
    [Alias('k')][switch]$Kill,
    [switch]$DaemonMode
)

function Get-AbsolutePath {
    param($Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
}

# ==========================================
# MODO KILL (-k)
# ==========================================
if ($Kill) {
    if ([string]::IsNullOrEmpty($Repo)) {
        Write-Host "❌ Error: El parámetro -kill requiere -repo." -ForegroundColor Red; exit 1
    }
    $RepoToCheck = Get-AbsolutePath $Repo
    if (-not $RepoToCheck) { Write-Host "❌ El directorio no existe." -ForegroundColor Red; exit 1 }
    
    $PidFile  = Join-Path $RepoToCheck ".ejercicio4.pid"
    $StopFile = Join-Path $RepoToCheck ".stop_monitor"
    
    if (Test-Path $PidFile) {
        $TargetPid = Get-Content $PidFile -ErrorAction SilentlyContinue
        $null | Out-File $StopFile -Force
        Write-Host "⏳ Deteniendo..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
        if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
        }
        Write-Host "✓ Demonio detenido." -ForegroundColor Green
        if (Test-Path $PidFile) { Remove-Item $PidFile -Force }
        if (Test-Path $StopFile) { Remove-Item $StopFile -Force }
    } else {
        Write-Host "⚠ No se encontró daemon corriendo." -ForegroundColor Yellow
    }
    exit 0
}

# ==========================================
# MODO LANZADOR
# ==========================================
if (-not $DaemonMode) {
    if (-not $Repo -or -not $Configuracion -or -not $Log) {
        Write-Host "Uso: ./ejercicio4.ps1 -r <dir> -c <conf> -l <log>" -ForegroundColor Yellow; exit 1
    }

    if (-not (Test-Path $Repo)) { Write-Host "❌ Error: El repo '$Repo' no existe." -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $Configuracion)) { Write-Host "❌ Error: Config '$Configuracion' no existe." -ForegroundColor Red; exit 1 }

    $RepoPath   = Get-AbsolutePath $Repo
    $ConfigPath = Get-AbsolutePath $Configuracion
    if (-not (Test-Path $Log)) { New-Item -Path $Log -ItemType File -Force | Out-Null }
    $LogPath    = Get-AbsolutePath $Log
    
    $PidFile = Join-Path $RepoPath ".ejercicio4.pid"
    $DebugFile = Join-Path $RepoPath "daemon_error.log"

    if (Test-Path $PidFile) {
        Write-Host "❌ Ya corre un daemon. Usa -k primero." -ForegroundColor Red; exit 1
    }
    if (Test-Path $DebugFile) { Remove-Item $DebugFile -Force }

    Write-Host "🚀 Iniciando Demonio..." -ForegroundColor Cyan
    
    $scriptPath = $PSCommandPath
    $IsLinuxEnv = $IsLinux -or ($PSVersionTable.OS -match 'Linux')

    if ($IsLinuxEnv) {
        $PwshCmd = (Get-Command pwsh).Source
        if (-not $PwshCmd) { $PwshCmd = "pwsh" }
        $cmd = "setsid nohup '$PwshCmd' -File '$scriptPath' -Repo '$RepoPath' -Configuracion '$ConfigPath' -Log '$LogPath' -DaemonMode > '$DebugFile' 2>&1 &"
        bash -c $cmd
    } else {
        Start-Process -FilePath "pwsh" -ArgumentList "-File `"$scriptPath`" -Repo `"$RepoPath`" -Configuracion `"$ConfigPath`" -Log `"$LogPath`" -DaemonMode" -WindowStyle Hidden
    }

    Start-Sleep -Seconds 3

    if (Test-Path $PidFile) {
        $NewPid = Get-Content $PidFile
        Write-Host "✓ Demonio iniciado (PID: $NewPid)" -ForegroundColor Green
    } else {
        Write-Host "❌ Error al iniciar." -ForegroundColor Red
        if (Test-Path $DebugFile) { Get-Content $DebugFile | Write-Host -ForegroundColor Red }
    }
    exit 0
}

# ==========================================
# MODO DEMONIO
# ==========================================
if ($DaemonMode) {
    $RepoPath   = $Repo
    $ConfigPath = $Configuracion
    $LogPath    = $Log
    $PidFile    = Join-Path $RepoPath ".ejercicio4.pid"
    $StopFile   = Join-Path $RepoPath ".stop_monitor"

    $PID | Out-File $PidFile -Force

    $Global:MonitoredLogPath = $LogPath
    $Global:MonitoredPatterns = @()

    function Global:Write-Audit {
        param($Message)
        $Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $Line = "[$Date] $Message"

        # 1. Auto-reparación si el archivo no existe
        if (-not (Test-Path $Global:MonitoredLogPath)) {
             try { New-Item -Path $Global:MonitoredLogPath -ItemType File -Force | Out-Null } catch {}
        }

        # 2. Escritura "No Bloqueante" (Shared Write)
        try {
            # Abrimos el archivo permitiendo que otros procesos (como tu editor) lo lean al mismo tiempo
            # FileMode.Append: Agrega al final
            # FileAccess.Write: Nosotros queremos escribir
            # FileShare.ReadWrite: ¡Permite que otros lean y escriban a la vez!
            
            $FileStream = New-Object System.IO.FileStream(
                $Global:MonitoredLogPath, 
                [System.IO.FileMode]::Append, 
                [System.IO.FileAccess]::Write, 
                [System.IO.FileShare]::ReadWrite
            )
            
            $StreamWriter = New-Object System.IO.StreamWriter($FileStream, [System.Text.Encoding]::UTF8)
            $StreamWriter.WriteLine($Line)
            
            # Es importante cerrar el stream rápido para liberar recursos
            $StreamWriter.Close()
            $FileStream.Close()

        } catch {
            # Si falla (ej: bloqueo exclusivo total), intentamos el método viejo como respaldo
            try { $Line | Out-File -FilePath $Global:MonitoredLogPath -Append -Encoding utf8 -ErrorAction Stop } catch {}
        }
    }

    Write-Audit "DAEMON INICIADO (PID: $PID)"

    try {
        if (-not (Test-Path $ConfigPath)) { throw "Config not found" }
        
        $rawPatterns = Get-Content $ConfigPath
        $Global:MonitoredPatterns = $rawPatterns | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }
        
        $actionBlock = {
            $evPath = $Event.SourceEventArgs.FullPath
            $evName = $Event.SourceEventArgs.Name
            
            if ($evPath -eq $Global:MonitoredLogPath -or $evName -match "^\.") { return }
            
            # OPTIMIZACIÓN: Bajamos de 500ms a 100ms para que sea más rápido
            Start-Sleep -Milliseconds 100 
            
            if (Test-Path $evPath -PathType Leaf) {
                try {
                    $content = Get-Content $evPath -Raw -ErrorAction Stop
                    
                    foreach ($p in $Global:MonitoredPatterns) {
                        $isMatch = $false
                        
                        # Guardamos el patrón original para mostrarlo en el log
                        $patronEncontrado = $p 
                        
                        if ($p -match "^regex:(.+)") {
                            if ($content -match $matches[1]) { 
                                $isMatch = $true
                                # Aclaramos en el log que fue por Regex
                                $patronEncontrado = " '$p (REGEX)' " 
                            }
                        } else {
                            if ($content -match [regex]::Escape($p)) { 
                                $isMatch = $true
                                # Aclaramos en el log que fue Texto
                                $patronEncontrado = "'$p' (TEXTO)" 
                            }
                        }

                        if ($isMatch) {
                            # AHORA SÍ: Muestra el patrón real
                            Write-Audit "ALERTA: Se detectó patrón $patronEncontrado en el archivo '$evName'"
                            break
                        }
                    }
                } catch { Write-Audit "ERROR leyendo ${evName}: $_" }
            }
        }

        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $RepoPath
        $watcher.IncludeSubdirectories = $true
        $watcher.EnableRaisingEvents = $true
        
        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $actionBlock | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $actionBlock | Out-Null
        
        while (-not (Test-Path $StopFile)) { Start-Sleep -Seconds 2 }

    } catch {
        Write-Audit "CRASH: $_"
    } finally {
        $watcher.EnableRaisingEvents = $false
        Get-EventSubscriber | Unregister-Event -Force
        if ($watcher) { $watcher.Dispose() }
        if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
        Write-Audit "DAEMON DETENIDO"
    }
}