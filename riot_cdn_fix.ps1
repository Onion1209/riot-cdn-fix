# Riot 下載節點切換：測出最快的 Riot CDN 節點，寫進 hosts；更新完用 -Remove 還原
#   riot_cdn_fix.ps1            測速 + 套用最快節點（需系統管理員）
#   riot_cdn_fix.ps1 -TestOnly  只測速，不改 hosts（不需系統管理員）
#   riot_cdn_fix.ps1 -Remove    移除本腳本寫入的 hosts 設定
param([switch]$TestOnly, [switch]$Remove)

$ErrorActionPreference = 'Stop'
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$Domains   = @('lol.secure.dyn.riotcdn.net', 'teamfighttactics.secure.dyn.riotcdn.net')
# 遊戲檔實際從 bundles_url（X.dyn.riotcdn.net，沒有 secure）下載，要一起釘到同一個節點，否則真正的下載還是走慢的 CloudFront
function Get-Aliases($d) { @($d, ($d -replace '\.secure\.dyn\.', '.dyn.')) | Select-Object -Unique }
$AllNames  = $Domains | ForEach-Object { Get-Aliases $_ }
$Begin     = '# RIOT-CDN-FIX BEGIN'
$End       = '# RIOT-CDN-FIX END'
# 曾經測到很快的節點，最先測；上次選中的節點也會記在 last_best.txt 一起先測
$KnownIps  = @('175.99.116.58', '175.99.116.41')
$LastBestFile = Join-Path $PSScriptRoot 'last_best.txt'
# 測到這個速度就直接採用，不再測其他節點
$GoodEnoughMBs = 1.5
$DnsList   = @('8.8.8.8', '1.1.1.1', '168.95.1.1', '9.9.9.9', '101.101.101.101')

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 移除本腳本的區塊，以及任何手動加過的 Riot 網域行
function Get-CleanHosts {
    $lines = Get-Content $HostsFile -Encoding UTF8
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -eq $Begin) { $skip = $true; continue }
        if ($l -eq $End)   { $skip = $false; continue }
        if ($skip) { continue }
        if ($AllNames | Where-Object { $l -match "^\s*[\d.]+\s+$([regex]::Escape($_))\s*$" }) { continue }
        $out.Add($l)
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    # 逗號避免 PowerShell 把 List 拆成固定大小的陣列（否則之後 .Add 會失敗）
    return ,$out
}

function Write-Hosts($lines) {
    $enc = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($HostsFile, (($lines -join "`r`n") + "`r`n"), $enc)
    ipconfig /flushdns | Out-Null
}

# 測速檔：用真的遊戲檔 bundle，在 bundle 網域（X.dyn.riotcdn.net）上測
# manifest 幾乎都常駐節點快取，拿它測每個節點都很快，看不出真正下載會走多慢
# bundle 清單從本機已安裝版本的 manifest 讀（需要 Python + zstd，見 rman_bundles.py）
# 每次隨機挑一個 bundle，所有節點測同一個；避免一直測同一個已被自己測熱的 bundle
$BundleHelper = Join-Path $PSScriptRoot 'rman_bundles.py'
$TestBytes = 8MB

function Get-ManifestFile($domain) {
    $product = ($domain -split '\.')[0] -replace '^lol$', 'league_of_legends'
    $f = "$env:ProgramData\Riot Games\Metadata\$product.live\$product.live.manifest"
    if (Test-Path $f) { return $f } else { return $null }
}

# RMAN 檔頭第 16 byte 起的 8 bytes（little-endian）就是 manifest ID
function Get-ManifestPath($file) {
    $bytes = New-Object byte[] 24
    $s = [IO.File]::OpenRead($file); [void]$s.Read($bytes, 0, 24); $s.Close()
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'RMAN') { return $null }
    $id = [BitConverter]::ToUInt64($bytes, 16).ToString('X16')
    return "/channels/public/releases/$id.manifest"
}

# 回傳 @{ Host; Path; Kind }；拿不到 bundle 就退回用 manifest（並標示 Kind = manifest）
function Get-TestTarget($domain) {
    $file = Get-ManifestFile $domain
    if (-not $file) { return $null }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py -and (Test-Path $BundleHelper)) {
        $lines = & $py.Source -I $BundleHelper $file 50 2>$null
        if ($LASTEXITCODE -eq 0 -and $lines) {
            $id = (($lines | Get-Random) -split ' ')[0]
            return @{ Host = ($domain -replace '\.secure\.dyn\.', '.dyn.'); Path = "/channels/public/bundles/$id.bundle"; Kind = 'bundle' }
        }
    }
    $path = Get-ManifestPath $file
    if (-not $path) { return $null }
    return @{ Host = $domain; Path = $path; Kind = 'manifest' }
}

