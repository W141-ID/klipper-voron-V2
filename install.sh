#!/usr/bin/env bash
#################################################
###### AUTOMATED INSTALL AND UPDATE SCRIPT ######
#################################################
# Written by yomgui1 & Frix_x
# @version: 1.2

# CHANGELOG:
#   v1.2: fixed some bugs and adding small new features:
#          - now it's ok to use the install script with the user config folder absent
#          - avoid copying all the existing MCU templates to the user config directory during install to keep it clean
#          - updated the logic to keep the user custom files and folders structure during a backup (it was previously flattened)
#   v1.1: added an MCU template automatic installation system
#   v1.0: first version of the script to allow a peaceful install and update ;)

KLIPPER_SERVICE=klipper
# Where the user Klipper config is located (ie. the one used by Klipper to work)
USER_CONFIG_PATH="${HOME}/printer_data/config"
# Where to clone Frix-x repository config files (read-only and keep untouched)
FRIX_CONFIG_PATH="${HOME}/klippain_config"
# Path used to store backups when updating (backups are automatically dated when saved inside)
BACKUP_PATH="${HOME}/klippain_config_backups"


set -eu
export LC_ALL=C

function folder_name {

    read < /dev/tty -rp "[CONFIG] Would you like to select custom folder locations? (Y/n) " custom_folder
    if [[ -z "$custom_folder" ]]; then
        custom_folder="y"
    fi

    # Continue with the standard folder location
    if [[ "$custom_folder" =~ ^(no|n)$ ]]; then
        printf "[CONFIG] Using the standard folder configuration!\n\n"
        return
    fi

    # Input folder name 
    read < /dev/tty -rp "[CONFIG]  Please input the custom Folder name:" USER_CONFIG_PATH_INPUT
        USER_CONFIG_PATH="${HOME}/${USER_CONFIG_PATH_INPUT}_data/config"
        KLIPPER_SERVICE=klipper-"${USER_CONFIG_PATH_INPUT}"
        BACKUP_DIR="${BACKUP_PATH}/${USER_CONFIG_PATH_INPUT}/$(date +'%Y_%m_%d-%H%M%S')"
}

# Step 1: Verify that the script is not run as root and Klipper is installed
function preflight_checks {
    if [ "$EUID" -eq 0 ]; then
        echo "[PRE-CHECK] This script must not be run as root!"
        exit -1
    fi

    if [ "$(sudo systemctl list-units --full -all -t service --no-legend | grep -F "${KLIPPER_SERVICE}"'.service')" ]; then
        printf "[PRE-CHECK] Klipper service found! Continuing...\n\n"
    else
        echo "[ERROR] Klipper service (""${KLIPPER_SERVICE}"".service) not found, please install Klipper first!"
        exit -1
    fi
}

# Step 2: Check if the git config folder exist (or download it)
function check_download {
    local frixtemppath frixreponame
    frixtemppath="$(dirname ${FRIX_CONFIG_PATH})"
    frixreponame="$(basename ${FRIX_CONFIG_PATH})"

    if [ ! -d "${FRIX_CONFIG_PATH}" ]; then
        echo "[DOWNLOAD] Downloading Klippain repository..."
        if git -C $frixtemppath clone https://github.com/Frix-x/klippain.git $frixreponame; then
            chmod +x ${FRIX_CONFIG_PATH}/install.sh
            printf "[DOWNLOAD] Download complete!\n\n"
        else
            echo "[ERROR] Download of Klippain git repository failed!"
            exit -1
        fi
    else
        printf "[DOWNLOAD] Klippain repository already found locally. Continuing...\n\n"
    fi
}


# Step 3: Backup the old Klipper configuration
function backup_config {
    mkdir -p ${BACKUP_DIR}

    # Copy every files from the user config ("2>/dev/null || :" allow it to fail silentely in case the config dir doesn't exist)
    cp -fa ${USER_CONFIG_PATH}/. ${BACKUP_DIR} 2>/dev/null || :
    # Then delete the symlinks inside the backup folder as they are not needed here...
    find ${BACKUP_DIR} -type l -exec rm -f {} \;

    printf "[BACKUP] Backup of current user config files done in: ${BACKUP_DIR}\n\n"
}


# Step 4: Put the new configuration files in place to be ready to start
function install_config {
    echo "[INSTALL] Installation of the last Klippain config files"
    mkdir -p ${USER_CONFIG_PATH}

    # Symlink Frix-x config folders (read-only git repository) to the user's config directory
    for dir in config macros scripts moonraker; do
        ln -fsn ${FRIX_CONFIG_PATH}/$dir ${USER_CONFIG_PATH}/$dir
    done

    # Detect if it's a first install by looking at the .VERSION file to ask for the config
    # template install. If the config is already installed, nothing need to be done here
    # as moonraker is already pulling the changes and custom user config files are already here
    if [ ! -f "${BACKUP_DIR}/.VERSION" ]; then
        printf "[INSTALL] New installation detected: config templates will be set in place!\n\n"
        find ${FRIX_CONFIG_PATH}/user_templates/ -type d -name 'mcu_defaults' -prune -o -type f -print | xargs cp -ft ${USER_CONFIG_PATH}/
        install_mcu_templates
    fi

    # CHMOD the scripts to be sure they are all executables (Git should keep the modes on files but it's to be sure)
    chmod +x ${FRIX_CONFIG_PATH}/install.sh
    for file in graph_vibrations.py plot_graphs.sh; do
        chmod +x ${FRIX_CONFIG_PATH}/scripts/$file
    done

    # Create or update the config version tracking file in the user config directory
    git -C ${FRIX_CONFIG_PATH} rev-parse HEAD > ${USER_CONFIG_PATH}/.VERSION
}


