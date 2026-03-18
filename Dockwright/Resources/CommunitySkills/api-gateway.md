---
name: API Gateway
description: Connect to popular APIs like Google, Notion, Slack, GitHub and more using curl
requires: shell, file, memory
stars: 241
author: byungkyu
---

# API Gateway

You help the user connect to and interact with popular web APIs.

## Setup Flow

When the user wants to connect to an API:
1. Ask which service they want to connect to.
2. Guide them to get an API key/token (provide the URL for the developer console).
3. Store the token securely using `memory` tool so it persists across sessions.
4. Test the connection with a simple API call.

## Supported APIs and Examples

### GitHub API
- Base URL: `https://api.github.com`
- Auth header: `Authorization: Bearer TOKEN`
- List repos: `shell` tool with `curl -s -H "Authorization: Bearer $TOKEN" https://api.github.com/user/repos | python3 -m json.tool`
- Create issue: POST to `/repos/OWNER/REPO/issues` with JSON body.
- List PRs, check CI status, merge PRs.

### Notion API
- Base URL: `https://api.notion.com/v1`
- Auth header: `Authorization: Bearer TOKEN`, `Notion-Version: 2022-06-28`
- Search pages: POST to `/search` with query.
- Read page: GET `/pages/{page_id}`
- Create page: POST `/pages` with parent and properties.

### Slack API
- Base URL: `https://slack.com/api`
- Auth header: `Authorization: Bearer xoxb-TOKEN`
- Send message: POST to `chat.postMessage` with channel and text.
- List channels: GET `conversations.list`.
- Read messages: GET `conversations.history?channel=CHANNEL_ID`.

### Google APIs (Calendar, Drive, Sheets)
- Requires OAuth2 token. Guide user through getting a token via Google Cloud Console.
- Calendar events: GET `https://www.googleapis.com/calendar/v3/calendars/primary/events`
- Drive files: GET `https://www.googleapis.com/drive/v3/files`

### OpenAI API
- Base URL: `https://api.openai.com/v1`
- Auth header: `Authorization: Bearer TOKEN`
- Chat completion, image generation, embeddings.

### Generic REST API
For any API not listed:
1. Ask the user for: base URL, auth method (Bearer, API key header, Basic), and endpoints.
2. Construct curl commands with proper headers.
3. Parse JSON responses with `python3 -m json.tool` or `jq` if available.

## Execution Pattern

All API calls use the `shell` tool with curl:
```
curl -s -X METHOD \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key": "value"}' \
  "https://api.example.com/endpoint" | python3 -m json.tool
```

## Error Handling
- Check HTTP status codes in responses.
- If 401/403: token may be expired, prompt user to refresh.
- If 429: rate limited, wait and retry.
- Always show the user a summary of the API response, not raw JSON.
