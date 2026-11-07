#Requires -Version 5.1
<#
.SYNOPSIS
    Creates ESXi ISO files using WSL + genisoimage.
    Version is automatically read from the "build" variable in boot.cfg / BOOT.CFG.
    Updates kernelopt in boot.cfg and efi\boot\boot.cfg per host.
    Supports install media: http | USB | CD
    Can import files from an existing ESXi ISO if BinariesDir is empty.
#>

# ============================================================
# Configuration
# ============================================================
$BinariesDir      = "C:\ESXi91"
$IsoOutDir        = "C:\ISO_images"
$WslDistro        = "Ubuntu"
$WslUserHome      = "/home/nibo"

# Kickstart base URL
$KickstartBaseUrl = "http://192.168.0.76/kickstart/"

# Select install media: "http", "USB" or "CD"
$MediaType        = "http"

$HostConfigDir    = @("ESX01", "ESX02", "ESX03")

# ============================================================
# Helper functions
# ============================================================
function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "Created directory: $Path"
    }
}

function Test-DirectoryEmpty {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
    return ($null -eq $items -or $items.Count -eq 0)
}

function Get-WslPath {
    param([string]$WindowsPath)
    $drive = $WindowsPath.Substring(0, 1).ToLower()
    $rest  = $WindowsPath.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function Test-WslAvailable {
    # Check if wsl.exe exists
    try {
        $null = Get-Command wsl -ErrorAction Stop
    }
    catch {
        throw "WSL (Windows Subsystem for Linux) is not installed or not available in PATH.`nInstall it with: wsl --install"
    }

    # Check if the specified distribution exists
    $distros = wsl -l -q 2>$null
    if (-not $distros) {
        throw "No WSL distributions found. Install one with: wsl --install -d $WslDistro"
    }

    $distroFound = $false
    foreach ($d in $distros) {
        if ($d.Trim() -eq $WslDistro) {
            $distroFound = $true
            break
        }
    }

    if (-not $distroFound) {
        $available = ($distros | ForEach-Object { $_.Trim() }) -join ", "
        throw "WSL distribution '$WslDistro' was not found.`nAvailable distributions: $available"
    }

    # Quick test that the distro can actually start
    $test = wsl -d $WslDistro -- echo OK 2>$null
    if ($test -ne "OK") {
        throw "WSL distribution '$WslDistro' exists but failed to start. Try running: wsl -d $WslDistro"
    }

    Write-Host "WSL distribution '$WslDistro' is available." -ForegroundColor Green
}

function Find-BootFile {
    param(
        [string]$BinariesDir,
        [string[]]$PossibleNames
    )
    foreach ($name in $PossibleNames) {
        $found = Get-ChildItem -Path $BinariesDir -Filter $name -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.Name }
    }
    return $null
}

function Import-FromEsxiIso {
    param([string]$BinariesDir)

    Write-Host ""
    $answer = Read-Host "BinariesDir is empty. Do you want to import files from an existing ESXi ISO? (Y/N)"
    if ($answer -notmatch '^[Yy]') {
        throw "BinariesDir is empty and import was declined. Aborting."
    }

    $isoPath = Read-Host "Enter full path to the ESXi ISO file"
    $isoPath = $isoPath.Trim().Trim('"')

    if (-not (Test-Path $isoPath)) {
        throw "ISO file not found: $isoPath"
    }

    Write-Host "Mounting ISO: $isoPath"
    $mountResult = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $driveLetter = ($mountResult | Get-Volume).DriveLetter

    if (-not $driveLetter) {
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        throw "Failed to get drive letter for mounted ISO."
    }

    $sourcePath = "$driveLetter`:"
    Write-Host "ISO mounted as $sourcePath"

    try {
        Write-Host "Copying files from $sourcePath to $BinariesDir ..."
        $robocopyArgs = @(
            $sourcePath,
            $BinariesDir,
            "/E", "/IS", "/IT",
            "/R:2", "/W:3",
            "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS"
        )
        & robocopy @robocopyArgs | Out-Null

        if ($LASTEXITCODE -ge 8) {
            throw "Robocopy failed with exit code $LASTEXITCODE"
        }

        # Clear Read-only attribute on all copied files
        Write-Host "Clearing Read-only attributes..."
        Get-ChildItem -Path $BinariesDir -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) }

        Write-Host "Files successfully copied to $BinariesDir" -ForegroundColor Green
    }
    finally {
        Write-Host "Dismounting ISO..."
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
    }
}

