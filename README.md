# Create customized ESXi installer ISOs with WSL

`Create-IsoFiles-From-Source-Dir.ps1` builds one ESXi installer ISO per host. It configures Kickstart for BIOS and UEFI boot.

## Prerequisites

- Windows PowerShell 5.1 or later and a WSL distribution with access to the Windows project directory.
- `genisoimage` in that distribution. On APT-based distributions, pass `-InstallDependencies` to let the script install it with `sudo apt-get`.
- An original ESXi installer ISO or a complete extracted installer tree containing `isolinux.bin`, `efiboot.img`, `boot.cfg` with a `build=` value, and `efi/boot/boot.cfg`.
- A web server hosting each host's `KS.CFG`. In HTTP mode, ESXi needs access at boot. In USB and CD modes, Windows needs access during the build.

## Run the script

```powershell
.\Create-IsoFiles-From-Source-Dir.ps1 -RootDir 'C:\ESXi' -HostName ESX01,ESX02 -MediaType HTTP -KickstartBaseUrl 'http://webserver/kickstart/'
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-RootDir` | `C:\ESXi` | Project directory. It must be accessible from Windows and WSL. |
| `-WslDistro` | `Ubuntu` | WSL distribution to use. |
| `-HostName` | `ESX01,ESX02,ESX03` | Unique host names used for filenames and Kickstart URLs. |
| `-MediaType` | `HTTP` | Kickstart location. Accepts `HTTP`, `USB`, or `CD`. |
| `-KickstartBaseUrl` | `http://192.168.0.76/kickstart/` | Base directory URL for host-specific Kickstart files. |
| `-SourceIso` | Automatic selection | Full or relative path to a specific installer ISO. |
| `-InstallDependencies` | Off | Allow APT to install a missing `genisoimage`. |

With `-SourceIso`, the script extracts that image into a temporary directory. Otherwise it uses a populated `Binaries` directory under the project root if present. If there are no extracted files, it selects the most recently modified `VMware-VMvisor-installer*.iso` or `VMware-ESXi*.iso` from `Depot` and extracts it for that run. Allow disk space for the extracted source, a per-host working copy, and the finished images.

## Kickstart and output

For host `ESX01`, the script requests `<KickstartBaseUrl>/ESXi01/KS.CFG`. It replaces a leading `ESX` with `ESXi` in the URL and uses the original host name in the ISO filename.

| Mode | Installer behavior |
| --- | --- |
| HTTP | Fetches the host's Kickstart file from its URL at boot. |
| USB | Looks for `ks=usb:/KS.CFG`. The build includes the downloaded file at the ISO root. |
| CD | Looks for `ks=cdrom:/KS.CFG`. The build includes the downloaded file at the ISO root. |

The script updates the `ks=` option in both boot configurations in a per-host working copy. It preserves other kernel options and cleans up the working files after each run.

Finished images appear in `<RootDir>\ISO`, with names such as `ESX01-9.1.1-0.25714478.iso`. A completed build replaces an existing image of the same name. If a later host fails, previously published images remain available.
