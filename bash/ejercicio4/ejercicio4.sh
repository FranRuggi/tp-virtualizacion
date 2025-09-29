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

scan_repo() {
    local repo_path="$1" config_path="$2" log_file="$3" sleep_secs="$4"

    exec 2>>"$log_file"
    log_message "Iniciando demonio para el repositorio: $repo_path" "$log_file"

    local patterns
    if ! patterns=$(validate_patterns "$config_path"); then
        log_message "No se encontraron patrones válidos. Finalizando demonio." "$log_file"
        return 1
    fi

    # Arrancar “desde ahora”: no procesar el commit presente al inicio
    local last_scanned_commit
    last_scanned_commit=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || printf "")

    while true; do
        local current_commit
        if ! current_commit=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null); then
            sleep "$sleep_secs"
            continue
        fi

        if [[ "$current_commit" != "$last_scanned_commit" ]]; then
            log_message "Nuevo commit detectado en el repositorio. Hash: $current_commit" "$log_file"

            # Archivos de ese commit (A/C/M/R), NUL-safe, sin variables intermedias
            git -C "$repo_path" diff-tree --no-commit-id --name-only -r -z --diff-filter=ACMR "$current_commit" 2>/dev/null \
            | while IFS= read -r -d '' file; do
                local full_path="$repo_path/$file"
                [[ -f "$full_path" ]] || continue
                is_text_file "$full_path" || continue

                # Evaluar patrones
                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    if [[ "$pattern" == regex:* ]]; then
                        local regex_pattern="${pattern#regex:}"
                        if grep -Eq -- "$regex_pattern" "$full_path"; then
                            log_message "Alerta: Patrón regex '$regex_pattern' encontrado en el archivo '$file'." "$log_file"
                        fi
                    else
                        if grep -Fq -- "$pattern" "$full_path"; then
                            log_message "Alerta: Patrón '$pattern' encontrado en el archivo '$file'." "$log_file"
                        fi
                    fi
                done <<< "$patterns"
            done

            # Marcar como procesado
            last_scanned_commit="$current_commit"
        fi

        sleep "$sleep_secs"
    done
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
    SLEEP_SECONDS=10

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -r|--repo) REPO_PATH="$2"; shift 2 ;;
            -c|--configuracion) CONFIG_PATH="$2"; shift 2 ;;
            -l|--log) LOG_FILE="$2"; shift 2 ;;
            --sleep) SLEEP_SECONDS="$2"; shift 2 ;;
            -k|--kill) KILL_FLAG=true; shift ;;
            -h|--help)
                printf "Uso: %s -r <repo> -c <config> [-l <log>] [--sleep <seg>] [-k]\n" "$0"
                return 0 ;;
            *) printf "Uso: %s -r <repo> -c <config>\n" "$0" >&2; return 1 ;;
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
    [[ -d "$REPO_PATH/.git" ]] || { printf "Error: '%s' no es un repositorio Git válido.\n" "$REPO_PATH" >&2; return 1; }

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
    scan_repo "$REPO_PATH" "$CONFIG_PATH" "$LOG_FILE" "$SLEEP_SECONDS" &
    local daemon_pid=$!
    printf "%s\n" "$daemon_pid" > "$pid_file"
    printf "Demonio iniciado. PID: %s\nLog: %s\n" "$daemon_pid" "$LOG_FILE"
    return 0
}

main "$@"
