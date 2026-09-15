<#
.SYNOPSIS
    Network Diagnostics Installer & Manager
#>

# Capture the original user's paths before any elevation happens
param (
    [string]$OriginalProfile = $env:USERPROFILE,
    [string]$OriginalDesktop = [Environment]::GetFolderPath('Desktop'),
    [string]$OriginalAppData = $env:APPDATA
)

# ---------------------------------------------------------
# 1. CHECK FOR ADMIN PRIVILEGES
# ---------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Requesting Administrative Privileges..." -ForegroundColor Yellow
    
    # Check if running from memory (no file path) or from a local file
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        # Re-run the in-memory download command for the elevated session
        $MemCommand = "& ([scriptblock]::Create((irm 'https://chris94.uk/install-scripts/Windows-Installer.ps1'))) -OriginalProfile `'$OriginalProfile`' -OriginalDesktop `'$OriginalDesktop`' -OriginalAppData `'$OriginalAppData`'"
        $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $MemCommand)
    } else {
        # Pass the original user's directories into the elevated Admin session using the local file
        $Arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-OriginalProfile", "`"$OriginalProfile`"",
            "-OriginalDesktop", "`"$OriginalDesktop`"",
            "-OriginalAppData", "`"$OriginalAppData`""
        )
    }
    
    Start-Process powershell.exe -ArgumentList $Arguments -Verb RunAs
    exit
}

# ---------------------------------------------------------
# 2. CONFIGURATION
# ---------------------------------------------------------
# Map to the original user's folders, NOT the Admin's folders
$script:TargetDir = "$OriginalProfile\Network-Testing-Tools\"
$script:RepoOwner = "Chrisb003"
$script:RepoName  = "Network-Testing-Tools"
$script:Branch    = "main"
$script:Token     = ""
$script:Version   = "1.0.0"

