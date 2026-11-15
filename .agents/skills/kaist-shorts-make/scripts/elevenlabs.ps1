# ElevenLabs 목소리로 나레이션 만들기 (PowerShell 5.1 / 7 겸용) - Typecast(typecast.ps1)의 백업 수단
#
#   키 넣기(기본):        키-입력.bat 을 더블클릭해 .env 의 ELEVENLABS_API_KEY= 뒤에 붙여 넣고 저장 (선택 항목)
#   키 확인:              elevenlabs.ps1 -Status          (키 값은 절대 출력하지 않습니다)
#   글자 수와 크레딧:     elevenlabs.ps1 -Script 대본.txt -Estimate     (인터넷과 키 없이 글자 수만 셉니다)
#   목소리 고르기:        elevenlabs.ps1 -ListVoices      (결과\목소리-목록-elevenlabs.html을 엽니다, 크레딧을 쓰지 않음)
#   나레이션 만들기:      elevenlabs.ps1 -Script 대본.txt -VoiceId <voice_id> -OutDir 결과\날짜-이름\narration
#   효과음(예비, 시험 전용): elevenlabs.ps1 -Sfx "short soft whoosh" -SfxSeconds 0.8     (지금은 크레딧 계산과 오류 안내만 합니다. 실제 생성은 켜지 않았습니다)
#       효과음의 기본 길은 openverse.ps1 -SearchSfx 입니다. ElevenLabs 효과음은 거기서 마땅한 소리를 못 찾았을 때의 예비입니다.
#       설계: POST https://api.elevenlabs.io/v1/sound-generation, 헤더 xi-api-key, 본문 {"text","duration_seconds"(0.5-30)}, 응답은 mp3. 생성 1회 약 200 크레딧(조정자 조사 보고서 기준, 길이를 직접 정하면 달라질 수 있음: 미확인).
#       무료 플랜(월 10,000 크레딧)으로 만든 소리는 상업 이용이 안 되고 공개하려면 제목에 elevenlabs.io 표기가 필요하므로 KAIST 채널 영상에는 유료 플랜이 필요합니다.
#
# typecast.ps1 과 같은 계약입니다: 대본 파일은 한 줄이 한 문장이고, 줄마다 한 클립을 만들고, 앞뒤 무음을 자르고 음량을 맞춘 뒤
# 줄 사이에 쉼을 두어 narration.wav 한 파일로 합치며, 줄별 시작/끝 시각과 자막 후보는 narration.json에 적습니다.
# API 키는 화면, 로그, 프로젝트 폴더, spec.json에 절대 적지 않습니다. 키를 읽는 순서: 환경 변수 ELEVENLABS_API_KEY > 프로젝트 폴더의 .env > 키 파일(-SetupKey)
# 키 파일: Windows %USERPROFILE%\.kaist-shorts\elevenlabs-key.txt, Mac/Linux ~/.kaist-shorts/elevenlabs-key.txt
#
# 근거(ElevenLabs 공식 문서, 2026-11-16 확인):
#  - 호출: POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128, 헤더 xi-api-key, 본문 {"text","model_id"}; 응답은 오디오 파일
#    (https://elevenlabs.io/docs/api-reference/text-to-speech/convert). model_id 기본값은 eleven_multilingual_v2이고 language_code 는 이 모델에서 지원하지 않는다고 적혀 있습니다.
#  - 모델과 한국어: eleven_multilingual_v2(한국어 지원, 요청당 10,000자), eleven_flash_v2_5(한국어 지원, 요청당 40,000자), eleven_v3(한국어 지원, 5,000자), eleven_v4(한국어 지원, 10,000자)
#    (https://elevenlabs.io/docs/overview/models). 기본 모델은 문서 기본값인 eleven_multilingual_v2로 합니다.
#  - 크레딧: 가격 페이지에 "Text to Speech: 1 credit per character", V2 Multilingual은 1자 = 1크레딧, V2.5 Flash/Turbo 다국어 API 모델은 0.5~1 크레딧(할인)
#    (https://elevenlabs.io/pricing). eleven_v3와 eleven_v4의 글자당 크레딧은 문서에서 확인하지 못했습니다(미확인) - 이 도구는 글자 수를 상한(1자 = 1크레딧)으로 안내합니다.
#  - 무료 플랜 한도: 월 10,000 크레딧(https://elevenlabs.io/pricing). 유료 플랜은 Starter 30,000, Creator 121,000 크레딧(같은 페이지).
#  - 이용 조건: "무료 플랜에는 상업 라이선스가 없고 어떤 상업적 목적에도 쓸 수 없다. 무료 플랜이나 로그아웃 상태에서 만든 콘텐츠를 공개하려면 제목에 elevenlabs.io 또는 11.ai 를 넣어 ElevenLabs를 밝혀야 한다.
#    모든 유료 플랜은 상업 라이선스를 포함한다(베타 서비스 제외)"
#    (https://elevenlabs.io/docs/help-center/legal/can-i-publish-the-content-i-generate-on-the-platform). AI 음성임을 밝혀야 하는지는 이 문서가 다루지 않아 미확인입니다.
#  - 기본 목소리: 공식 빠른 시작 예제의 voice_id JBFqnCBsd6RMkjVDRZzb(문서에서 "George")를 씁니다. 무료 플랜 API 키로 이 목소리를 쓸 수 있는지, 한국어 발음이 어떤지는 확인하지 못했습니다(미확인).
#  - 출력: mp3(mp3_44100_128)를 받아 ffmpeg로 wav로 바꿉니다. 44.1kHz PCM/WAV 출력은 Pro 이상이라고 문서에 적혀 있어 쓰지 않습니다.
#  - 요청당 글자 수 한도가 줄마다 걸리므로(쇼츠 한 줄은 수십 자) 문제가 되지 않습니다.
# 이 파일은 UTF-8 (BOM 포함)으로 저장합니다.
param(
    [switch]$SetupKey,
    [switch]$Status,
    [switch]$ListVoices,
    [switch]$Estimate,
    [string]$Sfx = "",           # 효과음 설명(시험 전용, 크레딧 계산만)
    [double]$SfxSeconds = 0,    # 효과음 길이(초) 0.5-30, 0이면 ElevenLabs가 정함
    [string]$Script = "",
    [string]$VoiceId = "JBFqnCBsd6RMkjVDRZzb",
    [string]$Model = "eleven_multilingual_v2",
    [string]$OutDir = "",
    [double]$Gap = 0.20,
    [switch]$AllowLong,
    [string]$FFmpeg = "",
    [switch]$NoOpen
)
. (Join-Path $PSScriptRoot "common.ps1")

