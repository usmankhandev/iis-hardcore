<powershell>
# First-boot bootstrap: make the server reachable by Ansible, then PROVE it.
# Writes C:\ProgramData\bootstrap.status = OK | FAILED: <reason>
$ErrorActionPreference = 'Stop'
$LogFile    = 'C:\ProgramData\bootstrap.log'
$StatusFile = 'C:\ProgramData\bootstrap.status'
$UserName   = 'ansible'
$ParamName  = '__PARAM__'
$Region     = '__REGION__'

Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Step([string]$Message) {
    Write-Output ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

try {
    Set-Content -Path $StatusFile -Value 'RUNNING'

    # ---- 1. Password from SSM (retry: the instance profile can take a minute)
    Write-Step "Reading password from SSM parameter $ParamName"
    $pw = $null
    for ($i = 1; $i -le 30 -and -not $pw; $i++) {
        try { $pw = (Get-SSMParameter -Name $ParamName -WithDecryption $true -Region $Region).Value }
        catch { Write-Step "SSM not ready (attempt $i/30): $($_.Exception.Message)"; Start-Sleep -Seconds 10 }
    }
    if (-not $pw) { throw "Could not read $ParamName from SSM after 30 attempts" }
    $secure = ConvertTo-SecureString $pw -AsPlainText -Force
    Write-Step 'Password retrieved'

    # ---- 2. ansible user: exists, current password, enabled, administrator
    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        Write-Step "Creating local user '$UserName'"
        New-LocalUser -Name $UserName -Password $secure -PasswordNeverExpires -AccountNeverExpires `
            -Description 'Ansible automation account' | Out-Null
    } else {
        Write-Step "User '$UserName' exists; syncing password with SSM"
        Set-LocalUser -Name $UserName -Password $secure
        Enable-LocalUser -Name $UserName
    }
    if (-not (Get-LocalGroupMember -Group 'Administrators' | Where-Object { $_.Name -like "*\$UserName" })) {
        Write-Step "Adding '$UserName' to Administrators"
        Add-LocalGroupMember -Group 'Administrators' -Member $UserName
    }

    # Local admins get a filtered (non-admin) token over the network unless this is 1.
    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if ((Get-ItemProperty $uacKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy -ne 1) {
        Write-Step 'Setting LocalAccountTokenFilterPolicy=1 (remote admin for local accounts)'
        Set-ItemProperty $uacKey -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
    }

    # ---- 3. WinRM over HTTPS
    Write-Step 'Enabling PowerShell remoting'
    Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null
    if (-not (Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' })) {
        Write-Step 'Creating HTTPS listener (self-signed certificate)'
        $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
        New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * `
            -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
    }
    if (-not (Get-NetFirewallRule -DisplayName 'WinRM HTTPS' -ErrorAction SilentlyContinue)) {
        Write-Step 'Opening Windows Firewall for TCP 5986'
        New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP `
            -LocalPort 5986 -Action Allow | Out-Null
    }

    # ---- 4. Self-test: log in over WinRM HTTPS as ansible, exactly like Ansible will
    $loginOk = $false
    try {
        $cred = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$UserName", $secure)
        $opt  = New-PSSessionOption -SkipCACheck -SkipCNCheck
        $who  = Invoke-Command -ComputerName localhost -Port 5986 -UseSSL -Credential $cred `
                    -SessionOption $opt -ScriptBlock { whoami }
        $loginOk = ($who -like "*\$UserName")
        Write-Step "WinRM self-test logged in as: $who"
    } catch { Write-Step "WinRM self-test failed: $($_.Exception.Message)" }

    # ---- 5. Validate: every check must pass, or the bootstrap is FAILED
    Write-Step 'Validating'
    $checks = [ordered]@{
        'ansible user exists'      = [bool](Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)
        'ansible user enabled'     = [bool]((Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue).Enabled)
        'ansible is administrator' = [bool](Get-LocalGroupMember -Group 'Administrators' | Where-Object { $_.Name -like "*\$UserName" })
        'WinRM service running'    = ((Get-Service WinRM).Status -eq 'Running')
        'HTTPS listener present'   = [bool](Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' })
        'port 5986 listening'      = [bool](Get-NetTCPConnection -LocalPort 5986 -State Listen -ErrorAction SilentlyContinue)
        'firewall rule enabled'    = [bool](Get-NetFirewallRule -DisplayName 'WinRM HTTPS' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
        'WinRM login as ansible'   = $loginOk
    }
    foreach ($c in $checks.GetEnumerator()) {
        Write-Step ("CHECK {0,-26} {1}" -f $c.Key, $(if ($c.Value) { 'PASS' } else { 'FAIL' }))
    }
    $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value }).Count
    if ($failed -gt 0) { throw "$failed validation check(s) failed" }

    Set-Content -Path $StatusFile -Value 'OK'
    Write-Step 'Bootstrap completed successfully'
}
catch {
    $msg = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Write-Step "BOOTSTRAP FAILED: $msg"
    Set-Content -Path $StatusFile -Value "FAILED: $msg"
}
finally {
    Stop-Transcript | Out-Null
}
</powershell>