#!/usr/bin/env bash

# @Name:         backup-to-server.bash
# @Author:       Tobias Marczewski
# @Last Edit:    2020-05-22
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
# attribution for notify icon
# Icons made by <a href="https://www.flaticon.com/authors/freepik" title="Freepik">Freepik</a> from <a href="https://www.flaticon.com/" title="Flaticon"> www.flaticon.com</a>
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

declare -a NOTIFICATION_ERROR_MSG

################################################################################
# Things to check even on an uncontrolled exit
#
# - if a sleep-lock is set on the server -> release it
#
function cleanup() {

    declare -i exit_status="$?"

    ## try to release a sleep lock
    ##
    if [[ ! -z "$USE_SLEEPLOCK" ]] &&
	   ( $USE_SLEEPLOCK ) &&
	   [[ ! -z "$sleep_lock_code" ]]
    then	
	    ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock release ${sleep_lock_code}"
    fi

    ## send a notification when exited on error
    ##
    if (( $exit_status != 0 )); then
	notification "Error during backup:" "${NOTIFICATION_ERROR_MSG[*]}" "error"
    fi	
}

trap cleanup EXIT


################################################################################
# Test if the passed argument is an integer.
#
# Arguments:
#   $1 - variable to test
#
# Returns:
#   0 - true - if the variable IS an integer
#   1 - false - if the variable is NOT and integer
#
function is_integer() {
        if [[ "$1" =~ ^-?[0-9]+$ ]]; then
	    return 0
	else
	    return 1
	fi
}

################################################################################
# Print the passed text to screen, broken on word boundaries to the
# specified line length, and with preceding space in each new line
# (if specified).
#
# Arguments:
#   $1   - The text to format [string]
#   $2   - line length [integer]
#   [$3] - preceding space for lines [integer, optional, default: 0]
#   [$4] - adjustment for first line [integer, optional, default: 0]
#          (this is basically the difference in characters that would
#           be needed to bring the first letter to start at the indent
#           of the other lines)
#          i.e.
#          >preceeding space<|TEXT
#
#          <other text>      |this here is the first line
#                            |this here is the second line
#                      ...... <- (adjustment to align first line = 6)
#
# Output:
#   Prints the formatted text to screen.
#
function print_formated_text() {
    local text
    declare -i line_length
    declare -i preceding_space
    declare -i space_adjust_first_line
    declare -a words

    if [[ -z "$1" ]]; then
	return
    fi

    if [[ -z "$2" ]]; then
	echo "print_formated_text Error: no line length passed!" >&2
	exit 1
    elif ( ! is_integer "$2" ); then
	echo "print_formated_text Error: line length not an integer!" >&2
	exit 1
    fi

    text="$1"
    line_length="$2"

    ## space on the left
    ##
    if [[ -z "$3" ]]; then
	preceding_space=0
    elif ( ! is_integer "$3" ); then
	echo "print_formated_text Error: preceeding space is not an integer!" >&2
	exit 1
    else
	preceding_space="$3"
    fi

    ## space adjustment for the first line
    ##
    if [[ -z "$4" ]]; then
	space_adjust_first_line=0
    elif ( ! is_integer "$4" ); then
	echo "print_formated_text Error: space adjustment for first line is not an integer!" >&2
	exit 1
    else
	space_adjust_first_line="$4"
    fi

    readonly text
    readonly line_length
    readonly preceding_space
    readonly space_adjust_first_line

    ## Split the text into separate words and put into an array.
    ## (keep escaped characters as is)
    ##
    read -ra words -d '' <<<"$text"

    ## write words until line length is reached, then break line
    ##
    declare -i current_line_length=0
    declare -i word_length

    ## if the first line has an indent, print it to screen
    ##
    current_line_length=$preceding_space
    
    if (( $space_adjust_first_line > 0 )); then
	printf "%${space_adjust_first_line}s" ""	
    elif (( $space_adjust_first_line < 0 )); then
	current_line_length=$(( ${current_line_length} - ${space_adjust_first_line} ))
    fi

    for word in "${words[@]}"; do

	word_length=$(expr length "$word")

	if (( $current_line_length + $word_length > $line_length )); then
	    printf "\n%${preceding_space}s" ""
	    current_line_length=$preceding_space
	fi
	
	printf "%s " "$word"
	current_line_length=$(( $current_line_length + $word_length ))
    done

    return 0
}



