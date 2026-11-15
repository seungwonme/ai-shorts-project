# 공용 함수 (collect-video.ps1, collect-article.ps1, typecast.ps1이 불러 씁니다). UTF-8 BOM으로 저장합니다.
$ErrorActionPreference = "Stop"
$inv = [Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$utf8 = New-Object Text.UTF8Encoding($false)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function F([double]$n) { return $n.ToString("0.###", $inv) }
function Say([string]$msg) { Write-Host $msg }
function Fail([string]$msg) { throw $msg }
function Tail([string]$s, [int]$n) { if ($s.Length -gt $n) { return $s.Substring($s.Length - $n) } return $s }
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Get-Opt($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $default
}

function Find-Tool([string]$name, [string]$hint) {
    if ($hint -and (Test-Path -LiteralPath $hint)) { return (Resolve-Path -LiteralPath $hint).Path }
    $envName = "KAIST_" + $name.ToUpper().Replace("-", "")
    $envVal = [Environment]::GetEnvironmentVariable($envName)
    if ($envVal -and (Test-Path -LiteralPath $envVal)) { return $envVal }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $local = $env:LOCALAPPDATA
    if ($local) {
        $links = Join-Path $local "Microsoft\WinGet\Links\$name.exe"
        if (Test-Path -LiteralPath $links) { return $links }
        $pk = Join-Path $local "Microsoft\WinGet\Packages"
        if (Test-Path -LiteralPath $pk) {
            $hit = Get-ChildItem -LiteralPath $pk -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Quote-Arg([string]$a) {
    if ($a -eq "") { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Invoke-Tool([string]$exe, [string[]]$argList, [string]$cwd) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argList | ForEach-Object { Quote-Arg $_ }) -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.CreateNoWindow = $true
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return New-Object psobject -Property @{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}

# 프로젝트 폴더 = "재료" 폴더가 있는 가장 가까운 윗 폴더 (현재 폴더에서 먼저, 없으면 스크립트 위치에서)
function Find-ProjectRoot {
    foreach ($start in @((Get-Location).Path, $PSScriptRoot)) {
        for ($d = $start; $d; $d = Split-Path -Parent $d) {
            if (Test-Path -LiteralPath (Join-Path $d "재료") -PathType Container) { return $d }
        }
    }
    return (Get-Location).Path
}

# 파일 이름으로 쓸 수 있게 다듬는다
function Safe-Name([string]$s, [int]$max) {
    $t = ($s -replace '[\\/:*?"<>|\s]+', '-').Trim("-")
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }
    return $t
}

# 비밀 값(API 키)을 내 계정만 읽을 수 있는 파일에 저장한다. 순서가 중요하다:
# 폴더 권한 제한 -> 빈 파일 만들기 -> 파일 권한 제한 -> 그 다음에야 값을 쓴다.
# 권한 제한이 하나라도 실패하면 파일을 지우고 멈춘다(값은 쓰지 않는다).
function Save-SecretFile([string]$dir, [string]$file, [string]$value) {
    $win = ($env:OS -eq "Windows_NT")
    $failMsg = "키 파일을 내 계정만 읽도록 제한하지 못해 저장하지 않았습니다. 이 컴퓨터의 보안 설정을 확인해 주세요."
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        if ($win) {
            $grant = ($env:USERNAME + ":(OI)(CI)F")
            $r = Invoke-Tool "icacls.exe" @($dir, "/inheritance:r", "/grant:r", $grant) $null
            if ($r.Code -ne 0) { throw "icacls dir $($r.Code)" }
        } else {
            $r = Invoke-Tool "chmod" @("700", $dir) $null
            if ($r.Code -ne 0) { throw "chmod dir $($r.Code)" }
        }
        # 빈 파일을 먼저 만든다 (값은 아직 쓰지 않는다)
        [IO.File]::WriteAllBytes($file, (New-Object byte[] 0))
        if ($win) {
            $grantF = ($env:USERNAME + ":F")
            $r = Invoke-Tool "icacls.exe" @($file, "/inheritance:r", "/grant:r", $grantF) $null
            if ($r.Code -ne 0) { throw "icacls file $($r.Code)" }
        } else {
            $r = Invoke-Tool "chmod" @("600", $file) $null
            if ($r.Code -ne 0) { throw "chmod file $($r.Code)" }
        }
    } catch {
        try { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } } catch { }
        Fail $failMsg
    }
    Write-Utf8 $file $value
}
