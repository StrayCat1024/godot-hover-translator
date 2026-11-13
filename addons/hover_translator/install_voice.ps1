param(
    [string]$StatusPath = "",
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"

function Set-Status([string]$message) {
    if ([string]::IsNullOrWhiteSpace($StatusPath)) { return }
    try { [IO.File]::WriteAllText($StatusPath, $message + "`n") } catch { }
}

function Write-Log([string]$message) {
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try { [IO.File]::AppendAllText($LogPath, ((Get-Date -Format "HH:mm:ss") + " " + $message + "`n")) } catch { }
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Find-Python {
    Refresh-Path
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd) { return [pscustomobject]@{ Exe = $cmd.Source; Args = @("-3") } }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notlike "*WindowsApps*") {
        return [pscustomobject]@{ Exe = $cmd.Source; Args = @() }
    }
    $patterns = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python*\python.exe"),
        "C:\Program Files\Python*\python.exe"
    )
    foreach ($pattern in $patterns) {
        $file = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($file) { return [pscustomobject]@{ Exe = $file.FullName; Args = @() } }
    }
    return $null
}

function Invoke-Logged([string]$exe, [string[]]$arguments) {
    $output = & $exe @arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try { [IO.File]::AppendAllText($LogPath, $output) } catch { }
    }
    return $code
}

Set-Status "START"
Write-Log "START"

try {
    $python = Find-Python
    if (-not $python) {
        Set-Status "PROGRESS|PYTHON"
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Log "winget install Python.Python.3.12"
            Invoke-Logged $winget.Source @("install", "--id", "Python.Python.3.12", "-e", "--silent", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget") | Out-Null
        } else {
            Write-Log "winget not found"
        }
        $python = Find-Python
    }

    if (-not $python) {
        Set-Status "PROGRESS|PYTHON"
        $urls = @(
            "https://mirrors.huaweicloud.com/python/3.12.7/python-3.12.7-amd64.exe",
            "https://registry.npmmirror.com/-/binary/python/3.12.7/python-3.12.7-amd64.exe",
            "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe"
        )
        $setup = Join-Path $env:TEMP "hover_translator_python_setup.exe"
        $downloaded = $false
        foreach ($url in $urls) {
            try {
                Write-Log "download $url"
                Invoke-WebRequest -Uri $url -OutFile $setup -UseBasicParsing -TimeoutSec 300
                $downloaded = $true
                break
            } catch {
                Write-Log ("download failed: " + $url + " / " + $_.Exception.Message)
            }
        }
        if (-not $downloaded) { throw "PYTHON_DOWNLOAD" }
        Write-Log "run python installer"
        Start-Process -FilePath $setup -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_pip=1", "Include_test=0" -Wait
        Start-Sleep -Seconds 5
        $python = Find-Python
    }

    if (-not $python) { throw "PYTHON_INSTALL" }
    Write-Log ("python=" + $python.Exe)

    Set-Status "PROGRESS|EDGE"
    $pyArgs = @($python.Args)
    $code = Invoke-Logged $python.Exe ($pyArgs + @("-m", "pip", "install", "--user", "--upgrade", "edge-tts", "-i", "https://pypi.tuna.tsinghua.edu.cn/simple"))
    if ($code -ne 0) {
        Write-Log "mirror pip failed, retry default index"
        $code = Invoke-Logged $python.Exe ($pyArgs + @("-m", "pip", "install", "--user", "--upgrade", "edge-tts"))
    }
    if ($code -ne 0) { throw "EDGE_INSTALL" }

    $code = Invoke-Logged $python.Exe ($pyArgs + @("-c", "import edge_tts"))
    if ($code -ne 0) { throw "EDGE_IMPORT" }

    Set-Status "DONE"
    Write-Log "DONE"
    exit 0
} catch {
    $message = $_.Exception.Message
    if ($message -notmatch "^(PYTHON|EDGE)") { $message = "UNKNOWN" }
    Set-Status ("ERROR|" + $message)
    Write-Log ("ERROR " + $message)
    exit 1
}
