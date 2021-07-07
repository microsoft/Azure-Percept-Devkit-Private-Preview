# Collect your device’s TPM-derived SoftAP password

The SoftAP Tool allows you to access your Project Santa Cruz AI Perception Devkit’s TPM-derived SoftAP password and print it to the console.

New devices built and shipped after 11/17/2020 will contain a Welcome card with your unique SoftAP password printed on a sticker. It is highly recommended that you keep this sticker so you can refer to it when needed. If you do not have a sticker or it was misplaced, you will need to complete the following tasks to retrieve your TPM-derived password from the device.

### What is SoftAP?

SoftAP, or software-enabled access point, allows your device to act as a wireless access point/hotspot through its integrated Wi-Fi module. By connecting to your device's SoftAP hotspot, you can set your device settings through the [onboarding exerience](https://docs.microsoft.com/en-us/azure/azure-percept/quickstart-percept-dk-set-up) or [SSH into your device](https://docs.microsoft.com/en-us/azure/azure-percept/how-to-ssh-into-percept-dk) for [troubleshooting](https://docs.microsoft.com/en-us/azure/azure-percept/troubleshoot-dev-kit) and [USB updates](https://docs.microsoft.com/en-us/azure/azure-percept/how-to-update-via-usb), even if your device is not yet connected to your home or office network over Wi-Fi or Ethernet.

## Prerequisites

- [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html)
- Host PC
- Project Santa Cruz AI Perception Devkit (PE100 or PE101)

## Using the tool

1. Power on your device.

1. Open PuTTY and [SSH into your device](https://docs.microsoft.com/en-us/azure/azure-percept/how-to-ssh-into-percept-dk).

1. In the PuTTY terminal, enter the following command to download the SoftAP Tool directly to your devkit:

    ```bash
    wget https://raw.githubusercontent.com/microsoft/Azure-Percept-Devkit-Private-Preview/main/tools/SoftAP-access-info-tool/scz-tool-wifisoftap-accessinfo.devkit.sh
    ```

1. Once you have downloaded the file, change the permissions of the file to allow execution:  

    ```bash
    chmod 755 ./scz-tool-wifisoftap-accessinfo.devkit.sh
    ```

1. Execute the file on your device to output your TPM-derived SoftAP password. If you are not signed in as root, you must add ```sudo``` in front of the command and enter your SSH username and password when prompted.

    If you are logged in as root, enter this command:
    ```bash
    ./scz-tool-wifisoftap-accessinfo.devkit.sh -m=pe101
   ```
   Otherwise, enter the following:
    ```bash
    sudo ./scz-tool-wifisoftap-accessinfo.devkit.sh -m=pe101
    ```

    > [!NOTE]
    > If your device model is PE100, change the command to ```./scz-tool-wifisoftap-accessinfo.devkit.sh -m=pe100```.

    Example output:

    ```bash
    Wifi-SoftAP MAC Address: 1234567890ab
    Wifi-SoftAP SSID: scz-0000
    Wifi-SoftAP Pre-Shared Key: asdf1234  
    ```

1. The ```Wifi-SoftAP Pre-Shared Key``` is your devkit’s TPM-derived SoftAP password. Write down and securely store this password.
