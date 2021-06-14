#!/bin/bash

#=================================================================================
# This is sample manufacturing provisioning tool for following purpose:
#
# -----------------------------
#  Azure Device Record Capture 
# -----------------------------  
#  Target Device
#  - Santa Cruz project devkit: PE100/PE101 
#
# 1. Re-provisioning TPM - to clear TPM and capture EK public part.
# 2. Capture - to collect persistent data from device, which includes:
#    - Serial Number (20 digits): from imx8 ocotp MAC_ADDR0 MAC_ADDR1 MAC_ADDR2 (MAC_ADDR* is not used for ethernet on pe101)
#    - TPM EK public key (RSA): for Azure DPS registration use
#    - TPM EK public key digist in sha256 hash: for Azure DPS registration use
#    - MAC address of the first "ethernet" interface: as part of hardware identity
#    - Wifi DPP public key (ECC): The Wifi EasyConnect (DPP) public bootstrapping key, to be part of device registration in Azure DPS
#    - Wifi MAC address
#    - Wifi Soft-AP PSK
#
#=================================================================================

MFG_TOOL_VERSION="1.0.201112.1001"
MFG_TOOL_PROD_TYPE="devkit"
MFG_TOOL_SUPPORTED_MODELS="pe100 pe101"
HW_NETIF_DEVICE="eth0"
HW_WIFIDPP_DEVICE="wlan0"

MFG_TOOL_OPT_NOPROVISION=0
MFG_TOOL_OPT_INITTPM=0
MFG_TOOL_OPT_CHECKREQUIRED=0
MFG_TOOL_OPT_OUTPUTFILE=
MFG_TOOL_OPT_SERIALNUM=
MFG_TOOL_OPT_MODEL=
MFG_TOOL_OPT_OVERRIDESN=0

HW_MODEL=
HW_BOARD_SERIALNUM="(N/A)"
HW_NETIF_MAC=

AZURE_DEV_TPM_ENDORSEMENT_KEY=
AZURE_DEV_REGISTRATION_ID=
AZURE_DEV_WIFIDPP_ECCPUB_KEY=
AZURE_DEV_WIFI_MAC=
AZURE_DEV_WIFISOFTAP_PSK=

TEMPDIR=$(mktemp -d -t mfgtool.XXXXXX)

function log_if_error()
{
    local rc=$1 
    local func_name=$2
    local err_msg=$3

    [ $rc -eq 0 ] || echo "ERROR: ${func_name} (rc=${rc}) ${err_msg}" >&2
    return $rc 
}

function clean_and_exit()
{
    local exitcode=$1

    [ -d ${TEMPDIR} ] && rm -rf ${TEMPDIR}
    exit $exitcode
}

function compare_pkg_version()
{
    # compare at most 3 numbers (main.minor.build) in version
    local src_ver_str="${1//./ }"
    local trg_ver_str="${2//./ }"

    declare -a src_ver=(${src_ver_str})
    declare -a trg_ver=(${trg_ver_str})

    # return 0 if src version < target version
    # return 1 if src version >= target version

    # compare main version number
    [[ "${src_ver[0]}" -lt "${trg_ver[0]}" ]] && return 0
    [[ "${src_ver[0]}" -gt "${trg_ver[0]}" ]] && return 1

    # compare monir version number
    [[ "${src_ver[1]}" -lt "${trg_ver[1]}" ]] && return 0
    [[ "${src_ver[1]}" -gt "${trg_ver[1]}" ]] && return 1

    # compare build version number
    [[ "${src_ver[2]}" -lt "${trg_ver[2]}" ]] && return 0
    [[ "${src_ver[2]}" -gt "${trg_ver[2]}" ]] && return 1

    # final condition: src version == target version, return 1
    return 1
}

