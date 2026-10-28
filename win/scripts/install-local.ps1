[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
function Get-Sha256([string]$FilePath) {
    $stream = [IO.File]::OpenRead($FilePath)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$targetFile = Join-Path $projectRoot '.local-install-path'
if (!(Test-Path -LiteralPath $targetFile -PathType Leaf)) {
    throw 'Set .local-install-path to the existing Margin installation directory first.'
}
$configuredTarget = (Get-Content -LiteralPath $targetFile -Raw).Trim()
if (![IO.Path]::IsPathRooted($configuredTarget)) { throw 'The install path must be absolute.' }
$installDirectory = [IO.Path]::GetFullPath($configuredTarget).TrimEnd('\')
$installedExe = Join-Path $installDirectory 'Margin.exe'
if (!(Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw "Existing Margin installation not found: $installedExe" }
if ([IO.Path]::GetFileName($installDirectory) -ne 'Margin') { throw 'The install directory must be the existing Margin folder.' }
if ($installDirectory.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installed app must be outside the source and build directories.'
}

$receiptPath = Join-Path $projectRoot 'dist\local-build.json'
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
$package = Get-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Raw | ConvertFrom-Json
if ($receipt.version -ne $package.version) { throw 'Build the current version before installing.' }
$expectedInstaller = 'dist/Margin-' + $package.version + '-Windows-x64-Setup.exe'
if ($receipt.installer.path -ne $expectedInstaller) { throw 'Unexpected installer path in the build receipt.' }
$installer = Join-Path $projectRoot $expectedInstaller
if ((Get-Sha256 $installer) -ne $receipt.installer.sha256) {
    throw 'Installer changed since the successful build. Rebuild before installing.'
}
if (@($receipt.files).Count -lt 2) { throw 'Build receipt is incomplete.' }
$checkedFiles = @()
foreach ($record in $receipt.files) {
    if (!$record.path.StartsWith('dist/win-unpacked/')) { throw 'Unexpected packaged file path.' }
    $relative = $record.path.Substring('dist/win-unpacked/'.Length).Replace('/', '\')
    $destination = [IO.Path]::GetFullPath((Join-Path $installDirectory $relative))
    if (!$destination.StartsWith($installDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Packaged file path escapes the installation directory.'
    }
    if ((Get-Sha256 (Join-Path $projectRoot $record.path)) -ne $record.sha256) {
        throw "Packaged file changed since the build: $relative"
    }
    $checkedFiles += [PSCustomObject]@{ path = $relative; destination = $destination; sha256 = $record.sha256 }
}
if ('Margin.exe' -notin $checkedFiles.path -or 'resources\app.asar' -notin $checkedFiles.path) { throw 'Build receipt is missing the app.' }

# Preserve the original installation scope instead of creating a second copy.
$scope = $null
$registryRoots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
foreach ($registryRoot in $registryRoots) {
    if (!(Test-Path -LiteralPath $registryRoot)) { continue }
    foreach ($entry in @(Get-ItemProperty -Path ($registryRoot + '\*') -ErrorAction SilentlyContinue)) {
        if ($entry.DisplayName -notmatch '^Margin(?:\s|$)') { continue }
        if ($entry.UninstallString -notmatch '^"([^"]+)"') { continue }
        if ([IO.Path]::GetDirectoryName($Matches[1]) -ne $installDirectory) { continue }
        $scope = if ($registryRoot.StartsWith('HKLM:')) { '/allusers' } else { '/currentuser' }
    }
}
if (!$scope) { throw "No registered Margin installation matches $installDirectory. Refusing to create a second installation." }
Write-Host "Margin $($receipt.version) -> $installDirectory ($scope)"
if ($DryRun) { Write-Host 'Build hashes, destination and install scope verified. No changes made.'; exit 0 }

# Request a normal close so Margin flushes notes, settings and credentials.
# Never let the silent installer force-close an app with unsaved work.
$running = @(Get-Process -Name Margin -ErrorAction SilentlyContinue)
foreach ($process in $running) {
    if ($process.Path -ne $installedExe) { throw 'Another Margin copy is running. Close it before updating the installed copy.' }
}
$restart = $running.Count -gt 0
foreach ($process in $running) {
    if ($process.MainWindowHandle -ne 0 -and !$process.CloseMainWindow()) { throw 'Margin could not be closed normally.' }
}
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (@(Get-Process -Name Margin -ErrorAction SilentlyContinue).Count -gt 0) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Margin has not finished saving and closing. Update stopped; no forced termination.' }
    Start-Sleep -Milliseconds 200
}

# NSIS requires /D to be last and unquoted, including for paths containing spaces.
$installerArguments = "/S --updated --keep-shortcuts $scope /D=$installDirectory"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$startOptions = @{ FilePath = $installer; ArgumentList = $installerArguments; Wait = $true; PassThru = $true; WindowStyle = 'Hidden' }
if ($scope -eq '/allusers' -and !$isAdmin) {
    Write-Host 'Windows may ask for administrator approval to update this all-users installation.'
    $startOptions.Verb = 'RunAs'
}
$installation = Start-Process @startOptions
if ($installation.ExitCode -ne 0) { throw "Installer failed with exit code $($installation.ExitCode)." }
foreach ($record in $checkedFiles) {
    if ((Get-Sha256 $record.destination) -ne $record.sha256) {
        throw "Installed file does not match the new build: $($record.path)"
    }
}
$restarted = $false
if ($restart) { Start-Process -FilePath $installedExe -WindowStyle Normal; $restarted = $true }
$result = @{ installed = $true; version = $receipt.version; installDirectory = $installDirectory;
    installedAt = [DateTime]::UtcNow.ToString('o'); installerSha256 = $receipt.installer.sha256;
    verifiedFiles = @($checkedFiles | Select-Object path, sha256); restarted = $restarted }
$resultDirectory = Join-Path $projectRoot 'test-results'
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $resultDirectory 'local-install-result.json') -Encoding UTF8
Write-Host "Installed and verified Margin $($receipt.version) at $installDirectory"
