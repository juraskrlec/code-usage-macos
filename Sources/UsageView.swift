import SwiftUI

private enum UsageProvider: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"

    var id: Self { self }
}

private struct ClaudeModelRow: Identifiable {
    let id: String
    let counts: TokenCounts
}

private struct CodexModelRow: Identifiable {
    let id: String
    let counts: CodexTokenCounts
}

struct UsageView: View {
    @ObservedObject var claudeStore: UsageStore
    @ObservedObject var codexStore: CodexUsageStore
    @State private var selectedProvider = UsageProvider.claude
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Text("Code usage")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if claudeStore.isLoading || codexStore.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            Picker("Provider", selection: $selectedProvider) {
                ForEach(UsageProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selectedProvider {
                case .claude:
                    claudeSection
                case .codex:
                    codexSection
                }
            }

            Divider()

            HStack {
                Text("Updated \(lastUpdated, style: .time)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Refresh") { refreshAll() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                Button("Quit") { onQuit() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }

    private var lastUpdated: Date {
        max(claudeStore.snapshot.updated, codexStore.snapshot.updated)
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("LLLL")
        return formatter.string(from: Date())
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerTitle("Claude Code", detail: nil)

            if let plan = claudeStore.snapshot.plan {
                planHeader(capturedAt: plan.capturedAt, isStale: plan.isStale)
                if let window = plan.fiveHour { quota("Session", window) }
                if let window = plan.sevenDay { quota("Week", window) }
            }

            if let error = claudeStore.snapshot.error {
                errorText(error)
            } else {
                HStack(spacing: 12) {
                    periodSummary(
                        "Today",
                        tokens: claudeStore.snapshot.today.counts.total,
                        detail: claudeStore.snapshot.todayCost.map(Fmt.money)
                            ?? "\(claudeStore.snapshot.today.messages) replies"
                    )
                    periodSummary(
                        monthLabel,
                        tokens: claudeStore.snapshot.month.counts.total,
                        detail: claudeStore.snapshot.monthCost.map(Fmt.money)
                            ?? "\(claudeStore.snapshot.month.messages) replies"
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    stat("in", claudeStore.snapshot.today.counts.input)
                    stat("out", claudeStore.snapshot.today.counts.output)
                    stat("cache write", claudeStore.snapshot.today.counts.cacheWrite)
                    stat("cache read", claudeStore.snapshot.today.counts.cacheRead)
                }
                modelLine(topClaudeModels(claudeStore.snapshot.today))
            }
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerTitle("Codex", detail: codexStore.snapshot.plan?.planType?.capitalized)

            if let plan = codexStore.snapshot.plan {
                planHeader(capturedAt: plan.capturedAt, isStale: plan.isStale)
                if let window = plan.primary { quota(windowLabel(window), window) }
                if let window = plan.secondary { quota(windowLabel(window), window) }
            }

            if let error = codexStore.snapshot.error {
                errorText(error)
            } else {
                HStack(spacing: 12) {
                    periodSummary(
                        "Today",
                        tokens: codexStore.snapshot.today.counts.total,
                        detail: "\(codexStore.snapshot.today.responses) responses"
                    )
                    periodSummary(
                        monthLabel,
                        tokens: codexStore.snapshot.month.counts.total,
                        detail: "\(codexStore.snapshot.month.responses) responses"
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    stat("in", codexStore.snapshot.today.counts.input)
                    stat("out", codexStore.snapshot.today.counts.output)
                    stat("cached", codexStore.snapshot.today.counts.cachedInput)
                    stat("reasoning", codexStore.snapshot.today.counts.reasoningOutput)
                }
                codexModelLine(topCodexModels(codexStore.snapshot.today))
            }
        }
    }

    private func providerTitle(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func planHeader(capturedAt: Date, isStale: Bool) -> some View {
        HStack {
            Text("Plan limits")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if isStale {
                Text("last seen \(capturedAt, style: .relative) ago")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func quota(_ label: String, _ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10))
                Spacer()
                Text(Fmt.percent(window.usedPercentage))
                    .font(.system(size: 10))
                    .monospacedDigit()
                if let resets = window.resetsAt, let text = Fmt.countdown(to: resets) {
                    Text(text)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: window.usedPercentage, total: 100)
                .progressViewStyle(.linear)
                .tint(window.usedPercentage >= 90 ? .red
                      : window.usedPercentage >= 70 ? .orange : .accentColor)
        }
    }

    private func periodSummary(_ title: String, tokens: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(Fmt.tokens(tokens))
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Fmt.tokens(value))
                .font(.system(size: 10))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func modelLine(_ rows: [ClaudeModelRow]) -> some View {
        if !rows.isEmpty {
            HStack(spacing: 10) {
                ForEach(rows) { row in
                    Text("\(Fmt.shortModel(row.id)) \(Fmt.tokens(row.counts.total))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func codexModelLine(_ rows: [CodexModelRow]) -> some View {
        if !rows.isEmpty {
            HStack(spacing: 10) {
                ForEach(rows) { row in
                    Text("\(Fmt.shortModel(row.id)) \(Fmt.tokens(row.counts.total))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func topClaudeModels(_ totals: Totals) -> [ClaudeModelRow] {
        totals.byModel
            .map { ClaudeModelRow(id: $0.key, counts: $0.value) }
            .sorted { $0.counts.total > $1.counts.total }
            .prefix(2)
            .map { $0 }
    }

    private func topCodexModels(_ totals: CodexTotals) -> [CodexModelRow] {
        totals.byModel
            .map { CodexModelRow(id: $0.key, counts: $0.value) }
            .sorted { $0.counts.total > $1.counts.total }
            .prefix(2)
            .map { $0 }
    }

    private func windowLabel(_ window: QuotaWindow) -> String {
        switch window.windowMinutes {
        case 300: return "Session"
        case 10_080: return "Week"
        case let minutes? where minutes % 1_440 == 0:
            return "\(minutes / 1_440)d"
        case let minutes? where minutes % 60 == 0:
            return "\(minutes / 60)h"
        case let minutes?:
            return "\(minutes)m"
        case nil:
            return "Limit"
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshAll() {
        claudeStore.refresh()
        codexStore.refresh()
    }
}
