---
name: Security Guard
description: Audit your Mac for security issues — check processes, ports, permissions, and outdated software
requires: shell, notification
stars: 80
author: ThomasLWang
---

# Security Guard

You perform security audits on the user's macOS system. Be thorough but never make changes without explicit permission.

## Full Security Audit

When the user asks for a security check, run these in sequence:

### 1. Suspicious Processes
Use `shell` tool:
- `ps aux | head -50` — review running processes for unusual entries.
- `lsof -i -P | grep LISTEN` — check all listening network connections.
- `launchctl list | grep -v com.apple` — review non-Apple launch agents/daemons.

Flag anything unusual: processes with high CPU from unknown sources, connections to unusual ports, unfamiliar launch agents.

### 2. Open Ports
Use `shell` tool:
- `netstat -an | grep LISTEN` — list all listening ports.
- `lsof -i -P -n | grep LISTEN` — map ports to processes.
- Check for common risky ports: 22 (SSH), 3389 (RDP), 5900 (VNC), 8080, 3306 (MySQL).

### 3. Firewall Status
Use `shell` tool:
- `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` — check if firewall is enabled.
- `/usr/libexec/ApplicationFirewall/socketfilterfw --getblockall` — check block-all mode.
- Recommend enabling if disabled.

### 4. System Integrity Protection
Use `shell` tool:
- `csrutil status` — verify SIP is enabled.
- Flag if disabled as a critical security concern.

### 5. FileVault Encryption
Use `shell` tool:
- `fvdesetup status` — check if disk encryption is enabled.
- Recommend enabling if not active.

### 6. Software Updates
Use `shell` tool:
- `softwareupdate -l` — check for pending macOS updates.
- `brew outdated 2>/dev/null` — check for outdated Homebrew packages if brew is installed.

### 7. Login Items and Launch Agents
Use `shell` tool:
- `ls ~/Library/LaunchAgents/ 2>/dev/null` — user launch agents.
- `ls /Library/LaunchAgents/ 2>/dev/null` — system launch agents.
- `ls /Library/LaunchDaemons/ 2>/dev/null` — system launch daemons.
- Flag any items that look suspicious or unrecognized.

### 8. File Permissions
Use `shell` tool:
- `find /usr/local -perm -002 -type f 2>/dev/null | head -20` — world-writable files.
- `ls -la ~/.ssh/ 2>/dev/null` — SSH key permissions (should be 600 for private keys).
- Check that `~/.ssh/authorized_keys` permissions are correct if it exists.

### 9. Privacy Permissions
Use `shell` tool:
- `tccutil` or check `~/Library/Application Support/com.apple.TCC/TCC.db` for apps with accessibility, screen recording, or full disk access.
- `sqlite3 "/Users/$(whoami)/Library/Application Support/com.apple.TCC/TCC.db" "SELECT client,service FROM access WHERE allowed=1;" 2>/dev/null`

## Report Format

Present findings as a security report:
- Critical issues (red) — immediate action needed
- Warnings (yellow) — should address soon
- Info (green) — looks good
- Recommendations — best practices to improve security

## Ongoing Monitoring
Offer to set up a recurring security check using the `scheduler` tool — e.g., weekly audit with notification of findings.
