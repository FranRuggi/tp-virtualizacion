#!/bin/bash

# --- Funciones de utilidad ---

log_message() {
    local message="$1"
    local log_file="$2"
    if [[ -z "$message" || -z "$log_file" ]]; then
        printf "Error: log_message requiere mensaje y log_file\n" >&2
        return 1
    fi
    printf "%s %s\n" "$(date '+[%Y-%m-%d %H:%M:%S]')" "$message" >> "$log_file"
}

sanitize_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 1
    fi
    local abs_path
    if ! abs_path=$(readlink -f "$path" 2>/dev/null); then
        return 1
    fi
    if [[ -z "$abs_path" ]]; then
        return 1
    fi
    printf "%s\n" "$abs_path"
}

validate_patterns() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        printf "Error: archivo de configuración no encontrado: %s\n" "$config_file" >&2
        return 1
    fi
    local patterns
    if ! patterns=$(grep -v '^\s*#\|^$' "$config_file"); then
        printf "Error al leer patrones de %s\n" "$config_file" >&2
        return 1
    fi
    if [[ -z "$patterns" ]]; then
        printf "Advertencia: el archivo de configuración %s no contiene patrones válidos\n" "$config_file" >&2
        return 1
    fi
    printf "%s\n" "$patterns"
}

scan_repo() {
    local repo_path="$1"
    local config_path="$2"
    local log_file="$3"

    exec 2>>"$log_file"
    log_message "Iniciando demonio para el repositorio: $repo_path" "$log_file"

    local patterns
    if ! patterns=$(validate_patterns "$config_path"); then
        log_message "No se encontraron patrones válidos. Finalizando demonio." "$log_file"
        return 1
    fi

    local last_scanned_commit=""

    while true; do
        local current_commit
        if ! current_commit=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null); then
            sleep 10
            continue
        fi

        if [[ "$current_commit" != "$last_scanned_commit" ]]; then
            local changed_files
            if ! changed_files=$(git -C "$repo_path" diff-tree --no-commit-id --name-only -r "$current_commit" 2>/dev/null); then
                sleep 10
                continue
            fi

            if [[ -n "$changed_files" ]]; then
                for file in $changed_files; do
                    local full_path="$repo_path/$file"
                    if [[ -f "$full_path" ]]; then
                        while IFS= read -r pattern; do
                            if [[ -z "$pattern" ]]; then
                                continue
                            fi
                            if [[ "$pattern" =~ ^regex: ]]; then
                                local regex_pattern="${pattern#regex:}"
                                if grep -Eq "$regex_pattern" "$full_path"; then
                                    log_message "Alerta: Patrón regex '$regex_pattern' encontrado en el archivo '$file'." "$log_file"
                                fi
                            else
                                if grep -qF "$pattern" "$full_path"; then
                                    log_message "Alerta: Patrón '$pattern' encontrado en el archivo '$file'." "$log_file"
                                fi
                            fi
                        done <<< "$patterns"
                    fi
                done
            fi
            last_scanned_commit="$current_commit"
        fi
        sleep 10
    done
}

stop_daemon() {
    local pid_file="$1"
    local log_file="$2"

    if [[ -f "$pid_file" ]]; then
        local pid
        if ! pid=$(cat "$pid_file" 2>/dev/null); then
            printf "Error: no se pudo leer el archivo PID\n" >&2
            return 1
        fi
        if ps -p "$pid" > /dev/null 2>&1; then
            printf "Deteniendo el proceso demonio con PID: %s\n" "$pid"
            kill "$pid"
            rm -f "$pid_file"
            log_message "Demonio detenido." "$log_file"
            return 0
        else
            printf "No se encontró un proceso demonio en ejecución para este repositorio.\n"
            rm -f "$pid_file"
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

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -r|--repo) REPO_PATH="$2"; shift 2 ;;
            -c|--configuracion) CONFIG_PATH="$2"; shift 2 ;;
            -l|--log) LOG_FILE="$2"; shift 2 ;;
            -k|--kill) KILL_FLAG=true; shift 1 ;;
            *) printf "Uso: %s -r <repositorio> -c <config>\n" "$0" >&2; return 1 ;;
        esac
    done

    if ! REPO_PATH=$(sanitize_path "$REPO_PATH"); then
        printf "Error: ruta de repositorio inválida\n" >&2
        return 1
    fi
    if [[ "$KILL_FLAG" == false ]]; then
        if ! CONFIG_PATH=$(sanitize_path "$CONFIG_PATH"); then
            printf "Error: ruta de configuración inválida\n" >&2
            return 1
        fi
        if ! LOG_FILE=$(sanitize_path "$LOG_FILE"); then
            printf "Error: ruta de log inválida\n" >&2
            return 1
        fi
    else
        LOG_FILE=$(sanitize_path "$LOG_FILE" 2>/dev/null || printf "./audit.log\n")
    fi

    local pid_file="./audit_daemon_$(basename "$REPO_PATH").pid"

    if [[ "$KILL_FLAG" == true ]]; then
        stop_daemon "$pid_file" "$LOG_FILE"
        return $?
    fi

    if [[ -z "$REPO_PATH" || -z "$CONFIG_PATH" ]]; then
        printf "Error: Se requieren los parámetros -r y -c.\n" >&2
        return 1
    fi
    if [[ ! -d "$REPO_PATH/.git" ]]; then
        printf "Error: La ruta '%s' no es un repositorio Git válido.\n" "$REPO_PATH" >&2
        return 1
    fi
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if ps -p "$pid" > /dev/null 2>&1; then
            printf "Ya existe un proceso demonio en ejecución (PID: %s) para este repositorio.\n" "$pid"
            return 1
        else
            rm -f "$pid_file"
        fi
    fi

    printf "Iniciando el demonio en segundo plano para el repositorio: %s\n" "$REPO_PATH"
    scan_repo "$REPO_PATH" "$CONFIG_PATH" "$LOG_FILE" &
    local daemon_pid=$!
    printf "%s\n" "$daemon_pid" > "$pid_file"
    printf "Demonio iniciado. PID: %s\n" "$daemon_pid"
    printf "Revisa el archivo de log para las alertas: %s\n" "$LOG_FILE"
    return 0
}

main "$@"
