#!/usr/bin/env pwsh
param(
    [Alias('m')][string] $Matriz,
    [Alias('s')][string] $Separador = '|',
    [Alias('c')][switch] $Camino,
    [switch] $Hub,
    [switch] $Help
)

function Show-Ayuda {
@"

Analiza una red de transporte modelada como matriz de adyacencia.
- Hub: estaciones con mayor grado (peso > 0)
- Camino: recorridos mínimos que visiten todas las estaciones (usa Dijkstra para tramos)

USO:
  ./ejercicio2.ps1 -Matriz <archivo> [-Separador <caracter>] (-Camino | -Hub)
  ./ejercicio2.ps1 -H


"@ | Write-Output
    exit 0
}

if ($Help) { Show-Ayuda }

# ================== Helpers ==================
$EPS = 1e-9
$INF = [double]::PositiveInfinity

function IsNumNonNeg([string]$v) { return ($v -match '^[0-9]+(\.[0-9]+)?$') }
function DblLt([double]$a, [double]$b) { return ($a -lt ($b - $EPS)) }
function DblEq([double]$a, [double]$b) { return ([math]::Abs($a - $b) -lt $EPS) }

function Resolve-File([string]$f) {
    if (-not $f) { return $null }
    $dir = Split-Path -Parent $f; if (-not $dir) { $dir = "." }
    try { $absDir = (Resolve-Path -Path $dir -ErrorAction Stop).Path } catch { return $null }
    return (Join-Path $absDir (Split-Path -Leaf $f))
}

# Split robusto (soporta separador 1 char como ';' o '|', y multicaracter)
function Split-Line([string]$line, [string]$sep) {
    if ([string]::IsNullOrEmpty($sep)) { return @($line) }
    if ($sep -eq '\t') { $sep = "`t" }
    if ($sep.Length -eq 1) { return $line.Split($sep[0]) }
    $rx = [regex]::Escape($sep)
    return [System.Text.RegularExpressions.Regex]::Split($line, $rx)
}

# ================== Validaciones generales ==================
$MFILE = Resolve-File $Matriz
if (-not $MFILE -or -not (Test-Path -LiteralPath $MFILE -PathType Leaf)) { Write-Error "Error: faltó -Matriz o no existe: $Matriz"; exit 1 }
if ($Camino -and $Hub) { Write-Error "Error: -Camino y -Hub son excluyentes."; exit 1 }
if (-not $Camino -and -not $Hub) { Write-Error "Debe elegir -Camino o -Hub (use -H)."; exit 1 }

# ================== Carga y validación de la matriz ==================
$lines = Get-Content -LiteralPath $MFILE | ForEach-Object { $_.TrimEnd("`r") }
if (-not $lines -or $lines.Count -eq 0) { Write-Error "Error: el archivo está vacío."; exit 1 }

$rows = @()
$colsEsperadas = -1
for ($r=0; $r -lt $lines.Count; $r++) {
    $line = $lines[$r]
    if ($line -eq '') { Write-Error "Error: línea vacía en fila $($r+1)"; exit 1 }
    $cells = Split-Line -line $line -sep $Separador
    if ($colsEsperadas -lt 0) { $colsEsperadas = $cells.Count }
    if ($cells.Count -ne $colsEsperadas) { Write-Error "Error: fila $($r+1) tiene $($cells.Count) columnas; se esperaban $colsEsperadas"; exit 2 }
    foreach ($v in $cells) {
        if (-not (IsNumNonNeg $v)) { Write-Error "Error: valor no numérico o negativo en fila $($r+1): '$v'"; exit 3 }
    }
    $rows += ,$cells
}

$N = $rows.Count
if ($N -ne $colsEsperadas) { Write-Error "Error: matriz no es cuadrada (${N}x${colsEsperadas})."; exit 4 }