function Get-VersionFromBootCfg {
    param([string]$BinariesDir)

    $bootCfgFile = Get-ChildItem -Path $BinariesDir -Filter "boot.cfg" -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1

    if (-not $bootCfgFile) {
        $bootCfgFile = Get-ChildItem -Path $BinariesDir -Filter "BOOT.CFG" -File -ErrorAction SilentlyContinue |
                       Select-Object -First 1
    }

    if (-not $bootCfgFile) {
        throw "Neither boot.cfg nor BOOT.CFG found in $BinariesDir"
    }

    Write-Host "Reading version from: $($bootCfgFile.FullName)"

    $buildLine = Get-Content $bootCfgFile.FullName -ErrorAction Stop |
                 Where-Object { $_ -match '^\s*build\s*=' } |
                 Select-Object -First 1

    if (-not $buildLine) {
        throw "Could not find 'build =' in $($bootCfgFile.FullName)"
    }

    $version = ($buildLine -split '=', 2)[1].Trim()

    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "build value is empty in $($bootCfgFile.FullName)"
    }

    $version = $version -replace '[\\/:*?"<>|]', '_'

    Write-Host "Found build/version: $version" -ForegroundColor Green
    return $version
}

function Update-KernelOpt {
    param(
        [string]$BinariesDir,
        [string]$HostName,
        [string]$MediaType
    )

    switch ($MediaType.ToUpper()) {
        "HTTP" {
            $ksHostName = $HostName -replace '^ESX', 'ESXi'
            $newKernelOpt = "kernelopt=ks=$KickstartBaseUrl$ksHostName/KS.CFG"
        }
        "USB" {
            $newKernelOpt = "kernelopt=ks=usb:/KS.CFG"
        }
        "CD" {
            $newKernelOpt = "kernelopt=ks=cdrom:/KS.CFG"
        }
        default {
            throw "Invalid value for MediaType: '$MediaType'. Allowed values: http, USB, CD"
        }
    }

    $bootCfgFiles = @(
        (Join-Path $BinariesDir "boot.cfg"),
        (Join-Path $BinariesDir "efi\boot\boot.cfg")
    )

    foreach ($file in $bootCfgFiles) {
        if (-not (Test-Path $file)) {
            Write-Warning "File not found: $file – skipping"
            continue
        }

        # Clear Read-only attribute before writing
        $item = Get-Item $file -Force
        if ($item.IsReadOnly) {
            $item.IsReadOnly = $false
        }

        Write-Host "Updating kernelopt in $file → $newKernelOpt"

        $content = Get-Content $file -Raw -ErrorAction Stop

        if ($content -match '(?m)^\s*kernelopt\s*=.*$') {
            $content = $content -replace '(?m)^\s*kernelopt\s*=.*$', $newKernelOpt
        }
        else {
            $content = $content.TrimEnd() + "`r`n$newKernelOpt`r`n"
        }

        Set-Content -Path $file -Value $content -Encoding ASCII -NoNewline
    }
}

function Copy-KickstartFile {
    param(
        [string]$HostName,
        [string]$BinariesDir
    )

    $ksHostName = $HostName -replace '^ESX', 'ESXi'
    $sourceUrl  = "$KickstartBaseUrl$ksHostName/KS.CFG"
    $destKs     = Join-Path $BinariesDir "KS.CFG"

    Write-Host "Downloading KS.CFG from $sourceUrl → $destKs"

    try {
        Invoke-WebRequest -Uri $sourceUrl -OutFile $destKs -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Failed to download KS.CFG from $sourceUrl : $($_.Exception.Message)"
    }

    if (-not (Test-Path $destKs)) {
        throw "KS.CFG missing after download: $destKs"
    }
}

function Remove-KickstartFile {
    param([string]$BinariesDir)

    $ksFile = Join-Path $BinariesDir "KS.CFG"
    if (Test-Path $ksFile) {
        Write-Host "Removing $ksFile"
        Remove-Item -Path $ksFile -Force
    }
}

