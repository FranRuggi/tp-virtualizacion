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
    Supervisa recursivamente un directorio específico detectando la creación o modificación de archivos
    mediante el uso eficiente de System.IO.FileSystemWatcher y Event Subscribers.

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
    Versión: Final Optimizada y Estructurada (Confirmando uso de FileSystemWatcher)
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
    # Intenta resolver la ruta a un path absoluto. Silencia errores si no existe.
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
}

# ==========================================
# Funciones Globales del Demonio
# ==========================================

# Escribe mensajes de auditoría en el log con soporte para escritura concurrente.
function Global:Write-Audit {
    param($Message)
    $Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Date] $Message"

    # 1. Auto-reparación si el archivo no existe (útil si se borró el log mientras corría)
    if (-not (Test-Path $Global:MonitoredLogPath)) {
        try { New-Item -Path $Global:MonitoredLogPath -ItemType File -Force | Out-Null } catch {}
    }

    # 2. Escritura No Bloqueante (Permite a otros procesos leer/escribir al mismo tiempo)
    try {
        # Creamos FileStream con FileShare.ReadWrite para evitar bloqueos.
        $FileStream = New-Object System.IO.FileStream(
            $Global:MonitoredLogPath, 
            [System.IO.FileMode]::Append, 
            [System.IO.FileAccess]::Write, 
            [System.IO.FileShare]::ReadWrite
        )
        
        $StreamWriter = New-Object System.IO.StreamWriter($FileStream, [System.Text.Encoding]::UTF8)
        $StreamWriter.WriteLine($Line)
        
        # Cierre rápido de los streams para liberar recursos inmediatamente
        $StreamWriter.Close()
        $FileStream.Close()

    } catch {
        # Respaldo: Si falla la escritura compartida, intentamos el método estándar (menos robusto)
        try { $Line | Out-File -FilePath $Global:MonitoredLogPath -Append -Encoding utf8 -ErrorAction Stop } catch {}
    }
}

