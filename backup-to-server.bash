#! /usr/bin/env bash

# @Name:         backup-to-server.bash
# @Author:       Tobias Marczewski
# @Last Edit:    2020-02-04
VERSION="1.1.9"
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


# How long to wait for the server to wake up before giving up
# a value of 1 ~ 2sec, hence 5 ~ 10sec
MAX_WAKEUP_WAIT=5
DB_FOLDER_PATH=".backup_db"
KEEP_N_BACKUPS=30

# set by arguments when calling the script
unset SOURCE_DIR
unset DESTINATION_DIR
unset EXCLUDE_FILE
unset SERVER_USER
unset SERVER_ADDRESS
unset SERVER_MAC
USE_LOGFILE=false
unset LOGFILE
unset RSYNC_LOG_FILE

# container for the lock code (sleep-lock on server)
unset sleep_lock_code

# FUNCTION VARIABLES -----------------------------------------------------------
# global variables needed for certain functions. Where the variable is only
# ever used by a certain function, it is defined just above that function with
# the tag VAR

# file for transfer of progress info from rsync to display_progress()
progress_file=$(tempfile --prefix="backup_to_server_progress_file_")


# FUNCTIONS --------------------------------------------------------------------

# cleanup()
# run just before exiting to remove leftovers...
#
function cleanup() {
    display_progress "stop"
    rm "$progress_file"
    if [ ! -z "$sleep_lock_code" ] ; then
	ssh "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock release $sleep_lock_code"
    fi
}

trap cleanup EXIT


