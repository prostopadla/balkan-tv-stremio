# Adds programmes from epgshare01's prebuilt country guides for channels the iptv-org grabber left empty.
# Usage (see .github/workflows/epg.yml): ./tools/epg-extra.ps1 -Guide guide.xml -Map tools/epg-extra.txt
param([string]$Guide = 'guide.xml', [string]$Map = 'tools/epg-extra.txt', [int]$Days = 4)
$ErrorActionPreference = 'Stop'
$base = 'https://epgshare01.online/epgshare01/epg_ripper_{0}.xml.gz'

$xml = [IO.File]::ReadAllText((Resolve-Path $Guide))
$have = @{}
foreach ($m in [regex]::Matches($xml, '<programme[^>]*channel="([^"]+)"')) { $have[$m.Groups[1].Value] = 1 }

# tvg-id -> (file, source id), only for channels still without a programme
$want = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Map))) {
    if ($l -match '^\s*#' -or $l -notmatch '^\s*(\S+)\s*=\s*(\S+)\s*\|\s*(.+?)\s*$') { continue }
    if ($have[$matches[1]]) { continue }
    $want[$matches[1]] = @($matches[2], $matches[3])
}
if (-not $want.Count) { Write-Host 'epg-extra: nothing missing'; exit 0 }

$limit = (Get-Date).ToUniversalTime().AddDays($Days).ToString('yyyyMMddHHmmss')
$add = New-Object Text.StringBuilder; $chan = New-Object Text.StringBuilder; $count = @{}
foreach ($file in ($want.Values | ForEach-Object { $_[0] } | Sort-Object -Unique)) {
    try {
        $tmp = [IO.Path]::GetTempFileName()
        Invoke-WebRequest ($base -f $file) -OutFile $tmp -TimeoutSec 180 -UseBasicParsing
        $in = [IO.File]::OpenRead($tmp); $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
        $rd = New-Object IO.StreamReader($gz); $src = $rd.ReadToEnd(); $rd.Close(); Remove-Item $tmp
    } catch { Write-Host "epg-extra: $file failed: $_"; continue }
    $byId = @{}
    foreach ($k in $want.Keys) { if ($want[$k][0] -eq $file) { $byId[$want[$k][1]] = $k } }
    foreach ($m in [regex]::Matches($src, '(?s)<programme\s[^>]*?start="(\d{14})[^"]*"[^>]*?channel="([^"]+)"[^>]*>.*?</programme>')) {
        $tvg = $byId[[Net.WebUtility]::HtmlDecode($m.Groups[2].Value)]
        if (-not $tvg -or $m.Groups[1].Value -gt $limit) { continue }
        $p = $m.Value -replace 'channel="[^"]+"', ('channel="' + [Security.SecurityElement]::Escape($tvg) + '"')
        [void]$add.Append('  ').Append($p).Append("`n")
        $count[$tvg] = 1 + [int]$count[$tvg]
    }
}
foreach ($tvg in $count.Keys) {
    if ($xml -notmatch ('<channel id="' + [regex]::Escape($tvg) + '"')) {
        [void]$chan.Append('  <channel id="' + [Security.SecurityElement]::Escape($tvg) + '"><display-name>' + [Security.SecurityElement]::Escape($tvg) + "</display-name></channel>`n")
    }
}
$i = $xml.LastIndexOf('</tv>')
if ($i -lt 0) { throw 'guide has no </tv>' }
# channels must come before programmes in XMLTV: put new ones after the last existing <channel>
$j = $xml.IndexOf('<programme')
if ($j -lt 0) { $j = $i }
$xml = $xml.Substring(0, $i) + $add.ToString() + $xml.Substring($i)
$xml = $xml.Substring(0, $j) + $chan.ToString() + $xml.Substring($j)
[IO.File]::WriteAllText((Resolve-Path $Guide), $xml, (New-Object Text.UTF8Encoding $false))
Write-Host "epg-extra: $($count.Count) / $($want.Count) channels filled, $(($count.Values | Measure-Object -Sum).Sum) programmes"
$want.Keys | Where-Object { -not $count[$_] } | ForEach-Object { Write-Host "  still empty: $_" }
