#!/usr/bin/env bash

# @Name:         backup-to-server.bash
# @Author:       Tobias Marczewski
# @Last Edit:    2020-05-12
# @Dependencies: wakeonlan, systemd (systemd-resolve), getopt,
#                notify-send.py (https://github.com/phuhl/notify-send.py)
#                notify-send.py has to be in the $PATH
#                sleep-lock.bash (on server)
# @Location:     /usr/local/bin/backup-to-server

# Shellscript to connect to a local server and run rsync to perform a backup
# (synchronisation with deleting files). Files that were deleted will be kept
# for a specified number of backups and can be found in the folder '/old/{date}'
# whereas the most recent backup will be in the folder '/current'.
# The script is intended to work with a server that has wake-on-lan capabilites,
# and if asleep will be woken up.
# For the script to work ssh login on the server via a key-pair has to be set up.
#

# NOTE: careful with ssh using <<EOF as the send command will be send
#       as text, which means that variables which are not escaped will be
#       resolved at the local machine and send as text to the server,
#       hence it is crucial to escape \${variables} and \$(subshells)
#       that are to be interpreted on the server shell!

# SSH:  the possibility to specify an ssh identity file via ssh -i is
#       intentionally not implemented, rather use the option of a
#       by user configuration via $HOME/.ssh/config !

# TODO
# implement: switch for (if to wakeup); switch for (if to show notifications)

readonly VERSION=1.2

#function cleanup




function usage() {
    echo "Usage:"
    echo "TEXT"
    echo ""
}

################################################################################
# Check if a program is available on the system.
#
# Arguments:
#   $1 - name of the program/command [string]
#
# Returns:
#   0 - (true) if the command is available
#   1 - (false) if the command is NOT available
#
function is_installed() {
    
    if [[ -z "$1" ]]; then
	echo "is_installed() Error: no argument provided!" >&2
	exit 1
    fi
    local -r check_command="$1"
    
    if $(command -v "$check_command" >/dev/null); then
	return 0
    else
	return 1
    fi  
}