# usage()
# displayed for -h, --help
# print usage information for the script
#
function usage() {
    self="${0##*/}"
    arr_usage=("" ""
	       "Usage: ${self} [-h] [-v] ARGUMENTS [OPTIONS] SRC DEST" ""
               "" ""
	       "" ""
	       "-h, --help"    "This information"
	       "-v, --version" "Version number"
	       "" ""
	       "" ""
	       "  All arguments are in the form '-s <value>' or '--switch <value>'" ""
	       "" ""
	       "ARGUMENTS" ""
	       "-u, --server-user"
	          "Login username for the server."
	       "" "This user has to be able to login via ssh without password"
	       "" "identification, which normally means that key based"
	       "" "authetication has to have been set up for this user."
	       "" "It is possible to specify"
	       "" "1) user and hostname together: '-u user@hostname'   OR"
	       "" "2) only the username:          '-u user'"
	       "" "For (2) the hostname has to be provided with '-a hostname'."
	       "" "Even when user@host is provided, the hostname/ip"
	       "" "provided with -a takes precedence!"
	       "" "An identity file (ssh -i) will not be passed, rather use"
	       "" "the option to specify by host settings in $HOME/.ssh/config."
	       "" ""
	       "-a, --server-address"
	          "Hostname or IP address of the server to which"
	       "" "to connect to. Also see -u above."
	       "" ""
	       "-m, --server-mac"
	          "The mac address of the host network interface."
	       "" "This is used to wake a suspended server with 'wakeonlan'."
	       "" ""
	       "" ""
	       "OPTIONS" ""
	       "-e, --exclude-file"
	          "Path to the file which contains patterns to"
	       "" "exclude from the backup (see rsync --exclude-from)"
	       "" ""
	       "-l, --log-file"
	          "When specified the given logfile will be used for output"
	       "" ""
	       "--rsync-log-file"
	          "Filename for the rsync logfile (on the server);"
	       "" "also see 'rsync --remote-option=--log-file='."
	       "" ""
	       "--max-wake-wait"
	          "Set the maximum time to wait for the server when waking it."
	       "" "steps of 2 sec, hence 5 would mean wait 10 seconds before"
	       "" "giving up. [default: ${MAX_WAKEUP_WAIT}]"
	       "" ""
	       "--db-path"
	          "Path / foldername for the database file."
	       "" "This file contains the dates of previously made backups"
	       "" "(deleted / changed files) and is needed to keep track of"
	       "" "which backups to delete when --keep-n-backups has"
	       "" "been reached. [default: ${DB_FOLDER_PATH}]"
	       "" ""
	       "--keep-n-backups"
	          "Number of backups (see rsync --backup) to keep."
	       "" "If daily backups are made this should be at least the"
	       "" "number of days for which rollback may be required."
	       "" "[default: ${KEEP_N_BACKUPS}]"
	       "" ""
	       "SRC" "The local source directory."
	       "" "(directory to backup)"
	       "" ""
	       "DEST" "The destination directory on the server."
	       "" "(here the backup will go)"
	       "" ""
	       "" ""
	       "INFO" ""
	       "" ""
	       "$(echo "This script is intended to be used to backup a local directory" \
	       "to a backup server. The used server has wake-on-lan with" \
	       "'magic packets' enabled, and can be expected" \
	       "to be suspended when this script is called." \
               "Therefore, first it will be insured" \
	       "that the server is woken and reachable before starting an rsync backup." \
	       "Furthermore, for a certain number of backups, copies of changed or" \
	       "deleted files will be kept in an '/old' folder, while the current state" \
	       "is saved in the folder '/current'. Hence the directory structure created" \
	       "will be 'DEST/old/<date>' and 'DEST/current'.")" ""
	       "" ""
	       "EXAMPLES" ""
	       "" ""
	       "$(echo "${self} -u joe@server -m 01:02:03:04:05:06 -l backup.log" \
	       	       "/from/here /to/there")" ""
	       "$(echo "${self} --server-user daisy --server-address 10.0.0.5" \
	       	       "--server-mac 01:02:03:04:05:06 /home/daisy /backup/daisy")" ""
	       "" ""
    )
    local width_l=24
    local width_r=56
    local i=0

    while (( i < ${#arr_usage[@]} ))
    do
	printf "    %-${width_l}s %-${width_r}s\n" "${arr_usage[i]}" "${arr_usage[i+1]}"
	(( i+=2 ))
    done

}


# log_entry()
# convinience function to redirect output to screen or to a log file
# Text will be printed (to log or to screen) either from pipe or/and
# from passed arguments (pipe appended to arguments if both are used). 
# usage:
#     a) log_entry "text1" "text2" "text3"...
#     b) echo "text" | log_entry
#     c) echo "text A" | log_entry "text_first" "text_second" ... "text_just_before A"
#
function log_entry() {

    # set separator explicitely to newline, as otherwise any space will be
    # regarded as separator (for cat /dev/stdin)
    IFS=$'\n'

    # get the passed arguments if there are any
    local args=("$@")

    # append stdin if it is a pipe
    if [ -p /dev/stdin ]
    then
	args=("${args[@]}" $(cat /dev/stdin))
    fi
    
    if $USE_LOGFILE
    then
	local date_string=$(date +"%F")
	local time_string=$(date +"%R:%S")
	for line in "${args[@]}"
	do
	    printf "%10s %8s |  %s\n" "$date_string" "$time_string" "$line" >> "$LOGFILE"
	    date_string=""
	    time_string=""
	done
    else
	for line in "${args[@]}"
	do
	    echo -e "$line"
	done
    fi
}

# send_notification()
# display a notification to the user via notify-send.py
#
# VAR variable to access the last notification message (notify-send.py)
last_notification_id=0
#
# wrapper function for notify-send.py
# always only have one notification open at a time (works to a certain degree),
# hence delete the previous notification when popping up a new one.
# For sudo (or cron) to be able to use this notification mechanism, it is
# neccessary to get a loggd in user that is using a graphical display, and
# then sendig the notification to there.
# (see: https://stackoverflow.com/questions/28195805/running-notify-send-as-root)
#
# usage:
#     send_notification $1 $2
# $1 header/title
# $2 notification/message
#
function send_notification() {
    # Get the message to be send
    local header="$1"
    local message="$2"

     # allow piping (append to $2 if existing)
    if [ -p /dev/stdin ]
    then
	message="$2\n$(cat /dev/stdin)"
    fi
    
    # If the script is called by root, or if the display variable is not set,
    # get a user that is logged in and is using a display, and set output
    # for notifications to that display.
    # Additionally the DBUS_SESSION_BUS_ADDRESS has to be set, this is either
    # a unix path at /run/user/$uid/bus OR
    # a abstract path set in the file /run/user/$uid/dbus-session

    if [ "$EUID" -lt 1000 ] || [ -z "$DISPLAY" ]
    then
	local user
	local uid
	local display

	# get all (local) displays known to X
	all_displays=($(ls /tmp/.X11-unix | tr 'X' ':'))

	# look which of the displays is in use
	for d in "${all_displays[@]}"
	do
	    if (( $(who | grep -c "($d)") == 1 )) ; then
		user=$(who | grep "($d)" | awk '{print $1}')
		display="$d"
		uid=$(id -u "$user")
		break;
	    fi
	done

	# only check the uid, if this is not set we didn't get the neccessary info
	if [ -z "$uid" ] ; then
	    echo "failed to identify a valid screen to post notifications" >&2
	    exit 1
	fi

	# Set the dbus session bus address
	local dbus_session_bus_address
	#
	# this seems to be handled differently for different desktop environments
	# or distros, no idea if the code below covers most of them...
	#
	if [ -e "/run/user/$uid/bus" ]
	then
	    dbus_session_bus_address="unix:path=/run/user/$uid/bus"
	elif [ -f "/run/user/$uid/dbus-session" ]
	then
	    dbus_session_bus_address=$(sed -r 's/DBUS_SESSION_BUS_ADDRESS=(.*)/\1/' \
					   "/run/user/$uid/dbus-session")
	else
	    echo "Error setting DBUS_SESSION_BUS_ADDRESS for notifications!" >&2
	    exit 1
	fi	

	# Send the notification
	last_notification_id=$(sudo -u $user \
	        DISPLAY=$display \
		DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus_address" \
		notify-send.py --expire-time 3 --category transfer \
		--replaces-id "$last_notification_id" \
		"$header" "$message")
    else
	last_notification_id=$(notify-send.py \
		--expire-time 3 \
		--category transfer \
		--replaces-id "$last_notification_id" \
		"$header" "$message")
    fi
    #
    # Note / FIXME
    # tried to solve the scenario between root/sudo and not sudo with a
    # $prefix variable only setting that for the if [ EUID < 1000 ] case,
    # but that didn't work -- it did work only in the function in a separate
    # script/file, but here the 100% identical code did not work for some
    # reason...
    # THIS DID NOT WORK
    # last_notification_id=$($prefix notify-send.py --expire-time 3 \
    #                                               --category transfer \
    #			                            --replaces-id "$last_notification_id" \
    #			                            "$header" "$message")

}


# display_progress()
# Spans a subprocess that constantly scans the last line of a file and returns
# it in a notification. Designed to display the progress of rsync in this case.
# usage:
#     a) display_progress start "<file to monitor>" ["header"]
#        --> starts an instance (or kills an old instance and starts a new one)
#            never have more than one open at the same time!
#            $3 [optional] set the header for the notifications
#     b) display_progress stop
#        --> stops a running instance
#
function display_progress() {
    local action="$1"
    local progress_file
    local header

    # subfunction that is a progress-update-process
    function spawn_progress_reader() {
	local text="";
        local header="$1"
	local monitored_file="$progress_file"
        
        while :
        do
	    sleep 1
            if [ ! -r "$monitored_file" ]
            then
                echo "ERROR spawn_progress_reader: " \
		     "can't read from file $monitored_file" >&2
                exit 1
	    else
                text=$(tail -n1 "$monitored_file")
                send_notification "${header}" "${text}"	
            fi
        done
    }

    case "$action" in
	"start")
	    display_progress "stop"
	    progress_file="$2"
	    if [ -z "$3" ]; then
		header="Progress:"
	    else
		header="$3"
	    fi
	    # spawn a reader and register its pid
	    spawn_progress_reader "$header" &
            display_progress_pid=$!
	    ;;
	"stop")
	    if [ ! -z "$display_progress_pid" ]; then
		kill $display_progress_pid
		wait $display_progress_pid 2>/dev/null
	    fi
	    unset display_progress_pid
	    ;;
	*)
	    echo "display_progress: unknown action: ${action}"
	    return 1
	    ;;
   esac

   return 0
}

# as_ip4_address()
# Convert a hostname to an ipv4 address (using systemd-resolve).
# If input is an ip address return it, otherwise try dns resolution
# and return an ip. This does not test that the ip is valid.
#
function as_ip4_address() {
    local IP_REGEX="(\d{1,3}(\.\d{1,3}){3})"
    
    # input is already an ip
    if [ $(echo "$1" | grep -cP "$IP_REGEX") -eq 1 ]
    then
	echo "$1"
	return 0
    fi

    # make sure the systemd service is running
    if ! $(systemctl is-active --quiet systemd-resolved.service)
    then
	log_entry "systemd-resolved.service not running, trying to start it."
	systemctl start systemd-resolved.service
	for i in {1..5} ; do
	    sleep 1
	    if $(systemctl is-active --quiet systemd-resolved.service) ; then
		break;
	    fi
	done
    fi

    # check again and exit if not running
    if $(systemctl is-active --quiet systemd-resolved.service)
    then
	log_entry "Ok, systemd-resolved.service is running."
    else
	log_entry "Failed to start systemd-resolved.service, terminating..."
	exit 1
    fi
    
    # perform dns lookup
    systemd-resolve "$1" &> /dev/null   # make sure network is awake
    local ip_addr=$(systemd-resolve -4 "$1" | grep -oP "$IP_REGEX")
    if [ $(echo "$ip_addr" | grep -cP "$IP_REGEX") -eq 1 ]
    then
	echo "$ip_addr"
	return 0
    else
	echo "Could not resolve hostname: $1." >&2 
	return 1
    fi
}


# PARSE SCRIPT ARGUMENTS --------------------------------------------------------

ARGUMENTS=$(getopt \
	    --options 'vhu:a:m:e:l:' \
	    --longoptions 'version,help,\
server-user:,server-address:,server-mac:,\
exclude-file:,log-file:,rsync-log-file:,\
max-wake-wait:,db-path:,keep-n-backups:'\
	    --name "$0" -- "$@")

if [ $? -ne 0 ]
then
    echo "Error while parsing arguments." >&2
    exit 1
fi

eval set -- "$ARGUMENTS"
unset ARGUMENTS

while true; do
    case "$1" in
	'-v'|'--version')
	    echo "$0 $VERSION"
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


