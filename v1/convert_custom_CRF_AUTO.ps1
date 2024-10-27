# Specify paths to required tools
$FfmpegDir = "c:\FFMpeg\bin"
$AbAv1Dir = "c:\FFMpeg\ab-av1"
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
    $ffmpegPath = Join-Path $FfmpegDir "ffmpeg.exe"
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
        default { "limited" }  # If unable to determine, use limited as a safe default value
    }

    Write-Host "Selected color range: $colorRange"

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

    $colorConversion = ""
    $x265ColorParams = @()

    switch ($targetColorSpace) {
        "bt601-625" {
            Write-Host "SD content (PAL) detected. Converting to BT.709."
            $colorConversion = "-vf colorspace=all=bt709:iall=bt470bg:fast=1"
            $x265ColorParams = @("colorprim=bt709", "transfer=bt709", "colormatrix=bt709")
        }
        "bt601-525" {
            Write-Host "SD content (NTSC) detected. Converting to BT.709."
            $colorConversion = "-vf colorspace=all=bt709:iall=smpte170m:fast=1"
            $x265ColorParams = @("colorprim=bt709", "transfer=bt709", "colormatrix=bt709")
        }
        "bt709" {
            Write-Host "HD content detected. No color conversion needed."
            $x265ColorParams = @("colorprim=bt709", "transfer=bt709", "colormatrix=bt709")
        }
        "bt2020-pq" {
            Write-Host "HDR10 content detected. No color conversion applied."
            $x265ColorParams = @("colorprim=bt2020", "transfer=smpte2084", "colormatrix=bt2020nc", "hdr-opt=1", "max-cll=1000,400")
        }
        "bt2020-hlg" {
            Write-Host "HLG content detected. No color conversion applied."
            $x265ColorParams = @("colorprim=bt2020", "transfer=arib-std-b67", "colormatrix=bt2020nc")
        }
        "iphone-dolby-vision" {
            Write-Host "iPhone Dolby Vision (Profile 8.4) content detected. Converting to HDR10..."
            $colorConversion = ""  # No color space conversion needed for iPhone DV
            $x265ColorParams = @(
                "colorprim=bt2020",
                "transfer=smpte2084",
                "colormatrix=bt2020nc",
                "hdr-opt=1",
                "max-cll=1000,400",  # iPhone typically uses these values
                "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
            )
        }
        default {
            Write-Host "Unknown color space combination. Assuming HD content and converting to BT.709."
            $colorConversion = "-vf colorspace=all=bt709:iall=bt709:fast=1"
            $x265ColorParams = @("colorprim=bt709", "transfer=bt709", "colormatrix=bt709")
        }
    }

    # Get video FPS
    $fpsString = &$ffprobePath -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $file
    # Convert fraction to number (e.g., "24000/1001" to ~23.976)
    $fpsParts = $fpsString.Split('/')
    $fps = [math]::Round([double]$fpsParts[0] / [double]$fpsParts[1])

    Write-Host "Detected FPS: $fps"

    # Calculate keyint parameters
    $minKeyint = $fps      # 1 second * fps
    $keyint = $fps * 10    # 10 seconds * fps

    # Function to get optimal CRF using ab-av1
    function Get-OptimalCRF {
        param (
            [string]$inputFile
        )
        
        try {
            Write-Host "`n=== Starting CRF Analysis ===" -ForegroundColor Cyan
            
            # Add FFmpeg directory to PATH for this session
            $env:Path = "$FfmpegDir;$env:Path"
            
            Write-Host "`nChecking ab-av1 executable..."
            $abAv1Path = Join-Path $AbAv1Dir "ab-av1.exe"
            
            if (!(Test-Path $abAv1Path)) {
                Write-Host "ERROR: ab-av1.exe not found at: $abAv1Path" -ForegroundColor Red
                throw "ab-av1.exe not found at path: $abAv1Path"
            }
            Write-Host "ab-av1.exe found at: $abAv1Path" -ForegroundColor Green
            
            # Run ab-av1 crf-search to determine optimal CRF
            Write-Host "`nExecuting ab-av1 command..." -ForegroundColor Cyan
            $abAv1Params = @(
                "crf-search",
                "-i", $inputFile,
                "--encoder", "libx265",  # Changed from x265 to libx265
                "--min-vmaf", "90",
                "--min-crf", "18",
                "--max-crf", "28",
                "--preset", "veryslow"
            )

            Write-Host "Command: $abAv1Path $($abAv1Params -join ' ')"
            $abAv1Output = & $abAv1Path $abAv1Params 2>&1

            Write-Host "`nab-av1 Output:" -ForegroundColor Cyan
            $abAv1Output | ForEach-Object { Write-Host $_ }

            # Parse the output to get recommended CRF
            Write-Host "`nParsing ab-av1 output..."
            if ($abAv1Output -match "Best crf: (\d+\.?\d*)") {
                $crf = [double]$matches[1]
                Write-Host "Successfully parsed CRF value: $crf" -ForegroundColor Green
                return $crf
            } else {
                Write-Host "Could not find 'Best crf' in ab-av1 output" -ForegroundColor Red
                Write-Host "Using default CRF=22" -ForegroundColor Yellow
                return 22
            }
        }
        catch {
            Write-Host "`nError in Get-OptimalCRF:" -ForegroundColor Red
            Write-Host "Exception message: $_" -ForegroundColor Red
            Write-Host "Stack trace:" -ForegroundColor Red
            Write-Host $_.ScriptStackTrace -ForegroundColor Red
            Write-Host "Using default CRF=22" -ForegroundColor Yellow
            return 22
        }
    }

    # Get optimal CRF
    $optimalCRF = Get-OptimalCRF -inputFile $file
    
    # Basic custom codec parameters
    $commonX265Params = @(
        "crf=$optimalCRF",  # Use dynamically determined CRF
        "frame-threads=2", # Number of threads to use for frame-level processing. Default 0
        "rc-lookahead=60", # Number of frames to look ahead for rate control. Default 20, slow-slowest 40, placebo 60
        "qcomp=0.7", # Quantization compression factor. Default 0.6
        "ref=4",# frames of reference. Default 5. effect on the amount of work performed in motion search, but will generally have a beneficial affect on compression and distortion.
        "ctu=64", # Maximum CU size (width and height). Default: 64
        "bframes=8", # Maximum number of consecutive b-frames. Default 4. In slower veryslow placebo = 8
        "psy-rd=2.00", # add an extra cost to move blocks instead blur
        "rdoq-level=1", # RDOQ level. Default 1. For anime 2 ????High levels of psy-rdoq can double the bitrate which can have a drastic effect on rate control, forcing higher overall QP
        "aq-mode=2", # Adaptive quantization mode. 0=Disabled, 1=Fast, 2=Better
        "aq-strength=1.0", # Strength of adaptive quantization. Default 1.0
        "no-cutree=1", # improve detail in the backgrounds of video with less detail in areas of high motion. Default enabled
        #"min-keyint=24", # Minimum interval between IDR frames. Default 24
        #"keyint=240", # Maximum interval between IDR frames. Default 240
        "min-keyint=$minKeyint",    # Dynamic value
        "keyint=$keyint",           # Dynamic value
        "tu-inter-depth=4", # Maximum depth of inter-CU tree. Default 4
        "tu-intra-depth=4", # Maximum depth of intra-CU tree. Default 4
        "limit-tu=3", # Maximum number of transform units (TU) per CU. Default 3
        "no-strong-intra-smoothing=1", # Disable strong intra smoothing. Default enabled
        "sao=1",# Enable Sample Adaptive Offset. Default enabled
        "selective-sao=2", # Enable selective SAO. Default enabled
        "no-sao-non-deblock=1", # Disable SAO non-deblocking. Default enabled
        "no-early-skip=1", # Disable early skip. Default enabled
        "hist-scenecut=1" # Enable histogram-based scene cut detection. Default enabled
    )

    $x265Params = $commonX265Params + $x265ColorParams + @("range=$colorRange")

    # Combine x265 parameters into one string
    $x265ParamsString = $x265Params -join ":"

    # Execute FFmpeg command
    $ffmpegCommand = @(
        "-i", $file
    )

    # Add color conversion if necessary
    if ($colorConversion -ne "") {
        $ffmpegCommand += $colorConversion.Split(" ")
    }

    $ffmpegCommand += @(
        "-map_metadata", "0",
        "-movflags", "use_metadata_tags",
        "-c:v", "libx265",
        "-preset", "veryslow",
        "-x265-params", $x265ParamsString,
        "-c:a", "copy",
        $outputFile
    )

    # Output command for debugging
    Write-Host "FFmpeg command: $ffmpegPath $($ffmpegCommand -join ' ')"

    # Execute command and handle possible errors
    try {
        & $ffmpegPath $ffmpegCommand
        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg finished with error code $LASTEXITCODE"
        }
    } catch {
        Write-Host "Error processing file $file : $_" -ForegroundColor Red
    }
}

# Recursively iterate through all files with extensions .mp4, .mov, and .avi in the folder and its subdirectories
Get-ChildItem -Recurse -Path $InputDir -Include "*.mp4", "*.mov", "*.avi" | ForEach-Object {
    Process-File $_.FullName
}

