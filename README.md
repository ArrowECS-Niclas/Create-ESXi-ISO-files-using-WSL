# Create-ESXi-ISO-files-using-WSL
Creates ESXi ISO files using WSL + genisoimage.

This script is intened for Windows users that want to create a customized ESXi iso image with automatic configuration using a kickstart file. Windows Subsystem for Linux (WSL) is going to be used on the Windows machine to create the iso image using genisoimage in WSL.

The script will create a bootable image from the files located in the $BinariesDir folder, if that folder is empty it will as for a path to an existing esxi iso image on your local drive, mount the image and copy the files to the $BinariesDir folder.

## How to use
The kickstart file (KS.CFG) for each host should be available on a web server with a folder name corresponding to the host name, **http://webserver/kickstart/hostname/KS.CFG**  
For example  
http://webserver/kickstart/ESXi01/KS.CFG  
http://webserver/kickstart/ESXi02/KS.CFG  
http://webserver/kickstart/ESXi03/KS.CFG  

If $MediaType is set to http the script will change **boot.cfg** and **efi/boot/boot.cfg** to read the kickstart file from the web server by updating  
`kernelopt=ks=http://webserver/kickstart/hostname/KS.CFG` and it will be read during installation.  
But if $MediaType is set to either USB or CD the script will copy the **KS.CFG** file to the $BinariesDir and change **boot.cfg** and **efi/boot/boot.cfg** to use a local kickstart file:
`kernelopt=ks=cdrom:/KS.CFG`  
`kernelopt=ks=usb:/KS.CFG`  

The iso file generated will be named using the host name and append the version of the source ESXi iso image by extracting the build label from the file **boot.cfg**, i.e ESX01-9.1.1-0.25714478.iso, ESX02-9.1.1-0.25714478.iso, ESX03-9.1.1-0.25714478.iso and so on.

| Variable          | Description                                   |
| ----------------- | --------------------------------------------- |
| $BinariesDir      | Working directory containing the ESXi files   |
| $IsoOutDir        | Destination folder for the finished ISO files |
| $KickstartBaseUrl | Base URL used for kickstartfiles              |
| $MediaType        | Installation method (http, USB, or CD)        |
| $HostConfigDir    | List of hosts to generate ISOs for            |
