param([string]$CheckLink)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Srun.ps1')

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseProxy = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(8)

function Read-Portal([string]$Url, [hashtable]$Query = @{}) {
    $builder = [UriBuilder]::new($Url)
    $queryParts = @($builder.Query.TrimStart('?') | Where-Object { $_ })
    foreach ($entry in $Query.GetEnumerator()) {
        $queryParts += '{0}={1}' -f [uri]::EscapeDataString($entry.Key), [uri]::EscapeDataString([string]$entry.Value)
    }
    $builder.Query = ($queryParts + ('_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) -join '&'
    $client.GetStringAsync($builder.Uri).GetAwaiter().GetResult()
}

function Read-Status {
    foreach ($origin in @($portal.SecureOrigin, $portal.ReadOnlyOrigin) | Select-Object -Unique) {
        try {
            $body = Read-Portal ($origin + '/cgi-bin/rad_user_info') @{callback='campusConnect'}
            $state = Get-PortalState $body
            if ($state -ne 'unknown') { return $state }
        } catch {}
    }
    'unknown'
}

function Read-ClientIp {
    foreach ($page in @($portal.SecurePage, $portal.Link) | Select-Object -Unique) {
        try {
            $html = Read-Portal $page
            if ($html -match '\bip\s*:\s*["'']([0-9.]+)["'']') {
                $address = $null
                if ([Net.IPAddress]::TryParse($Matches[1], [ref]$address) -and
                    $address.AddressFamily -eq 'InterNetwork' -and $address.ToString() -ne '0.0.0.0') { return $address.ToString() }
            }
        } catch {}
    }
    throw 'No client IP in the portal page'
}

if ($CheckLink) {
    $portal = Get-PortalSettings $CheckLink
    Read-Status
    $client.Dispose()
    return
}

$settings = Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'settings.xml')
$portal = Get-PortalSettings $settings.Link
$statusPath = Join-Path $PSScriptRoot 'status.json'
$failures = 0
$retrySeconds = 30
$nextAttempt = [DateTime]::MinValue
$detail = ''
$lastState = ''

function Write-MonitorStatus([string]$State, [string]$Detail) {
    @{ state=$State; detail=$Detail; checkedAt=[DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

try {
    while ($true) {
        $state = Read-Status
        if ($state -eq 'online') {
            $failures = 0
            $retrySeconds = 30
            $nextAttempt = [DateTime]::MinValue
            $detail = '认证正常，正在后台监测。'
        } elseif ($state -eq 'offline') {
            $failures++
            if ($lastState -ne 'offline') { $detail = '检测到未认证，正在确认。' }
            if ($failures -ge 2 -and [DateTime]::UtcNow -ge $nextAttempt) {
                $detail = '正在尝试自动登录。'
                Write-MonitorStatus $state $detail
                $stage = '读取认证页面'
                try {
                    $ip = Read-ClientIp
                    $stage = '通过 HTTPS 获取挑战码'
                    $reply = Read-Portal ($portal.SecureOrigin + '/cgi-bin/get_challenge') @{
                        callback='campusConnect'; username=$settings.Credential.UserName; ip=$ip
                    }
                    $challenge = ConvertFrom-PortalResponse $reply
                    if ($challenge.error -ne 'ok' -or -not $challenge.challenge) { throw 'No challenge' }
                    $state = Read-Status
                    if ($state -eq 'offline') {
                        $stage = '通过 HTTPS 提交登录'
                        $query = New-LoginQuery $settings.Credential $ip $portal.AcId $challenge.challenge
                        $query.callback = 'campusConnect'
                        try { $result = ConvertFrom-PortalResponse (Read-Portal ($portal.SecureOrigin + '/cgi-bin/srun_portal') $query) }
                        finally { $query.Clear() }
                        if ($result.error -eq 'ok') { $detail = '登录已受理，正在等待确认在线。' }
                        elseif (('{0} {1} {2}' -f $result.error, $result.error_msg, $result.ecode) -match 'password|passwd|E2553') {
                            $detail = '学校可能拒绝了账号或密码，请核对后重新保存。'
                            $retrySeconds = 900
                        } else { $detail = '学校未确认登录成功，稍后重试。' }
                    } elseif ($state -eq 'online') { $detail = '已恢复在线。' }
                    else { $detail = '无法确认当前认证状态，稍后检查。' }
                } catch { $detail = "$stage 失败，稍后重试。" }
                $nextAttempt = [DateTime]::UtcNow.AddSeconds($retrySeconds)
                $retrySeconds = [Math]::Min(900, $retrySeconds * 2)
            }
        } else {
            $failures = 0
            $detail = '认证接口不可达或返回不兼容，请检查校园网和认证链接。'
        }
        Write-MonitorStatus $state $detail
        $lastState = $state
        Start-Sleep -Seconds 10
    }
} finally { $client.Dispose() }
