---
name: Discord Controller
description: Send messages, react, and manage Discord channels via webhooks and API
requires: shell, memory, scheduler
stars: 51
author: steipete
---

# Discord Controller

You interact with Discord using webhooks and the Discord API via curl.

## Setup

### Webhook Setup (Easiest - No Bot Token Required)
1. Ask the user for their Discord webhook URL.
   - In Discord: Server Settings > Integrations > Webhooks > New Webhook > Copy URL.
2. Store it with `memory` tool for future use.

### Bot Token Setup (Full API Access)
1. Guide user to https://discord.com/developers/applications to create an app.
2. Get the bot token from Bot section.
3. Store with `memory` tool.

## Webhook Operations

### Send a Message
Use `shell` tool:
```
curl -s -X POST "WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hello from Dockwright!"}'
```

### Send a Rich Embed
```
curl -s -X POST "WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "embeds": [{
      "title": "Status Update",
      "description": "Everything is running smoothly.",
      "color": 3066993,
      "fields": [
        {"name": "Uptime", "value": "99.9%", "inline": true},
        {"name": "Load", "value": "Low", "inline": true}
      ],
      "footer": {"text": "Sent by Dockwright"},
      "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
    }]
  }'
```

### Send with Username Override
```
curl -s -X POST "WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content": "Alert!", "username": "Dockwright Bot", "avatar_url": "https://example.com/avatar.png"}'
```

## Bot API Operations (Requires Bot Token)

### Send a Message to a Channel
```
curl -s -X POST "https://discord.com/api/v10/channels/CHANNEL_ID/messages" \
  -H "Authorization: Bot TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hello!"}'
```

### Read Messages from a Channel
```
curl -s "https://discord.com/api/v10/channels/CHANNEL_ID/messages?limit=10" \
  -H "Authorization: Bot TOKEN" | python3 -m json.tool
```

### Add a Reaction
```
curl -s -X PUT "https://discord.com/api/v10/channels/CHANNEL_ID/messages/MESSAGE_ID/reactions/EMOJI/@me" \
  -H "Authorization: Bot TOKEN"
```

### List Channels in a Server
```
curl -s "https://discord.com/api/v10/guilds/GUILD_ID/channels" \
  -H "Authorization: Bot TOKEN" | python3 -m json.tool
```

## Scheduled Messages
Use `scheduler` tool to send messages on a schedule:
- Daily standup reminders.
- Weekly digest posts.
- Recurring announcements.

Example: "Send a standup reminder to #dev every weekday at 9am"
1. Create a cron job with schedule "0 9 * * 1-5".
2. Action: execute webhook with the reminder message.

## Message Formatting
Discord supports markdown:
- **Bold**: `**text**`
- *Italic*: `*text*`
- Code: `` `code` ``
- Code block: ` ```language\ncode\n``` `
- Mentions: `<@USER_ID>`, `<#CHANNEL_ID>`, `<@&ROLE_ID>`
- Emoji: `:emoji_name:` or Unicode emoji directly.
