# GRUPO 2

# RUGGIERO BELLONE, ZOIS ANDRES UZIEL
# ROMBOLÁ FIGUEROA, FACUNDO AGUSTÍN
# RUGGIERI, FRANCO
# CROTTI, TOMÁS BENJAMÍN
# RIVERA MAMANI, VICTOR LEONCIO

#!/usr/bin/env bash
set -o pipefail

# =============== Utilidad ===============

log_message() {
    local message="$1" log_file="$2"
    [[ -z "$message" || -z "$log_file" ]] && { printf "Error: log_message requiere mensaje y log_file\n" >&2; return 1; }
    printf "%s %s\n" "$(date '+[%Y-%m-%d %H:%M:%S]')" "$message" >> "$log_file"
}

sanitize_path() {
    local path="$1"
    [[ -z "$path" ]] && return 1
    local abs_path
    abs_path=$(readlink -f -- "$path" 2>/dev/null) || return 1
    [[ -n "$abs_path" ]] || return 1
    printf "%s\n" "$abs_path"
}
ayuda() {
    cat <<EOF
Uso: $0 -r <repo> -c <config> [opciones]

Este script arranca un demonio que audita un repositorio Git en busca de
patrones sensibles (ej. contraseñas, claves privadas, tokens) definidos
en un archivo de configuración.

Opciones obligatorias:
  -r, --repo <repo>         Ruta al repositorio Git a auditar
  -c, --configuracion <cfg> Archivo con patrones (patterns.conf)

Opciones opcionales:
  -l, --log <log>           Archivo de log donde se registran alertas
                            (por defecto: ./audit.log)
  --sleep <segundos>        Intervalo entre chequeos (default: 10s)
  -k, --kill                Detiene el demonio asociado al repo indicado
  -h, --help                Muestra esta ayuda

Ejemplos:
  # Iniciar el demonio 
  $0 -r ./mi_repo -c ./patterns.conf -l ./audit.log

  # Detener el demonio
  $0 -r ./mi_repo -k

EOF
}


