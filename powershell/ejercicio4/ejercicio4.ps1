# GRUPO 2

# RUGGIERO BELLONE, ZOIS ANDRES UZIEL
# ROMBOLÁ FIGUEROA, FACUNDO AGUSTÍN
# RUGGIERI, FRANCO
# CROTTI, TOMÁS BENJAMÍN
# RIVERA MAMANI, VICTOR LEONCIO

<# 
.SYNOPSIS
Monitorea un repositorio Git y registra alertas si detecta patrones sensibles en archivos modificados.

.DESCRIPTION
Daemon que observa el HEAD del repo. En cada nuevo commit lista archivos ACMR y
busca patrones definidos (texto literal o 'regex:...'). Intervalo fijo: 10s.
Una sola instancia por repo (pidfile con MD5 de la ruta).

.PARAMETER Repo
Ruta al repositorio Git (relativa o absoluta).

.PARAMETER Configuracion
Archivo con patrones (ignora vacías y líneas que comiencen con '#').
Prefijo 'regex:' para regex. Obligatorio al iniciar.

.PARAMETER Log
Archivo de log. Si no existe, se crea en el directorio actual. Default: ./audit.log

.PARAMETER Kill
Detiene el daemon del repo.

.PARAMETER Help
Muestra ayuda rápida.

.EXAMPLE
pwsh ./ejercicio4.ps1 -Repo ./repo -Configuracion ./patterns.conf -Log ./audit.log

.EXAMPLE
pwsh ./ejercicio4.ps1 -Repo ./repo -Kill

.NOTES
Requiere 'git' en PATH. Compatible con Windows PowerShell 5.1 y PowerShell 7+ (WSL/Windows).
⚠️ Recomendado: PowerShell 7.1 o superior. 
Si se usa una versión anterior, en la línea
    $proc = Start-Process -FilePath $pwshPath -ArgumentList $argLine -PassThru
debe agregarse -WindowStyle Hidden.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Repo,

    [Parameter(Mandatory=$false)]
    [string]$Configuracion,

    [Parameter(Mandatory=$false)]
    [string]$Log = "./audit.log",

    [switch]$Kill,
    [switch]$Help,

    # Uso interno (no invocar a mano)
    [switch]$RunDaemon
)

# ======== Pre-chequeos mínimos ========
try { Get-Command git -ErrorAction Stop | Out-Null }
catch { Write-Error "No se encontró 'git' en PATH."; exit 1 }

# ======== Constantes ========
$SleepSeconds = 10

# ======== Ayuda corta ========
function Show-Usage {
@"
Uso:
  pwsh ./ejercicio4.ps1 -Repo <ruta_repo> -Configuracion <patterns.conf> [-Log <audit.log>]
  pwsh ./ejercicio4.ps1 -Repo <ruta_repo> -Kill
  pwsh ./ejercicio4.ps1 -Repo <ruta_repo> -Help

Descripción:
  Daemon que monitorea el repo y escanea archivos cambiados por patrones sensibles.
  Intervalo fijo: ${SleepSeconds}s.
  ⚠️ Recomendado: PowerShell 7.1 o superior. 
     En versiones más viejas, en la línea con Start-Process debe agregarse -WindowStyle Hidden.

Parámetros:
  -Repo <ruta_repo>           Obligatorio (Git repo)
  -Configuracion <archivo>    Obligatorio al iniciar
  -Log <archivo>              Default: ./audit.log (se crea si no existe)
  -Kill                       Detiene el demonio del repo
  -Help                       Ayuda rápida (para extendida: Get-Help -Detailed ./ejercicio4.ps1)

patterns.conf (ejemplos):
  # comentarios
  password=
  regex:\bAKIA[0-9A-Z]{16}\b

"@ | Write-Host
}
if ($Help) { Show-Usage; return }

# ======== Utilidad de paths ========
function Resolve-ExistingPath {
    param([Parameter(Mandatory)][string]$Path)
    try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path }
    catch { throw "Ruta inválida o inaccesible: $Path" }
}

function Get-AbsoluteFilePath {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Directorio inválido: $dir"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    }
    (Resolve-Path -LiteralPath $Path).Path
}

# ======== Log ========
function Write-Log {
    param([Parameter(Mandatory)][string]$Message,[Parameter(Mandatory)][string]$LogFile)
    $ts = Get-Date -Format "[yyyy-MM-dd HH:mm:ss]"
    Add-Content -LiteralPath $LogFile -Value "$ts $Message"
}

