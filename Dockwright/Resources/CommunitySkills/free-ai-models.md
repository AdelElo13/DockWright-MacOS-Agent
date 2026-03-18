---
name: Free AI Models Gateway
description: Use free AI models from OpenRouter as fallback when primary model is unavailable
requires: shell, memory, file
stars: 291
author: Shaivpidadi
---

# Free AI Models Gateway

You help users access free AI models via OpenRouter as a fallback or alternative to paid API keys.

## Setup

### Get OpenRouter API Key (Free Tier Available)
1. Guide user to https://openrouter.ai/keys
2. Create a free account and generate an API key.
3. Store with `memory` tool for future use.

## Available Free Models

OpenRouter offers several free models. Check current availability:
```
curl -s https://openrouter.ai/api/v1/models | python3 -c "
import json, sys
data = json.load(sys.stdin)
free = [m for m in data['data'] if float(m.get('pricing', {}).get('prompt', '1')) == 0]
for m in sorted(free, key=lambda x: x['id']):
    print(f'{m[\"id\"]}')
    print(f'  Context: {m.get(\"context_length\", \"?\")} tokens')
    print()
" 2>/dev/null
```

### Common Free Models (availability varies)
- `meta-llama/llama-3-8b-instruct:free` — Good general purpose.
- `google/gemma-2-9b-it:free` — Google's efficient model.
- `mistralai/mistral-7b-instruct:free` — Fast and capable.
- `qwen/qwen-2-7b-instruct:free` — Strong multilingual support.

## Making API Calls

### Chat Completion
Use `shell` tool:
```
curl -s https://openrouter.ai/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer OPENROUTER_KEY" \
  -d '{
    "model": "meta-llama/llama-3-8b-instruct:free",
    "messages": [
      {"role": "user", "content": "YOUR PROMPT HERE"}
    ]
  }' | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data['choices'][0]['message']['content'])
"
```

### Streaming Response
```
curl -s -N https://openrouter.ai/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer OPENROUTER_KEY" \
  -d '{
    "model": "meta-llama/llama-3-8b-instruct:free",
    "messages": [{"role": "user", "content": "YOUR PROMPT"}],
    "stream": true
  }'
```

## Use Cases

### Batch Processing
When the user needs to process many items and wants to save costs:
1. Use free models for bulk classification, summarization, or extraction.
2. Write a shell script that loops through items.
3. Save results to a file.

### Model Comparison
Help the user compare outputs from different free models:
1. Send the same prompt to 3-4 free models.
2. Present outputs side by side.
3. Let the user judge quality for their use case.

### Fallback Chain
Configure a priority order of models:
1. Primary: User's main model (e.g., Claude via Dockwright).
2. Fallback 1: Best free model on OpenRouter.
3. Fallback 2: Alternative free model.
If the primary model is rate-limited or unavailable, suggest using the free fallback.

### Local Model Integration
If the user has Ollama installed:
```
# Check if Ollama is running
curl -s http://localhost:11434/api/tags | python3 -m json.tool

# List installed models
curl -s http://localhost:11434/api/tags | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('models', []):
    print(f'{m[\"name\"]} ({m[\"size\"] / 1e9:.1f}GB)')
"

# Chat with local model
curl -s http://localhost:11434/api/chat -d '{
  "model": "llama3",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": false
}' | python3 -c "import json,sys; print(json.load(sys.stdin)['message']['content'])"
```

## Cost Monitoring
Track usage across models:
- OpenRouter provides usage stats in response headers.
- Log each API call's model and token count with `memory` tool.
- Periodically summarize usage and costs.

## Tips
- Free models have rate limits — add delays between rapid requests.
- Free model quality varies — test with your specific use case.
- Some "free" models may have daily token limits.
- Check https://openrouter.ai/models for current free model availability.