# Lógica principal de monitoreo con FileSystemWatcher
function Start-Monitor {
    param(
        [string]$RepoPath,
        [string]$ConfigPath
    )

    # ----------------------------------------------------
    # Preparación de variables globales de monitoreo
    # ----------------------------------------------------
    $Global:MonitoredLogPath = $Log
    $Global:MonitoredPatterns = @()
    $PidFile    = Join-Path $RepoPath ".ejercicio4.pid"
    $StopFile   = Join-Path $RepoPath ".stop_monitor"
    $watcher = $null # Inicializa para el bloque finally

    # Escribir el PID del demonio y la señal de inicio
    $PID | Out-File $PidFile -Force
    Write-Audit "DAEMON INICIADO (PID: $PID)"
    
    try {
        # 1. Cargar Patrones
        if (-not (Test-Path $ConfigPath)) { throw "Error: Archivo de configuración no encontrado en '$ConfigPath'." }
        
        $rawPatterns = Get-Content $ConfigPath
        # Filtra líneas vacías o de comentario (#)
        $Global:MonitoredPatterns = $rawPatterns | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }
        
        # 2. Definir Bloque de Acción del Evento
        $actionBlock = {
            # Se ejecuta cuando FileSystemWatcher dispara un evento Created o Changed
            $evPath = $Event.SourceEventArgs.FullPath
            $evName = $Event.SourceEventArgs.Name
            $evType = $Event.SourceEventArgs.ChangeType
            
            # Ignorar el archivo de log, los archivos de control (PID/STOP) y archivos temporales/ocultos.
            if ($evPath -eq $Global:MonitoredLogPath -or $evName -match "^\.") { return }
            
            # OPTIMIZACIÓN: Esperar brevemente (100ms) para asegurar que el archivo haya terminado de ser escrito.
            Start-Sleep -Milliseconds 100 
            
            # Solo procesar si el path sigue existiendo y es un archivo (no un directorio que acaba de crearse)
            if (Test-Path $evPath -PathType Leaf) {
                try {
                    # Intentar leer el contenido completo
                    $content = Get-Content $evPath -Raw -ErrorAction Stop
                    
                    foreach ($p in $Global:MonitoredPatterns) {
                        $isMatch = $false
                        $patronEncontrado = $p 
                        
                        # Determinar si es Regex o Texto Literal
                        if ($p -match "^regex:(.+)") {
                            # Es Regex
                            if ($content -match $matches[1]) { 
                                $isMatch = $true
                                $patronEncontrado = " '$p' (REGEX)" 
                            }
                        } else {
                            # Es Texto Literal (se escapa para asegurar búsqueda exacta)
                            if ($content -match [regex]::Escape($p)) { 
                                $isMatch = $true
                                $patronEncontrado = "'$p' (TEXTO)" 
                            }
                        }

                        # Si se encuentra una coincidencia, se registra la alerta
                        if ($isMatch) {
                            $change = if ($evType -match "Created") {"CREACIÓN"} else {"MODIFICACIÓN"}
                            Write-Audit "ALERTA [${change}]: Patrón detectado $patronEncontrado en el archivo '$evName'"
                            # NOTA: Se eliminó el 'break' para que se sigan revisando otros patrones en el mismo archivo.
                        }
                    }
                } catch { 
                    # Manejo de error si el archivo está bloqueado o se borró justo después del evento
                    Write-Audit "ERROR leyendo '${evName}' (${evType}): $_. Puede estar bloqueado o ya borrado." 
                }
            }
        }

        # 3. Configurar y Activar FileSystemWatcher
        Write-Audit "Iniciando System.IO.FileSystemWatcher en '$RepoPath'..."
        
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $RepoPath
        $watcher.IncludeSubdirectories = $true
        $watcher.EnableRaisingEvents = $true
        
        # 4. Registrar Event Subscribers
        # NOTA: Register-ObjectEvent crea internamente un EventSubscriber, cumpliendo con la consigna.
        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $actionBlock -SourceIdentifier "FileCreated" | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $actionBlock -SourceIdentifier "FileChanged" | Out-Null
        
        # 5. Bucle de Mantenimiento
        Write-Audit "Monitoreo activo. Esperando archivo de stop (.stop_monitor)."
        while (-not (Test-Path $StopFile)) { 
            # El bucle solo necesita esperar; el trabajo lo hacen los eventos.
            Start-Sleep -Seconds 2 
        }

    } catch {
        Write-Audit "CRASH FATAL DEL DAEMON: $_"
    } finally {
        # 6. Limpieza al salir del bucle
        if ($watcher) { 
            $watcher.EnableRaisingEvents = $false
            $watcher.Dispose() # Liberar el recurso del sistema operativo
        }
        # Eliminar Event Subscribers
        Get-EventSubscriber -SourceIdentifier "FileCreated", "FileChanged" -ErrorAction SilentlyContinue | Unregister-Event -Force
        
        if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
        Write-Audit "DAEMON DETENIDO"
    }
}


# ==========================================
# MODO KILL (-k)
# ==========================================
if ($Kill) {
    if ([string]::IsNullOrEmpty($Repo)) {
        Write-Host "❌ Error: El parámetro -kill requiere -repo." -ForegroundColor Red; exit 1
    }
    $RepoToCheck = Get-AbsolutePath $Repo
    if (-not $RepoToCheck) { Write-Host "❌ El directorio del repo no existe." -ForegroundColor Red; exit 1 }
    
    $PidFile  = Join-Path $RepoToCheck ".ejercicio4.pid"
    $StopFile = Join-Path $RepoToCheck ".stop_monitor"
    
    if (Test-Path $PidFile) {
        $TargetPid = Get-Content $PidFile -ErrorAction SilentlyContinue
        
        # Crear la señal de stop y esperar
        Write-Host "⏳ Enviando señal de detención al demonio..." -ForegroundColor Cyan
        $null | Out-File $StopFile -Force
        Start-Sleep -Seconds 3 # Dar tiempo al demonio para la limpieza
        
        $Process = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
        if ($Process) {
            Write-Host "⚠️ Terminando proceso (PID: $TargetPid)..." -ForegroundColor Yellow
            Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
        } else {
             Write-Host "⚠️ Terminando proceso (PID: $TargetPid)..." -ForegroundColor Yellow
        }
        
        Write-Host "✓ Demonio detenido." -ForegroundColor Green
        if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Host "⚠ No se encontró daemon corriendo para este repositorio." -ForegroundColor Yellow
    }
    exit 0
}