# Matriz global 2D
$script:MAT = New-Object 'double[,]' $N, $N
for ($i=0; $i -lt $N; $i++) {
    for ($j=0; $j -lt $N; $j++) {
        $script:MAT[$i,$j] = [double]::Parse($rows[$i][$j], [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

# Validar simetría
for ($i=0; $i -lt $N; $i++) {
    for ($j=0; $j -lt $N; $j++) {
        if (-not (DblEq $script:MAT[$i,$j] $script:MAT[$j,$i])) {
            Write-Error "Error: matriz no simétrica en ($i,$j)"
            exit 5
        }
    }
}
Write-Host "OK: matriz ${N}x${N} validada y cargada"

# ================== Dijkstra (usa $script:MAT global) ==================
function Dijkstra([int]$s) {
    $Nloc = $script:MAT.GetLength(0)
    $dist  = New-Object 'double[]' $Nloc
    $vis   = New-Object 'bool[]'   $Nloc
    $parentBest = New-Object 'int[]' $Nloc
    for ($i=0; $i -lt $Nloc; $i++) { $dist[$i] = $INF; $vis[$i]=$false; $parentBest[$i]=-1 }
    $dist[$s] = 0.0

    for ($k=0; $k -lt $Nloc; $k++) {
        $u = -1; $best = $INF
        for ($i=0; $i -lt $Nloc; $i++) {
            if (-not $vis[$i] -and (DblLt $dist[$i] $best)) { $u=$i; $best=$dist[$i] }
        }
        if ($u -lt 0) { break }
        $vis[$u] = $true

        for ($v=0; $v -lt $Nloc; $v++) {
            if ($u -eq $v) { continue }
            $w = $script:MAT[$u,$v]
            if ($w -gt 0) {
                $new = $dist[$u] + $w
                if (DblLt $new $dist[$v]) {
                    $dist[$v] = $new
                    $parentBest[$v] = $u
                } elseif (DblEq $new $dist[$v]) {
                    # estable
                }
            }
        }
    }

    return [pscustomobject]@{ dist = $dist; parentBest = $parentBest }
}

function Get-ReconstructedPath([int]$s, [int]$t, [int[]]$parentBest, [double[]]$dist) {
    if ([double]::IsPositiveInfinity($dist[$t])) { return $null }
    $stack = New-Object System.Collections.Generic.List[int]
    $cur = $t
    while ($cur -ne -1) {
        $stack.Add($cur)
        if ($cur -eq $s) { break }
        $cur = $parentBest[$cur]
        if ($cur -eq -1) { return $null }
    }
    $out = @()
    for ($i = $stack.Count-1; $i -ge 0; $i--) { $out += $stack[$i] }
    return ,$out
}

# ================== Precalcular distancias ==================
$script:D = New-Object 'double[,]' $N, $N
for ($s=0; $s -lt $N; $s++) {
    $dj = Dijkstra -s $s
    for ($t=0; $t -lt $N; $t++) { $script:D[$s,$t] = $dj.dist[$t] }
}

# ================== Backtracking ==================
$script:bestCost = $INF
$script:bestOrders = New-Object System.Collections.Generic.List[object]
$script:visit = New-Object 'bool[]' $N
$script:order = New-Object 'int[]'  $N

function BT([int]$k, [double]$cost) {
    if (DblLt $script:bestCost $cost) { return }
    if ($k -eq $N) {
        if (DblLt $cost $script:bestCost) {
            $script:bestCost = $cost
            $script:bestOrders.Clear()
        }
        if (DblEq $cost $script:bestCost) {
            $script:bestOrders.Add(@($script:order))
        }
        return
    }
    for ($v=0; $v -lt $N; $v++) {
        if (-not $script:visit[$v]) {
            $extra = 0.0
            if ($k -gt 0) {
                $prev = $script:order[$k-1]
                $d = $script:D[$prev,$v]
                if ([double]::IsPositiveInfinity($d)) { continue }
                $extra = $d
            }
            $script:visit[$v] = $true
            $script:order[$k] = $v
            BT -k ($k+1) -cost ($cost + $extra)
            $script:visit[$v] = $false
        }
    }
}

# ================== Salida ==================
$dir  = Split-Path -Parent $MFILE
$base = Split-Path -Leaf   $MFILE
$SALIDA = Join-Path $dir ("informe." + $base)

if ($Camino) {
    for ($i=0; $i -lt $N; $i++) { $script:visit[$i] = $false }
    BT -k 0 -cost 0.0

    $outLines = @()
    $outLines += "## Informe de análisis de red de transporte"
    $outLines += "**Recorrido(s) más rápido(s) que visitan todas las estaciones (0..$([int]($N))):**"
    $outLines += "**Costo total mínimo:** $([math]::Round($script:bestCost,4))"
    $outLines += "**Ruta(s) (estaciones 1..$N):**"

    foreach ($ord in $script:bestOrders) {
        $ruta = @()
        for ($i=0; $i -lt $N-1; $i++) {
            $s = $ord[$i]; $t = $ord[$i+1]
            $dj = Dijkstra -s $s
            $path = Get-ReconstructedPath -s $s -t $t -parentBest $dj.parentBest -dist $dj.dist
            if (-not $path) {
                $outLines += "- Advertencia: red no conexa para $($s+1)→$($t+1)"
                continue
            }
            if ($i -eq 0) { $ruta += $path } else { $ruta += $path[1..($path.Count-1)] }
        }
        $pretty = ($ruta | ForEach-Object { $_ + 1 }) -join ' -> '
        $outLines += "- $pretty"
    }

    $outLines | Set-Content -LiteralPath $SALIDA -Encoding UTF8
    Write-Host "Informe escrito en: $SALIDA"
}

if ($Hub) {
    $deg = New-Object 'int[]' $N
    $max = -1
    for ($i=0; $i -lt $N; $i++) {
        $count = 0
        for ($j=0; $j -lt $N; $j++) {
            if ($i -eq $j) { continue }
            if ($script:MAT[$i,$j] -gt 0) { $count++ }
        }
        $deg[$i] = $count
        if ($count -gt $max) { $max = $count }
    }

    $outLines = @()
    $outLines += "## Informe de análisis de red de transporte"
    $outLines += "**Hub(s) de la red** (grado=$max):"
    for ($i=0; $i -lt $N; $i++) {
        if ($deg[$i] -eq $max) { $outLines += "  - Estación $($i+1)" }
    }

    $outLines | Set-Content -LiteralPath $SALIDA -Encoding UTF8
    Write-Host "Informe escrito en: $SALIDA"
}
