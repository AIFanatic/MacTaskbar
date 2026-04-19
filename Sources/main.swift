import AppKit
import CoreGraphics

private let barHeight: CGFloat = 35
private let iconSize: CGFloat = 25
private let buttonHeight: CGFloat = 35
private let pinnedButtonWidth: CGFloat = 38
private let windowButtonWidth: CGFloat = 220
private let minimumWindowSize: CGFloat = 80
private let refreshInterval: TimeInterval = 0.3

private let pinnedItems: [PinnedItem] = [
    .app(name: "Finder", bundleIdentifier: "com.apple.finder"),
    .folder(name: "Applications", path: "/Applications")
]

@MainActor
private enum TaskbarSettings {
    static let barMaterial: NSVisualEffectView.Material = .hudWindow
    static let barBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88)
    static let focusedEntryColor = NSColor.systemBlue.withAlphaComponent(0.42)
    static let normalEntryColor = NSColor.clear
    static let entryTextColor = NSColor(calibratedWhite: 0.92, alpha: 1)
    static let entryCornerRadius: CGFloat = 8
}

@main
@MainActor
final class MacTaskbarApp: NSObject, NSApplicationDelegate {
    private var controller: TaskbarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = MacTaskbarApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = TaskbarController()
        controller?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct WindowItem: Equatable {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let displayID: CGDirectDisplayID
    let appName: String
    let title: String
    let icon: NSImage
}

enum PinnedItem: Equatable {
    case app(name: String, bundleIdentifier: String)
    case folder(name: String, path: String)

    var id: String {
        switch self {
        case .app(_, let bundleIdentifier):
            return "app:\(bundleIdentifier)"
        case .folder(_, let path):
            return "folder:\(path)"
        }
    }

    var name: String {
        switch self {
        case .app(let name, _), .folder(let name, _):
            return name
        }
    }

    var icon: NSImage {
        switch self {
        case .app(_, let bundleIdentifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return NSImage(size: NSSize(width: iconSize, height: iconSize))
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .folder(_, let path):
            return NSWorkspace.shared.icon(forFile: path)
        }
    }

    var isFinder: Bool {
        guard case .app(_, let bundleIdentifier) = self else {
            return false
        }
        return bundleIdentifier == "com.apple.finder"
    }
}

enum TaskbarEntry: Equatable {
    case pinned(PinnedItem)
    case window(WindowItem)
}

private extension TaskbarEntry {
    var windowID: CGWindowID? {
        guard case .window(let item) = self else {
            return nil
        }
        return item.windowID
    }

    var title: String {
        switch self {
        case .pinned(let item):
            return item.name
        case .window(let item):
            return item.title
        }
    }

    var tooltip: String {
        switch self {
        case .pinned(let item):
            return item.name
        case .window(let item):
            return "\(item.appName): \(item.title)"
        }
    }

    var icon: NSImage {
        switch self {
        case .pinned(let item):
            return item.icon
        case .window(let item):
            return item.icon
        }
    }

    var buttonWidth: CGFloat {
        switch self {
        case .pinned:
            return pinnedButtonWidth
        case .window:
            return windowButtonWidth
        }
    }

    var showsTitle: Bool {
        switch self {
        case .pinned:
            return false
        case .window:
            return true
        }
    }
}

private extension WindowItem {
    static func stableSort(lhs: WindowItem, rhs: WindowItem) -> Bool {
        let appComparison = lhs.appName.localizedStandardCompare(rhs.appName)
        if appComparison != .orderedSame {
            return appComparison == .orderedAscending
        }

        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        if lhs.processIdentifier != rhs.processIdentifier {
            return lhs.processIdentifier < rhs.processIdentifier
        }

        return lhs.windowID < rhs.windowID
    }
}

@MainActor
final class TaskbarController {
    private var bars: [CGDirectDisplayID: DisplayTaskbar] = [:]
    private var itemsByWindowID: [CGWindowID: WindowItem] = [:]
    private var refreshTimer: Timer?

    init() {
        installObservers()
        rebuildBars()
        refresh()
    }