################################################################################
# Parse the arguments provided to the script and set Global variables accordingly.
# Also check the validity of the input when possible (local variables). Destinations
# on the server are not being checked.
#
# Arguments:
#   none
#
# Output:
#   none - but sets the following
#
# Global Variables:
#   DB_FOLDER_PATH
#   DESTINATION_DIR
#   DRY_RUN
#   EXCLUDE_FILE
#   KEEP_N_BACKUPS
#   LOGFILE
#   MAX_WAKEUP_WAIT
#   RSYNC_LOG_FILE
#   SEND_NOTIFICATIONS
#   SERVER_ADDRESS
#   SERVER_MAC
#   SERVER_USER
#   SOURCE_DIR
#   USE_LOGFILE
#
function parse_arguments() {

    echo "Entering function parse_arguments()"  # XXX

    if [[ -z "$1" ]]; then
	echo "No arguments provided, see ${0} --help for usage." >&2
	exit 1
    fi
    
    local arguments
    arguments=$(getopt --options 'vhu:a:m:e:l:' \
		       --longoptions 'version,help,\
server-user:,server-address:,server-mac:,\
exclude-file:,log-file:,rsync-log-file:,\
send-notifications,dry-run,\
max-wake-wait:,db-path:,keep-n-backups:'\
		       --name "$0" -- "$@")
    
    if (( "$?" != 0 )); then
        echo "Error while parsing arguments." >&2
	exit 1
    fi

    eval set -- "$arguments"
    unset arguments

    while true; do
	case "$1" in
	    '-v'|'--version')
		echo "$VERSION"
		exit 0
		;;
	    '-h'|'--help')
		usage
		exit 0
		;;
	    '-u'|'--server-user')
		SERVER_USER="$2"
		shift 2
		continue
		;;
	    '-a'|'--server-address')
		SERVER_ADDRESS="$2"
		shift 2
		continue
		;;
	    '-m'|'--server-mac')
		SERVER_MAC="$2"
		shift 2
		continue
		;;
	    '-e'|'--exclude-file')
		EXCLUDE_FILE="$2"
		shift 2
		continue
		;;
	    '-l'|'--log-file')
		USE_LOGFILE=true
		LOGFILE="$2"
		shift 2
		continue
		;;
	    '--rsync-log-file')
		RSYNC_LOG_FILE="$2"
		shift 2
		continue
		;;
	    '--max-wake-wait')
		MAX_WAKEUP_WAIT="$2"
		shift 2
		continue
		;;
	    '--db-path')
		DB_FOLDER_PATH="$2"
		shift 2
		continue
		;;
	    '--keep-n-backups')
		KEEP_N_BACKUPS="$2"
		shift 2
		continue
		;;
	    '--send-notifications')
		SEND_NOTIFICATIONS=true
		shift
		continue
		;;
	    '--dry-run')
		DRY_RUN=true
		shift
		continue
		;;
	    '--')
		shift
		break
		;;
	    *)
		echo "Internal error!" >&2
		exit 1
		;;
	esac
    done    

    ## read directories SRC DEST
    ##
    SOURCE_DIR="$1"
    DESTINATION_DIR="$2"
    shift 2

    ## Check the validity of all arguments
    ##

    ## 1) SRC and DEST
    ##
    if [[ -z "$SOURCE_DIR" ]]; then
	echo "No SRC specified, see ${0} --help for usage." >&2
	exit 1
    elif [[ ! -d "$SOURCE_DIR" ]]; then
	echo "Source dir ${SOURCE_DIR} not found." >&2
	exit 1
    elif [[ ! -r "$SOURCE_DIR" ]] || [[ ! -x "$SOURCE_DIR" ]]; then
	echo "No read permission for SRC - ${SOURCE_DIR}" >&2
	exit 1
    fi

    if [[ -z "$DESTINATION_DIR" ]]; then
	echo "No DEST specified, see ${0} --help for usage." >&2
	exit 1
    fi

    ## remove trailing slashes from DEST if present
    ##
    DESTINATION_DIR="${DESTINATION_DIR%%+(/)}"
    
    readonly SOURCE_DIR
    readonly DESTINATION_DIR

    ## 2) user and server
    ##
    if [[ -z "$SERVER_USER" ]]; then
	SERVER_USER="${USER}"
    fi

    if [[ -z "$SERVER_ADDRESS" ]]; then
	## Was user@server provided?
	## check if '@' in SERVER_USER, and if so
	## split into 'SERVER_USER'@'SERVER_ADDRESS'
	##
	if [[ -n "${SERVER_USER//[^@]}" ]]; then
	    SERVER_ADDRESS="${SERVER_USER#*@}"
	    SERVER_USER="${SERVER_USER%@*}"
	else
	    SERVER_ADDRESS="localhost"
	fi
    fi

    declare -r mac_regex='^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
    if [[ ! -z "$SERVER_MAC" ]] &&
	   (( $(echo "${SERVER_MAC}" | grep -cP "$mac_regex") != 1 ))
    then
	echo "The provided MAC address ${SERVER_MAC} is not a valid MAC." >&2
	exit 1
    fi

    ## Insure that 'wakeonlan' is installed when a server mac is provided
    ##
    if (! is_installed wakeonlan); then
	echo "A MAC address for the server was provided," \
	     "implying that WakeOnLAN should be used." \
	     "However, the package 'wakeonlan' does not seem to be installed." \
	     "Please install it before proceeding 'apt install wakeonlan'" >&2
	exit 1
    fi
    
    readonly SERVER_USER
    readonly SERVER_ADDRESS
    readonly SERVER_MAC
    
    ## 3) Log
    ##
    if $USE_LOGFILE; then
	if [[ -z "$LOGFILE" ]]; then
	    echo "No logfile provided see ${0} for usage." >&2
	    exit 1
	elif ( ! touch "$LOGFILE" &>/dev/null ); then
	    echo "Can't create or write to logfile: ${LOGFILE}." >&2
	    exit 1
	fi
    fi
    
    readonly USE_LOGFILE
    readonly LOGFILE

    ## 4) Exclude file
    ##
    if [[ ! -z "$EXCLUDE_FILE" ]] && [[ ! -r "$EXCLUDE_FILE" ]]; then
	echo "Can't read exclude file: ${EXCLUDE_FILE}" >&2
	exit 1
    fi

    ## 5) Settings with default values
    ##
    if [[ -z "$DB_FOLDER_PATH" ]]; then
	echo "Error: db-folder path was unset." >&2
	exit 1
    fi

    if (( "$KEEP_N_BACKUPS" < 0 )); then
	KEEP_N_BACKUPS=0
    fi

    if (( "$MAX_WAKEUP_WAIT" < 1 )); then
	MAX_WAKEUP_WAIT=0
    fi

    readonly DB_FOLDER_PATH
    readonly KEEP_N_BACKUPS
    readonly MAX_WAKEUP_WAIT

    ## Ensure 'libnotify-bin' is installed when notifications are requested
    ##
    if $SEND_NOTIFICATIONS && (! is_installed notify-send); then
	echo "Notifications are enabled, but 'notify-send' is not available." \
	     "Please install 'libnotify-bin' before proceeding." >&2
	exit 1
    fi
    
    readonly SEND_NOTIFICATIONS
    readonly DRY_RUN
    
    return 0
}

