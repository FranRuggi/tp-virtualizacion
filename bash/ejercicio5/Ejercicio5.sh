
PAISES=()
rutaBaseCache="." #Aca debe ir "/tmp" por criterio de correcion
ttlActual=-1

function ayuda() {
    echo ""
    echo "Uso: $0 [opciones]"
    echo ""
    echo "Opciones:"
    echo "  -n, --nombre  Nombres de los países a consultar (separados por comas)."
    echo "                Puede ser uno o varios, por ejemplo:"
    echo "                  -n \"argentina, brasil, canada\""
    echo ""
    echo "  -t, --ttl     Tiempo de validez en segundos para usar los datos cacheados."
    echo "                Ejemplo:"
    echo "                  -t 3600"
    echo ""
    echo "  -h, --ayuda   Muestra esta ayuda."
    echo ""
    echo "Ejemplo de uso:"
    echo "  $0 -n \"argentina, brasil\" -t 600"
    echo ""
}

function mostrarInfoPaises () {
    for pais in "${PAISES[@]}";do
        rutaCompleArchTem="$rutaBaseCache/$pais.json" #armo la ruta final
        if [ -f "$rutaCompleArchTem" ]; then #veo si existe el archivo
            tiempoActual=$(date +%s) #tomo el tiempo atual
            ultimaModArch=$(stat -c %Y "$rutaCompleArchTem") #obtengo el tiempo de la ultima vez que el archivo fue editado
            if ((tiempoActual - ultimaModArch <= $ttlActual)); then #consulto si existe el archivo y veo si esta dentro del tiempo valido
                echo "usando Archivo $rutaCompleArchTem"
                echo "la diferencia: $(( $tiempoActual - $ultimaModArch ))"
                jq -r '"País: \(.name.common)\nCapital: \(.capital[0])\nRegión: \(.region)\nPoblación: \(.population)\nMoneda: \(.currencies | to_entries[] | .value.name)"' "$rutaCompleArchTem"
                echo ""
                continue
            fi
        fi
         #consulto a la api por que no existe o no esta dentro del tiempo valido
        echo "usando API"
        wget -qO- https://restcountries.com/v3.1/name/"$pais" | jq '.[0]' > "$rutaCompleArchTem" #lo guardo com un objeto, la API devuelve un array de un elemento
        jq -r '"País: \(.name.common)\nCapital: \(.capital[0])\nRegión: \(.region)\nPoblación: \(.population)\nMoneda: \(.currencies | to_entries[] | .value.name)"' "$rutaCompleArchTem"
        echo ""
    done
}
options=$(getopt -o n:,t:,h --l nombre:,ttl:,help -- "$@" 2> /dev/null)
if [ "$?" != "0" ]
then
    echo 'Error: parametro invalido o falta argumento a algun parametro.'
    exit 1
fi
eval set -- "$options"

while true
do
    case "$1" in
        -n | --nombre)
            CLEAN=$(echo "$2" | tr -d ' ') #elimino los espacios
            IFS=',' read -r -a PAISES <<< "$CLEAN" #Capturo todos los paises que me pasan por parametro
            if (( ttlActual == -1 )); then #si no entra, quiere decir que primero paso el ttl
                shift 2 #una vez que ya tengo todos los paises puedo shiftear
                ttlActual=$2
            fi
            mostrarInfoPaises
            exit 0
            ;;
        -t | --ttl)
            #Verifico si está vacío
            if [ -z "$2" ]; then
                echo "Error: Falta un valor para el parámetro -t o --ttl."
                exit 1
            fi

            #Verifico si es un número entero
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: El valor del parámetro -t o --ttl debe ser un número entero positivo."
                exit 1
            fi
            ttlActual=$2 #si me paso primero el parametro de ttl, lo tomo y paso a procesar el string de paises
            shift 2
            ;;
        -h | --help)
            ayuda
            exit 1
            ;;    
        --)
            shift
            break
            ;;
        *)
            echo 'Error de comando'
            exit 1
            ;;
    esac
done