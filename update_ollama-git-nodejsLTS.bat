@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem User-scope Dev Tools Installer / Updater
rem Installs/updates:
rem   - Git via winget
rem   - Ollama via winget
rem   - Portable Node.js LTS via official Node ZIP
rem No admin rights required if run as the logged-in user.
rem v2
rem ============================================================

if not defined LOCALAPPDATA (
    set "FATAL=LOCALAPPDATA is not defined. This must run as a normal logged-in user."
    goto :fatal
)

set "PROGRAMS=%LOCALAPPDATA%\Programs"
set "GIT_DIR=%PROGRAMS%\Git"
set "OLLAMA_DIR=%PROGRAMS%\Ollama"
set "NODE_DIR=%PROGRAMS%\nodejs"
set "WORK=%TEMP%\devtools-setup-%RANDOM%-%RANDOM%"
set "PATH_PS1=%WORK%\add-user-path.ps1"
set "FATAL="

rem Detect OS architecture for Node portable ZIP.
set "OS_ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "OS_ARCH=%PROCESSOR_ARCHITEW6432%"

set "NODE_ARCH=win-x64"
if /i "%OS_ARCH%"=="ARM64" set "NODE_ARCH=win-arm64"
if /i "%OS_ARCH%"=="x86" set "NODE_ARCH=win-x86"

echo.
echo ============================================================
echo Dev tools user-scope installer/updater
echo Target root: %PROGRAMS%
echo Node architecture: %NODE_ARCH%
echo ============================================================
echo.

mkdir "%PROGRAMS%" 2>nul
mkdir "%WORK%" 2>nul

call :need winget.exe "Windows Package Manager / winget" || goto :fatal
call :need curl.exe "curl.exe" || goto :fatal
call :need cscript.exe "Windows Script Host / cscript" || goto :fatal
call :need certutil.exe "CertUtil" || goto :fatal
call :need powershell.exe "Windows PowerShell" || goto :fatal

where tar.exe >nul 2>&1
if errorlevel 1 (
    call :need powershell.exe "tar.exe or PowerShell Expand-Archive fallback" || goto :fatal
)

echo Updating winget source metadata...
winget source update --name winget --accept-source-agreements >nul 2>&1

call :winget_install_or_update "Git.Git" "%GIT_DIR%" "%GIT_DIR%\cmd\git.exe" || goto :fatal

call :stop_ollama
call :winget_install_or_update "Ollama.Ollama" "%OLLAMA_DIR%" "%OLLAMA_DIR%\ollama.exe" || goto :fatal
call :start_ollama

call :install_node_lts || goto :fatal

echo.
echo Updating user PATH...
call :write_path_helper
call :add_user_path "%GIT_DIR%\cmd" || goto :fatal
call :add_user_path "%OLLAMA_DIR%" || goto :fatal
call :add_user_path "%NODE_DIR%" || goto :fatal

rem Make PATH available to the rest of this current script/session too.
set "PATH=%PATH%;%GIT_DIR%\cmd;%OLLAMA_DIR%;%NODE_DIR%"

echo.
echo ============================================================
echo Installed versions detected in this session:
echo ============================================================

where git.exe >nul 2>&1 && git --version
where node.exe >nul 2>&1 && node -v
where npm.cmd >nul 2>&1 && npm -v
where ollama.exe >nul 2>&1 && ollama --version

echo.
echo Done.
echo Note: The user PATH was broadcast to the system, so newly launched programs
echo       will see it. Already-open terminals/apps keep their old PATH until restarted.
echo.

rmdir /s /q "%WORK%" 2>nul
exit /b 0


:need
where "%~1" >nul 2>&1
if errorlevel 1 (
    set "FATAL=Missing required tool: %~2 (%~1)."
    exit /b 1
)
exit /b 0


:stop_ollama
rem Stop any running Ollama server/tray app so the upgrade can replace files
rem in place and so the new server (not the old in-memory one) starts afterward.
echo.
echo Stopping any running Ollama processes...

