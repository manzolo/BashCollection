#!/bin/bash

# Configurazione dell'ambiente per ridurre i warning lsof
configure_lsof_environment() {
    # Imposta variabili d'ambiente per ridurre warning lsof
    export LSOF_AVOID_WARNINGS=1
    
    # Crea un alias per lsof con opzioni silenziose se non esiste
    if ! alias lsof >/dev/null 2>&1; then
        alias lsof='lsof -w'
    fi
}