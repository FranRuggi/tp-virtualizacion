#!/usr/bin/env pwsh
# GRUPO 2

# RUGGIERO BELLONE, ZOIS ANDRES UZIEL
# ROMBOLÁ FIGUEROA, FACUNDO AGUSTÍN
# RUGGIERI, FRANCO
# CROTTI, TOMÁS BENJAMÍN
# RIVERA MAMANI, VICTOR LEONCIO
param(
    [Alias("d")] [Parameter(Mandatory=$true)] [string]$Directorio,
    [Alias("p")] [Parameter(Mandatory=$true)] [string]$Palabras,
    [switch]$Recursivo,
    [switch]$Boundaries,
    [switch]$CaseSensitive,
    [Alias("h")] [switch]$Help
)

function Get-HelpText {
@"
Uso:
  pwsh ./buscar.ps1 -d ./logs -p "USB,error,fail"

Opciones:
  -Recursivo
  -Boundaries      palabra exacta (\b)
  -CaseSensitive
"@ | Write-Host
}

if ($Help) { Get-HelpText; exit }

# palabras
$keywords = $Palabras -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# archivos
if (Test-Path $Directorio -PathType Leaf) {
    $archivos = @((Resolve-Path $Directorio).Path)
}
else {
    $params = @{ Path = $Directorio; Filter = "*.log"; File = $true }
    if ($Recursivo) { $params.Recurse = $true }
    $archivos = (Get-ChildItem @params).FullName
}

# procesar patrones
$countMap = [ordered]@{}
foreach ($k in $keywords) {

    $pat = if ($Boundaries) {
        "\\b{0}\\b" -f [Regex]::Escape($k)
    } else {
        [Regex]::Escape($k)
    }

    # $matches = Select-String -Path $archivos -AllMatches -Pattern $pat -ErrorAction SilentlyContinue
    # $total = ($matches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
    $resultMatches = Select-String -Path $archivos -AllMatches -Pattern $pat -ErrorAction SilentlyContinue
    $total = ($resultMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum

    $countMap[$k] = $total
}

# salida
Write-Host "`nConteo por palabra:`n"
foreach ($k in $countMap.Keys) {
    Write-Host "$k : $($countMap[$k])"
}
