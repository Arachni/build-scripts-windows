param(
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
        & "$archive" -o"$destination" -y | Out-Null
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
set ENV_WEBUI_ROOT=%ENV_ROOT%arachni-ui-web
set ENV_WEBUI_BIN=%ENV_WEBUI_ROOT%\bin

:: Arachni packages run the system in production.
set RAILS_ENV=production

set ARACHNI_FRAMEWORK_LOGDIR=%ENV_ROOT%\logs\framework
set ARACHNI_WEBUI_LOGDIR=%ENV_ROOT%\logs\webui

:: PhantomJS cache needs to be per package to prevent conflicts.
set USERPROFILE=%ENV_ROOT%user-profile

For /F "Delims=" %%I In ('echo "%PATH%" ^| find /C /I "%ENV_RUBY_BIN%"') Do set pathExists=%%I 2>Nul
If %pathExists%==0 set PATH=%ENV_RUBY_BIN%;%PATH%
"@
}

function EnvWrapper( $executable ) {
    return @"
@echo OFF
setlocal
call "%~dp0..\system\setenv.bat"

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
    Copy "$($dependencies.ruby.directory)\*" "$($directories.ruby)\" -Recurse
}

function InstallBundler(){
    & "$($directories.ruby)\bin\gem.bat" "install" "bundler" *>> "$($directories.build.logs)\bundler.txt"
    HandleFailure( "bundler" )
}

function InstallDevKit() {
    $devkit_config_yml = "---
- $($directories.ruby -replace "\\", "/" )"

    # We need to write config.yml so make sure we're somewhere with enough permissions.
    Set-Location $dependencies.devkit.directory
    Set-Content "config.yml" $devkit_config_yml

    & "$($directories.ruby)\bin\ruby" "$($dependencies.devkit.directory)\dk.rb" "install" *>> "$($directories.build.logs)\devkit.txt"
    HandleFailure( "devkit" )

    Delete config.yml
}

function Installlibcurl(){
    Delete "$($directories.ruby)\bin\*curl.*"
    Copy "$($dependencies.libcurl.directory)\*curl.*" "$($directories.ruby)\bin\"
}

function InstallPhantomJS(){
    Delete "$($directories.ruby)\bin\phantomjs.exe"
    Copy "$($dependencies.phantomjs.directory)\phantomjs.exe" "$($directories.ruby)\bin\"
}

function FixBcrypt(){
    Write-Host -NoNewline "  * Fixing bcrypt..."

    Set-Location "$($directories.ruby)\lib\ruby\gems\2.2.0\gems\bcrypt-3.1.10-x64-mingw32\ext\mri"

    & "$($directories.ruby)\bin\ruby" "extconf.rb" *>> "$($directories.build.logs)\bcrypt.txt"
    HandleFailure( "devkit" )

    & "$($dependencies.devkit.directory)\bin\make.exe" *>> "$($directories.build.logs)\bcrypt.txt"
    HandleFailure( "devkit" )

    & "$($dependencies.devkit.directory)\bin\make.exe" "install" *>> "$($directories.build.logs)\bcrypt.txt"
    HandleFailure( "devkit" )

    Write-Output "done."
}

function InstallArachni(){
    Delete "$($directories.arachni)\*"
    Copy "$($dependencies.arachni.directory)\*" "$($directories.arachni)\" -Recurse

    Write-Host -NoNewline "  * Installing bundle..."
    Set-Location $directories.arachni
    & "$($directories.ruby)\bin\bundle.bat" "install" *>> "$($directories.build.logs)\arachni.txt"
    HandleFailure( "arachni" )
    Write-Output "done."

    . "$($dependencies.devkit.directory)\devkitvars.ps1" *>> "$($directories.build.logs)\arachni.txt"
    FixBcrypt

    Set-Location $directories.arachni

    Write-Host -NoNewline "  * Setting up the database..."
    & "$($directories.ruby)\bin\rake.bat" "db:setup" "RAILS_ENV=production" *>> "$($directories.build.logs)\arachni.txt"
    HandleFailure( "arachni" )
    Write-Output "done."

    Write-Host -NoNewline "  * Precompiling assets..."
    & "$($directories.ruby)\bin\rake.bat" "assets:precompile" "RAILS_ENV=production" *>> "$($directories.build.logs)\arachni.txt"
    HandleFailure( "arachni" )
    Write-Output "done."

    Write-Host -NoNewline "  * Writing full version to VERSION.txt file..."
    & "$($directories.ruby)\bin\rake.bat" "version:full" > "$($directories.root)\VERSION.txt"
    HandleFailure( "arachni" )
    Write-Output "done."
}