validate_patterns() {
    # Lee patrones, limpia CRLF, descarta comentarios/vacías y devuelve líneas intactas
    local config_file="$1"
    [[ -f "$config_file" ]] || { printf "Error: archivo de configuración no encontrado: %s\n" "$config_file" >&2; return 1; }

    local line
    local -a out=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}                 # quitar \r (CRLF)
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        out+=("$line")
    done < "$config_file"

    ((${#out[@]})) || { printf "Advertencia: %s no contiene patrones válidos\n" "$config_file" >&2; return 1; }
    printf '%s\n' "${out[@]}"
}

is_text_file() {
    # True si es texto (evita grepear binarios)
    local f="$1"
    grep -Iq . -- "$f"
}

# =============== Núcleo ===============
monitor_poll() { 
    local watch_path="$1" config_path="$2" log_file="$3" sleep_secs="${4:-10}"
    local patterns; patterns=$(validate_patterns "$config_path") || {
        log_message "No se encontraron patrones válidos. Saliendo." "$log_file"; return 1; }

    declare -A MTIME
    # índice inicial
    while IFS= read -r -d '' f; do
        MTIME["$f"]="$(stat -c %Y -- "$f" 2>/dev/null || echo 0)"
    done < <(find "$watch_path" -type f -print0)

    while true; do
        while IFS= read -r -d '' f; do
            local new="$(stat -c %Y -- "$f" 2>/dev/null || echo 0)"
            local old="${MTIME["$f"]:-0}"
            if [[ "$new" -gt "$old" ]]; then
                MTIME["$f"]="$new"
                is_text_file "$f" || continue
                local rel="${f#$watch_path/}"

                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    if [[ "$pattern" == regex:* ]]; then
                        local rg="${pattern#regex:}"
                        if grep -Eq -- "$rg" "$f"; then
                            log_message "Alerta: Patrón regex '$rg' encontrado en el archivo '$rel'." "$log_file"
                        fi
                    else
                        if grep -Fwq -- "$pattern" "$f"; then
                            log_message "Alerta: Patrón '$pattern' encontrado en el archivo '$rel'." "$log_file"
                        fi
                    fi
                done <<< "$patterns"
            fi
        done < <(find "$watch_path" -type f -print0)
        sleep "$sleep_secs"
    done
}
start_daemon() { 
    local repo_path="$1" config_path="$2" log_file="$3" sleep_secs="$4"

    exec 2>>"$log_file"
    log_message "Iniciando demonio. Directorio monitoreado: $repo_path" "$log_file"
    monitor_poll "$repo_path" "$config_path" "$log_file" "$sleep_secs"

}


stop_daemon() {
    local pid_file="$1" log_file="$2"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || { printf "Error: no se pudo leer el archivo PID\n" >&2; return 1; }
        if ps -p "$pid" > /dev/null 2>&1; then
            printf "Deteniendo el proceso demonio con PID: %s\n" "$pid"
            kill "$pid"
            rm -f -- "$pid_file"
            log_message "Demonio detenido." "$log_file"
            return 0
        else
            printf "No se encontró un proceso demonio en ejecución para este repositorio.\n"
            rm -f -- "$pid_file"
            return 1
        fi
    else
        printf "No se encontró un proceso demonio en ejecución para este repositorio.\n"
        return 1
    fi
}

main() {
    REPO_PATH=""
    CONFIG_PATH=""
    LOG_FILE="./audit.log"
    KILL_FLAG=false
    SLEEP_SECONDS=5

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -r|--repo) REPO_PATH="$2"; shift 2 ;;
            -c|--configuracion) CONFIG_PATH="$2"; shift 2 ;;
            -l|--log) LOG_FILE="$2"; shift 2 ;;
            --sleep) SLEEP_SECONDS="$2"; shift 2 ;;
            -k|--kill) KILL_FLAG=true; shift ;;
            -h|--help)
                ayuda;
                return 0 ;;
            *) return 1 ;;
        esac
    done

    if ! REPO_PATH=$(sanitize_path "$REPO_PATH"); then
        printf "Error: ruta de repositorio inválida\n" >&2; return 1
    fi
    if [[ "$KILL_FLAG" == false ]]; then
        if ! CONFIG_PATH=$(sanitize_path "$CONFIG_PATH"); then
            printf "Error: ruta de configuración inválida\n" >&2; return 1
        fi
        if ! LOG_FILE=$(sanitize_path "$LOG_FILE"); then
            printf "Error: ruta de log inválida\n" >&2; return 1
        fi
    else
        LOG_FILE=$(sanitize_path "$LOG_FILE" 2>/dev/null || printf "./audit.log\n")
    fi

    # pidfile único por repo (hash de la ruta absoluta)
    local repo_hash pid_file
    repo_hash=$(printf "%s" "$REPO_PATH" | md5sum | awk '{print $1}')
    pid_file="./audit_daemon_${repo_hash}.pid"

    if [[ "$KILL_FLAG" == true ]]; then
        stop_daemon "$pid_file" "$LOG_FILE"
        return $?
    fi

    if [[ -z "$REPO_PATH" || -z "$CONFIG_PATH" ]]; then
        printf "Error: Se requieren los parámetros -r y -c.\n" >&2; return 1
    fi
    if [[ -f "$pid_file" ]]; then
        local pid; pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" > /dev/null 2>&1; then
            printf "Ya existe un proceso demonio en ejecución (PID: %s) para este repositorio.\n" "$pid"
            return 1
        else
            rm -f -- "$pid_file"
        fi
    fi

    printf "Iniciando el demonio en segundo plano para: %s (sleep=%ss)\n" "$REPO_PATH" "$SLEEP_SECONDS"
    start_daemon "$REPO_PATH" "$CONFIG_PATH" "$LOG_FILE" "$SLEEP_SECONDS" &
    local daemon_pid=$!
    printf "%s\n" "$daemon_pid" > "$pid_file"
    printf "Demonio iniciado. PID: %s\nLog: %s\n" "$daemon_pid" "$LOG_FILE"
    return 0
}

main "$@"
