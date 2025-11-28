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
    Servicio de monitoreo (daemon) que:
    - Supervisa recursivamente un directorio.
    - Ante creación/modificación de archivos, busca patrones definidos.
    - Registra alertas en un archivo de log.

    Implementado como:
    - Job de PowerShell (Start-Job).
    - FileSystemWatcher + Register-ObjectEvent.
    - Log con escritura concurrente.

.PARAMETER Repo
    (Alias: -r) Ruta del directorio a monitorear recursivamente.

.PARAMETER Configuracion
    (Alias: -c) Archivo de patrones:
        - Una palabra por línea => texto exacto.
        - 'regex:<expresión>' => expresión regular.

.PARAMETER Log
    (Alias: -l) Archivo donde se escriben auditorías y alertas.

.PARAMETER Kill
    (Alias: -k) Detiene el demonio asociado al repositorio indicado.

.EXAMPLE
    ./ejercicio4.ps1 -r ./lotes_de_prueba -c ./patterns.conf -l ./audit.log

.EXAMPLE
    ./ejercicio4.ps1 -k -r ./lotes_de_prueba
#>

param(
    [Alias('r')]
    [string]$Repo,

    [Alias('c')]
    [string]$Configuracion,

    [Alias('l')]
    [string]$Log,

    [Alias('k')]
    [switch]$Kill
)

function Get-AbsolutePath {
    param($Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
}

# ================================
# MODO KILL (-k)
# ================================
if ($Kill) {
    if ([string]::IsNullOrEmpty($Repo)) {
        Write-Host "❌ Error: El parámetro -kill requiere -repo." -ForegroundColor Red
        exit 1
    }

    $RepoToCheck = Get-AbsolutePath $Repo
    if (-not $RepoToCheck) {
        Write-Host "❌ El directorio no existe." -ForegroundColor Red
        exit 1
    }

    $JobFile  = Join-Path $RepoToCheck ".ejercicio4.jobid"
    $StopFile = Join-Path $RepoToCheck ".stop_monitor"

    if (-not (Test-Path $JobFile)) {
        Write-Host "⚠ No se encontró daemon corriendo para este repo." -ForegroundColor Yellow
        exit 0
    }

    $jobId = Get-Content $JobFile -ErrorAction SilentlyContinue
    if (-not $jobId) {
        Write-Host "⚠ Archivo de estado corrupto, limpiando." -ForegroundColor Yellow
        Remove-Item $JobFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
        exit 0
    }

    $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue

    # Señal al job para que termine prolijo
    $null | Out-File $StopFile -Force

    if ($job) {
        Write-Host "⏳ Deteniendo daemon (JobID: $jobId)..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2

        if ($job.State -notin 'Completed','Stopped') {
            Stop-Job -Id $jobId -ErrorAction SilentlyContinue
        }

        Remove-Job -Id $jobId -ErrorAction SilentlyContinue
        Write-Host "✓ Demonio detenido." -ForegroundColor Green
    } else {
        Write-Host "⚠ Job no encontrado en esta sesión, limpiando archivos." -ForegroundColor Yellow
    }

    if (Test-Path $JobFile)  { Remove-Item $JobFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }

    exit 0
}

# ================================
# MODO LANZADOR (START)
# ================================
if (-not $Repo -or -not $Configuracion -or -not $Log) {
    Write-Host "Uso: ./ejercicio4.ps1 -r <dir> -c <conf> -l <log>  |  ./ejercicio4.ps1 -k -r <dir>" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $Repo)) {
    Write-Host "❌ Error: El directorio '$Repo' no existe." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Configuracion)) {
    Write-Host "❌ Error: Config '$Configuracion' no existe." -ForegroundColor Red
    exit 1
}

$RepoPath   = Get-AbsolutePath $Repo
$ConfigPath = Get-AbsolutePath $Configuracion

if (-not (Test-Path $Log)) {
    New-Item -Path $Log -ItemType File -Force | Out-Null
}
$LogPath = Get-AbsolutePath $Log

$JobFile  = Join-Path $RepoPath ".ejercicio4.jobid"
$StopFile = Join-Path $RepoPath ".stop_monitor"

# Si ya hay un job registrado, verificamos que no siga vivo
if (Test-Path $JobFile) {
    $existingId = Get-Content $JobFile -ErrorAction SilentlyContinue
    if ($existingId) {
        $existingJob = Get-Job -Id $existingId -ErrorAction SilentlyContinue
        if ($existingJob -and $existingJob.State -eq 'Running') {
            Write-Host "❌ Ya corre un daemon para este repo (JobID: $existingId). Usa -k primero." -ForegroundColor Red
            exit 1
        }
    }
    Remove-Item $JobFile -Force -ErrorAction SilentlyContinue
}

