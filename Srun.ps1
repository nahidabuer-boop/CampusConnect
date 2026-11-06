Add-Type -AssemblyName System.Net.Http
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Security.Cryptography;

public static class CampusSrun {
    static uint[] Pack(string text, bool appendLength) {
        var words = new uint[(text.Length + 3) / 4 + (appendLength ? 1 : 0)];
        for (int i = 0; i < text.Length; i++) words[i / 4] |= (uint)text[i] << ((i % 4) * 8);
        if (appendLength) words[words.Length - 1] = (uint)text.Length;
        return words;
    }

    public static string Encode(string json, string token) {
        var words = Pack(json, true);
        var key = Pack(token, false);
        if (key.Length < 4) Array.Resize(ref key, 4);
        int last = words.Length - 1;
        uint z = words[last], sum = 0;
        unchecked {
            for (int rounds = 6 + 52 / words.Length; rounds > 0; rounds--) {
                sum += 0x9e3779b9;
                int e = (int)((sum >> 2) & 3);
                for (int p = 0; p <= last; p++) {
                    uint y = words[p == last ? 0 : p + 1];
                    uint mix = (z >> 5) ^ (y << 2);
                    mix += (y >> 3) ^ (z << 4) ^ (sum ^ y);
                    mix += key[(p & 3) ^ e] ^ z;
                    z = words[p] += mix;
                }
            }
        }
        var bytes = new byte[words.Length * 4];
        Buffer.BlockCopy(words, 0, bytes, 0, bytes.Length);
        const string standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const string custom = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA";
        var result = new StringBuilder("{SRBX1}");
        foreach (char c in Convert.ToBase64String(bytes)) result.Append(c == '=' ? c : custom[standard.IndexOf(c)]);
        return result.ToString();
    }

    public static string PasswordDigest(string password, string token) {
        using (var hmac = new HMACMD5(Encoding.UTF8.GetBytes(token))) return Hex(hmac.ComputeHash(Encoding.UTF8.GetBytes(password)));
    }

    public static string Checksum(string value) {
        using (var sha = SHA1.Create()) return Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(value)));
    }

    static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
}
'@

function Get-PortalSettings([string]$Link) {
    $uri = $null
    if (-not [uri]::TryCreate($Link.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Fragment) {
        throw '请输入完整的 HTTP 或 HTTPS 校园网认证链接。'
    }
    $ids = @($uri.Query.TrimStart('?').Split('&') | Where-Object { $_ -match '^ac_id=[0-9]{1,8}$' })
    if ($ids.Count -ne 1) { throw '认证链接需要包含一个数字 ac_id，例如 ?ac_id=20。' }
    $secure = [UriBuilder]::new($uri)
    if ($uri.Scheme -eq 'http') { $secure.Scheme = 'https'; $secure.Port = -1 }
    [pscustomobject]@{
        Link = $uri.AbsoluteUri
        SecurePage = $secure.Uri.AbsoluteUri
        SecureOrigin = $secure.Uri.GetLeftPart([UriPartial]::Authority)
        ReadOnlyOrigin = $uri.GetLeftPart([UriPartial]::Authority)
        AcId = $ids[0].Substring(6)
    }
}

function ConvertFrom-PortalResponse([string]$Body) {
    if ($Body.Trim() -match '(?s)^campusConnect\s*\((.*)\)\s*;?$') { $Body = $Matches[1] }
    ConvertFrom-Json -InputObject $Body -ErrorAction Stop
}

function Get-PortalState([string]$Body) {
    $Body = $Body.Trim()
    if ($Body -in @('not_online', 'not_online_error')) { return 'offline' }
    try {
        $result = ConvertFrom-PortalResponse $Body
        if ($result.error -in @('not_online','not_online_error') -or $result.res -eq 'not_online_error') { return 'offline' }
        if ($result.error -eq 'ok' -and $result.user_name -and $result.online_ip) { return 'online' }
    } catch {}
    $fields = $Body.Split(',')
    if ($fields.Count -ge 10 -and $fields[0] -and $fields[1] -match '^\d+$' -and $fields[8] -match '^\d+\.\d+\.\d+\.\d+$') { return 'online' }
    return 'unknown'
}

function New-LoginQuery($Credential, [string]$Ip, [string]$AcId, [string]$Token) {
    $user = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password
    $json = [ordered]@{ username=$user; password=$password; ip=$Ip; acid=$AcId; enc_ver='srun_bx1' } | ConvertTo-Json -Compress
    $info = [CampusSrun]::Encode($json, $Token)
    $digest = [CampusSrun]::PasswordDigest($password, $Token)
    $sum = (($user, $digest, $AcId, $Ip, '200', '1', $info) | ForEach-Object { $Token + $_ }) -join ''
    @{
        action='login'; username=$user; password='{MD5}'+$digest; ip=$Ip; ac_id=$AcId; info=$info
        chksum=[CampusSrun]::Checksum($sum); n='200'; type='1'; double_stack='0'; os='Windows'; name='Windows'
    }
}
