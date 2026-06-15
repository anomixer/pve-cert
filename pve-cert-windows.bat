@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

:: ============================================================
:: pve-cert-windows.bat  —  Proxmox VE Client Certificate Installer
:: Usage:
::   pve-cert-windows.bat       Install cert, update hosts
::   pve-cert-windows.bat -u    Uninstall cert, remove hosts entry
:: Run as Administrator
:: Supports multiple PVE sites
:: ============================================================

title PVE Certificate Installer

echo.
echo =====================================================
echo   Proxmox VE Client Certificate Installer
echo   pve-cert-windows.bat
echo =====================================================
echo.

:: ── Check Administrator privileges ──────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Please run this script as Administrator!
    echo.
    echo Right-click pve-cert-windows.bat and select "Run as administrator"
    echo.
    pause
    exit /b 1
)

:: ── Persistent storage folder ────────────────────────────────
set DATA_DIR=%ProgramData%\pve-cert
if not exist "!DATA_DIR!" mkdir "!DATA_DIR!"
set INFO_FILE=!DATA_DIR!\pve-cert-info.txt

if /i "%~1"=="-u" goto do_uninstall

:: ============================================================
::  INSTALL MODE
:: ============================================================

where ssh >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] ssh/scp not found.
    echo Please enable OpenSSH Client:
    echo   Settings ^> Apps ^> Optional Features ^> OpenSSH Client
    pause
    exit /b 1
)

:: ── Show existing sites ──────────────────────────────────────
if exist "!INFO_FILE!" (
    echo   Currently registered PVE sites:
    echo   -----------------------------------
    for /f "tokens=1,2" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
    echo.
)

:: ── Step 1 ───────────────────────────────────────────────────
echo [Step 1/5] Enter Proxmox VE server information
echo -----------------------------------------------------
echo.
set /p PVE_IP=  PVE IP address [e.g. 192.168.21.60]: 
if "!PVE_IP!"=="" (
    echo [ERROR] IP cannot be empty.
    pause
    exit /b 1
)

if exist "!INFO_FILE!" (
    set ALREADY=0
    for /f "tokens=1,2" %%A in (!INFO_FILE!) do (
        if "%%A"=="!PVE_IP!" set ALREADY=1
    )
    if "!ALREADY!"=="1" (
        echo   [WARN] This IP is already registered.
        echo.
        set /p REIMPORT=  Re-import anyway? [y/N]: 
        if /i not "!REIMPORT!"=="y" (
            echo   Aborted.
            pause
            exit /b 0
        )
    )
)

set /p PVE_USER=  SSH username [default: root]: 
if "!PVE_USER!"=="" set PVE_USER=root

echo.
echo   [NOTE] You will be prompted for the SSH password below.
echo.

:: ── Step 2 ───────────────────────────────────────────────────
echo [Step 2/5] Downloading CA certificate from PVE
echo -----------------------------------------------------

set CA_REMOTE=/root/pve-local-ca.crt
set CA_LOCAL=!DATA_DIR!\pve-ca-!PVE_IP!.crt

echo   Source : !PVE_USER!@!PVE_IP!:!CA_REMOTE!
echo   Dest   : !CA_LOCAL!
echo.

scp -o StrictHostKeyChecking=no "!PVE_USER!@!PVE_IP!:!CA_REMOTE!" "!CA_LOCAL!"
set SCP_RC=!errorlevel!

if !SCP_RC! neq 0 goto scp_failed
goto scp_ok

:scp_failed
echo.
echo [ERROR] Failed to download certificate! Please check:
echo   1. IP address is correct: !PVE_IP!
echo   2. SSH credentials are correct
echo   3. pve-cert.sh has been run on PVE
echo   4. PVE firewall allows SSH [port 22]
echo.
pause
exit /b 1

:scp_ok
echo.
echo   [OK] Certificate downloaded!
echo.

:: ── Get cert thumbprint and save to info file later ──────────
set CERT_THUMB=
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 '!CA_LOCAL!').Thumbprint"`) do (
    if "!CERT_THUMB!"=="" set CERT_THUMB=%%T
)
echo   [INFO] Cert thumbprint: !CERT_THUMB!
echo.

:: ── Step 3 ───────────────────────────────────────────────────
echo [Step 3/5] Auto-detecting PVE DNS name via SSH
echo -----------------------------------------------------
echo.