# ======== Hash ========
function Get-MD5Hex {
    param([Parameter(Mandatory)][string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString("x2") })
}

# ======== Git runner ========
function Invoke-GitCompat {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$LogFile
    )
    $cmdArgs = @('-C', $RepoPath) + $GitArgs
    $out = & git @cmdArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $LogFile) {
        Write-Log -Message ("git {0} -> Exit {1} | ERR: {2}" -f ($cmdArgs -join ' '), $code, (($out -join "`n").Trim())) -LogFile $LogFile
    }
    [pscustomobject]@{ ExitCode = $code; Output = [string]($out -join "`n") }
}

function Get-CommitHashFromText([string]$text) {
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line.Trim()
        if ($l -match '^[0-9a-f]{40}$') { return $l }
    }
    return $null
}

# ======== Patterns / files ========
function Read-ValidPatterns {
    param([Parameter(Mandatory)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Archivo de configuración no encontrado: $ConfigPath"
    }
    $lines = (Get-Content -LiteralPath $ConfigPath -Raw) -split "`n" | ForEach-Object { $_ -replace "`r","" }
    $valid = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith("#")) { continue }
        $valid += $line
    }
    if ($valid.Count -eq 0) { throw "Advertencia: $ConfigPath no contiene patrones válidos." }
    ,$valid
}

function Test-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
        try {
            $buf = New-Object byte[] 8192
            $read = $fs.Read($buf,0,$buf.Length)
            for ($i=0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { return $false } }
            $true
        } finally { $fs.Dispose() }
    } catch { $false }
}

function Test-FileForPatterns {
    param([Parameter(Mandatory)][string]$FullPath,[Parameter(Mandatory)][string[]]$Patterns)
    $alerts = @()
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return ,$alerts }
    if (-not (Test-TextFile -Path $FullPath)) { return ,$alerts }
    $content = Get-Content -LiteralPath $FullPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return ,$alerts }
    foreach ($p in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p.StartsWith('regex:')) {
            $rx = $p.Substring(6)
            if ($content -match $rx) { $alerts += "regex '$rx'" }
        } else {
            if ($content.Contains($p)) { $alerts += "'$p'" }
        }
    }
    ,$alerts
}

# ======== Stop daemon ========
function Stop-Daemon {
    param([Parameter(Mandatory)][string]$PidFile,[Parameter(Mandatory)][string]$LogFile,[string]$RepoPath)
    if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
        $raw = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue) -join ""
        $SavedPid = ([regex]::Match($raw,'\d+')).Value
        if ($SavedPid) {
            $proc = Get-Process -Id ([int]$SavedPid) -ErrorAction SilentlyContinue
            if ($proc) {
                try {
                    Stop-Process -Id ([int]$SavedPid) -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
                    Write-Log -Message "Se detuvo el monitoreo del repositorio: $RepoPath" -LogFile $LogFile
                    return $true
                } catch {
                    Write-Warning ("No se pudo detener el proceso {0}: {1}" -f $SavedPid, $_.Exception.Message)
                    return $false
                }
            } else {
                Write-Host "No se encontró un proceso demonio en ejecución para este repositorio."
                Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
                return $false
            }
        } else {
            Write-Host "PID inválido en $PidFile"
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
            return $false
        }
    } else {
        Write-Host "No se encontró un proceso demonio en ejecución para este repositorio."
        return $false
    }
}

