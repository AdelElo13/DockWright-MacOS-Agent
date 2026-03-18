---
name: Security Scan
description: Scan installed apps and files for security vulnerabilities and integrity issues
requires: shell, file, notification
stars: 79
author: aigsec
---

# Security Scan

You scan installed applications and files on macOS for security issues including code signature validation, suspicious modifications, and known vulnerabilities.

## App Integrity Scan

### 1. Code Signature Verification
Use `shell` tool to check app signatures:
- `codesign -vv /Applications/*.app 2>&1` — verify all apps in /Applications.
- For a specific app: `codesign -dvvv "/Applications/AppName.app" 2>&1`
- Flag apps where verification fails or signatures are missing.

### 2. Notarization Check
Use `shell` tool:
- `spctl -a -vv "/Applications/AppName.app" 2>&1` — check if app is notarized by Apple.
- Apps from the Mac App Store are automatically notarized.
- Flag apps that are neither notarized nor from the App Store.

### 3. Quarantine Attribute Check
Use `shell` tool:
- `xattr -l "/Applications/AppName.app" 2>/dev/null | grep quarantine` — check if quarantine flag is present.
- Recently downloaded apps should have this attribute.

## File System Scan

### 4. Recently Modified System Files
Use `shell` tool:
- `find /usr/local/bin -mtime -7 -type f 2>/dev/null` — files modified in last 7 days.
- `find /Library -mtime -3 -type f -name "*.plist" 2>/dev/null | head -20` — recently changed plists.
- Flag unexpected modifications to system directories.

### 5. Suspicious Executables
Use `shell` tool:
- `find ~/Downloads -type f -perm +111 -mtime -30 2>/dev/null` — executable files in Downloads from last 30 days.
- `find /tmp -type f -perm +111 2>/dev/null` — executables in /tmp.
- Check for scripts or binaries in unusual locations.

### 6. Hidden Files in User Directories
Use `shell` tool:
- `find ~ -maxdepth 2 -name ".*" -not -name ".DS_Store" -not -name ".Trash" -not -name ".config" -not -name ".ssh" -not -name ".zshrc" -not -name ".gitconfig" -newer /tmp -type f 2>/dev/null | head -20`
- Flag recently created hidden files that don't match common dotfiles.

### 7. Cron Jobs and Scheduled Tasks
Use `shell` tool:
- `crontab -l 2>/dev/null` — user crontab.
- `sudo crontab -l 2>/dev/null` — root crontab (if accessible).
- `at -l 2>/dev/null` — scheduled at jobs.
- Cross-reference with launch agents for completeness.

### 8. Browser Extension Audit
Use `shell` tool:
- Chrome: `ls ~/Library/Application\ Support/Google/Chrome/Default/Extensions/ 2>/dev/null`
- Safari: `pluginkit -m -p com.apple.Safari.extension 2>/dev/null`
- List installed extensions and flag any that are unrecognized.

## Vulnerability Check

### 9. Known Vulnerable Software
Use `shell` tool:
- `brew list --versions 2>/dev/null` — list all Homebrew packages with versions.
- `python3 --version 2>/dev/null` — check Python version.
- `node --version 2>/dev/null` — check Node.js version.
- `openssl version 2>/dev/null` — check OpenSSL version.
- Cross-reference major version numbers against known vulnerabilities.

## Report

Present a clean scan report:
- **PASS** — verified and secure
- **WARN** — potential concern, investigate further
- **FAIL** — definite security issue, action required

Include specific remediation steps for each finding.