function check_system_requirement()
{
    local required_tpm2tools_ver="4.2"
    local err=0

    echo "Check system requirement for model ${HW_MODEL} ..." >&2

    # package tpm2-tools 4.2
    if ! (rpm -q tpm2-tools >/dev/null 2>&1); then
        echo "ERROR: Required tool - tpm2-tools - Not installed!" >&2
        (( err += 1 ))
    elif (compare_pkg_version "$(rpm -q --queryformat '%{VERSION}' tpm2-tools 2>/dev/null)" "$required_tpm2tools_ver"); then
        echo "ERROR: Required tool - tpm2-tools version less than $required_tpm2tools_ver !" >&2
        (( err += 1 ))
    fi

    # tool: awk, base64, base32, sha256sum, openssl
    for t in awk base64 base32 sha256sum openssl; do
        if ! (command -v $t >/dev/null 2>&1); then
            echo "ERROR: Required tool - $t - Not found!" >&2
            (( err += 1 ))
        fi
    done

    # hardware: netif existance
    if [ ! -f "/sys/class/net/${HW_NETIF_DEVICE}/address" ]; then
        echo "ERROR: Hw device - ${HW_NETIF_DEVICE} - Not found!" >&2
        (( err += 1 ))
    fi

    if [ ! -f "/sys/class/net/${HW_WIFIDPP_DEVICE}/address" ]; then
        echo "ERROR: Hw device - ${HW_WIFIDPP_DEVICE} - Not found!" >&2
        (( err += 1 ))
    fi

    # hardware: tpm0 existance
    if [ ! -e "/dev/tpm0" ]; then
        echo "ERROR: Hw device - tpm0 - Not found!" >&2
        (( err += 1 ))
    fi

    [ $err -eq 0 ] && echo "Passed!" >&2

    return $err
}

function set_model()
{
    # set model
    local model=$1

    if [ -z "$model" ]; then
        log_if_error 1 $FUNCNAME "empty model name!" || return $?
    fi

    if [[ " ${MFG_TOOL_SUPPORTED_MODELS} " =~ .*\ $model\ .*  ]]; then
        HW_MODEL=$model
    else
        log_if_error 1 $FUNCNAME "$model is not supported by this tool!" || return $?
    fi

    case ${HW_MODEL} in
    pe101)
        # pe101 has default (the only) ethernet at "eth1"
        HW_NETIF_DEVICE="eth1"
        ;;
    *)
        ;;
    esac
}

function read_sn_from_hardware()
{
    case ${HW_MODEL} in
    pe100|pe101)
        nvmem_path="/sys/devices/platform/soc@0/soc@0:bus@30000000/30350000.ocotp-ctrl/imx-ocotp0/nvmem"
        
        # check nvmem node existance
        if [ ! -f "$nvmem_path" ]; then
            log_if_error 1 $FUNCNAME "imx-ocotp0 is not found!" || return $?
        fi

        # serial number is stored at 12 bytes in ocotp MAC_ADDR0 MAC_ADDR1 MAC_ADDR2 (uboot=> fuse read 9 0 3), 
        # 4 bits per digit in ocotp nvmem, convert these bits to serial number
        HW_BOARD_SERIALNUM=$(hexdump -v -x $nvmem_path 2>/dev/null | grep 0000090 | awk '{print toupper($6 $5 $4 $3 $2) }' | sed -e 's/./& /g' | awk '{print $20 $19 $18 $17 $16 $15 $14 $13 $12 $11 $10 $9 $8 $7 $6 $5 $4 $3 $2 $1}')
        log_if_error $? $FUNCNAME "serial number is not provisioned on this board!" || return $?
        ;;
    *)
        log_if_error 1 $FUNCNAME "don't know how to read serial number for model \"${HW_MODEL}\"" || return $?
        ;;
    esac
}

function read_sn_from_dmi()
{
    # serial number is stored in smbios
    # read serial number from dmi record

    local dmi_id_path="/sys/class/dmi/id/board_serial"
    local serial_number=
    
    # check board_serial node existance
    if [ ! -f "$dmi_id_path" ]; then
        log_if_error 1 $FUNCNAME "$dmi_id_path is not found!" || return $?
    fi
    
    serial_number=$(cat $dmi_id_path 2>/dev/null)
    log_if_error $? $FUNCNAME || return $?

    if [ -z "$serial_number" ]; then
        log_if_error 1 $FUNCNAME "$dmi_id_path is empty!" || return $?
    fi

    HW_BOARD_SERIALNUM=$serial_number
}