$API = "https://api.elevenlabs.io"
$homeDir = $HOME
if ($env:USERPROFILE) { $homeDir = $env:USERPROFILE }
$keyDir = Join-Path $homeDir ".kaist-shorts"
$keyFile = Join-Path $keyDir "elevenlabs-key.txt"
$isWin = ($env:OS -eq "Windows_NT")
$MODELS_KO = @("eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_v3", "eleven_v4")
if ($MODELS_KO -notcontains $Model) { Fail "이 도구가 확인한 한국어 모델은 $($MODELS_KO -join ', ') 입니다: $Model" }
if ($VoiceId -notmatch '^[A-Za-z0-9]{10,40}$') { Fail "voice_id 는 영문과 숫자로 된 ElevenLabs 목소리 번호여야 합니다." }

function Api-Error([object]$err, [string]$what) {
    $code = 0
    try { $code = [int]$err.Exception.Response.StatusCode } catch { }
    if ($code -eq 401 -or $code -eq 403) { return "ElevenLabs가 키를 받아 주지 않습니다 (코드 $code). 키가 맞는지, 계정이 살아 있는지, 크레딧이 남았는지 확인해 주세요." }
    if ($code -eq 402) { return "크레딧이나 플랜이 모자랍니다 (코드 402). ElevenLabs 사이트에서 확인해 주세요." }
    if ($code -eq 422 -or $code -eq 400) { return "$what 요청을 ElevenLabs가 받아들이지 않았습니다 (코드 $code). 목소리 번호나 모델이 맞는지 확인해 주세요." }
    if ($code -eq 429) { return "한꺼번에 너무 많이 요청했습니다 (코드 429). 잠시 뒤 다시 시도합니다." }
    if ($code -ne 0) { return "$what 중 ElevenLabs가 오류를 돌려줬습니다 (코드 $code)." }
    return "$what 중 인터넷 연결에 실패했습니다: " + $err.Exception.Message
}

