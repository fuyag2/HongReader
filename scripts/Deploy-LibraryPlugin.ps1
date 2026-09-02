param(
    [string]$Source = (Join-Path $PSScriptRoot '..\library.koplugin\main.lua'),
    [switch]$InspectOnly
)

$ErrorActionPreference = 'Stop'

function Get-ChildItemByName {
    param(
        [Parameter(Mandatory)]$Folder,
        [Parameter(Mandatory)][string]$Name
    )

    $items = $Folder.Items()
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items.Item($index)
        $displayName = $item.Name
        $pathName = $null
        try { $pathName = [IO.Path]::GetFileName($item.Path) } catch {}
        $baseName = [IO.Path]::GetFileNameWithoutExtension($Name)
        if ($displayName -eq $Name -or $pathName -eq $Name -or
            (-not $item.IsFolder -and $displayName -eq $baseName)) {
            return $item
        }
    }
    return $null
}

function Get-ChildFolderByName {
    param(
        [Parameter(Mandatory)]$Folder,
        [Parameter(Mandatory)][string]$Name
    )

    $item = Get-ChildItemByName -Folder $Folder -Name $Name
    if (-not $item -or -not $item.IsFolder) {
        throw "Kindle folder '$Name' was not found."
    }
    return $item.GetFolder
}

function Wait-LocalFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 45
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $previousLength = -1L
    $stableChecks = 0
    do {
        if (Test-Path -LiteralPath $Path) {
            $length = (Get-Item -LiteralPath $Path).Length
            if ($length -gt 0 -and $length -eq $previousLength) {
                $stableChecks++
                if ($stableChecks -ge 2) {
                    return
                }
            }
            else {
                $stableChecks = 0
                $previousLength = $length
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for '$Path'."
}

function Copy-RemoteFileToLocal {
    param(
        [Parameter(Mandatory)]$Shell,
        [Parameter(Mandatory)]$RemoteFile,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [string]$ExpectedName = 'main.lua'
    )

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    $localFolder = $Shell.Namespace($DestinationDirectory)
    if (-not $localFolder) {
        throw "Could not open local folder '$DestinationDirectory'."
    }
    $localFolder.CopyHere($RemoteFile, 0x14)
    # Explorer hides the .lua extension in the portable-device item's display
    # name, while the downloaded file keeps its real main.lua filename.
    $destination = Join-Path $DestinationDirectory $ExpectedName
    Wait-LocalFile -Path $destination
    return $destination
}

function Open-KindlePluginContext {
    $shell = New-Object -ComObject Shell.Application
    $thisPc = $shell.Namespace(0x11)
    $kindles = @()
    $items = $thisPc.Items()
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items.Item($index)
        if ($item.Name -like '*Kindle*') {
            $kindles += $item
        }
    }
    if ($kindles.Count -ne 1) {
        throw "Expected exactly one connected Kindle, but found $($kindles.Count)."
    }

    $device = $kindles[0].GetFolder()
    $storageItem = Get-ChildItemByName -Folder $device -Name 'Internal Storage'
    if (-not $storageItem) {
        $deviceItems = $device.Items()
        for ($index = 0; $index -lt $deviceItems.Count; $index++) {
            $candidate = $deviceItems.Item($index)
            if ($candidate.IsFolder) {
                $storageItem = $candidate
                break
            }
        }
    }
    if (-not $storageItem) {
        throw 'The Kindle internal storage folder was not found.'
    }

    $storage = $storageItem.GetFolder()
    $koreader = Get-ChildFolderByName -Folder $storage -Name 'koreader'
    $plugins = Get-ChildFolderByName -Folder $koreader -Name 'plugins'
    $pluginFolder = Get-ChildFolderByName -Folder $plugins -Name 'library.koplugin'
    return [pscustomobject]@{
        Shell = $shell
        DeviceItem = $kindles[0]
        PluginFolder = $pluginFolder
    }
}

if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Plugin source was not found: $Source"
}
$Source = (Resolve-Path -LiteralPath $Source).Path
$sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash

