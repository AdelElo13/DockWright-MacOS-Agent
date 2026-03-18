---
name: Video Transcript Extractor
description: Download videos and extract transcripts using yt-dlp and subtitle tools
requires: shell, file
stars: 47
author: steipete
---

# Video Transcript Extractor

You download videos and extract clean transcripts using yt-dlp and related tools.

## Setup
Check for required tools:
- `shell` tool: `which yt-dlp || echo "NOT INSTALLED"`
- If not installed: `brew install yt-dlp` or `pip3 install yt-dlp`
- Also check: `which ffmpeg || echo "NOT INSTALLED"` (needed for some operations)
- If not installed: `brew install ffmpeg`

## Extract Transcript (Subtitles Only - No Download)

### From YouTube (fastest method)
Use `shell` tool:
```
yt-dlp --write-auto-sub --sub-lang en --skip-download --sub-format vtt -o "/tmp/transcript" "VIDEO_URL" 2>&1
```
Then read and clean the VTT file:
```
python3 -c "
import re
with open('/tmp/transcript.en.vtt') as f:
    text = f.read()
# Remove VTT headers and timestamps
lines = text.split('\n')
clean = []
seen = set()
for line in lines:
    if line.strip() and not line.startswith('WEBVTT') and not line.startswith('Kind:') and not line.startswith('Language:') and not re.match(r'^\d{2}:\d{2}', line) and not re.match(r'^\d+$', line):
        # Remove HTML tags
        line = re.sub(r'<[^>]+>', '', line).strip()
        if line and line not in seen:
            seen.add(line)
            clean.append(line)
print(' '.join(clean))
"
```

### List Available Subtitles
```
yt-dlp --list-subs "VIDEO_URL" 2>&1
```

### Download Specific Language Subtitles
```
yt-dlp --write-sub --sub-lang nl --skip-download --sub-format vtt -o "/tmp/transcript" "VIDEO_URL"
```

## Download Video + Extract Audio Transcript

### Download Audio Only
```
yt-dlp -x --audio-format mp3 -o "/tmp/audio.%(ext)s" "VIDEO_URL"
```

### Transcribe with Whisper (if installed)
```
whisper /tmp/audio.mp3 --model base --output_dir /tmp/whisper_out --output_format txt
```

## Download Full Video
```
yt-dlp -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]" -o "~/Downloads/%(title)s.%(ext)s" "VIDEO_URL"
```

## Batch Processing
For multiple videos, create a text file with one URL per line:
```
yt-dlp --write-auto-sub --sub-lang en --skip-download -o "/tmp/%(title)s" -a urls.txt
```

## Transcript Cleanup
After extracting raw subtitles, clean them up:
- Remove duplicate lines (auto-subs often repeat).
- Join broken sentences.
- Add paragraph breaks at natural pauses (gaps > 3 seconds).
- Remove filler words if requested: "um", "uh", "like", "you know".

## Output Options
- Save as plain text: `file` tool to write `.txt`.
- Save as markdown with timestamps: include `[MM:SS]` markers.
- Save as SRT for re-use as subtitles.
- Copy to clipboard: `shell` tool with `pbcopy`.

## Supported Platforms
yt-dlp supports 1000+ sites including:
- YouTube, Vimeo, Dailymotion
- Twitter/X, Instagram, TikTok
- Twitch (VODs and clips)
- Many news sites and podcast platforms
