param([int]$Port = 5556)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $workspace '.android-test'
$env:ANDROID_HOME = Join-Path $testRoot 'sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_AVD_HOME = Join-Path $testRoot 'avd'
if (-not (Test-Path "$env:ANDROID_AVD_HOME/ZeroChat_API_34.ini")) {
    throw 'Run tools/setup_android_test_device.ps1 first.'
}
if ($Port -lt 5554 -or $Port -gt 5682 -or $Port % 2 -ne 0) {
    throw 'Use an even emulator port from 5554 through 5682.'
}
$listener = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
    Where-Object { $_.Port -eq $Port -or $_.Port -eq ($Port + 1) }
if ($listener) { throw "Port $Port or $($Port + 1) is already in use." }
Start-Process -FilePath "$env:ANDROID_HOME/emulator/emulator.exe" `
    -ArgumentList '-avd','ZeroChat_API_34','-port',$Port,'-cores','4','-memory','3072',`
        '-gpu','swiftshader_indirect','-no-snapshot','-no-boot-anim' `
    -WindowStyle Hidden -RedirectStandardOutput "$testRoot/emulator-stdout.log" `
    -RedirectStandardError "$testRoot/emulator-stderr.log" | Out-Null
Write-Output "Starting ZeroChat_API_34 on emulator-$Port. Wait for the Android home screen before testing."
