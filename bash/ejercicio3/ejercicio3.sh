#!/bin/bash

# Uso:
#   ./contar_eventos.sh -d /ruta/a/logs -p "usb,invalid"

# --- 1. Parseo de parámetros ---
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

# --- 2. Validar parámetros obligatorios ---
if [[ -z "$DIR" || -z "$PALABRAS" ]]; then
  echo "Error: Faltan parámetros. Uso: $0 -d <directorio o archivo .log> -p <palabras>"
  exit 1
fi

# --- 3. Validar que las palabras no estén vacías ni sean solo espacios ---
if [[ -z "${PALABRAS// /}" ]]; then
    echo "Error: El parámetro -p/--palabras no puede estar vacío ni ser solo espacios."
    exit 1
fi

# --- 4. Validar palabras separadas por coma ---
if [[ "$PALABRAS" != *","* && "$PALABRAS" != *"," ]]; then
  if [[ "$PALABRAS" == *" "* ]]; then
    echo "Error: Las palabras clave deben ir separadas por coma. Ej: usb,invalid"
    exit 1
  fi
fi

# --- 5. Validar directorio/archivo ---
if [[ -d "$DIR" ]]; then
    # Es un directorio
    FILES=( "$DIR"/*.log )
    NUM_FILES=${#FILES[@]}
    
    if [[ $NUM_FILES -eq 0 ]]; then
        echo "Error: No se encontraron archivos .log en el directorio $DIR"
        exit 1
    elif [[ $NUM_FILES -gt 1 ]]; then
        echo "Error: Hay más de un archivo .log en el directorio $DIR. No se puede procesar."
        exit 1
    fi
    FILES="${FILES[0]}"  # Solo un archivo, lo procesamos
elif [[ -f "$DIR" ]]; then
    # Es un archivo. Comprobar extensión .log
    if [[ "$DIR" != *.log ]]; then
        echo "Error: El archivo especificado no tiene extensión .log"
        exit 1
    fi
    FILES="$DIR"
else
    echo "Error: No existe el directorio o archivo especificado: $DIR"
    exit 1
fi

# --- 6. Convertir palabras clave a minúsculas para búsqueda case-insensitive ---
KEYWORDS=$(echo "$PALABRAS" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')

# --- 7. Procesar con awk ---
awk -v words="$KEYWORDS" '
BEGIN {
    n=split(words, keys, " ");
    for (i=1; i<=n; i++) {
        counts[keys[i]]=0;
    }
}
{
    line=tolower($0);
    for (i=1; i<=n; i++) {
        if (index(line, keys[i])) {
            counts[keys[i]]++;
        }
    }
}
END {
    printf "Conteo por palabra:\n"
    for (i=1; i<=n; i++) {
        printf "%s: %d\n", keys[i], counts[keys[i]];
    }
}
' "$FILES"