# 回傳兩組：先測的快節點，和 DNS 查到的其他節點
function Get-CandidateIps($domain) {
    $first = New-Object System.Collections.Generic.List[string]
    if (Test-Path $LastBestFile) { Get-Content $LastBestFile | Where-Object { $_ -match '^[\d.]+$' } | ForEach-Object { $first.Add($_) } }
    $KnownIps | Where-Object { $first -notcontains $_ } | ForEach-Object { $first.Add($_) }
    $ips = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in $DnsList) {
        try {
            Resolve-DnsName $domain -Server $d -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } | ForEach-Object { [void]$ips.Add($_.IPAddress) }
        } catch {}
    }
    # 其他 Riot 網域可能被分到不同節點（快的那台就是從 valorant 網域找到的）
    foreach ($other in @('valorant.secure.dyn.riotcdn.net', 'riot-client.secure.dyn.riotcdn.net')) {
        try {
            Resolve-DnsName $other -Type A -DnsOnly -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } | ForEach-Object { [void]$ips.Add($_.IPAddress) }
        } catch {}
    }
    return @($first) + @($ips | Where-Object { $first -notcontains $_ })
}

# 用 curl --resolve 強制連到該 IP；憑證驗證失敗或回應不對一律淘汰
# 只抓前 8MB（range 請求，回 206）；慢節點最多等 8 秒就放棄，用已下載的量算速度
# 兩個網域都會釘到同一個 IP，所以 manifest 網域也要能連（只抓 1 byte 確認憑證和回應）
function Measure-Ip($domain, $ip, $target, $manifestPath) {
    if ($target.Kind -eq 'bundle' -and $manifestPath) {
        $c = & curl.exe -s -o NUL -r 0-0 --resolve "${domain}:443:$ip" -w '%{http_code}' --max-time 5 "https://$domain$manifestPath" 2>$null
        if ("$c" -notin @('200', '206')) { return 0 }
    }
    $h = $target.Host
    $r = & curl.exe -s -o NUL -r "0-$($TestBytes - 1)" --resolve "${h}:443:$ip" -w '%{http_code} %{size_download} %{time_total}' --max-time 8 "https://$h$($target.Path)" 2>$null
    $code, $size, $time = "$r" -split ' '
    if ($code -notin @('200', '206') -or [double]$time -le 0) { return 0 }
    return [double]$size / [double]$time / 1MB
}

if ($Remove) {
    if (-not (Test-Admin)) { Write-Host '需要系統管理員權限，請用「下載加速器.bat」執行。' -ForegroundColor Red; exit 1 }
    Write-Hosts (Get-CleanHosts)
    Write-Host '已移除 Riot 節點設定，恢復正常 DNS。' -ForegroundColor Green
    exit 0
}

if (-not $TestOnly -and -not (Test-Admin)) {
    Write-Host '需要系統管理員權限，請用「下載加速器.bat」執行。' -ForegroundColor Red; exit 1
}

$best = @{}
foreach ($domain in $Domains) {
    Write-Host "== $domain"
    $target = Get-TestTarget $domain
    if (-not $target) { Write-Host "  找不到測速檔（先開一次 Riot Client 再跑），跳過`n" -ForegroundColor Yellow; continue }
    $manifestPath = Get-ManifestPath (Get-ManifestFile $domain)
    Write-Host "  測速檔：https://$($target.Host)$($target.Path)"
    if ($target.Kind -ne 'bundle') {
        Write-Host '  （讀不到 bundle 清單，退回用 manifest 測；manifest 常駐快取，速度會偏樂觀。要用 bundle 測請裝 Python 與 zstandard）' -ForegroundColor Yellow
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($ip in (Get-CandidateIps $domain)) {
        $mb = Measure-Ip $domain $ip $target $manifestPath
        Write-Host ("  {0,-16} {1}" -f $ip, $(if ($mb -gt 0) { '{0:N2} MB/s' -f $mb } else { '失敗/不可用' }))
        $results.Add([pscustomobject]@{ Ip = $ip; MBs = $mb })
        if ($mb -ge $GoodEnoughMBs) { Write-Host "  （已達 $GoodEnoughMBs MB/s，其他節點不測了）"; break }
    }
    $top = $results | Where-Object MBs -gt 0 | Sort-Object MBs -Descending | Select-Object -First 1
    if ($top) { $best[$domain] = $top; Write-Host ("  -> 最快：{0}（{1:N2} MB/s）`n" -f $top.Ip, $top.MBs) -ForegroundColor Cyan }
    else { Write-Host "  -> 全部失敗，這個網域不設定`n" -ForegroundColor Yellow }
}

if ($TestOnly) { Write-Host '只測速模式，hosts 沒有更動。'; exit 0 }
if ($best.Count -eq 0) { Write-Host '沒有可用節點，hosts 沒有更動。' -ForegroundColor Red; exit 1 }

$lines = Get-CleanHosts
$lines.Add('')
$lines.Add($Begin)
foreach ($d in $best.Keys) { foreach ($n in (Get-Aliases $d)) { $lines.Add("$($best[$d].Ip) $n") } }
$lines.Add($End)
Write-Hosts $lines
$best.Values | ForEach-Object { $_.Ip } | Select-Object -Unique | Set-Content $LastBestFile
Write-Host "`n目前 hosts 裡的 Riot 設定："
Get-Content $HostsFile | Where-Object { $_ -match 'riotcdn' } | ForEach-Object { Write-Host "  $_" }
Write-Host '已套用。正在更新的話，在 Riot Client 按「暫停」再「繼續」就會改走新節點。' -ForegroundColor Green
Write-Host '更新完記得執行「還原」，不然之後 Riot 換節點時更新會失敗。' -ForegroundColor Yellow