function get_serial_number()
{
    # read serial number
    # implement device manufacturer specific method to read serial number from device

    local confirm_serial_num=$1

    if [ $MFG_TOOL_OPT_OVERRIDESN -ne 0 ]; then
        # serial number is overriden by the one input from command line
        HW_BOARD_SERIALNUM=$confirm_serial_num
        return 0
    fi

    case ${HW_MODEL} in
    pe100|pe101)
        # read_sn_from_hardware
        read_sn_from_dmi
        log_if_error $? $FUNCNAME || return $?
        ;;
    *)
        log_if_error 1 $FUNCNAME "don't know how to get serial number for model \"${HW_MODEL}\"." || return $?
        ;;
    esac

    # if exists serial number from input, compare and make sure 
    if [ ! -z "$confirm_serial_num" ]; then
        if [ ! "$confirm_serial_num" = "${HW_BOARD_SERIALNUM}" ]; then
            log_if_error 1 $FUNCNAME "serial number does not match! input($confirm_serial_num) != hw (${HW_BOARD_SERIALNUM})" || return $?
        fi
    fi
}

function init_tpm()
{
    local dont_provision=$1
    local inittpm=$2

    if [[ $dont_provision -eq 0 ]]; then
        # do tpm provisioning

        if [[ $inittpm -ne 0 ]]; then
            # clear tpm first before create EK
            tpm2_clear -c p
            tpm2_clear -c l
            echo "INFO: TPM cleared!" >&2
        fi
        
        if ! (tpm2_getcap handles-persistent | grep 0x81010001 >/dev/null); then
            # no EK persists, create EK
            tpm2_createek -c 0x81010001 -G rsa
            log_if_error $? $FUNCNAME || return $?
            echo "INFO: EK created!" >&2
        else
            echo "INFO: EK existed!" >&2
        fi
    else
        if ! (tpm2_getcap handles-persistent | grep 0x81010001 >/dev/null); then
            log_if_error 1 $FUNCNAME "no EK found! please run without -q option to re-provision TPM!" || return $?
        fi
    fi
}

function get_tpm_ek_pubdata()
{
    local temp_obj="${TEMPDIR}/ek.rsa.pub.obj"
    
    if ! (tpm2_readpublic -c 0x81010001 -o $temp_obj >/dev/null); then
        log_if_error 1 $FUNCNAME || return $?
    fi

    AZURE_DEV_TPM_ENDORSEMENT_KEY=$(base64 -i $temp_obj | tr -d '\n')
    log_if_error $? $FUNCNAME || return $?
    
    AZURE_DEV_REGISTRATION_ID=$(echo -ne "$(sha256sum  $temp_obj | awk '{print toupper($1)}' | sed -e 's/../\\x&/g')" | base32 | awk '{print tolower($0)}' | tr -d '=\n')
    log_if_error $? $FUNCNAME || return $?
}

function get_netif_mac()
{
    HW_NETIF_MAC=$(cat /sys/class/net/${HW_NETIF_DEVICE}/address 2>/dev/null)
    log_if_error $? $FUNCNAME || return $?
}

function get_wifidpp_pubdata()
{
    local context_obj="${TEMPDIR}/wifidpp_ek.ctx"
    local pubkey_der="${TEMPDIR}/wifidpp_ek.pub.der"
    local ek_unique_data="${TEMPDIR}/wifidpp_ek_unique.dat"

    local EK_UNIQUE_X="Santa Cruz WiFi ZTP Team"
    local EK_UNIQUE_Y="Jeffrey John Paul Andrew"
    local EK_ALG="ecc256:ecdh-sha256"
    local EK_OUTSIDE_INFO=5a2162fc33cffc1a28b6cb6b6a9fca7b2ff4
    local EK_ATTRS="fixedparent|fixedtpm|decrypt|sensitivedataorigin|userwithauth|noda"

    # Generate unique file for template, 0x10 0x00 (0x0010 = 16) is the size of unique data
    echo -ne '\x10\x00' > $ek_unique_data
    echo -ne $EK_UNIQUE_X | openssl dgst -sha256 -binary 2>/dev/null | head -c 16 >> $ek_unique_data 2>/dev/null
    echo -ne '\x10\x00' >> $ek_unique_data
    echo -ne $EK_UNIQUE_Y | openssl dgst -sha256 -binary 2>/dev/null | head -c 16 >> $ek_unique_data 2>/dev/null
    #od -tx1 $EK_UNIQUE

    # Get primary key
    tpm2_createprimary -c $context_obj -C e -G $EK_ALG -q $EK_OUTSIDE_INFO -a $EK_ATTRS -u $ek_unique_data > /dev/null
    log_if_error $? $FUNCNAME || return $?
 
    tpm2_readpublic -c $context_obj -f der -o $pubkey_der >/dev/null
    log_if_error $? $FUNCNAME || return $?

    # Convert and collect data in preferred format
    AZURE_DEV_WIFIDPP_ECCPUB_KEY=$(openssl ec -pubin -in $pubkey_der -inform der -conv_form compressed -outform DER 2>/dev/null | base64 - | tr -d '\n')
    log_if_error $? $FUNCNAME || return $?

    AZURE_DEV_WIFI_MAC=$(cat /sys/class/net/${HW_WIFIDPP_DEVICE}/address 2>/dev/null)
    log_if_error $? $FUNCNAME || return $?

    AZURE_DEV_WIFISOFTAP_PSK=$(openssl sha256 -binary $pubkey_der 2>/dev/null | base32 | awk '{print tolower($0)}' | tr -d '=\n' | cut -c -8)
    log_if_error $? $FUNCNAME || return $?
}

