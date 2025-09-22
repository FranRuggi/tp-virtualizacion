#!/bin/bash

# --- Función de ayuda ---
function mostrar_ayuda {
  echo "Uso: $0 -d <directorio o archivo .log> -p <palabras separadas por coma>"
  echo
  echo "Parámetros:"
  echo "  -d, --directorio   Ruta al directorio que contiene un único .log o un archivo .log específico"
  echo "  -p, --palabras     Lista de palabras clave separadas por coma (ejemplo: usb,invalid)"
  echo "  -h, --help         Muestra esta ayuda y termina"
  echo
  echo "Ejemplos:"
  echo "  $0 -d /var/logs -p usb,invalid"
  echo "  $0 -d ./system.log -p \"usb,invalid\""
}

# --- 1. Parseo de parámetros ---
if [[ $# -eq 0 ]]; then
  mostrar_ayuda
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      mostrar_ayuda
      exit 0
      ;;
    -d|--directorio)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: Falta argumento para $1"
        exit 1
      fi
      DIR="$2"
      shift 2
      ;;
    -p|--palabras)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: Falta argumento para $1"
        exit 1
      fi
      # Validar que no sean solo espacios
      if [[ -z "${2// /}" ]]; then
        echo "Error: El parámetro -p/--palabras no puede estar vacío ni ser solo espacios."
        exit 1
      fi
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
  echo "Error: Faltan parámetros obligatorios. Uso: $0 -d <directorio o archivo .log> -p <palabras>"
  exit 1
fi

# --- 3. Validar palabras separadas por coma ---
if [[ "$PALABRAS" != *","* && "$PALABRAS" != *"," ]]; then
  if [[ "$PALABRAS" == *" "* ]]; then
    echo "Error: Las palabras clave deben ir separadas por coma. Ej: usb,invalid"
    exit 1
  fi
fi

# --- 4. Validar directorio/archivo ---
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
    FILES="${FILES[0]}"  # Solo un archivo, lo procesamos
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

# --- 5. Convertir palabras clave a minúsculas para búsqueda case-insensitive ---
KEYWORDS=$(echo "$PALABRAS" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')

# --- 6. Procesar con awk ---
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
    for (i=1; i<=n; i++) {
        printf "%s: %d\n", keys[i], counts[keys[i]];
    }
}
' "$FILES"