function Get-Voices([string]$key) {
    try {
        $r = Invoke-WebRequest -Uri "$API/v1/voices" -UseBasicParsing -Headers @{ "xi-api-key" = $key } -TimeoutSec 60
    } catch { Fail (Api-Error $_ "목소리 목록 읽기") }
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    return @(($text | ConvertFrom-Json).voices)
}

# ---- 키 저장(대체 수단) ---------------------------------------------------------------------
if ($SetupKey) {
    $clip = $null
    try { $clip = (Get-Clipboard -Raw) } catch { }
    $cand = ""
    if ($clip) { $cand = ([string]$clip).Trim() }
    if (-not $cand) { Fail "복사된 내용이 없습니다. ElevenLabs 사이트에서 API 키를 복사(Ctrl+C)한 뒤 다시 실행해 주세요." }
    if ($cand -match '\s' -or $cand.Length -lt 16 -or $cand.Length -gt 200) { Fail "복사된 내용이 API 키처럼 보이지 않습니다. 키 전체만 복사했는지 확인해 주세요. (복사한 내용은 화면에 보여 주지 않습니다.)" }
    Save-SecretFile $keyDir $keyFile $cand
    try { Set-Clipboard -Value " " } catch { }
    Say "저장했습니다. 키가 맞는지는 -ListVoices 나 나레이션 만들기에서 확인됩니다. (복사해 둔 내용은 지웠습니다.)"
    Say "키 파일: $keyFile (프로젝트 폴더 밖, 화면에 출력하지 않음)"
    return
}

if ($Status) {
    $kr = Get-ApiKey "ELEVENLABS_API_KEY" $keyFile
    if ($kr.Value) { Say ("키 있음 (출처: {0})" -f $kr.Source) } else { Say (Key-Missing $kr "ElevenLabs") }
    return
}

# ---- 효과음 크레딧 계산 (시험 전용: 아무것도 호출하지 않고, 아무것도 만들지 않는다) -----------------------
if ($Sfx) {
    $st = $Sfx.Trim()
    if ($st.Length -lt 3) { Fail "효과음 설명이 너무 짧습니다. 어떤 소리인지 영어나 한국어 한 문장으로 적어 주세요. 예: short soft whoosh" }
    if ($st.Length -gt 200) { Fail "효과음 설명이 깁니다($($st.Length)자). 200자 이하로 줄여 주세요." }
    if ($SfxSeconds -ne 0 -and ($SfxSeconds -lt 0.5 -or $SfxSeconds -gt 30)) { Fail "-SfxSeconds 는 0.5에서 30 사이(초)여야 합니다. 쇼츠 효과음은 1초 안팎이면 충분합니다." }
    $durTxt = "길이는 ElevenLabs가 정함"; if ($SfxSeconds -gt 0) { $durTxt = "길이 $(F $SfxSeconds)초" }
    Say ("효과음 1개: '{0}' ({1})" -f $st, $durTxt)
    Say "예상 크레딧: 생성 1회 약 200 (조정자 조사 보고서 기준. 길이를 정하면 달라질 수 있는지는 확인하지 못했습니다). 무료 플랜은 월 10,000 크레딧이라 최대 약 50개입니다."
    $kr0 = Get-ApiKey "ELEVENLABS_API_KEY" $keyFile
    if ($kr0.Value) { Say ("키: 있음 (출처: {0})" -f $kr0.Source) } else { Say ("키: 없음. 실제 생성 때 필요합니다. " + (Key-Missing $kr0 "ElevenLabs")) }
    Say "주의: ElevenLabs 무료 플랜으로 만든 소리는 상업 이용이 안 되고, 공개하려면 제목에 elevenlabs.io 표기가 필요합니다. KAIST 채널 영상에는 유료 플랜(상업 이용 허가)이 필요합니다."
    Say "이 도구는 지금 효과음을 실제로 만들지 않습니다(설계와 시험 단계). 아무것도 호출하지 않았고 크레딧을 쓰지 않았습니다. 실제 생성은 사용자 승인 뒤에 켭니다."
    return
}

