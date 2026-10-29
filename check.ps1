# 電子車検証特設サイトのお知らせ一覧を確認し、新着を RSS フィード (_site/feed.xml) として出力する
# GitHub Actions (pwsh 7) と Windows PowerShell 5.1 の両方で動く
# 使い方: pwsh ./check.ps1 [-HtmlFile ローカルHTML(テスト用)]
param(
    [string]$HtmlFile,
    [string]$StateFile = (Join-Path $PSScriptRoot 'state.json'),
    [string]$OutDir    = (Join-Path $PSScriptRoot '_site'),
    [int]$FeedSize     = 30,
    # 配信確認用のテスト項目をフィードの先頭に1件加える（state には記録しない）
    [switch]$TestItem
)

$ErrorActionPreference = 'Stop'
$NewsUrl = 'https://www.denshishakensho-portal.mlit.go.jp/news'
$BaseUrl = 'https://www.denshishakensho-portal.mlit.go.jp'
$Utf8    = New-Object Text.UTF8Encoding $false

if ($HtmlFile) {
    $html = [IO.File]::ReadAllText($HtmlFile, $Utf8)
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res  = Invoke-WebRequest -Uri $NewsUrl -UseBasicParsing -TimeoutSec 60
    $html = $Utf8.GetString($res.RawContentStream.ToArray())
}

function Clean([string]$s) {
    $s = [regex]::Replace($s, '<[^>]+>', ' ')
    $s = [Net.WebUtility]::HtmlDecode($s)
    return ([regex]::Replace($s, '\s+', ' ')).Trim()
}

$items = @()
foreach ($m in [regex]::Matches($html, '(?s)<li class="c-news__list">(.*?)</li>')) {
    $block = $m.Groups[1].Value
    $date  = Clean ([regex]::Match($block, '(?s)<div class="c-news__date">(.*?)</div>').Groups[1].Value)
    $raw   = [regex]::Match($block, '(?s)<div class="c-news__text">(.*?)</div>').Groups[1].Value
    $text  = Clean $raw
    $href  = [regex]::Match($raw, 'href="([^"]+)"').Groups[1].Value
    if ($href.StartsWith('/')) { $href = $BaseUrl + $href }
    if (-not $href) { $href = $NewsUrl }
    $items += [pscustomobject]@{
        key        = "$date|$text"
        date       = $date
        title      = $text
        link       = $href
        html       = $raw.Trim().Replace('href="/', "href=`"$BaseUrl/")
        detectedAt = $null
    }
}
if ($items.Count -eq 0) { throw 'お知らせを1件も抽出できませんでした。ページ構造が変わった可能性があります。' }

# state.json: 既知のお知らせ。detectedAt は新着として検知した時刻 (UTC, 初期登録分は null)
$state = @()
if (Test-Path $StateFile) {
    $state = @([IO.File]::ReadAllText($StateFile, $Utf8) | ConvertFrom-Json | ForEach-Object { $_ })
}
function ToUtc($v) {
    if ($v -is [DateTime]) { return $v.ToUniversalTime() }
    return [DateTime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
}
$known = @{}
foreach ($s in $state) {
    $known[$s.key] = $true
    # pwsh 7 の ConvertFrom-Json は日時文字列を DateTime にするので文字列に戻す
    if ($s.detectedAt) { $s.detectedAt = (ToUtc $s.detectedAt).ToString('yyyy-MM-ddTHH:mm:ssZ') }
}
$firstRun = $state.Count -eq 0

$new = @($items | Where-Object { -not $known.ContainsKey($_.key) })
if ($firstRun) {
    $state = $items
    Write-Output "初回実行: $($items.Count) 件を既知として記録しました（フィード項目なし）。"
} elseif ($new.Count -eq 0) {
    Write-Output "新着なし（掲載 $($items.Count) 件）。"
} else {
    # RSS トリガーは pubDate が前回より大きい項目だけを新着とみなすため、検知時刻を厳密に増加させる
    $t = [DateTime]::UtcNow
    $last = @($state | Where-Object { $_.detectedAt } | ForEach-Object { ToUtc $_.detectedAt } | Sort-Object)
    if ($last.Count -gt 0 -and $t -le $last[-1]) { $t = $last[-1] }
    # ページは新しい順なので、古いものから順に時刻を振る
    for ($i = $new.Count - 1; $i -ge 0; $i--) {
        $t = $t.AddSeconds(1)
        $new[$i].detectedAt = $t.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $state = $new + $state
    Write-Output "新着 $($new.Count) 件:"
    $new | ForEach-Object { Write-Output "  $($_.date) $($_.title)" }
}

[IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject @($state) -Depth 3), $Utf8)

function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }
$sha = [Security.Cryptography.SHA1]::Create()
$feedItems = @($state | Where-Object { $_.detectedAt } |
    Sort-Object { ToUtc $_.detectedAt } -Descending |
    Select-Object -First $FeedSize)
if ($TestItem) {
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $test = [pscustomobject]@{
        key = "test|$now"; date = 'テスト'; title = '【テスト】新着通知の配信確認'; link = $NewsUrl
        html = 'これは配信確認用のテストです。実際のお知らせではありません。'; detectedAt = $now
    }
    $feedItems = @($test) + $feedItems
    Write-Output 'テスト項目をフィードに追加しました。'
}
$xmlItems = foreach ($it in $feedItems) {
    $guid = -join ($sha.ComputeHash($Utf8.GetBytes($it.key)) | ForEach-Object { $_.ToString('x2') })
    $pub  = (ToUtc $it.detectedAt).ToString('r')
    $desc = ("掲載日: $($it.date)<br>$($it.html)").Replace(']]>', ']]&gt;')
@"
    <item>
      <title>$(Esc $it.title)</title>
      <link>$(Esc $it.link)</link>
      <guid isPermaLink="false">$guid</guid>
      <pubDate>$pub</pubDate>
      <description><![CDATA[$desc]]></description>
    </item>
"@
}
$xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>電子車検証特設サイト お知らせ（新着検知）</title>
    <link>$NewsUrl</link>
    <description>電子車検証特設サイトのお知らせ一覧から新着を検知したもの（非公式）</description>
    <lastBuildDate>$([DateTime]::UtcNow.ToString('r'))</lastBuildDate>
$($xmlItems -join "`n")
  </channel>
</rss>
"@
New-Item -ItemType Directory -Force $OutDir | Out-Null
[IO.File]::WriteAllText((Join-Path $OutDir 'feed.xml'), $xml, $Utf8)
