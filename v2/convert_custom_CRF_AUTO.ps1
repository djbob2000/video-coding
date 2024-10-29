# Specify paths to required tools
$FfmpegDir = "c:\FFMpeg\bin"
$AbAv1Dir = "c:\FFMpeg\ab-av1"

# Add FFmpeg to PATH
$env:Path = "$FfmpegDir;$env:Path"

# Specify the folder with source files and output folder
$InputDir = "c:\!Share\download-reduce-size-move-to-google\video\gnom-vera"
$OutputDir = "c:\FFMpeg\output"

# Create output folder if it doesn't exist
if (!(Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir
}

# Function to process one file
function Process-File {
    param (
        [string]$file
    )
    $filename = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $outputFile = "$OutputDir\$filename`_converted.mp4"

    if (Test-Path $outputFile) {
        Write-Host "File $outputFile already exists. Skipping..."
        return
    }

    # Check color space and color transfer via ffprobe
    $ffprobePath = Join-Path $FfmpegDir "ffprobe.exe"
    $ffprobeOutputColorSpace = &$ffprobePath -v error -select_streams v:0 -show_entries stream=color_space -of default=noprint_wrappers=1:nokey=1 $file
    $ffprobeOutputColorTransfer = &$ffprobePath -v error -select_streams v:0 -show_entries stream=color_transfer -of default=noprint_wrappers=1:nokey=1 $file
    $ffprobeOutputColorPrimaries = &$ffprobePath -v error -select_streams v:0 -show_entries stream=color_primaries -of default=noprint_wrappers=1:nokey=1 $file
    $ffprobeOutputColorRange = &$ffprobePath -v error -select_streams v:0 -show_entries stream=color_range -of default=noprint_wrappers=1:nokey=1 $file

    Write-Host "Processing file: $file"
    Write-Host "Color space: $ffprobeOutputColorSpace"
    Write-Host "Color transfer: $ffprobeOutputColorTransfer"
    Write-Host "Color primaries: $ffprobeOutputColorPrimaries"
    Write-Host "Color range: $ffprobeOutputColorRange"

    # Define color range
    $colorRange = switch ($ffprobeOutputColorRange) {
        "tv" { "limited" }
        "pc" { "full" }
        default { "limited" }
    }

    Write-Host "Selected color range: $colorRange" -ForegroundColor Green

    # Define target color space
    function Get-TargetColorSpace {
        param (
            [string]$colorSpace,
            [string]$colorTransfer,
            [string]$colorPrimaries
        )

        # Check specifically for iPhone Dolby Vision (Profile 8.4)
        $dolbyVisionInfo = &$ffprobePath -v error -select_streams v:0 -show_entries stream=codec_tag_string:side_data_list $file
        if ($dolbyVisionInfo -match "dvh1" -or $dolbyVisionInfo -match "dvhe") {
            # iPhone uses Profile 8.4 which is compatible with HDR10
            return "iphone-dolby-vision"
        }

        # Combination for SD content (PAL)
        if ($colorSpace -eq "bt470bg" -and $colorTransfer -eq "bt470bg" -and $colorPrimaries -eq "bt470bg") {
            return "bt601-625"
        }
        # Combination for SD content (NTSC)
        elseif ($colorSpace -in @("smpte170m", "bt470bg") -and $colorTransfer -eq "smpte170m" -and $colorPrimaries -in @("smpte170m", "bt470bg")) {
            return "bt601-525"
        }
        # HD content
        elseif ($colorSpace -eq "bt709" -and $colorTransfer -eq "bt709" -and $colorPrimaries -eq "bt709") {
            return "bt709"
        }
        # HDR10
        elseif ($colorSpace -eq "bt2020nc" -and $colorTransfer -eq "smpte2084" -and $colorPrimaries -eq "bt2020") {
            return "bt2020-pq"
        }
        # HLG
        elseif ($colorSpace -eq "bt2020nc" -and $colorTransfer -eq "arib-std-b67" -and $colorPrimaries -eq "bt2020") {
            return "bt2020-hlg"
        }
        else {
            # For unknown combinations, assume HD content
            return "bt709"
        }
    }

    $targetColorSpace = Get-TargetColorSpace -colorSpace $ffprobeOutputColorSpace -colorTransfer $ffprobeOutputColorTransfer -colorPrimaries $ffprobeOutputColorPrimaries

    # Get video FPS
    Write-Host "Detecting FPS..."

    $fpsString = &$ffprobePath -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $file
    $fpsParts = $fpsString.Split('/')
    $fps = [math]::Round([double]$fpsParts[0] / [double]$fpsParts[1])

    Write-Host "Detected FPS: $fps" -ForegroundColor Green

    # Calculate keyint parameters
    $minKeyint = $fps      # 1 second * fps
    $keyint = $fps * 10    # 10 seconds * fps

    # Determine pixel format based on color space and bit depth
    $pixFmt = switch ($targetColorSpace) {
        "bt2020-pq" { "yuv420p10le" }  # HDR10 requires 10-bit
        "bt2020-hlg" { "yuv420p10le" } # HLG requires 10-bit
        "iphone-dolby-vision" { "yuv420p10le" } # Dolby Vision requires 10-bit
        default { "yuv420p" }  # For SDR content, 8-bit is sufficient
    }

    # Базовые параметры x265
    $baseX265Params = "ref=4:bframes=8:psy-rd=2.0:aq-mode=2:aq-strength=1.0:qcomp=0.7:rc-lookahead=60:ctu=64:tu-inter-depth=4:tu-intra-depth=4:limit-tu=3:sao=1:selective-sao=2:no-sao-non-deblock=1:no-early-skip=1:hist-scenecut=1:no-cutree=1"

    # Базовые параметры ab-av1
    $abav1Args = @(
        "auto-encode",
        "-i", $file,
        "-o", $outputFile,
        "--encoder", "libx265",
        "--preset", "veryslow",
        "--min-vmaf", "90",
        "--pix-format", $pixFmt
    )

    # Добавляем цветовые параметры через --enc
    $x265Params = switch ($targetColorSpace) {
        "bt601-625" { 
            Write-Host "SD content (PAL) detected. Converting to BT.709."
            "--enc", "x265-params=$($colorParams):range=$($colorRange):min-keyint=$($minKeyint):keyint=$($keyint):$($baseX265Params)"
        }
        "bt601-525" { 
            Write-Host "SD content (NTSC) detected. Converting to BT.709."
            "--enc", "x265-params=$($colorParams):range=$($colorRange):min-keyint=$($minKeyint):keyint=$($keyint):$($baseX265Params)"
        }
        "bt709" { 
            Write-Host "HD content detected. No color conversion needed." -ForegroundColor Green
            "--enc", "x265-params=colorprim=bt709:transfer=bt709:colormatrix=bt709:range=$($colorRange):min-keyint=$($minKeyint):keyint=$($keyint):$($baseX265Params)"
        }
        "bt2020-pq" { 
            Write-Host "HDR10 content detected."
            "--enc", "x265-params=colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=$($colorRange):min-keyint=$($minKeyint):keyint=$($keyint):hdr-opt=1:max-cll=1000,400:$($baseX265Params)"
        }
        "bt2020-hlg" { 
            Write-Host "HLG content detected."
            "--enc", "x265-params=colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=$($colorRange):min-keyint=$($minKeyint):keyint=$($keyint):$($baseX265Params)"
        }
        "iphone-dolby-vision" { 
            Write-Host "iPhone Dolby Vision (Profile 8.4) detected. Converting to HDR10..."
            "--enc", "x265-params=colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=$($colorRange):min-keyint=$($minKeyint):keyint=$($keyint):hdr-opt=1:max-cll=1000,400:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):$($baseX265Params)"
        }
    }

    # Добавляем параметры к основной команде
    $abav1Args += $x265Params
    $abav1Args += @("--acodec", "copy")

    # Execute ab-av1 command
    try {
        $abav1Path = Join-Path $AbAv1Dir "ab-av1.exe"
        Write-Host "Executing ab-av1 command: $abav1Path $($abav1Args -join ' ')"
        & $abav1Path $abav1Args
        if ($LASTEXITCODE -ne 0) {
            throw "ab-av1 finished with error code $LASTEXITCODE"
        }
    } catch {
        Write-Host "Error processing file $file : $_" -ForegroundColor Red
    }
}

# Recursively iterate through all files with extensions .mp4, .mov, and .avi in the folder and its subdirectories
Get-ChildItem -Recurse -Path $InputDir -Include "*.mp4", "*.mov", "*.avi" | ForEach-Object {
    Process-File $_.FullName
}
