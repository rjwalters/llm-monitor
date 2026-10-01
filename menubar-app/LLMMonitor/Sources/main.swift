#if os(macOS)
import SwiftUI

// MARK: - Popover Height Manager

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Sizes the popover to hug its content: the window height tracks the number
/// of account rows so there is no empty space below the table. Height is
/// clamped to [minHeight, maxHeight]; when rows would exceed maxHeight the row
/// list scrolls. The user can override the fit by dragging the handle on the
/// popover's bottom edge (`PopoverResizeHandle`); that height persists across
/// launches, and double-clicking the handle returns to the automatic fit.
///
/// `@MainActor`: it holds an `NSPopover` and mutates its `contentSize` (an
/// AppKit main-actor API) and is only ever driven from the app's main-thread
/// UI path (`AppDelegate`, SwiftUI view bodies), matching the isolation of the
/// other UI-state classes (`UsageStore`, `OAuthPoller`).
@MainActor
class PopoverHeightManager: ObservableObject {
    /// Exactly the sum of `SummaryColumns`' widths plus its horizontal padding
    /// on both sides, so the summary table neither clips nor floats in empty
    /// space. Recompute it whenever a column width there changes — the two
    /// Session %/Weekly % columns grew by 16pt each in #220 to carry the
    /// even-burn mark beside the raw percentage, taking 818 to 850.
    // An immutable constant, read by `SummaryColumns.tableWidth` outside the
    // main actor, so it carries no isolation.
    nonisolated static let popoverWidth: CGFloat = 850
    static let minHeight: CGFloat = 200
    static let maxHeight: CGFloat = 800

    /// Fixed chrome around the scrolling row list: header (~50) + column
    /// header (~28) + dividers (~3) + footer (~42).
    static let chromeHeight: CGFloat = 123
    /// Height of a single account row: caption text (~16) + 6pt vertical
    /// padding × 2. Keep in sync with `SummaryRow`'s `.padding(.vertical, 6)`.
    static let rowHeight: CGFloat = 28
    /// Height for the setup/empty/error state (no table rows to size against).
    static let setupHeight: CGFloat = 360

    // Neither size is `@Published`: `popover.contentSize` is the only thing that
    // sizes the popover, and the SwiftUI content just fills it. Publishing them
    // would re-render the whole table on every mouse-move of a resize drag.
    private(set) var currentHeight: CGFloat = PopoverHeightManager.minHeight
    /// The table's width for the columns actually shown (#227) — narrower than
    /// `popoverWidth` when a provider-specific column is hidden.
    private(set) var currentWidth: CGFloat = PopoverHeightManager.popoverWidth
    weak var popover: NSPopover?

    private static let userHeightKey = "popoverUserHeight"
    /// Height the user dragged the popover to, or nil to auto-fit. Only a
    /// height *below* the content fit is kept: dragging to or past it returns
    /// to auto-fit, so the popover keeps growing as accounts are added.
    private var userHeight: CGFloat? = (UserDefaults.standard.object(forKey: PopoverHeightManager.userHeightKey) as? Double).map { CGFloat($0) }
    private var rowCount = 0
    private var dragStartHeight: CGFloat?
    private var dragStartMouseY: CGFloat = 0

    /// Recompute the width from the providers now visible in the table.
    func setVisibleProviders(_ providers: Set<AccountProvider>) {
        let w = SummaryColumns.tableWidth(among: providers)
        if w != currentWidth { currentWidth = w }
    }