# read out directories SRC DEST
SOURCE_DIR="$1"
DESTINATION_DIR="$2"
shift 2

# enable extended pattern matching
shopt -s extglob

# remove trailing slashes from DEST if present
DESTINATION_DIR="${DESTINATION_DIR%%+(/)}"


# check if anything is left, this shouldn't be the case
##for uparsed_arg
##do
##    echo "unrecognised argument: '$unparsed_arg'" >&2
##    exit 1
##done


# Check that all variables are set and valid
# ------------------------------------------------------------------------------

# 1) Username for server
if [ -z "${SERVER_USER}" ]
then
    echo "Please provide a login user for the server; see $0 --help for usage." >&2 
    exit 1
fi

# check if user@host was provided, and if so set SERVER_ADDRESS from it
if [ $(echo "${SERVER_USER}" | grep -c "@") -eq 1 ]
then
    if [ ! -z "${SERVER_ADDRESS}" ]
    then
	echo "Warning: Server address was provided in addition to user@host." >&2
	echo "         using the ip/hostname provided with -a / --server-address" >&2
    else
	SERVER_ADDRESS=$(echo "${SERVER_USER}" | cut -d "@" -f 2)
    fi
    
    SERVER_USER=$(echo "${SERVER_USER}" | cut -d "@" -f 1)
