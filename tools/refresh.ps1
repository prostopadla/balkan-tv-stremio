# Weekly refresh of the channel list: Kodi playlist (kodi.m3u) + Stremio addon files (catalog/, meta/, stream/).
# Source: the open iptv-org catalog. Runs on GitHub Actions (pwsh, US servers) and on Windows PowerShell 5.1.
#
# Many Balkan streams are geo-blocked outside the region, so a check from a US server can't be trusted to
# say a channel is dead. Rules:
#   - a channel already in our list stays, with iptv-org's current address, unless that address is truly dead
#     (404/410, domain does not exist, connection refused);
#   - a channel iptv-org no longer lists stays only if it still answers from here;
#   - a new Balkan channel is added only if it answers; new English channels only with -AddNewEnglish
#     (then only formats Stremio's player can play);
#   - if a list would shrink by more than 30 %, nothing is written and the script fails (GitHub emails the owner).
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [double]$MaxDrop = 0.30,
    [switch]$AddNewEnglish
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$enc = New-Object Text.UTF8Encoding $false
$src = 'https://iptv-org.github.io/iptv'
$countries = [ordered]@{ 'rs' = 'Srbija'; 'hr' = 'Hrvatska'; 'ba' = 'Bosna i Hercegovina'; 'me' = 'Crna Gora'; 'si' = 'Slovenija'; 'mk' = 'Severna Makedonija' }
$enGenres = [ordered]@{
    'News'            = 'News', 'Business', 'Weather'
    'Movies & Series' = 'Movies', 'Series', 'Classic'
    'Sports'          = 'Sports', 'Outdoor', 'Auto'
    'Documentary'     = 'Documentary', 'Science', 'Education', 'Culture', 'Travel'
    'Kids'            = 'Kids', 'Animation', 'Family'
    'Music'           = 'Music', 'Relax'
}
$englishGenres = @($enGenres.Keys) + 'Entertainment'
# English channels: European and big international broadcasters only, no religious/shopping/parliament
$europe = 'uk', 'ie', 'de', 'fr', 'nl', 'be', 'lu', 'es', 'pt', 'it', 'mt', 'cy', 'gr', 'pl', 'cz', 'sk', 'hu', 'ro', 'bg', 'si', 'hr', 'rs', 'ba', 'me', 'mk', 'al', 'xk', 'at', 'ch', 'se', 'no', 'dk', 'fi', 'is', 'ee', 'lv', 'lt', 'ua', 'md'
$global = 'qa', 'tr', 'cn', 'jp', 'sg', 'kr', 'ae', 'il', 'hk', 'int'
$badCat = 'Religious', 'Shop', 'Legislative'
$top = 'BBC|Sky News|Euronews|DW|France 24|Al Jazeera|CNA|NHK|TRT World|CGTN|Arirang|i24|Bloomberg|Reuters'

function Get-Text([string]$url) {
    $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8; $wc.Headers['User-Agent'] = 'balkan-tv-refresh'
    try { return $wc.DownloadString($url) } finally { $wc.Dispose() }
}

function Read-M3u([string]$text) {
    $l = $text -split "`r?`n"
    for ($i = 0; $i -lt $l.Count; $i++) {
        if ($l[$i] -notlike '#EXTINF*') { continue }
        $inf = $l[$i]; $extra = @(); $j = $i + 1
        while ($j -lt $l.Count -and ($l[$j] -like '#*' -or -not $l[$j].Trim())) { if ($l[$j].Trim()) { $extra += $l[$j] }; $j++ }
        if ($j -ge $l.Count) { break }
        $ua = $null; $ref = $null
        foreach ($e in @($inf) + $extra) {
            if ($e -match 'http-user-agent=("?)([^"]+)\1') { $ua = $matches[2].Trim() }
            if ($e -match 'http-referrer=("?)([^"]+)\1') { $ref = $matches[2].Trim() }
        }
        $name = if ($inf -match '"\s*,(.*)$') { $matches[1].Trim() } else { ($inf -replace '^.*?,', '').Trim() }
        $clean = ($name -replace '\s*\(\d+p\)', '' -replace '\s*\((Serbia|Croatia|Bosnia and Herzegovina|Montenegro|Slovenia|North Macedonia)\)', '' -replace '\s*\[[^\]]*\]', '').Trim()
        $tvgid = if ($inf -match 'tvg-id="([^"]*)"') { $matches[1] } else { '' }
        [pscustomobject]@{
            inf = $inf; extra = $extra; url = $l[$j].Trim(); ua = $ua; ref = $ref; name = $name; clean = $clean; tvgid = $tvgid
            logo = $(if ($inf -match 'tvg-logo="([^"]*)"') { $matches[1] } else { '' })
            grp = $(if ($inf -match 'group-title="([^"]*)"') { $matches[1] } else { '' })
            key = ($tvgid + '|' + $clean).ToLower(); cat = ''; genre = ''
        }
        $i = $j
    }
}

