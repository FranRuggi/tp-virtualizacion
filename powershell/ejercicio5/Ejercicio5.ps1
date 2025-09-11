<#
.SYNOPSIS
   Este comando obtendra informacion de paises mediante una API publica.

.DESCRIPTION
   Se utilizara la URL https://restcountries.com/v3.1 para obtener los datos, se guardaran en un arhcivo con el nombre del pais y extencion .json,
   los datos mas relevantes seran mostrados por pantalla de inmediato, el mencionado archivo se usara de cache, para una vez obtenido informcacion
   de un pais, se pueda usar esa informacion partiendo del archivo sin necesidad de usar la API.

.PARAMETER nombre
   Lista de países a consultar. Obligatorio.

.PARAMETER ttl
   Tiempo de valido para la informacion en el archivo. Obligatorio y debe ser positivo.

.EXAMPLE
   ./ConsultarInfoPais.ps1 -nombre Argentina Brasil -ttl 3600

   Consulta los países Argentina y Brasil y guarda sus datos en /tmp, si a partir de que se creo el archivo no supera el tiempo que indica
   el ttl, se usara la informacion de ese archivo, caso contrario se consultara a la API.

.NOTES
   Autor: Víctor
   Fecha: 2025-09-11
#>
Param(
    [Parameter(Mandatory=$True)] [string[]]$nombre,
    [Parameter(Mandatory=$True)] [int]$ttl
)
if ($ttl -lt 0) {
    Write-Error "El parámetro -ttl debe ser un entero positivo."
    exit 1
}
#Defino la ruta global donde almacena la cache de registros, las consideraciones indican que debe ir en /tmp
$rutaDestino="."#"/tmp"
function VerInfoPais{
    Param(
        [string]$origen
    )
    $datos = Get-Content $origen -Raw | ConvertFrom-Json
    Write-Output "País: $($datos.name.common)"
    Write-Output "Capital: $($datos.capital[0])"
    Write-Output "Región: $($datos.region)"
    Write-Output "Población: $($datos.population)"
    Write-Output "Moneda: $($datos.currencies.($datos.currencies.PSObject.Properties.Name).name)"
}
function ConsultarInfoPais {
    Param (
        [string]$pais,
        [int]$ttlMax
    )
    $nomArchivo="$pais.json"
    $rutaCompleta="$rutaDestino/$nomArchivo"
    if( Test-Path "$rutaCompleta" ){
        $tiempoActual = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $tiempoUltMod = ([System.DateTimeOffset](Get-Item $rutaCompleta).LastWriteTime).ToUnixTimeSeconds()
        if( $tiempoActual - $tiempoUltMod -le $ttlMax ){
            VerInfoPais $rutaCompleta
            return
        }
    }
    try{
        $(Invoke-WebRequest -Uri "https://restcountries.com/v3.1/name/$pais").Content | ConvertFrom-Json | Select-Object -First 1 | ConvertTo-Json -Depth 10 | Out-File -FilePath $rutaCompleta
        VerInfoPais $rutaCompleta
    }
    catch{
        Write-Output "Ocurrio un error al obtener la informacion del pais: $pais"
    }

}
foreach($pais in $nombre){
    ConsultarInfoPais $pais $ttl
    Write-Output ""
}