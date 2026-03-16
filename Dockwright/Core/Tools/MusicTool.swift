import Foundation
import os

nonisolated private let musicLogger = Logger(subsystem: "com.dockwright", category: "MusicTool")

/// LLM tool for controlling Music.app and Spotify via AppleScript.
/// Actions: now_playing, play, pause, next, previous, volume, search_play, queue, shuffle, repeat_mode.
nonisolated struct MusicTool: Tool, @unchecked Sendable {
    let name = "music"
    let description = "Control music playback: get now playing info, play/pause, skip tracks, adjust volume, search and play songs, view queue, and toggle shuffle/repeat. Supports Music.app and Spotify."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: now_playing, play, pause, next, previous, volume, search_play, queue, shuffle, repeat_mode",
        ] as [String: Any],
        "volume_level": [
            "type": "integer",
            "description": "Volume level 0-100 (for volume action; omit to get current volume)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query — song, artist, or album name (for search_play)",
            "optional": true,
        ] as [String: Any],
        "player": [
            "type": "string",
            "description": "Music player to control: music or spotify (default: music)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: now_playing, play, pause, next, previous, volume, search_play, queue, shuffle, repeat_mode",
                isError: true
            )
        }

        let player = detectPlayer(arguments)

        switch action {
        case "now_playing":
            return await nowPlaying(player)
        case "play":
            return await play(player)
        case "pause":
            return await pause(player)
        case "next":
            return await nextTrack(player)
        case "previous":
            return await previousTrack(player)
        case "volume":
            return await volume(arguments, player: player)
        case "search_play":
            return await searchPlay(arguments, player: player)
        case "queue":
            return await showQueue(player)
        case "shuffle":
            return await toggleShuffle(player)
        case "repeat_mode":
            return await toggleRepeat(player)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: now_playing, play, pause, next, previous, volume, search_play, queue, shuffle, repeat_mode",
                isError: true
            )
        }
    }

    // MARK: - Player Detection

    private enum Player: String {
        case music = "Music"
        case spotify = "Spotify"
    }

    private func detectPlayer(_ args: [String: Any]) -> Player {
        if let explicit = args["player"] as? String {
            if explicit.lowercased() == "spotify" { return .spotify }
        }
        return .music
    }

    // MARK: - AppleScript Runner

    private func runAppleScript(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            musicLogger.error("AppleScript failed: \(errStr)")
            throw MusicToolError.scriptFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Actions

    private func nowPlaying(_ player: Player) async -> ToolResult {
        let script: String
        switch player {
        case .music:
            script = """
            tell application "Music"
                if player state is not playing and player state is not paused then
                    return "No track currently loaded."
                end if
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set playerState to player state as string
                set mins to (trackDuration div 60) as integer
                set secs to (trackDuration mod 60) as integer
                set posMin to (trackPosition div 60) as integer
                set posSec to (trackPosition mod 60) as integer
                return "Track: " & trackName & "\\nArtist: " & trackArtist & "\\nAlbum: " & trackAlbum & "\\nDuration: " & mins & ":" & text -2 thru -1 of ("0" & secs) & "\\nPosition: " & posMin & ":" & text -2 thru -1 of ("0" & posSec) & "\\nState: " & playerState
            end tell
            """
        case .spotify:
            script = """
            tell application "Spotify"
                if player state is stopped then
                    return "No track currently loaded."
                end if
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to (duration of current track) / 1000
                set trackPosition to player position
                set playerState to player state as string
                set mins to (trackDuration div 60) as integer
                set secs to (trackDuration mod 60) as integer
                set posMin to (trackPosition div 60) as integer
                set posSec to (trackPosition mod 60) as integer
                return "Track: " & trackName & "\\nArtist: " & trackArtist & "\\nAlbum: " & trackAlbum & "\\nDuration: " & mins & ":" & text -2 thru -1 of ("0" & secs) & "\\nPosition: " & posMin & ":" & text -2 thru -1 of ("0" & posSec) & "\\nState: " & playerState
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] Now Playing:\n\(result)")
        } catch {
            return ToolResult("Failed to get now playing from \(player.rawValue): \(error.localizedDescription)", isError: true)
        }
    }

    private func play(_ player: Player) async -> ToolResult {
        let script = "tell application \"\(player.rawValue)\" to play"
        do {
            _ = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] Playback started.")
        } catch {
            return ToolResult("Failed to play: \(error.localizedDescription)", isError: true)
        }
    }

    private func pause(_ player: Player) async -> ToolResult {
        let script = "tell application \"\(player.rawValue)\" to pause"
        do {
            _ = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] Playback paused.")
        } catch {
            return ToolResult("Failed to pause: \(error.localizedDescription)", isError: true)
        }
    }

    private func nextTrack(_ player: Player) async -> ToolResult {
        let script = "tell application \"\(player.rawValue)\" to next track"
        do {
            _ = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] Skipped to next track.")
        } catch {
            return ToolResult("Failed to skip: \(error.localizedDescription)", isError: true)
        }
    }

    private func previousTrack(_ player: Player) async -> ToolResult {
        let command = player == .spotify ? "previous track" : "back track"
        let script = "tell application \"\(player.rawValue)\" to \(command)"
        do {
            _ = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] Went to previous track.")
        } catch {
            return ToolResult("Failed to go back: \(error.localizedDescription)", isError: true)
        }
    }

    private func volume(_ args: [String: Any], player: Player) async -> ToolResult {
        if let level = args["volume_level"] as? Int {
            let clamped = max(0, min(100, level))
            let script = "tell application \"\(player.rawValue)\" to set sound volume to \(clamped)"
            do {
                _ = try await runAppleScript(script)
                return ToolResult("[\(player.rawValue)] Volume set to \(clamped).")
            } catch {
                return ToolResult("Failed to set volume: \(error.localizedDescription)", isError: true)
            }
        } else {
            let script = "tell application \"\(player.rawValue)\" to return sound volume"
            do {
                let result = try await runAppleScript(script)
                return ToolResult("[\(player.rawValue)] Current volume: \(result)")
            } catch {
                return ToolResult("Failed to get volume: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func searchPlay(_ args: [String: Any], player: Player) async -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search_play", isError: true)
        }

        let escaped = escapeForAppleScript(query)

        let script: String
        switch player {
        case .music:
            script = """
            tell application "Music"
                set searchResults to search playlist "Library" for "\(escaped)"
                if (count of searchResults) = 0 then
                    return "No results found for: \(escaped)"
                end if
                set firstResult to item 1 of searchResults
                play firstResult
                set trackName to name of firstResult
                set trackArtist to artist of firstResult
                return "Playing: " & trackName & " by " & trackArtist
            end tell
            """
        case .spotify:
            script = """
            tell application "Spotify"
                activate
                delay 0.5
                tell application "System Events"
                    tell process "Spotify"
                        keystroke "l" using command down
                        delay 0.3
                        keystroke "\(escaped)"
                        delay 1
                        key code 36
                    end tell
                end tell
                delay 2
                set trackName to name of current track
                set trackArtist to artist of current track
                return "Playing: " & trackName & " by " & trackArtist
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] \(result)")
        } catch {
            return ToolResult("Failed to search and play: \(error.localizedDescription)", isError: true)
        }
    }

    private func showQueue(_ player: Player) async -> ToolResult {
        let script: String
        switch player {
        case .music:
            script = """
            tell application "Music"
                if player state is not playing and player state is not paused then
                    return "No track currently loaded."
                end if
                set currentName to name of current track
                set currentArtist to artist of current track
                set output to "Now Playing: " & currentName & " by " & currentArtist & "\\n\\nUp Next:\\n"
                try
                    set nextTracks to tracks of current playlist
                    set trackCount to count of nextTracks
                    if trackCount > 10 then set trackCount to 10
                    repeat with i from 1 to trackCount
                        set t to item i of nextTracks
                        set output to output & "  " & i & ". " & name of t & " — " & artist of t & "\\n"
                    end repeat
                on error
                    set output to output & "  [Queue details unavailable]"
                end try
                return output
            end tell
            """
        case .spotify:
            script = """
            tell application "Spotify"
                if player state is stopped then
                    return "No track currently loaded."
                end if
                set currentName to name of current track
                set currentArtist to artist of current track
                return "Now Playing: " & currentName & " by " & currentArtist & "\\n\\nUp Next:\\n  [Spotify queue details require Spotify API]"
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] Queue:\n\(result)")
        } catch {
            return ToolResult("Failed to get queue: \(error.localizedDescription)", isError: true)
        }
    }

    private func toggleShuffle(_ player: Player) async -> ToolResult {
        let script: String
        switch player {
        case .music:
            script = """
            tell application "Music"
                set shuffle enabled to not shuffle enabled
                if shuffle enabled then
                    return "Shuffle: ON"
                else
                    return "Shuffle: OFF"
                end if
            end tell
            """
        case .spotify:
            script = """
            tell application "Spotify"
                set shuffling to not shuffling
                if shuffling then
                    return "Shuffle: ON"
                else
                    return "Shuffle: OFF"
                end if
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] \(result)")
        } catch {
            return ToolResult("Failed to toggle shuffle: \(error.localizedDescription)", isError: true)
        }
    }

    private func toggleRepeat(_ player: Player) async -> ToolResult {
        let script: String
        switch player {
        case .music:
            script = """
            tell application "Music"
                if song repeat is off then
                    set song repeat to all
                    return "Repeat: ALL"
                else if song repeat is all then
                    set song repeat to one
                    return "Repeat: ONE"
                else
                    set song repeat to off
                    return "Repeat: OFF"
                end if
            end tell
            """
        case .spotify:
            script = """
            tell application "Spotify"
                if repeating then
                    set repeating to false
                    return "Repeat: OFF"
                else
                    set repeating to true
                    return "Repeat: ON"
                end if
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(player.rawValue)] \(result)")
        } catch {
            return ToolResult("Failed to toggle repeat: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum MusicToolError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "Music tool error: \(msg)"
        }
    }
}
