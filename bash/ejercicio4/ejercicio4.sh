#!/bin/bash

# --- Funciones auxiliares ---

# Obtiene la ruta del repositorio
REPO_PATH=""
# Obtiene la ruta del archivo de configuración
CONFIG_PATH=""
# PID del proceso en ejecución
PID_FILE=""
# Ruta del archivo de log
LOG_FILE=""

# Función para mostrar el uso del script
function show_help() {
    echo "Uso: $0 -r <repositorio> -c <configuracion> [-l <log>] [-k]"
    echo ""
    echo "Parámetros:"
    echo "  -r, --repo          Ruta del repositorio Git a monitorear."
    echo "  -c, --configuracion Ruta del archivo de configuración que contiene la lista de patrones a buscar."
    echo "  -l, --log           Ruta del archivo de logs que contiene la lista de eventos identificados. (Opcional, por defecto es ./audit.log)"
    echo "  -k, --kill          Detiene el demonio. Solo se usa junto con -r / --repo y -c / --configuracion"
    echo ""
    echo "Ejemplo:"
    echo "  $0 -r /home/user/myrepo -c ./patrones.conf"
    echo "  $0 -r /home/user/myrepo -c ./patrones.conf -k"
    exit 1
}

# Función para registrar un mensaje en el log
function log_message() {
    local message=$1
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') $message" >> "$LOG_FILE"
}

# Función para escanear el repositorio
function scan_repo() {
    local patterns_file=$1
    local repo=$2

    # Verifica si el archivo de patrones existe
    if [[ ! -f "$patterns_file" ]]; then
        log_message "Error: Archivo de configuración no encontrado: $patterns_file"
        exit 1
    fi

    log_message "Iniciando escaneo del repositorio: $repo"
    local patterns=$(grep -v '^\s*#\|^$' "$patterns_file")

    # Mantiene un registro de los commits ya escaneados para evitar duplicados
    local scanned_commits_file="/tmp/audit_scanned_commits_$(echo "$repo" | md5sum | awk '{print $1}')"
    if [[ ! -f "$scanned_commits_file" ]]; then
        touch "$scanned_commits_file"
    fi

    # Bucle principal para monitorear cambios
    while true; do
        current_commit=$(git -C "$repo" rev-parse HEAD)
        
        # Si el commit actual es diferente al último escaneado, hay cambios
        if ! grep -q "$current_commit" "$scanned_commits_file"; then
            
            # Obtiene la lista de archivos modificados en el último commit
            changed_files=$(git -C "$repo" diff-tree --no-commit-id --name-only -r "$current_commit")
            
            log_message "Nuevo commit detectado en el repositorio. Hash: $current_commit"
            
            # Escanea cada archivo modificado
            for file in $changed_files; do
                local full_path="$repo/$file"
                if [[ -f "$full_path" ]]; then
                    # Busca cada patrón en el archivo
                    for pattern in $patterns; do
                        # Maneja la búsqueda con regex
                        if [[ "$pattern" =~ ^regex: ]]; then
                            local regex_pattern=$(echo "$pattern" | sed 's/^regex://')
                            if grep -E -q "$regex_pattern" "$full_path"; then
                                log_message "Alerta: Patrón regex '$regex_pattern' encontrado en el archivo '$file'."
                            fi
                        # Maneja la búsqueda de palabras clave
                        else
                            if grep -q "$pattern" "$full_path"; then
                                log_message "Alerta: Patrón '$pattern' encontrado en el archivo '$file'."
                            fi
                        fi
                    done
                fi
            done
            # Registra el commit como escaneado
            echo "$current_commit" >> "$scanned_commits_file"
        fi
        
        # Espera un tiempo antes de volver a verificar (por ejemplo, 10 segundos)
        sleep 10
    done
}

# --- Lógica principal del script ---
KILL_FLAG=false

# Analiza los argumentos de la línea de comandos
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|--repo)
            REPO_PATH="$2"
            shift 2
            ;;
        -c|--configuracion)
            CONFIG_PATH="$2"
            shift 2
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        -k|--kill)
            KILL_FLAG=true
            shift 1
            ;;
        *)
            show_help
            ;;
    esac
done

# Asigna la ruta por defecto al log si no se especifica
if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="./audit.log"
fi

# El archivo PID del proceso se basa en la ruta del repositorio
PID_FILE="/tmp/audit_daemon_$(echo "$REPO_PATH" | md5sum | awk '{print $1}').pid"

# --- Validaciones y ejecución ---

# Validación del flag -k
if [[ "$KILL_FLAG" == true ]]; then
    if [[ -z "$REPO_PATH" ]]; then
        echo "Error: El flag -k requiere la ruta del repositorio (-r)."
        show_help
    fi
    
    # Verifica si existe un proceso para detener
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            echo "Deteniendo el proceso demonio con PID: $PID"
            kill "$PID"
            rm "$PID_FILE"
            log_message "Demonio detenido."
            exit 0
        else
            echo "No se encontró un proceso demonio en ejecución para este repositorio."
            rm "$PID_FILE" # Limpia el archivo PID si el proceso ya no existe
            exit 1
        fi
    else
        echo "No se encontró un proceso demonio en ejecución para este repositorio."
        exit 1
    fi
fi

# Validación para iniciar el demonio
if [[ -z "$REPO_PATH" || -z "$CONFIG_PATH" ]]; then
    echo "Error: Se requieren los parámetros -r (repositorio) y -c (configuración)."
    show_help
fi

# Validación del repositorio
if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "Error: La ruta '$REPO_PATH' no es un repositorio Git válido."
    exit 1
fi

# Validación de la unicidad del proceso
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null; then
        echo "Ya existe un proceso demonio en ejecución (PID: $PID) para este repositorio."
        exit 1
    else
        # Limpia el archivo PID si el proceso no está activo
        rm "$PID_FILE"
    fi
fi

# --- Iniciar el demonio ---
echo "Iniciando el demonio en segundo plano para el repositorio: $REPO_PATH"
# Ejecuta la función scan_repo en segundo plano y redirige la salida
scan_repo "$CONFIG_PATH" "$REPO_PATH" &
# Guarda el PID del proceso en un archivo
echo $! > "$PID_FILE"
echo "Demonio iniciado. PID: $!"
echo "Revisa el archivo de log para las alertas: $LOG_FILE"
exit 0