# Set to TEMP since in-memory scripts do not have a $PSScriptRoot
Set-Location $env:TEMP

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   NETWORK DIAGNOSTICS - WINDOWS INSTALLER & MANAGER" -ForegroundColor Cyan
Write-Host "   Installer Version: $script:Version" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------
# 3. EXISTING INSTALLATION CHECK & UNINSTALL OPTION
# ---------------------------------------------------------
if (Test-Path "$script:TargetDir\app.py") {
    Write-Host ""
    Write-Host "[*] Existing installation detected at $script:TargetDir." -ForegroundColor Cyan
    $removeApp = Read-Host "[?] Do you want to REMOVE the existing installation? (y/N)"
    if ($removeApp -match '^[Yy]') {
        
        $keepDb = Read-Host "[?] Do you want to KEEP your database files? (y/N)"
        $confirmWipe = Read-Host "[?] Are you ABSOLUTELY sure you want to uninstall? Type 'yes' to confirm"
        
        if ($confirmWipe -eq 'yes') {
            Write-Host "[*] Removing Startup shortcut if present..." -ForegroundColor Gray
            Remove-Item "$OriginalAppData\Microsoft\Windows\Start Menu\Programs\Startup\Network Diagnostics.lnk" -ErrorAction SilentlyContinue
            Write-Host "[*] Removing Desktop shortcut if present..." -ForegroundColor Gray
            Remove-Item "$OriginalDesktop\Network Diagnostics.lnk" -ErrorAction SilentlyContinue
            Write-Host "[*] Removing Start Menu shortcut if present..." -ForegroundColor Gray
            Remove-Item "$OriginalAppData\Microsoft\Windows\Start Menu\Programs\Network Diagnostics.lnk" -ErrorAction SilentlyContinue
            
            # --- BACKUP LOGIC (DATABASE ONLY) ---
            if ($keepDb -match '^[Yy]') {
                Write-Host "[*] Backing up database files..." -ForegroundColor Cyan
                $backupDir = Join-Path $OriginalDesktop "Network-Diagnostics-Backup"
                if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
                
                # Copies ONLY database files
                Get-ChildItem -Path $script:TargetDir -Include *.db, *.sqlite -Recurse -ErrorAction SilentlyContinue | Copy-Item -Destination $backupDir -Force
                
                # Ensure the original user has full permissions to edit or delete the backed-up files despite Admin execution
                icacls "$backupDir" /grant "Everyone:(F)" /T /C /Q | Out-Null
                Write-Host "[+] Data backed up safely to: $backupDir" -ForegroundColor Green
            }
            
            Write-Host "[*] Deleting application directory..." -ForegroundColor Gray
            Remove-Item "$script:TargetDir" -Recurse -Force -ErrorAction SilentlyContinue
            
            Write-Host "[✓] Application completely removed." -ForegroundColor Green
            exit
        } else {
            Write-Host "[*] Deletion cancelled." -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------
# 4. WELCOME BANNER & INSTALL PROMPT
# ---------------------------------------------------------
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   NETWORK DIAGNOSTICS - WINDOWS INSTALLER & MANAGER" -ForegroundColor Cyan
Write-Host "   Installer Version: $script:Version" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "This script installs, updates, or manages the Network" -ForegroundColor White
Write-Host "Diagnostics Dashboard, Python dependencies, and tools." -ForegroundColor White
Write-Host ""
$proceed = Read-Host "[?] Do you want to proceed with the installation of system prerequisites? (y/N)"

$SkipPrereqs = $false
if ($proceed -notmatch '^[Yy]') {
    Write-Host "[*] Skipping system prerequisites. Moving to application updates and configuration..." -ForegroundColor Yellow
    $SkipPrereqs = $true
}

# ---------------------------------------------------------
# 5. CHECK FOR PYTHON (AUTO-DOWNLOAD FROM PYTHON.ORG)
# ---------------------------------------------------------
if (-not $SkipPrereqs) {
    $pythonTest = Get-Command python -ErrorAction SilentlyContinue

    # Verify it isn't the fake Windows Store shortcut
    if ($pythonTest) {
        $testOutput = python --version 2>&1 | Out-String
        if ($testOutput -match "Python was not found") {
            $pythonTest = $null # Force the script to treat Python as missing
        }
    }

    if (-not $pythonTest) {
        Write-Host ""
        Write-Host "[!] Python was not found on this system." -ForegroundColor Red
        Write-Host "[*] Downloading official Python 3.14.7 installer from python.org..." -ForegroundColor Cyan
        
        $pyVersion = "3.14.7"
        $pyUrl = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-amd64.exe"
        $installerPath = "$env:TEMP\python_installer.exe"
        
        Invoke-WebRequest -Uri $pyUrl -OutFile $installerPath
        
        Write-Host "[*] Installing Python silently (this may take a minute). Please wait..." -ForegroundColor Yellow
        $installArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0"
        Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait
        
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        
        Write-Host "[✓] Python installation complete. Refreshing environment..." -ForegroundColor Green
        
        # Safely merge Machine and User PATH to prevent breaking built-in Windows commands like icacls
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
        [Environment]::SetEnvironmentVariable("Path", "$machinePath;$userPath", "Process")
    } else {
        Write-Host "[✓] Python is detected." -ForegroundColor Green
    }
}

# Explicitly find a working python.exe (Bypasses Windows Store alias issues)
$script:PythonCmd = $null
$allPy = Get-Command python -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
foreach ($p in $allPy) {
    $testOut = & $p --version 2>&1 | Out-String
    if ($testOut -match "Python") {
        $script:PythonCmd = $p
        break
    }
}

# Fallback if PowerShell hasn't updated its command cache after a fresh installation
if (-not $script:PythonCmd) {
    $fallbackPaths = @(
        "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe",
        "C:\Program Files\Python*\python.exe",
        "C:\Program Files (x86)\Python*\python.exe"
    )
    foreach ($path in $fallbackPaths) {
        $found = Get-ChildItem $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $script:PythonCmd = $found.FullName
            break
        }
    }
}

if (-not $script:PythonCmd -and -not $SkipPrereqs) {
    Write-Host "[X] Valid Python executable not found. Please restart your computer and run this script again." -ForegroundColor Red
    pause
    exit
}

# Locate pythonw.exe for silent background execution
$script:PythonWCmd = $null
if ($script:PythonCmd) {
    $derivedW = $script:PythonCmd -replace "(?i)python\.exe$", "pythonw.exe"
    if (Test-Path $derivedW) { 
        $script:PythonWCmd = $derivedW 
    } else { 
        $script:PythonWCmd = $script:PythonCmd 
    }
}

# ---------------------------------------------------------
# 6. CHECK FOR INTERNET CONNECTIVITY
# ---------------------------------------------------------
if (-not $SkipPrereqs) {
    Write-Host ""
    Write-Host "[*] Checking for internet connectivity..." -ForegroundColor Cyan
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue

    if (-not $ping) {
        Write-Host ""
        Write-Host "[!] No Internet: Pip Requirements skipped." -ForegroundColor Yellow
    } else {
        if ($script:PythonCmd) {
            Write-Host "[✓] Internet detected. Installing system certificates..." -ForegroundColor Green
            & $script:PythonCmd -m pip install pip-system-certs | Out-Null
        }
    }
}

# ---------------------------------------------------------
# 7. DOWNLOAD OR UPDATE CODE FROM GITHUB
# ---------------------------------------------------------
Write-Host ""
Write-Host "[*] Managing application files..." -ForegroundColor Cyan
if (-not (Test-Path $script:TargetDir)) {
    New-Item -ItemType Directory -Path $script:TargetDir | Out-Null
}

if (-not (Test-Path "$script:TargetDir\app.py")) {
    Write-Host "[*] Downloading latest project files from GitHub..." -ForegroundColor Cyan
    $zipPath = "$env:TEMP\network_dashboard.zip"
    $extractPath = "$env:TEMP\network_dashboard_extract"

    if (-not [string]::IsNullOrWhiteSpace($script:Token)) {
        $headers = @{
            'Authorization' = "token $script:Token"
            'Accept'        = 'application/vnd.github.v3+json'
        }
        Invoke-WebRequest -Uri "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/zipball/$script:Branch" -Headers $headers -OutFile $zipPath
    } else {
        Invoke-WebRequest -Uri "https://github.com/$script:RepoOwner/$script:RepoName/archive/refs/heads/$script:Branch.zip" -OutFile $zipPath
    }
    
    Write-Host "[*] Extracting files into $script:TargetDir..." -ForegroundColor Cyan
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    
    $extractedFolder = Get-ChildItem $extractPath | Select-Object -First 1
    Copy-Item "$($extractedFolder.FullName)\*" $script:TargetDir -Recurse -Force
    
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[✓] Files downloaded into $script:TargetDir." -ForegroundColor Green
} else {
    Write-Host "[✓] Code directory already exists. Skipping full re-download to preserve configs/database." -ForegroundColor Green
    $updateCode = Read-Host "[?] Do you want to pull/update latest code changes from GitHub repository? (y/N)"
    if ($updateCode -match '^[Yy]') {
        Write-Host "[*] Updating code from GitHub..." -ForegroundColor Cyan
        $zipPath = "$env:TEMP\network_dashboard.zip"
        $extractPath = "$env:TEMP\network_dashboard_extract"

        if (-not [string]::IsNullOrWhiteSpace($script:Token)) {
            $headers = @{
                'Authorization' = "token $script:Token"
                'Accept'        = 'application/vnd.github.v3+json'
            }
            Invoke-WebRequest -Uri "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/zipball/$script:Branch" -Headers $headers -OutFile $zipPath
        } else {
            Invoke-WebRequest -Uri "https://github.com/$script:RepoOwner/$script:RepoName/archive/refs/heads/$script:Branch.zip" -OutFile $zipPath
        }
        
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        
        $extractedFolder = Get-ChildItem $extractPath | Select-Object -First 1
        
        Get-ChildItem "$($extractedFolder.FullName)" -Recurse | ForEach-Object {
            $relPath = $_.FullName.Substring($extractedFolder.FullName.Length + 1)
            if ($relPath -notin @('webport', 'standalone', 'disablecleanup')) {
                $destPath = Join-Path $script:TargetDir $relPath
                if ($_.PSIsContainer) {
                    if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath | Out-Null }
                } else {
                    Copy-Item $_.FullName $destPath -Force
                }
            }
        }
        
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[✓] Code updated." -ForegroundColor Green
    }
}

# ---------------------------------------------------------
# 8. APP CONFIGURATION & DEDICATED DEVICE
# ---------------------------------------------------------
Write-Host ""
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

# 8a. Web Port Prompt
$currentPort = "81"
if (Test-Path "$script:TargetDir\webport") {
    $currentPort = (Get-Content "$script:TargetDir\webport" -Raw).Trim()
}

$userPort = Read-Host "[?] Enter the port for the Web Dashboard [Default: $currentPort]"
if ([string]::IsNullOrWhiteSpace($userPort)) {
    $userPort = $currentPort
}
if ($userPort -notmatch '^\d+$') {
    Write-Host "    [!] Invalid port format. Reverting to $currentPort." -ForegroundColor Yellow
    $userPort = $currentPort
}

Set-Content -Path "$script:TargetDir\webport" -Value $userPort
Write-Host "    [✓] Web port configured to $userPort." -ForegroundColor Green
Write-Host ""

# 8b. Dedicated Device Prompt
$isDedicated = Read-Host "[?] Are you using this device as a dedicated test device? (y/N)"
if ($isDedicated -match '^[Yy]') {
    Write-Host "    [*] Configuring for dedicated test device mode..." -ForegroundColor Cyan
    
    if (-not (Test-Path "$script:TargetDir\standalone")) {
        New-Item -ItemType File -Path "$script:TargetDir\standalone" | Out-Null
        Write-Host "        [+] Created 'standalone' file." -ForegroundColor Green
    }
    if (-not (Test-Path "$script:TargetDir\disablecleanup")) {
        New-Item -ItemType File -Path "$script:TargetDir\disablecleanup" | Out-Null
        Write-Host "        [+] Created 'disablecleanup' file." -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "    [?] Windows Mobile Hotspot Configuration:" -ForegroundColor Cyan
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $asTask = ([System.Runtime.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 })[0]
        $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetInternetConnectionProfile()
        $tetheringManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateForConnectionProfile($connectionProfile)
        
        $doHotspotSetup = $false
        
        if ($tetheringManager.TetheringOperationalState -eq 1) {
            $ans = Read-Host "        [?] Hotspot is ACTIVE. (D)isable, (R)econfigure, or (K)eep? [D/R/K]"
            if ($ans -match '^[Dd]') {
                $task = $tetheringManager.StopTetheringAsync()
                $asTask.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($task)).GetAwaiter().GetResult() | Out-Null
                Write-Host "        [✓] Mobile Hotspot disabled." -ForegroundColor Green
            } elseif ($ans -match '^[Rr]') {
                $task = $tetheringManager.StopTetheringAsync()
                $asTask.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($task)).GetAwaiter().GetResult() | Out-Null
                $doHotspotSetup = $true
            } else {
                Write-Host "        [*] Keeping existing Hotspot configuration active." -ForegroundColor Gray
            }
        } else {
            $ans = Read-Host "        [?] Hotspot is DISABLED. Do you want to enable/configure it? (y/N)"
            if ($ans -match '^[Yy]') {
                $doHotspotSetup = $true
            }
        }

        if ($doHotspotSetup) {
            $ssid = Read-Host "        Enter Hotspot SSID [Default: Network-Dashboard]"
            $pass = Read-Host "        Enter Hotspot Password (min 8 chars) [Default: dashboard123]"
            
            $config = $tetheringManager.GetCurrentConfiguration()
            $config.Ssid = if ([string]::IsNullOrWhiteSpace($ssid)) { "Network-Dashboard" } else { $ssid }
            $config.Passphrase = if ([string]::IsNullOrWhiteSpace($pass)) { "dashboard123" } else { $pass }
            
            $configTask = $tetheringManager.ConfigureAsync($config)
            $asTask.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($configTask)).GetAwaiter().GetResult() | Out-Null
            
            $startTask = $tetheringManager.StartTetheringAsync()
            $asTask.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($startTask)).GetAwaiter().GetResult() | Out-Null
            Write-Host "        [✓] Mobile Hotspot successfully configured and enabled!" -ForegroundColor Green
        }
    } catch {
        Write-Host "        [!] Mobile Hotspot is not supported by this device's Wi-Fi adapter or requires modern Windows 10/11." -ForegroundColor Red
        Write-Host "        Tip: You can also manage Mobile Hotspot directly in Windows Settings (Network & internet -> Mobile hotspot)." -ForegroundColor Yellow
    }
} else {
    Write-Host "    [*] Skipping dedicated test device configurations." -ForegroundColor Gray
}