    func show() {
        for bar in bars.values {
            bar.show()
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    @objc func refresh() {
        let items = WindowReader.readWindows()
        let groupedItems = Dictionary(grouping: items, by: \.displayID)
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let activeWindowID = items.first { $0.processIdentifier == activePID }?.windowID

        itemsByWindowID = Dictionary(uniqueKeysWithValues: items.map { ($0.windowID, $0) })

        for (displayID, bar) in bars {
            bar.update(windows: groupedItems[displayID] ?? [], pinnedItems: pinnedItems, activeWindowID: activeWindowID)
        }
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(workspaceChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(workspaceChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(workspaceChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        refresh()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        rebuildBars()
        refresh()
    }

    private func rebuildBars() {
        let screensByDisplayID = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
                guard let displayID = screen.displayID else {
                    return nil
                }
                return (displayID, screen)
            }
        )

        for displayID in bars.keys where screensByDisplayID[displayID] == nil {
            bars[displayID]?.close()
            bars.removeValue(forKey: displayID)
        }

        for (displayID, screen) in screensByDisplayID {
            if let bar = bars[displayID] {
                bar.updateScreen(screen)
            } else {
                let bar = DisplayTaskbar(screen: screen, displayID: displayID, target: self)
                bars[displayID] = bar
                bar.show()
            }
        }
    }

    @objc func activateEntry(_ sender: TaskbarEntryButton) {
        switch sender.entry {
        case .pinned(let item):
            activatePinnedItem(item)
        case .window(let item):
            activateApp(processIdentifier: item.processIdentifier)
        }
    }

    @objc func activateWindowOwner(_ sender: TaskbarEntryButton) {
        guard let windowID = sender.windowID,
              let item = itemsByWindowID[windowID] else {
            refresh()
            return
        }

        activateApp(processIdentifier: item.processIdentifier)
    }

    @objc func activateWindowOwnerMenuItem(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? CGWindowID,
              let item = itemsByWindowID[windowID] else {
            refresh()
            return
        }

        activateApp(processIdentifier: item.processIdentifier)
    }

    @objc func quitWindowOwner(_ sender: NSMenuItem) {
        guard let processIdentifier = sender.representedObject as? pid_t,
              let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            refresh()
            return
        }

        app.terminate()
        refresh()
    }

    func showContextMenu(for button: TaskbarEntryButton) {
        switch button.entry {
        case .pinned(let item):
            showPinnedContextMenu(for: item, relativeTo: button)
        case .window:
            showWindowContextMenu(for: button)
        }
    }

    func showBarContextMenu(relativeTo view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu(_:)), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit MacTaskbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func refreshFromMenu(_ sender: NSMenuItem) {
        refresh()
    }

    private func showWindowContextMenu(for button: TaskbarEntryButton) {
        guard let windowID = button.windowID,
              let item = itemsByWindowID[windowID] else {
            refresh()
            return
        }

        let menu = NSMenu()
        let activateItem = NSMenuItem(title: "Activate \(item.title)", action: #selector(activateWindowOwnerMenuItem(_:)), keyEquivalent: "")
        activateItem.target = self
        activateItem.representedObject = item.windowID
        menu.addItem(activateItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(item.appName)", action: #selector(quitWindowOwner(_:)), keyEquivalent: "")
        quitItem.target = self
        quitItem.representedObject = item.processIdentifier
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func showPinnedContextMenu(for item: PinnedItem, relativeTo button: TaskbarEntryButton) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open \(item.name)", action: #selector(activatePinnedMenuItem(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = item.id
        menu.addItem(openItem)

        if case .app(_, let bundleIdentifier) = item,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit \(item.name)", action: #selector(quitPinnedAppMenuItem(_:)), keyEquivalent: "")
            quitItem.target = self
            quitItem.representedObject = app.processIdentifier
            menu.addItem(quitItem)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc func activatePinnedMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = pinnedItems.first(where: { $0.id == id }) else {
            return
        }

        activatePinnedItem(item)
    }

    @objc func quitPinnedAppMenuItem(_ sender: NSMenuItem) {
        guard let processIdentifier = sender.representedObject as? pid_t,
              let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            refresh()
            return
        }

        app.terminate()
        refresh()
    }

    private func activateApp(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            refresh()
            return
        }

        app.activate(options: [.activateAllWindows])
        refresh()
    }

    private func activatePinnedItem(_ item: PinnedItem) {
        switch item {
        case .app(_, let bundleIdentifier):
            if item.isFinder {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
                refresh()
                return
            }

            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                app.activate(options: [.activateAllWindows])
                refresh()
                return
            }

            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .folder(_, let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        refresh()
    }
}

@MainActor
final class DisplayTaskbar {
    private let panel: NSPanel
    private let documentView = NSView()
    private let stackView = NSStackView()
    private weak var target: TaskbarController?
    private var screen: NSScreen
    private var currentItems: [TaskbarEntry] = []
    private var currentActiveWindowID: CGWindowID?

    init(screen: NSScreen, displayID: CGDirectDisplayID, target: TaskbarController) {
        self.screen = screen
        self.target = target
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureContent()
        positionPanel()
    }

    func show() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    func updateScreen(_ screen: NSScreen) {
        self.screen = screen
        positionPanel()
    }

    func update(windows: [WindowItem], pinnedItems: [PinnedItem], activeWindowID: CGWindowID?) {
        let stableItems = entriesPreservingCurrentOrder(windows: windows, pinnedItems: pinnedItems)

        guard stableItems != currentItems || activeWindowID != currentActiveWindowID else {
            return
        }

        currentItems = stableItems
        currentActiveWindowID = activeWindowID
        rebuildButtons(activeWindowID: activeWindowID)
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
    }

    private func configureContent() {
        let root = TaskbarRootView()
        root.controller = target
        root.material = TaskbarSettings.barMaterial
        root.appearance = NSAppearance(named: .darkAqua)
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 0
        root.layer?.backgroundColor = TaskbarSettings.barBackgroundColor.cgColor

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            documentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor)
        ])

        panel.contentView = root
    }

