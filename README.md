# Create customized ESXi installer ISOs with WSL

`Create-IsoFiles-From-Source-Dir.ps1` creates one bootable VMware ESXi installer ISO per host. It runs in PowerShell on Windows and uses `genisoimage` in Windows Subsystem for Linux (WSL) to build images that support BIOS and UEFI boot. Each image is configured to load a host-specific Kickstart file (`KS.CFG`) for unattended installation.

## Prerequisites

- Windows with PowerShell 5.1 or later and a working WSL distribution.
- `genisoimage` in the selected distribution. If it is missing, the script attempts to install it using `sudo apt-get`, which requires an APT-based distribution, sudo access, and access to its package repositories.
- An original ESXi installer ISO or a complete set of extracted installer files. The script requires `isolinux.bin`, `efiboot.img`, and a root `boot.cfg` containing a `build=` value. Keep `efi/boot/boot.cfg` in the source tree so the script can update the UEFI boot options.
- A web server serving each host’s `KS.CFG`. In HTTP mode, the ESXi installer needs access to that server during installation. In USB and CD modes, Windows needs access during ISO creation.

## Configuration

Edit the variables at the top of the PowerShell script before running it.

| Variable | Default | Purpose |
| --- | --- | --- |
| `$RootDir` | `C:\ESXi` | Parent directory for the project folders. Use a drive-letter path accessible in WSL under `/mnt/<drive>`. |
| `$DepotDir` | `$RootDir\Depot` | Folder for original VMware installer ISOs. |
| `$BinariesDir` | `$RootDir\Binaries` | Working folder containing the extracted installer files. The script edits the boot configuration files here in place. |
| `$IsoOutDir` | `$RootDir\ISO` | Windows destination for the finished ISOs. |
| `$WslDistro` | `Ubuntu` | Installed WSL distribution to use. Run `wsl -l -q` to list distribution names. |
| `$WslUserHome` | `/home/nibo` | Existing, writable Linux directory where ISOs are built before being moved to Windows. Set it to the appropriate path for your WSL user. |
| `$MediaType` | `http` | How the installer reads Kickstart. Valid values are `http`, `USB`, and `CD`. |
| `$KickstartBaseUrl` | `http://192.168.0.76/kickstart/` | Base URL for host-specific Kickstart files in all three modes. Include the trailing slash. |
| `$HostConfigDir` | `@("ESX01", "ESX02", "ESX03")` | Array of host names. Each name supplies the ISO filename prefix and determines the Kickstart URL. |

## Kickstart files

Serve each file at `<KickstartBaseUrl><host-directory>/KS.CFG`. The script replaces a leading `ESX` with `ESXi` when constructing the URL. For example, with a base URL of `http://webserver/kickstart/`, host `ESX01` uses `http://webserver/kickstart/ESXi01/KS.CFG`. The ISO filename still uses `ESX01`.

The script sets `kernelopt` in `boot.cfg` and `efi/boot/boot.cfg` wherever those files are present. It replaces an existing setting or adds one if needed.

| `$MediaType` | Example `kernelopt` value | How Kickstart is loaded |
| --- | --- | --- |
| `http` | `kernelopt=ks=http://webserver/kickstart/ESXi01/KS.CFG` | The ESXi installer fetches the file at boot. |
| `USB` | `kernelopt=ks=usb:/KS.CFG` | The script downloads the file and includes it at the ISO root. The installer looks for it at the root of the USB media. |
| `CD` | `kernelopt=ks=cdrom:/KS.CFG` | The script downloads the file and includes it at the ISO root. The installer looks for it at the root of the CD-ROM media. |

In USB and CD modes, the script removes the downloaded `KS.CFG` from the working folder after each successful ISO build.

## Build the ISOs

1. Put a source ISO named `VMware-VMvisor-installer*.iso` or `VMware-ESXi*.iso` in `$DepotDir`. You can also populate `$BinariesDir` with already extracted installer files.
2. Publish the per-host Kickstart files and set the configuration variables.
3. From the script’s directory in PowerShell, run:

   ```powershell
   .\Create-IsoFiles-From-Source-Dir.ps1
   ```

If `$BinariesDir` is empty, the script selects the matching ISO in `$DepotDir` with the most recent file modification time. If it finds no match, it prompts for the full path to an ISO. It mounts the selected image, copies the installer files into `$BinariesDir`, and dismounts the image. When `$BinariesDir` already contains files, the script reuses them. To start from a different source ISO, point `$BinariesDir` at a new, empty working folder.

The output filename combines the host name and the `build=` value from the root `boot.cfg`, for example `ESX01-9.1.1-0.25714478.iso`. After building the images in WSL, the script moves them to `$IsoOutDir` through `\\wsl.localhost`. Existing ISOs with the same names can be overwritten. The working boot configuration retains the settings for the last host processed.
