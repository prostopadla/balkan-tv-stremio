# Builds custom.channels.xml for the iptv-org/epg grabber: one guide source per channel of kodi.m3u.
# Usage (GitHub Actions, see .github/workflows/epg.yml): ./tools/epg-channels.ps1 -Sites epg/sites -Out custom.channels.xml
param([string]$Sites = 'epg/sites', [string]$Out = 'custom.channels.xml', [string]$M3u = 'kodi.m3u')
$ErrorActionPreference = 'Stop'

# tvg-id -> group (Srbija, Hrvatska, ..., English - News ...)
$want = [ordered]@{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $M3u))) {
    if ($l -match '^#EXTINF' -and $l -match 'tvg-id="([^"]+)"') {
        $g = if ($l -match 'group-title="([^"]+)"') { $matches[1] } else { '' }
        $id = ($l | Select-String 'tvg-id="([^"]+)"').Matches[0].Groups[1].Value
        if (-not $want.Contains($id)) { $want[$id] = $g }
    }
}

# Sites known to answer from GitHub runners and to cover the region well get tried first.
$prefer = 'tvprofil.com', 'mts.rs', 'mojmaxtv.hrvatskitelekom.hr', 'epg.telemach.ba', 'mtel.ba', 'maxtvgo.mk',
    'tvarenasport.com', 'tvarenasport.hr', 'aljazeera.com', 'arirang.com', 'dw.com', 'france24.com', 'bbc.com'
$rank = @{}; for ($i = 0; $i -lt $prefer.Count; $i++) { $rank[$prefer[$i]] = $i }

$exact = @{}; $base = @{}
foreach ($f in Get-ChildItem $Sites -Recurse -Filter *.channels.xml) {
    foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
        if ($l -notmatch '<channel\s' -or $l -notmatch 'xmltv_id="([^"]+)"') { continue }
        $x = $matches[1]
        $site = if ($l -match 'site="([^"]+)"') { $matches[1] } else { continue }
        $lang = if ($l -match 'lang="([^"]+)"') { $matches[1] } else { '' }
        $c = [pscustomobject]@{ line = $l.Trim(); site = $site; lang = $lang; x = $x }
        if (-not $exact.ContainsKey($x)) { $exact[$x] = New-Object Collections.ArrayList }
        [void]$exact[$x].Add($c)
        $b = $x -replace '@.*$', ''
        if (-not $base.ContainsKey($b)) { $base[$b] = New-Object Collections.ArrayList }
        [void]$base[$b].Add($c)
    }
}

function Pick($cands, [string]$group) {
    $local = if ($group -like 'English*') { 'en' } else { '' }
    $cands | Sort-Object @{ e = { if ($rank.ContainsKey($_.site)) { $rank[$_.site] } else { 100 } } },
                        @{ e = { if ($local -and $_.lang -eq $local) { 0 } else { 1 } } } | Select-Object -First 1
}

$lines = New-Object Collections.Generic.List[string]
$lines.Add('<?xml version="1.0" encoding="UTF-8"?>'); $lines.Add('<channels>')
$hit = 0
foreach ($id in $want.Keys) {
    $c = $null
    if ($exact.ContainsKey($id)) { $c = Pick $exact[$id] $want[$id] }
    elseif ($base.ContainsKey(($id -replace '@.*$', ''))) { $c = Pick $base[($id -replace '@.*$', '')] $want[$id] }
    if (-not $c) { continue }
    # keep our exact tvg-id so Kodi matches the guide to the channel
    $lines.Add('  ' + ($c.line -replace 'xmltv_id="[^"]+"', ('xmltv_id="' + $id + '"')))
    $hit++
}
$lines.Add('</channels>')
[IO.File]::WriteAllLines([IO.Path]::Combine((Get-Location).Path, $Out), $lines, (New-Object Text.UTF8Encoding $false))
Write-Host "channels with a guide source: $hit / $($want.Count)"
$lines | Select-Object -Skip 2 | ForEach-Object { if ($_ -match 'site="([^"]+)"') { $matches[1] } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object { Write-Host ('  {0,4}  {1}' -f $_.Count, $_.Name) }
