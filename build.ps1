﻿param(
    [string] $branch    = "experimental",
    [string] $build_dir = "$(Get-Location)\arachni",
    [bool]   $package   = $false
)

if( -not ( test-path "$env:ProgramFiles\7-Zip\7z.exe" ) ) {
    throw "Missing $env:ProgramFiles\7-Zip\7z.exe"
}
$env:Path += ";$env:ProgramFiles\7-Zip\"
set-alias sz "7z.exe"

function CreateDirectories( $dirs )
{
    foreach( $directory in $dirs.GetEnumerator() ) {
        $path = $directory.value

        if( "$($path.GetType())" -eq "Hashtable" ) {
            CreateDirectories( $path )
        } else {
            if( test-path $path ) {
                Write-Output "  * $path -- already exists"
            } else {
                Write-Output "  * $path"
                New-Item $path -type directory *> $null
            }
        }
    }

}

function HandleFailure( $process )
{
    if( $lastexitcode -ne 0 ) {
        Write-Output "Process exited with code $lastexitcode, check $($directories.build.logs)\$process.txt for details."
        Write-Output "When you resolve the issue you can run the script again to continue where the process left off."
        Set-Location $cwd
        exit $lastexitcode
    }
}

function Delete( $target )
{
    If (Test-Path $target ){
        Remove-Item $target -Force -Recurse
    }
}

function FilenameFromUrl( $url )
{
    return split-path $url -leaf
}

function ArchiveToDirectory( $archive )
{
    return "$($directories.build.extracted)\$([io.path]::GetFileNameWithoutExtension( $archive ))"
}

