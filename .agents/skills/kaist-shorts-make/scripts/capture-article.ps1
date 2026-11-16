# 기사 웹페이지를 실제로 캡처해 page.png 와, 본문 문장마다 화면 좌표를 적은 page-boxes.json 을 만듭니다 (PowerShell 5.1 / 7 겸용)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture-article.ps1 -Url "https://news.kaist.ac.kr/news/html/news/?mode=V&mng_no=69410"
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture-article.ps1 -Dir "재료\기사-69410"      (sources.json 의 주소를 씁니다)
#
# collect-article.ps1 다음 단계입니다. 결과: 재료\기사-<번호>\page.png, page-boxes.json (그리고 sources.json 에 page_capture 기록).
# 브라우저는 PC에 이미 있는 Microsoft Edge(없으면 Chrome)를 씁니다. 새 프로그램을 설치하지 않고, 파이썬과 npm 패키지도 쓰지 않습니다.
# 방법: 브라우저를 화면 없이(headless) 띄우고 DevTools 프로토콜(CDP, 127.0.0.1 로컬 웹소켓)로 페이지를 읽습니다.
# 문장 좌표는 이미지를 보고 추측하지 않고 브라우저 DOM에서 Range.getClientRects 로 얻습니다.
# 이 파일은 UTF-8 (BOM 포함)으로 저장합니다.
param(
    [string]$Url = "",
    [string]$Dir = "",
    [int]$Width = 360,        # 브라우저 창 폭(CSS px). 작을수록 글자가 영상에서 크게 보입니다. 360 x 배율 3 = 폭 1080 픽셀
    [int]$Scale = 3,          # 화면 배율(DPR)
    [string]$Browser = ""     # 브라우저 실행 파일 경로(자동으로 못 찾을 때)
)
. (Join-Path $PSScriptRoot "common.ps1")