if (Test-Path $StopFile) {
    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
}

Write-Host "🚀 Iniciando Demonio como Job de PowerShell..." -ForegroundColor Cyan

# Demonio implementado como Job
$job = Start-Job -ArgumentList $RepoPath, $ConfigPath, $LogPath -ScriptBlock {
    param($RepoPath, $ConfigPath, $LogPath)

    $PidFile  = Join-Path $RepoPath ".ejercicio4.jobid"
    $StopFile = Join-Path $RepoPath ".stop_monitor"

    # Variables de script (compartidas con el -Action)
    $script:MonitoredLogPath  = $LogPath
    $script:MonitoredPatterns = @()

    function Write-Audit {
        param($Message)
        $Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $Line = "[$Date] $Message"

        if (-not (Test-Path $script:MonitoredLogPath)) {
            try { New-Item -Path $script:MonitoredLogPath -ItemType File -Force | Out-Null } catch {}
        }

        try {
            $FileStream = New-Object System.IO.FileStream(
                $script:MonitoredLogPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )

            $StreamWriter = New-Object System.IO.StreamWriter($FileStream, [System.Text.Encoding]::UTF8)
            $StreamWriter.WriteLine($Line)
            $StreamWriter.Close()
            $FileStream.Close()
        } catch {
            try { $Line | Out-File -FilePath $script:MonitoredLogPath -Append -Encoding utf8 -ErrorAction Stop } catch {}
        }
    }

    Write-Audit "DAEMON INICIADO (Job en proceso PID: $PID)"
    Write-Audit "DEBUG: RepoPath monitoreado = '$RepoPath'"

    try {
        if (-not (Test-Path $ConfigPath)) { throw "Config not found" }

        $rawPatterns = Get-Content $ConfigPath
        $script:MonitoredPatterns = $rawPatterns | Where-Object {
            $_ -notmatch '^\s*#' -and $_ -match '\S'
        }

        $actionBlock = {
            param($sender, $eventArgs)

            $evPath = $eventArgs.FullPath
            $evName = $eventArgs.Name
            $evType = $eventArgs.ChangeType

            Write-Audit "DEBUG: Evento '$evType' sobre '$evPath'"

            if ($evPath -eq $script:MonitoredLogPath -or $evName -match "^\.") {
                Write-Audit "DEBUG: Ignorado (log o archivo oculto): '$evName'"
                return
            }

            Start-Sleep -Milliseconds 100

            if (Test-Path $evPath -PathType Leaf) {
                try {
                    $content = Get-Content $evPath -Raw -ErrorAction Stop

                    foreach ($p in $script:MonitoredPatterns) {
                        $isMatch = $false
                        $patronEncontrado = $p

                        if ($p -match "^regex:(.+)") {
                            if ($content -match $matches[1]) {
                                $isMatch = $true
                                $patronEncontrado = "'$p' (REGEX)"
                            }
                        } else {
                            if ($content -match [regex]::Escape($p)) {
                                $isMatch = $true
                                $patronEncontrado = "'$p' (TEXTO)"
                            }
                        }

                        if ($isMatch) {
                            Write-Audit "ALERTA: Se detectó patrón $patronEncontrado en el archivo '$evName'"
                            break
                        }
                    }
                } catch {
                    Write-Audit "ERROR leyendo ${evName}: $_"
                }
            } else {
                Write-Audit "DEBUG: El path reportado por el evento no es un archivo: '$evPath'"
            }
        }

        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $RepoPath
        $watcher.IncludeSubdirectories = $true
        $watcher.Filter = "*.*"
        $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'
        $watcher.EnableRaisingEvents = $true

        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $actionBlock | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $actionBlock | Out-Null

        while (-not (Test-Path $StopFile)) {
            Start-Sleep -Seconds 2
        }

    } catch {
        Write-Audit "CRASH: $_"
    } finally {
        if ($watcher) {
            $watcher.EnableRaisingEvents = $false
            Get-EventSubscriber | Where-Object { $_.SourceObject -eq $watcher } | Unregister-Event -Force
            $watcher.Dispose()
        }
        if (Test-Path $PidFile)  { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
        Write-Audit "DAEMON DETENIDO"
    }
}

$job.Id | Out-File $JobFile -Force

Write-Host "✓ Demonio iniciado como Job (ID: $($job.Id))" -ForegroundColor Green
exit 0
