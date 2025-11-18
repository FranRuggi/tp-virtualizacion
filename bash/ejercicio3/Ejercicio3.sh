#!/bin/bash

# Uso:
#   ./contar_eventos.sh -d /ruta/a/logs -p "usb,invalid"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directorio)
      DIR="$2"
      shift 2
      ;;
    -p|--palabras)
      PALABRAS="$2"
      shift 2
      ;;
    *)
      echo "Uso: $0 -d <directorio o archivo .log> -p <palabras separadas por coma>"
      exit 1
      ;;
  esac
done

if [[ -z "$DIR" || -z "$PALABRAS" ]]; then
  echo "Error: Faltan parámetros. Uso: $0 -d <directorio o archivo .log> -p <palabras>"
  exit 1
fi

if [[ -z "${PALABRAS// /}" ]]; then
    echo "Error: El parámetro -p/--palabras no puede estar vacío ni ser solo espacios."
    exit 1
fi

if [[ "$PALABRAS" != *","* && "$PALABRAS" != *"," ]]; then
  if [[ "$PALABRAS" == *" "* ]]; then
    echo "Error: Las palabras clave deben ir separadas por coma. Ej: usb,invalid"
    exit 1
  fi
fi

if [[ -d "$DIR" ]]; then
    FILES=( "$DIR"/*.log )
    NUM_FILES=${#FILES[@]}
    
    if [[ $NUM_FILES -eq 0 ]]; then
        echo "Error: No se encontraron archivos .log en el directorio $DIR"
        exit 1
    elif [[ $NUM_FILES -gt 1 ]]; then
        echo "Error: Hay más de un archivo .log en el directorio $DIR. No se puede procesar."
        exit 1
    fi
    FILES="${FILES[0]}"
elif [[ -f "$DIR" ]]; then
    if [[ "$DIR" != *.log ]]; then
        echo "Error: El archivo especificado no tiene extensión .log"
        exit 1
    fi
    FILES="$DIR"
else
    echo "Error: No existe el directorio o archivo especificado: $DIR"
    exit 1
fi

# Convertir palabras a minúsculas y a espacios (awk las splittea)
KEYWORDS=$(echo "$PALABRAS" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')

# AWK actualizado: usa gsub para contar todas las ocurrencias por línea
awk -v words="$KEYWORDS" '
# Función para escapar metacaracteres de regex en la palabra
function escape_regex(s,   esc) {
    esc = s
    # escapamos caracteres que tienen significado en regex
    gsub(/[][\.^$*+?(){}|\\\/]/, "\\\\&", esc)
    return esc
}
BEGIN {
    n = split(words, keys, " ")
    for (i=1; i<=n; i++) {
        counts[keys[i]] = 0
        patterns[i] = escape_regex(keys[i])    # patrón escapado
        # Si querés buscar solo palabras completas (no subcadenas), usá:
        # patterns[i] = "(^|[^[:alnum:]_])" escape_regex(keys[i]) "([^[:alnum:]_]|$)"
        # y luego usar gsub(patterns[i], "&", line)
    }
}
{
    line = tolower($0)
    for (i=1; i<=n; i++) {
        # gsub devuelve el número de sustituciones (ocurrencias no solapadas)
        occ = gsub(patterns[i], "&", line)
        counts[keys[i]] += occ
    }
}
END {
    printf "Conteo por palabra:\n"
    for (i=1; i<=n; i++) {
        printf "%s: %d\n", keys[i], counts[keys[i]]
    }
}
' "$FILES"
