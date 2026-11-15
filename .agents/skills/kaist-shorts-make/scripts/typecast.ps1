# Typecast 목소리로 나레이션 만들기 (PowerShell 5.1 / 7 겸용)
#
#   키 넣기(기본):        키-입력.bat 을 더블클릭해 .env 의 TYPECAST_API_KEY= 뒤에 붙여 넣고 저장
#   키 저장(대체 수단):   typecast.ps1 -SetupKey          (Typecast 사이트에서 키를 복사(Ctrl+C)한 뒤 실행)
#   키 확인:              typecast.ps1 -Status
#   목소리 고르기:        typecast.ps1 -ListVoices        (결과\목소리-목록.html을 엽니다)
#   나레이션 만들기:      typecast.ps1 -Script 대본.txt -VoiceId tc_... -OutDir 결과\날짜-이름\narration
#
# 대본 파일은 한 줄이 한 문장입니다. 줄마다 음성을 만들고, 앞뒤 무음을 자르고, 음량을 맞춘 뒤
# 줄 사이에 쉼을 두어 narration.wav 한 파일로 합칩니다. 줄별 시작/끝 시각은 narration.json에 적습니다.
# API 키는 화면, 로그, 프로젝트 폴더, spec.json에 절대 적지 않습니다.
# 키를 읽는 순서: 환경 변수 TYPECAST_API_KEY > 프로젝트 폴더의 .env > 키 파일(-SetupKey 로 만든 것)
# 키 파일: Windows %USERPROFILE%\.kaist-shorts\typecast-key.txt, Mac/Linux ~/.kaist-shorts/typecast-key.txt
# 이 파일은 UTF-8 (BOM 포함)으로 저장합니다.
param(
    [switch]$SetupKey,
    [switch]$Status,
    [switch]$ListVoices,
    [string]$Script = "",
    [string]$VoiceId = "tc_6731b2b2478a48710ecc9158",
    [string]$OutDir = "",
    [double]$Tempo = 1.0,
    [double]$Gap = 0.20,
    [string]$Emotion = "normal",
    [switch]$AllowLong,
    [string]$FFmpeg = "",
    [switch]$NoOpen
)
. (Join-Path $PSScriptRoot "common.ps1")

$API = "https://api.typecast.ai"
$MODEL = "ssfm-v30"
$homeDir = $HOME
if ($env:USERPROFILE) { $homeDir = $env:USERPROFILE }
$keyDir = Join-Path $homeDir ".kaist-shorts"
$keyFile = Join-Path $keyDir "typecast-key.txt"
$isWin = ($env:OS -eq "Windows_NT")

function Api-Error([object]$err, [string]$what) {
    $code = 0
    try { $code = [int]$err.Exception.Response.StatusCode } catch { }
    if ($code -eq 401 -or $code -eq 403) { return "Typecast가 키를 받아 주지 않습니다 (코드 $code). 키가 맞는지, 계정이 살아 있는지 확인해 주세요." }
    if ($code -eq 402) { return "크레딧이 모자랍니다 (코드 402). Typecast 콘솔에서 남은 크레딧을 확인해 주세요." }
    if ($code -eq 429) { return "한꺼번에 너무 많이 요청했습니다 (코드 429). 잠시 뒤 다시 시도합니다." }
    if ($code -ne 0) { return "$what 중 Typecast가 오류를 돌려줬습니다 (코드 $code)." }
    return "$what 중 인터넷 연결에 실패했습니다: " + $err.Exception.Message
}

function Get-Voices([string]$key) {
    try {
        $r = Invoke-WebRequest -Uri "$API/v3/voices?model=$MODEL" -UseBasicParsing -Headers @{ "X-API-KEY" = $key } -TimeoutSec 60
    } catch { Fail (Api-Error $_ "목소리 목록 읽기") }
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    return @($text | ConvertFrom-Json)
}

