#!/usr/bin/env bash
#
# Install all scripts in rsync_backup_scripts to the system
#
# @Name:         setup.bash
# @Author:       Tobias Marczewski
# @Last Edit:    2020-05-29
# @Version:      0.1
#
# Arguments:
#   "install"                               - install/update the scripts
#   "unsinstall"                            - remove the scripts from the system
#   "enable-systemd" </path/to/script.bash> - enable a daily execution for <script>
#


function cleanup() {
    ## Don't keep unneccesary sudo rights
    ##
    sudo -k &>/dev/null
}
trap cleanup EXIT


################################################################################
# Display usage info
#
# Global variables:
#   SCRIPTS
function usage() {
    declare -i -r l_width=25
    declare -i -r r_width=55

    printf "\n%s\n\n" "Usage:  ${0} MODE"
    printf "MODE\n"
    printf "%-${l_width}s %-${r_width}s\n" "   help" "Show this information."
    printf "%-${l_width}s %-${r_width}s\n" "   install" "Install or update all SCRIPTS"
    printf "%-${l_width}s %-${r_width}s\n" "   uninstall" "Uninstall all SCRIPTS"
    printf "\n"
    printf "%-${l_width}s %-${r_width}s\n" "   enable-systemd </path/to/script>" ""
    printf "%-${l_width}s %-${r_width}s\n" "" "Set-up a systemd.service and a corresponding systemd.timer"
    printf "%-${l_width}s %-${r_width}s\n" "" "unit to run the <script> specified. For an example look at"
    printf "%-${l_width}s %-${r_width}s\n" "" "backup.template. Currently a daily task-timer will be set."
    printf "\n"
    printf "SCRIPTS\n"
    for script in "${!SCRIPTS[@]}"; do
	printf "%-${l_width}s -> %s\n" "   ${script}" "${SCRIPTS[$script]}"
    done
    printf "\n"

}

################################################################################
# Insure we have super user privileges.
#
# Arguments: none
#
# Returns:
#   0 - succes (we have su privileges)
#   1 - failure (could not obtain privileges)
#
function insure_su_privileges() {

    if (( $EUID == 0 )) ; then
	return 0
    fi

    sudo --validate --prompt="Please enter the sudo password for %p to proceed: " &>/dev/null

    if (( "$?" == 0 )); then
	return 0
    else
	echo "Failed to obtain super user privileges." >&2
	return 1
    fi
}

################################################################################
# Setup a systemd service for the specified script to be executed daily
#
# Arguments:
#   $1 - path to the script to be executed
#
# Global variables:
#   SYSTEMD_LIB_PATH
#
# Output:
#   This will wirte the two systemd unit files:
#   - <scriptname>.service
#   - <scriptname>.timer
#   and then enable the service in systemd
#
# Returns:
#   0 - on success
#   1 - on error
#
function enable_systemd_timer() {

    local script_path
    local script_name
    local service_unit_file
    local timer_unit_file

    

    if [[ -z "$1" ]]; then
	echo "enable_systemd_timer() Error: No script provided!" >&2
	return 1
    fi

    readonly script_path=$(realpath "$1")
    
    if [[ ! -f "$script_path" ]]; then
	echo "enable_systemd_timer() Error: script file ${script_path} not found." >&2
	return 1
    fi

    readonly script_name=$(basename "${script_path}")
    readonly service_unit_file="${SYSTEMD_LIB_PATH}/${script_name%.*}.service"
    readonly timer_unit_file="${SYSTEMD_LIB_PATH}/${script_name%.*}.timer"

    ## Check if a service with the name already exists and if so ask the
    ## user how to proceed.
    ##
    if [[ -e "$service_unit_file" ]] || [[ -e "$timer_unit_file" ]]; then
	echo "${service_unit_file} or/and ${timer_unit_file} already exist." \
	     "Continuing will replace those services!"
	read -p "[(A)bort / (C)ontinue]: " check

	case "$check" in
	    [cC]|"continue"|"Continue" )
		echo "continuing..."
		## Stop the existing service and disable it
		##
		sudo systemctl stop "${service_unit_file##*/}" &>/dev/null
		sudo systemctl stop "${timer_unit_file##*/}" &>/dev/null
		sleep 1
		sudo systemctl disable "${timer_unit_file##*/}" &>/dev/null
		sudo systemctl disable "${service_unit_file##*/}" &>/dev/null
		sleep 1
		rm "${timer_unit_file}" &>/dev/null
		rm "${service_unit_file}" &>/dev/null
		;;
	    *)
		echo "aborting..."
		return 1
		;;
	esac
    fi

    ## Write the service file
    ## (no [Install] block needed, as the timer starts the service,
    ##  but better be save and require ac power to be plugged in.)
    ##
    cat <<EOF | sudo tee "$service_unit_file" >/dev/null