function InstallBinWrappers() {
    Set-Content "$($directories.system)\setenv.bat" $(SetEnvBatch)

    $web_executables = (
        "create_user",
        "change_password",
        "import",
        "scan_import"
    )

    foreach( $executable in $web_executables ) {
        $wrapper = "$($directories.bin)\arachni_web_$executable.bat"
        Set-Content $wrapper $(WebUIScriptWrapper( $executable ))
        Write-Output "  * $wrapper"
    }

    $wrapper = "$($directories.bin)\arachni_web.bat"
    Set-Content $wrapper $(WebUIBinWrapper( "rackup `"%ENV_WEBUI_ROOT%/config.ru`"" ))
    Write-Output "  * $wrapper"

    $wrapper = "$($directories.bin)\arachni_web_task.bat"
    Set-Content $wrapper $(WebUIBinWrapper( "rake -f `"%ENV_WEBUI_ROOT%/Rakefile`"" ))
    Write-Output "  * $wrapper"

    $wrapper = "$($directories.bin)\arachni_shell.bat"
    Set-Content $wrapper $(EnvWrapper( "set prompt=%username%@%computername%:`$p [arachni-shell]`$`$ `r`ncmd.exe" ))
    Write-Output "  * $wrapper"

    $wrapper = "$($directories.bin)\arachni_web_script.bat"
    Set-Content $wrapper $(WebUIBinWrapper( "rails runner" ))
    Write-Output "  * $wrapper"

    Get-ChildItem "$($directories.arachni)\bin" -Filter arachni* | `
    Foreach-Object{
        $wrapper = "$($directories.bin)\$($_.BaseName).bat"
        Set-Content $wrapper $(WebUIBinDelegator)
        Write-Output "  * $wrapper"
    }

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
    system    = "$build_dir\system"
    arachni   = "$build_dir\system\arachni-ui-web"
    ruby      = "$build_dir\system\ruby"
    logs      = "$build_dir\system\logs"
    flogs     = "$build_dir\system\logs\framework"
    wlogs     = "$build_dir\system\logs\webui"
    appdata   = "$build_dir\system\user-profile\AppData\Local"

    build     = @{
        logs      = "$build_dir\build\logs\"
        archives  = "$build_dir\build\archives"
        extracted = "$build_dir\build\extracted"
    }
}

$dependencies = @{
    ruby   = @{
        url       = "http://dl.bintray.com/oneclick/rubyinstaller/ruby-2.2.3-x64-mingw32.7z"
        archive   = $null
        directory = $null
        force     = $false
    }
    devkit = @{
        url       = "http://dl.bintray.com/oneclick/rubyinstaller/DevKit-mingw64-64-4.7.2-20130224-1432-sfx.exe"
        archive   = $null
        directory = $null
        force     = $false
    }
    phantomjs = @{
        url       = "https://phantomjs.googlecode.com/files/phantomjs-1.9.2-windows.zip"
        archive   = $null
        directory = $null
        force     = $false
    }
    libcurl = @{
        url       = "http://curl.haxx.se/gknw.net/7.40.0/dist-w64/curl-7.40.0-rtmp-ssh2-ssl-sspi-zlib-winidn-static-bin-w64.7z"
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

    Write-Output "  * Ruby"
    InstallRuby

    Write-Output "  * Bundler"
    InstallBundler

    Write-Output "  * DevKit"
    InstallDevKit

    Write-Output "  * libcurl"
    Installlibcurl

    Write-Output "  * PhantomJS"
    InstallPhantomJS

    New-Item "$clean_build_dir" -type directory *> $null
    Write-Output ""
    Write-Output "==== Backing up clean build directory ($clean_build_dir)."
    Copy "$($directories.root)\*" "$clean_build_dir\" -Recurse
    Write-Output ""
} else {
    FetchDependency "devkit" $dependencies.devkit
    FetchDependency "arachni" $dependencies.arachni
}

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