function DownloadArchive( $url, $force )
{
    $destination = "$($directories.build.archives)\$(FilenameFromUrl( $url ))"

    if( $force ) {
        Delete $destination
    }

    if (test-path "$destination" ) {
        return $destination
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile( $url, $destination )

    return $destination
}

function Extract( $archive )
{
    $extention   = [System.IO.Path]::GetExtension( $archive )
    $destination = ArchiveToDirectory( $archive )
    $name        = FilenameFromUrl( $archive )

    Delete( $destination )

    # 7z Self-extracting archive
    if( $extention -eq ".exe" ) {
        # & "$archive" /dir="$destination" -y /verysilent | Out-Null
    } elseif( $extention -eq ".xz" ) {
        sz x $archive -o"$($directories.build.archives)" -y *>> "$($directories.build.logs)\$name.txt"

        $archive = $archive.Substring( 0, $archive.length - 3 )
        $name    = FilenameFromUrl( $archive )

        sz x $archive -o"$($directories.build.extracted)\$($name)" -y *>> "$($directories.build.logs)\$name.txt"
    } else {
        sz x $archive -o"$($directories.build.extracted)" -y *>> "$($directories.build.logs)\$name.txt"
    }

    HandleFailure( $name )

    return $destination
}

function SetEnvBatch() {
    return @"
@echo OFF

set ENV_ROOT=%~dp0
set ENV_RUBY_BIN=%ENV_ROOT%ruby\bin
set ENV_CHROMEDRIVER_DIR=%ENV_ROOT%\..\chromedriver
set ENV_WEBUI_ROOT=%ENV_ROOT%arachni-ui-web
set ENV_WEBUI_BIN=%ENV_WEBUI_ROOT%\bin

:: Arachni packages run the system in production.
set RAILS_ENV=production

set ARACHNI_FRAMEWORK_LOGDIR=%ENV_ROOT%\logs\framework
set ARACHNI_WEBUI_LOGDIR=%ENV_ROOT%\logs\webui

:: PhantomJS cache needs to be per package to prevent conflicts.
set USERPROFILE=%ENV_ROOT%home

For /F "Delims=" %%I In ('echo "%PATH%" ^| find /C /I "%ENV_CHROMEDRIVER_DIR%"') Do set pathExists=%%I 2>Nul
If %pathExists%==0 set PATH=%ENV_RUBY_BIN%;%ENV_CHROMEDRIVER_DIR%;%PATH%
"@
}

function EnvWrapper( $executable ) {
    return @"
@echo OFF
setlocal
call "%~dp0..\system\setenv.cmd"

$executable %*

endlocal
"@
}

function BinWrapper( $executable ) {
    EnvWrapper( "@`"ruby.exe`" $executable" )
}

function WebUIBinDelegator() {
    return BinWrapper "`"%ENV_WEBUI_BIN%`"\%~n0"
}

function WebUIBinWrapper( $executable ) {
    return BinWrapper "`"%ENV_WEBUI_BIN%`"\$executable"
}

function WebUIScriptWrapper( $executable ) {
    return BinWrapper "`"%ENV_WEBUI_ROOT%`"\script\$executable"
}

function FetchDependency( $name, $data ){
    Write-Output "Fetching $name"

    Write-Output "  * Downloading: $($data.url)"
    $data.archive = DownloadArchive $data.url $data.force
    Write-Output "  * --> $($data.archive)"

    Write-Output "  * Extracting: $($data.archive)"
    $directory = Extract $data.archive $data.original_directory_name

    if( $data.directory -eq $null ) {
        $data.directory = $directory
    } else {
        $data.directory = "$($directories.build.extracted)\$($data.directory)"
    }

    Write-Output "  * --> $($data.directory)"
    Write-Output ""
}

function FetchDependencies(){
    foreach( $dependency in $dependencies.GetEnumerator() ) {
        FetchDependency $dependency.Name $dependency.Value
    }
}

function InstallRuby() {
    Delete "$($directories.ruby)\*"

    $name  = FilenameFromUrl( $dependencies.ruby.url )
    & "$($directories.build.archives)\$($name)" /dir="$($directories.ruby)" /verysilent | Out-Null
}

function InstallOpenSSL() {
    $name  = FilenameFromUrl( $dependencies.openssl.url )
    & "$($directories.build.archives)\$($name)" /dir="$($directories.appdata)\openssl" /verysilent | Out-Null
}

function InstallBundler(){
    & "$($directories.ruby)\bin\gem.cmd" "install" "bundler" *>> "$($directories.build.logs)\bundler.txt"
    HandleFailure( "bundler" )
}

function Installlibcurl(){
    Delete "$($directories.ruby)\bin\libcurl.dll*"
    Copy "$($dependencies.libcurl.directory)\bin\libcurl-x64.dll" "$($directories.ruby)\bin\libcurl.dll"
    HandleFailure( "curl" )
}

function InstallChromedriver(){
    Delete "$($directories.chromedriver)\chromedriver.exe"
    Copy "$($directories.build.extracted)\chromedriver.exe" "$($directories.chromedriver)\chromedriver.exe"
    HandleFailure( "chromedriver" )
}

function InstallMimeInfo(){
    Copy "$($dependencies.mimeinfo.directory)\shared-mime-info-2.0\data\freedesktop.org.xml.in" "$($directories.appdata)"
    HandleFailure( "mimeinfo" )
}

function InstallArachni(){
    Delete "$($directories.arachni)\*"
    Copy "$($dependencies.arachni.directory)\*" "$($directories.arachni)\" -Recurse


    # Required for shared-mime-info gem.
    $env:FREEDESKTOP_MIME_TYPES_PATH = "$($directories.appdata)\freedesktop.org.xml.in"

    # Required for asset precompilation.
    $env:Path = "$($directories.build.extracted)\node-v16.14.0-win-x64\;$($env:Path)"

    # Required for SQlite3.
    & "$($directories.ruby)\msys64\usr\bin\sh.exe" "-l" "-c" "pacman.exe --noconfirm -S mingw-w64-x86_64-dlfcn" *>> "$($directories.build.logs)\arachni.txt"

    Write-Host -NoNewline "  * Installing bundle..."
    Set-Location $directories.arachni

    & "$($directories.ruby)\bin\bundle.bat" "config" "build.puma" "--with-opt-dir=$($directories.appdata)\openssl\" *>> "$($directories.build.logs)\arachni.txt"
    & "$($directories.ruby)\bin\bundle.bat" "install" *>> "$($directories.build.logs)\arachni.txt"
    HandleFailure( "arachni" )
    Write-Output "done."

    Set-Location $directories.arachni

    Write-Host -NoNewline "  * Setting up the database..."
    & "$($directories.ruby)\bin\rake.cmd" "db:setup" "RAILS_ENV=production" "--trace" *>> "$($directories.build.logs)\arachni.txt"
    HandleFailure( "arachni" )
    Write-Output "done."

    Write-Host -NoNewline "  * Precompiling assets..."
    & "$($directories.ruby)\bin\rake.cmd" "assets:precompile" "RAILS_ENV=production" "--trace" *>> "$($directories.build.logs)\arachni.txt"
    HandleFailure( "arachni" )
    Write-Output "done."

    Write-Host -NoNewline "  * Writing full version to VERSION.txt file..."
    & "$($directories.ruby)\bin\rake.cmd" "version:full" > "$($directories.root)\VERSION.txt"
    HandleFailure( "arachni" )
    Write-Output "done."
}

function InstallBinWrappers() {
    Set-Content "$($directories.system)\setenv.cmd" $(SetEnvBatch)

    $web_executables = (
        "create_user",
        "change_password",
        "import",
        "scan_import"
    )

    foreach( $executable in $web_executables ) {
        $wrapper = "$($directories.bin)\arachni_web_$executable.cmd"
        Set-Content $wrapper $(WebUIScriptWrapper( $executable ))
        Write-Output "  * $wrapper"
    }

    $wrapper = "$($directories.bin)\arachni_web.cmd"
    Set-Content $wrapper $(WebUIBinWrapper( "rackup `"%ENV_WEBUI_ROOT%/config.ru`"" ))
    Write-Output "  * $wrapper"

    $wrapper = "$($directories.bin)\arachni_web_task.cmd"
    Set-Content $wrapper $(WebUIBinWrapper( "rake -f `"%ENV_WEBUI_ROOT%/Rakefile`"" ))
    Write-Output "  * $wrapper"

    $wrapper = "$($directories.bin)\arachni_shell.cmd"
    Set-Content $wrapper $(EnvWrapper( "set prompt=%username%@%computername%:`$p [arachni-shell]`$`$ `r`ncmd.exe" ))
    Write-Output "  * $wrapper"

    $wrapper = "$($directories.bin)\arachni_web_script.cmd"
    Set-Content $wrapper $(WebUIBinWrapper( "rails runner" ))
    Write-Output "  * $wrapper"

    Get-ChildItem "$($directories.arachni)\bin" -Filter arachni* | `
    Foreach-Object{
        $wrapper = "$($directories.bin)\$($_.BaseName).cmd"
        Set-Content $wrapper $(WebUIBinDelegator)
        Write-Output "  * $wrapper"
    }

}

function ConvertToCrLf( $path ) {
  (Get-Content $path) | Set-Content $path
}

#$build_dir = "C:\arachni"

$cwd = Convert-Path .

if( $build_dir -match '\s' ) {
    throw "Path to build directory should not contain spaces: '$build_dir'"
}

$clean_build_dir = "$build_dir-clean"
$from_clean_dir  = $false

if( test-path $clean_build_dir ) {
    Write-Output "Found clean build ($clean_build_dir), using it as base."
    Write-Output ""

    Delete "$build_dir"
    Copy "$clean_build_dir\" "$build_dir\" -Recurse

    $from_clean_dir = $true
}

$directories = @{
    root      = $build_dir

    bin       = "$build_dir\bin"
    chromedriver = "$build_dir\chromedriver"
    system    = "$build_dir\system"
    arachni   = "$build_dir\system\arachni-ui-web"
    arachni_puma_pids   = "$build_dir\system\arachni-ui-web\tmp\pids"
    ruby      = "$build_dir\system\ruby"
    logs      = "$build_dir\system\logs"
    flogs     = "$build_dir\system\logs\framework"
    wlogs     = "$build_dir\system\logs\webui"
    appdata   = "$build_dir\system\home\AppData\Local"

    build     = @{
        logs      = "$build_dir\build\logs\"
        archives  = "$build_dir\build\archives"
        extracted = "$build_dir\build\extracted"
    }
}

$dependencies = @{
    openssl = @{
        url       = "https://slproweb.com/download/Win64OpenSSL_Light-1_1_1m.exe"
        archive   = $null
        directory = $null
        force     = $false
    }
    nodejs = @{
        url       = "https://nodejs.org/dist/v16.14.0/node-v16.14.0-win-x64.zip"
        archive   = $null
        directory = $null
        force     = $false
    }
    ruby   = @{
        url       = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-2.7.5-1/rubyinstaller-devkit-2.7.5-1-x64.exe"
        archive   = $null
        directory = $null
        force     = $false
    }
    chromedriver = @{
        url       = "https://chromedriver.storage.googleapis.com/98.0.4758.102/chromedriver_win32.zip"
        archive   = $null
        directory = $null
        force     = $false
    }
    mimeinfo = @{
        url       = "https://gitlab.freedesktop.org/xdg/shared-mime-info/uploads/0440063a2e6823a4b1a6fb2f2af8350f/shared-mime-info-2.0.tar.xz"
        archive   = $null
        directory = $null
        force     = $false
    }
    libcurl = @{
        url       = "https://curl.se/windows/dl-7.81.0/curl-7.81.0-win64-mingw.zip"
        archive   = $null
        directory = $null
        force     = $false
    }
    arachni = @{
        url       = "https://github.com/Arachni/arachni-ui-web/archive/$branch.zip"
        archive   = $null
        directory = "arachni-ui-web-$branch"
        force     = $true
    }

}

Write-Output "Creating environment directories:"
CreateDirectories( $directories )
Write-Output ""

Delete "$($directories.build.logs)\*"

if( -not $from_clean_dir ) {
    FetchDependencies

    Write-Output "Installing"

    Write-Output "  * OpenSSL"
    InstallOpenSSL

    Write-Output "  * Ruby"
    InstallRuby

    Write-Output "  * libcurl"
    Installlibcurl

    Write-Output "  * Chromedriver"
    InstallChromedriver

    Write-Output "  * Mime info"
    InstallMimeInfo

    New-Item "$clean_build_dir" -type directory *> $null
    Write-Output ""
    Write-Output "==== Backing up clean build directory ($clean_build_dir)."
    Copy "$($directories.root)\*" "$clean_build_dir\" -Recurse
    Write-Output ""
} else {
    FetchDependency "arachni" $dependencies.arachni
}

Write-Output "Installing Bundler"
InstallBundler
Write-Output ""

Write-Output "Installing Arachni"
InstallArachni
Write-Output ""

Write-Output "Installing bin wrappers"
InstallBinWrappers
Write-Output ""

Write-Host -NoNewline "Cleaning up..."
Delete "$($directories.root)\build"
Write-Output "done."

Copy "$PSScriptRoot\templates\*" "$($directories.root)\"
ConvertToCrLf( "$($directories.root)\LICENSE.txt" )
ConvertToCrLf( "$($directories.root)\README.txt" )
ConvertToCrLf( "$($directories.root)\TROUBLESHOOTING.txt" )

if( $package ) {
    Set-Location $cwd

    $version      = Get-Content( "$build_dir\VERSION.txt" ).trim()
    $package_name = "arachni-$version-windows-x86_64"
    $package_dir  = "$build_dir\..\$package_name"

    Delete $package_dir
    Delete "$package_dir.exe"

    Rename-Item $build_dir $package_name

    Write-Host -NoNewline "Packaging..."

    sz a "$package_dir.exe" -mmt -mx5 -sfx "$package_dir" | Out-Null
    HandleFailure( "package" )

    Write-Output "done: $package_name.exe"
}

Set-Location $cwd