# ---- 글자 수 세기 (키 없이) -----------------------------------------------------------------
function Read-Script([string]$path) {
    $scriptPath = $path
    if (-not (Test-Path -LiteralPath $scriptPath)) { $scriptPath = Join-Path (Find-ProjectRoot) $path }
    if (-not (Test-Path -LiteralPath $scriptPath)) { Fail "대본 파일을 찾지 못했습니다: $path" }
    $ls = @(Get-Content -LiteralPath $scriptPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ls.Count -eq 0) { Fail "대본이 비어 있습니다." }
    return $ls
}
if ($Estimate) {
    if (-not $Script) { Fail "-Script 에 대본 파일(한 줄에 한 문장)을 적어 주세요." }
    $el = Read-Script $Script
    $tt = 0; foreach ($l in $el) { $tt += $l.Length }
    Say ("대본 {0}줄, {1}자 -> 예상 크레딧 최대 {1} (모델 {2}, 글자당 1크레딧 상한). 무료 플랜은 월 10,000 크레딧입니다. 아무것도 호출하지 않았습니다." -f $el.Count, $tt, $Model)
    return
}

$kr = Get-ApiKey "ELEVENLABS_API_KEY" $keyFile
if (-not $kr.Value) { Fail (Key-Missing $kr "ElevenLabs") }
$key = $kr.Value

