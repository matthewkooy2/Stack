param([Parameter(Mandatory=$true)][string]$OutputDirectory)
# Existing Windows offline voice; synthetic fixture speech only, no downloads.
Add-Type -AssemblyName System.Speech
$speechFixture = Get-Content -LiteralPath "$PSScriptRoot/../tests/fixtures/interview-speech.json" -Raw | ConvertFrom-Json
$speechOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $speechOutput -Force | Out-Null
$speechFormat = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(16000,[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,[System.Speech.AudioFormat.AudioChannel]::Mono)
$speaker = [System.Speech.Synthesis.SpeechSynthesizer]::new()
try {
    $speaker.SelectVoice('Microsoft Zira Desktop')
    for ($speechIndex=0; $speechIndex -lt $speechFixture.answers.Count; $speechIndex++) {
        $speechPath = Join-Path $speechOutput ("answer-"+($speechIndex+1)+'.wav')
        if (Test-Path -LiteralPath $speechPath) { throw 'Preserve existing fixture audio; choose another output directory.' }
        $speaker.SetOutputToWaveFile($speechPath,$speechFormat)
        $speaker.Speak($speechFixture.answers[$speechIndex])
        $speaker.SetOutputToNull()
        Get-Item -LiteralPath $speechPath | Select-Object Name,Length
    }
} finally { $speaker.Dispose() }
