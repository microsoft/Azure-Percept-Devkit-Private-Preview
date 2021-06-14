# Manufacturing provisioning tool sample script for Project Santa Cruz devices

## Introduction

The manufacturing provisioning tool sample script is a Linux shell script that allows Santa Cruz device manufacturers to capture device identities or hardware keys in the manufacturing line. The tool generates a “device record” with those hardware identities, which it can output directly or save to a JSON file.
The device record can then be used in a post-manufacturing process to provision each device to Azure and enable Wi-Fi Zero-Touch Provisioning. Please note that **this tool only covers “collecting” the information for provisioning and does not handle the actual enrollment process to Azure**.

## Prerequisites

This script currently supports the following hardware. With minor customization (if necessary), it may support other Santa Cruz devices that are loaded with Mariner OS.
 - PE100 (i.MX 8)
 - DKSC-101 (i.MX 8): this is the Project Santa Cruz devkit, sometimes referred to as the PE101.

Additionally, the Santa Cruz device must meet the following environment requirements:

 - Microsoft Mariner OS.
	 - (With the other dependences listed below fulfilled, this tool should be able to run on various Linux distros or just need minor modifications.)
 - TPM must be enabled.
 - TPM tool package ([tpm2-tools v4.2](https://github.com/tpm2-software/tpm2-tools/wiki)) must be included in the device's Mariner OS.
	 - For the Wi-Fi ZTP key feature, the version of tpm2-tools must be 4.2 or later. No action is needed for the PE100/DKSC-101 if using the private preview image.
 - The Serial Number of the device must be stored in permanent memory (e.g. EEPROM) and properly exposed to the OS.

## Usage

### Syntax

    aed-mfgtool-azuredeviceprovision.devkit.sh [-m|--model=<model_name>] [-n|--serialnum=<serial_number>] [--inittpm]
    [-h|--help] [-f|--file=<output_filename>] [-c|--checkrequired] [-o|--overridesn] [-q|--query]
    
### Parameters

Manufacturing options:

    -m, --model=<model_name> (Required)
        Name of supported models: pe100 pe101.
        (pe101 is for DKSC-101)
    -n, --serialnum=<serial_number> (Optional)
        Give a serial number to be compared with what is read from the hardware. When this parameter is provided,
        if the input serial number does not match the hardware serial number,
        the tool will output an error and will not return the device record. 
    -o, --overridesn (Optional)
        Override the device record with the given serial number instead of the serial number read from the hardware.
        (This approach is not recommended, but it is an alternative when the S/N is not yet stored in the firmware.)
    -f, --file=<output_filename> (Optional)
        Redirect device record output from standard output to a file at /tmp.
    --inittpm (Optional)
        Clear the TPM before reprovisioning the TPM. When this parameter is used, the tool calls the following tpm2-tools commands:
		tpm2_clear -c p
		tpm2_clear -c l

Other options:

    -h, --help
	    Shows help messages.
    -c, --checkrequired
	    Apply this option with "-m=<model_name>" to run system requirement check and then exit.
    -q, --query
	    Apply this option with "-m=<model_name>" to run this tool in query mode (dry-run) without re-provisioning the TPM.
	  
### Tool execution and example

To execute this tool, first SSH into the target device (PE100/DKSC-101). Next, copy the script file (aed-mfgtool-azuredeviceprovision.devkit.sh) to the target device by entering the following command:

    scp [local file path]\aed-mfgtool-azuredeviceprovision.devkit.sh root@[remote server]:/[path to destination]
    
Make the script executable:

    chmod 755 ./aed-mfgtool-azuredeviceprovision.devkit.sh
    

Script execution examples:

 - To run provisioning and check the serial number on a DKSC-101 device:
	 - `> ./aed-mfgtool-azuredeviceprovision.devkit.sh -m=pe101 -n=11111101111110011000 ; echo rc=$?`
 - To run provisioning without checking the serial number on a DKSC-101 device:
	 - `> ./aed-mfgtool-azuredeviceprovision.devkit.sh -m=pe101 ; echo rc=$?`
 - To check the system requirements on a DKSC-101 device:
	 - `> ./aed-mfgtool-azuredeviceprovision.devkit.sh -m=pe101 -c ; echo rc=$? `

Output example:

    root@mariner-machine [ ~ ]# ./aed-mfgtool-azuredeviceprovision.devkit.sh -m=pe101 -n=11111101111110011000; echo rc=$?
    {
    "SerialNumber": "11111101111110011000",
    "LAN0MAC": "01:02:03:04:05:06",
    "TPM_EkPub": "AToAA...JznbfyQ==",
    "TPM_EkPub_Digest": "b5dk...baq",
    "WifiDPP_EccPub": "MFkw...piog==",
    "Wifi_MAC": "0A:0B:03:04:05:06",
    "Wifi-SoftAP_PSK": "sdf234wh"
    }
    rc=0

### Description of output data

The following device identity/information (if applicable to the hardware) shall print before the script generates the device record.

 - SerialNumber
	 - This shall be the key for associating the other device identities with the actual hardware. (Microsoft strongly recommends that the S/N should be visible on the device. That way, there is an easy way to associate a physical device with its virtual copy on the Azure side.)
 - TPM_EkPub
	 - This key can be used as the secrete key for connecting the device to Azure IoT Hub.
 - TPM_EkPub_Digest
	 - This hash can be used as the Enrollment Device ID for registering the device to the Azure DPS service.
 - LAN0MAC
	 - Ethernet MAC address.
 - WifiDPP_EccPub
	 - This is a derivative ID from the TPM key. It is used for enabling the Wi-Fi ZTP (Zero Touch Provisioning) feature.
 - Wifi_MAC
	 - Used for enabling the Wi-Fi ZTP (Zero Touch Provisioning) feature. Can also serve as a secondary device identity if necessary.
**[Note]** WifiDPP_EccPub and Wifi_MAC are only required if the manufacturer wants to enable the Wi-Fi ZTP feature and the Wi-Fi module is included in the hardware design. However, pre-recording the WifiDPP_EccPub at the manufacturing stage would make the experience of future hardware/function expansion more seamless. (i.e. if there is a chance that the SI/customer will install the Wi-Fi module and enable ZTP later, they would already have the ECC Key.)
 - Wifi-SoftAP_PSK
	 - This is also a derivative ID from the TPM key. It is the default password of the Wi-Fi SoftAP.

## Known issues

 - [Fixed] Support for DKSC-101 to be enabled. 
 - [Fixed] Wi-Fi ZTP key provisioning and capturing is not implemented yet. Will be providing in future version of script. 
 - [Won’t fix] For some early preview hardware (S/N: 1624662100xxx203xxxx), the tool cannot retrieve the completed S/N (last 4 digits will be “0000”). This is caused by a hardware issue, not the tool itself.

## Issue reporting

For any issues or feedback related to the manufacturing provisioning tool, please file an issue on GitHub.

1. Log in to the [Project Santa Cruz GitHub repo](https://github.com/microsoft/Project-Santa-Cruz-Preview/)
2. Select **Issues**, then **New issue**.
3. Use the prefix “**[MFG Script]**”, followed by a clear title of the issue.
4. Provide a description and attach the error log, if any.

## Release notes

| Version | Release Date | Description |
|--|--|--|
| 0.1.200417.1 | April 24, 2020 | Beta version released. |
| 0.2.200501.1 | May 20, 2020 | -Support for PE101 <br>-Provision/capture of Wi-Fi ZTP key enabled. |
| 0.3.200706.1 | July 10, 2020 | -Support for reading S/N on Mariner OS and checking mechanism.<br>-Modified/added new fields: "WifiDPP_MAC, "WifiDPP_PSK". |
| 0.4.200806.1 | August 15. 2020 | Minor bug fix. |
| 1.0.201112.1001 | November 13. 2020 | (Open source version)<br>-Rename WifiDPP_PSK to Wifi-SoftAP_PSK. |
