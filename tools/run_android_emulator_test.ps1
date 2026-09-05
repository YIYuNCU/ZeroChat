param(
    [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/sdk",
    [string]$JavaHome = 'G:/Android/jbr',
    [string]$Flutter = 'G:/Flutter/flutter/bin/flutter.bat',
    [string]$Serial = 'emulator-5556',
    [switch]$SkipBuild,
    [switch]$NormalApp
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$adb = Join-Path $AndroidSdk 'platform-tools/adb.exe'
$env:JAVA_HOME = $JavaHome
$avdName = & $adb -s $Serial emu avd name
if ($LASTEXITCODE -ne 0 -or $avdName -notcontains 'ZeroChat_API_34') {
    throw 'This script only runs on the disposable ZeroChat_API_34 emulator.'
}
$results = Join-Path $workspace '.android-test/results'
New-Item -ItemType Directory -Force -Path $results | Out-Null
Push-Location "$workspace/client/android"
try {
    if (-not $SkipBuild) {
        $target = if ($NormalApp) { "$workspace/client/lib/main.dart" } else {
            "$workspace/client/integration_test/emulator_smoke_test.dart"
        }
        $defines = if ($NormalApp) { '' } else {
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ZEROCHAT_EMULATOR_TEST=true'))
        }
        & ./gradlew.bat --init-script ../../tools/android_test_init.gradle `
            '-Ptarget-platform=android-x64' "-Ptarget=$target" "-Pdart-defines=$defines" assembleProfile
        if ($LASTEXITCODE -ne 0) { throw 'Profile APK build failed' }
    }
} finally { Pop-Location }

& $adb -s $Serial shell am force-stop com.zerochat.zerochat
& $adb -s $Serial install -r "$workspace/client/build/app/outputs/apk/profile/app-profile.apk"
if ($LASTEXITCODE -ne 0) { throw 'APK install failed' }
& $adb -s $Serial logcat -c
& $adb -s $Serial shell am start -W -n com.zerochat.zerochat/.MainActivity `
    --ez enable-dart-profiling true --ez disable-service-auth-codes true --ei vm-service-port 8181
if ($LASTEXITCODE -ne 0) { throw 'Application launch failed' }
if ($NormalApp) { exit 0 }

& $adb -s $Serial forward tcp:8181 tcp:8181
if ($LASTEXITCODE -ne 0) { throw 'VM service port forwarding failed' }
Push-Location "$workspace/client"
try {
    & $Flutter drive -d $Serial --no-pub --no-dds --profile --use-existing-app=http://127.0.0.1:8181/ `
        --driver=test_driver/emulator_test.dart --target=integration_test/emulator_smoke_test.dart
    $testExitCode = $LASTEXITCODE
    & $adb -s $Serial logcat -d -s flutter AndroidRuntime |
        Out-File -LiteralPath "$results/integration-logcat.txt" -Encoding utf8
    if ($testExitCode -ne 0) { throw "Device integration test failed: $results/integration-logcat.txt" }
} finally {
    Pop-Location
    & $adb -s $Serial forward --remove tcp:8181
}
Write-Output "Results: $results/emulator-results.json"