# ---------------------------------------------------------
# 9. FIX DIRECTORY PERMISSIONS FOR ALL USERS
# ---------------------------------------------------------
Write-Host "    [*] Unlocking folder permissions for all users..." -ForegroundColor Cyan
icacls "$script:TargetDir" /grant "Everyone:(F)" /T /C /Q | Out-Null
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

# ---------------------------------------------------------
# 10. OPTIONAL USER-LOGIN STARTUP (STARTUP FOLDER)
# ---------------------------------------------------------
Write-Host ""
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

$icoPath = Join-Path $script:TargetDir 'static\favicon.ico'
$startupLnk = "$OriginalAppData\Microsoft\Windows\Start Menu\Programs\Startup\Network Diagnostics.lnk"

if (Test-Path $startupLnk) {
    Write-Host "[?] Background User-Login Startup is currently ENABLED." -ForegroundColor Yellow
    $toggleStartup = Read-Host "[?] Do you want to DISABLE/REMOVE the startup shortcut? (y/N)"
    if ($toggleStartup -match '^[Yy]') {
        Remove-Item $startupLnk -Force -ErrorAction SilentlyContinue
        Write-Host "    [✓] Startup shortcut removed." -ForegroundColor Green
    }
} else {
    Write-Host "[?] Background User-Login Startup is currently DISABLED." -ForegroundColor Yellow
    $toggleStartup = Read-Host "[?] Do you want to ENABLE automatic start on user login? (y/N)"
    if ($toggleStartup -match '^[Yy]') {
        
        Write-Host "    How should the dashboard start on login?"
        Write-Host "      1) Visible Terminal Window"
        Write-Host "      2) Invisible Background Process (Silent)"
        $startMode = Read-Host "    Select option (1 or 2)"

        Write-Host "    [*] Creating startup shortcut..." -ForegroundColor Cyan
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($startupLnk)
        
        if ($startMode -eq '2') {
            $sc.TargetPath = $script:PythonWCmd
            $modeMsg = "Invisible Background Process"
            
            # --- NEW: Disable browser autostart for headless mode ---
            Set-Content -Path "$script:TargetDir\autostart" -Value "0"
        } else {
            $sc.TargetPath = $script:PythonCmd
            $modeMsg = "Visible Terminal Window"
            
            # --- NEW: Ensure browser autostart is enabled for visible mode ---
            Set-Content -Path "$script:TargetDir\autostart" -Value "1"
        }
        
        $sc.Arguments = "`"$script:TargetDir\setup_env.py`""
        $sc.WorkingDirectory = $script:TargetDir
        if (Test-Path $icoPath) { 
            $sc.IconLocation = "$icoPath,0" 
        }
        $sc.Save()
        Write-Host "    [✓] Startup on login enabled ($modeMsg)." -ForegroundColor Green
    }
}
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

# ---------------------------------------------------------
# 11. DESKTOP SHORTCUT CREATION
# ---------------------------------------------------------
Write-Host ""
$deskLnk = Join-Path $OriginalDesktop 'Network Diagnostics.lnk'

if (Test-Path $deskLnk) {
    Write-Host "[✓] Desktop shortcut already exists." -ForegroundColor Green
} else {
    $createDesktop = Read-Host "[?] Do you want to create a Desktop shortcut? (y/N)"
    if ($createDesktop -match '^[Yy]') {
        Write-Host "    [*] Generating Desktop shortcut..." -ForegroundColor Cyan
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($deskLnk)
        $sc.TargetPath = $script:PythonCmd
        $sc.Arguments = "`"$script:TargetDir\setup_env.py`""
        $sc.WorkingDirectory = $script:TargetDir
        if (Test-Path $icoPath) { 
            $sc.IconLocation = "$icoPath,0" 
        }
        $sc.Save()
        Write-Host "[✓] Desktop shortcut created successfully." -ForegroundColor Green
    }
}