# ---- 키 저장 -------------------------------------------------------------------------------
if ($SetupKey) {
    $clip = $null
    try { $clip = (Get-Clipboard -Raw) } catch { }
    $cand = ""
    if ($clip) { $cand = ([string]$clip).Trim() }
    if (-not $cand) { Fail "복사된 내용이 없습니다. Typecast 사이트에서 API 키를 복사(Ctrl+C)한 뒤 다시 실행해 주세요." }
    if ($cand -match '\s' -or $cand.Length -lt 16 -or $cand.Length -gt 200) { Fail "복사된 내용이 API 키처럼 보이지 않습니다. 키 전체만 복사했는지 확인해 주세요. (복사한 내용은 화면에 보여 주지 않습니다.)" }
    Say "키가 맞는지 Typecast에 확인하는 중..."
    $voices = Get-Voices $cand
    # 내 계정(내 컴퓨터 사용자)만 읽을 수 있게 먼저 제한한 뒤에 키를 쓴다 (제한에 실패하면 저장하지 않는다)
    Save-SecretFile $keyDir $keyFile $cand
    try { Set-Clipboard -Value " " } catch { }
    Say ("저장했습니다. 이 키로 쓸 수 있는 목소리가 {0}개 보입니다. (복사해 둔 내용은 지웠습니다.)" -f $voices.Count)
    Say "키 파일: $keyFile (프로젝트 폴더 밖, 화면에 출력하지 않음)"
    return
}

if ($Status) {
    $kr = Get-ApiKey "TYPECAST_API_KEY" $keyFile
    if ($kr.Value) { Say ("키 있음 (출처: {0})" -f $kr.Source) } else { Say (Key-Missing $kr "Typecast") }
    return
}

$kr = Get-ApiKey "TYPECAST_API_KEY" $keyFile
if (-not $kr.Value) { Fail (Key-Missing $kr "Typecast") }
$key = $kr.Value

