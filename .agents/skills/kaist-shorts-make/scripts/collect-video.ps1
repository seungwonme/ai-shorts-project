# 유튜브 주소에서 영상, 정보, 한국어 자막(대본)을 모읍니다 (PowerShell 5.1 / 7 겸용)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File collect-video.ps1 -Url "https://www.youtube.com/watch?v=..."
#
# 결과: 재료\<영상번호>\video.mp4, meta.json, transcript.txt (한국어 자막이 있을 때), 자막 원본(.vtt)
# 필요한 것: yt-dlp, Deno(유튜브 읽기용), FFmpeg. 파이썬은 쓰지 않습니다.
# 이 파일은 UTF-8 (BOM 포함)으로 저장합니다.
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$FFmpeg = "",
    [string]$YtDlp = "",
    [switch]$Force
)
. (Join-Path $PSScriptRoot "common.ps1")

if ($Url -notmatch '^https?://') { Fail "주소는 https:// 로 시작해야 합니다." }
$yt = Find-Tool "yt-dlp" $YtDlp
if (-not $yt) { Fail "yt-dlp를 찾지 못했습니다. setup-windows.bat을 먼저 실행해 주세요." }
$ff = Find-Tool "ffmpeg" $FFmpeg
if (-not $ff) { Fail "FFmpeg를 찾지 못했습니다. setup-windows.bat을 먼저 실행해 주세요." }
$ffdir = Split-Path -Parent $ff
$ROOT = Find-ProjectRoot

Say "영상 정보를 읽는 중..."
$ir = Invoke-Tool $yt @("--dump-single-json", "--no-playlist", "--no-warnings", $Url) $null
if ($ir.Code -ne 0) {
    $hint = ""
    if ($ir.Err -match "(?i)js runtime|javascript|deno") { $hint = "`n(유튜브를 읽으려면 Deno가 필요합니다. setup-windows.bat이 설치합니다.)" }
    Fail ("yt-dlp가 영상 정보를 읽지 못했습니다.`n" + (Tail $ir.Err 1200) + $hint)
}
$info = $ir.Out | ConvertFrom-Json
$id = [string]$info.id
# The folder name comes from the site's id: keep only safe characters so it stays inside 재료.
$folder = $id -replace '[^A-Za-z0-9_-]', '_'
if (-not $folder) { $folder = "video" }
$dir = Join-Path (Join-Path $ROOT "재료") $folder
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$video = Join-Path $dir "video.mp4"

if ((Test-Path -LiteralPath $video) -and -not $Force) { Say "이미 받아 둔 영상이 있어 다시 받지 않습니다. (다시 받으려면 -Force)" }
else {
    Say "영상을 내려받는 중... (1080p 이하)"
    $dl = Invoke-Tool $yt @("--no-playlist", "--no-warnings", "--ffmpeg-location", $ffdir, "-f", "bv*[height<=1080][vcodec^=avc1]+ba/bv*[height<=1080]+ba/b[height<=1080]/b", "--merge-output-format", "mp4", "-o", (Join-Path $dir "video.%(ext)s"), $Url) $null
    if ($dl.Code -ne 0) { Fail ("내려받기에 실패했습니다.`n" + (Tail $dl.Err 1200)) }
    if (-not (Test-Path -LiteralPath $video)) { Fail "내려받은 mp4 파일을 찾지 못했습니다." }
}

# ---- 자막 (대본): 직접 올린 한국어 자막이 있으면 그것, 없으면 자동 자막 ----------------------
$hasManual = $false
if ($info.PSObject.Properties["subtitles"] -and $info.subtitles -and $info.subtitles.PSObject.Properties["ko"]) { $hasManual = $true }
$vtt = $null
foreach ($n in @("video.ko.vtt", "video.ko-orig.vtt")) { if (Test-Path -LiteralPath (Join-Path $dir $n)) { $vtt = Join-Path $dir $n; break } }
if (-not $vtt -or $Force) {
    Say "한국어 자막을 받는 중..."
    $sr = Invoke-Tool $yt @("--no-playlist", "--no-warnings", "--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", "ko,ko-orig", "--sub-format", "vtt", "-o", (Join-Path $dir "video.%(ext)s"), $Url) $null
    if ($sr.Code -ne 0) { Say "주의: 자막을 받지 못했습니다. (잠시 뒤 다시 시도하거나, 화면을 직접 보고 구간을 고릅니다.)" }
    foreach ($n in @("video.ko.vtt", "video.ko-orig.vtt")) { $p = Join-Path $dir $n; if (Test-Path -LiteralPath $p) { if (-not $hasManual -and $n -eq "video.ko.vtt" -and (Test-Path -LiteralPath (Join-Path $dir "video.ko-orig.vtt"))) { continue }; $vtt = $p; break } }
}