function print_device_record()
{
    # - This function will print out device record (according to hardware model) to standard output in JSON format
    # - Following JSON structure are for pe100|pe101.
    # - You may modify the JSON struture to customize for other hardware models.

    echo "{" 
    #echo "  \"Model\": \"${HW_MODEL}\"," 
    echo "  \"SerialNumber\": \"${HW_BOARD_SERIALNUM}\","
    echo "  \"LAN0MAC\": \"${HW_NETIF_MAC}\","
    echo "  \"TPM_EkPub\": \"${AZURE_DEV_TPM_ENDORSEMENT_KEY}\","
    echo "  \"TPM_EkPub_Digest\": \"${AZURE_DEV_REGISTRATION_ID}\","
    echo "  \"WifiDPP_EccPub\": \"${AZURE_DEV_WIFIDPP_ECCPUB_KEY}\","
    echo "  \"Wifi_MAC\": \"${AZURE_DEV_WIFI_MAC}\","
    echo "  \"Wifi-SoftAP_PSK\": \"${AZURE_DEV_WIFISOFTAP_PSK}\""
    echo "}"
}

function print_usage()
{
    echo "AED Manufacturing Tool - Provisioning Tool Sample - Usage"
    echo "Version: ${MFG_TOOL_VERSION}"
    echo "[Usage] aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh [-m|--model=<model_name>] [-n|--serialnum=<serial_number>] [--inittpm]"
    echo "           [-h|--help] [-f|--file=<output_filename>] [-c|--checkrequired] [-o|--overridesn] [-q|--query]"
    echo ""
}

function print_help()
{
    echo "AED Manufacturing Tool - Provisioning Tool Sample - Help"
    echo "Version: ${MFG_TOOL_VERSION}"
    echo "[Usage] aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh [OPTION...]"
    echo ""
    echo "Manufacturing featured options:"
    echo "  -m, --model=<model_name>        (Required) Name of supported models: ${MFG_TOOL_SUPPORTED_MODELS} ."
    echo "  -n, --serialnum=<serial_number> (Optional) Given serial number to be compared with what've read from hardware."
    echo "  -o, --overridesn                (Optional) Override device record with given serial number instead of serial number read from hardware."
    echo "  -f, --file=<output_filename>    (Optional) Redirect device record output from standard output to a file at /tmp."
    echo "  --inittpm                       (Optional) Clear TPM before to provision TPM."

    echo "Other options:"
    echo "  -h, --help           Apply this option solely to show help messages."
    echo "  -c, --checkrequired  Apply this option with \"-m=<model_name>\" to run system requirement check and then exit."
    echo "  -q, --query          Apply this option with \"-m=<model_name>\" to run this tool in query mode (dry-run) without re-provisioning TPM."
    echo ""
    echo "[Example]"   
    echo "- To run provisioning and check serialnumber on pe101 device:"
    echo "  > ./aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh -m=pe101 -n=11111101111110011000 ; echo rc=\$?"
    echo ""
    echo "- To run provisioning with clearing TPM and also check serialnumber on pe101 device:"
    echo "  > ./aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh -m=pe101 -n=11111101111110011000 --inittpm ; echo rc=\$?"
    echo ""        
    echo "- To run provisioning without check serialnumber on pe101 device:"
    echo "  > ./aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh -m=pe101 ; echo rc=\$?"
    echo ""
    echo "- To run without re-provisioning TPM (query only):"
    echo "  > ./aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh -m=pe101 -q ; echo rc=\$?"
    echo ""    
    echo "- To check system requirement on pe101 device:"
    echo "  > ./aed-mfgtool-azuredeviceprovision.${MFG_TOOL_PROD_TYPE}.sh -m=pe101 -c ; echo rc=\$?"
}