# ---------------------------------------------------------
# 12. START MENU SHORTCUT CREATION
# ---------------------------------------------------------
Write-Host ""
$startMenuPath = Join-Path $OriginalAppData 'Microsoft\Windows\Start Menu\Programs'
$startLnk = Join-Path $startMenuPath 'Network Diagnostics.lnk'

if (Test-Path $startLnk) {
    Write-Host "[✓] Start Menu shortcut already exists." -ForegroundColor Green
} else {
    $createStartMenu = Read-Host "[?] Do you want to create a Start Menu shortcut? (y/N)"
    if ($createStartMenu -match '^[Yy]') {
        Write-Host "    [*] Generating Start Menu shortcut..." -ForegroundColor Cyan
        if (-not (Test-Path $startMenuPath)) { New-Item -ItemType Directory -Path $startMenuPath | Out-Null }
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($startLnk)
        $sc.TargetPath = $script:PythonCmd
        $sc.Arguments = "`"$script:TargetDir\setup_env.py`""
        $sc.WorkingDirectory = $script:TargetDir
        if (Test-Path $icoPath) { 
            $sc.IconLocation = "$icoPath,0" 
        }
        $sc.Save()
        Write-Host "[✓] Start Menu shortcut created successfully." -ForegroundColor Green
    }
}

# ---------------------------------------------------------
# 13. CHECK AND INSTALL NPCAP (IF MISSING)
# ---------------------------------------------------------
Write-Host ""
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

if (-not $SkipPrereqs) {
    $npcapInstalled = Test-Path "$env:SystemRoot\System32\Npcap"

    if ($npcapInstalled) {
        Write-Host "[✓] Npcap is already detected on this system. Skipping installation." -ForegroundColor Green
    } else {
        Write-Host "[!] Npcap is required for network packet capture features." -ForegroundColor Yellow
        Write-Host "    (The free version requires you to click through the installer manually)." -ForegroundColor Gray
        $installNpcap = Read-Host "[?] Do you want to download and install Npcap now? (y/N)"

        if ($installNpcap -match '^[Yy]') {
            Write-Host "    [*] Downloading the latest Npcap installer..." -ForegroundColor Cyan
            
            $npcapUrl = "https://npcap.com/dist/npcap-1.88.exe"
            $npcapInstaller = "$env:TEMP\npcap_installer.exe"
            
            Invoke-WebRequest -Uri $npcapUrl -OutFile $npcapInstaller -UseBasicParsing
            
            Write-Host "    [*] Launching Npcap installer. Please complete the installation window that pops up." -ForegroundColor Yellow
            
            Start-Process -FilePath $npcapInstaller -Wait
            
            Remove-Item $npcapInstaller -Force -ErrorAction SilentlyContinue
            Write-Host "    [✓] Npcap installation step completed." -ForegroundColor Green
        } else {
            Write-Host "    [*] Skipping Npcap installation." -ForegroundColor Gray
        }
    }
} else {
    Write-Host "[*] Skipping Npcap checks due to prerequisite bypass." -ForegroundColor Gray
}
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

# ---------------------------------------------------------
# 14. FINAL SUMMARY & LAUNCH
# ---------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   SETUP COMPLETE!" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $script:PythonCmd) {
    Write-Host "[!] Python command missing. Could not launch the dashboard automatically." -ForegroundColor Red
    exit
}

Write-Host "[*] Checking for running instances..." -ForegroundColor Cyan

# Query Windows processes to see if Python is currently running setup_env.py
$isRunning = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "setup_env.py" }

if ($isRunning) {
    Write-Host "[✓] Network Diagnostics is already running. Skipping launch." -ForegroundColor Green
} else {
    Write-Host "[*] Launching Setup Script from $script:TargetDir..." -ForegroundColor Cyan
    Set-Location $script:TargetDir
    & $script:PythonCmd setup_env.py
}