function To-Sec([string]$ts) {
    $m = [regex]::Match($ts, '(?:(\d+):)?(\d+):(\d+)[.,](\d+)')
    if (-not $m.Success) { return -1.0 }
    $h = 0; if ($m.Groups[1].Success) { $h = [int]$m.Groups[1].Value }
    return $h * 3600 + [int]$m.Groups[2].Value * 60 + [int]$m.Groups[3].Value + [double]::Parse("0." + $m.Groups[4].Value, $inv)
}

$lines = New-Object System.Collections.ArrayList
$transcript = $null
if ($vtt) {
    $text = Get-Content -LiteralPath $vtt -Raw -Encoding UTF8
    $prev = ""
    foreach ($block in ($text -split "(\r?\n){2,}")) {
        $rows = @($block -split "\r?\n" | Where-Object { $_ -ne $null })
        $ti = -1
        for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i] -match '-->') { $ti = $i; break } }
        if ($ti -lt 0) { continue }
        $mm = [regex]::Match($rows[$ti], '^\s*(\S+)\s+-->\s+(\S+)')
        $start = To-Sec $mm.Groups[1].Value; $end = To-Sec $mm.Groups[2].Value
        if ($start -lt 0 -or ($end - $start) -lt 0.05) { continue }
        $body = @()
        for ($i = $ti + 1; $i -lt $rows.Count; $i++) {
            $t = ([regex]::Replace($rows[$i], '<[^>]+>', '')).Trim()
            $t = [Net.WebUtility]::HtmlDecode($t)
            if ($t) { $body += $t }
        }
        if ($body.Count -eq 0) { continue }
        # 자동 자막은 앞 줄을 한 번 더 보여 주는 방식이라, 앞 줄이 이전 자막과 같으면 뺀다
        if ($body.Count -gt 1 -and $body[0] -eq $prev) { $body = @($body[1..($body.Count - 1)]) }
        $line = ($body -join " ").Trim()
        if (-not $line -or $line -eq $prev) { continue }
        [void]$lines.Add(("[{0}] {1}" -f (F ([Math]::Round($start, 1))), $line))
        $prev = $line
    }
    if ($lines.Count -gt 0) {
        $kind = "자동 자막 (사람이 만든 자막이 아니라 틀린 글자가 있을 수 있습니다)"
        if ($hasManual) { $kind = "올린 사람이 만든 자막" }
        $head = "# 제목: $($info.title)`n# 자막: $kind`n# 줄 앞의 [숫자]는 그 말이 시작되는 시각(초)입니다.`n"
        $transcript = Join-Path $dir "transcript.txt"
        Write-Utf8 $transcript ($head + ($lines -join "`n") + "`n")
    }
}

$meta = [ordered]@{
    id = $id; title = [string]$info.title; uploader = [string](Get-Opt $info "uploader" ""); channel = [string](Get-Opt $info "channel" "")
    upload_date = [string](Get-Opt $info "upload_date" ""); duration = [double](Get-Opt $info "duration" 0)
    view_count = [string](Get-Opt $info "view_count" ""); webpage_url = [string](Get-Opt $info "webpage_url" $Url)
    license = [string](Get-Opt $info "license" ""); fetched = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    credit = "출처: YouTube " + [string](Get-Opt $info "channel" (Get-Opt $info "uploader" ""))
    transcript = $(if ($transcript) { "transcript.txt" } else { $null }); transcript_kind = $(if ($transcript) { $(if ($hasManual) { "manual" } else { "auto" }) } else { $null })
}
Write-Utf8 (Join-Path $dir "meta.json") (($meta | ConvertTo-Json -Depth 5))

Say ""
Say "모으기 끝: $dir"
Say ("  video.mp4 ({0:0.0}MB, {1:0.0}초), meta.json" -f ((Get-Item -LiteralPath $video).Length / 1MB), $meta.duration)
if ($transcript) { Say ("  transcript.txt ({0}줄)" -f $lines.Count) } else { Say "  (한국어 자막이 없어 transcript.txt는 만들지 못했습니다)" }
Say "안내: 영상을 쓸 권리가 있는 것만 쓰고, 완성본에는 출처를 밝히세요."
