import Foundation

/// LLM tool for controlling macOS system settings.
/// Actions: volume, brightness, wifi, bluetooth, battery, dark_mode, do_not_disturb, sleep, lock, system_info.
nonisolated struct SystemControlTool: Tool, @unchecked Sendable {
    let name = "system_control"
    let description = "Control macOS system settings: volume, brightness, WiFi, Bluetooth, battery status, dark mode, Do Not Disturb, sleep, lock screen, and system info."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: volume, brightness, wifi, bluetooth, battery, dark_mode, do_not_disturb, sleep, lock, system_info",
        ] as [String: Any],
        "value": [
            "type": "integer",
            "description": "Value to set (0-100 for volume/brightness)",
            "optional": true,
        ] as [String: Any],
        "state": [
            "type": "string",
            "description": "Desired state: on, off, toggle, status (for wifi, bluetooth, dark_mode, do_not_disturb)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: volume, brightness, wifi, bluetooth, battery, dark_mode, do_not_disturb, sleep, lock, system_info",
                isError: true
            )
        }

        switch action {
        case "volume":
            return await handleVolume(arguments)
        case "brightness":
            return await handleBrightness(arguments)
        case "wifi":
            return await handleWifi(arguments)
        case "bluetooth":
            return await handleBluetooth(arguments)
        case "battery":
            return await handleBattery()
        case "dark_mode":
            return await handleDarkMode(arguments)
        case "do_not_disturb":
            return await handleDoNotDisturb(arguments)
        case "sleep":
            return await handleSleep()
        case "lock":
            return await handleLock()
        case "system_info":
            return await handleSystemInfo()
        default:
            return ToolResult(
                "Unknown action: \(action). Use: volume, brightness, wifi, bluetooth, battery, dark_mode, do_not_disturb, sleep, lock, system_info",
                isError: true
            )
        }
    }

    // MARK: - Process Runner

    private func runProcess(_ executablePath: String, arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func runAppleScript(_ source: String) async throws -> String {
        let result = try await runProcess("/usr/bin/osascript", arguments: ["-e", source])
        if result.status != 0 {
            throw SystemControlError.scriptFailed(result.stderr)
        }
        return result.stdout
    }

    // MARK: - Volume

    private func handleVolume(_ args: [String: Any]) async -> ToolResult {
        // If a value is provided, set the volume
        if let value = args["value"] as? Int {
            let clamped = max(0, min(100, value))
            let script = "set volume output volume \(clamped)"
            do {
                _ = try await runAppleScript(script)
                return ToolResult("Volume set to \(clamped)%.")
            } catch {
                return ToolResult("Failed to set volume: \(error.localizedDescription)", isError: true)
            }
        }

        // Otherwise, get current volume
        let script = "output volume of (get volume settings)"
        do {
            let result = try await runAppleScript(script)
            return ToolResult("Current volume: \(result)%")
        } catch {
            return ToolResult("Failed to get volume: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Brightness

    private func handleBrightness(_ args: [String: Any]) async -> ToolResult {
        if let value = args["value"] as? Int {
            let clamped = max(0, min(100, value))
            let fraction = Double(clamped) / 100.0
            let script = """
            do shell script "brightness \(fraction)"
            return "Brightness set to \(clamped)%"
            """
            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                // Fallback: try using AppleScript with System Preferences
                return ToolResult("Failed to set brightness. The 'brightness' command-line tool may not be installed. Install via: brew install brightness\nError: \(error.localizedDescription)", isError: true)
            }
        }

        // Get current brightness
        let script = """
        do shell script "brightness -l 2>/dev/null | grep 'display 0' | sed 's/.*brightness //' || echo 'unknown'"
        """
        do {
            let result = try await runAppleScript(script)
            if result == "unknown" || result.isEmpty {
                return ToolResult("Could not read brightness. The 'brightness' command-line tool may not be installed. Install via: brew install brightness")
            }
            if let floatVal = Double(result) {
                let percent = Int(floatVal * 100)
                return ToolResult("Current brightness: \(percent)%")
            }
            return ToolResult("Current brightness: \(result)")
        } catch {
            return ToolResult("Failed to get brightness: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - WiFi

    private func handleWifi(_ args: [String: Any]) async -> ToolResult {
        let state = (args["state"] as? String)?.lowercased() ?? "status"

        switch state {
        case "on":
            do {
                let result = try await runProcess("/usr/bin/networksetup", arguments: ["-setairportpower", "en0", "on"])
                if result.status != 0 {
                    return ToolResult("Failed to enable WiFi: \(result.stderr)", isError: true)
                }
                return ToolResult("WiFi turned on.")
            } catch {
                return ToolResult("Failed to enable WiFi: \(error.localizedDescription)", isError: true)
            }
        case "off":
            do {
                let result = try await runProcess("/usr/bin/networksetup", arguments: ["-setairportpower", "en0", "off"])
                if result.status != 0 {
                    return ToolResult("Failed to disable WiFi: \(result.stderr)", isError: true)
                }
                return ToolResult("WiFi turned off.")
            } catch {
                return ToolResult("Failed to disable WiFi: \(error.localizedDescription)", isError: true)
            }
        default:
            // Get WiFi status
            do {
                let powerResult = try await runProcess("/usr/bin/networksetup", arguments: ["-getairportpower", "en0"])
                let networkResult = try await runProcess("/usr/bin/networksetup", arguments: ["-getairportnetwork", "en0"])
                let info = "\(powerResult.stdout)\n\(networkResult.stdout)"
                return ToolResult("WiFi status:\n\(info)")
            } catch {
                return ToolResult("Failed to get WiFi status: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Bluetooth

    private func handleBluetooth(_ args: [String: Any]) async -> ToolResult {
        let state = (args["state"] as? String)?.lowercased() ?? "status"

        // Use the blueutil command if available, otherwise report limitation
        switch state {
        case "on":
            do {
                let result = try await runProcess("/usr/local/bin/blueutil", arguments: ["--power", "1"])
                if result.status != 0 {
                    return ToolResult("Failed to enable Bluetooth: \(result.stderr)", isError: true)
                }
                return ToolResult("Bluetooth turned on.")
            } catch {
                return ToolResult("Failed to enable Bluetooth. The 'blueutil' tool may not be installed. Install via: brew install blueutil", isError: true)
            }
        case "off":
            do {
                let result = try await runProcess("/usr/local/bin/blueutil", arguments: ["--power", "0"])
                if result.status != 0 {
                    return ToolResult("Failed to disable Bluetooth: \(result.stderr)", isError: true)
                }
                return ToolResult("Bluetooth turned off.")
            } catch {
                return ToolResult("Failed to disable Bluetooth. The 'blueutil' tool may not be installed. Install via: brew install blueutil", isError: true)
            }
        default:
            do {
                let result = try await runProcess("/usr/local/bin/blueutil", arguments: ["--power"])
                if result.status != 0 {
                    return ToolResult("Failed to get Bluetooth status. The 'blueutil' tool may not be installed. Install via: brew install blueutil", isError: true)
                }
                let status = result.stdout == "1" ? "On" : "Off"
                return ToolResult("Bluetooth is \(status).")
            } catch {
                return ToolResult("Failed to get Bluetooth status. The 'blueutil' tool may not be installed. Install via: brew install blueutil", isError: true)
            }
        }
    }

    // MARK: - Battery

    private func handleBattery() async -> ToolResult {
        do {
            let result = try await runProcess("/usr/bin/pmset", arguments: ["-g", "batt"])
            if result.status != 0 {
                return ToolResult("Failed to get battery status: \(result.stderr)", isError: true)
            }
            return ToolResult("Battery status:\n\(result.stdout)")
        } catch {
            return ToolResult("Failed to get battery status: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Dark Mode

    private func handleDarkMode(_ args: [String: Any]) async -> ToolResult {
        let state = (args["state"] as? String)?.lowercased() ?? "status"

        switch state {
        case "on":
            let script = """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to true
                end tell
            end tell
            return "Dark mode enabled."
            """
            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to enable dark mode: \(error.localizedDescription)", isError: true)
            }
        case "off":
            let script = """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to false
                end tell
            end tell
            return "Dark mode disabled."
            """
            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to disable dark mode: \(error.localizedDescription)", isError: true)
            }
        case "toggle":
            let script = """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to not dark mode
                    if dark mode then
                        return "Dark mode enabled."
                    else
                        return "Dark mode disabled."
                    end if
                end tell
            end tell
            """
            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to toggle dark mode: \(error.localizedDescription)", isError: true)
            }
        default:
            let script = """
            tell application "System Events"
                tell appearance preferences
                    if dark mode then
                        return "Dark mode is currently enabled."
                    else
                        return "Dark mode is currently disabled."
                    end if
                end tell
            end tell
            """
            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to get dark mode status: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Do Not Disturb

    private func handleDoNotDisturb(_ args: [String: Any]) async -> ToolResult {
        let state = (args["state"] as? String)?.lowercased() ?? "status"

        switch state {
        case "on", "toggle", "off":
            // macOS Ventura+ uses Focus system; toggle via shortcuts
            let script = """
            do shell script "defaults -currentHost read com.apple.notificationcenterui doNotDisturb 2>/dev/null || echo 0"
            """
            do {
                let current = try await runAppleScript(script)
                let isOn = current == "1"

                if (state == "on" && isOn) || (state == "off" && !isOn) {
                    return ToolResult("Do Not Disturb is already \(isOn ? "on" : "off").")
                }

                // Toggle DND via keyboard shortcut simulation is unreliable;
                // use defaults write approach for older macOS
                let toggleScript = """
                do shell script "defaults -currentHost write com.apple.notificationcenterui doNotDisturb -bool \(state == "on" || (state == "toggle" && !isOn) ? "true" : "false")"
                do shell script "killall NotificationCenter 2>/dev/null || true"
                return "Do Not Disturb \(state == "on" || (state == "toggle" && !isOn) ? "enabled" : "disabled"). Note: On macOS Ventura+, use Focus settings in System Settings for reliable control."
                """
                let result = try await runAppleScript(toggleScript)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to control Do Not Disturb: \(error.localizedDescription)\nNote: On macOS Ventura+, DND is managed through the Focus system and may require manual control.", isError: true)
            }
        default:
            let script = """
            do shell script "defaults -currentHost read com.apple.notificationcenterui doNotDisturb 2>/dev/null || echo 0"
            """
            do {
                let result = try await runAppleScript(script)
                let status = result == "1" ? "enabled" : "disabled"
                return ToolResult("Do Not Disturb is currently \(status).\nNote: On macOS Ventura+, this reads the legacy setting. The Focus system may override it.")
            } catch {
                return ToolResult("Failed to get Do Not Disturb status: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Sleep

    private func handleSleep() async -> ToolResult {
        do {
            let result = try await runProcess("/usr/bin/pmset", arguments: ["displaysleepnow"])
            if result.status != 0 {
                return ToolResult("Failed to put display to sleep: \(result.stderr)", isError: true)
            }
            return ToolResult("Display put to sleep.")
        } catch {
            return ToolResult("Failed to put display to sleep: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Lock

    private func handleLock() async -> ToolResult {
        let script = """
        tell application "System Events" to keystroke "q" using {control down, command down}
        """
        do {
            _ = try await runAppleScript(script)
            return ToolResult("Screen locked.")
        } catch {
            return ToolResult("Failed to lock screen: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - System Info

    private func handleSystemInfo() async -> ToolResult {
        var info: [String] = []

        // CPU info
        do {
            let cpuResult = try await runProcess("/usr/sbin/sysctl", arguments: ["-n", "machdep.cpu.brand_string"])
            info.append("CPU: \(cpuResult.stdout)")
        } catch {
            info.append("CPU: unknown")
        }

        // CPU core count
        do {
            let coreResult = try await runProcess("/usr/sbin/sysctl", arguments: ["-n", "hw.ncpu"])
            info.append("CPU Cores: \(coreResult.stdout)")
        } catch {
            // skip
        }

        // Memory
        do {
            let memResult = try await runProcess("/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"])
            if let bytes = UInt64(memResult.stdout) {
                let gb = Double(bytes) / 1_073_741_824.0
                info.append("Memory: \(String(format: "%.1f", gb)) GB")
            }
        } catch {
            // skip
        }

        // Memory pressure
        do {
            let pressureResult = try await runProcess("/usr/bin/memory_pressure", arguments: ["-Q"])
            let lines = pressureResult.stdout.components(separatedBy: .newlines)
            if let lastLine = lines.last(where: { !$0.isEmpty }) {
                info.append("Memory Pressure: \(lastLine)")
            }
        } catch {
            // skip
        }

        // Disk usage
        do {
            let diskResult = try await runProcess("/bin/df", arguments: ["-h", "/"])
            let lines = diskResult.stdout.components(separatedBy: .newlines)
            if lines.count >= 2 {
                info.append("Disk Usage (/):\n  \(lines[0])\n  \(lines[1])")
            }
        } catch {
            // skip
        }

        // Uptime
        do {
            let uptimeResult = try await runProcess("/usr/bin/uptime", arguments: [])
            info.append("Uptime: \(uptimeResult.stdout)")
        } catch {
            // skip
        }

        // macOS version
        do {
            let versionResult = try await runProcess("/usr/bin/sw_vers", arguments: [])
            info.append("OS:\n\(versionResult.stdout)")
        } catch {
            // skip
        }

        return ToolResult("System Information:\n\n\(info.joined(separator: "\n"))")
    }
}

// MARK: - Errors

private enum SystemControlError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "System control error: \(msg)"
        }
    }
}