fi


# 2) Server ip / hostname
if [ -z ${SERVER_ADDRESS} ]
then
    echo "Please provide an ip address or hostname for the server;" \
	 "see $0 --help for usage." >&2
    exit 1
fi

# DON'T translate to ip address, as this potentially conflicts with settings
# in the .ssh/config file!
as_ip4_address "$SERVER_ADDRESS" 1>/dev/null
if [ $? -ne 0 ]; then
    exit 1
fi


# 3) MAC address
if [ -z ${SERVER_MAC} ]
then
    echo "Please provide a MAC address for the server; see $0 --help for usage." >&2
    exit 1
fi

# does conform to pattern 01:02:03:04:05:06 ?
if [ $(echo "${SERVER_MAC}" | 
	   grep -cP "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$") -ne 1 ]
then
    echo "The provided MAC address ${SERVER_MAC} is not a valid MAC." >&2
    exit 1
fi  


# 4) when using a logfile make sure it is writable
if $USE_LOGFILE 
then
    if ( ! touch "${LOGFILE}" &> /dev/null )
    then
	echo "Check permissions, can't create or write to logfile, terminating..." >&2
	exit 1
    fi
    log_entry "START"
fi


# 5) Source Directory
if [ -z "${SOURCE_DIR}" ]
then
    echo "Please provide a source directory; see $0 --help for usage." >&2
    exit 1
fi

if [ ! -d "${SOURCE_DIR}" ]
then
    echo "Directory $SOURCE_DIR not found." >&2
    exit 1
fi

if [ ! -r "${SOURCE_DIR}" ] || [ ! -x "${SOURCE_DIR}" ]
then
    echo "No permission to access $SOURCE_DIR ." >&2
    exit 1
fi


# 6) Destination Directory
if [ -z "${DESTINATION_DIR}" ]
then
    echo "Please provide a destination directory; see $0 --help for usage." >&2
    exit 1
fi


