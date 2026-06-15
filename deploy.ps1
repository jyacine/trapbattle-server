# deploy.ps1 — build & push Linux server binary to VM, then restart the service
# Usage: .\deploy.ps1

$IP         = "172.174.208.254"
$USER       = "labadmin"
$PASS       = "ZeroTrust@Lab2026!"
$LOCAL_EXE  = "$PSScriptRoot\export\linux\TrapBattle Server.x86_64"
$LOCAL_PCK  = "$PSScriptRoot\export\linux\TrapBattle Server.pck"
$REMOTE_EXE = "/home/labadmin/TrapBattle_Server"
$REMOTE_PCK = "/home/labadmin/TrapBattle_Server.pck"

# ── Verify local files exist ──────────────────────────────────────────────────
if (-not (Test-Path $LOCAL_EXE)) {
    Write-Error "Export not found: $LOCAL_EXE`nExport the project first via Godot → Project → Export → Linux."
    exit 1
}

# ── SSH askpass helper (Windows OpenSSH non-interactive password auth) ────────
$askpass = "$env:TEMP\sshpass.cmd"
Set-Content $askpass "@echo $PASS"
$env:SSH_ASKPASS         = $askpass   # tells SSH which program to call for the password
$env:SSH_ASKPASS_REQUIRE = "force"    # forces askpass even when a terminal is present
$env:DISPLAY             = "dummy"    # must be set for askpass to activate on Windows

$ssh_opts = "-o StrictHostKeyChecking=no -o BatchMode=no"

function Invoke-SSH($cmd) {
    & ssh $ssh_opts.Split(" ") "$USER@$IP" $cmd
}
function Invoke-SCP($local, $remote) {
    & scp $ssh_opts.Split(" ") $local "${USER}@${IP}:${remote}"
}

# ── Step 1: stop existing process ────────────────────────────────────────────
Write-Host ">> Stopping existing server process..." -ForegroundColor Cyan
Invoke-SSH "pkill -f TrapBattle_Server; true"
Start-Sleep -Seconds 1

# ── Step 2: copy executable ───────────────────────────────────────────────────
Write-Host ">> Copying executable..." -ForegroundColor Cyan
Invoke-SCP $LOCAL_EXE $REMOTE_EXE
if ($LASTEXITCODE -ne 0) { Write-Error "scp failed"; exit 1 }

# ── Step 3: copy .pck if separate (embed_pck=false) ──────────────────────────
if (Test-Path $LOCAL_PCK) {
    Write-Host ">> Copying PCK..." -ForegroundColor Cyan
    Invoke-SCP $LOCAL_PCK $REMOTE_PCK
    if ($LASTEXITCODE -ne 0) { Write-Error "scp pck failed"; exit 1 }
}

# ── Step 4: chmod + start detached ───────────────────────────────────────────
Write-Host ">> Starting server..." -ForegroundColor Cyan
Invoke-SSH "chmod +x $REMOTE_EXE && setsid nohup $REMOTE_EXE --headless < /dev/null > /home/labadmin/trapserver.log 2>&1 &"

Start-Sleep -Seconds 2

# ── Step 5: verify it is running ─────────────────────────────────────────────
Write-Host ">> Checking process..." -ForegroundColor Cyan
Invoke-SSH "pgrep -a -f TrapBattle_Server && echo 'SERVER RUNNING' || echo 'WARNING: process not found'"

Write-Host "`nDone. Tail logs: ssh $USER@$IP 'tail -f /home/labadmin/trapserver.log'" -ForegroundColor Green
