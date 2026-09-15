import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item. SwiftUI's MenuBarExtra can't observe hover on the
/// status button, so this is plain AppKit: an NSStatusItem with a tracking
/// area that opens an NSPopover on mouseEntered.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let claudeStore = UsageStore()
    private let codexStore = CodexUsageStore()

    private var refreshTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var clickMonitor: Any?
    private var cancellable: AnyCancellable?

    /// Hover opens the popover transiently; a click pins it open.
    private var isPinned = false

    override init() {
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: UsageView(
                claudeStore: claudeStore,
                codexStore: codexStore,
                onQuit: { NSApp.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "chart.bar.fill",
                accessibilityDescription: "Claude Code and Codex usage"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePinned)

            // .inVisibleRect keeps the rect correct as the menu bar reflows.
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            button.addTrackingArea(area)
        }

        cancellable = Publishers.CombineLatest(
            claudeStore.$snapshot,
            codexStore.$snapshot
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] claude, codex in self?.updateTitle(claude: claude, codex: codex) }

        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        removeClickMonitor()
    }

    // MARK: Hover

    @objc func mouseEntered(with event: NSEvent) {
        hideWorkItem?.cancel()
        refreshAll()
        showPopover()
    }

    @objc func mouseExited(with event: NSEvent) {
        guard !isPinned else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPinned else { return }
            self.popover.performClose(nil)
        }
        hideWorkItem = work
        // Small grace period so a wobbly cursor doesn't flicker the popover.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: Click to pin

    @objc private func togglePinned() {
        isPinned.toggle()
        if isPinned {
            showPopover()
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            installClickMonitor()
        } else {
            removeClickMonitor()
            popover.performClose(nil)
        }
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.isPinned else { return }
            self.isPinned = false
            self.removeClickMonitor()
            self.popover.performClose(nil)
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    // MARK: Presentation

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func refreshAll() {
        claudeStore.refresh()
        codexStore.refresh()
    }

    private func updateTitle(claude: Snapshot, codex: CodexSnapshot) {
        guard let button = statusItem.button else { return }

        let claudeLabel = shortLabel(
            plan: claude.plan.flatMap { $0.isStale ? nil : ($0.fiveHour ?? $0.sevenDay) },
            tokens: claude.error == nil ? claude.today.counts.total : nil
        )
        let codexLabel = shortLabel(
            plan: codex.plan.flatMap { $0.isStale ? nil : ($0.primary ?? $0.secondary) },
            tokens: codex.error == nil ? codex.today.counts.total : nil
        )

        button.attributedTitle = NSAttributedString(
            string: " C \(claudeLabel) · X \(codexLabel)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize(for: .small),
                    weight: .regular
                )
            ]
        )

        // Free fallback: macOS shows this on hover with no tracking area at all.
        var lines: [String] = []
        if let window = claude.plan?.fiveHour {
            lines.append("Claude session: \(Fmt.percent(window.usedPercentage)) used")
        }
        if let window = claude.plan?.sevenDay {
            lines.append("Claude week: \(Fmt.percent(window.usedPercentage)) used")
        }
        if let window = codex.plan?.primary {
            lines.append("Codex session: \(Fmt.percent(window.usedPercentage)) used")
        }
        if let window = codex.plan?.secondary {
            lines.append("Codex week: \(Fmt.percent(window.usedPercentage)) used")
        }
        lines.append("Claude today: \(Fmt.tokens(claude.today.counts.total)) tokens")
        lines.append("Codex today: \(Fmt.tokens(codex.today.counts.total)) tokens")
        button.toolTip = lines.joined(separator: "\n")
    }

    private func shortLabel(plan: QuotaWindow?, tokens: Int?) -> String {
        if let plan { return Fmt.percent(plan.usedPercentage) }
        if let tokens { return Fmt.tokens(tokens) }
        return "—"
    }
}