rem Force-kill the server and the tray app so the upgrade replaces files in place.
taskkill /F /IM ollama.exe >nul 2>&1
taskkill /F /IM "ollama app.exe" >nul 2>&1

rem Confirm nothing named ollama* is still running before continuing.
set "OLLAMA_RUNNING="
for /f "skip=1 delims=" %%P in ('tasklist /fi "imagename eq ollama.exe" /fo csv 2^>nul') do set "OLLAMA_RUNNING=1"
for /f "skip=1 delims=" %%P in ('tasklist /fi "imagename eq ollama app.exe" /fo csv 2^>nul') do set "OLLAMA_RUNNING=1"

if defined OLLAMA_RUNNING (
    echo Ollama still appears to be running; retrying force-stop...
    taskkill /F /IM ollama.exe >nul 2>&1
    taskkill /F /IM "ollama app.exe" >nul 2>&1
)

echo Ollama stopped.
exit /b 0


:start_ollama
rem Relaunch Ollama after the upgrade so the freshly installed server (not the
rem old one we killed) is the one running. Prefer the tray app; fall back to
rem a detached "ollama serve". Both are single-instance-safe to start.
echo.
echo Starting Ollama...
if exist "%OLLAMA_DIR%\ollama app.exe" (
    start "" "%OLLAMA_DIR%\ollama app.exe"
) else if exist "%OLLAMA_DIR%\ollama.exe" (
    start "Ollama" "%OLLAMA_DIR%\ollama.exe" serve
)
exit /b 0


:winget_install_or_update
set "PKG=%~1"
set "LOC=%~2"
set "VERIFY_EXE=%~3"

echo.
echo ============================================================
echo Checking %PKG%
echo ============================================================

winget list --id "%PKG%" --exact --accept-source-agreements >nul 2>&1
if not errorlevel 1 (
    echo %PKG% is installed. Attempting upgrade...
    winget upgrade ^
        --id "%PKG%" ^
        --exact ^
        --source winget ^
        --scope user ^
        --silent ^
        --disable-interactivity ^
        --accept-source-agreements ^
        --accept-package-agreements

    rem Some winget builds/packages can return non-zero when already current.
    rem Verify the expected executable instead of failing immediately.
    if exist "%VERIFY_EXE%" (
        echo %PKG% ready.
        exit /b 0
    )

    echo Upgrade did not expose expected executable. Trying upgrade without scope as fallback...
    winget upgrade ^
        --id "%PKG%" ^
        --exact ^
        --source winget ^
        --silent ^
        --disable-interactivity ^
        --accept-source-agreements ^
        --accept-package-agreements

    if exist "%VERIFY_EXE%" (
        echo %PKG% ready.
        exit /b 0
    )
)

echo %PKG% not found in expected user location. Installing user-scope to:
echo %LOC%

winget install ^
    --id "%PKG%" ^
    --exact ^
    --source winget ^
    --scope user ^
    --location "%LOC%" ^
    --silent ^
    --disable-interactivity ^
    --accept-source-agreements ^
    --accept-package-agreements

if errorlevel 1 (
    echo Install with explicit location failed. Retrying user-scope default location...
    winget install ^
        --id "%PKG%" ^
        --exact ^
        --source winget ^
        --scope user ^
        --silent ^
        --disable-interactivity ^
        --accept-source-agreements ^
        --accept-package-agreements
)

if exist "%VERIFY_EXE%" (
    echo %PKG% ready.
    exit /b 0
)

set "FATAL=%PKG% install/update did not complete or expected executable was not found: %VERIFY_EXE%"
exit /b 1


:install_node_lts
echo.
echo ============================================================
echo Checking portable Node.js LTS
echo ============================================================

set "INDEX_JSON=%WORK%\node-index.json"
set "GET_LTS_JS=%WORK%\get-node-lts.js"
set "NODE_ZIP=%WORK%\node.zip"
set "NODE_SHASUMS=%WORK%\SHASUMS256.txt"
set "NODE_EXTRACT=%WORK%\node-extract"
set "NODE_VERSION="

