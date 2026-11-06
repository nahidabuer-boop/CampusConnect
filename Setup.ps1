param([switch]$CheckUi)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Srun.ps1')
[Windows.Forms.Application]::EnableVisualStyles()

$installDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CampusConnect'
$settingsPath = Join-Path $installDir 'settings.xml'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$taskName = 'CampusConnect-' + $identity.User.Value

function Get-TaskFolder {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $scheduler.GetFolder('\')
}

function Get-MonitorTask($Folder) {
    try { $Folder.GetTask($taskName) }
    catch { if ($_.Exception.HResult -ne -2147024894) { throw } }
}

function Enable-Monitor($Portal, [pscredential]$Credential) {
    $folder = Get-TaskFolder
    $existing = Get-MonitorTask $folder
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $definition = $scheduler.NewTask(0)
    $definition.RegistrationInfo.Description = 'CampusConnect automatic SRun campus network sign-in'
    $definition.Principal.UserId = $identity.Name
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.MultipleInstances = 2
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.RestartCount = 999
    $definition.Settings.RestartInterval = 'PT1M'
    $trigger = $definition.Triggers.Create(9)
    $trigger.UserId = $identity.Name
    $action = $definition.Actions.Create(0)
    $action.Path = Join-Path $PSHOME 'powershell.exe'
    $action.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $installDir 'Monitor.ps1') + '"'
    $action.WorkingDirectory = $installDir

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -LiteralPath @((Join-Path $PSScriptRoot 'Srun.ps1'), (Join-Path $PSScriptRoot 'Monitor.ps1')) -Destination $installDir -Force
    $pending = $settingsPath + '.new'
    [pscustomobject]@{Link=$Portal.Link; Credential=$Credential} | Export-Clixml -LiteralPath $pending
    try {
        if ($existing -and $existing.State -eq 4) { $existing.Stop(0) }
        $task = $folder.RegisterTaskDefinition($taskName, $definition, 6, $identity.Name, $null, 3, $null)
        Move-Item -LiteralPath $pending -Destination $settingsPath -Force
        [void]$task.Run($null)
    } finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = '校园网自动连接'
$form.ClientSize = [Drawing.Size]::new(660, 355)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)

function Add-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Location = [Drawing.Point]::new($X, $Y)
    $label.Size = [Drawing.Size]::new($Width, $Height)
    $form.Controls.Add($label)
    $label
}

function Add-Field([string]$Caption, [int]$Y) {
    [void](Add-Label $Caption 24 ($Y + 3) 100 26)
    $field = New-Object Windows.Forms.TextBox
    $field.Location = [Drawing.Point]::new(128, $Y)
    $field.Width = 500
    $form.Controls.Add($field)
    $field
}

[void](Add-Label '填写学校的 SRun 认证链接和账号，掉线后自动登录。' 24 22 610 30)
$link = Add-Field '认证链接' 67
$account = Add-Field '校园网账号' 109
$password = Add-Field '校园网密码' 151
$password.UseSystemPasswordChar = $true
[void](Add-Label '认证链接需要包含 ac_id，例如 ?ac_id=20。密码加密保存在本机。' 24 190 610 30)

$enable = New-Object Windows.Forms.Button
$enable.Text = '保存并启用自启'
$enable.Location = [Drawing.Point]::new(128, 229)
$enable.Size = [Drawing.Size]::new(160, 38)
$form.Controls.Add($enable)
$form.AcceptButton = $enable

$disable = New-Object Windows.Forms.Button
$disable.Text = '停止并关闭自启'
$disable.Location = [Drawing.Point]::new(304, 229)
$disable.Size = [Drawing.Size]::new(160, 38)
$form.Controls.Add($disable)

$status = Add-Label '尚未启用后台连接。' 24 285 610 52

if ($CheckUi) { $form.Dispose(); return }

if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Import-Clixml -LiteralPath $settingsPath
        $link.Text = $saved.Link
        $account.Text = $saved.Credential.UserName
    } catch {}
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({
    try {
        $task = Get-MonitorTask (Get-TaskFolder)
        if (-not $task -or -not $task.Enabled) { $status.Text = '后台连接和自启已关闭。'; return }
        if ($task.State -ne 4) { $status.Text = '后台已配置，等待任务计划程序启动。'; return }
        $current = Get-Content -LiteralPath (Join-Path $installDir 'status.json') -Raw | ConvertFrom-Json
        $checked = [DateTimeOffset]::Parse([string]$current.checkedAt).ToLocalTime()
        if ($checked -lt [DateTimeOffset]::Now.AddMinutes(-2)) { $status.Text = '后台已启动，等待新的检测结果。'; return }
        $status.Text = $checked.ToString('HH:mm:ss') + '  ' + $current.detail
    } catch {}
})

$enable.Add_Click({
    try {
        $portal = Get-PortalSettings $link.Text
        if ([string]::IsNullOrWhiteSpace($account.Text) -or $password.Text.Length -eq 0) { throw '请输入账号和密码。' }
        $credential = [pscredential]::new($account.Text.Trim(), (ConvertTo-SecureString $password.Text -AsPlainText -Force))
        Enable-Monitor $portal $credential
        $password.Clear()
        $status.Text = '已保存并启用自启，正在等待后台检测。'
    } catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法启用') }
})

$disable.Add_Click({
    try {
        $task = Get-MonitorTask (Get-TaskFolder)
        if ($task) {
            $task.Enabled = $false
            if ($task.State -eq 4 -or $task.GetInstances(0).Count -gt 0) { $task.Stop(0) }
        }
        $status.Text = '后台连接和自启已关闭。'
    } catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法停止') }
})

$timer.Start()
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
