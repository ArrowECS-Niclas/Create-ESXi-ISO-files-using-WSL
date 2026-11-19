#Requires -Version 5.1
<#
.SYNOPSIS
    Creates per-host ESXi installer ISOs with BIOS and UEFI Kickstart support.
#>
[CmdletBinding()]
param(
    [string]$RootDir = 'C:\ESXi',
    [string]$WslDistro = 'Ubuntu',
    [ValidateSet('HTTP', 'USB', 'CD')]
    [string]$MediaType = 'HTTP',
    [uri]$KickstartBaseUrl = 'http://192.168.0.76/kickstart/',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')]
    [string[]]$HostName = @('ESX01', 'ESX02', 'ESX03'),
    [string]$SourceIso,
    [switch]$InstallDependencies
)

$ErrorActionPreference = 'Stop'

function Invoke-Wsl {
    param([string[]]$ArgumentList)

    & wsl.exe -d $WslDistro --exec @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command '$($ArgumentList[0])' failed in '$WslDistro' (exit code $LASTEXITCODE)."
    }
}

function Get-WslPath {
    param([string]$WindowsPath)

    $path = Invoke-Wsl @('wslpath', '-a', '-u', $WindowsPath)
    if (-not $path -or -not $path.StartsWith('/')) {
        throw "Could not translate '$WindowsPath' to a WSL path."
    }
    return $path
}

function Copy-InstallerTree {
    param([string]$Source, [string]$Destination)

    & robocopy.exe $Source $Destination /E /R:2 /W:3 /NFL /NDL /NJH /NJS /NC /NS | Out-Host
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed copying '$Source' (exit code $LASTEXITCODE)."
    }
}

function Get-InstallerLayout {
    param([string]$Directory)

    $requiredFiles = @(
        'boot.cfg'
        'efi\boot\boot.cfg'
        'isolinux.bin'
        'efiboot.img'
    )
    $files = foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $Directory $relativePath
        $parent = Split-Path -LiteralPath $path
        $expectedName = Split-Path -Path $path -Leaf
        # Directory enumeration returns the on-disk casing required by genisoimage.
        $file = if (Test-Path -LiteralPath $parent -PathType Container) {
            Get-ChildItem -LiteralPath $parent -Filter $expectedName -File -Force |
                Where-Object Name -EQ $expectedName |
                Select-Object -First 1
        }
        if (-not $file) {
            throw "Required installer file missing: '$path'."
        }
        $file
    }

    $buildLine = Get-Content -LiteralPath $files[0].FullName |
        Where-Object { $_ -match '^\s*build\s*=' } |
        Select-Object -First 1
    if (-not $buildLine -or $buildLine -match '^\s*build\s*=\s*$') {
        throw "Missing build value in '$($files[0].FullName)'."
    }

    [pscustomobject]@{
        Version = (($buildLine -split '=', 2)[1].Trim() -replace '[\\/:*?"<>|\x00-\x1f]', '_')
        BootConfigs = $files[0..1]
        BiosImage = $files[2].Name
        EfiImage = $files[3].Name
    }
}

function Import-InstallerIso {
    param([string]$IsoPath, [string]$Destination)

    $image = Get-DiskImage -ImagePath $IsoPath
    $mountedHere = -not $image.Attached
    try {
        if ($mountedHere) {
            Write-Host "Mounting $IsoPath"
            $image = Mount-DiskImage -ImagePath $IsoPath -PassThru
        }
        $volume = $image | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
        if (-not $volume) {
            throw "No drive letter found for '$IsoPath'."
        }

        # Use a rooted path without a trailing backslash for native argument quoting.
        Copy-InstallerTree "$($volume.DriveLetter):\." $Destination
    }
    finally {
        if ($mountedHere -and $image.Attached) {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }
    }
}

function Set-KickstartOption {
    param([System.IO.FileInfo]$File, [string]$Kickstart)

    $kernelPattern = [regex]'(?im)^([ \t]*kernelopt[ \t]*=[ \t]*)([^\r\n]*)'
    # Match complete arguments so ks= inside another option's quoted value is preserved.
    $argumentPattern = [regex]'[ \t]*(?:"[^"]*"|''[^'']*''|[^ \t"'']+)+'
    $content = [IO.File]::ReadAllText($File.FullName)
    $option = "ks=$Kickstart"

    if ($kernelPattern.IsMatch($content)) {
        $content = $kernelPattern.Replace($content, {
            param($match)
            $options = $argumentPattern.Replace($match.Groups[2].Value, {
                param($argument)
                if ($argument.Value.TrimStart() -match '^ks=') { return '' }
                return $argument.Value
            }).Trim()
            if ($options) {
                return "$($match.Groups[1].Value)$options $option"
            }
            return "$($match.Groups[1].Value)$option"
        })
    }
    else {
        $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
        if ($content -and -not $content.EndsWith("`n")) {
            $content += $newline
        }
        $content += "kernelopt=$option$newline"
    }

    $File.IsReadOnly = $false
    [IO.File]::WriteAllText($File.FullName, $content, [Text.UTF8Encoding]::new($false))
}