    /// Content-fitted popover height for `rowCount` account rows, clamped to
    /// [minHeight, maxHeight]. With no rows (setup/empty/error state) a fixed
    /// setup height is used so the guide isn't cramped.
    func fittedHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return Self.setupHeight }
        let content = Self.chromeHeight + CGFloat(rowCount) * Self.rowHeight
        return content.clamped(to: Self.minHeight...Self.maxHeight)
    }

    /// Unclamped height that shows every row without scrolling.
    private func contentHeight(rowCount: Int) -> CGFloat {
        Self.chromeHeight + CGFloat(rowCount) * Self.rowHeight
    }

    /// Tallest the user may drag the popover: the screen's usable height,
    /// less a margin for the menu-bar arrow.
    private var screenMaxHeight: CGFloat {
        let screen = popover?.contentViewController?.view.window?.screen ?? NSScreen.main
        return (screen?.visibleFrame.height ?? Self.maxHeight) - 40
    }

    /// Popover height for `rowCount` rows: the user's dragged height if set
    /// (never taller than the content or the screen), else the content fit.
    func effectiveHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return Self.setupHeight }
        guard let userHeight else { return fittedHeight(rowCount: rowCount) }
        let upper = Swift.max(Self.minHeight, Swift.min(contentHeight(rowCount: rowCount), screenMaxHeight))
        return userHeight.clamped(to: Self.minHeight...upper)
    }

    /// Recompute `currentHeight` from the row count and resize the live popover.
    func update(rowCount: Int) {
        self.rowCount = rowCount
        apply()
    }

    private func apply() {
        let size = NSSize(width: currentWidth, height: effectiveHeight(rowCount: rowCount))
        currentHeight = size.height
        if popover?.contentSize != size { popover?.contentSize = size }
    }

    // MARK: Manual resize

    /// Drag progress is read from the screen-space mouse position rather than
    /// the gesture's translation, because the view being dragged is resized
    /// (and its coordinate space moved) by the drag itself.
    func dragChanged() {
        if dragStartHeight == nil {
            dragStartHeight = currentHeight
            dragStartMouseY = NSEvent.mouseLocation.y
            // Content-size changes animate by default, which lags the cursor.
            popover?.animates = false
        }
        guard let start = dragStartHeight else { return }
        // Screen y grows upward; the popover hangs down from the menu bar.
        userHeight = start + (dragStartMouseY - NSEvent.mouseLocation.y)
        apply()
    }

    func dragEnded() {
        dragStartHeight = nil
        popover?.animates = true
        let reachesContent = currentHeight >= Swift.min(contentHeight(rowCount: rowCount), screenMaxHeight)
        userHeight = reachesContent ? nil : currentHeight
        persistUserHeight()
        apply()
    }

    func resetToFit() {
        userHeight = nil
        persistUserHeight()
        apply()
    }

    private func persistUserHeight() {
        if let userHeight {
            UserDefaults.standard.set(Double(userHeight), forKey: Self.userHeightKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.userHeightKey)
        }
    }
}

