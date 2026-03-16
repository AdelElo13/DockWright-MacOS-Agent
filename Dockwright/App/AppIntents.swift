import AppIntents
import Foundation

// MARK: - Ask Dockwright (Main Intent)

struct AskDockwrightIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Dockwright"
    static let description: IntentDescription = "Ask Dockwright a question and get an AI-powered response."

    @Parameter(title: "Question")
    var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let executor = ToolExecutor()
        // Use shell tool to echo the query — a lightweight round-trip confirming Dockwright is reachable
        let result = await executor.executeTool(name: "shell", arguments: ["command": "echo 'Dockwright received your query.'"])
        let response = result.isError
            ? "Sorry, I couldn't process that request."
            : "Received: \(query). Open Dockwright for a full AI response."
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

// MARK: - Check Email

struct CheckEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Email with Dockwright"
    static let description: IntentDescription = "Check your recent emails using Dockwright."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = EmailTool()
        let result = try await tool.execute(arguments: ["action": "read_inbox", "count": 5])
        let response = result.isError ? "Could not check email: \(result.output)" : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: String(response.prefix(400))))
    }
}

// MARK: - Check Calendar

struct CheckCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Calendar with Dockwright"
    static let description: IntentDescription = "Show today's calendar events using Dockwright."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = CalendarTool()
        let result = try await tool.execute(arguments: ["action": "today"])
        let response = result.isError ? "Could not check calendar: \(result.output)" : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: String(response.prefix(400))))
    }
}

// MARK: - Take Screenshot

struct TakeScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Screenshot with Dockwright"
    static let description: IntentDescription = "Capture a screenshot of your screen."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = ScreenshotTool()
        let result = try await tool.execute(arguments: ["action": "capture_screen"])
        let response = result.isError ? "Screenshot failed: \(result.output)" : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

// MARK: - Show Battery

struct ShowBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Battery Status"
    static let description: IntentDescription = "Show your Mac's current battery status."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = SystemControlTool()
        let result = try await tool.execute(arguments: ["action": "battery"])
        let response = result.isError ? "Could not get battery status." : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

// MARK: - Toggle Dark Mode

struct ToggleDarkModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dark Mode"
    static let description: IntentDescription = "Toggle dark mode on or off on your Mac."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = SystemControlTool()
        let result = try await tool.execute(arguments: ["action": "dark_mode", "state": "toggle"])
        let response = result.isError ? "Could not toggle dark mode." : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

// MARK: - Now Playing

struct NowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description: IntentDescription = "Show the currently playing music track."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = MusicTool()
        let result = try await tool.execute(arguments: ["action": "now_playing"])
        let response = result.isError ? "Could not get now playing info." : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

// MARK: - Show Reminders

struct ShowRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Reminders"
    static let description: IntentDescription = "List your current reminders."

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = RemindersTool()
        let result = try await tool.execute(arguments: ["action": "list"])
        let response = result.isError ? "Could not list reminders: \(result.output)" : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: String(response.prefix(400))))
    }
}

// MARK: - Create Reminder

struct CreateReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Reminder with Dockwright"
    static let description: IntentDescription = "Create a new reminder with an optional due date."

    @Parameter(title: "Title")
    var reminderTitle: String

    @Parameter(title: "Due Date")
    var dueDate: Date?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tool = RemindersTool()
        var args: [String: Any] = ["action": "create", "title": reminderTitle]
        if let dueDate {
            let formatter = ISO8601DateFormatter()
            args["due"] = formatter.string(from: dueDate)
        }
        let result = try await tool.execute(arguments: args)
        let response = result.isError ? "Could not create reminder: \(result.output)" : result.output
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

// MARK: - App Shortcuts Provider

struct DockwrightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskDockwrightIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Hey \(.applicationName)",
                "Ask \(.applicationName) something",
            ],
            shortTitle: "Ask Dockwright",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: CheckEmailIntent(),
            phrases: [
                "Check email with \(.applicationName)",
                "Read my email in \(.applicationName)",
            ],
            shortTitle: "Check Email",
            systemImageName: "envelope"
        )
        AppShortcut(
            intent: CheckCalendarIntent(),
            phrases: [
                "Check calendar with \(.applicationName)",
                "What's on my calendar in \(.applicationName)",
            ],
            shortTitle: "Check Calendar",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: TakeScreenshotIntent(),
            phrases: [
                "Take a screenshot with \(.applicationName)",
                "Capture screen with \(.applicationName)",
            ],
            shortTitle: "Take Screenshot",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: ShowBatteryIntent(),
            phrases: [
                "Battery status in \(.applicationName)",
                "Check battery with \(.applicationName)",
            ],
            shortTitle: "Battery Status",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: ToggleDarkModeIntent(),
            phrases: [
                "Toggle dark mode with \(.applicationName)",
                "Switch dark mode in \(.applicationName)",
            ],
            shortTitle: "Toggle Dark Mode",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: NowPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "Now playing in \(.applicationName)",
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: ShowRemindersIntent(),
            phrases: [
                "Show reminders in \(.applicationName)",
                "List reminders with \(.applicationName)",
            ],
            shortTitle: "Show Reminders",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CreateReminderIntent(),
            phrases: [
                "Create a reminder with \(.applicationName)",
                "Remind me with \(.applicationName)",
            ],
            shortTitle: "Create Reminder",
            systemImageName: "plus.circle"
        )
    }
}