# ---- 목소리 목록 ---------------------------------------------------------------------------
if ($ListVoices) {
    $voices = Get-Voices $key
    $ROOT = Find-ProjectRoot
    $outDirV = Join-Path $ROOT "결과"
    New-Item -ItemType Directory -Force -Path $outDirV | Out-Null
    $ko = @{ female = "여자"; male = "남자" }
    $ageKo = @{ child = "어린이"; teenager = "10대"; young_adult = "청년"; middle_age = "중년"; elder = "어르신" }
    $rows = ""
    $sorted = @($voices | Sort-Object { $_.voice_name.kor })
    foreach ($v in $sorted) {
        $nm = [string]$v.voice_name.kor; if (-not $nm) { $nm = [string]$v.voice_name.eng }
        $g = [string]$v.gender; $a = [string]$v.age
        $gk = $g; if ($ko.ContainsKey($g)) { $gk = $ko[$g] }
        $ak = $a; if ($ageKo.ContainsKey($a)) { $ak = $ageKo[$a] }
        $uc = (@($v.use_cases) -join ", ")
        $emo = ""
        foreach ($mdl in @($v.models)) { if ($mdl.version -eq $MODEL) { $emo = (@($mdl.emotions) -join ", ") } }
        $rows += "<tr data-g='$g' data-a='$a'><td><b>$([Net.WebUtility]::HtmlEncode($nm))</b><br><span class='m'>$([Net.WebUtility]::HtmlEncode([string]$v.voice_name.eng))</span></td><td>$gk</td><td>$ak</td><td>$([Net.WebUtility]::HtmlEncode($uc))</td><td><audio controls preload='none' src='$([Net.WebUtility]::HtmlEncode([string]$v.preview_url))'></audio></td><td><code>$($v.voice_id)</code></td></tr>"
    }
    $html = @"
<!DOCTYPE html><html lang='ko'><head><meta charset='utf-8'><title>Typecast 목소리 목록</title>
<style>body{font-family:'Malgun Gothic','Apple SD Gothic Neo',sans-serif;margin:24px;color:#1d2330}table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #e3e6ec;padding:6px 8px;text-align:left;vertical-align:middle;font-size:14px}th{background:#eef2f7;position:sticky;top:0}.m{color:#667085;font-size:12px}code{background:#eef2f7;padding:1px 5px;border-radius:4px;font-size:12px}select{font-size:15px;margin-right:10px}</style></head><body>
<h1>Typecast 목소리 목록 ($($voices.Count)개)</h1>
<p>듣기 버튼으로 미리 듣고, 마음에 드는 목소리의 이름을 Codex에게 알려 주세요. 미리 듣기는 인터넷이 필요합니다. 미리 듣기는 크레딧을 쓰지 않습니다.</p>
<p>성별 <select id='g'><option value=''>전체</option><option value='female'>여자</option><option value='male'>남자</option></select>
나이 <select id='a'><option value=''>전체</option><option value='young_adult'>청년</option><option value='middle_age'>중년</option><option value='elder'>어르신</option><option value='teenager'>10대</option><option value='child'>어린이</option></select></p>
<table><thead><tr><th>이름</th><th>성별</th><th>나이대</th><th>잘 어울리는 용도</th><th>미리 듣기</th><th>번호(voice_id)</th></tr></thead><tbody id='b'>$rows</tbody></table>
<script>function f(){var g=document.getElementById('g').value,a=document.getElementById('a').value;document.querySelectorAll('#b tr').forEach(function(r){r.style.display=((!g||r.dataset.g==g)&&(!a||r.dataset.a==a))?'':'none'})}document.getElementById('g').onchange=f;document.getElementById('a').onchange=f;</script></body></html>
"@
    $outHtml = Join-Path $outDirV "목소리-목록.html"
    Write-Utf8 $outHtml $html
    Say ("목소리 {0}개를 정리했습니다: {1}" -f $voices.Count, $outHtml)
    if (-not $NoOpen) {
        try {
            if ($isWin) { Start-Process -FilePath $outHtml }
            elseif (Get-Command open -ErrorAction SilentlyContinue) { & open $outHtml }
        } catch { Say "자동으로 열지 못했습니다. 위 파일을 직접 열어 주세요." }
    }
    return
}

# ---- 나레이션 만들기 ------------------------------------------------------------------------
if (-not $Script) { Fail "-Script 에 대본 파일(한 줄에 한 문장)을 적어 주세요." }
if (-not $OutDir) { Fail "-OutDir 에 결과를 둘 폴더를 적어 주세요. 예: 결과\날짜-이름\narration" }
$scriptPath = $Script
if (-not (Test-Path -LiteralPath $scriptPath)) { $scriptPath = Join-Path (Find-ProjectRoot) $Script }
if (-not (Test-Path -LiteralPath $scriptPath)) { Fail "대본 파일을 찾지 못했습니다: $Script" }
$lines = @(Get-Content -LiteralPath $scriptPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($lines.Count -eq 0) { Fail "대본이 비어 있습니다." }
$total = 0; foreach ($l in $lines) { $total += $l.Length }
if ($total -gt 1500 -and -not $AllowLong) { Fail "대본이 $total 자라서 크레딧을 많이 씁니다(1자 = 1크레딧). 쇼츠 대본은 보통 400자 안팎입니다. 줄이거나, 정말 필요하면 -AllowLong 을 붙이세요." }
if ($Tempo -lt 0.5 -or $Tempo -gt 2.0) { Fail "-Tempo 는 0.5에서 2.0 사이여야 합니다." }
$out = $OutDir
if (-not [IO.Path]::IsPathRooted($out)) { $out = Join-Path (Find-ProjectRoot) $OutDir }
$cacheDir = Join-Path $out "cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

$ff = Find-Tool "ffmpeg" $FFmpeg
if (-not $ff) { Fail "FFmpeg를 찾지 못했습니다. setup-windows.bat을 먼저 실행해 주세요." }
$probeName = "ffprobe"; if ($isWin) { $probeName = "ffprobe.exe" }
$fp = Join-Path (Split-Path -Parent $ff) $probeName
if (-not (Test-Path -LiteralPath $fp)) { $fp = Find-Tool "ffprobe" "" }
if (-not $fp) { Fail "ffprobe를 찾지 못했습니다." }

Say ("대본 {0}줄, {1}자 (약 {1} 크레딧). 같은 줄을 다시 만들 때는 저장해 둔 소리를 써서 크레딧을 쓰지 않습니다." -f $lines.Count, $total)
$used = 0
$sha = [Security.Cryptography.SHA1]::Create()
$procPaths = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $text = $lines[$i]
    $hb = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$VoiceId|$(F $Tempo)|$Emotion|$text"))
    $ck = ((($hb | ForEach-Object { $_.ToString("x2") }) -join "")).Substring(0, 16)
    $raw = Join-Path $cacheDir "$ck.wav"
    if (-not (Test-Path -LiteralPath $raw)) {
        $body = @{ voice_id = $VoiceId; text = $text; model = $MODEL; language = "kor"
            prompt = @{ emotion_type = "preset"; emotion_preset = $Emotion; emotion_intensity = 1.0 }
            output = @{ audio_format = "wav"; audio_tempo = $Tempo } } | ConvertTo-Json -Depth 5
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            try {
                $r = Invoke-WebRequest -Uri "$API/v1/text-to-speech" -Method Post -UseBasicParsing -Headers @{ "X-API-KEY" = $key } -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 180
                $bytes = $r.RawContentStream.ToArray()
                [IO.File]::WriteAllBytes($raw, $bytes)
                $ok = $true; $used += $text.Length
            } catch {
                $msg = Api-Error $_ "음성 만들기"
                $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
                if ($code -eq 429 -and $try -lt 3) { Say $msg; Start-Sleep -Seconds (3 * $try); continue }
                Fail ("{0}번째 줄에서 멈췄습니다. {1}" -f ($i + 1), $msg)
            }
        }
    }
    # 앞뒤 무음 자르기 + 줄마다 음량 맞추기(-21 LUFS), 44.1kHz 모노로 통일
    $proc = Join-Path $out ("line_{0:0000}.wav" -f ($i + 1))
    $af = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,areverse,loudnorm=I=-21:TP=-2:LRA=11,aresample=44100,aformat=sample_fmts=s16:channel_layouts=mono"
    $pr = Invoke-Tool $ff @("-hide_banner", "-nostats", "-y", "-i", $raw, "-af", $af, $proc) $null
    if ($pr.Code -ne 0) { Fail ("{0}번째 줄 소리 다듬기에 실패했습니다.`n{1}" -f ($i + 1), (Tail $pr.Err 800)) }
    $procPaths += $proc
}