set PVE_DNS=
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "& ssh -o StrictHostKeyChecking=no '!PVE_USER!@!PVE_IP!' 'hostname -f' 2>$null"`) do (
    if "!PVE_DNS!"=="" set PVE_DNS=%%H
)

if "!PVE_DNS!"=="" goto dns_fallback
goto dns_ok

:dns_fallback
echo   [WARN] Auto-detection failed.
set /p PVE_DNS=  PVE DNS name [e.g. proxmox.local]: 
if "!PVE_DNS!"=="" (
    echo [ERROR] DNS name cannot be empty.
    pause
    exit /b 1
)

:dns_ok
echo   [OK] PVE DNS name: !PVE_DNS!
echo.

:: ── Save site info: IP DNS THUMBPRINT ────────────────────────
set TEMP_INFO=!DATA_DIR!\pve-cert-info.tmp
if exist "!TEMP_INFO!" del "!TEMP_INFO!"
if exist "!INFO_FILE!" (
    for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
        if not "%%A"=="!PVE_IP!" echo %%A %%B %%C>> "!TEMP_INFO!"
    )
)
echo !PVE_IP! !PVE_DNS! !CERT_THUMB!>> "!TEMP_INFO!"
copy /y "!TEMP_INFO!" "!INFO_FILE!" >nul
del "!TEMP_INFO!"

:: ── Step 4 ───────────────────────────────────────────────────
echo [Step 4/5] Updating hosts file
echo -----------------------------------------------------

set HOSTS_FILE=C:\Windows\System32\drivers\etc\hosts

set DNS_EXISTS=0
for /f "tokens=*" %%L in ('type "!HOSTS_FILE!"') do (
    echo %%L | findstr /i "!PVE_DNS!" >nul 2>&1
    if !errorlevel! equ 0 set DNS_EXISTS=1
)

if "!DNS_EXISTS!"=="0" goto hosts_add

echo   [WARN] Entry for !PVE_DNS! already exists:
findstr /i "!PVE_DNS!" "!HOSTS_FILE!"
echo.
set /p OVERWRITE=  Overwrite? [y/N]: 
if /i "!OVERWRITE!"=="y" goto hosts_overwrite
echo   [SKIP] Keeping existing entry.
goto skip_hosts

:hosts_overwrite
set TEMP_HOSTS=%TEMP%\hosts.tmp
findstr /v /i "!PVE_DNS!" "!HOSTS_FILE!" > "!TEMP_HOSTS!"
copy /y "!TEMP_HOSTS!" "!HOSTS_FILE!" >nul
del "!TEMP_HOSTS!"
echo   [OK] Old entry removed.

:hosts_add
echo.>> "!HOSTS_FILE!"
echo # Proxmox VE [!PVE_IP!] - Added by pve-cert-windows.bat>> "!HOSTS_FILE!"
echo !PVE_IP!    !PVE_DNS!>> "!HOSTS_FILE!"
echo   [OK] hosts updated: !PVE_IP!    !PVE_DNS!

:skip_hosts
echo.

:: ── Step 5 ───────────────────────────────────────────────────
echo [Step 5/5] Importing CA certificate to Windows trust store
echo -----------------------------------------------------

certutil -addstore -f "Root" "!CA_LOCAL!" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [OK] CA certificate imported!
) else (
    echo   [ERROR] Import failed. Install manually:
    echo   Double-click !CA_LOCAL! ^> Install Certificate
    echo   ^> Local Machine ^> Trusted Root Certification Authorities
)
echo.

:: ── Summary ──────────────────────────────────────────────────
echo =====================================================
echo   Setup Complete!
echo =====================================================
echo.
echo   PVE IP    : !PVE_IP!
echo   PVE DNS   : !PVE_DNS!
echo   Thumbprint: !CERT_THUMB!
echo   CA cert   : !CA_LOCAL!
echo.
echo   All registered PVE sites:
echo   -----------------------------------
for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
echo.
echo   Open browser: https://!PVE_DNS!:8006
echo.
echo   Uninstall   : pve-cert-windows.bat -u
echo.

set /p OPEN_BROWSER=  Open PVE Web UI now? [y/N]: 
if /i "!OPEN_BROWSER!"=="y" start https://!PVE_DNS!:8006

goto end

:: ============================================================
::  UNINSTALL MODE
:: ============================================================
:do_uninstall

echo [Uninstall Mode] Removing PVE certificate and hosts entry
echo -----------------------------------------------------
echo.

if not exist "!INFO_FILE!" goto uninstall_no_info

set SITE_COUNT=0
for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
    set /a SITE_COUNT+=1
    set SITE_IP_!SITE_COUNT!=%%A
    set SITE_DNS_!SITE_COUNT!=%%B
    set SITE_THUMB_!SITE_COUNT!=%%C
)

if !SITE_COUNT! equ 0 goto uninstall_no_info

echo   Registered PVE sites:
echo   -----------------------------------
for /l %%N in (1,1,!SITE_COUNT!) do (
    echo     [%%N]  !SITE_IP_%%N!  ^<^>  !SITE_DNS_%%N!
)
echo     [0]  Remove ALL
echo.

set /p SITE_CHOICE=  Select [1-!SITE_COUNT!, 0=all]: 
if "!SITE_CHOICE!"=="" goto uninstall_abort
if "!SITE_CHOICE!"=="0" goto uninstall_all

set CHOSEN_IP=!SITE_IP_%SITE_CHOICE%!
set CHOSEN_DNS=!SITE_DNS_%SITE_CHOICE%!
set CHOSEN_THUMB=!SITE_THUMB_%SITE_CHOICE%!
if "!CHOSEN_IP!"=="" goto uninstall_abort

echo.
echo   Selected: !CHOSEN_IP!  ^<^>  !CHOSEN_DNS!
set /p CONFIRM_U=  Proceed? [y/N]: 
if /i not "!CONFIRM_U!"=="y" goto uninstall_abort

call :remove_one "!CHOSEN_IP!" "!CHOSEN_DNS!" "!CHOSEN_THUMB!"
goto uninstall_done

:uninstall_all
echo.
set /p CONFIRM_ALL=  Remove ALL !SITE_COUNT! sites? [y/N]: 
if /i not "!CONFIRM_ALL!"=="y" goto uninstall_abort
for /l %%N in (1,1,!SITE_COUNT!) do (
    call :remove_one "!SITE_IP_%%N!" "!SITE_DNS_%%N!" "!SITE_THUMB_%%N!"
)
goto uninstall_done

:uninstall_no_info
echo   No registered sites found. Enter DNS manually:
set /p MANUAL_DNS=  DNS name [e.g. proxmox.local]: 
if "!MANUAL_DNS!"=="" goto uninstall_abort
call :remove_one "" "!MANUAL_DNS!" ""
goto uninstall_done

:uninstall_abort
echo   Aborted.
pause
exit /b 0

:uninstall_done
echo.
echo =====================================================
echo   Uninstall Complete!
echo =====================================================
echo.
if exist "!INFO_FILE!" (
    set REMAINING=0
    for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do set /a REMAINING+=1
    if "!REMAINING!"=="0" (
        del "!INFO_FILE!"
        echo   No remaining PVE sites.
    ) else (
        echo   Remaining sites:
        for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
    )
) else (
    echo   No remaining PVE sites.
)
echo.
echo   Restart browser to apply changes.
echo   Run pve-cert.sh -u on each PVE server too.
echo.
goto end

:: ============================================================
::  SUBROUTINE: remove_one <IP> <DNS> <THUMBPRINT>
:: ============================================================
:remove_one
set R_IP=%~1
set R_DNS=%~2
set R_THUMB=%~3
set HOSTS_FILE=C:\Windows\System32\drivers\etc\hosts
echo.
echo   --- Removing: !R_IP! !R_DNS! ---

:: Remove from hosts
set DNS_IN_HOSTS=0
for /f "tokens=*" %%L in ('type "!HOSTS_FILE!"') do (
    echo %%L | findstr /i "!R_DNS!" >nul 2>&1
    if !errorlevel! equ 0 set DNS_IN_HOSTS=1
)
if "!DNS_IN_HOSTS!"=="0" (
    echo   [SKIP] No hosts entry for: !R_DNS!
) else (
    set TEMP_HOSTS=%TEMP%\hosts.tmp
    findstr /v /i "!R_DNS!" "!HOSTS_FILE!" > "!TEMP_HOSTS!"
    findstr /v /i "pve-cert-windows.bat" "!TEMP_HOSTS!" > "!HOSTS_FILE!"
    del "!TEMP_HOSTS!"
    echo   [OK] Removed hosts entry: !R_DNS!
)

:: Remove cert by THUMBPRINT
if not "!R_THUMB!"=="" (
    powershell -NoProfile -Command "& { $s = [System.Security.Cryptography.X509Certificates.StoreName]::Root; $l = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine; $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($s,$l); $store.Open('ReadWrite'); $certs = $store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,'!R_THUMB!',$false); foreach($c in $certs){$store.Remove($c)}; $store.Close() }" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK] CA cert removed from trust store [thumbprint: !R_THUMB!]
    ) else (
        echo   [WARN] Could not remove cert. Try manually:
        echo   certmgr.msc ^> Trusted Root CA ^> delete !R_DNS!
    )
) else (
    echo   [WARN] No thumbprint saved. Remove cert manually:
    echo   certmgr.msc ^> Trusted Root CA ^> delete !R_DNS!
)

:: Remove cert file
if not "!R_IP!"=="" (
    if exist "!DATA_DIR!\pve-ca-!R_IP!.crt" (
        del "!DATA_DIR!\pve-ca-!R_IP!.crt"
        echo   [OK] Cert file deleted.
    )
)

:: Remove from info file
if not "!R_IP!"=="" (
    if exist "!INFO_FILE!" (
        set TEMP_INFO=!DATA_DIR!\pve-cert-info.tmp
        if exist "!TEMP_INFO!" del "!TEMP_INFO!"
        for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
            if not "%%A"=="!R_IP!" echo %%A %%B %%C>> "!TEMP_INFO!"
        )
        if exist "!TEMP_INFO!" (
            copy /y "!TEMP_INFO!" "!INFO_FILE!" >nul
            del "!TEMP_INFO!"
        ) else (
            del "!INFO_FILE!"
        )
    )
)
goto :eof

:end
echo.
pause
endlocal