[Unit]
Description=Run the backup script ${script_name}
ConditionACPower=true

[Service]
Type=simple
ExecStart=${script_path}

EOF

    ## Write the timer file
    ##
    cat <<EOF | sudo tee "$timer_unit_file" >/dev/null
[Unit]
Description=Run the backup script ${script_name}

[Timer]
OnCalendar=daily

[Install]
WantedBy=timers.target

EOF

    ## Enable and start the service
    ##
    sudo systemctl enable "${timer_unit_file}" &&
    sudo systemctl start "${timer_unit_file##*/}"

    if (( "$?" != 0 )); then
	echo "enable_systemd_timer() Error: Failed to enable the timer" \
	     "${timer_unit_file}." >&2
	return 1
    fi

    echo "The service ${timer_unit_file##*/} is now enabled."
    echo "To disable it please use 'systemctl disable ${timer_unit_file##*/}'."
    
    return 0
}

################################################################################
# Install (or update) all scripts in SCRIPTS ([script]="/install/location")
#
# Arguments:
#   none
#
# Global variables:
#   SCRIPTS
#   SETUP_SCRIPT_DIR
#
# Returns:
#   0 - success, 1 - error
#
function do_install() {
    local script_path
    local install_path
    local install_mode

    for script in "${!SCRIPTS[@]}"; do
	script_path="${SETUP_SCRIPT_DIR}/${script}"
	install_path="${SCRIPTS[$script]}"
	if [[ -e "$install_path" ]]; then
	    install_mode="update"
	else
	    install_mode="install"
	fi
	
	sudo install --mode=755 "$script_path" "$install_path"
	
	if (( "$?" != 0 )); then
	    echo "Failed to install ${script_path} under ${install_path}."
	    return 1
	fi

	echo "Successfully ${install_mode}d ${install_path##*/}."
    done
    
    return 0
}

################################################################################
# Uninstall all scripts in SCRIPTS ([script]="/install/location")
#
# Arguments:
#   none
#
# Global variables:
#   SCRIPTS
#
# Returns:
#   0 - success, 1 - error
#
function do_uninstall() {

    for script in "${SCRIPTS[@]}"; do
	if [[ -e "$script" ]]; then
	    sudo rm "$script" || return
	    echo "Successfully removed ${script}"
	fi
    done
    
    return 0
}


function main() {

    ## Get the path to the directory the script is located in
    ##
    local SETUP_SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
    declare -rA SCRIPTS=(["backup-to-server.bash"]="/usr/local/bin/backup-to-server")
    declare -r SYSTEMD_LIB_PATH="/lib/systemd/system"
    local mode="$1"

    
    case "$mode" in
	"help")
	    usage
	    ;;
	"install")
	    insure_su_privileges || exit
	    do_install || exit
	    ;;
	"uninstall")
	    insure_su_privileges || exit
	    do_uninstall || exit
	    ;;
	"enable-systemd")
	    if [[ -z "$2" ]]; then
		echo "No script specified to be used for the systemd.service." >&2
		exit 1
	    fi
	    insure_su_privileges || exit
	    enable_systemd_timer "$2" || exit
	    ;;
	*)
	    echo "No valid mode provided; see '$0 help' for usage." >&2
	    exit 1
	    ;;
    esac
    
    exit 0
}


## ENTRY POINT
##
main "$@"