function EnGenre([string]$grp) {
    foreach ($g in ($grp -split ';')) { foreach ($k in $enGenres.Keys) { if ($enGenres[$k] -contains $g) { return $k } } }
    return 'Entertainment'
}

# --- what we publish now (state = our own kodi.m3u)
$curFile = Join-Path $Root 'kodi.m3u'
$cur = @{}
if (Test-Path $curFile) {
    foreach ($c in Read-M3u ([IO.File]::ReadAllText($curFile, [Text.Encoding]::UTF8))) {
        if ($c.grp -like 'English - *') { $c.cat = 'english'; $c.genre = $c.grp.Substring(10) } else { $c.cat = 'balkan'; $c.genre = $c.grp }
        $cur[$c.cat + '|' + $c.key] = $c
    }
}
Write-Host "published now: $($cur.Count)"

# --- fresh iptv-org lists
$fresh = New-Object Collections.Generic.List[object]
$seen = New-Object Collections.Generic.HashSet[string]
foreach ($cc in $countries.Keys) {
    foreach ($c in Read-M3u (Get-Text "$src/countries/$cc.m3u")) {
        if (-not $seen.Add($c.url)) { continue }
        $c.cat = 'balkan'; $c.genre = $countries[$cc]; $fresh.Add($c)
    }
}
foreach ($c in Read-M3u (Get-Text "$src/languages/eng.m3u")) {
    $cc = if ($c.tvgid -match '\.([a-z]{2,3})(@|$)') { $matches[1] } else { '' }
    if (($europe + $global) -notcontains $cc) { continue }
    if (@($c.grp -split ';' | Where-Object { $badCat -contains $_ }).Count) { continue }
    if ($c.inf -match 'Geo-blocked') { continue }
    if (-not $seen.Add($c.url)) { continue }
    $c.cat = 'english'; $c.genre = EnGenre $c.grp; $fresh.Add($c)
}
Write-Host "iptv-org offers: $($fresh.Count)"