################################################################################
# Write a message to standard output, or to a logfile
#
# Arguments:
#   The text to write (as in echo), \n will be interpreted as newline,
#   but other escaped characters will not.
#
# Pipe / Stdin
#   Text piped to the function will be appended after the arguments
#
# Global Variables:
#   USE_LOGFILE
#   LOGFILE
#
# Examples:
#   message "this" "will" be in "one line"
#   -> this will be in one line
#   message "This is line 1\nwhile this is line 2."
#   -> This is line 1
#      while this is line 2.
#   echo "This is from a pipe" | message
#   -> This is from a pipe
#   echo "pipe text\nwill be appended." | message "First text from arguments, then"
#   -> First text from arguments, then
#      pipe text
#      will be appended.
#
function message() {
    
    declare -a text_message

    ## If any arguments where passed, read them
    ## 1. first as concatenated text (as is), and
    ## 2. then put them into an array separated by newline.
    ##    [discarding one space at the beginning of a line]
    ##
    if (( "$#" > 0 )); then 
	while IFS= read -r arguments; do
    	    while IFS=$'\n' read -r line; do
    		text_message+=("${line## }")
    	    done <<<"${arguments//\\n/$'\n'}"
	done <<<"$@"
    fi

    ## If standard input is a pipe,
    ## do the same as for the arguments, and append the
    ## piped in text to messages from the arguments
    ##
    if [[ -p /dev/stdin ]]; then
	while IFS= read -r pipe_text; do
    	    while IFS=$'\n' read -r line; do
    		text_message+=("${line# }")
    	    done <<<"${pipe_text//\\n/$'\n'}"
	done <<<"$(cat /dev/stdin)"
    fi
    
    ## Write to log if USE_LOGFILE or otherwise to stdout.
    ## When writing a log file only add the date (& time) for the first line of the entry.
    ##
    if $USE_LOGFILE; then
    	local date_string=$(date +"%F %R:%S")
    	for line in "${text_message[@]}"; do
    	    printf '%19s |  %s\n' "$date_string" "$line" >> "$LOGFILE"
    	    date_string=""    # only add the date to the first line.
    	done
	
    else
    	for line in "${text_message[@]}"; do
    	    printf '%s\n' "$line"
    	done
    fi    
}






function main() {
    echo "Entering function main()"  # XXX

    declare -i MAX_WAKEUP_WAIT=5        # how long to wait for the server 1 =~ 2 sec
    declare -i KEEP_N_BACKUPS=30        # number of backups before they will be overwritten
    local DB_FOLDER_PATH=".backup_db"   # path on server, file with backup dates for decision
                                        # which to delete next
    
    ## 'Global' Variables set by parse_arguments()
    ##
    local SOURCE_DIR
    local DESTINATION_DIR
    local EXCLUDE_FILE
    local SERVER_USER
    local SERVER_ADDRESS
    local SERVER_MAC
    local USE_LOGFILE=false
    local LOGFILE
    local RSYNC_LOG_FILE
    local SEND_NOTIFICATIONS=false
    local DRY_RUN=false

    ## container for the lock code (sleep-lock on server)
    ##
    local sleep_lock_code

    parse_arguments "$@"

    ## Show the chosen settings if --dry-run,
    ## or write to log file if --log-file
    ##
    declare -a used_settings

    used_settings+=("SETTINGS:\n")
    used_settings+=("source directory    = ${SOURCE_DIR}\n")
    used_settings+=("dest directory      = ${DESTINATION_DIR}\n")
    used_settings+=("user                = ${SERVER_USER}\n")
    used_settings+=("backup server       = ${SERVER_ADDRESS}\n")
    [[ ! -z "$SERVER_MAC" ]] &&
	used_settings+=("server mac address  = ${SERVER_MAC}\n")
    [[ ! -z "$EXCLUDE_FILE" ]] &&
	used_settings+=("rsync exclude file  = ${EXCLUDE_FILE}\n")
    used_settings+=("max wakeup wait     = ${MAX_WAKEUP_WAIT}\n")
    used_settings+=(">> on server >>\n")
    used_settings+=("db folder path      = ${DB_FOLDER_PATH}\n")
    used_settings+=("backups to keep     = ${KEEP_N_BACKUPS}\n")
    [[ ! -z "$RSYNC_LOG_FILE" ]] &&
	used_settings+=("rsync log file      = ${RSYNC_LOG_FILE}\n")
    used_settings+=(">> other >>\n")
    {
	local state;
	# notifications
	$SEND_NOTIFICATIONS && state="enabled" || state="disabled";
	used_settings+=("Sending of notifications is: ${state}\n");
	# wakeonlan
	[[ -z "$SERVER_MAC" ]] && state="disabled" || state="enabled"
	used_settings+=("WakeOnLAN is:                ${state}\n");
    }

    ## Print settings to screen or to log
    ##
    if $DRY_RUN || $USE_LOGFILE; then
	message "${used_settings[@]}"
    fi


    
    
    exit 0
}






## ENTRY POINT
##
main "$@"




























