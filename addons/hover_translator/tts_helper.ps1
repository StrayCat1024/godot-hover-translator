param(
    [string]$Voice = "Microsoft Zira Desktop",
    [int]$Rate = 0,
    [int]$Volume = 100,
    [string]$LogPath = "",
    [string]$StatusPath = ""
)

$ErrorActionPreference = "Continue"
$script:synth = $null
$script:final_status = ""

function Ensure-Parent($path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        $dir = [IO.Path]::GetDirectoryName($path)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    } catch { }
}

function Log($message) {
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        [IO.File]::AppendAllText($LogPath, (Get-Date -Format "HH:mm:ss.fff") + " " + $message + "`n")
    } catch { }
}

function Set-Status($message) {
    $script:final_status = $message
    if ([string]::IsNullOrWhiteSpace($StatusPath)) { return }
    try {
        [IO.File]::WriteAllText($StatusPath, $message + "`n")
    } catch { }
}

Ensure-Parent $LogPath
Ensure-Parent $StatusPath
Log ("START pid=" + $PID + " voice=" + $Voice)
Set-Status "STARTING"

try {
    Add-Type -AssemblyName System.Speech
    Log "ADDED System.Speech"

    $script:synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voices = @($script:synth.GetInstalledVoices() | Where-Object { $_.Enabled })
    Log ("VOICES=" + (($voices | ForEach-Object { $_.VoiceInfo.Name }) -join ";"))

    if ($voices.Count -eq 0) {
        throw "No usable voice installed. Install an English voice in Windows Settings."
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Voice)) {
        $wanted = $voices | Where-Object { $_.VoiceInfo.Name -eq $Voice } | Select-Object -First 1
        if ($wanted) { $candidates += $wanted }
    }
    $english = $voices | Where-Object { $_.VoiceInfo.Culture.Name -like "en-*" } | Select-Object -First 1
    if ($english) { $candidates += $english }
    foreach ($v in $voices) { $candidates += $v }

    $selected = $null
    foreach ($candidate in $candidates) {
        try {
            $script:synth.SelectVoice($candidate.VoiceInfo.Name)
            $selected = $candidate
            Log ("SELECTED:" + $candidate.VoiceInfo.Name)
            break
        } catch {
            Log ("SELECT_FAILED:" + $candidate.VoiceInfo.Name + " / " + $_.Exception.Message)
        }
    }

    if ($null -eq $selected) {
        throw "Cannot select a voice. Windows denied speech access (restricted or sandboxed process)."
    }

    $script:synth.Rate = [Math]::Max(-10, [Math]::Min(10, $Rate))
    $script:synth.Volume = [Math]::Max(0, [Math]::Min(100, $Volume))
    try {
        $script:synth.SetOutputToDefaultAudioDevice()
        Log "OUTPUT:default"
    } catch {
        Log ("OUTPUT_DEFAULT_FAILED:" + $_.Exception.Message)
    }

    Set-Status ("READY|" + $selected.VoiceInfo.Name)
    Log ("READY voice=" + $selected.VoiceInfo.Name + " rate=" + $script:synth.Rate + " volume=" + $script:synth.Volume)

    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) {
            Log "EOF"
            break
        }
        if ($line -eq "__QUIT__") {
            Log "QUIT"
            break
        }
        $text = $line.Trim()
        if ($text -eq "") { continue }
        try {
            $script:synth.SpeakAsyncCancelAll()
            $script:synth.SpeakAsync($text) | Out-Null
            Log ("SPEAK:" + $text)
        } catch {
            $message = $_.Exception.Message
            Log ("SPEAK_FAILED:" + $text + " / " + $message)
            Set-Status ("ERROR|" + $message)
            break
        }
    }
} catch {
    $message = $_.Exception.Message
    Log ("FATAL:" + $message)
    Set-Status ("ERROR|" + $message)
} finally {
    if ($script:synth) {
        try { $script:synth.Dispose() } catch { }
    }
    if ($script:final_status -notlike "ERROR|*") {
        Set-Status "STOPPED"
    }
}