    private func rebuildButtons(activeWindowID: CGWindowID?) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in currentItems {
            let button = TaskbarEntryButton(
                item: item,
                isActive: item.windowID.map { $0 == activeWindowID } ?? false
            )
            button.target = target
            button.action = #selector(TaskbarController.activateEntry(_:))
            stackView.addArrangedSubview(button)
        }

        addTrailingSpacer()
    }

    private func addTrailingSpacer() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(spacer)
    }

    private func entriesPreservingCurrentOrder(windows: [WindowItem], pinnedItems: [PinnedItem]) -> [TaskbarEntry] {
        let pinnedEntries = pinnedItems.map(TaskbarEntry.pinned)
        let windowsByWindowID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let retainedWindows = currentItems.compactMap { entry -> WindowItem? in
            guard case .window(let item) = entry else {
                return nil
            }
            return windowsByWindowID[item.windowID]
        }
        let retainedWindowIDs = Set(retainedWindows.map(\.windowID))
        let newWindows = windows
            .filter { !retainedWindowIDs.contains($0.windowID) }
            .sorted(by: WindowItem.stableSort)

        return pinnedEntries + (retainedWindows + newWindows).map(TaskbarEntry.window)
    }

    private func positionPanel() {
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: barHeight),
            display: true
        )
    }
}

@MainActor
final class TaskbarRootView: NSVisualEffectView {
    weak var controller: TaskbarController?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showBarContextMenu(relativeTo: self, at: convert(event.locationInWindow, from: nil))
    }
}

@MainActor
final class TaskbarEntryButton: NSButton {
    let entry: TaskbarEntry
    let windowID: CGWindowID?

    init(item: TaskbarEntry, isActive: Bool) {
        entry = item
        windowID = item.windowID
        super.init(frame: NSRect(x: 0, y: 0, width: item.buttonWidth, height: buttonHeight))

        title = ""
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        toolTip = item.tooltip

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true
        widthAnchor.constraint(equalToConstant: item.buttonWidth).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        layer?.cornerRadius = TaskbarSettings.entryCornerRadius
        layer?.backgroundColor = isActive
            ? TaskbarSettings.focusedEntryColor.cgColor
            : TaskbarSettings.normalEntryColor.cgColor

        let icon = (item.icon.copy() as? NSImage) ?? item.icon
        icon.size = NSSize(width: iconSize, height: iconSize)

        let imageView = NSImageView(image: icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)

        if item.showsTitle {
            let titleLabel = NSTextField(labelWithString: item.title)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 1
            titleLabel.textColor = TaskbarSettings.entryTextColor
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            addSubview(titleLabel)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: iconSize),
                imageView.heightAnchor.constraint(equalToConstant: iconSize),
                titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: iconSize),
                imageView.heightAnchor.constraint(equalToConstant: iconSize)
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller = target as? TaskbarController else {
            super.rightMouseDown(with: event)
            return
        }

        controller.showContextMenu(for: self)
    }
}

enum WindowReader {
    @MainActor
    static func readWindows() -> [WindowItem] {
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var runningAppsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let processIdentifier = app.processIdentifier
            guard processIdentifier > 0, runningAppsByPID[processIdentifier] == nil else {
                continue
            }
            runningAppsByPID[processIdentifier] = app
        }
        let currentBundleID = Bundle.main.bundleIdentifier

        return windowInfos.compactMap { info -> WindowItem? in
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let processIdentifier = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = runningAppsByPID[processIdentifier],
                  app.activationPolicy == .regular,
                  !app.isTerminated,
                  app.bundleIdentifier != currentBundleID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = readBounds(from: info),
                  bounds.width >= minimumWindowSize,
                  bounds.height >= minimumWindowSize,
                  let displayID = bestDisplayID(for: bounds) else {
                return nil
            }

            let appName = app.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? "App"
            let windowTitle = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = windowTitle?.isEmpty == false ? windowTitle! : appName

            return WindowItem(
                windowID: windowID,
                processIdentifier: processIdentifier,
                displayID: displayID,
                appName: appName,
                title: title,
                icon: app.icon ?? NSImage(size: NSSize(width: iconSize, height: iconSize))
            )
        }
    }

    private static func readBounds(from info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }

        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect) else {
            return nil
        }
        return rect
    }

    private static func bestDisplayID(for windowBounds: CGRect) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return nil
        }

        return displayIDs
            .map { displayID in
                (displayID, CGDisplayBounds(displayID).intersection(windowBounds).area)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isEmpty else {
            return 0
        }
        return width * height
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
