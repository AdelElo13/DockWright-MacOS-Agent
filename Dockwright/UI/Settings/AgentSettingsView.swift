import SwiftUI

/// Agent mode and autonomy settings.
struct AgentSettingsView: View {
    @State private var autonomyLevel = UserDefaults.standard.string(forKey: "autonomyLevel") ?? "suggest"
    @State private var maxStepsPerTask = UserDefaults.standard.object(forKey: "agentMaxSteps") as? Int ?? 10
    @State private var tokenBudget = UserDefaults.standard.object(forKey: "agentTokenBudget") as? Int ?? 50000
    @State private var heartbeatEnabled = UserDefaults.standard.object(forKey: "heartbeatEnabled") as? Bool ?? true
    @State private var heartbeatInterval = UserDefaults.standard.object(forKey: "heartbeatInterval") as? Int ?? 30
    @State private var activeHoursStart = UserDefaults.standard.object(forKey: "activeHoursStart") as? Int ?? 7
    @State private var activeHoursEnd = UserDefaults.standard.object(forKey: "activeHoursEnd") as? Int ?? 23
    @State private var parallelTasks = UserDefaults.standard.object(forKey: "maxParallelTasks") as? Int ?? 3
    @State private var autoRetry = UserDefaults.standard.object(forKey: "agentAutoRetry") as? Bool ?? true
    @State private var showThinking = UserDefaults.standard.object(forKey: "showAgentThinking") as? Bool ?? true

    private let autonomyLevels = [
        ("off", "Off", "Chatbot only — no autonomous actions"),
        ("suggest", "Suggest", "Analyze and suggest actions, wait for approval"),
        ("proactive", "Proactive", "Execute safe tasks automatically, ask for risky ones"),
        ("autonomous", "Autonomous", "Execute everything, notify after completion")
    ]

    var body: some View {
        Form {
            Section("Autonomy Level") {
                ForEach(autonomyLevels, id: \.0) { level in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.1)
                                .font(.system(size: 13, weight: autonomyLevel == level.0 ? .semibold : .regular))
                            Text(level.2)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if autonomyLevel == level.0 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        autonomyLevel = level.0
                        UserDefaults.standard.set(level.0, forKey: "autonomyLevel")
                    }
                }
            }

            Section("Agent Limits") {
                Stepper("Max steps per task: \(maxStepsPerTask)", value: $maxStepsPerTask, in: 1...50)
                    .onChange(of: maxStepsPerTask) { _, v in
                        UserDefaults.standard.set(v, forKey: "agentMaxSteps")
                    }

                VStack(alignment: .leading) {
                    Text("Token budget per request: \(tokenBudget / 1000)k")
                        .font(.caption)
                    Slider(value: Binding(
                        get: { Double(tokenBudget) },
                        set: { tokenBudget = Int($0) }
                    ), in: 5000...200000, step: 5000)
                    .onChange(of: tokenBudget) { _, v in
                        UserDefaults.standard.set(v, forKey: "agentTokenBudget")
                    }
                }

                Stepper("Max parallel tasks: \(parallelTasks)", value: $parallelTasks, in: 1...10)
                    .onChange(of: parallelTasks) { _, v in
                        UserDefaults.standard.set(v, forKey: "maxParallelTasks")
                    }

                Toggle("Auto-retry failed steps", isOn: $autoRetry)
                    .onChange(of: autoRetry) { _, v in
                        UserDefaults.standard.set(v, forKey: "agentAutoRetry")
                    }

                Toggle("Show agent thinking process", isOn: $showThinking)
                    .onChange(of: showThinking) { _, v in
                        UserDefaults.standard.set(v, forKey: "showAgentThinking")
                    }
            }

            Section("Heartbeat") {
                Toggle("Enable heartbeat monitor", isOn: $heartbeatEnabled)
                    .onChange(of: heartbeatEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "heartbeatEnabled")
                    }

                Picker("Check interval", selection: $heartbeatInterval) {
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .onChange(of: heartbeatInterval) { _, v in
                    UserDefaults.standard.set(v, forKey: "heartbeatInterval")
                }

                HStack {
                    Picker("Active from", selection: $activeHoursStart) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .onChange(of: activeHoursStart) { _, v in
                        UserDefaults.standard.set(v, forKey: "activeHoursStart")
                    }

                    Text("to")

                    Picker("", selection: $activeHoursEnd) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: activeHoursEnd) { _, v in
                        UserDefaults.standard.set(v, forKey: "activeHoursEnd")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