# 7) exclude file
if [ ! -z "${EXCLUDE_FILE}" ] && [ ! -r "${EXCLUDE_FILE}" ]
then
    echo "Can't read provided exclude file: '${EXCLUDE_FILE}'" >&2
    exit 1
fi

log_entry "Running with the following provided settings:" \
	  "source directory    = $SOURCE_DIR" \
	  "dest directory      = $DESTINATION_DIR" \
	  "login user (server) = $SERVER_USER" \
	  "server ip address   = $SERVER_ADDRESS" \
	  "server mac address  = $SERVER_MAC" \
	  "max wakeup wait     = $MAX_WAKEUP_WAIT" \
	  " >> on server >>" \
	  "db folder path      = $DB_FOLDER_PATH" \
	  "backups to keep     = $KEEP_N_BACKUPS"

# ----------------------------------------------------------------------------


# check connectivity
# ------------------------------------------------------------------------------

# 1) insure working network interface on client
if ( ! ping -c 1 localhost &> /dev/null )
then
    log_entry "Problem with network card or settings, "\
	      "can't connect to 'localhost' terminating... [ERROR]"
    send_notification "Backup Error" "couldn't connect to localhost!"
    exit 1
fi


# 2) check if server online, if not try to wake it

## check if wakeonlan is installed
which wakeonlan >/dev/null
if [ $? -ne 0 ]
then
    echo "Could not find wakeonlan, is it installed? terminating..." >&2
    exit 1
fi

SERVER_ONLINE=false
log_entry "Trying to connect to server at: $SERVER_ADDRESS"

for i in $(seq 1 "$MAX_WAKEUP_WAIT")
do
    if ( ! ping -c 3 "$SERVER_ADDRESS"  &> /dev/null )
    then
        log_entry "Server not reachable; trying to wake it up."
        wakeonlan "$SERVER_MAC" &> /dev/null
	sleep 2
    else
	SERVER_ONLINE=true
	break;
    fi
done

if $SERVER_ONLINE
then
    log_entry "Server is running and reachable."
else
    log_entry "Failed to connect to server, terminating... [ERROR]"
    send_notification "Backup Error" "couldn't wake up server!"
    exit 1
fi


# 3) make sure ssh is working
log_entry "Checking that ssh service is running on server:"

if ( nc -zw 2 "$SERVER_ADDRESS" 22 &> /dev/null )
then
    log_entry "Succeeded, ssh server listening on port 22."
else
    log_entry "No ssh service detected on port 22, terminating... [ERROR]"
    send_notification "Backup ERROR" "no ssh service detected on server!"
    exit 1
fi
# ------------------------------------------------------------------------------

# inform the user about the start of the backup
send_notification "Backup to Server" "Starting backup of ${SOURCE_DIR} ..."

# Note: To be able to have incremental backups (rsync with backup and --backup-dir)
# and only keeping the last 30 backups, it is necessary to store a file with
# the file names (= dates) of previously performed and kept backups.
# entries will be appended to this file, and if the list gets longer than
# 30 entries, folders matching the string from the top of the file will be
# deleted
# ------------------------------------------------------------------------------
#
db_file="${DB_FOLDER_PATH}/$(echo "${SOURCE_DIR}@@${DESTINATION_DIR}" | sed 's#/#%%#g').backup.history"

# set variables for the files on the server (used via ssh)
current_date=$(date +"%Y-%m-%d")
current_folder="current"
backup_folder="old"

if [ ! -z "$RSYNC_LOG_FILE" ] ; then
    server_log_dir="${RSYNC_LOG_FILE%/*}"
    log_entry "Directory for logs on server: ${server_log_dir=}"
fi