$context = Open-KindlePluginContext
$shell = $context.Shell
$pluginFolder = $context.PluginFolder
$pluginItems = $pluginFolder.Items()
if ($InspectOnly) {
    for ($index = 0; $index -lt $pluginItems.Count; $index++) {
        $entry = $pluginItems.Item($index)
        [pscustomobject]@{
            Name = $entry.Name
            Path = $entry.Path
            IsFolder = $entry.IsFolder
            Size = $entry.Size
        }
    }
    exit 0
}
$installedFile = Get-ChildItemByName -Folder $pluginFolder -Name 'main.lua'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDirectory = Join-Path $PSScriptRoot "..\.local\kindle-backups\before-library-update-$timestamp"
$backupHash = $null
if ($installedFile) {
    $backupFile = Copy-RemoteFileToLocal -Shell $shell -RemoteFile $installedFile -DestinationDirectory $backupDirectory
    $backupHash = (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash
}
else {
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
}

$verified = $false
$verificationRoot = Join-Path $PSScriptRoot "..\.local\kindle-upload\verify-library-update-$timestamp"
for ($attempt = 1; $attempt -le 3 -and -not $verified; $attempt++) {
    # Windows' MTP shell silently refuses to overwrite this file in place.
    # The old copy is already backed up above, so remove only that exact item
    # before placing its replacement.
    $context = Open-KindlePluginContext
    $shell = $context.Shell
    $pluginFolder = $context.PluginFolder
    $existingFile = Get-ChildItemByName -Folder $pluginFolder -Name 'main.lua'
    if ($existingFile) {
        Write-Host 'Removing the backed-up previous main.lua...'
        $existingFile.InvokeVerb('delete')
        $deleteDeadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Seconds 1
            $context = Open-KindlePluginContext
            $shell = $context.Shell
            $pluginFolder = $context.PluginFolder
            $existingFile = Get-ChildItemByName -Folder $pluginFolder -Name 'main.lua'
        } while ($existingFile -and [DateTime]::UtcNow -lt $deleteDeadline)
        if ($existingFile) {
            throw 'The previous Kindle main.lua could not be removed after it was backed up.'
        }
    }

    Write-Host "Uploading plugin (attempt $attempt of 3)..."
    $pluginFolder.CopyHere($Source, 0x14)
    $remoteFile = $null
    $refreshDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Seconds 2
        $context = Open-KindlePluginContext
        $shell = $context.Shell
        $pluginFolder = $context.PluginFolder
        $remoteFile = Get-ChildItemByName -Folder $pluginFolder -Name 'main.lua'
    } while (-not $remoteFile -and [DateTime]::UtcNow -lt $refreshDeadline)
    if (-not $remoteFile) {
        Write-Host 'The uploaded file is not visible through MTP yet.'
        continue
    }
    $attemptDirectory = Join-Path $verificationRoot "attempt-$attempt"
    $readback = Copy-RemoteFileToLocal -Shell $shell -RemoteFile $remoteFile -DestinationDirectory $attemptDirectory
    $readbackHash = (Get-FileHash -LiteralPath $readback -Algorithm SHA256).Hash
    $verified = $readbackHash -eq $sourceHash
}

if (-not $verified) {
    throw "The Kindle read-back hash did not match after three attempts. Verification files remain in '$verificationRoot'."
}

if (Test-Path -LiteralPath $verificationRoot) {
    Remove-Item -LiteralPath $verificationRoot -Recurse -Force
}

[pscustomobject]@{
    Device = $context.DeviceItem.Name
    SourceHash = $sourceHash
    PreviousHash = $backupHash
    BackupDirectory = $backupDirectory
    InstalledPath = '/mnt/us/koreader/plugins/library.koplugin/main.lua'
    Verified = $verified
} | Format-List
