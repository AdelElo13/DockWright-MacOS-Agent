import SwiftUI

/// Visual representation of an agent plan with step-by-step status indicators.
/// Shows in chat or as a standalone panel — each step transitions: pending → running → done/failed.
struct PlanVisualizationView: View {
    let plan: AgentExecutor.AgentPlan
    let results: [AgentExecutor.StepResult]
    let currentStep: Int?  // nil = not executing
    let onCancel: (() -> Void)?

    init(
        plan: AgentExecutor.AgentPlan,
        results: [AgentExecutor.StepResult] = [],
        currentStep: Int? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.plan = plan
        self.results = results
        self.currentStep = currentStep
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            planHeader
            Divider().padding(.horizontal, 12)
            stepList
            if let onCancel = onCancel, currentStep != nil {
                Divider().padding(.horizontal, 12)
                cancelBar(onCancel)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DockwrightTheme.glassBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(DockwrightTheme.primary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Header

    private var planHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .foregroundStyle(DockwrightTheme.primary)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text("Execution Plan")
                    .font(.system(size: 13, weight: .semibold))
                Text(plan.goal.prefix(80) + (plan.goal.count > 80 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            progressBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var progressBadge: some View {
        let completed = results.filter { !$0.isError }.count
        let failed = results.filter { $0.isError }.count
        let total = plan.steps.count

        return HStack(spacing: 4) {
            if currentStep != nil {
                ProgressView()
                    .controlSize(.mini)
            }
            Text("\(completed)/\(total)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(failed > 0 ? .red : DockwrightTheme.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DockwrightTheme.primary.opacity(0.1))
        )
    }

    // MARK: - Step List

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                stepRow(step: step, index: index)
                if index < plan.steps.count - 1 {
                    connectorLine(for: index)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func stepRow(step: AgentExecutor.AgentStep, index: Int) -> some View {
        let status = stepStatus(for: step)
        let result = results.first { $0.step.index == step.index }

        return HStack(alignment: .top, spacing: 10) {
            // Status indicator
            stepIndicator(status: status)

            // Step content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Step \(step.index)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(status))

                    if let toolName = step.toolName {
                        Text(toolName)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(statusColor(status).opacity(0.1))
                            .clipShape(Capsule())
                            .foregroundStyle(statusColor(status))
                    }

                    if let r = result, r.retryCount > 0 {
                        Text("retry ×\(r.retryCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }

                Text(step.description)
                    .font(.system(size: 11))
                    .foregroundStyle(status == .pending ? .secondary : .primary)
                    .lineLimit(3)

                // Output preview for completed steps
                if let r = result, !r.output.isEmpty {
                    Text(r.output.prefix(150).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func connectorLine(for index: Int) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(stepStatus(for: plan.steps[index]) == .completed ? DockwrightTheme.primary.opacity(0.3) : Color.secondary.opacity(0.15))
                .frame(width: 2, height: 16)
                .padding(.leading, 9) // Center under the 20px indicator
            Spacer()
        }
    }

    // MARK: - Status

    private enum StepStatus {
        case pending, running, completed, failed
    }

    private func stepStatus(for step: AgentExecutor.AgentStep) -> StepStatus {
        if let result = results.first(where: { $0.step.index == step.index }) {
            return result.isError ? .failed : .completed
        }
        if let current = currentStep, step.index == current {
            return .running
        }
        return .pending
    }

    private func stepIndicator(status: StepStatus) -> some View {
        ZStack {
            switch status {
            case .pending:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            case .running:
                Circle()
                    .fill(DockwrightTheme.primary.opacity(0.15))
                    .frame(width: 20, height: 20)
                    .overlay(
                        ProgressView()
                            .controlSize(.mini)
                    )
            case .completed:
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    )
            case .failed:
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                    )
            }
        }
    }

    private func statusColor(_ status: StepStatus) -> Color {
        switch status {
        case .pending:   return .secondary
        case .running:   return DockwrightTheme.primary
        case .completed: return .green
        case .failed:    return .red
        }
    }

    // MARK: - Cancel Bar

    private func cancelBar(_ onCancel: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button {
                onCancel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                    Text("Cancel Plan")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