try {
    if (-not $HostName -or ($HostName | Group-Object | Where-Object Count -gt 1)) {
        throw 'Specify one or more unique host names.'
    }
    if (-not $KickstartBaseUrl.IsAbsoluteUri -or $KickstartBaseUrl.Scheme -notin @('http', 'https') -or
        $KickstartBaseUrl.Query -or $KickstartBaseUrl.Fragment) {
        throw 'KickstartBaseUrl must be an absolute HTTP or HTTPS directory URL without a query or fragment.'
    }
    $kickstartBase = $KickstartBaseUrl.AbsoluteUri.TrimEnd('/') + '/'

    $null = Get-Command wsl.exe
    Invoke-Wsl @('true')
    $null = & wsl.exe -d $WslDistro --exec which genisoimage
    if ($LASTEXITCODE -ne 0) {
        if (-not $InstallDependencies) {
            throw "genisoimage is missing in '$WslDistro'. Install it there or rerun with -InstallDependencies."
        }
        Invoke-Wsl @('sudo', 'apt-get', 'update')
        Invoke-Wsl @('sudo', 'apt-get', 'install', '-y', 'genisoimage')
        Invoke-Wsl @('which', 'genisoimage') | Out-Null
    }

    $RootDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RootDir)
    $depotDir = Join-Path $RootDir 'Depot'
    $binariesDir = Join-Path $RootDir 'Binaries'
    $isoOutDir = Join-Path $RootDir 'ISO'
    $null = [IO.Directory]::CreateDirectory($depotDir)
    $null = [IO.Directory]::CreateDirectory($isoOutDir)

    $runId = [guid]::NewGuid().ToString('N')
    $workDir = Join-Path $RootDir ".esxi-$runId"
    $null = [IO.Directory]::CreateDirectory($workDir)
    try {
        $installer = $null
        if ($SourceIso) {
            $installer = Get-Item -LiteralPath $SourceIso
            $sourceDir = Join-Path $workDir 'Source'
        }
        elseif (Test-Path -LiteralPath $binariesDir -PathType Leaf) {
            throw "'$binariesDir' must be a directory."
        }
        elseif (Get-ChildItem -LiteralPath $binariesDir -Force -ErrorAction SilentlyContinue |
                Select-Object -First 1) {
            $sourceDir = $binariesDir
        }
        else {
            $installer = Get-ChildItem -LiteralPath $depotDir -File |
                Where-Object Name -Match '^VMware-(VMvisor-installer|ESXi).*\.iso$' |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if (-not $installer) {
                throw "No ESXi installer ISO found in '$depotDir'. Supply -SourceIso or populate '$binariesDir'."
            }
            $sourceDir = Join-Path $workDir 'Source'
        }

        if ($installer) {
            if ($installer -isnot [IO.FileInfo] -or $installer.Extension -ne '.iso') {
                throw "Source ISO must be an .iso file: '$installer'."
            }
            Import-InstallerIso $installer.FullName $sourceDir
        }

        $layout = Get-InstallerLayout $sourceDir
        $published = foreach ($name in $HostName) {
            $stage = Join-Path $workDir 'Host'
            $isoName = "$name-$($layout.Version).iso"
            $destination = Join-Path $isoOutDir $isoName
            $temporaryIso = Join-Path $isoOutDir ".$runId-$name.partial"
            Write-Host "Building $isoName"

            try {
                Copy-InstallerTree $sourceDir $stage
                $stagedLayout = Get-InstallerLayout $stage
                $ksHostName = $name -replace '^ESX', 'ESXi'
                $sourceUrl = "$kickstartBase$ksHostName/KS.CFG"
                $ksFile = Join-Path $stage 'KS.CFG'
                if (Test-Path -LiteralPath $ksFile -PathType Leaf) {
                    Remove-Item -LiteralPath $ksFile -Force
                }

                $kickstart = switch ($MediaType) {
                    'HTTP' { $sourceUrl }
                    'USB'  { 'usb:/KS.CFG' }
                    'CD'   { 'cdrom:/KS.CFG' }
                }
                if ($MediaType -in @('USB', 'CD')) {
                    Invoke-WebRequest -Uri $sourceUrl -OutFile $ksFile -UseBasicParsing
                    if ((Get-Item -LiteralPath $ksFile).Length -eq 0) {
                        throw "Empty Kickstart file downloaded from '$sourceUrl'."
                    }
                }
                foreach ($config in $stagedLayout.BootConfigs) {
                    Set-KickstartOption $config $kickstart
                }
                # Boot information table generation may require a writable BIOS image.
                (Get-Item -LiteralPath (Join-Path $stage $stagedLayout.BiosImage)).IsReadOnly = $false

                $outputPath = Get-WslPath $temporaryIso
                $sourcePath = Get-WslPath $stage
                $arguments = @(
                    'genisoimage', '-relaxed-filenames', '-J', '-R', '-o', $outputPath
                    '-b', $stagedLayout.BiosImage, '-c', 'BOOT.CAT'
                    '-no-emul-boot', '-boot-load-size', '4', '-boot-info-table'
                    '-eltorito-alt-boot', '-e', $stagedLayout.EfiImage, '-no-emul-boot', $sourcePath
                )
                Invoke-Wsl $arguments | Out-Host

                if ((Get-Item -LiteralPath $temporaryIso).Length -eq 0) {
                    throw "genisoimage produced an empty file for '$isoName'."
                }
                if ([IO.File]::Exists($destination)) {
                    [IO.File]::Replace($temporaryIso, $destination, [NullString]::Value)
                }
                else {
                    [IO.File]::Move($temporaryIso, $destination)
                }
                Get-Item -LiteralPath $destination
            }
            finally {
                if (Test-Path -LiteralPath $temporaryIso) {
                    Remove-Item -LiteralPath $temporaryIso -Force
                }
                if (Test-Path -LiteralPath $stage) {
                    Remove-Item -LiteralPath $stage -Recurse -Force
                }
            }
        }
        $published | Format-Table Name, Length, LastWriteTime -AutoSize
    }
    finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}
