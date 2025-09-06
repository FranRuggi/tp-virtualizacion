#!/bin/bash

# ====== Parser de opciones ======
DIR=""
ARCHIVO=""
PANTALLA=0  
AYUDA=0

# --- Funciones simples ---

function abspath_dir() {
  # Resuelve .. de un DIRECTORIO existente
  local d="$1"
  case "$d" in
    /*|~*) printf '%s\n' "$d" ;;
    *)     ( cd "$d" 2>/dev/null && pwd ) || return 1 ;;
  esac
}

function abspath_file() {
  # Convierte RUTA DE ARCHIVO (que puede no existir) a absoluta
  # resolviendo el directorio padre
  local f="$1"
  local dir base
  dir=$(dirname -- "$f")
  base=$(basename -- "$f")
  dir=$(abspath_dir "$dir") || return 1
  printf '%s/%s\n' "$dir" "$base"
}
function ayuda() {
  cat <<'EOF'

Analiza encuestas de satisfacción de clientes a partir de archivos de texto.
Cada archivo tiene líneas con formato:
  ID_ENCUESTA|FECHA|CANAL|TIEMPO_RESPUESTA|NOTA_SATISFACCION

El script calcula:
  • Promedio de tiempo de respuesta por fecha y canal
  • Promedio de nota de satisfacción por fecha y canal

REQUISITOS:
  • Tener instalado el paquete "jq" para procesar la salida en JSON.
  • Los archivos de entrada se leen desde un directorio dado.

USO:
  $0 -d|--directorio <directorio>   [-a|--archivo <archivo> | -p|--pantalla]
  $0 -h|--help

PARÁMETROS:
  -d, --directorio   Directorio con archivos de encuestas (obligatorio).
  -a, --archivo      Archivo JSON de salida (excluyente con -p).
  -p, --pantalla     Muestra la salida por pantalla (excluyente con -a).
  -h, --help         Muestra esta ayuda (ignora el resto de parámetros).

EJEMPLOS:
  # Procesar encuestas y ver resultado por pantalla
  $0 --directorio ./datos --pantalla

  # Procesar encuestas y guardar en un JSON
  $0 -d ./datos -a salida.json

EOF
  exit 0
}



parsed=$(getopt -o d:a:ph -l directorio:,archivo:,pantalla,help -- "$@") || {
  echo "Uso: $0 -d <directorio> [-a <archivo> | -p]
Para mas detalles sobre el script usar -h | --help"; exit 2; }
eval set -- "$parsed"

while true; do
  case "$1" in
    -d|--directorio) DIR="$(abspath_dir "$2")"; shift 2 ;;
    -a|--archivo)    ARCHIVO="$(abspath_file "$2")"; shift 2 ;;
    -p|--pantalla)   PANTALLA=1; shift ;;
    -h|--help)       ayuda ;;
    --)              shift; break ;;
    *)               echo "Opción inválida: $1" >&2; exit 2 ;;
  esac
done

# ====== Validaciones ======
# Directorio obligatorio y existente
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "Error: faltó -d/--directorio o no existe: $DIR" >&2
  exit 1
fi

# Exclusión -a / -p
if [ -n "$ARCHIVO" ] && [ "$PANTALLA" -eq 1 ]; then
  echo "Error: -a/--archivo y -p/--pantalla son excluyentes." >&2
  exit 1
fi

# Si no dieron ni -a ni -p → pedimos archivo
if [ -z "$ARCHIVO" ] && [ "$PANTALLA" -eq 0 ]; then
  read -p "Ingrese ruta del archivo de salida: " ARCHIVO
  ARCHIVO="$(abspath_file "$ARCHIVO")" || { echo "Error: ruta inválida"; exit 1; }
fi

# Si hay archivo, no debe existir y el directorio destino debe ser escribible
if [ -n "$ARCHIVO" ]; then
  if [ -e "$ARCHIVO" ]; then
    echo "Error: el archivo de salida ya existe: $ARCHIVO" >&2
    exit 1
  fi
  DEST_DIR=$(dirname -- "$ARCHIVO")
  if [ ! -d "$DEST_DIR" ]; then
    echo "Error: no existe el directorio destino: $DEST_DIR" >&2
    exit 1
  fi
  if [ ! -w "$DEST_DIR" ]; then
    echo "Error: sin permisos de escritura en: $DEST_DIR" >&2
    exit 1
  fi
fi

# ====== Procesamiento (awk -> líneas | jq -> JSON) ======
# Formato esperado del .txt: ID|FECHA(yyyy-mm-dd hh:mm:ss)|CANAL|TIEMPO|min|NOTA(1..5)
# Se agrupa por fecha (solo día) + canal y se promedian tiempo y nota.

function generar_json() {
  awk -F"|" '
  {
      split($2, fecha_hora, " ");
      fecha = fecha_hora[1];
      canal = $3;

      key = fecha "|" canal;
      tiempo[key] += $4;
      satis[key]  += $5;
      cuenta[key]++
  }
  END {
      for (k in cuenta) {
          split(k, arr, "|");
          fecha = arr[1]; 
          canal = arr[2];
          printf "%s|%s|%.2f|%.2f\n", fecha, canal, tiempo[k]/cuenta[k], satis[k]/cuenta[k]
      }
  }' "$DIR"/*.txt |
  jq -R -s '
    split("\n")[:-1]                              
    | map(split("|"))                             
    | reduce .[] as $it ({}; 
        .[$it[0]] += {
          ($it[1]): {
            tiempo_respuesta_promedio: ($it[2]|tonumber),
            nota_satisfaccion_promedio: ($it[3]|tonumber)
          }
        }
      )
  '
}

# ====== Salida ======
if [ "$PANTALLA" -eq 1 ]; then
  generar_json
else
  generar_json > "$ARCHIVO"
  echo "JSON generado en $ARCHIVO"
fi
