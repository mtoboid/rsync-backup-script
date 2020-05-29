#!/usr/bin/env bash

function main() {

    local SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
    
    if (( $EUID != 0 )); then
	echo "${0##*/} has to be run as root." >&2
	exit 1
    fi

    ## make the folder structure in root
    ##
    mkdir -p /root/backup/log /root/backup/scripts

    ## copy the necessary files across
    ##
    install --mode=640 "${SCRIPT_DIR}/exclude-backup-home.patterns" /root/backup
    install --mode=750 "${SCRIPT_DIR}/backup.template" /root/backup/scripts
    
    exit 0
}

main