################################################################################
# Display usage information (-h, --help)
#
function usage() {
    local self="${0##*/}"
    local usage_info
    declare -a info
    local description
    declare -a examples
    usage_info="${self} [-h] [-v] [OPTIONS] SRC [[USER@]HOST:]DEST"

    info=(
	"-h, --help"
	"This information"
	"-v, --version"
	"Version of ${self}"
	"" ""
	"SRC"
	"The local source directory e.g. '/home/user'."
	"" ""
	"DEST"
	"The destination directory on the server.
	   For a local backup something like '/backup/my_backup_folder';
	   for a remote backup 'username@server:/backup/my_backup_folder' or 'server:backup'.
	   If no login user is specified, the username will default to \$USER."
	"" ""
	"OPTIONS:" ""
	"" ""
	"-w, --wake-on-lan"
	"Use 'wakeonlan' to wake the server if not reachable.
	   This option has to be followed by the MAC address of
	   the network device of the server.
	   (also see 'man wakeonlan')"
	"" ""
	"--max-wake-wait"
	"The maximum number of tries to perform when waking the
	   server (--wake-on-lan).
	   Every cycle takes about 2 seconds, hence 5 would mean wait 10 seconds before
	   giving up. [default: ${MAX_WAKEUP_WAIT}]"
	"" ""
	"-e, --exclude-file"
	"Path to the file which contains patterns to exclude from the backup
	   (also see 'rsync --exclude-from')."
	"" ""
	"-l, --log-file"
	"When specified the given /path/to/logfile will be used for log output."
	"" ""
	"--rsync-log-file"
	"If specified, a separate log (produced by rsync) will be written on the server.
	   path/to/the/logfile (on the server), also see 'rsync --remote-option=--log-file='."
	"" ""
	"--keep-n-backups"
	"Number of old backups to keep (see 'rsync --backup').
	   If daily backups are made this should be at least the number of days for which
	   a rollback may be required. [default: ${KEEP_N_BACKUPS}]"
	"" ""
	"--send-notifications"
	"(switch) Send notifications to the desktop when performing the backup?
	   These are 'started...' 'finished...' 'error...' (see 'man notify-send').
	   [default: false]"
	"" ""
	"--dry-run"
	"(switch) Only show the chosen settings and check the connectivity to the server,
	   but otherwise don't do anything. This doesn't test if rsync will run properly
	   as in 'rsync --dry-run'! [default: false]"
	"" ""
	"--use-sleeplock"
	"(switch) When waking a server via wake-on-lan that has autosuspend enabled,
	   use a sleep-lock? (has to be enabled on server - TODO see package XXX). [default: false]"
    )

    readonly description="\
	  This script is intended to be used to backup a local directory \
	       to a backup server. The used server has wake-on-lan with \
	       'magic packets' enabled, and can be expected \
	       to be suspended when this script is called. \
               Therefore, first it will be insured \
	       that the server is woken and reachable before starting an rsync backup. \
	       Furthermore, for a certain number of backups, copies of changed or \
	       deleted files will be kept in an '/old' folder, while the current state \
	       is saved in the folder '/current'. Hence the directory structure created \
	       will be 'DEST/old/<date>' and 'DEST/current'."

    examples=(
	"${self} -u joe@server -m 01:02:03:04:05:06 -l backup.log /from/here /to/there)"
	"${self} --server-user daisy --server-address 10.0.0.5 --server-mac 01:02:03:04:05:06 \
	  /home/daisy /backup/daisy)"
    )


    ## Print usage information
    ## left column - switch/argument
    ## right column - explanation
    ## - determine width of left column
    ## - print even indeces (0. 2 , 4...) starting at left margin
    ## - print odd indeces (1, 3, 5...) indented by the 'left column'
    ##
    local left    # text going into the respective column
    local right
    declare -i index=0
    declare -i print_width=80   # total print width of usage info
    declare -i left_column      # width of the left column
    declare -i left_diff        # left column width - current left sting length

    ## find the longest string in the left column
    ##
    left_column=0
    declare -i string_length

    while (( index < "${#info[@]}" )); do
	string_length=$(expr length "${info[$index]}")
	if (( $string_length > $left_column )); then
	    left_column=$string_length
	fi
	(( index+=2 ))
    done

    ## add some spacing between left and right column
    ##
    (( left_column+=2 ))

    ## reset the index we already used above
    ##
    index=0
    
    ## Print the info array (even indeces - left | odd - right)
    ##
    printf "\n"
    
    ## USAGE
    ##
    printf "USAGE:\n\n"
    print_formated_text "$usage_info" $print_width 2 2
    printf "\n\n\n"
    
    ## OPTIONS
    ##
    while (( $index < "${#info[@]}" )); do
	left="${info[$index]}"
	right="${info[$index+1]}"
	left_diff=$(( $left_column - $(expr length "$left") - 3 ))
	print_formated_text "$left" $print_width 2 2
	print_formated_text "$right" $print_width $left_column $left_diff
	printf "\n"
	(( index+=2 ))
    done

    ## DESCRIPTION
    ##
    printf "\nDESCRIPTION:\n\n"
    print_formated_text "$description" $print_width 2 2
    
    ## EXAMPLES
    ##
    printf "\n\nEXAMPLES:\n\n"
    
    for example in "${examples[@]}"; do
#	echo "$example"
	print_formated_text "$example" $print_width 2 2
	printf "\n\n"
    done
}