# 길이 재기
$durs = @()
foreach ($p in $procPaths) {
    $d = Invoke-Tool $fp @("-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", $p) $null
    $durs += [double]::Parse($d.Out.Trim(), $inv)
}

# 합치기: 앞 0.15초 + 줄1 + 쉼 + 줄2 ... + 끝 0.35초
$lead = 0.15; $tailPad = 0.35
$inputs = @(); $labels = ""; $n = 0
$inputs += @("-f", "lavfi", "-t", (F $lead), "-i", "anullsrc=r=44100:cl=mono"); $labels += "[$n`:a]"; $n++
$timeline = @(); $t = $lead
for ($i = 0; $i -lt $procPaths.Count; $i++) {
    $inputs += @("-i", $procPaths[$i]); $labels += "[$n`:a]"; $n++
    $timeline += [ordered]@{ index = $i + 1; text = $lines[$i]; start = [Math]::Round($t, 3); end = [Math]::Round($t + $durs[$i], 3); duration = [Math]::Round($durs[$i], 3) }
    $t += $durs[$i]
    if ($i -lt $procPaths.Count - 1) {
        $inputs += @("-f", "lavfi", "-t", (F $Gap), "-i", "anullsrc=r=44100:cl=mono"); $labels += "[$n`:a]"; $n++
        $t += $Gap
    }
}
$inputs += @("-f", "lavfi", "-t", (F $tailPad), "-i", "anullsrc=r=44100:cl=mono"); $labels += "[$n`:a]"; $n++
$t += $tailPad
$graph = "${labels}concat=n=${n}:v=0:a=1[out]"
$gf = Join-Path $out "concat-graph.txt"
Write-Utf8 $gf $graph
$flag = "-filter_complex_script"
$ver = Invoke-Tool $ff @("-hide_banner", "-version") $null
if ($ver.Out -match "version\D*(\d+)\." -and [int]$Matches[1] -ge 7) { $flag = "-/filter_complex" }
$narr = Join-Path $out "narration.wav"
$cr = Invoke-Tool $ff (@("-hide_banner", "-nostats", "-y") + $inputs + @($flag, $gf, "-map", "[out]", "-ar", "44100", "-ac", "1", $narr)) $null
if ($cr.Code -ne 0) { Fail ("나레이션 합치기에 실패했습니다.`n" + (Tail $cr.Err 800)) }
Remove-Item -LiteralPath $gf -Force -ErrorAction SilentlyContinue

