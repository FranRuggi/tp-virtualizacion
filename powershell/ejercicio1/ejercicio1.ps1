param(
    [string] $Directorio,
    [string] $Archivo,
    [switch] $Pantalla,
    [switch] $Help
)

# ========== Funciones simples ==========
function Show-Ayuda {
@"

Analiza encuestas de satisfacción de clientes a partir de archivos de texto (.txt).
Cada línea: ID|FECHA(yyyy-mm-dd hh:mm:ss)|CANAL|TIEMPO|NOTA

Calcula:
  • Promedio de tiempo de respuesta por fecha y canal
  • Promedio de nota de satisfacción por fecha y canal

USO:
  .\ej1.ps1 -Directorio <directorio> [-Archivo <salida.json> | -Pantalla]
  .\ej1.ps1 -Help

Parámetros:
  -Directorio  Directorio con archivos de encuestas (obligatorio).
  -Archivo     Archivo JSON de salida (excluyente con -Pantalla).
  -Pantalla    Muestra la salida por pantalla (excluyente con -Archivo).
  -Help        Muestra esta ayuda.

"@ | Write-Output
    exit 0
}

function Resolve-Dir([string]$d) {
    if (-not $d) { return $null }
    try {
        # Si existe, devolvemos absoluto; si no, fallamos
        $p = Resolve-Path -Path $d -ErrorAction Stop
        return $p.Path
    } catch {
        return $null
    }
}

function Resolve-File([string]$f) {
    if (-not $f) { return $null }
    # Convertir a ruta absoluta aunque no exista el archivo
    $dir = Split-Path -Parent $f
    if (-not $dir) { $dir = "." }
    $absDir = Resolve-Dir $dir
    if (-not $absDir) { return $null }
    $base = Split-Path -Leaf $f
    return (Join-Path $absDir $base)
}

# ========== Parser / ayuda ==========
if ($Help) { Show-Ayuda }

# ========== Validaciones ==========
$DIR = Resolve-Dir $Directorio
if (-not $DIR) {
    Write-Error "Error: faltó -Directorio o no existe: $Directorio"
    exit 1
}

if ($Archivo -and $Pantalla) {
    Write-Error "Error: -Archivo y -Pantalla son excluyentes."
    exit 1
}

# Si no dieron ni -Archivo ni -Pantalla → pedimos ruta
if (-not $Archivo -and -not $Pantalla) {
    $Archivo = Read-Host "Ingrese ruta del archivo de salida"
}

$OUTFILE = $null
if ($Archivo) {
    $OUTFILE = Resolve-File $Archivo
    if (-not $OUTFILE) {
        Write-Error "Error: ruta inválida de salida."
        exit 1
    }
    if (Test-Path -LiteralPath $OUTFILE) {
        Write-Error "Error: el archivo de salida ya existe: $OUTFILE"
        exit 1
    }
    $DEST_DIR = Split-Path -Parent $OUTFILE
    if (-not (Test-Path -LiteralPath $DEST_DIR)) {
        Write-Error "Error: no existe el directorio destino: $DEST_DIR"
        exit 1
    }
    # Chequeo simple de escritura creando un archivo temporal
    try {
        $tmp = Join-Path $DEST_DIR ([System.IO.Path]::GetRandomFileName())
        $fs = [System.IO.File]::OpenWrite($tmp)
        $fs.Close()
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    } catch {
        Write-Error "Error: sin permisos de escritura en: $DEST_DIR"
        exit 1
    }
}

# ========== Procesamiento ==========
# Estructura de salida deseada:
# {
#   "2025-05-01": {
#       "Web":   { "tiempo_respuesta_promedio": X, "nota_satisfaccion_promedio": Y },
#       "Phone": { ... }
#   },
#   ...
# }

# Agregado por clave "fecha|canal"
$agg = @{}  # key -> @{TiempoSum=..; SatisSum=..; Count=..}

# Buscar .txt en el directorio
$files = Get-ChildItem -LiteralPath $DIR -Filter *.txt -File -ErrorAction Stop
if (-not $files -or $files.Count -eq 0) {
    Write-Error "Error: no se encontraron archivos .txt en: $DIR"
    exit 1
}

foreach ($f in $files) {
    foreach ($line in Get-Content -LiteralPath $f.FullName) {
        if (-not $line) { continue }
        $parts = $line -split '\|'
        if ($parts.Count -lt 5) { continue } # línea inválida

        # Extraer campos
        $fechaHora = $parts[1].Trim()
        $canal     = $parts[2].Trim()

        # fecha solo (yyyy-mm-dd)
        $fecha = ($fechaHora -split '\s+')[0]

        # numéricos (si falla, saltamos la línea)
        [double]$tiempo = 0
        [double]$nota   = 0
        if (-not [double]::TryParse($parts[3].Trim(), [ref]$tiempo)) { continue }
        if (-not [double]::TryParse($parts[4].Trim(), [ref]$nota))   { continue }

        $key = "$fecha|$canal"
        if (-not $agg.ContainsKey($key)) {
            $agg[$key] = @{
                TiempoSum = 0.0
                SatisSum  = 0.0
                Count     = 0
            }
        }
        $agg[$key].TiempoSum += $tiempo
        $agg[$key].SatisSum  += $nota
        $agg[$key].Count     += 1
    }
}

# Construir estructura final { fecha: { canal: { promedios } } }
$out = @{}
foreach ($k in $agg.Keys) {
    $fecha, $canal = $k -split '\|', 2
    $sumT = $agg[$k].TiempoSum
    $sumS = $agg[$k].SatisSum
    $cnt  = [double]$agg[$k].Count

    $promT = [math]::Round($sumT / $cnt, 2)
    $promS = [math]::Round($sumS / $cnt, 2)

    if (-not $out.ContainsKey($fecha)) {
        $out[$fecha] = @{}
    }
    $out[$fecha][$canal] = [ordered]@{
        tiempo_respuesta_promedio   = $promT
        nota_satisfaccion_promedio  = $promS
    }
}

# Convertir a JSON
# Nota: -Depth alto para anidar correctamente
$json = $out | ConvertTo-Json -Depth 8

# ========== Salida ==========
if ($Pantalla) {
    $json | Write-Output
} else {
    $json | Set-Content -LiteralPath $OUTFILE -Encoding UTF8
    Write-Host "JSON generado en $OUTFILE"
}