@main
enum LLMMonitorEntry {
    @MainActor
    static func main() {
        // `accounts export|import` is a one-shot CLI operation, not a launch
        // mode — route it before the --headless/GUI dispatch so it works
        // without also passing --headless.
        if CommandLine.arguments.dropFirst().first == "accounts" {
            AccountSyncCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "codex" {
            CodexCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "claude" {
            ClaudeCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "zai" {
            ZaiCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "tokens" {
            TokensCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "calibrate" {
            CalibrationCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "selftest" {
            SelfTest.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.contains("--version") {
            // Dispatched at top level (not just inside HeadlessRunner) so
            // `LLMMonitor --version` never falls through to the GUI branch
            // below — see #46.
            print("llm-monitor \(AppVersion.current)")
            exit(0)
        } else if CommandLine.arguments.contains("--headless") {
            HeadlessRunner.main()
        } else if CommandLine.arguments.contains("--once") || CommandLine.arguments.contains("--interval") {
            // These are headless-loop flags handled inside HeadlessRunner; bare
            // (without --headless) they must fail fast rather than silently
            // launching a duplicate GUI instance — see #46.
            FileHandle.standardError.write(Data("--once/--interval require --headless on macOS, e.g. `LLMMonitor --headless --once`\n".utf8))
            exit(2)
        } else {
            LLMMonitorApp.main()
        }
    }
}

struct LLMMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .suppressedAtLaunch()
    }
}

extension Scene {
    /// The `Settings` scene above is only a placeholder the `App` lifecycle
    /// requires; without this, recent macOS presents it at launch as an empty
    /// window the user has to close.
    func suppressedAtLaunch() -> some Scene {
        if #available(macOS 15.0, *) {
            return defaultLaunchBehavior(.suppressed)
        } else {
            return self
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set at launch so windows opened deep in the SwiftUI view tree can reach the
    /// popover to dismiss it. `NSApp.delegate as? AppDelegate` is unreliable under
    /// the SwiftUI @NSApplicationDelegateAdaptor lifecycle, so we hold it directly.
    static weak var shared: AppDelegate?

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var timer: Timer?
    var usageStore = UsageStore()
    var oauthPoller = OAuthPoller()
    var loginWizardWindow: NSWindow?
    var heightManager: PopoverHeightManager!

    private let flog = FileLogger.shared

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        flog.info("LLMMonitor launched (v\(AppVersion.current))", category: "App")

        // Ensure database exists (standalone mode without native host)
        usageStore.ensureDatabase()
        flog.info("Database ready", category: "App")

        // `usageStore` and `oauthPoller` are separate instances (see
        // UsageStore.pollIntervalHint) — tell the store the actual poll
        // cadence so its staleness threshold (#148) tracks the poller's,
        // rather than silently drifting if `oauthPoller.pollInterval` is
        // ever made configurable on macOS.
        usageStore.pollIntervalHint = oauthPoller.pollInterval

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Variable length so the highlight auto-fits the rendered text
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Handle both left and right clicks (M3.2)
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusButton()
        }
        flog.info("Status item created", category: "App")

        // Update menubar when accounts change (e.g., reordering)
        usageStore.onAccountsChanged = { [weak self] in
            self?.updateStatusButton()
        }

        // Create height manager (auto-fits the popover to its content)
        heightManager = PopoverHeightManager()

        // Create popover
        popover = NSPopover()
        heightManager.setVisibleProviders(Set(usageStore.accounts.map(\.provider)))
        popover?.contentSize = NSSize(width: heightManager.currentWidth, height: heightManager.effectiveHeight(rowCount: usageStore.accounts.count))
        // .semitransient keeps the popover open while user interacts with other
        // windows in this app (e.g. multiple chart windows launched from rows).
        popover?.behavior = .semitransient
        let popoverHost = NSHostingController(
            rootView: UsagePopoverView(store: usageStore, oauthPoller: oauthPoller, heightManager: heightManager, onAddAccount: { [weak self] in
                self?.openAddAccountWindow()
            })
        )
        // `heightManager` owns the popover's size; the hosting controller must
        // not push the SwiftUI content's own preferred size back at it.
        popoverHost.sizingOptions = []
        popover?.contentViewController = popoverHost
        heightManager.popover = popover
        flog.info("Popover ready, starting poll timer", category: "App")

        // Tick every 30s; each account is polled once per 10 min (staggered).
        // The timer is scheduled on the main run loop, so its `@Sendable` block
        // always fires on the main thread; `MainActor.assumeIsolated` lets it call
        // the `@MainActor`-isolated `refreshDue()` without an async hop.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDue()
            }
        }

        // Initial load — sync accounts from the master + local list files, then
        // poll all accounts once (staggers their next-poll times).
        syncThenRefreshAll()
    }

    /// Import accounts from ~/.llm-monitor/accounts.env (+ accounts.local.env)
    /// additively, then poll everything. Runs once at launch.
    func syncThenRefreshAll() {
        Task {
            let results = await oauthPoller.syncFromAccountFiles()
            if !results.isEmpty {
                let ok = results.filter { $0.success }.count
                flog.info("syncThenRefreshAll: imported \(ok)/\(results.count) account(s) from list files", category: "App")
            }
            await oauthPoller.pollAll()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
                // Export right after the launch poll too, not only on the next
                // due tick: otherwise ranking.json keeps the previous process's
                // account set until some account comes due again.
                RankingExporter.export()
                flog.info("syncThenRefreshAll: loaded \(usageStore.accounts.count) account(s)", category: "App")
            }
        }
    }

    /// Poll all accounts (startup and manual refresh)
    func refreshAll() {
        flog.info("refreshAll: polling all accounts", category: "App")
        Task {
            await oauthPoller.pollAll()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
                // Emit ~/.llm-monitor/ranking.json for external load balancers (#2)
                RankingExporter.export()
                flog.info("refreshAll: loaded \(usageStore.accounts.count) account(s)", category: "App")
            }
        }
    }