$ROOT = Find-ProjectRoot
if (-not $Url) {
    if (-not $Dir) { Fail "기사 주소(-Url) 또는 기사 폴더(-Dir)를 알려 주세요." }
    $dirFull = $Dir
    if (-not [IO.Path]::IsPathRooted($dirFull)) { $dirFull = Join-Path $ROOT $Dir }
    $sj = Join-Path $dirFull "sources.json"
    if (-not (Test-Path -LiteralPath $sj)) { Fail "기사 폴더에 sources.json 이 없습니다. 먼저 collect-article.ps1 을 실행해 주세요: $dirFull" }
    $Url = [string](Get-Content -LiteralPath $sj -Raw -Encoding UTF8 | ConvertFrom-Json).url
}
if ($Url -notmatch '^https://') { Fail "주소는 https:// 로 시작해야 합니다." }
$uri = [Uri]$Url
if ($uri.Host -ne "news.kaist.ac.kr" -and -not $uri.Host.EndsWith(".kaist.ac.kr")) { Fail "KAIST 기사 주소(news.kaist.ac.kr)만 캡처합니다: $($uri.Host)" }
if ($uri.UserInfo -or ($uri.Port -ne 443)) { Fail "주소에 계정 정보나 특별한 포트가 있어 캡처하지 않습니다." }
$id = $null
if ($Url -match '[?&]mng_no=(\d+)') { $id = $Matches[1] }
else {
    $sha = [Security.Cryptography.SHA1]::Create()
    $id = ((($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString("x2") }) -join "")).Substring(0, 8)
}
$outDir = Join-Path (Join-Path $ROOT "재료") ("기사-" + $id)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ---- 브라우저 찾기: Edge 먼저, 없으면 Chrome ------------------------------------------------
function Find-Browser([string]$hint) {
    if ($hint) { if (Test-Path -LiteralPath $hint) { return (Resolve-Path -LiteralPath $hint).Path } Fail "브라우저 파일을 찾지 못했습니다: $hint" }
    $envVal = [Environment]::GetEnvironmentVariable("KAIST_BROWSER")
    if ($envVal -and (Test-Path -LiteralPath $envVal)) { return $envVal }
    $c = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $c += (Join-Path $base "Microsoft\Edge\Application\msedge.exe") }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $c += (Join-Path $base "Google\Chrome\Application\chrome.exe") }
    }
    $c += @("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}
$exe = Find-Browser $Browser
if (-not $exe) { Fail "Microsoft Edge 또는 Google Chrome 을 찾지 못했습니다. 둘 중 하나가 PC에 있어야 기사 페이지를 캡처할 수 있습니다(새로 설치하지는 않습니다). 기사 캡처 없이 이어가려면 사용자에게 알려 주세요." }
Say "브라우저: $exe"

# 안 쓰는 로컬 포트 하나
$lis = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
$lis.Start(); $port = ([Net.IPEndPoint]$lis.LocalEndpoint).Port; $lis.Stop()
$ud = Join-Path ([IO.Path]::GetTempPath()) ("kaist-capture-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $ud | Out-Null

$script:ws = $null; $script:cdpId = 0; $script:proc = $null
$script:ct = [Threading.CancellationToken]::None

function Receive-Text {
    $ms = New-Object IO.MemoryStream
    $buf = New-Object 'byte[]' 65536
    do {
        $seg = New-Object 'ArraySegment[byte]' (, $buf)
        $r = $script:ws.ReceiveAsync($seg, $script:ct).GetAwaiter().GetResult()
        if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { Fail "브라우저가 연결을 닫았습니다." }
        $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}
# CDP 명령 하나를 보내고 같은 id 의 응답 원문(JSON 문자열)을 돌려준다. 이벤트 메시지는 건너뛴다.
function Cdp-Raw([string]$method, $params) {
    $script:cdpId++
    $myId = $script:cdpId
    if ($null -eq $params) { $params = @{} }
    $msg = (@{ id = $myId; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress)
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object 'ArraySegment[byte]' (, $bytes)
    [void]$script:ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $script:ct).GetAwaiter().GetResult()
    while ($true) {
        $t = Receive-Text
        if ($t.StartsWith('{"id":' + $myId + ',') -or $t.StartsWith('{"id":' + $myId + '}')) {
            if ($t.Contains('"error":{') -and -not $t.Contains('"result":')) { Fail ("브라우저 명령 실패 ($method): " + $t.Substring(0, [Math]::Min(300, $t.Length))) }
            return $t
        }
    }
}
function Cdp([string]$method, $params) {
    $t = Cdp-Raw $method $params
    if ($t.Length -gt 1500000) { return $null }   # PowerShell 5.1 의 JSON 읽기 한도(약 2MB) 때문에 큰 응답은 Cdp-Raw 로 직접 다룬다
    return ($t | ConvertFrom-Json).result
}
function Eval-Js([string]$js) {
    $r = Cdp "Runtime.evaluate" @{ expression = $js; returnByValue = $true; awaitPromise = $true }
    if ($r.exceptionDetails) { Fail ("페이지 안 스크립트 오류: " + ($r.exceptionDetails | ConvertTo-Json -Depth 4 -Compress)) }
    return $r.result.value
}

$js = @'
(() => {
  const SEL = ['.prog_layout', '.prog_contents', '.txt_box', 'article', 'body'];
  // 화면에 고정된 요소(배너, 팝업)는 숨긴다
  for (const el of Array.from(document.querySelectorAll('body *'))) { const cs = getComputedStyle(el); if (cs.position === 'fixed' || cs.position === 'sticky') el.style.display = 'none'; }
  window.scrollTo(0, 0);
  const sx = window.pageXOffset, sy = window.pageYOffset;
  let cont = null, used = '';
  for (const s of SEL) { const e = document.querySelector(s); if (e && e.getBoundingClientRect().height > 100) { cont = e; used = s; break; } }
  if (!cont) cont = document.body;
  const bodyEl = document.querySelector('.txt_box') || cont;
  const isCaption = p => { const t = p.textContent.replace(/\s+/g, ' ').trim(); return p.querySelector('img') !== null || (/^[<＜\[]/.test(t) && t.length < 140); };
  let ps = Array.from(bodyEl.querySelectorAll('p')).filter(p => p.textContent.replace(/[\s\u200b\u00a0\ufeff]/g, '').length > 0 && !isCaption(p));
  const out = { container: used || 'body', paragraphs: [], images: [], title: null };
  const cr = cont.getBoundingClientRect();
  let bottom = cr.bottom;
  if (ps.length) { bottom = Math.max(...ps.map(p => p.getBoundingClientRect().bottom)) + 20; }
  const M = Math.min(16, cr.left + sx);   // 좌우 여백(CSS px): 박스 테두리가 이미지 가장자리에 걸려 잘리지 않게 본문 바깥 여백을 조금 포함한다
  const clip = { x: cr.left + sx - M, y: cr.top + sy, w: cr.width + 2 * M, h: Math.max(50, bottom - cr.top) };
  out.clip = clip;
  const fx = r => ({ x: +((r.left + sx - clip.x) / clip.w).toFixed(5), y: +((r.top + sy - clip.y) / clip.h).toFixed(5), w: +(r.width / clip.w).toFixed(5), h: +(r.height / clip.h).toFixed(5) });
  const union = rs => { const l = Math.min(...rs.map(r => r.x)), t = Math.min(...rs.map(r => r.y)), rr = Math.max(...rs.map(r => r.x + r.w)), b = Math.max(...rs.map(r => r.y + r.h)); return { x: +l.toFixed(5), y: +t.toFixed(5), w: +(rr - l).toFixed(5), h: +(b - t).toFixed(5) }; };
  // 같은 줄(세로 위치가 비슷한) 사각형을 한 줄로 합친다
  function lineRects(range) {
    const rs = Array.from(range.getClientRects()).filter(r => r.width > 1 && r.height > 1).map(fx);
    const lines = [];
    for (const r of rs.sort((a, b) => a.y - b.y || a.x - b.x)) {
      const last = lines[lines.length - 1];
      if (last && Math.abs((last.y + last.h / 2) - (r.y + r.h / 2)) < Math.min(last.h, r.h) * 0.5) {
        const l = Math.min(last.x, r.x), t = Math.min(last.y, r.y), rr = Math.max(last.x + last.w, r.x + r.w), b = Math.max(last.y + last.h, r.y + r.h);
        last.x = l; last.y = t; last.w = rr - l; last.h = b - t;
      } else lines.push({ x: r.x, y: r.y, w: r.w, h: r.h });
    }
    return lines.map(l => ({ x: +l.x.toFixed(5), y: +l.y.toFixed(5), w: +l.w.toFixed(5), h: +l.h.toFixed(5) }));
  }
  function split(t) {
    const res = []; let start = 0, depth = 0, dq = false;
    for (let i = 0; i < t.length; i++) {
      const c = t[i];
      if (c === '“' || c === '‘' || c === '「' || c === '『') depth++;
      else if ((c === '”' || c === '’' || c === '」' || c === '』') && depth > 0) depth--;
      else if (c === '"') dq = !dq;
      if (depth === 0 && !dq && (c === '.' || c === '!' || c === '?' || c === '。')) {
        if (c === '.' && /\d/.test(t[i - 1] || '') && /\d/.test(t[i + 1] || '')) continue;
        let j = i + 1; while (j < t.length && /[”’」』)\]"']/.test(t[j])) j++;
        if (j >= t.length || /\s/.test(t[j])) { res.push([start, j]); start = j; while (start < t.length && /\s/.test(t[start])) start++; i = start - 1; }
      }
    }
    if (start < t.length && t.slice(start).trim()) res.push([start, t.length]);
    return res;
  }
  let sn = 0;
  ps.forEach((p, pi) => {
    const nodes = []; const tw = document.createTreeWalker(p, NodeFilter.SHOW_TEXT); let flat = '';
    while (tw.nextNode()) { const n = tw.currentNode; nodes.push({ n, s: flat.length }); flat += n.nodeValue; }
    const loc = off => { for (let k = nodes.length - 1; k >= 0; k--) if (off >= nodes[k].s) return [nodes[k].n, Math.min(off - nodes[k].s, nodes[k].n.nodeValue.length)]; return [nodes[0].n, 0]; };
    const mk = (a, b) => { const r = document.createRange(); const A = loc(a), B = loc(b); r.setStart(A[0], A[1]); r.setEnd(B[0], B[1]); return r; };
    const pr = document.createRange(); pr.selectNodeContents(p);
    const plines = lineRects(pr);
    const para = { n: pi + 1, text: flat.replace(/\s+/g, ' ').trim(), box: plines.length ? union(plines) : null, lines: plines, sentences: [] };
    let spans = [];
    try { spans = split(flat); } catch (e) { spans = []; }
    for (const [a0, b0] of spans) {
      let a = a0, b = b0; const txt = flat.slice(a, b);
      if (!txt.trim()) continue;
      let lines = [];
      try { lines = lineRects(mk(a, b)); } catch (e) { lines = []; }
      if (!lines.length) continue;
      sn++;
      para.sentences.push({ n: sn, paragraph: pi + 1, text: txt.replace(/\s+/g, ' ').trim(), box: union(lines), lines });
    }
    out.paragraphs.push(para);
  });
  for (const im of Array.from(bodyEl.querySelectorAll('img'))) { const r = im.getBoundingClientRect(); if (r.width > 40) out.images.push({ src: im.getAttribute('src'), alt: im.getAttribute('alt') || '', box: fx(r) }); }
  const tt = document.querySelector('.prog_tit strong');
  if (tt) { const r = document.createRange(); r.selectNodeContents(tt); const ls = lineRects(r); if (ls.length) out.title = { text: tt.textContent.replace(/\s+/g, ' ').trim(), box: union(ls), lines: ls }; }
  return JSON.stringify(out);
})()
'@

$ok = $false
try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $argList = @("--headless=new", "--disable-gpu", "--hide-scrollbars", "--mute-audio", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--log-level=3", "--disable-logging",
        "--remote-debugging-port=$port", "--remote-allow-origins=http://127.0.0.1:$port", "--user-data-dir=$ud", "about:blank")
    $psi.Arguments = (($argList | ForEach-Object { Quote-Arg $_ }) -join " ")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:proc = [Diagnostics.Process]::Start($psi)

    # 디버그 포트가 열릴 때까지 기다린다 (127.0.0.1 로컬만)
    $wsUrl = $null
    for ($k = 0; $k -lt 80 -and -not $wsUrl; $k++) {
        Start-Sleep -Milliseconds 250
        try {
            $lst = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json
            $pg = @($lst | Where-Object { $_.type -eq "page" } | Select-Object -First 1)
            if ($pg.Count -gt 0) { $wsUrl = [string]$pg[0].webSocketDebuggerUrl }
        } catch { }
    }
    if (-not $wsUrl) { Fail "브라우저를 띄우지 못했습니다(20초 안에 응답 없음). 브라우저가 이미 열려 있어도 이 방식은 따로 새 창을 씁니다. 다시 한 번 실행해 보고, 계속 안 되면 알려 주세요." }
    $script:ws = New-Object Net.WebSockets.ClientWebSocket
    [void]$script:ws.ConnectAsync([Uri]$wsUrl, $script:ct).GetAwaiter().GetResult()

    [void](Cdp "Page.enable" $null)
    [void](Cdp "Emulation.setDeviceMetricsOverride" @{ width = $Width; height = 900; deviceScaleFactor = $Scale; mobile = $false })
    Say "페이지를 여는 중: $Url"
    [void](Cdp "Page.navigate" @{ url = $Url })
    $ready = $false
    for ($k = 0; $k -lt 120 -and -not $ready; $k++) {
        Start-Sleep -Milliseconds 500
        $st = Eval-Js "document.readyState === 'complete' && Array.from(document.images).every(i => i.complete)"
        if ($st -eq $true) { $ready = $true }
    }
    if (-not $ready) { Fail "페이지를 다 읽지 못했습니다(60초). 인터넷 연결을 확인해 주세요." }
    [void](Eval-Js "document.fonts ? document.fonts.ready.then(() => true) : true")
    Start-Sleep -Milliseconds 800

    $data = (Eval-Js $js) | ConvertFrom-Json
    if (-not $data.paragraphs -or @($data.paragraphs).Count -eq 0) { Fail "페이지에서 본문 문단을 찾지 못했습니다. 이 주소는 캡처할 수 없습니다." }
    $clip = $data.clip
    $dpr = [double]$Scale
    if ($clip.h * $dpr -gt 15500) { $dpr = [Math]::Floor(15500 / $clip.h * 100) / 100; Say "페이지가 길어 배율을 $dpr 로 낮춥니다."; [void](Cdp "Emulation.setDeviceMetricsOverride" @{ width = $Width; height = 900; deviceScaleFactor = $dpr; mobile = $false }) }
    $raw = Cdp-Raw "Page.captureScreenshot" @{ format = "png"; captureBeyondViewport = $true; clip = @{ x = $clip.x; y = $clip.y; width = $clip.w; height = $clip.h; scale = 1 } }
    $mm = [regex]::Match($raw, '"data":"([^"]+)"')
    if (-not $mm.Success) { Fail "화면 캡처 결과를 읽지 못했습니다." }
    $png = [Convert]::FromBase64String($mm.Groups[1].Value)
    if ($png.Length -lt 1000 -or $png[1] -ne 0x50) { Fail "캡처한 파일이 PNG가 아닙니다." }
    $pw = ([int]$png[16] -shl 24) + ([int]$png[17] -shl 16) + ([int]$png[18] -shl 8) + [int]$png[19]
    $ph = ([int]$png[20] -shl 24) + ([int]$png[21] -shl 16) + ([int]$png[22] -shl 8) + [int]$png[23]
    [IO.File]::WriteAllBytes((Join-Path $outDir "page.png"), $png)

    $nSent = 0; foreach ($p in @($data.paragraphs)) { $nSent += @($p.sentences).Count }
    $boxes = [ordered]@{
        url = $Url; captured_at = (Get-Date).ToString("yyyy-MM-dd HH:mm"); browser = (Split-Path -Leaf $exe); container = $data.container
        image = [ordered]@{ file = "page.png"; w = $pw; h = $ph; dpr = $dpr; viewport_css_px = $Width }
        note = "좌표는 page.png 기준 0-1 분수 {x,y,w,h}이고 브라우저 DOM에서 읽은 값입니다. 문장 번호는 본문 전체에서 1부터, 문단 번호는 article.md 의 [문단 N]과 같습니다."
        title = $data.title; images = @($data.images); paragraphs = @($data.paragraphs)
    }
    Write-Utf8 (Join-Path $outDir "page-boxes.json") ($boxes | ConvertTo-Json -Depth 12)

    # sources.json 에 출처와 캡처한 날짜를 남긴다 (기존 내용은 그대로 두고 page_capture 만 더한다)
    $sjPath = Join-Path $outDir "sources.json"
    $sjo = $null
    if (Test-Path -LiteralPath $sjPath) { try { $sjo = Get-Content -LiteralPath $sjPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $sjo = $null } }
    if ($null -eq $sjo) { $sjo = [pscustomobject]@{ url = $Url; credit = "출처: KAIST 뉴스" } }
    $cap = [ordered]@{ file = "page.png"; boxes = "page-boxes.json"; source = "출처: KAIST 뉴스"; url = $Url; captured_at = (Get-Date).ToString("yyyy-MM-dd HH:mm"); browser = (Split-Path -Leaf $exe) }
    Add-Member -InputObject $sjo -NotePropertyName page_capture -NotePropertyValue ([pscustomobject]$cap) -Force
    Write-Utf8 $sjPath ($sjo | ConvertTo-Json -Depth 8)
    $ok = $true
    Say ("완료: {0} ({1}x{2}), 문단 {3}개, 문장 {4}개, page-boxes.json" -f (Join-Path $outDir "page.png"), $pw, $ph, @($data.paragraphs).Count, $nSent)
}
finally {
    try { if ($script:ws -and $script:ws.State -eq [Net.WebSockets.WebSocketState]::Open) { [void](Cdp-Raw "Browser.close" $null) } } catch { }
    try { if ($script:ws) { $script:ws.Dispose() } } catch { }
    try { if ($script:proc -and -not $script:proc.WaitForExit(3000)) { $script:proc.Kill() } } catch { }
    Start-Sleep -Milliseconds 300
    try { Remove-Item -LiteralPath $ud -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