################################################################################
# Send text to stderr and (if USE_LOGFILE=true) to the log file.
#
# Arguments:
#   $1 -- text for the error message
#
# Global Variables:
#   NOTIFICATION_ERROR_MSG
#
# Returns:
#   nothing
#
function error() {
    local error_msg="$1"

    ## append message to the global error message string
    ##
    NOTIFICATION_ERROR_MSG+=("\n${error_msg}\n")
    
    if ( $USE_LOGFILE ); then
	message "[ERROR]: " "${error_msg}"
    else
	echo "Error: ${error_msg}" >&2	
    fi
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
#   USE_SLEEPLOCK
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
	exit 1
    fi
    
    local arguments
    arguments=$(getopt --options 'vhu:a:w:e:l:' \
		       --longoptions 'version,help,\
server-user:,server-address:,wake-on-lan:,\
exclude-file:,log-file:,rsync-log-file:,\
send-notifications,dry-run,use-sleeplock\
max-wake-wait:,keep-n-backups:'\
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
	    '-w'|'--wake-on-lan')
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
	    '--use-sleeplock')
		USE_SLEEPLOCK=true
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

    ## Check that no arguments are left
    ##
    if [[ ! -z "$1" ]]; then
	error "Unparsed argument: ${1}"
	return 1
    fi

    
    ## Check the validity of all arguments
    ##

    ## 1) SRC
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

    readonly SOURCE_DIR
    
    ## 2) DEST
    ##
    if [[ -z "$DESTINATION_DIR" ]]; then
	error "No DEST specified, see ${0} --help for usage."
	return 2
    fi

    ## split DEST into parts for
    ## SERVER_USER
    ## SERVER_ADDRESS
    ## DESTINATION_DIR
    ##
    ## Is a remote DEST specified?
    ##
    if [[ -n "${DESTINATION_DIR//[^:]}" ]]; then
	SERVER_ADDRESS="${DESTINATION_DIR%:*}"
	DESTINATION_DIR="${DESTINATION_DIR#*:}"
    fi

    ## Is a user@host specified?
    ##
    if [[ -n "${SERVER_ADDRESS//[^@]}" ]]; then
	SERVER_USER="${SERVER_ADDRESS%@*}"
	SERVER_ADDRESS="${SERVER_ADDRESS#*@}"
    else
	SERVER_USER="$USER"
    fi
    
    ## Remove trailing slashes
    ##
    DESTINATION_DIR="${DESTINATION_DIR%%+(/)}"

    ## Remove a leading ~/ if present
    ##
    DESTINATION_DIR="${DESTINATION_DIR#\~/}"

    readonly DESTINATION_DIR
    readonly SERVER_ADDRESS
    readonly SERVER_USER

    ## If a mac for wake-on-lan was provided, is it valid,
    ## and is wakeonlan installed?
    ##
    if [[ ! -z "$SERVER_MAC" ]]; then
	
	declare -r mac_regex='^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
	if (( $(echo "${SERVER_MAC}" | grep -cP "$mac_regex") != 1 )); then
	    error "The provided MAC address for WakeOnLAN: ${SERVER_MAC} is not a valid MAC."
	    return 2
	fi

	if (! is_installed wakeonlan); then
	    error "WakeOnLAN was enabled, however, the package 'wakeonlan' does not seem to be installed." \
		  "Please install it before proceeding 'apt install wakeonlan'"
	    return 1
	fi
    fi
    
    readonly SERVER_MAC

    ## If the backup is local or the server is not woken, ignore
    ## an enabled sleeplock setting
    ##
    if [[ -z "$SERVER_ADDRESS" ]] || [[ -z "$SERVER_MAC" ]]; then
	USE_SLEEPLOCK=false
    fi
    readonly USE_SLEEPLOCK
    
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
    if (( "$KEEP_N_BACKUPS" < 0 )); then
	KEEP_N_BACKUPS=0
    fi

    if (( "$MAX_WAKEUP_WAIT" < 1 )); then
	MAX_WAKEUP_WAIT=0
    fi

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
	error "Could not find 'rsync', please install it before proceeding."
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
    if ( $DRY_RUN ) && ( $USE_LOGFILE ); then
	local date_string=$(date +"%F %R:%S")
	echo "Would be written to: ${LOGFILE}"
    	for line in "${text_message[@]}"; do
    	    printf '%19s |  %s\n' "$date_string" "$line"
    	    date_string=""    # only add the date to the first line.
    	done
	echo ""
	
    elif ( $USE_LOGFILE ) && [[ ! -z "$LOGFILE" ]]; then
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
# Send a notification to the user via a popup.
# Produces a notification popup for the currently logged-in user who
# is using a display.
#
# Depends:
#   notify-send
#
# Arguments:
#   $1 - Summary (the 'header' shown) for the notification [string]
#   $2 - Body of the notification message [string]
#   $3 - Icon (name of icon to use) [optional]
#
# Global Variables:
#   DISPLAY
#   DBUS_SESSION_BUS_ADDRESS
#   SEND_NOTIFICATIONS
#
# Output:
#   none (apart from the popup)
#
function notification() {

    ## Only send notifications when enabled
    ##
    if (! $SEND_NOTIFICATIONS ); then
	return 0
    fi
    
    local summary
    local body
    local icon

    if [[ -z "$1" ]] || [[ -z "$2" ]]; then
	echo "notification() Error: not enough arguments passed!"
	exit 1
    fi

    readonly summary="$1"
    readonly body="$2"

    ## Set icon if provided or otherwise default
    ##
    if [[ ! -z "$3" ]]; then
	icon="$3"
    else
	icon="drive-harddisk"
    fi
    
    ## Under certain circumstances it can happen that for the user running
    ## this script DISPLAY or DBUS_SESSION_BUS_ADDRESS are not set.
    ## (e.g. when running as an anacron job)
    ## Therefore, we test if those are set and if not, try to assign
    ## the display and dbus_session_bus_address of a/the logged in user.
    ## Note:
    ## Especially were the dbus for the user is registered varies between
    ## different DEs (Distros?) and I am not sure if the approach immplemented
    ## here will work for all, so this might be a FIXME.
    ##
    local active_display
    local user
    local uid
    local dbus_session_bus_address
    
    if [[ -z "$DISPLAY" ]] || [[ -z "$DBUS_SESSION_BUS_ADDRESS" ]]; then
	
	## Check if the glob pattern matches anything at all
	##
	if ( ! compgen -G /tmp/.X11-unix/X* >/dev/null ); then
	    error "could not find display for notification. [notification]"
	    return 1
	fi
	local connected_displays
	connected_displays=(/tmp/.X11-unix/X*)

	## Look which of the connected displays is assigned to a user
	##
	for display in "${connected_displays[@]##*/}"; do
	    if (( $(who | grep -c "${display/X/:}") > 0 )); then
		active_display="${display/X/:}"
		user=$(who | grep "(${active_display})" | awk '{print $1}')
		uid=$(id -u "$user")
		(( "$?" == 0 )) && break
	    fi
	done

	## Ensure we got a uid, otherwise we can't continue
	##
	if [[ -z "$uid" ]]; then
	    error "could not determine which display is assigned to a user. [notification]"
	    return 1
	fi

	## Set the dbus to use
	##
	if [[ -S "/run/user/${uid}/bus" ]]; then
	    dbus_session_bus_address="unix:path=/run/user/${uid}/bus"
	    
	elif [[ -f "/run/user/${uid}/dbus-session" ]]; then
	    dbus_session_bus_address=$(sed -r 's/DBUS_SESSION_BUS_ADDRESS=(.*)/\1/' \
 					   "/run/user/$uid/dbus-session")
	else
	    error "could not find the correct dbus_session_bus_address. [notification]"
	    return 1
	fi
    else
	active_display="$DISPLAY"
	dbus_session_bus_address="$DBUS_SESSION_BUS_ADDRESS"
    fi

    ## Send a notification in a subshell, where the parameters are
    ## ensured to be set.
    ##
    (
	DISPLAY="$active_display"
	DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus_address"
	notify-send --icon="$icon" "$summary" "$body"
    )
    
    return 0
}

