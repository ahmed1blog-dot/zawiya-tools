import AppKit
import SwiftUI
import ZawiyaCore
import QuartzCore
import Combine

final class FloatingPanel: NSPanel {
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DragWheel {
    private let workspace: Workspace
    private let preferences: Preferences
    private var timer: Timer?
    private var panel: FloatingPanel?
    private var shelfPanel: NSPanel?
    private var wasDown = false
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var origin = NSPoint.zero
    private var shownMode = ""
    private var releaseAt: Date?
    private var shelfObserver: NSObjectProtocol?
    private var quickObserver: NSObjectProtocol?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timerInterval: TimeInterval = 0
    private var lastPoll: TimeInterval = 0
    private var manualOpen = false
    private var cells: [WheelDropView] = []
    private var feedbackGate = FeedbackGate()
    private var selection: Int?
    private var choices: [(String, String, ([URL]) -> Void)] = []
    private var activeURLs: [URL] = []
    private let presentation = WheelPresentation()
    private var statusObservation: AnyCancellable?
    private var statusPanel: FloatingPanel?
    private var hideStatusWork: DispatchWorkItem?
    private var suppressedQuickJob: UUID?


    init(workspace: Workspace, preferences: Preferences) { self.workspace = workspace; self.preferences = preferences }
    func start() {
        guard timer == nil else { return }
        scheduleTimer(0.3)
        statusObservation = workspace.quickActions.$jobs.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.showQuickStatus() }
        }
        // Mouse events need no Accessibility permission. Keyboard events are observed
        // only inside this app, to let Escape dismiss a manually opened wheel.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if let self, self.panel != nil {
                        if event.keyCode == 53 { self.dismiss(); return true }
                        if self.manualOpen {
                            if [123, 124, 125, 126, 48].contains(event.keyCode) {
                                let backwards = [123, 126].contains(event.keyCode) || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
                                self.stepSelection(backwards ? -1 : 1); return true
                            }
                            if event.keyCode == 36 || event.keyCode == 76 { self.commitSelection(); return true }
                        }
                    }
                } else { self?.poll() }
                return false
            }
            return consumed ? nil : event
        }
        shelfObserver = NotificationCenter.default.addObserver(forName: .showShelf, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.showShelf() } }
        quickObserver = NotificationCenter.default.addObserver(forName: .showQuickWheel, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.workspace.pending.isEmpty else { return }
                self.show(mode: notification.object as? String ?? "convert", urls: self.workspace.pending.map(\.url), at: NSEvent.mouseLocation, manual: true)
            }
        }
    }
    private func scheduleTimer(_ interval: TimeInterval) {
        guard timerInterval != interval else { return }
        timer?.invalidate(); timerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = interval == 0.3 ? 0.08 : 0.01
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPoll >= 1.0 / 60 else { return }
        lastPoll = now; tick()
    }
    private func tick() {
        if manualOpen {
            if NSEvent.pressedMouseButtons & 1 != 0, let panel, !panel.frame.contains(NSEvent.mouseLocation) { dismiss() }
            return
        }
        guard preferences.wheelEnabled, !workspace.isRunning else {
            dismiss(); wasDown = false; baseline = NSPasteboard(name: .drag).changeCount; scheduleTimer(0.3); return
        }
        let pasteboard = NSPasteboard(name: .drag)
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if !down {
            if wasDown { releaseAt = Date() }
            if let releaseAt, Date().timeIntervalSince(releaseAt) > 0.14 { dismiss() }
            wasDown = false; baseline = pasteboard.changeCount
            scheduleTimer(panel == nil ? 0.3 : 0.05)
            return
        }
        scheduleTimer(0.05)
        if !wasDown { origin = NSEvent.mouseLocation; shownMode = ""; releaseAt = nil }
        wasDown = true
        let point = NSEvent.mouseLocation
        guard hypot(point.x - origin.x, point.y - origin.y) > 8, pasteboard.changeCount != baseline else { return }
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mode = flags.contains(.control) ? "actions" : flags.contains(.command) ? "tools" : flags.contains(.shift) ? "convert" : ""
        guard !mode.isEmpty, mode != shownMode,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        show(mode: mode, urls: urls, at: point)
        shownMode = mode
    }
    private func menuChoices(mode: String, urls: [URL]) -> [(String, String, ([URL]) -> Void)] {
        let ar = preferences.arabic
        let kinds = urls.map(FileKind.detect)
        if mode == "convert" {
            return MenuCatalog.commonFormats(for: kinds, favorites: preferences.favoriteFormats).map { format in (format.uppercased(), MenuCatalog.symbol(for: format), { [weak self] in self?.workspace.wheelConvert($0, format: format) }) }
        }
        if mode == "tools" {
            return MenuCatalog.tools(for: kinds).filter { $0 != .convert }.map { tool in (tool.title(ar) + (tool.runsImmediatelyFromWheel ? "" : "…"), tool.icon, { [weak self] in self?.workspace.wheelTool($0, tool: tool) }) }
        }
        let actions = [("airdrop", "AirDrop", "antenna.radiowaves.left.and.right"), ("float", ar ? "رف عائم" : "Float", "square.stack"), ("copy", ar ? "نسخ" : "Copy", "doc.on.doc"), ("move", ar ? "نقل" : "Move", "folder"), ("path", ar ? "نسخ المسار" : "Copy path", "link"), ("terminal", "Terminal", "terminal")]
        return actions.map { action in (action.1, action.2, { [weak self] in self?.workspace.fileAction(action.0, urls: $0) }) }
    }
    private func content(mode: String, urls: [URL], manual: Bool, size: CGSize, at point: NSPoint) -> NSView {
        choices = menuChoices(mode: mode, urls: urls); activeURLs = urls
        cells = []; selection = nil; feedbackGate = FeedbackGate()
        presentation.title = preferences.text(mode == "convert" ? "حوّل" : mode == "tools" ? "أدوات" : "إجراءات", mode == "convert" ? "Convert" : mode == "tools" ? "Tools" : "Actions")
        let geometry = WheelGeometry(count: choices.count)
        let dark = preferences.nativeDark
        let root = NSView(frame: NSRect(origin: .zero, size: size)); root.bounds = CGRect(origin: .zero, size: geometry.size)
        let backdrop = NSVisualEffectView(frame: root.bounds)
        backdrop.material = .popover; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = geometry.size.width / 2; backdrop.layer?.masksToBounds = true
        let tint = NSView(frame: root.bounds); tint.wantsLayer = true
        let base = dark ? NSColor(calibratedRed: 0.059, green: 0.090, blue: 0.165, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)
        let solid = preferences.wheelAppearance == "solid" || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        tint.layer?.backgroundColor = base.withAlphaComponent(solid ? 1 : dark ? 0.65 : 0.75).cgColor
        tint.layer?.cornerRadius = geometry.size.width / 2
        tint.layer?.borderWidth = 1; tint.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.12).cgColor
        root.addSubview(backdrop); root.addSubview(tint)
        let switchMode: (String) -> Void = { [weak self] selected in self?.show(mode: selected, urls: urls, at: point, manual: true) }
        let center = NSHostingView(rootView: WheelCenter(presentation: presentation, mode: mode, manual: manual, dark: dark, arabic: preferences.arabic, switchMode: switchMode).preferredColorScheme(dark ? .dark : .light))
        center.frame = geometry.centerFrame; root.addSubview(center)
        for (i, choice) in choices.enumerated() {
            let cell = WheelDropView(title: choice.0, symbol: choice.1, dark: dark, motion: preferences.nativeMotion, urls: urls, hover: { [weak self] entered in self?.select(entered ? i : nil, leaving: entered ? nil : i) }) { [weak self] dropped in
                self?.commit(index: i, urls: dropped)
            }
            cell.frame = geometry.frames[i]; cells.append(cell); root.addSubview(cell)
        }
        return root
    }
    // Renders this app's own wheel for visual QA; never opens a window or monitors events.
    func preview(mode: String, urls: [URL]) -> NSView {
        let count = menuChoices(mode: mode, urls: urls).count
        return content(mode: mode, urls: urls, manual: true, size: WheelGeometry(count: count).size, at: .zero)
    }
    private func show(mode: String, urls: [URL], at point: NSPoint, manual: Bool = false) {
        dismiss(animated: false)
        let count = menuChoices(mode: mode, urls: urls).count
        guard count > 0 else {
            if manual { workspace.message = preferences.text("هذه الملفات لا تشترك بصيغة تحويل. اختر أداة مثل ZIP أو افصل الدفعات.", "These files have no shared format. Choose a tool such as ZIP, or split the batch.") }
            return
        }
        if preferences.soundsEnabled { InteractionFeedback.shared.prepare() }
        let geometry = WheelGeometry(count: count)
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = WheelGeometry.presentationFrame(size: geometry.size, pointer: point, screen: screen)
        let panel = FloatingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsKeyboard = manual; panel.title = preferences.text("العجلة السريعة", "Quick wheel")
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content(mode: mode, urls: urls, manual: manual, size: frame.size, at: point)
        panel.setFrame(frame, display: false)
        self.panel = panel; manualOpen = manual
        panel.alphaValue = preferences.nativeMotion ? 0 : 1
        panel.orderFrontRegardless()
        if manual { panel.makeKeyAndOrderFront(nil) }
        if preferences.nativeMotion { NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; context.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().alphaValue = 1 } }
    }
    private func select(_ index: Int?, leaving: Int? = nil) {
        if let leaving, selection != leaving { return }
        selection = index
        for (i, cell) in cells.enumerated() { cell.updateHighlight(i == index) }
        if feedbackGate.select(index, at: ProcessInfo.processInfo.systemUptime) { InteractionFeedback.shared.selection(preferences: preferences) }
    }
    private func stepSelection(_ delta: Int) {
        guard !cells.isEmpty else { return }
        let next = selection.map { ($0 + delta + cells.count) % cells.count } ?? (delta > 0 ? 0 : cells.count - 1)
        select(next)
    }
    private func commitSelection() { if let selection { commit(index: selection, urls: activeURLs) } }
    private func commit(index: Int, urls: [URL]) {
        guard choices.indices.contains(index) else { return }
        let action = choices[index].2
        InteractionFeedback.shared.confirm(preferences: preferences)
        dismiss(); action(urls)
    }
    private func dismiss(animated: Bool = true) {
        manualOpen = false; selection = nil; cells = []; choices = []; activeURLs = []; feedbackGate = FeedbackGate()
        guard let old = panel else { return }; panel = nil
        if animated && preferences.nativeMotion {
            NSAnimationContext.runAnimationGroup({ context in context.duration = 0.08; old.animator().alphaValue = 0 }, completionHandler: { old.orderOut(nil) })
        } else { old.orderOut(nil) }
    }
    private func showShelf() {
        if shelfPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 310), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = preferences.text("رف زاوية", "Zawiya Float"); panel.level = .floating; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: ShelfView().environmentObject(workspace).environmentObject(preferences))
            if let screen = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: screen.maxX - 320, y: screen.midY - 150)) }
            shelfPanel = panel
        }
        shelfPanel?.orderFrontRegardless()
    }
    private func showQuickStatus() {
        guard let job = workspace.quickActions.visibleJob, job.id != suppressedQuickJob else { return }
        hideStatusWork?.cancel()
        let panel = statusPanel ?? FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 150), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = preferences.text("الإجراء السريع", "Quick action")
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: QuickStatusView(actions: workspace.quickActions, preferences: preferences) { [weak self] in
            guard let self else { return }
            self.suppressedQuickJob = self.workspace.quickActions.visibleJob?.id; self.statusPanel?.orderOut(nil); self.hideStatusWork?.cancel()
        }.preferredColorScheme(preferences.nativeDark ? .dark : .light))
        panel.contentView = host
        let height = max(120, host.fittingSize.height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(CGRect(x: screen.maxX - 360, y: screen.minY + 20, width: 340, height: height), display: false)
        statusPanel = panel; panel.orderFrontRegardless()
        if !workspace.quickActions.isProcessing && job.state == .done {
            let hide = DispatchWorkItem { [weak self] in self?.statusPanel?.orderOut(nil) }
            hideStatusWork = hide; DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hide)
        }
    }
}