    /// Poll any accounts that are due (called by 30s timer)
    func refreshDue() {
        Task {
            let polled = await oauthPoller.pollDue()
            // Fable-tier probe runs on its own (slower) cadence and writes the
            // premium/overage headers the UI reads.
            let fableProbed = await oauthPoller.probeFableDue()
            // Transcript token ingest (#197) runs on a slower cadence still,
            // and self-throttles — a no-op on almost every tick. It feeds the
            // token-history chart, not the live percentages, so it does not
            // participate in the reload/export decision below.
            _ = await oauthPoller.syncTranscriptTokensIfDue()
            // Quota calibration (#198) derives from usage_history + token_usage
            // on the same slow cadence, and likewise feeds no live percentage.
            _ = await oauthPoller.recomputeQuotaCalibrationIfDue()
            if polled > 0 || fableProbed > 0 {
                await MainActor.run {
                    usageStore.loadFromDatabase()
                    updateStatusButton()
                    // Emit ~/.llm-monitor/ranking.json for external load balancers (#2)
                    RankingExporter.export()
                }
            }
        }
    }

    // MARK: - Menubar shows top card (first account)

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        var percent: Int = 0
        var isWeeklyLimit = false
        var calibrationAlertActive = false

        // Menubar follows the user's pinned account, or falls back to most-available.
        let targetAccount = usageStore.accounts.first(where: { $0.id == usageStore.effectivePrimaryAccountId })

        // A stale or drifted account's last-known percentage must not be
        // presented as current (#156) — the same cause-independent gate the
        // popover row already applies via `SummaryRow.displayUsage`. Without
        // this, the badge is the one UI surface visible without opening the
        // popover at all, so a frozen credential could sit silently "healthy"
        // on the menu bar even after the popover row correctly blanks itself.
        if let account = targetAccount {
            let isStale = usageStore.isStale(account)
            let tokenStatus = oauthPoller.credentialStatuses.first(where: { $0.accountId == account.id })?.status
            let suppress = AccountFreshness.shouldSuppressPercent(isStale: isStale, tokenStatus: tokenStatus)

            if !suppress {
                if let usage = usageStore.latestUsage[account.id] {
                    let sessionPercent = usage.sessionPercent ?? 0
                    let weeklyAllPercent = usage.weeklyAllPercent ?? 0
                    percent = Int(max(sessionPercent, weeklyAllPercent))
                    isWeeklyLimit = weeklyAllPercent >= sessionPercent
                } else {
                    percent = Int(account.latestPercent ?? 0)
                    isWeeklyLimit = true
                }
                // Pool-wide quota-calibration step-change alert (#199) —
                // suppressed under the identical rule as the percent readout
                // above: a badge combining "no current reading" with "there's
                // a warning" would be a contradiction, not useful signal.
                calibrationAlertActive = oauthPoller.hasActiveCalibrationAlert
            }
        }