function New-IsoInWsl {
    param(
        [string]$IsoName,
        [string]$SourcePathInWsl,
        [string]$BiosBootImage,
        [string]$EfiBootImage
    )

    $wslIsoPath = "$WslUserHome/$IsoName"

    $genisoCmd = "cd $WslUserHome && genisoimage -relaxed-filenames -J -R -o `"$IsoName`" -b `"$BiosBootImage`" -c BOOT.CAT -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e `"$EfiBootImage`" -no-emul-boot `"$SourcePathInWsl`""

    Write-Host "Running genisoimage in WSL → $IsoName ..."
    Write-Host "  BIOS boot image : $BiosBootImage"
    Write-Host "  EFI  boot image : $EfiBootImage"

    wsl -d $WslDistro -- bash -c $genisoCmd

    if ($LASTEXITCODE -ne 0) {
        throw "genisoimage failed for $IsoName (exit code $LASTEXITCODE)"
    }

    $check = wsl -d $WslDistro -- bash -c "test -f '$wslIsoPath' && echo OK || echo FAIL"
    if ($check.Trim() -ne "OK") {
        throw "ISO file not found after creation: $wslIsoPath"
    }
    Write-Host "ISO created: $wslIsoPath" -ForegroundColor Green
}

function Move-IsosToWindows {
    param([string[]]$IsoNames)

    Ensure-Directory -Path $IsoOutDir

    foreach ($iso in $IsoNames) {
        $wslSource = "\\wsl.localhost\$WslDistro$WslUserHome\$iso"
        $dest      = Join-Path $IsoOutDir $iso

        if (-not (Test-Path $wslSource)) {
            Write-Warning "Could not find $wslSource – skipping"
            continue
        }

        Write-Host "Moving $iso → $IsoOutDir"
        Move-Item -Path $wslSource -Destination $dest -Force
    }
}

# ============================================================
# Main flow
# ============================================================
try {
    Write-Step "Checking prerequisites"

    # Validate MediaType
    $allowedMedia = @("http", "USB", "CD")
    if ($MediaType -notin $allowedMedia) {
        throw "MediaType must be one of: $($allowedMedia -join ', '). You specified: '$MediaType'"
    }

    # Check WSL
    Test-WslAvailable

    # Check / install genisoimage
    $wslCheck = wsl -d $WslDistro -- which genisoimage 2>$null
    if (-not $wslCheck) {
        Write-Host "genisoimage is missing in WSL. Installing..." -ForegroundColor Yellow
        wsl -d $WslDistro -- sudo apt-get update
        wsl -d $WslDistro -- sudo apt-get install -y genisoimage

        # Verify installation
        $wslCheck = wsl -d $WslDistro -- which genisoimage 2>$null
        if (-not $wslCheck) {
            throw "Failed to install genisoimage in WSL."
        }
        Write-Host "genisoimage installed successfully." -ForegroundColor Green
    }

    # Ensure BinariesDir exists
    Ensure-Directory -Path $BinariesDir

    # If BinariesDir is empty → offer to import from an existing ESXi ISO
    if (Test-DirectoryEmpty -Path $BinariesDir) {
        Write-Step "BinariesDir is empty"
        Import-FromEsxiIso -BinariesDir $BinariesDir
    }

    # Locate boot images (handles different casing)
    $biosBoot = Find-BootFile -BinariesDir $BinariesDir -PossibleNames @("isolinux.bin", "ISOLINUX.BIN", "Isolinux.bin")
    $efiBoot  = Find-BootFile -BinariesDir $BinariesDir -PossibleNames @("efiboot.img", "EFIBOOT.IMG", "Efiboot.img")

    if (-not $biosBoot) {
        throw "Could not find isolinux.bin (BIOS boot image) in $BinariesDir. Cannot create hybrid ISO."
    }
    if (-not $efiBoot) {
        throw "Could not find efiboot.img (EFI boot image) in $BinariesDir. Cannot create hybrid ISO."
    }

    Write-Host "Found BIOS boot image: $biosBoot"
    Write-Host "Found EFI  boot image: $efiBoot"

    $BinariesDirInWsl = Get-WslPath -WindowsPath $BinariesDir
    Write-Host "WSL path for binaries: $BinariesDirInWsl"

    $createdIsos = @()
    $Version     = $null

    foreach ($folder in $HostConfigDir) {
        # Read version from boot.cfg / BOOT.CFG (only once)
        if (-not $Version) {
            $Version = Get-VersionFromBootCfg -BinariesDir $BinariesDir
        }

        # Download KS.CFG via HTTP if MediaType is USB or CD
        if ($MediaType -in @("USB", "CD")) {
            Write-Step "Downloading KS.CFG for $folder ($MediaType)"
            Copy-KickstartFile -HostName $folder -BinariesDir $BinariesDir
        }

        # Update kernelopt based on MediaType
        Write-Step "Updating kernelopt for $folder ($MediaType)"
        Update-KernelOpt -BinariesDir $BinariesDir -HostName $folder -MediaType $MediaType

        $isoName = "$folder-$Version.iso"

        Write-Step "$folder → $isoName"
        New-IsoInWsl -IsoName $isoName `
                     -SourcePathInWsl $BinariesDirInWsl `
                     -BiosBootImage $biosBoot `
                     -EfiBootImage $efiBoot

        # Remove KS.CFG after the ISO has been created
        if ($MediaType -in @("USB", "CD")) {
            Remove-KickstartFile -BinariesDir $BinariesDir
        }

        $createdIsos += $isoName
    }

    # Move all created ISO files to Windows
    Write-Step "Moving finished ISO files to Windows"
    Move-IsosToWindows -IsoNames $createdIsos

    Write-Host "`nDone! ISO files are located in:" -ForegroundColor Green
    Write-Host "  $IsoOutDir" -ForegroundColor Green
    Get-ChildItem $IsoOutDir -Filter "*.iso" | Format-Table Name, Length, LastWriteTime -AutoSize
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}