# ---- 목소리 목록 ---------------------------------------------------------------------------
if ($ListVoices) {
    $voices = Get-Voices $key
    $ROOT = Find-ProjectRoot
    $outDirV = Join-Path $ROOT "결과"
    New-Item -ItemType Directory -Force -Path $outDirV | Out-Null
    $rows = ""
    foreach ($v in @($voices | Sort-Object { [string]$_.name })) {
        $lab = ""; try { $lab = (@($v.labels.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join ", ") } catch { }
        $pv = ""; if ($v.preview_url) { $pv = "<audio controls preload='none' src='$([Net.WebUtility]::HtmlEncode([string]$v.preview_url))'></audio>" }
        $rows += "<tr><td><b>$([Net.WebUtility]::HtmlEncode([string]$v.name))</b></td><td>$([Net.WebUtility]::HtmlEncode($lab))</td><td>$pv</td><td><code>$($v.voice_id)</code></td></tr>"
    }
    $html = @"
<!DOCTYPE html><html lang='ko'><head><meta charset='utf-8'><title>ElevenLabs 목소리 목록</title>
<style>body{font-family:'Malgun Gothic','Apple SD Gothic Neo',sans-serif;margin:24px;color:#1d2330}table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #e3e6ec;padding:6px 8px;text-align:left;vertical-align:middle;font-size:14px}th{background:#eef2f7}code{background:#eef2f7;padding:1px 5px;border-radius:4px;font-size:12px}</style></head><body>
<h1>ElevenLabs 목소리 목록 ($($voices.Count)개)</h1>
<p>듣기 버튼으로 미리 듣고, 마음에 드는 목소리의 이름이나 번호를 Codex에게 알려 주세요. 미리 듣기는 크레딧을 쓰지 않습니다. 목소리가 한국어를 얼마나 자연스럽게 읽는지는 이 미리 듣기로 알 수 없을 수 있으니 짧은 줄로 먼저 시험하세요.</p>
<table><thead><tr><th>이름</th><th>특징</th><th>미리 듣기</th><th>번호(voice_id)</th></tr></thead><tbody>$rows</tbody></table></body></html>
"@
    $outHtml = Join-Path $outDirV "목소리-목록-elevenlabs.html"
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
$lines = Read-Script $Script
$total = 0; foreach ($l in $lines) { $total += $l.Length }
if ($total -gt 1500 -and -not $AllowLong) { Fail "대본이 $total 자라서 크레딧을 많이 씁니다(1자 = 최대 1크레딧). 쇼츠 대본은 보통 400자 안팎입니다. 줄이거나, 정말 필요하면 -AllowLong 을 붙이세요." }
foreach ($l in $lines) { if ($l.Length -gt 1000) { Fail "한 줄이 1000자를 넘습니다. 줄을 나눠 주세요." } }
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

Say ("대본 {0}줄, {1}자 (예상 크레딧 최대 {1}, 모델 {2}). 같은 줄을 다시 만들 때는 저장해 둔 소리를 써서 크레딧을 쓰지 않습니다." -f $lines.Count, $total, $Model)
$used = 0
$sha = [Security.Cryptography.SHA1]::Create()
$procPaths = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $text = $lines[$i]
    $hb = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("elevenlabs|$VoiceId|$Model|$text"))
    $ck = ((($hb | ForEach-Object { $_.ToString("x2") }) -join "")).Substring(0, 16)
    $raw = Join-Path $cacheDir "$ck.mp3"
    if (-not (Test-Path -LiteralPath $raw)) {
        $body = @{ text = $text; model_id = $Model }
        if ($Model -ne "eleven_multilingual_v2") { $body["language_code"] = "ko" }   # 문서: language_code 는 multilingual_v2 에서 지원하지 않음
        $bodyJson = $body | ConvertTo-Json -Depth 4
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            try {
                $r = Invoke-WebRequest -Uri "$API/v1/text-to-speech/${VoiceId}?output_format=mp3_44100_128" -Method Post -UseBasicParsing -Headers @{ "xi-api-key" = $key; "Accept" = "audio/mpeg" } -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 180
                $bytes = $r.RawContentStream.ToArray()
                if ($bytes.Length -lt 1000) { throw "응답이 너무 작습니다" }
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
    # mp3 -> wav, 앞뒤 무음 자르기 + 줄마다 음량 맞추기(-21 LUFS), 44.1kHz 모노로 통일
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
$info = [ordered]@{ provider = "elevenlabs"; voice_id = $VoiceId; model = $Model; tempo = 1.0; gap = $Gap; total_chars = $total; credits_used_this_run = $used; duration = [Math]::Round($t, 3); lines = $timeline; captions = $captions }
Write-Utf8 (Join-Path $out "narration.json") (($info | ConvertTo-Json -Depth 6))

Say ""
Say ("나레이션을 만들었습니다: {0} ({1:0.0}초)" -f $narr, $t)
Say ("이번에 쓴 크레딧: 최대 {0} (글자 수 기준 상한, 저장해 둔 소리를 다시 쓴 줄은 0. 실제 사용량은 ElevenLabs 사이트에서 확인)" -f $used)
Say "줄별 시각(초): 사진 길이를 여기에 맞춥니다. 자막 후보(17자 안팎, 시각 어림값)도 narration.json의 captions에 있습니다."
foreach ($e in $timeline) { Say ("  {0,2}. {1,6:0.00} - {2,6:0.00}  {3}" -f $e.index, $e.start, $e.end, $e.text) }
Say "안내: ElevenLabs 무료 플랜 음성은 상업적 이용이 안 되고, 비상업으로 공개하려면 제목에 elevenlabs.io 또는 11.ai 표기가 필요합니다. KAIST 채널 게시에는 유료 플랜(상업 이용 허가)이 필요합니다. 자세한 조건은 시작하기.md와 AGENTS.md를 확인하세요."
