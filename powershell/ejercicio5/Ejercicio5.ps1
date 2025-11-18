# GRUPO 2
# RUGGIERO BELLONE, ZOIS ANDRES UZIEL
# ROMBOLÁ FIGUEROA, FACUNDO AGUSTÍN
# RUGGIERI, FRANCO
# CROTTI, TOMÁS BENJAMÍN
# RIVERA MAMANI, VICTOR LEONCIO

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
    $jsonRespuesta = Get-Content $origen -Raw | ConvertFrom-Json
    $datos = $jsonRespuesta.data
    Write-Output "País: $($datos.name.common)"
    Write-Output "Capital: $($datos.capital[0])"
    Write-Output "Región: $($datos.region)"
    Write-Output "Población: $($datos.population)"
    $monedaKey = $datos.currencies.PSObject.Properties.Name
    $nombreMoneda = $datos.currencies.$monedaKey.name
    Write-Output "Moneda: $nombreMoneda"
}
function ConsultarInfoPais {
    Param (
        [string]$pais,
        [int]$ttlMax
    )
    $nomArchivo="$pais.json"
    $rutaCompleta="$rutaDestino/$nomArchivo"
    $tiempoActual = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if( Test-Path "$rutaCompleta" ){
        $datosPais = Get-Content $rutaCompleta | ConvertFrom-Json
        if( $tiempoActual - $datosPais.timestamp  -le $datosPais.ttl ){
            VerInfoPais $rutaCompleta
            return
        }
    }
    try{
        $respuestaApi = Invoke-WebRequest -Uri "https://restcountries.com/v3.1/name/$pais" | Select-Object -ExpandProperty Content | ConvertFrom-Json | Select-Object -First 1
        $jsonFinal = [PSCustomObject]@{
            timestamp = $tiempoActual #el tiempo en el que fue creado para validar con su ttl
            ttl = $ttlMax #el ttl que va a durar la validez del archivo a partir de cuando fue creado
            data = $respuestaApi
        }
        $jsonFinal | ConvertTo-Json -Depth 10 | Out-File $rutaCompleta
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