################################################################################
# Print the current settings to screen or to log file.
#
# Arguments:
#   none
#
# Global Variables:
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
	# sleep-lock
	$USE_SLEEPLOCK && state="enabled" || state="disabled"
	used_settings+=("Setting a sleep-lock is:     ${state}\n");
    }

    ## Print settings to screen or to log
    ##
    ( $DRY_RUN ) && echo ""
    if ( $DRY_RUN || $USE_LOGFILE ); then
	message "${used_settings[@]}"
    fi
    ( $DRY_RUN ) && echo ""

    return 0
}    


################################################################################
# Check if the passed argument is an IPv4 address in the range
# 0.0.0.0 - 255.255.255.255
#
# Arguments:
#   $1 - string to check
#
# Returns:
#   0 - true - if the passed string IS an IPv4 address
#   1 - false - if NOT
#
function is_ipv4() {
    declare -a -i fields
    IFS='.' read -ra fields <<<"$1"

    if (( "${#fields[@]}" != 4 )); then
	return 1
    fi
    
    for field in "${fields[@]}"; do
	if (( "$field" < 0 )) || (( "$field" > 255 )); then
	    return 1
	fi
    done

    return 0
}

################################################################################
# Check if the provided hostname can be resolved (by systemd-resolve
#
# Arguments:
#   $1 - hostname to test
#
# Returns:
#   0 - true - if the passed hostname is already a valid ipv4 address, or
#              if the passed hostname could be successfully resolved
#   1 - false - otherwise
#
function can_resolve_hostname() {
    local hostname
    declare -i count

    if [[ -z "$1" ]]; then
	echo "can_resolve_hostname Error: no argument passed!" >&2
	exit 1
    fi
    
    readonly hostname="$1"

    ## If already an ip, we do not have to resolve it
    ##
    if ( is_ipv4 "$hostname" ); then
	return 0
    fi
    
    ## Ensure systemd-resolved service is running
    ##
    count=0
    while ( ! $(systemctl is-active --quiet systemd-resolved.service) ) &&
	      (( $count < 3 ))
    do
	systemctl start systemd-resolved.service && sleep 2
    done

    if ( ! $(systemctl is-active --quiet systemd-resolved.service) ); then
	error "Can't get systemd-resolved.service started."
	return 1
    fi

    ## Test if we can resolve the hostname
    ##
    if $(systemd-resolve "$hostname" &>/dev/null); then
	return 0
    else
	return 1
    fi
}

