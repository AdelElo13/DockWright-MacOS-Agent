-- ═══════════════════════════════════════════════════════════════
-- Dockwright TikTok Demo Script
-- Run with: osascript /Users/a/Dockwright/scripts/tiktok-demo.scpt
--
-- BEFORE RUNNING:
-- 1. Open Dockwright (main window)
-- 2. Start screen recording (Cmd+Shift+5)
-- 3. Run this script
-- 4. Stop recording when done (~90 seconds)
-- ═══════════════════════════════════════════════════════════════

on typeSlowly(theText, delayPerChar)
	tell application "System Events"
		repeat with i from 1 to length of theText
			keystroke (character i of theText)
			delay delayPerChar
		end repeat
	end tell
end typeSlowly

on pressEnter()
	tell application "System Events"
		keystroke return
	end tell
end pressEnter

-- ═══════════════════════════════════════════════════════════════
-- SCENE 1: Email check
-- ═══════════════════════════════════════════════════════════════
tell application "Dockwright" to activate
delay 2

tell application "System Events"
	tell process "Dockwright"
		click text field 1 of window 1
	end tell
end tell
delay 0.5

my typeSlowly("Check my emails", 0.04)
delay 1
my pressEnter()
delay 12

-- ═══════════════════════════════════════════════════════════════
-- SCENE 2: Calendar
-- ═══════════════════════════════════════════════════════════════
tell application "System Events"
	keystroke "n" using command down
end tell
delay 1

my typeSlowly("What's on my calendar today?", 0.04)
delay 1
my pressEnter()
delay 10

-- ═══════════════════════════════════════════════════════════════
-- SCENE 3: Music control
-- ═══════════════════════════════════════════════════════════════
tell application "System Events"
	keystroke "n" using command down
end tell
delay 1

my typeSlowly("Play some lo-fi music on Spotify", 0.04)
delay 1
my pressEnter()
delay 10

-- ═══════════════════════════════════════════════════════════════
-- SCENE 4: Screen awareness
-- ═══════════════════════════════════════════════════════════════
tell application "Safari"
	activate
	open location "https://dockwright.com"
end tell
delay 3

tell application "Dockwright" to activate
delay 1

tell application "System Events"
	keystroke "n" using command down
end tell
delay 1

my typeSlowly("What do you see on my screen?", 0.04)
delay 1
my pressEnter()
delay 10

-- ═══════════════════════════════════════════════════════════════
-- SCENE 5: System info
-- ═══════════════════════════════════════════════════════════════
tell application "System Events"
	keystroke "n" using command down
end tell
delay 1

my typeSlowly("How's my system doing? Battery, CPU, memory?", 0.04)
delay 1
my pressEnter()
delay 8

-- ═══════════════════════════════════════════════════════════════
-- SCENE 6: Menu bar panel
-- ═══════════════════════════════════════════════════════════════
tell application "System Events"
	keystroke space using {command down, shift down}
end tell
delay 2

my typeSlowly("Remind me in 5 minutes to grab coffee", 0.04)
delay 1
my pressEnter()
delay 8

-- ═══════════════════════════════════════════════════════════════
-- SCENE 7: Quick hello
-- ═══════════════════════════════════════════════════════════════
tell application "System Events"
	keystroke space using {command down, shift down}
end tell
delay 1

tell application "Dockwright" to activate
delay 1

tell application "System Events"
	keystroke "n" using command down
end tell
delay 1

my typeSlowly("Hey Dockwright, what can you do?", 0.04)
delay 1
my pressEnter()
delay 8

-- ═══════════════════════════════════════════════════════════════
-- END
-- ═══════════════════════════════════════════════════════════════
display notification "Demo recording done! Stop your screen recording." with title "Dockwright Demo"