# ======== Preparación de rutas y pidfile ========
try {
    $Repo = Resolve-ExistingPath -Path $Repo
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$repoHash = Get-MD5Hex -Text $Repo
$PidFile  = Join-Path -Path (Get-Location) -ChildPath ("audit_daemon_{0}.pid" -f $repoHash)

# ======== Modo Daemon (loop) ========
if ($RunDaemon) {
    try {
        $Log = Get-AbsoluteFilePath -Path $Log
        $Configuracion = Resolve-ExistingPath -Path $Configuracion
        $patterns = Read-ValidPatterns -ConfigPath $Configuracion

        # HEAD inicial
        $head = Invoke-GitCompat -RepoPath $Repo -GitArgs @('rev-parse','HEAD')
        $last = Get-CommitHashFromText $head.Output

        if ($null -eq $last) {
            Write-Log -Message "Repositorio $Repo vacío, esperando primer commit..." -LogFile $Log
        } else {
            Write-Log -Message "Se inició el monitoreo del repositorio: $Repo" -LogFile $Log
        }

        while ($true) {
            $res     = Invoke-GitCompat -RepoPath $Repo -GitArgs @('rev-parse','HEAD')
            $current = Get-CommitHashFromText $res.Output

            if ($res.ExitCode -ne 0 -or $null -eq $current) {
                Start-Sleep -Seconds $SleepSeconds
                continue
            }

            if ($current -ne $last) {
                $df = Invoke-GitCompat -RepoPath $Repo -GitArgs @('diff-tree','--no-commit-id','--name-only','-r','-z','--diff-filter=ACMR',$current)
                if ($df.ExitCode -eq 0) {
                    $files = ($df.Output -split "`0") | Where-Object { $_ }
                    foreach ($rel in $files) {
                        # Usar diff con --unified=0 para obtener SOLO las líneas agregadas
                        $diff = Invoke-GitCompat -RepoPath $Repo -GitArgs @('diff',$last,$current,'--unified=0','--',$rel)
                        if ($diff.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($diff.Output)) { continue }

                        # Solo mirar líneas que empiecen con '+'
                        $added = ($diff.Output -split "`n") | Where-Object { $_ -like '+*' -and $_ -notlike '+++*' }

                        foreach ($line in $added) {
                            foreach ($p in $patterns) {
                                if ($p.StartsWith('regex:')) {
                                    $rx = $p.Substring(6)
                                    if ($line -match $rx) {
                                        Write-Log -Message ("El demonio que monitorea $Repo detectó coincidencia de patrón regex '{0}' en el archivo '{1}'." -f $rx, $rel) -LogFile $Log
                                    }
                                } else {
                                    if ($line.Contains($p)) {
                                        Write-Log -Message ("El demonio que monitorea $Repo detectó coincidencia de patrón '{0}' en el archivo '{1}'." -f $p, $rel) -LogFile $Log
                                    }
                                }
                            }
                        }
                    }

                }
                $last = $current
            }

            Start-Sleep -Seconds $SleepSeconds
        }
    } catch {
        try { Write-Log -Message ("Error en daemon para ${Repo}: {0}" -f $_.Exception.Message) -LogFile $Log } catch {}
        exit 2
    }
    return
}

# ======== Iniciar / Detener ========
try {
    if ($Kill) {
        try { $Log = Get-AbsoluteFilePath -Path $Log } catch { $Log = "./audit.log" }
        Stop-Daemon -PidFile $PidFile -LogFile $Log -RepoPath $Repo | Out-Null
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git') -PathType Container)) {
        throw "'$Repo' no es un repositorio Git válido (no existe .git)."
    }

    if (-not $Configuracion) { throw "Falta el parámetro -Configuracion para iniciar el daemon." }

    $Configuracion = Resolve-ExistingPath -Path $Configuracion
    $Log = Get-AbsoluteFilePath -Path $Log

    if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
        $raw = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue) -join ""
        $SavedPid = ([regex]::Match($raw,'\d+')).Value
        if ($SavedPid -and (Get-Process -Id ([int]$SavedPid) -ErrorAction SilentlyContinue)) {
            throw "Ya existe un demonio en ejecución (PID: $SavedPid) para este repositorio."
        } else {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Iniciando el demonio en segundo plano para: $Repo (sleep=${SleepSeconds}s)"

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

    function ConvertTo-SingleQuotedString([string]$s) {
        return "'" + ($s -replace "'", "''") + "'"
    }

    $cmd = @(
        "&", (ConvertTo-SingleQuotedString $scriptPath),
        "-RunDaemon",
        "-Repo",           (ConvertTo-SingleQuotedString $Repo),
        "-Configuracion",  (ConvertTo-SingleQuotedString $Configuracion),
        "-Log",            (ConvertTo-SingleQuotedString $Log)
    ) -join " "

    $pwshPath = (Get-Process -Id $PID).Path
    $argLine  = "-NoLogo -NoProfile -Command $cmd"

    $proc = Start-Process -FilePath $pwshPath -ArgumentList $argLine -PassThru

    ($proc.Id).ToString() | Set-Content -LiteralPath $PidFile
    Write-Host "Demonio iniciado. PID: $($proc.Id)"
    Write-Host "Log: $Log"
    return

} catch {
    Write-Error $_.Exception.Message
    exit 1
}