################################################################################
# Check if the specified server is reachable and ssh is listening on port 22.
# If necessary wake it via wakeonlan, if a MAC was provided.
#
# Arguments:
#   none
#
# Global Variables:
#   MAX_WAKEUP_WAIT
#   SERVER_ADDRESS
#   SERVER_MAC
#   SERVER_USER
#
# Returns:
#   0 - success - when server is reachable and user@server can ssh into it
#   1 - failure - when server is NOT reachable
#
function server_connection_ok() {

    ## If the provided server address is not an ip address
    ## check that systemd-resolve can resolve it, as this
    ## is most commonly an error on local networks.
    ##
    if ( ! can_resolve_hostname "$SERVER_ADDRESS" ); then
	error "The passed server address: ${SERVER_ADDRESS} \
is not a valid ip, and as hostname can't be \
resolved by systemd-resolve."
	return 1
    fi
    
    ## 1) Check that the network interface is working
    ##
    if ( ! ping -c 1 localhost &>/dev/null ); then
	error "Problem with network settings, can't reach localhost!"
	return 1
    fi

    ## 2) Insure that server is online
    ##
    local server_online=false
    
    if (ping -c 3 "$SERVER_ADDRESS" &>/dev/null); then
	server_online=true
    fi
    
    ## 2a) Wake up if WakeOnLAN enabled
    ##
    if ( ! $server_online ) && [[ ! -z "$SERVER_MAC" ]]; then
	message "Server not reachable, trying to wake it up."
	
	declare -i counter=0
	while ( ! $server_online ) && (( counter <= $MAX_WAKEUP_WAIT )); do
	    wakeonlan "$SERVER_MAC" &>/dev/null
	    sleep 2
	    (( counter++ ))
	    if ( ping -c 3 "$SERVER_ADDRESS" &>/dev/null ); then
		server_online=true
	    fi
	done
    fi

    ## Check final reachability
    ##
    if ( ! $server_online ); then
	error "No reply when pinging server."
	return 1
    fi

    ## 3) Ensure ssh is working
    ##
    if ( ! nc -zw 2 "$SERVER_ADDRESS" 22 &>/dev/null ); then
	error "No ssh service detected on port 22 of ${SERVER_ADDRESS}."
	return 1
    fi

    ## 4) Ensure that provided user@host can log into server
    ##
    local msg
    declare -i exit_status
    msg=$(ssh -o BatchMode=yes -T "${SERVER_USER}@${SERVER_ADDRESS}" 'exit' 2>&1)
    exit_status="$?"

    if (( "$exit_status" > 0 )); then
	## FIXME when failing, the ssh command also returns a weird return character
	## which seems to be at the beginning of msg, and leads to deletion of
	## text being written before the variable.
	## Therefore, remove this unknown beginning to avoid strange effects.
	##
	msg="${msg#*[^a-zA-Z]}"
	error $(printf "Can't connect via ssh: %s\n" "${msg}")
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
# Enable a sleep-lock if requested.
#
# Arguments:
#   none
#
# Global Variables:
#   DESTINATION_DIR
#   RSYNC_LOG_FILE
#   USE_SLEEPLOCK
#   backup_folder
#   current_folder
#   sleep_lock_code
#
# Depends:
#   execute_on_host()
#
# Returns:
#   Exit status of last command run on host
#
function pre_backup_setup() {

    local cmd_string
    local lock_state

    ## Enable a sleep lock on the server and save the code
    ##
    if ($USE_SLEEPLOCK); then
	sleep_lock_code=$(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock enable")
	lock_state=$(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock check $sleep_lock_code")
	## Check that setting successful
	##
	if [[ "$lock_state" == "active" ]]; then
	    message "Enabled sleep lock on server, code: $sleep_lock_code"
	else
	    error "Could not enable sleep lock for server."
	    return 1
	fi
    fi
    
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
    
    return "${PIPESTATUS[0]}"
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

################################################################################
# Delete old incremental backups (rsync --backup) if more than specified
# are present on the host; Disable a sleep-lock if set.
#
# Arguments:
#   none
#
# Global Variables:
#   DESTINATION_DIR
#   KEEP_N_BACKUPS
#   USE_SLEEPLOCK
#   backup_folder
#   sleep_lock_code
#
# Depends:
#   execute_on_host()
#
# Returns:
#   Exit status of the last command run on host
#
function post_backup_cleanup() {

    declare -i exit_status=0
    local lock_state
    local cmd_string

    ## Remove old backups if present on the host
    ##
    read -r -d '' cmd_string <<-EOF    
    ## List all folders of previous backups
    ##
    declare -a folders=("${DESTINATION_DIR}"/"${backup_folder}"/*)

    ## Sort the dates (old -> recent)
    ##
    read -a sorted_dates < <(sort <<<"\${folders[@]##*/}")

    ## Remove older backups if more are present than requested
    ##
    declare -i count=0
    declare -a deleted_folders
    
    while (( \${#sorted_dates[@]} - \$count > $KEEP_N_BACKUPS )); do
	rm -rf "${DESTINATION_DIR}"/"${backup_folder}"/"\${sorted_dates[\${count}]}"
	deleted_folders+=("\${sorted_dates[\${count}]}")
	(( count++ ))
    done

    ## Output for log if old folders were deleted
    ##
    if (( "\${#deleted_folders[@]}" > 0 )); then
	echo "Deleted following old backups:"
	echo "\${deleted_folders[@]}"
    fi
''
EOF

    execute_on_host "${cmd_string}" | message
    exit_status="${PIPESTATUS[0]}"

    ## Disable a sleep-lock if set
    ##
    if ($USE_SLEEPLOCK); then
	ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock release ${sleep_lock_code}"
	lock_state=$(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock check ${sleep_lock_code}")
	# check that successful
	if [[ "$lock_state" == "inactive" ]]; then
	    unset sleep_lock_code
	else
	    error "Could not release sleep lock for server"
	    exit_status=1
	fi
    fi
    
    return $exit_status
}

################################################################################
# Encapsulate the main logic of the script here to be able to keep most
# variables local.
#
function main() {

    declare -r VERSION="0.9"
    
    declare -i MAX_WAKEUP_WAIT=5        # how long to wait for the server 1 =~ 2 sec
    declare -i KEEP_N_BACKUPS=30        # number of backups before they will be overwritten
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
    local USE_SLEEPLOCK=false
    # container for the sleep lock code, not set by parse_arguments()
    local sleep_lock_code
    
    ## Set variables according to arguments and check their validity.
    ## Also check that all needed dependencies are installed.
    ##
    parse_arguments "$@"

    if (( "$?" != 0 )); then
	error "while parsing arguments."
	exit 1
    fi

    ## notification START
    ##
    notification "Backup started" "starting backup of ${SOURCE_DIR}"

    
    ## Print settings to log (or to screen if --dry-run)
    ##
    print_settings

    
    ## If not performing a local backup,
    ## make sure we can reach the server, (and ssh is enabled).
    ##
    if [[ ! -z "$SERVER_ADDRESS" ]]; then
	## !! don't put server_connection_ok in a subshell as otherwise
	## the text to NOTIFICATION_ERROR_MSG will not be appended
	##
	if server_connection_ok; then
	    message "server is reachable"
	else
	    error "Failed to connect to server."
	    exit 1
	fi
    fi

    ## Exit here when performing a dry-run
    ##
    if ( $DRY_RUN ); then
	exit 0
    fi

    
    ## Setup everything for the backup
    ## [ enable sleep_lock ]
    ## 
    pre_backup_setup

    if (( "$?" != 0 )); then
	error "while setting pre-requisites on host."
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
    ## [ disable sleep_lock ]
    ##
    post_backup_cleanup


    ## notification FINISH
    ##
    notification "Backup finished" "Successfully finished backup of ${SOURCE_DIR}"

    exit 0
}



## ENTRY POINT
##
main "$@"