# 자막 후보: 줄을 17자 안팎으로 끊고, 줄 안에서 글자 수에 비례해 시각을 나눈다(말하는 속도가 일정하다고 보는 어림값)
function Split-Caption([string]$text, [int]$max) {
    $chunks = @(); $cur = ""
    foreach ($tok in ($text -split ' ')) {
        if (-not $tok) { continue }
        if ($cur -and (($cur.Length + 1 + $tok.Length) -gt $max)) { $chunks += $cur; $cur = $tok }
        elseif ($cur) { $cur = "$cur $tok" } else { $cur = $tok }
        if ($cur.Length -ge 8 -and ($cur.EndsWith(",") -or $cur.EndsWith("."))) { $chunks += $cur; $cur = "" }
    }
    if ($cur) { $chunks += $cur }
    if ($chunks.Count -ge 2 -and $chunks[$chunks.Count - 1].Length -lt 6 -and ($chunks[$chunks.Count - 2].Length + 1 + $chunks[$chunks.Count - 1].Length) -le 22) {
        $merged = $chunks[$chunks.Count - 2] + " " + $chunks[$chunks.Count - 1]
        $chunks = @($chunks[0..($chunks.Count - 3)]) + @($merged)
    }
    return $chunks
}
$captions = @()
foreach ($e in $timeline) {
    $parts = @(Split-Caption $e.text 17)
    $sum = 0; foreach ($pt in $parts) { $sum += ($pt -replace ' ', '').Length }
    $ct = [double]$e.start
    foreach ($pt in $parts) {
        $len = ($pt -replace ' ', '').Length
        $cd = [double]$e.duration * $len / [Math]::Max(1, $sum)
        $captions += [ordered]@{ start = [Math]::Round($ct, 2); end = [Math]::Round($ct + $cd, 2); text = $pt }
        $ct += $cd
    }
}
$info = [ordered]@{ voice_id = $VoiceId; model = $MODEL; tempo = $Tempo; gap = $Gap; total_chars = $total; credits_used_this_run = $used; duration = [Math]::Round($t, 3); lines = $timeline; captions = $captions }
Write-Utf8 (Join-Path $out "narration.json") (($info | ConvertTo-Json -Depth 6))

Say ""
Say ("나레이션을 만들었습니다: {0} ({1:0.0}초)" -f $narr, $t)
Say ("이번에 쓴 크레딧: 약 {0} (저장해 둔 소리를 다시 쓴 줄은 0)" -f $used)
Say "줄별 시각(초): 사진 길이를 여기에 맞춥니다. 자막 후보(17자 안팎, 시각 어림값)도 narration.json의 captions에 있습니다."
foreach ($e in $timeline) { Say ("  {0,2}. {1,6:0.00} - {2,6:0.00}  {3}" -f $e.index, $e.start, $e.end, $e.text) }
Say "안내: 무료 플랜 음성은 연습용입니다. 올리거나 퍼뜨릴 때의 이용 조건은 시작하기.md를 확인하세요."
