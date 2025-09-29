#!/usr/bin/env pwsh
param(
    [Alias("d")]
    [Parameter(Mandatory=$true)]
    [string]$Directorio,

    [Alias("p")]
    [Parameter(Mandatory=$true)]
    [string]$Palabras,

    [switch]$Recursivo,
    [switch]$Boundaries,     # contar palabra exacta con \b...\b
    [switch]$CaseSensitive,  # por defecto es insensible
    [Alias("h")]
    [switch]$Help
)

function Get-HelpText {
@"


Uso:
  .\ejercicio3.ps1 -Directorio <dir | archivo.log> -Palabras <lista separada por coma> [-Recursivo] [-Boundaries] [-CaseSensitive]

Parámetros:
  -Directorio (-d)    Ruta a un directorio o a un archivo .log
  -Palabras  (-p)     Lista separada por coma:  usb,invalid,error  (ignora espacios)
  -Recursivo          Si es directorio, busca .log en subcarpetas
  -Boundaries         Coincidencias por palabra exacta (usa \b... \b)
  -CaseSensitive      Sensible a mayúsculas/minúsculas (por defecto NO)

Ejemplos:
  .\ejercicio3.ps1 -d .\system.log -p "usb,invalid"
  .\ejercicio3.ps1 -d C:\Logs -p "error,timeout" -Recursivo
  .\ejercicio3.ps1 -d ./logs -p "usb" -Boundaries

"@ | Write-Host
}
if ($Help) { Get-HelpText; exit 0 }

# ============ Validación básica ============
if ([string]::IsNullOrWhiteSpace($Directorio) -or [string]::IsNullOrWhiteSpace($Palabras)) {
    Write-Host "Error: Faltan parámetros obligatorios." -ForegroundColor Red
    Show-Help
    exit 1
}

# ============ Normalizar y validar palabras ============
$keywords = @()
foreach ($raw in ($Palabras -split ",")) {
    $k = $raw.Trim()
    if ($k.Length -gt 0) { $keywords += $k }
}
if ($keywords.Count -eq 0) {
    Write-Host "Error: No hay palabras válidas después de separar por coma." -ForegroundColor Red
    exit 1
}

# ============ Resolver ruta y armar lista de archivos ============
$archivos = @()

if (Test-Path -LiteralPath $Directorio -PathType Leaf) {
    if ([IO.Path]::GetExtension($Directorio) -ne ".log") {
        Write-Host "Error: El archivo especificado no tiene extensión .log" -ForegroundColor Red
        exit 1
    }
    $archivos = @((Resolve-Path -LiteralPath $Directorio).Path)
}
elseif (Test-Path -LiteralPath $Directorio -PathType Container) {
    $gciParams = @{
        Path        = $Directorio
        Filter      = "*.log"
        File        = $true
        ErrorAction = "Stop"
    }
    if ($Recursivo) { $gciParams.Recurse = $true }
    $logs = Get-ChildItem @gciParams
    if (-not $logs -or $logs.Count -eq 0) {
        Write-Host "Error: No se encontraron archivos .log en $Directorio" -ForegroundColor Red
        exit 1
    }
    $archivos = $logs.FullName
}
else {
    Write-Host "Error: No existe el directorio/archivo: $Directorio" -ForegroundColor Red
    exit 1
}

# ============ Preparar comparadores ============
# Por defecto, insensible a mayúsculas: normalizamos línea y keywords a minúsculas
$normKeywords = if ($CaseSensitive) { $keywords } else { $keywords | ForEach-Object { $_.ToLowerInvariant() } }

# Si Boundaries, usamos regex escapado; si no, Contains/IndexOf
$regexes = @()
if ($Boundaries) {
    foreach ($k in $keywords) {
        $pat = "\b{0}\b" -f [Regex]::Escape($k)
        $options = if ($CaseSensitive) { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
        $regexes += [Regex]::new($pat, $options)
    }
}

# ============ Contadores ============
$countMap = [ordered]@{}
foreach ($k in $normKeywords) { $countMap[$k] = 0 }

# ============ Procesamiento ============
foreach ($archivo in $archivos) {

    # Leer en bloques para logs grandes
    Get-Content -LiteralPath $archivo -ReadCount 1000 | ForEach-Object {
        foreach ($line in $_) {
            if ($Boundaries) {
                # regex (palabra exacta)
                for ($i=0; $i -lt $regexes.Count; $i++) {
                    if ($regexes[$i].IsMatch($line)) {
                        $countMap[$normKeywords[$i]]++
                    }
                }
            } else {
                # contains simple
                $line2 = if ($CaseSensitive) { $line } else { $line.ToLowerInvariant() }
                foreach ($k in $normKeywords) {
                    if ($line2.Contains($k)) { $countMap[$k]++ }
                }
            }
        }
    }
}

# ============ Salida ============
Write-Host "Conteo por palabra:"
foreach ($k in $countMap.Keys) {
    # si no CaseSensitive, mostramos la palabra original si existe única
    $display = if ($CaseSensitive) { $k } else {
        # buscar el original que matchee (por prolijidad al mostrar)
        $orig = $keywords | Where-Object { $_.ToLowerInvariant() -eq $k } | Select-Object -First 1
        if ($orig) { $orig } else { $k }
    }
    "{0}: {1}" -f $display, $countMap[$k] | Write-Host
}
