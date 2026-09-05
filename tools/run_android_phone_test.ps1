param(
    [string]$Serial,
    [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/sdk",
    [string]$JavaHome = 'G:/Android/jbr',
    [string]$Flutter = 'G:/Flutter/flutter/bin/flutter.bat',
    [switch]$BuildOnly,
    [switch]$UseBuiltApk,
    [switch]$NoServiceAuth,
    [switch]$NormalApp
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$adb = Join-Path $AndroidSdk 'platform-tools/adb.exe'
$packageName = 'com.zerochat.zerochat.devicetest'
$results = Join-Path $workspace '.android-test/phone-results'
$artifact = Join-Path $results $(if ($NormalApp) { 'zerochat-test-app.apk' } else { 'zerochat-phone-smoke.apk' })
$env:JAVA_HOME = $JavaHome
New-Item -ItemType Directory -Force -Path $results | Out-Null
if (-not $BuildOnly) {
    if (-not $Serial -or $Serial.StartsWith('emulator-')) {
        throw 'Specify the authorized physical phone with -Serial.'
    }
    $state = & $adb -s $Serial get-state
    if ($LASTEXITCODE -ne 0 -or $state -ne 'device') {
        throw 'Authorize USB debugging on the phone, then rerun this command.'
    }
}

Push-Location "$workspace/client/android"
try {
    if (-not $UseBuiltApk) {
        $target = if ($NormalApp) { "$workspace/client/lib/main.dart" } else {
            "$workspace/client/integration_test/emulator_smoke_test.dart"
        }
        $defines = if ($NormalApp) { '' } else {
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ZEROCHAT_DEVICE_TEST=true'))
        }
        & ./gradlew.bat --console=plain --quiet --init-script ../../tools/android_test_init.gradle `
            '-PzerochatDeviceTest=true' '-Ptarget-platform=android-arm,android-arm64' `
            "-Ptarget=$target" "-Pdart-defines=$defines" assembleProfile
        if ($LASTEXITCODE -ne 0) { throw 'Phone Profile APK build failed' }
    }
} finally { Pop-Location }

$apk = if ($UseBuiltApk) { $artifact } else {
    Join-Path $workspace 'client/build/app/outputs/apk/profile/app-profile.apk'
}
$buildTools = Get-ChildItem "$AndroidSdk/build-tools" -Directory |
    Where-Object { Test-Path "$($_.FullName)/aapt2.exe" } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $buildTools) { throw 'aapt2 is required to verify the APK identity.' }
$badging = & "$($buildTools.FullName)/aapt2.exe" dump badging $apk
if ($LASTEXITCODE -ne 0 -or -not ($badging -match "^package: name='com\.zerochat\.zerochat\.devicetest'")) {
    throw 'Refusing to install an APK without the isolated test package ID.'
}
if (-not $UseBuiltApk) { Copy-Item -LiteralPath $apk -Destination $artifact -Force }
Write-Output "Verified isolated APK: $artifact"
if ($BuildOnly) { exit 0 }

& $adb -s $Serial install -r $artifact
if ($LASTEXITCODE -ne 0) { throw 'Phone installation failed; check the phone for an install prompt.' }
& $adb -s $Serial shell am force-stop $packageName
$launchArgs = @('shell', 'am', 'start', '-W', '-n', "$packageName/com.zerochat.zerochat.MainActivity",
    '--ez', 'enable-dart-profiling', 'true', '--ei', 'vm-service-port', '8182')
if ($NoServiceAuth -and -not $NormalApp) { $launchArgs += @('--ez', 'disable-service-auth-codes', 'true') }
& $adb -s $Serial @launchArgs
if ($LASTEXITCODE -ne 0) { throw 'Test application launch failed' }
if ($NormalApp) { exit 0 }

$forwardedPort = & $adb -s $Serial forward tcp:0 tcp:8182
if ($LASTEXITCODE -ne 0) { throw 'VM service forwarding failed' }
$previousResults = $env:ZEROCHAT_TEST_RESULTS
try {
    $serviceUri = $null
    $appPid = & $adb -s $Serial shell pidof $packageName
    if ($NoServiceAuth) { $serviceUri = "http://127.0.0.1:$($forwardedPort.Trim())/" }
    for ($attempt = 0; $attempt -lt 30 -and -not $serviceUri; $attempt++) {
        $appPid = & $adb -s $Serial shell pidof $packageName
        if ($appPid) {
            $log = & $adb -s $Serial logcat -d "--pid=$($appPid.Trim())" -s flutter
            foreach ($line in $log) {
                if ($line -match 'The Dart VM service is listening on (http://127\.0\.0\.1:8182/\S*)') {
                    $serviceUri = $Matches[1].Replace(':8182/', ":$($forwardedPort.Trim())/")
                }
            }
        }
        if (-not $serviceUri) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $serviceUri) { throw 'No Dart VM service found for the isolated application.' }
    $env:ZEROCHAT_TEST_RESULTS = $results
    Push-Location "$workspace/client"
    try {
        & $Flutter drive -d $Serial --no-pub --no-dds --profile "--use-existing-app=$serviceUri" `
            --driver=test_driver/emulator_test.dart --target=integration_test/emulator_smoke_test.dart
        $testExitCode = $LASTEXITCODE
    } finally { Pop-Location }
    & $adb -s $Serial logcat -d "--pid=$($appPid.Trim())" -s flutter AndroidRuntime |
        Out-File -LiteralPath "$results/integration-logcat.txt" -Encoding utf8
    if ($testExitCode -ne 0) { throw "Phone integration test failed; see $results/integration-logcat.txt" }
} finally {
    $env:ZEROCHAT_TEST_RESULTS = $previousResults
    & $adb -s $Serial forward --remove "tcp:$($forwardedPort.Trim())"
    if ($NoServiceAuth) { & $adb -s $Serial shell am force-stop $packageName }
}
Write-Output "Phone report: $results/emulator-results.json"
