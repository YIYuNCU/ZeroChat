param(
    [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/sdk",
    [string]$JavaHome = 'G:/Android/jbr'
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $workspace '.android-test'
$testSdk = Join-Path $testRoot 'sdk'
$toolsRoot = Join-Path $testRoot 'tools-19'
$env:JAVA_HOME = $JavaHome
$env:ANDROID_HOME = $testSdk
$env:ANDROID_SDK_ROOT = $testSdk
$env:ANDROID_AVD_HOME = Join-Path $testRoot 'avd'
if (-not (Test-Path "$JavaHome/bin/java.exe")) { throw "Java not found: $JavaHome" }
New-Item -ItemType Directory -Force -Path $testRoot, $testSdk, $env:ANDROID_AVD_HOME | Out-Null

$sdkManager = Join-Path $toolsRoot 'cmdline-tools/bin/sdkmanager.bat'
if (-not (Test-Path $sdkManager)) {
    $catalogFile = Join-Path $testRoot 'repository.xml'
    & curl.exe --ipv4 --fail --location --retry 3 --retry-all-errors --silent --show-error `
        'https://dl.google.com/android/repository/repository2-1.xml' --output $catalogFile
    if ($LASTEXITCODE -ne 0) { throw 'SDK catalog download failed' }
    [xml]$catalog = Get-Content -LiteralPath $catalogFile -Raw
    $package = $catalog.SelectSingleNode("//*[local-name()='remotePackage' and @path='cmdline-tools;19.0']")
    $archive = $package.archives.archive | Where-Object { $_.'host-os' -eq 'windows' } | Select-Object -First 1
    $zip = Join-Path $testRoot 'command-line-tools-19.zip'
    $expected = [string]$archive.complete.checksum
    if (-not (Test-Path $zip) -or (Get-FileHash $zip -Algorithm SHA1).Hash -ne $expected) {
        & curl.exe --ipv4 --fail --location --retry 3 --retry-all-errors --connect-timeout 30 `
            "https://dl.google.com/android/repository/$($archive.complete.url)" --output $zip
        if ($LASTEXITCODE -ne 0) { throw 'Command-line tools download failed' }
    }
    if ((Get-FileHash $zip -Algorithm SHA1).Hash -ne $expected) { throw 'Command-line tools checksum mismatch' }
    Expand-Archive -LiteralPath $zip -DestinationPath $toolsRoot -Force
}

# Reuse the SDK license acceptances already present on this development machine.
if (Test-Path "$AndroidSdk/licenses") {
    Copy-Item -LiteralPath "$AndroidSdk/licenses" -Destination $testSdk -Recurse -Force
}
$imageDirectory = Join-Path $testSdk 'system-images/android-34/default'
if (-not (Test-Path "$imageDirectory/x86_64/system.img")) {
    $imageCatalog = Join-Path $testRoot 'system-images.xml'
    & curl.exe --ipv4 --fail --location --retry 3 --retry-all-errors --silent --show-error `
        'https://dl.google.com/android/repository/sys-img/android/sys-img2-1.xml' --output $imageCatalog
    if ($LASTEXITCODE -ne 0) { throw 'System image catalog download failed' }
    [xml]$images = Get-Content -LiteralPath $imageCatalog -Raw
    $imagePackage = $images.SelectSingleNode("//*[local-name()='remotePackage' and @path='system-images;android-34;default;x86_64']")
    $imageArchive = $imagePackage.archives.archive | Select-Object -First 1
    $imageZip = Join-Path $testRoot 'android-34-x86_64.zip'
    $expectedImageHash = [string]$imageArchive.complete.checksum
    if (-not (Test-Path $imageZip) -or (Get-FileHash $imageZip -Algorithm SHA1).Hash -ne $expectedImageHash) {
        & curl.exe --ipv4 --fail --location --retry 3 --retry-all-errors --connect-timeout 30 `
            "https://dl.google.com/android/repository/sys-img/android/$($imageArchive.complete.url)" --output $imageZip
        if ($LASTEXITCODE -ne 0) { throw 'System image download failed' }
    }
    if ((Get-FileHash $imageZip -Algorithm SHA1).Hash -ne $expectedImageHash) { throw 'System image checksum mismatch' }
    Expand-Archive -LiteralPath $imageZip -DestinationPath $imageDirectory -Force
}

$installedTools = Join-Path $testSdk 'cmdline-tools/19.0'
foreach ($component in @('emulator', 'platform-tools', 'platforms')) {
    $destination = Join-Path $testSdk $component
    if (-not (Test-Path $destination)) {
        New-Item -ItemType Junction -Path $destination -Target "$AndroidSdk/$component" | Out-Null
    }
}
if (-not (Test-Path "$installedTools/bin/avdmanager.bat")) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installedTools) | Out-Null
    Copy-Item -LiteralPath "$toolsRoot/cmdline-tools" -Destination $installedTools -Recurse
}
$avdManager = Join-Path $installedTools 'bin/avdmanager.bat'
if (-not (Test-Path "$env:ANDROID_AVD_HOME/ZeroChat_API_34.ini")) {
    'no' | & $avdManager create avd --name ZeroChat_API_34 `
        --package 'system-images;android-34;default;x86_64' --device 'pixel_5' `
        --path "$env:ANDROID_AVD_HOME/ZeroChat_API_34.avd"
    if ($LASTEXITCODE -ne 0) { throw 'Virtual device creation failed' }
}
Write-Output "AVD: $env:ANDROID_AVD_HOME/ZeroChat_API_34.avd"
Write-Output "SDK: $testSdk"
