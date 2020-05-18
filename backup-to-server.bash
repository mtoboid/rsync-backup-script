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
# Send text to stderr and (if USE_LOGFILE=true) to the log file.
#
# Arguments:
#   $1 -- text for the error message
#
# Returns:
#   nothing
#
function error() {
    local text="$1"
    
    echo "Error: ${text}" >&2
    
    if ($USE_LOGFILE); then
	message "[ERROR]: " "${text}"
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
# Returns:
#   0 - success - all arguments were successfully parsed,
#                 and settings are valid
#   1 - on error
#   2 - invalid setting
#
function parse_arguments() {

    if [[ -z "$1" ]]; then
	error "No arguments provided, see ${0} --help for usage."
	return 1
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
        error "Unexpected getopt error while  parsing arguments."
	return 1
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
		error "Internal error! (parsing arguments)"
		return 1
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
	error "No SRC specified, see ${0} --help for usage."
	return 2
    elif [[ ! -d "$SOURCE_DIR" ]]; then
	error "Source dir ${SOURCE_DIR} not found."
	return 2
    elif [[ ! -r "$SOURCE_DIR" ]] || [[ ! -x "$SOURCE_DIR" ]]; then
	error "No read permission for SRC - ${SOURCE_DIR}"
	return 2
    fi

    if [[ -z "$DESTINATION_DIR" ]]; then
	error "No DEST specified, see ${0} --help for usage."
	return 2
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
    
    ## Was user@server provided?
    ## check if '@' in SERVER_USER, and if so
    ## split into 'SERVER_USER'@'SERVER_ADDRESS'
    ##
    if [[ -z "$SERVER_ADDRESS" ]] && [[ -n "${SERVER_USER//[^@]}" ]]; then
	SERVER_ADDRESS="${SERVER_USER#*@}"
	SERVER_USER="${SERVER_USER%@*}"
    fi

    declare -r mac_regex='^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
    if [[ ! -z "$SERVER_MAC" ]] &&
	   (( $(echo "${SERVER_MAC}" | grep -cP "$mac_regex") != 1 ))
    then
	error "The provided MAC address ${SERVER_MAC} is not a valid MAC."
	return 2
    fi

    ## Insure that 'wakeonlan' is installed when a server mac is provided
    ##
    if (! is_installed wakeonlan); then
	error "A MAC address for the server was provided," \
	     "implying that WakeOnLAN should be used." \
	     "However, the package 'wakeonlan' does not seem to be installed." \
	     "Please install it before proceeding 'apt install wakeonlan'"
	return 1
    fi
    
    readonly SERVER_USER
    readonly SERVER_ADDRESS
    readonly SERVER_MAC
    
    ## 3) Log
    ##
    if ( $USE_LOGFILE ); then
	if [[ -z "$LOGFILE" ]]; then
	    error "No logfile provided see ${0} for usage."
	    return 2
	elif ( ! touch "$LOGFILE" &>/dev/null ); then
	    error "Can't create or write to logfile: ${LOGFILE}."
	    return 1
	fi
    fi
    
    readonly USE_LOGFILE
    readonly LOGFILE

    ## 4) Exclude file
    ##
    if [[ ! -z "$EXCLUDE_FILE" ]] && [[ ! -r "$EXCLUDE_FILE" ]]; then
	error "Can't read exclude file: ${EXCLUDE_FILE}"
	return 1
    fi

    ## 5) Settings with default values
    ##
    if [[ -z "$DB_FOLDER_PATH" ]]; then
	error "Invalid setting: db-folder path was unset."
	return 1
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
    if ( $SEND_NOTIFICATIONS ) && (! is_installed notify-send); then
	error "Notifications are enabled, but 'notify-send' is not available." \
	      "Please install 'libnotify-bin' before proceeding."
	return 1
    fi
    
    readonly SEND_NOTIFICATIONS
    readonly DRY_RUN

    ## Ensure rsync is installed
    ##
    if (! is_installed rsync); then
	error "Did not find 'rsync', please install it before proceeding."
	return 1
    fi
    
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
#   DRY_RUN
#   USE_LOGFILE
#   LOGFILE
#
# Output:
#   Text written to screen OR to log file.
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
    if ($DRY_RUN && $USE_LOGFILE); then
	local date_string=$(date +"%F %R:%S")
	echo "Would be written to: ${LOGFILE}"
	echo ""
    	for line in "${text_message[@]}"; do
    	    printf '%19s |  %s\n' "$date_string" "$line"
    	    date_string=""    # only add the date to the first line.
    	done
	
    elif ($USE_LOGFILE); then
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

################################################################################
# Print the current settings to screen or to log file.
#
# Arguments:
#   none
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
# Output:
#   if USE_LOGFILE=true -- to log file ($LOGFILE)
#   if DRY_RUN=true     -- only to screen (even if USE_LOGFILE=true)
#   else none
#
function print_settings() {
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
	used_settings+=("WakeOnLAN is:                ${state}");
    }

    ## Print settings to screen or to log
    ##
    ($DRY_RUN) && echo ""
    if ($DRY_RUN || $USE_LOGFILE); then
	message "${used_settings[@]}"
    fi
    ($DRY_RUN) && echo ""

    return 0
}    

################################################################################
# Check if the specified server is reachable and ssh is listening on port 22.
# If necessary wake it via wakeonlan, if a MAC is provided as second argument. 
#
# Arguments:
#   $1 - the hostname or ip address of the server
#   $2 - the MAC address of the network device for wakeonlan [optional]
#
# Global Variables:
#   MAX_WAKEUP_WAIT
#
# Returns:
#   0 - success - when server is reachable
#   1 - failure - when server is NOT reachable
#
function server_is_reachable() {

    local hostname
    local mac_address

    if [[ -z "$1" ]]; then
	echo "server_is_reachable() Error: no hostname provided." >&2
	exit 1
    fi

    readonly hostname="$1"
    readonly mac_address="$2"

    ## 1) Check that network interface is working
    ##
    if ( ! ping -c 1 localhost &>/dev/null ); then
	error "Problem with network settings, can't reach localhost!"
	return 1
    fi

    ## 2) Insure that server is online
    ##
    local server_online=false
    
    if (ping -c 3 "$hostname"); then
	server_online=true
    fi
    
    ## 2a) Wake up if WakeOnLAN enabled
    ##
    if ( ! $server_online ) && [[ ! -z "$mac_address" ]]; then
	message "Server not reachable, trying to wake it up."
	
	declare -i counter=0
	while ( ! $server_online ) && (( counter <= $MAX_WAKEUP_WAIT )); do
	    wakeonlan "$mac_address" &>/dev/null
	    sleep 2
	    (( counter++ ))
	    if ( ping -c 3 "$hostname" &>/dev/null ); then
		server_online=true
	    fi
	done
    fi

    ## Check final reachability
    ##
    if ( $server_online ); then
	message "Server at ${hostname} is reachable."
    else
	error "Failed to connect to server."
	return 1
    fi

    ### FIXME not needed when localhost
    ## 3) make sure ssh is working
    ##
    if ( ! nc -zw 2 "$hostname" 22 &>/dev/null ); then
	error "No ssh service detected on port 22 of ${hostname}."
	return 1
    fi

    return 0
}

################################################################################
# Execute the passed commands either on a server via ssh,
# or on the current machine.
#
# Arguments:
#   $1 - The commands to execute [string]
#
# Global Variables:
#   SERVER_USER
#   SERVER_ADDRESS
#
# Returns:
#   The exit status of the last command run on the server.
#
function execute_on_host() {

    if [[ -z "$1" ]]; then
	echo "execute_on_host() Error: no argument provided!" >&2
	exit 1
    fi
    
    declare -r exec_command="$1"
    declare -a use_command

    ## Switch between local and ssh use
    ## (to test $SERVER_USER here is ok, as this should be set to
    ##  $USER by parse_arguments() if not specified explicitly.)
    ##
    if [[ ! -z "$SERVER_ADDRESS" ]] && [[ ! -z "$SERVER_USER" ]]; then
	use_command=(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}")
    else
	use_command=(bash -c)
    fi
    
    "${use_command[@]}" "eval '${exec_command}'"
    
    return
}

################################################################################
# Setup everything on the host so that the rsync command can run.
# Ensure all directories & files needed are present & accessabe on the host.
# Also move logfiles to next number and delete old ones. 
#
# Arguments:
#   none
#
# Global Variables:
#   DB_FOLDER_PATH
#   DESTINATION_DIR
#   RSYNC_LOG_FILE
#   backup_folder
#   current_folder
#   db_file
#
# Depends:
#   execute_on_host()
#
# Returns:
#   Exit status of last command run on host
#
function pre_backup_setup() {

    local cmd_string

    ## Ensure that following exist:
    ## > the folder and file for the backup-db
    ## > the folder structure for the rsync backups
    ##   <DESTINATION_DIR>--+--current
    ##                      |
    ##                      +--old
    ## [if logging on the server is enabled]
    ## > the folder for the rsync logs on the server
    ## > (additionally) move logs to keep the last 10
    ##
    read -r -d '' cmd_string <<-EOF    
    ## utility function to save some code
    ##
    function ensure_exists() {
    	if [[ -z "\$1" ]]; then
    	   echo "ensure_exists() Error: no argument passed!" >&2
    	   exit 1
    	fi
    	local directory="\$1"

	if [[ -e "\${directory}" ]] && [[ ! -d "\${directory}" ]]; then
    	    echo "Error: \${directory} does exist but is no directory." >&2
    	    exit 1
	else
	    mkdir -p "\${directory}" ||
	    { echo "Error creating directory \${directory}."; exit 1; }
	fi
	return 0
    }

    ## backup-db
    ##    
    ensure_exists "${DB_FOLDER_PATH}"
    touch "${db_file}"
    if [[ ! -r "$db_file" ]] || [[ ! -w "$db_file" ]]; then 
    	echo "Error no read/write permission for ${db_file}" >&2
        exit 1
    fi

    ## rsync folder-structure
    ##
    ensure_exists "${DESTINATION_DIR}/${current_folder}"
    ensure_exists "${DESTINATION_DIR}/${backup_folder}"

    ## logging on the server:
    ##
    if [[ ! -z "$RSYNC_LOG_FILE" ]]; then
    	## ensure log dir exists
    	##
    	ensure_exists "${RSYNC_LOG_FILE%/*}"
    	## move logs to keep 10 (remove nr. 10)
    	##
    	if [[ -e "${RSYNC_LOG_FILE}.10" ]]; then
    	    rm "${RSYNC_LOG_FILE}.10" ||
    		{ echo "Error removing logfile ${RSYNC_LOG_FILE}.10" >&2; exit 1; }
    	fi
    	## move existing logs one number up
    	##
    	for i in {9..0} ; do
    	    if [[ -e "${RSYNC_LOG_FILE}.\$i" ]]; then
    		mv "${RSYNC_LOG_FILE}.\$i" "${RSYNC_LOG_FILE}.\$((\$i + 1))" ||
    		    { echo "Error moving logfile ${RSYNC_LOG_FILE}.\$1 to \$((\$i + 1))" >&2; exit 1; }
    	    fi
    	done
    	## move current log to number 0
    	##
    	if [[ -e "${RSYNC_LOG_FILE}" ]]; then
    	    mv "${RSYNC_LOG_FILE}" "${RSYNC_LOG_FILE}.0" ||
    		{ echo "Error moving logfile ${RSYNC_LOG_FILE} to .0" >&2; exit 1; }
    	fi
    fi
''
EOF

    execute_on_host "${cmd_string}" | message
    
    return
}

################################################################################
# Run rsync with the specified options set.
#
# Arguments:
#   none
#
# Global Variables:
#   DESTINATION_DIR
#   EXCLUDE_FILE
#   RSYNC_LOG_FILE
#   SERVER_ADDRESS
#   SERVER_USER
#   SOURCE_DIR
#   backup_folder
#   current_date
#   current_folder
#
# Returns:
#   The exit status of the rsync command.
#
function run_rsync() {

    declare -a rsync_opts
    
    ## Build the options for rsync
    ## Note append arguments separately to options as e.g.
    ## +=("--delete --delete-excluded") would be parsed as a single argument,
    ## use +=("--delete" "--delete-excluded") -- note the double quotes!

    ## Archive and compress
    ##
    rsync_opts+=("-az")

    ## Honour an exclude file if provided
    ##
    [[ ! -z "$EXCLUDE_FILE" ]] &&
	rsync_opts+=("--exclude-from=${EXCLUDE_FILE}")

    ## Set to delete and make backups
    ## to achive wanted behaviour for incremental backups
    ##
    rsync_opts+=("--delete" "--delete-excluded" "--delete-delay")
    rsync_opts+=("--backup" "--backup-dir=../${backup_folder}/${current_date}")

    ## If logging for the rsync process is wanted to that on the host.
    ## Set the log file path differently when not making backups to a remote server
    ##
    if [[ ! -z "$RSYNC_LOG_FILE" ]]; then
	if [[ ! -z "$SERVER_ADDRESS" ]]; then
	    rsync_opts+=("--remote-option=--log-file=${RSYNC_LOG_FILE}")
	else
	    rsync_opts+=("--log-file=${RSYNC_LOG_FILE}")
	fi
    fi

    ## Set SRC, and DEST according to if making a local or a remote backup
    ##
    rsync_opts+=("${SOURCE_DIR}")
    
    if [[ ! -z "$SERVER_ADDRESS" ]]; then
	rsync_opts+=("${SERVER_USER}@${SERVER_ADDRESS}:${DESTINATION_DIR}/${current_folder}")
    else
	rsync_opts+=("${DESTINATION_DIR}/${current_folder}")
    fi

    ## Run rsync with the set options
    ##
    rsync "${rsync_opts[@]}"
    
    return
}




### TODO ###
function post_backup_cleanup() {
    return 0
}



function main() {
    echo "Entering function main()"  # XXX

    declare -i MAX_WAKEUP_WAIT=5        # how long to wait for the server 1 =~ 2 sec
    declare -i KEEP_N_BACKUPS=30        # number of backups before they will be overwritten
    local DB_FOLDER_PATH=".backup_db"   # path on server, file with backup dates for decision
                                        # which to delete next
    local backup_folder="old"           # name for the subfolder with the kept dates
    local current_folder="current"      # name for the subfolder with the most up to date backup
    local current_date=$(date +"%Y-%m-%d")
    readonly backup_folder
    readonly current_folder
    readonly current_date
    
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

    ## Container for the lock code (sleep-lock on server)  XXX put as global and trap on exit??
    ##
    local sleep_lock_code

    ## ensure rsync is installed
    ##
    if (! is_installed rsync); then
	error "No rsync found, please run 'apt install rsync' before continuing."
	exit 1
    fi
    
    ## Set variables according to arguments and check their validity
    ##
    parse_arguments "$@"

    if (( "$?" != 0 )); then
	error "while parsing arguments."
	exit 1
    fi
    

    ## Print settings to log (or to sreen if --dry-run)
    ##
    print_settings

    ## Make sure we can reach the server, (and ssh is enabled)
    ##
    if ( ! server_is_reachable "$SERVER_ADDRESS" "$SERVER_MAC" ); then
	error "could not connect to server." >&2
	exit 1
    fi

    ## Setup everything for the backup
    ## 

    ## For incremental backups (rsync with backup and --backup-dir)
    ## with a 'rolling cycle' (only keeping the last 'n' backups)
    ## but kept in folders labeled by date, it is necessary to store a file with
    ## the file names (= dates) of previously performed and kept backups.
    ## Entries will be appended to this file, and if the list gets longer than
    ## 'n' entries, folders matching the string from the top of the file will be
    ## deleted.
    ## From a design perspective this 'database structure' is envisaged to have two levels:
    ## 1) a folder with the same name as the backing up client ($HOSTNAME) which is
    ##    added outside this script in the calling script to retain flexibility for
    ##    other possible setups.
    ## and within this
    ## 2) backup.history files to store the dates for backups (folders in 'old')
    ## Of these, more than one file would only be needed if two different types of backup are
    ## being run to the same server (e.g. one for /home/betty and another for /home/joe).
    ## In this way (if clientnames are unique) using the SRC and DEST to build the filename
    ## for the db_file ensures unambiguous db names.
    ##
    local db_file
    db_file="${DB_FOLDER_PATH}/${SOURCE_DIR//\/%%}@@${DESTINATION_DIR//\/%%}.backup.history"
    readonly db_file

    ## TODO enable sleep lock TODO
    pre_backup_setup

    if (( "$?" != 0 )); then
	error "while checking pre-requisites on host."
	exit 1
    fi

    ## Make the backup via rsync
    ##
    run_rsync

    if (( "$?" != 0 )); then
	error "rsync finished with exit status $?."
	exit 1
    else
	message "Backup: rsync finished successfully."
    fi

    ## Update the database and delete the oldest backup
    ##
    post_backup_cleanup

    ## TODO disable sleep lock ##

    
    exit 0
}






## ENTRY POINT
##
main "$@"




