function process_commandline()
{
    local opt
    local val
    local state="p"

    if [ -z "$1" ]; then
         print_usage
         exit 1
    fi

    while [ ! -z "$1" ]; do
        opt=$(echo $1 | awk -F= '{print $1}')
        val=$(echo $1 | awk -F= '{print $2}')
        #echo "opt=$opt, val=$val" >&2
        case $opt in
        -h | --help)
            print_help
            exit 0
            ;;
        -c | --checkrequired)
            MFG_TOOL_OPT_CHECKREQUIRED=1
            ;;
        -f | --file)
            if [ -z "$val" ]; then 
                log_if_error 1 $FUNCNAME "no file path is specified." || exit $?
            fi
            [ ! -f "/tmp/$val" ] && printf "" > "/tmp/$val"
            if [ -f "/tmp/$val" ]; then
                MFG_TOOL_OPT_OUTPUTFILE=/tmp/$val
            else 
                log_if_error 1 $FUNCNAME "filename is invalid or file cannot be created!" || exit $?
            fi
            ;;
        --inittpm)
            # clear TPM and provision TPM
            MFG_TOOL_OPT_NOPROVISION=0
            MFG_TOOL_OPT_INITTPM=1
            state+="i"
            ;;
        -q | --query)
            # when query mode is on, no_provision should be set to true
            MFG_TOOL_OPT_NOPROVISION=1
            state+="q"
            ;;
        -m | --model)
            if [ -z "$val" ]; then
               log_if_error 1 $FUNCNAME "no model name specified." || exit $?
            fi
            MFG_TOOL_OPT_MODEL=$val
            ;;
        -n | --serialnum)
            #if [ -z "$val" ]; then
            #    log_if_error 1 $FUNCNAME "no serial number is specified." || exit $?
            #fi
            MFG_TOOL_OPT_SERIALNUM=$val
            ;;
        -o | --overridesn)
            MFG_TOOL_OPT_OVERRIDESN=1
            ;;
        *)
            log_if_error 1 $FUNCNAME "unknown commandline option \"$opt\"."
            print_usage
            exit 1
            ;;
        esac
        shift
    done
    if ((echo $state | grep i >/dev/null) && (echo $state | grep q >/dev/null)); then
        log_if_error 1 $FUNCNAME "'--inittpm' cannot be used with '-q'."
        print_usage
        exit 1
    fi
    if [ "$state" = "p" ]; then
        echo "INFO: TPM provisioning will be run without clearing TPM." >&2
    fi
    if (echo $state | grep i >/dev/null); then
        echo "INFO: TPM will be cleared with provisioning." >&2
    fi
}

function run_azure_device_provision()
{
    # - This function will do device provisioning, capturing device identity, 
    #   and then printing out device record (according to hardware model) to standard output in JSON format
    # - Following provisioning/capturing steps are for pe100|pe101.
    # - You may modify the steps and functions called here to customized for other hardware models.

    get_serial_number ${MFG_TOOL_OPT_SERIALNUM} || return $?
    init_tpm ${MFG_TOOL_OPT_NOPROVISION} ${MFG_TOOL_OPT_INITTPM} || return $?
    get_tpm_ek_pubdata || return $?
    get_netif_mac || return $?
    get_wifidpp_pubdata || return $?

    if [ ! -z ${MFG_TOOL_OPT_OUTPUTFILE} ]; then
        print_device_record >${MFG_TOOL_OPT_OUTPUTFILE} || return $?
        echo "Find output at ${MFG_TOOL_OPT_OUTPUTFILE}" >&2
    else
        print_device_record || return $?
    fi
}

##################################
# main workflow starts from here
##################################

set -o pipefail

# process commandline to get options
process_commandline $@

# set model
set_model ${MFG_TOOL_OPT_MODEL} || exit $?

# check system requirement if user enable this option
if [ ${MFG_TOOL_OPT_CHECKREQUIRED} -ne 0 ]; then
    check_system_requirement
    exit $?
fi

run_azure_device_provision 
clean_and_exit $?
