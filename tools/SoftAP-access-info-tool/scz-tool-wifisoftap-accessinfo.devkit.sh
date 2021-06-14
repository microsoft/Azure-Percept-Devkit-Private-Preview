#!/bin/bash

#=================================================================================
# -----------------------------
#  Print Wifi SoftAP Info  
# -----------------------------  
#  Target Device
#  - Santa Cruz project devkit: PE100/PE101 
#
#  Following Wifi SoftAP info will be printed:
#    - Wifi SoftAP SSID
#    - Wifi SoftAP Pe-Shared Key
#
#=================================================================================

MFG_TOOL_VERSION="1.0.201112.1001"
MFG_TOOL_PROD_TYPE="devkit"
MFG_TOOL_SUPPORTED_MODELS="pe100 pe101"
HW_WIFISOFTAP_DEVICE="wlan1"

MFG_TOOL_OPT_MODEL=
MFG_TOOL_OPT_CHECKREQUIRED=1

HW_MODEL=

AZURE_DEV_WIFISOFTAP_MAC=
AZURE_DEV_WIFISOFTAP_SSID=
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

    #echo "Check system requirement for model ${HW_MODEL} ..." >&2

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
    if [ ! -f "/sys/class/net/${HW_WIFISOFTAP_DEVICE}/address" ]; then
        echo "ERROR: Hw device - ${HW_WIFISOFTAP_DEVICE} - Not found!" >&2
        (( err += 1 ))
    fi

    # hardware: tpm0 existance
    if [ ! -e "/dev/tpm0" ]; then
        echo "ERROR: Hw device - tpm0 - Not found!" >&2
        (( err += 1 ))
    fi

    #[ $err -eq 0 ] && echo "Passed!" >&2

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

function get_wifisoftap_accessinfo()
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

    AZURE_DEV_WIFISOFTAP_MAC=$(cat /sys/class/net/${HW_WIFISOFTAP_DEVICE}/address 2>/dev/null | tr -d ':' )
    log_if_error $? $FUNCNAME || return $?

    AZURE_DEV_WIFISOFTAP_SSID="scz-${AZURE_DEV_WIFISOFTAP_MAC:8:4}"
    AZURE_DEV_WIFISOFTAP_PSK=$(openssl sha256 -binary $pubkey_der 2>/dev/null | base32 | awk '{print tolower($0)}' | tr -d '=\n' | cut -c -8)
    log_if_error $? $FUNCNAME || return $?
}

function print_wifisoftap_accessinfo()
{ 
    echo "  Wifi-SoftAP MAC Address: ${AZURE_DEV_WIFISOFTAP_MAC}"
    echo "  Wifi-SoftAP SSID: ${AZURE_DEV_WIFISOFTAP_SSID}"
    echo "  Wifi-SoftAP Pre-Shared Key: ${AZURE_DEV_WIFISOFTAP_PSK}"
}

function print_usage()
{
    echo "SCZ Tool - Print Wifi-SoftAP Access Info - Usage"
    echo "Version: ${MFG_TOOL_VERSION}"
    echo "[Usage] scz-tool-wifisoftap-accessinfo.${MFG_TOOL_PROD_TYPE}.sh [-m|--model=<model_name>] [-h|--help]"
    echo ""
}

function print_help()
{
    echo "SCZ Tool - Print Wifi-SoftAP Access Info - Help"
    echo "Version: ${MFG_TOOL_VERSION}"
    echo "[Usage] scz-tool-wifisoftap-accessinfo.${MFG_TOOL_PROD_TYPE}.sh [OPTION...]"
    echo ""
    echo "Manufacturing featured options:"
    echo "  -m, --model=<model_name>        (Required) Name of supported models: ${MFG_TOOL_SUPPORTED_MODELS} ."

    echo "Other options:"
    echo "  -h, --help           Apply this option solely to show help messages."
    echo ""
    echo "[Example]"   
    echo "- To print Wifi SoftAP access info:"
    echo "  > ./scz-tool-wifisoftap-accessinfo.${MFG_TOOL_PROD_TYPE}.sh -m=pe101"
    echo ""
}

function process_commandline()
{
    local opt
    local val

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
        -m | --model)
            if [ -z "$val" ]; then
               log_if_error 1 $FUNCNAME "no model name specified." || exit $?
            fi
            MFG_TOOL_OPT_MODEL=$val
            ;;
        *)
            log_if_error 1 $FUNCNAME "unknown commandline option \"$opt\"."
            print_usage
            exit 1
            ;;
        esac
        shift
    done
}

function run_get_wifisoftapp_accessinfo()
{
    get_wifisoftap_accessinfo || return $?
    print_wifisoftap_accessinfo || return $?
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
    check_system_requirement || exit $?
fi

run_get_wifisoftapp_accessinfo
clean_and_exit $?