@MainActor private final class WheelPresentation: ObservableObject {
    @Published var title = ""
}

private struct WheelCenter: View {
    @ObservedObject var presentation: WheelPresentation
    let mode: String
    let manual: Bool
    let dark: Bool
    let arabic: Bool
    let switchMode: (String) -> Void
    var body: some View {
        VStack(spacing: 4) {
            ZawiyaMark(color: Brand.accent(dark)).frame(width: 23, height: 23)
            Text(presentation.title).font(.system(size: 10, weight: .semibold))
            if manual {
                HStack(spacing: 2) {
                    ForEach([("convert", "⇧"), ("tools", "⌘"), ("actions", "⌃")], id: \.0) { item in
                        Button(item.1) { switchMode(item.0) }.buttonStyle(.plain).font(.system(size: 11)).frame(width: 19, height: 17)
                            .background(mode == item.0 ? Brand.accent(dark).opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel(item.0 == "convert" ? (arabic ? "عجلة التحويل" : "Conversion wheel") : item.0 == "tools" ? (arabic ? "عجلة الأدوات" : "Tools wheel") : (arabic ? "عجلة الإجراءات" : "Actions wheel"))
                    }
                }.environment(\.layoutDirection, .leftToRight)
            }
        }.frame(width: 76, height: 76).background(Brand.surface(dark).opacity(0.7), in: Circle())
            .overlay(Circle().stroke(Brand.line(dark), lineWidth: 1))
            .foregroundStyle(dark ? Color.white : Brand.ink)
    }
}

@MainActor final class WheelDropView: NSView {
    let title: String
    let symbol: String
    let dark: Bool
    let motion: Bool
    let urls: [URL]
    let action: ([URL]) -> Void
    let hover: (Bool) -> Void
    var highlighted = false
    init(title: String, symbol: String, dark: Bool, motion: Bool, urls: [URL], hover: @escaping (Bool) -> Void, action: @escaping ([URL]) -> Void) {
        self.title = title; self.symbol = symbol; self.dark = dark; self.motion = motion; self.urls = urls; self.hover = hover; self.action = action
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.borderWidth = 1
        updateHighlight(false)
        registerForDraggedTypes([.fileURL]); setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        setAccessibilityIdentifier("wheel-\(title)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor = highlighted ? NSColor(calibratedRed: 0.024, green: 0.075, blue: 0.122, alpha: 1) : dark ? .white : .black
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        (title as NSString).draw(in: NSRect(x: 3, y: 2, width: bounds.width - 6, height: 27), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: foreground, .paragraphStyle: paragraph])
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) {
            let tinted = image.copy() as! NSImage
            tinted.lockFocus(); foreground.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
            let ratio = min(22 / tinted.size.width, 22 / tinted.size.height)
            let size = NSSize(width: tinted.size.width * ratio, height: tinted.size.height * ratio)
            tinted.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: 32 + (22 - size.height) / 2, width: size.width, height: size.height))
        }
    }
    func updateHighlight(_ value: Bool) {
        guard value != highlighted || layer?.backgroundColor == nil else { return }
        highlighted = value; setAccessibilityValue(value ? 1 : 0)
        let color = value ? NSColor(red: 14/255, green: 165/255, blue: 233/255, alpha: 1) : .clear
        if motion, let old = layer?.presentation()?.backgroundColor {
            let animation = CABasicAnimation(keyPath: "backgroundColor"); animation.fromValue = old; animation.toValue = color.cgColor; animation.duration = 0.09; layer?.add(animation, forKey: "highlight")
        }
        layer?.backgroundColor = color.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    override func mouseDown(with event: NSEvent) { hover(true) }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action(urls) } else { hover(false) } }
    override func accessibilityPerformPress() -> Bool { action(urls); return true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hover(true); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        // Exit AppKit's drag callback before executing actions that can open modal panels.
        DispatchQueue.main.async { self.action(urls) }
        return true
    }
}

struct ShelfView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var preferences: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preferences.text("اسحب ملفك إلى أي تطبيق", "Drag a file into any app")).font(.headline)
            ScrollView { VStack(spacing: 10) { ForEach(workspace.shelf, id: \.self) { url in
                HStack { Image(systemName: FileKind.detect(url).symbol); Text(url.lastPathComponent).lineLimit(1); Spacer(); Button { workspace.shelf.removeAll { $0 == url } } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onDrag { NSItemProvider(object: url as NSURL) }
            } } }
            Text(preferences.text("الرف يحتفظ بمراجع الملفات فقط.", "The shelf keeps file references only.")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 270, minHeight: 270).preferredColorScheme(preferences.scheme)
    }
}