echo Downloading Node.js release index...
curl.exe -L --fail --silent --show-error --retry 3 --retry-delay 2 --retry-connrefused -o "%INDEX_JSON%" "https://nodejs.org/dist/index.json"
if errorlevel 1 (
    set "FATAL=Failed to download Node.js release index."
    exit /b 1
)

> "%GET_LTS_JS%" echo var fso = new ActiveXObject("Scripting.FileSystemObject");
>>"%GET_LTS_JS%" echo var arch = WScript.Arguments(1);
>>"%GET_LTS_JS%" echo var txt = fso.OpenTextFile(WScript.Arguments(0), 1).ReadAll();
>>"%GET_LTS_JS%" echo var data = eval("(" + txt + ")");
>>"%GET_LTS_JS%" echo for (var i = 0; i ^< data.length; i++) {
>>"%GET_LTS_JS%" echo   var x = data[i];
>>"%GET_LTS_JS%" echo   if (x.lts ^&^& x.files ^&^& x.files.join(",").indexOf(arch) ^>= 0) { WScript.Echo(x.version); WScript.Quit(0); }
>>"%GET_LTS_JS%" echo }
>>"%GET_LTS_JS%" echo WScript.Quit(1);

for /f "usebackq delims=" %%V in (`cscript.exe //nologo "%GET_LTS_JS%" "%INDEX_JSON%" "%NODE_ARCH%"`) do set "NODE_VERSION=%%V"

if not defined NODE_VERSION (
    set "FATAL=Could not determine latest Node.js LTS version for %NODE_ARCH%."
    exit /b 1
)

set "NODE_BASE=node-%NODE_VERSION%-%NODE_ARCH%"
set "NODE_URL=https://nodejs.org/dist/%NODE_VERSION%/%NODE_BASE%.zip"
set "SHASUMS_URL=https://nodejs.org/dist/%NODE_VERSION%/SHASUMS256.txt"

set "INSTALLED_NODE="
if exist "%NODE_DIR%\node.exe" (
    for /f "delims=" %%V in ('"%NODE_DIR%\node.exe" -v 2^>nul') do set "INSTALLED_NODE=%%V"
)

if /i "%INSTALLED_NODE%"=="%NODE_VERSION%" (
    echo Node.js %NODE_VERSION% is already installed at %NODE_DIR%.
    exit /b 0
)

echo Installing/updating Node.js portable:
echo   Current: %INSTALLED_NODE%
echo   Target : %NODE_VERSION%
echo   URL    : %NODE_URL%

curl.exe -L --fail --silent --show-error --retry 3 --retry-delay 2 --retry-connrefused -o "%NODE_ZIP%" "%NODE_URL%"
if errorlevel 1 (
    set "FATAL=Failed to download Node.js ZIP."
    exit /b 1
)

curl.exe -L --fail --silent --show-error --retry 3 --retry-delay 2 --retry-connrefused -o "%NODE_SHASUMS%" "%SHASUMS_URL%"
if errorlevel 1 (
    set "FATAL=Failed to download Node.js SHASUMS256.txt."
    exit /b 1
)

set "EXPECTED_HASH="
for /f "tokens=1" %%H in ('findstr /i /c:"%NODE_BASE%.zip" "%NODE_SHASUMS%"') do set "EXPECTED_HASH=%%H"

if not defined EXPECTED_HASH (
    set "FATAL=Could not find expected SHA256 for %NODE_BASE%.zip."
    exit /b 1
)

rem certutil prints a header line, then the hash on line 2, then a status line.
rem Taking line 2 (skip=1) is locale-independent, unlike matching "hash"/"CertUtil".
set "ACTUAL_HASH="
for /f "skip=1 delims=" %%H in ('certutil.exe -hashfile "%NODE_ZIP%" SHA256') do (
    if not defined ACTUAL_HASH set "ACTUAL_HASH=%%H"
)
set "ACTUAL_HASH=%ACTUAL_HASH: =%"