# Helper function to ask and install the MCU templates if needed
function install_mcu_templates {
    local install_template file_list main_template install_toolhead_template toolhead_template install_ercf_template

    read < /dev/tty -rp "[CONFIG] Would you like to select and install MCU wiring templates files? (Y/n) " install_template
    if [[ -z "$install_template" ]]; then
        install_template="y"
    fi
    install_template="${install_template,,}"

    # Check and exit if the user do not wants to install an MCU template file
    if [[ "$install_template" =~ ^(no|n)$ ]]; then
        printf "[CONFIG] Skipping installation of MCU templates. You will need to manually populate your own mcu.cfg file!\n\n"
        return
    fi

    # If "yes" was selected, let's continue the install by listing the main MCU template
    file_list=()
    while IFS= read -r -d '' file; do
        file_list+=("$file")
    done < <(find "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/main" -maxdepth 1 -type f -print0)
    echo "[CONFIG] Please select your main MCU in the following list:"
    for i in "${!file_list[@]}"; do
        echo "  $((i+1))) $(basename "${file_list[i]}")"
    done

    read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " main_template
    if [[ "$main_template" -gt 0 ]]; then
        # If the user selected a file, copy its content into the mcu.cfg file
        filename=$(basename "${file_list[$((main_template-1))]}")
        cat "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/main/$filename" >> ${USER_CONFIG_PATH}/mcu.cfg
        printf "[CONFIG] Template '$filename' inserted into your mcu.cfg user file\n\n"
    else
        printf "[CONFIG] No template selected. Skip and continuing...\n\n"
    fi

    # Next see if the user use a toolhead board
    read < /dev/tty -rp "[CONFIG] Do you have a toolhead MCU and want to install a template? (y/N) " install_toolhead_template
    if [[ -z "$install_toolhead_template" ]]; then
        install_toolhead_template="n"
    fi
    install_toolhead_template="${install_toolhead_template,,}"

    # Check if the user wants to install a toolhead MCU template
    if [[ "$install_toolhead_template" =~ ^(yes|y)$ ]]; then
        file_list=()
        while IFS= read -r -d '' file; do
            file_list+=("$file")
        done < <(find "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/toolhead" -maxdepth 1 -type f -print0)
        echo "[CONFIG] Please select your toolhead MCU in the following list:"
        for i in "${!file_list[@]}"; do
            echo "  $((i+1))) $(basename "${file_list[i]}")"
        done

        read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " toolhead_template
        if [[ "$toolhead_template" -gt 0 ]]; then
            # If the user selected a file, copy its content into the mcu.cfg file
            filename=$(basename "${file_list[$((toolhead_template-1))]}")
            cat "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/toolhead/$filename" >> ${USER_CONFIG_PATH}/mcu.cfg
            cat "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/toolhead/overrides/default.cfg" >> ${USER_CONFIG_PATH}/overrides.cfg
            printf "[CONFIG] Template '$filename' inserted into your mcu.cfg and default overrides added to your overrides.cfg user files\n\n"
        else
            printf "[CONFIG] No toolhead template selected. Skip and continuing...\n\n"
        fi
    fi

    # Finally see if the user use an ERCF board
    read < /dev/tty -rp "[CONFIG] Do you have an ERCF MCU and want to install a template? (y/N) " install_ercf_template
    if [[ -z "$install_ercf_template" ]]; then
        install_ercf_template="n"
    fi
    install_ercf_template="${install_ercf_template,,}"

    # Check if the user wants to install an ERCF MCU template
    if [[ "$install_ercf_template" =~ ^(yes|y)$ ]]; then
        file_list=()
        while IFS= read -r -d '' file; do
            file_list+=("$file")
        done < <(find "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/ercf" -maxdepth 1 -type f -print0)
        echo "[CONFIG] Please select your ERCF MCU in the following list:"
        for i in "${!file_list[@]}"; do
            echo "  $((i+1))) $(basename "${file_list[i]}")"
        done

        read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " ercf_template
        if [[ "$ercf_template" -gt 0 ]]; then
            # If the user selected a file, copy its content into the mcu.cfg file
            filename=$(basename "${file_list[$((ercf_template-1))]}")
            cat "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/ercf/$filename" >> ${USER_CONFIG_PATH}/mcu.cfg
            printf "[CONFIG] Template '$filename' inserted into your mcu.cfg user file\n\n"
        else
            printf "[CONFIG] No ERCF template selected. Skip and continuing...\n\n"
        fi
    fi
}


# Step 5: restarting Klipper
function restart_klipper {
    echo "[POST-INSTALL] Restarting Klipper..."
    sudo systemctl restart "${KLIPPER_SERVICE}"
}


BACKUP_DIR="${BACKUP_PATH}/$(date +'%Y_%m_%d-%H%M%S')"

printf "\n======================================\n"
echo "- Klippain install and update script -"
printf "======================================\n\n"

# Run steps
folder_name
preflight_checks
check_download
backup_config
install_config
restart_klipper

echo "[POST-INSTALL] Everything is ok, Klippain installed and up to date!"
echo "[POST-INSTALL] Be sure to check the breaking changes on the release page: https://github.com/Frix-x/klippain/releases"
