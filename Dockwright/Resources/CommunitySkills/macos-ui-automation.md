---
name: macOS UI Automation
description: Automate macOS UI interactions — click buttons, fill forms, navigate apps by description
requires: process_symbiosis, shell, screenshot, vision
stars: 55
author: steipete
---

# macOS UI Automation

You automate macOS user interface interactions using AppleScript, accessibility APIs, and visual recognition.

## Core Techniques

### 1. AppleScript UI Scripting
Use `shell` tool with osascript for UI automation:

**Click a button by name:**
```
osascript -e 'tell application "System Events" to tell process "AppName" to click button "OK" of window 1'
```

**Click a menu item:**
```
osascript -e 'tell application "System Events" to tell process "AppName" to click menu item "Save" of menu "File" of menu bar 1'
```

**Type text into a field:**
```
osascript -e 'tell application "System Events" to tell process "AppName" to set value of text field 1 of window 1 to "Hello"'
```

**Press keyboard shortcut:**
```
osascript -e 'tell application "System Events" to keystroke "s" using command down'
```

### 2. Process Symbiosis
Use `process_symbiosis` tool for semantic UI interaction:
- Describe the action in natural language: "Click the Send button in Mail"
- The tool translates to accessibility API calls.
- Works across applications without app-specific scripting.

### 3. Visual Automation
When UI elements can't be found by accessibility:
1. Use `screenshot` tool to capture the screen.
2. Use `vision` tool to OCR and locate the target element.
3. Use `shell` tool with cliclick or AppleScript to click at coordinates.

**Click at coordinates (requires cliclick):**
```
cliclick c:500,300
```

**Or with AppleScript:**
```
osascript -e 'tell application "System Events" to click at {500, 300}'
```

## Common Automations

### Open and Navigate Apps
```
osascript -e 'tell application "Safari" to activate'
osascript -e 'tell application "Safari" to open location "https://example.com"'
```

### Window Management
```
# Resize window
osascript -e 'tell application "Finder" to set bounds of window 1 to {0, 0, 800, 600}'

# Move window
osascript -e 'tell application "System Events" to tell process "AppName" to set position of window 1 to {100, 100}'

# Minimize
osascript -e 'tell application "System Events" to tell process "AppName" to set value of attribute "AXMinimized" of window 1 to true'
```

### Form Filling
1. Activate the target application.
2. Tab through fields or click specific text fields.
3. Set values using `set value of text field`.
4. Handle dropdowns with `click pop up button` then `click menu item`.

### File Dialogs
```
# Handle Save dialog
osascript -e '
tell application "System Events"
    tell process "AppName"
        keystroke "g" using {command down, shift down}
        delay 0.5
        keystroke "/path/to/file"
        keystroke return
        delay 0.5
        click button "Save" of window 1
    end tell
end tell'
```

## Discovery

### List UI Elements
To discover what UI elements exist in an app:
```
osascript -e 'tell application "System Events" to tell process "AppName" to get entire contents of window 1'
```

### Get Element Properties
```
osascript -e 'tell application "System Events" to tell process "AppName" to get properties of button 1 of window 1'
```

## Safety
- Always confirm destructive actions with the user.
- Add delays between UI steps to let the interface update.
- Check that the target app is in the expected state before acting.
- Use `screenshot` tool to verify results after automation.
