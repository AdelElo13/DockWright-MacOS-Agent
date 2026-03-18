---
name: AI Image Generator
description: Generate and edit images using AI APIs like DALL-E and Stability AI
requires: shell, file, memory
stars: 221
author: steipete
---

# AI Image Generator

You generate and edit images using AI image generation APIs via curl.

## Setup

Ask the user which service they want to use and help them get an API key:

### OpenAI DALL-E
- Get API key at: https://platform.openai.com/api-keys
- Store with `memory` tool.

### Stability AI
- Get API key at: https://platform.stability.ai/account/keys
- Store with `memory` tool.

## DALL-E Image Generation

### Generate an Image
Use `shell` tool:
```
curl -s https://api.openai.com/v1/images/generations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer OPENAI_KEY" \
  -d '{
    "model": "dall-e-3",
    "prompt": "DESCRIPTION HERE",
    "n": 1,
    "size": "1024x1024",
    "quality": "standard"
  }' | python3 -c "
import json, sys, urllib.request
data = json.load(sys.stdin)
url = data['data'][0]['url']
revised = data['data'][0].get('revised_prompt', '')
print(f'Revised prompt: {revised}')
urllib.request.urlretrieve(url, '/tmp/generated_image.png')
print('Saved to /tmp/generated_image.png')
"
```

### Size Options (DALL-E 3)
- `1024x1024` — Square (default)
- `1792x1024` — Landscape
- `1024x1792` — Portrait

### Quality Options
- `standard` — Faster, cheaper
- `hd` — Higher detail

### Open the Result
```
open /tmp/generated_image.png
```

### Save to Desktop
```
cp /tmp/generated_image.png ~/Desktop/generated_$(date +%Y%m%d_%H%M%S).png
```

## Stability AI Image Generation

### Generate an Image
```
curl -s -X POST "https://api.stability.ai/v2beta/stable-image/generate/sd3" \
  -H "authorization: Bearer STABILITY_KEY" \
  -H "accept: image/*" \
  -F prompt="DESCRIPTION HERE" \
  -F output_format=png \
  -o /tmp/stability_image.png
```

## Image Editing

### DALL-E Edit (Inpainting)
Requires a source image and mask:
```
curl -s https://api.openai.com/v1/images/edits \
  -H "Authorization: Bearer OPENAI_KEY" \
  -F image="@/path/to/image.png" \
  -F mask="@/path/to/mask.png" \
  -F prompt="EDIT DESCRIPTION" \
  -F n=1 \
  -F size="1024x1024"
```

### DALL-E Variations
Generate variations of an existing image:
```
curl -s https://api.openai.com/v1/images/variations \
  -H "Authorization: Bearer OPENAI_KEY" \
  -F image="@/path/to/image.png" \
  -F n=2 \
  -F size="1024x1024"
```

## Prompt Engineering Tips

When crafting prompts, help the user with:
1. **Subject**: What is in the image.
2. **Style**: "digital art", "oil painting", "photograph", "watercolor", "3D render".
3. **Mood**: "dramatic lighting", "soft pastel colors", "high contrast".
4. **Composition**: "close-up", "wide angle", "birds eye view", "symmetrical".
5. **Details**: "highly detailed", "minimalist", "abstract".

## Batch Generation
For multiple images:
1. Generate variations on a theme.
2. Save each with a sequential filename.
3. Present all results for the user to choose.

## Cost Awareness
- DALL-E 3 Standard 1024x1024: ~$0.040/image
- DALL-E 3 HD 1024x1024: ~$0.080/image
- Stability SD3: varies by plan
- Always inform the user of approximate cost before generating.