# --- check every address once, in parallel
$freshKeys = New-Object Collections.Generic.HashSet[string]
foreach ($c in $fresh) { [void]$freshKeys.Add($c.cat + '|' + $c.key) }
$gone = @($cur.Keys | Where-Object { -not $freshKeys.Contains($_) } | ForEach-Object { $cur[$_] })
$toCheck = @{}
foreach ($c in ([object[]]$fresh.ToArray() + [object[]]$gone)) { if (-not $toCheck.ContainsKey($c.url)) { $toCheck[$c.url] = $c } }
$probe = {
    param($u, $ua, $ref)
    # ok:<type> | hard (really dead) | soft (no answer from here: geo-block, timeout, 403, 5xx...)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = [Net.HttpWebRequest]::Create($u); $r.Timeout = 10000; $r.ReadWriteTimeout = 10000
        $r.UserAgent = $(if ($ua) { $ua } else { 'Mozilla/5.0' }); if ($ref) { $r.Referer = $ref }
        $resp = $r.GetResponse(); $s = $resp.GetResponseStream(); $b = New-Object byte[] 2048; $n = $s.Read($b, 0, 2048); $resp.Close()
        if ($n -le 0) { return 'soft' }
        $txt = [Text.Encoding]::ASCII.GetString($b, 0, $n); $path = ([uri]$u).AbsolutePath.ToLower()
        if ($txt.StartsWith('#EXTM3U')) { if ($path -match '\.m3u8?$') { return 'ok:hls' } else { return 'ok:hls-noext' } }
        if ($b[0] -eq 0x47) { return 'ok:ts' }
        if ($path -match '\.(mpd|mp4|mkv)$') { return 'ok:file' }
        return 'ok:other'
    } catch {
        $e = $_.Exception; while ($e.InnerException -and -not ($e -is [Net.WebException])) { $e = $e.InnerException }
        if ($e -is [Net.WebException]) {
            if ($e.Response -and [int]$e.Response.StatusCode -in 404, 410) { return 'hard' }
            if ($e.Status -eq [Net.WebExceptionStatus]::NameResolutionFailure) { return 'hard' }
        }
        $all = "$($_.Exception)"
        if ($all -match 'No such host|Name or service not known|nodename nor servname|Connection refused|actively refused') { return 'hard' }
        return 'soft'
    }
}
$pool = [RunspaceFactory]::CreateRunspacePool(1, 48); $pool.Open()
$tasks = foreach ($c in $toCheck.Values) {
    $ps = [PowerShell]::Create().AddScript($probe).AddArgument($c.url).AddArgument($c.ua).AddArgument($c.ref); $ps.RunspacePool = $pool
    [pscustomobject]@{ url = $c.url; ps = $ps; h = $ps.BeginInvoke() }
}
$res = @{}
foreach ($t in $tasks) { $res[$t.url] = [string]($t.ps.EndInvoke($t.h) | Select-Object -Last 1); $t.ps.Dispose() }
$pool.Close()
Write-Host ('checked ' + $res.Count + ': ' + (($res.Values | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '))

function Playable($c, $r) { if ($c.cat -eq 'english') { return $r -in 'ok:hls', 'ok:ts', 'ok:file' } return $r -like 'ok:*' }

# --- decide
$keep = New-Object Collections.Generic.List[object]; $added = @(); $removed = @()
$urls = New-Object Collections.Generic.HashSet[string]
foreach ($c in $fresh) {
    $r = $res[$c.url]; $known = $cur.ContainsKey($c.cat + '|' + $c.key)
    # New English channels are not added automatically: a US server can reach many regional feeds (DK/NO/SE copies...)
    # that are blocked in Serbia. Add them by hand with -AddNewEnglish after a check from Serbia.
    $ok = if ($known) { $r -ne 'hard' } elseif ($c.cat -eq 'english' -and -not $AddNewEnglish) { $false } else { Playable $c $r }
    if ($ok -and $urls.Add($c.url)) { $keep.Add($c); if (-not $known) { $added += "$($c.cat): $($c.clean)" } }
    elseif ($known -and -not $ok) { $removed += "$($c.cat): $($c.clean) (dead address)" }
}
foreach ($c in $gone) {
    if ((Playable $c $res[$c.url]) -and $urls.Add($c.url)) { $keep.Add($c) } else { $removed += "$($c.cat): $($c.clean) (gone from iptv-org)" }
}

# --- safety: never publish a list that collapsed (iptv-org outage, network trouble on the runner...)
foreach ($cat in 'balkan', 'english') {
    $was = @($cur.Values | Where-Object { $_.cat -eq $cat }).Count
    $now = @($keep | Where-Object { $_.cat -eq $cat }).Count
    Write-Host "${cat}: $was -> $now"
    if ($was -gt 0 -and $now -lt [math]::Floor($was * (1 - $MaxDrop))) { throw "$cat list would shrink from $was to $now channels: not publishing" }
}

# --- Kodi playlist: Balkan by country, then English by genre (well-known news brands first)
$order = @($countries.Values) + @($englishGenres | ForEach-Object { "English - $_" })
$rows = foreach ($c in $keep) {
    $g = if ($c.cat -eq 'english') { "English - $($c.genre)" } else { $c.genre }
    [pscustomobject]@{ c = $c; g = $g; o1 = [array]::IndexOf($order, $g); o2 = $(if ($c.cat -eq 'english' -and $c.name -match $top) { 0 } else { 1 }) }
}
$rows = @($rows | Sort-Object o1, o2, @{ e = { $_.c.clean } }, @{ e = { $_.c.url } })
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('#EXTM3U')
foreach ($r in $rows) {
    $inf = if ($r.c.inf -match 'group-title="') { $r.c.inf -replace 'group-title="[^"]*"', "group-title=`"$($r.g)`"" } else { $r.c.inf -replace '^(#EXTINF:-?\d+)', "`$1 group-title=`"$($r.g)`"" }
    [void]$sb.AppendLine($inf); foreach ($e in $r.c.extra) { [void]$sb.AppendLine($e) }; [void]$sb.AppendLine($r.c.url)
}
[IO.File]::WriteAllText($curFile, $sb.ToString().Replace("`r`n", "`n"), $enc)

# --- Stremio addon (static files). Ids come from channel names, so they stay the same between runs.
function W($path, $obj) {
    $full = Join-Path $Root $path
    New-Item -ItemType Directory -Force (Split-Path $full) | Out-Null
    [IO.File]::WriteAllText($full, ($obj | ConvertTo-Json -Depth 10 -Compress), $enc)
}
foreach ($d in 'catalog', 'meta', 'stream') { $p = Join-Path $Root $d; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }
$ids = New-Object Collections.Generic.HashSet[string]
$chs = foreach ($r in $rows) {
    $c = $r.c
    $slug = (($c.clean.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
    $pre = if ($c.cat -eq 'english') { 'en-' } else { '' }
    $id = "balkantv_$pre$slug"; $n = 2
    while (-not $ids.Add($id)) { $id = "balkantv_$pre$slug-$n"; $n++ }
    [pscustomobject]@{ id = $id; c = $c }
}
function Preview($x) {
    $p = [ordered]@{ id = $x.id; type = 'tv'; name = $x.c.clean; posterShape = 'square' }
    if ($x.c.logo) { $p.poster = $x.c.logo; $p.logo = $x.c.logo }
    if ($x.c.genre) { $p.genres = @($x.c.genre) }
    return $p
}
foreach ($cat in @(@{ id = 'balkan'; genres = @($countries.Values) }, @{ id = 'english'; genres = $englishGenres })) {
    $sel = @($chs | Where-Object { $_.c.cat -eq $cat.id })
    W "catalog/tv/$($cat.id).json" @{ metas = @($sel | ForEach-Object { Preview $_ }) }
    foreach ($g in $cat.genres) { W "catalog/tv/$($cat.id)/genre=$g.json" @{ metas = @($sel | Where-Object { $_.c.genre -eq $g } | ForEach-Object { Preview $_ }) } }
}
foreach ($x in $chs) {
    $m = Preview $x
    $m.description = (@($x.c.genre, $(if ($x.c.name -match 'Not 24/7') { 'not 24/7' })) | Where-Object { $_ }) -join ' - '
    W "meta/tv/$($x.id).json" @{ meta = $m }
    $s = [ordered]@{ url = $x.c.url; name = $(if ($x.c.cat -eq 'balkan') { 'Balkan TV' } else { 'English TV' }); title = $x.c.clean; behaviorHints = [ordered]@{ notWebReady = $true } }
    $h = [ordered]@{}; if ($x.c.ua) { $h['User-Agent'] = $x.c.ua }; if ($x.c.ref) { $h['Referer'] = $x.c.ref }
    # Stremio's local proxy (used whenever proxyHeaders are set) rejects http:// sources, so headers only for https
    if ($h.Count -and $x.c.url -like 'https:*') { $s.behaviorHints.proxyHeaders = @{ request = $h } }
    W "stream/tv/$($x.id).json" @{ streams = @($s) }
}

# --- report (also shown on the GitHub Actions run page)
$rep = @("### Channel refresh $(Get-Date -Format 'yyyy-MM-dd')", '',
    "Balkan: $(@($keep | Where-Object { $_.cat -eq 'balkan' }).Count), English: $(@($keep | Where-Object { $_.cat -eq 'english' }).Count)", '',
    "Added ($($added.Count)):") + ($added | Sort-Object | ForEach-Object { "- $_" }) + @('', "Removed ($($removed.Count)):") + ($removed | Sort-Object | ForEach-Object { "- $_" })
$rep | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) { $rep -join "`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
