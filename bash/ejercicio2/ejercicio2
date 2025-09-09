#!/bin/bash

# ================== FLAGS Y VARIABLES ==================
MATRIZ=""
SEPARADOR="|"
CAMINO=0
HUB=0
AYUDA=0

INF=1e300                 # "infinito" para distancias
MEJOR_COSTO="$INF"

# Matriz y estructuras globales
declare -A MAT           # MAT["i,j"] = peso
declare -A D             # D["i,j"]  = distancia mínima entre i y j (precalc)

declare -a dist visit prev_parents parent_best
declare -a orden visit                     # para backtracking
declare -a MEJORES_ORDENES                 # lista de órdenes óptimos en CSV (ej: "0,1,2,3")

# ================== HELPERS NUMÉRICOS ==================
f_add() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.15g\n", a+b}'; }
f_lt()  { awk -v a="$1" -v b="$2" 'BEGIN{eps=1e-9; exit !(a < b - eps)}'; }
f_eq()  { awk -v a="$1" -v b="$2" 'BEGIN{eps=1e-9; d=a-b; if (d<0) d=-d; exit !(d<eps)}'; }
es_pos(){ awk -v x="$1" 'BEGIN{exit !(x>0)}'; }   # true si x>0

# ================== RUTAS ABSOLUTAS ==================
abspath_dir() {
  local d="$1"
  case "$d" in
    /*|~*) printf '%s\n' "$d" ;;
    *)     ( cd "$d" 2>/dev/null && pwd ) || return 1 ;;
  esac
}
abspath_file() {
  local f="$1" dir base
  dir=$(dirname -- "$f")
  base=$(basename -- "$f")
  dir=$(abspath_dir "$dir") || return 1
  printf '%s/%s\n' "$dir" "$base"
}

# ================== VALIDACIÓN + CARGA MATRIZ ==================
validar_y_cargar_matriz() {
  local archivo="$1" sep="$2"
  [[ -f "$archivo" ]] || { echo "Error: no existe archivo $archivo" >&2; return 1; }

  local fila=0 cols_esperadas=-1

  while IFS= read -r linea || [[ -n "$linea" ]]; do
    # limpiar CRLF si viniera de Windows
    linea=${linea%$'\r'}

    # split SOLO con IFS local (no tocamos IFS global)
    local IFS="$sep"
    read -r -a celdas <<< "$linea"

    local cols=${#celdas[@]}
    if (( cols_esperadas < 0 )); then
      cols_esperadas=$cols
    fi
    if (( cols != cols_esperadas )); then
      echo "Error: fila $((fila+1)) tiene $cols columnas, se esperaban $cols_esperadas" >&2
      return 2
    fi

    # numérico no negativo (enteros o decimales)
    local v
    for v in "${celdas[@]}"; do
      [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Error: valor no numérico en fila $((fila+1)): '$v'" >&2; return 3; }
    done

    # cargar en MAT
    local col
    for ((col=0; col<cols; col++)); do
      MAT["$fila,$col"]="${celdas[$col]}"
    done
    ((fila++))
  done < <(tr -d '\r' < "$archivo")   # seguro en Linux y Windows

  # cuadrada
  if (( fila != cols_esperadas )); then
    echo "Error: matriz no es cuadrada (${fila}x${cols_esperadas})" >&2
    return 4
  fi

  N=$fila

  # simétrica
  local i j
  for ((i=0;i<N;i++)); do
    for ((j=0;j<N;j++)); do
      [[ "${MAT["$i,$j"]}" == "${MAT["$j,$i"]}" ]] || {
        echo "Error: matriz no simétrica en ($i,$j)" >&2
        return 5
      }
    done
  done

  echo "OK: matriz ${N}x${N} validada y cargada"
  return 0
}

# ================== DIJKSTRA (single-source) ==================
dijkstra_desde() {  # $1 = origen 0..N-1
  local s="$1"
  dist=(); visit=(); prev_parents=(); parent_best=()
  local i
  for ((i=0;i<N;i++)); do
    dist[$i]="$INF"; visit[$i]=0; prev_parents[$i]=""; parent_best[$i]=-1
  done
  dist[$s]=0
  parent_best[$s]=-1

  local k u best v w new
  for ((k=0;k<N;k++)); do
    # elegir u no visitado con dist mínima
    u=-1; best="$INF"
    for ((i=0;i<N;i++)); do
      if [[ ${visit[$i]} -eq 0 ]] && f_lt "${dist[$i]}" "$best"; then
        u=$i; best="${dist[$i]}"
      fi
    done
    [[ $u -lt 0 ]] && break
    visit[$u]=1

    # relajar u->v
    for ((v=0; v<N; v++)); do
      (( u==v )) && continue
      w="${MAT["$u,$v"]}"
      if es_pos "$w"; then
        new=$(f_add "${dist[$u]}" "$w")
        if f_lt "$new" "${dist[$v]}"; then
          dist[$v]="$new"
          prev_parents[$v]="$u"
          parent_best[$v]="$u"      # padre único para reconstrucción segura
        elif f_eq "$new" "${dist[$v]}"; then
          prev_parents[$v]="${prev_parents[$v]} $u"
          # parent_best se mantiene (ya válido)
        fi
      fi
    done
  done
}

# ================== RECONSTRUIR UN CAMINO s..t ==================
reconstruir_un_camino() {  # $1=s $2=t ; imprime "s ... t" o retorna 1 si no hay
  local s="$1" t="$2"
  f_eq "${dist[$t]}" "$INF" && return 1
  local cur="$t"
  local -a stack out

  while [[ $cur -ne -1 ]]; do
    stack+=( "$cur" )
    [[ $cur -eq $s ]] && break
    cur="${parent_best[$cur]}"
    [[ $cur -eq -1 ]] && return 1
  done
  local i
  for ((i=${#stack[@]}-1;i>=0;i--)); do out+=( "${stack[$i]}" ); done
  echo "${out[*]}"
}

# ================== PRECALCULAR TODAS LAS DISTANCIAS ==================
precalcular_todas_las_distancias() {
  local s t
  for ((s=0; s<N; s++)); do
    dijkstra_desde "$s"
    for ((t=0; t<N; t++)); do
      D["$s,$t"]="${dist[$t]}"
    done
  done
}

# ================== BACKTRACKING (orden que visita todas) ==================
buscar_ordenes_minimos_bt() {  # $1=profundidad $2=costo_parcial
  local k="$1" costo="$2"

  # poda
  f_lt "$MEJOR_COSTO" "$costo" && return

  if (( k == N )); then
    if f_lt "$costo" "$MEJOR_COSTO"; then
      MEJOR_COSTO="$costo"
      MEJORES_ORDENES=()
    fi
    if f_eq "$costo" "$MEJOR_COSTO"; then
      local line=""
      local i
      for ((i=0;i<N;i++)); do
        line+="${orden[$i]},"
      done
      line="${line%,}"                # quitar coma final
      MEJORES_ORDENES+=( "$line" )
    fi
    return
  fi

  local v extra prev d nuevo
  for ((v=0; v<N; v++)); do
    if [[ "${visit[$v]}" -eq 0 ]]; then
      extra="0"
      if (( k > 0 )); then
        prev="${orden[$((k-1))]}"
        d="${D["$prev,$v"]}"
        f_eq "$d" "$INF" && continue  # rama inválida
        extra="$d"
      fi
      visit[$v]=1
      orden[$k]="$v"
      nuevo=$(f_add "$costo" "$extra")
      buscar_ordenes_minimos_bt "$((k+1))" "$nuevo"
      visit[$v]=0
    fi
  done
}

# ================== HUB ==================
resolver_hub() {
  local -a DEG
  local max=-1
  local i j v
  for ((i=0;i<N;i++)); do
    DEG[$i]=0
    for ((j=0;j<N;j++)); do
      (( i==j )) && continue
      v=${MAT["$i,$j"]}
      if es_pos "$v"; then (( DEG[$i]++ )); fi
    done
    (( DEG[$i] > max )) && max=${DEG[$i]}
  done

  echo "**Hub(s) de la red** (grado=$max):"
  for ((i=0;i<N;i++)); do
    (( DEG[$i] == max )) && echo "  - Estación $((i+1))"
  done
}

# ================== INFORME: CAMINO QUE VISITA TODAS ==================
camino() {
  precalcular_todas_las_distancias

  MEJOR_COSTO="$INF"; MEJORES_ORDENES=()
  visit=(); orden=(); for ((i=0;i<N;i++)); do visit[$i]=0; done
  buscar_ordenes_minimos_bt 0 0

  {
    echo "## Informe de análisis de red de transporte"
    echo "**Recorrido(s) más rápido(s) que visitan todas las estaciones (0..N-1):**"
    echo "**Costo total mínimo:** $MEJOR_COSTO"
    echo "**Ruta(s) (estaciones 1..$N):**"
  } > "$SALIDA"

  local line
  for line in "${MEJORES_ORDENES[@]}"; do
    # orden CSV → array de enteros
    local -a ord
    IFS=',' read -r -a ord <<< "$line"

    # armar ruta pegando tramos mínimos entre consecutivos
    local -a ruta_completa
    ruta_completa=()

    local i s t tramo
    for ((i=0;i<N-1;i++)); do
      s="${ord[$i]}"
      t="${ord[$((i+1))]}"

      dijkstra_desde "$s"
      tramo="$(reconstruir_un_camino "$s" "$t")" || {
        echo "Advertencia: red no conexa para $((s+1))→$((t+1))" >&2
        continue
      }

      local -a nodes
      IFS=$' \t\n' read -r -a nodes <<< "$tramo"

      if (( i == 0 )); then
        ruta_completa+=( "${nodes[@]}" )
      else
        # evitar repetir el primer nodo del tramo
        local k
        for ((k=1;k<${#nodes[@]};k++)); do
          ruta_completa+=( "${nodes[$k]}" )
        done
      fi
    done

    # pretty 1..N con flechas
    local pretty
    pretty=$(awk '{
      out="";
      for(i=1;i<=NF;i++){ if(i>1) out=out" -> "; out=out"" ($i+1) }
      print out
    }' <<< "${ruta_completa[*]}")

    echo "- $pretty" >> "$SALIDA"
  done

  echo "Informe escrito en: $SALIDA"
}

# ================== AYUDA ==================
ayuda() {
  cat <<'EOF'

Analiza una red de transporte modelada como matriz de adyacencia.
Puede:
  - Determinar HUB(s) (estaciones con más conexiones).
  - Calcular recorridos mínimos que visiten todas las estaciones (usando Dijkstra para tramos).

REQUISITOS:
  • La salida se guarda en "informe.<nombreArchivoEntrada>" en el MISMO directorio del archivo original.
  • La matriz debe ser cuadrada, simétrica y numérica (pesos no negativos).

USO:
  script -m|--matriz <archivo> [-s|--separador <caracter>] (-c|--camino | -h|--hub)
  script -H | --help

PARÁMETROS:
  -m, --matriz      Archivo de la matriz (obligatorio).
  -s, --separador   Separador de columnas (default: "|"). Para tab: $'\t'
  -c, --camino      Calcula recorrido(s) que visiten todas las estaciones (usa Dijkstra entre pares).
  -h, --hub         Muestra el/los hubs (mayor grado).
  -H, --help        Esta ayuda.

EOF
  exit 0
}

# ================== PARSEO DE OPCIONES ==================
options=$(getopt -o m:s:c,h,H -l matriz:,separador:,camino,hub,help -- "$@") || {
  echo "Uso: $0 -m <archivo> [-s <sep>] (-c | -h)  |  -H" >&2; exit 2; }
eval set -- "$options"
while true; do
  case "$1" in
    -m|--matriz)     MATRIZ="$(abspath_file "$2")"; shift 2 ;;
    -s|--separador)  SEPARADOR="$2"; shift 2 ;;
    -c|--camino)     CAMINO=1; shift ;;
    -h|--hub)        HUB=1; shift ;;
    -H|--help)       ayuda ;;
    --)              shift; break ;;
    *)               echo "Opción inválida: $1" >&2; exit 2 ;;
  esac
done

# ================== VALIDACIONES GENERALES ==================
if [ -z "$MATRIZ" ] || [ ! -f "$MATRIZ" ]; then
  echo "Error: faltó -m/--matriz o no existe: $MATRIZ" >&2
  exit 1
fi
if [ "$CAMINO" -eq 1 ] && [ "$HUB" -eq 1 ]; then
  echo "Error: -c/--camino y -h/--hub son excluyentes." >&2
  exit 1
fi
if [ "$CAMINO" -eq 0 ] && [ "$HUB" -eq 0 ]; then
  echo "Debe elegir -c|--camino o -h|--hub (use -H para ayuda)" >&2
  exit 1
fi

# validar matriz
validar_y_cargar_matriz "$MATRIZ" "$SEPARADOR" || exit $?

# ruta de salida (mismo directorio, prefijo "informe.")
dir=$(dirname -- "$MATRIZ")
base=$(basename -- "$MATRIZ")
SALIDA="$dir/informe.$base"

# ================== EJECUCIÓN ==================
if [ "$CAMINO" -eq 1 ]; then
  camino
fi

if [ "$HUB" -eq 1 ]; then
  {
    echo "## Informe de análisis de red de transporte"
    resolver_hub
  } > "$SALIDA"
  echo "Informe escrito en: $SALIDA"
fi

# (opcional) eco de control
#echo "Matriz: $MATRIZ"
#echo "Separador: $SEPARADOR"
#echo "Camino: $CAMINO"
#echo "HUB: $HUB"
#echo "Salida: $SALIDA"