if /i not "%EXPECTED_HASH%"=="%ACTUAL_HASH%" (
    set "FATAL=Node.js ZIP SHA256 verification failed."
    exit /b 1
)

mkdir "%NODE_EXTRACT%" 2>nul

where tar.exe >nul 2>&1
if not errorlevel 1 (
    tar.exe -xf "%NODE_ZIP%" -C "%NODE_EXTRACT%"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%NODE_ZIP%' -DestinationPath '%NODE_EXTRACT%' -Force"
)

if errorlevel 1 (
    set "FATAL=Failed to extract Node.js ZIP."
    exit /b 1
)

if not exist "%NODE_EXTRACT%\%NODE_BASE%\node.exe" (
    set "FATAL=Extracted Node.js folder was not found: %NODE_EXTRACT%\%NODE_BASE%"
    exit /b 1
)

if exist "%NODE_DIR%.old" rmdir /s /q "%NODE_DIR%.old" 2>nul

if exist "%NODE_DIR%" (
    echo Replacing existing Node.js folder...
    ren "%NODE_DIR%" "nodejs.old" >nul 2>&1
    if errorlevel 1 (
        set "FATAL=Could not replace existing Node.js folder. Close any running node.exe/npm processes and retry."
        exit /b 1
    )
)

move "%NODE_EXTRACT%\%NODE_BASE%" "%NODE_DIR%" >nul
if errorlevel 1 (
    if exist "%NODE_DIR%.old" ren "%NODE_DIR%.old" "nodejs" >nul 2>&1
    set "FATAL=Failed to move Node.js into %NODE_DIR%."
    exit /b 1
)

if exist "%NODE_DIR%.old" rmdir /s /q "%NODE_DIR%.old" 2>nul

echo Node.js %NODE_VERSION% installed at %NODE_DIR%.
exit /b 0


:write_path_helper
rem Generate the PowerShell PATH helper once. Using PowerShell (instead of the
rem old WScript.Shell RegWrite) avoids the 2048-char truncation of long PATHs,
rem and [Environment]::SetEnvironmentVariable(..,'User') broadcasts a
rem WM_SETTINGCHANGE so new processes inherit the change without a sign-out.
rem NOTE: these echo lines must stay at top level (not inside a ( ) block),
rem because the PowerShell code contains parentheses that would otherwise be
rem read by cmd as the end of the block.
> "%PATH_PS1%" echo param([string]$Dir)
>>"%PATH_PS1%" echo $ErrorActionPreference = 'Stop'
>>"%PATH_PS1%" echo $cur = [Environment]::GetEnvironmentVariable('Path','User'); if (-not $cur) { $cur = '' }
>>"%PATH_PS1%" echo function Norm([string]$s) { return ($s -replace '[\\/]+$','').ToLowerInvariant() }
>>"%PATH_PS1%" echo $want = Norm $Dir
>>"%PATH_PS1%" echo $has = $false
>>"%PATH_PS1%" echo foreach ($p in $cur.Split(';')) { if ($p -ne '' -and (Norm $p) -eq $want) { $has = $true } }
>>"%PATH_PS1%" echo if ($has) { Write-Host ('PATH already contains: ' + $Dir); exit 0 }
>>"%PATH_PS1%" echo if ($cur -ne '') { $next = $cur.TrimEnd(';') + ';' + $Dir } else { $next = $Dir }
>>"%PATH_PS1%" echo [Environment]::SetEnvironmentVariable('Path', $next, 'User')
>>"%PATH_PS1%" echo Write-Host ('Added to user PATH: ' + $Dir)
>>"%PATH_PS1%" echo exit 0
exit /b 0


:add_user_path
set "ADD_PATH=%~1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PATH_PS1%" "%ADD_PATH%"
if errorlevel 1 (
    set "FATAL=Failed to update user PATH with: %ADD_PATH%"
    exit /b 1
)

exit /b 0


:fatal
echo.
echo ============================================================
echo ERROR
echo ============================================================
echo %FATAL%
echo.
echo Work folder kept for debugging:
echo %WORK%
echo.
exit /b 1