# ==========================================
# MODO LANZADOR (Foreground)
# ==========================================
if (-not $DaemonMode) {
    if (-not $Repo -or -not $Configuracion -or -not $Log) {
        Write-Host "Uso: ./ejercicio4.ps1 -r <dir> -c <conf> -l <log>" -ForegroundColor Yellow; exit 1
    }

    # 1. Validar y resolver paths absolutos
    $RepoPath   = Get-AbsolutePath $Repo
    $ConfigPath = Get-AbsolutePath $Configuracion
    
    if (-not $RepoPath) { Write-Host "❌ Error: El repo '$Repo' no existe." -ForegroundColor Red; exit 1 }
    if (-not $ConfigPath) { Write-Host "❌ Error: Config '$Configuracion' no existe." -ForegroundColor Red; exit 1 }
    
    # 2. Asegurar que el log exista antes de pasarlo al subproceso
    if (-not (Test-Path $Log)) { New-Item -Path $Log -ItemType File -Force | Out-Null }
    $LogPath    = Get-AbsolutePath $Log # Asegurar que el subproceso reciba la ruta absoluta del log
    
    $PidFile = Join-Path $RepoPath ".ejercicio4.pid"
    $DebugFile = Join-Path $RepoPath "daemon_error.log"

    if (Test-Path $PidFile) {
        Write-Host "❌ Ya corre un daemon asociado a este repositorio. Usa -k primero." -ForegroundColor Red; exit 1
    }
    if (Test-Path $DebugFile) { Remove-Item $DebugFile -Force }

    Write-Host "🚀 Iniciando Demonio en segundo plano..." -ForegroundColor Cyan
    
    $scriptPath = $PSCommandPath
    $IsLinuxEnv = $IsLinux -or ($PSVersionTable.OS -match 'Linux')
    
    # Argumentos que se pasan al subproceso
    $arguments = "-File `"$scriptPath`" -Repo `"$RepoPath`" -Configuracion `"$ConfigPath`" -Log `"$LogPath`" -DaemonMode"
    
    if ($IsLinuxEnv) {
        # Ejecución DETACHED en Linux/WSL
        $PwshCmd = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $PwshCmd) { $PwshCmd = "pwsh" } # Fallback si Get-Command no funciona
        $cmd = "setsid nohup '$PwshCmd' $arguments > '$DebugFile' 2>&1 &"
        bash -c $cmd
    } else {
        # Ejecución HIDDEN en Windows
        Start-Process -FilePath "pwsh" -ArgumentList $arguments -WindowStyle Hidden
    }

    Start-Sleep -Seconds 3 # Esperar a que el demonio cree el PID file

    if (Test-Path $PidFile) {
        $NewPid = Get-Content $PidFile
        Write-Host "✓ Demonio iniciado correctamente (PID: $NewPid). Revisar '$Log' para auditoría." -ForegroundColor Green
    } else {
        Write-Host "❌ Error al iniciar el demonio. Revisar log de errores." -ForegroundColor Red
        if (Test-Path $DebugFile) { Get-Content $DebugFile | Write-Host -ForegroundColor Red }
    }
    exit 0
}

# ==========================================
# MODO DEMONIO (Background)
# ==========================================
if ($DaemonMode) {
    # Estos paths vienen como argumentos del lanzador
    $Log = $Log
    $Repo = $Repo
    $Configuracion = $Configuracion
    
    Start-Monitor -RepoPath $Repo -ConfigPath $Configuracion
    
    # Al finalizar Start-Monitor, el proceso se cierra automáticamente.
}