        // Create Stats-style image with "LLM" label and percentage
        button.image = createStatsStyleImage(
            percent: percent, isWeeklyLimit: isWeeklyLimit, calibrationAlertActive: calibrationAlertActive)
        button.title = ""
    }

    func createStatsStyleImage(percent: Int, isWeeklyLimit: Bool, calibrationAlertActive: Bool = false) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .light)
        let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let labelText = "LLM"
        let percentText: String
        if percent > 0 {
            percentText = isWeeklyLimit ? "(\(percent)%)" : "\(percent)%"
        } else {
            percentText = "--"
        }

        let height: CGFloat = 22

        // Measure actual text width so the image (and highlight) fits tightly
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let labelColor: NSColor = isDark ? .white : .textColor

        let valueColor: NSColor
        switch PercentSeverity(percent: Double(percent)) {
        case .critical: valueColor = .systemRed
        case .warning: valueColor = .systemOrange
        case .normal: valueColor = isDark ? .white : .black
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .left

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
            .paragraphStyle: style
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: valueColor,
            .paragraphStyle: style
        ]

        let labelSize = (labelText as NSString).size(withAttributes: labelAttrs)
        let valueSize = (percentText as NSString).size(withAttributes: valueAttrs)
        let blockWidth = max(labelSize.width, valueSize.width)
        // 2pt padding on each side for breathing room
        let contentWidth = ceil(blockWidth) + 4

        // A calibration step-change alert (#199) gets its own small dot to the
        // right of the label/percentage block, in a color no `PercentSeverity`
        // band ever uses (red/orange/black-or-white) — a distinct visual
        // channel, not a fourth shade competing with the existing three.
        let badgeDiameter: CGFloat = 5
        let badgeGap: CGFloat = 3
        let width = contentWidth + (calibrationAlertActive ? badgeDiameter + badgeGap : 0)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let xOffset = (contentWidth - blockWidth) / 2

            let labelRect = CGRect(x: xOffset, y: 14, width: blockWidth, height: 7)
            let labelStr = NSAttributedString(string: labelText, attributes: labelAttrs)
            labelStr.draw(with: labelRect)

            let valueRect = CGRect(x: xOffset, y: 3, width: blockWidth, height: 13)
            let valueStr = NSAttributedString(string: percentText, attributes: valueAttrs)
            valueStr.draw(with: valueRect)

            if calibrationAlertActive {
                let badgeRect = CGRect(
                    x: contentWidth + badgeGap, y: height - badgeDiameter - 2,
                    width: badgeDiameter, height: badgeDiameter)
                NSColor.systemTeal.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - M3.2: Right-click context menu

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Account list sorted by availability
        for account in usageStore.sortedAccountsForPopover {
            let item = NSMenuItem(
                title: account.displayName,
                action: #selector(selectAccount(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id
            if account.isAbsent {
                // An absent identity (#135) has no reading and never will
                // until it is provisioned here — say so rather than leave a
                // bare name that reads like an account with nothing used yet.
                item.title = "\(account.displayName) (\(CodexCLI.absentLabel))"
            } else if let usage = usageStore.latestUsage[account.id] {
                let pct = Int(max(usage.sessionPercent ?? 0, usage.weeklyAllPercent ?? 0))
                item.title = "\(account.displayName) (\(pct)%)"
            }
            menu.addItem(item)
        }

        if !usageStore.accounts.isEmpty {
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Reset menu so left-click still shows popover
        statusItem?.menu = nil
    }

    @objc func selectAccount(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? String,
              let account = usageStore.accounts.first(where: { $0.id == accountId }) else { return }
        ChartWindowController.showChart(for: account, store: usageStore)
    }

    func togglePopover() {
        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else if let button = statusItem?.button {
                heightManager.update(rowCount: usageStore.accounts.count)
                refreshAll()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    // MARK: - Add Account Window

    func openAddAccountWindow() {
        flog.info("openAddAccountWindow called", category: "App")

        // Close the popover first, then open window after a delay
        // to avoid AppKit layout crash during popover dismissal
        popover?.performClose(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            if let window = self.loginWizardWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let addAccountView = AddAccountView(store: self.usageStore, oauthPoller: self.oauthPoller, onDone: { [weak self] in
                self?.loginWizardWindow?.close()
                self?.loginWizardWindow = nil
            }, onImported: { [weak self] in
                // Poll the freshly-added credentials so credentialStatuses populates
                // (the import only pings — it doesn't update poller status), and the
                // popover sees an up-to-date snapshot when it next opens.
                self?.refreshAll()
            })

            let hostingController = NSHostingController(rootView: addAccountView)
            if #available(macOS 13.0, *) {
                hostingController.sizingOptions = []
            }
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Add Account"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 360, height: 420))
            window.center()
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.loginWizardWindow = window

            self.flog.info("Add Account window opened", category: "App")
        }
    }

}

#endif  // os(macOS)
