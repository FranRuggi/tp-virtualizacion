#!/bin/bash


parsed=$(getopt -o r:c:l:kh -l repo:configuracion:log,kill,help -- "$@") || {
  echo "Uso: $0 -r <repositorio> -c <archivo configuración> -l <ruta de log> -k 
Para mas detalles sobre el script usar -h | --help"; exit 2; }
eval set -- "$parsed"