# enable a sleep lock on the server
sleep_lock_code=$(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock enable")

# check that successful
if [[ $(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock check $sleep_lock_code") == "active" ]]
then
    log_entry "Enabled sleep lock on server, code: $sleep_lock_code"
else
    send_notification "Backup Error" "Error could not get sleep lock for server"
    log_entry "Setting sleep lock for server failed, code: $sleep_lock_code"
    exit 1
fi

# ensure directories exist on the server
ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" << EOF
        [ -d "${DESTINATION_DIR}" ] || mkdir -p "${DESTINATION_DIR}"
	[ -d "${DESTINATION_DIR}/${current_folder}" ] ||
	  mkdir "${DESTINATION_DIR}/${current_folder}"
	[ -d "${DESTINATION_DIR}/${backup_folder}" ]  ||
	  mkdir "${DESTINATION_DIR}/${backup_folder}"
	[ -d "${DB_FOLDER_PATH}" ] || mkdir -p "${DB_FOLDER_PATH}"
	touch "${db_file}"

	# log things:
	if [ ! -z "$RSYNC_LOG_FILE" ] ; then
	   # ensure log dir exists
	   [ -d "{server_log_dir}" ] || mkdir -p "${server_log_dir}" 
	   # don't keep more than 10 logs
	   [ -e "${RSYNC_LOG_FILE}.10" ] && rm "${RSYNC_LOG_FILE}.10"
	   # move existing logs one number up
	   for i in {9..0} ; do
	       [ -e "${RSYNC_LOG_FILE}.\$i" ] &&
	       	 mv "${RSYNC_LOG_FILE}.\$i" "${RSYNC_LOG_FILE}.\$((\$i + 1))"
	   done
	   [ -e "${RSYNC_LOG_FILE}" ] &&
	       	 mv "${RSYNC_LOG_FILE}" "${RSYNC_LOG_FILE}.0"
	fi
EOF

# build the options for rsync
# Note append arguments separately to options as e.g.
# +=("--delete --delete-excluded") would be parsed as a single argument,
# use +=("--delete" "--delete-excluded") -- note the double quotes!
#
rsync_opts=("-az")

[ ! -z "$EXCLUDE_FILE" ] &&
    rsync_opts+=("--exclude-from=${EXCLUDE_FILE}")

rsync_opts+=("--delete" "--delete-excluded" "--delete-delay")
rsync_opts+=("--backup" "--backup-dir=../${backup_folder}/${current_date}")

[ ! -z "$RSYNC_LOG_FILE" ] &&
    rsync_opts+=("--remote-option=--log-file=${RSYNC_LOG_FILE}")

rsync_opts+=("--info=progress2")

# last the SRC and DEST
rsync_opts+=("${SOURCE_DIR}" "${SERVER_USER}@${SERVER_ADDRESS}:${DESTINATION_DIR}/current")


# >> start showing progress >>
echo "0%" > "$progress_file"
display_progress "start" "$progress_file" "Backing up files:"


# run rsync
rsync "${rsync_opts[@]}" |
    stdbuf -oL awk 'BEGIN { RS="\r" } /%/ { print $2 }' >> "$progress_file"


# << stop showing progress <<
sleep 2
display_progress "stop"

# check that rsync terminated ok
rsync_exit_status="${PIPESTATUS[0]}"

if [ "$rsync_exit_status" -ne 0 ]
then
    log_entry "Rsync terminated with |error status '$rsync_exit_status' ... [ERROR]"
    send_notification "Backup Error" "rsync terminated unexpectedly!"
    exit 1
else
    log_entry "Rsync finished without errors."
fi


# 1) if a backup-dir was created (as there were changes and a backup was made),
# write the name (date) of the backup-dir into the db, otherwise DO NOT.

# 2) delete old backups when more have been made than should be kept
ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" << EOF | log_entry "SERVER"
    if [ -d "${DESTINATION_DIR}/${backup_folder}/${current_date}" ]
    then
        echo "${current_date}" >> "${db_file}"
    else
        echo "No backup folder created for: ${current_date}"
    fi
    
    while (( \$(cat "${db_file}" | wc -l) > "$KEEP_N_BACKUPS" ))
    do
        # delete the topmost backup and remove it from the db
        backup_to_delete=\$(head -n 1 "${db_file}")
        echo "deleting backup \${backup_to_delete}"
        rm -rf "${DESTINATION_DIR}/${backup_folder}/\${backup_to_delete}" >/dev/null
    
        # remove first line in db
        sed -i '1d' "${db_file}"
    done
    
    echo "folders on server:"
    cat "${db_file}"
EOF

# release the sleep lock on the server
ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock release $sleep_lock_code"

# check that successful
if [[ $(ssh -q "${SERVER_USER}@${SERVER_ADDRESS}" "sleep-lock check $sleep_lock_code") == "inactive" ]]
then
    log_entry "Disabled sleep lock on server, code: $sleep_lock_code"
    unset sleep_lock_code
else
    send_notification "Backup Error" "Could not release sleep lock for server"
    log_entry "Releasing sleep lock for server failed, code: $sleep_lock_code"
    exit 1
fi


if $USE_LOGFILE
then
    log_entry "FINISHED" ""
fi

send_notification "Backup to server" "Finished backup of ${SOURCE_DIR}."

exit 0

