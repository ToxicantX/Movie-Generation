param(
    [string]$ResultsPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_i2v_results.json",
    [string]$OutputPath = "G:\ComfyUI\output\AIShortDrama\episodes\SSJ_EP01_SC01_test_24s_v001.mp4",
    [string]$ConcatListPath = "E:\workspace\ComfyUIProjects\Movie-Generation\manifests\ssj_ep01_sc01_concat_list.txt",
    [string]$FfmpegPath = ""
)

$ffmpegExe = $FfmpegPath
if (-not $ffmpegExe) {
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ffmpeg) {
        $ffmpegExe = $ffmpeg.Source
    }
}
if (-not $ffmpegExe -or -not (Test-Path -LiteralPath $ffmpegExe)) {
    throw "ffmpeg was not found in PATH. Install ffmpeg or add it to PATH before concatenating videos."
}
if (-not (Test-Path -LiteralPath $ResultsPath)) {
    throw "Results file not found: $ResultsPath"
}

$results = Get-Content -Path $ResultsPath -Raw | ConvertFrom-Json
$videoPaths = @()
foreach ($result in $results) {
    if ($result.completed -and $result.video_paths) {
        foreach ($videoPath in $result.video_paths) {
            if (Test-Path -LiteralPath $videoPath) {
                $videoPaths += $videoPath
            }
        }
    }
}
if ($videoPaths.Count -lt 1) {
    throw "No completed video paths found in $ResultsPath"
}

New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $ConcatListPath) -Force | Out-Null

$concatLines = foreach ($videoPath in $videoPaths) {
    $escaped = $videoPath.Replace("'", "'\\''")
    "file '$escaped'"
}
$concatLines | Set-Content -Path $ConcatListPath -Encoding ASCII

& $ffmpegExe -y -f concat -safe 0 -i $ConcatListPath -c copy $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg concat failed with exit code $LASTEXITCODE"
}

Get-Item -LiteralPath $OutputPath | Select-Object FullName, Length, LastWriteTime
