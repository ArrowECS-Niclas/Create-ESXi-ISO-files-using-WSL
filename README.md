# Create-ESXi-ISO-files-using-WSL-
Creates ESXi ISO files using WSL + genisoimage.

This script is intened for Windows users that want to create a customized ESXi iso image with automatic configuration using a kickstart file. Windows Subsystem for Linux (WSL) is going to be used on the Windows machine to create the iso image using genisoimage in WSL.

The kickstart file (KS.CFG) for each host will be available on a web server with a folder name corresponding to the host name, i.e http://webserver/kickstart/hostname/KS.CFG

The iso file generated will be named using the host name and append the version of the source ESXi iso image by extracting the build label from the file boot.cfg, i.e ESX01-9.1.1-0.25714478.iso, ESX02-9.1.1-0.25714478.iso, ESX03-9.1.1-0.25714478.iso and so on.
