#!/bin/bash

# ============================
# Demonio de auditoría Git
# ============================

show_help() {
    echo "Uso: $0 -r <repo_dir> -c <config_file> -l <log_file> [-k]"
    echo "  -r | --repo          Ruta del repositorio Git a monitorear"
    echo "  -c | --configuracion Ruta del archivo con patrones"
    echo "  -l | --log           Ruta del archivo de log"
    echo "  -k | --kill          Detener demonio en ejecución"
}

# --- Parámetros ---
REPO_DIR=""
CONFIG_FILE=""
LOG_FILE=""
KILL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--repo)
            REPO_DIR="$2"; shift 2 ;;
        -c|--configuracion)
            CONFIG_FILE="$2"; shift 2 ;;
        -l|--log)
            LOG_FILE="$2"; shift 2 ;;
        -k|--kill)
            KILL=true; shift ;;
        -h|--help)
            show_help; exit 0 ;;
        *)
            echo "Parámetro desconocido: $1"; show_help; exit 1 ;;
    esac
done

# --- Validaciones ---
if [[ -z "$REPO_DIR" ]]; then
    echo "Error: se debe especificar -r/--repo"
    exit 1
fi

PID_FILE="/tmp/audit_git_$(echo "$REPO_DIR" | md5sum | awk '{print $1}').pid"

if $KILL; then
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            rm -f "$PID_FILE"
            echo "Demonio detenido (PID: $PID)"
        else
            echo "No hay demonio corriendo para este repo."
            rm -f "$PID_FILE"
        fi
    else
        echo "No hay demonio registrado para este repo."
    fi
    exit 0
fi

if [[ -z "$CONFIG_FILE" || -z "$LOG_FILE" ]]; then
    echo "Error: faltan parámetros obligatorios (-c y -l)."
    exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "Error: $REPO_DIR no parece ser un repositorio Git."
    exit 1
fi

if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Ya hay un demonio corriendo para este repo (PID: $PID)"
        exit 1
    else
        rm -f "$PID_FILE"
    fi
fi

# --- Función principal ---
monitor_repo() {
    cd "$REPO_DIR" || exit 1
    echo $$ > "$PID_FILE"
    echo "Demonio iniciado (PID: $$). Monitoreando $REPO_DIR..."

    LAST_COMMIT=$(git rev-parse HEAD)

    while true; do
        # Obtener el hash actual de la rama principal
        CURRENT_COMMIT=$(git rev-parse HEAD)

        if [[ "$LAST_COMMIT" != "$CURRENT_COMMIT" ]]; then
            FILES=$(git diff --name-only "$LAST_COMMIT" "$CURRENT_COMMIT")
            LAST_COMMIT=$CURRENT_COMMIT

            for FILE in $FILES; do
                [[ -f "$FILE" ]] || continue
                while IFS= read -r PATTERN; do
                    [[ -z "$PATTERN" ]] && continue
                    if [[ "$PATTERN" == regex:* ]]; then
                        REGEX="${PATTERN#regex:}"
                        if grep -Pq "$REGEX" "$FILE"; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alerta: patrón regex '$REGEX' encontrado en archivo '$FILE'." >> "$LOG_FILE"
                        fi
                    else
                        if grep -q "$PATTERN" "$FILE"; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alerta: patrón '$PATTERN' encontrado en archivo '$FILE'." >> "$LOG_FILE"
                        fi
                    fi
                done < "$CONFIG_FILE"
            done
        fi

        sleep 5   # chequea cada 5 segundos si el hash cambió
    done
}

# --- Lanzar en segundo plano ---
monitor_repo &
disown
