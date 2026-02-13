import Cocoa

struct ToolInfo {
    var name: String
    var description: String
    var label: String
    var plist: String
    var script: String
}

// MARK: - Custom Toggle Switch

class ToggleSwitch: NSView {
    private(set) var isOn: Bool = false
    var isEnabled: Bool = true {
        didSet {
            let a: Float = isEnabled ? 1.0 : 0.4
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            trackLayer.opacity = a
            knobLayer.opacity = a
            CATransaction.commit()
        }
    }
    var greyed: Bool = false {
        didSet {
            let a: Float = greyed ? 0.4 : 1.0
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            trackLayer.opacity = a
            knobLayer.opacity = a
            CATransaction.commit()
        }
    }
    var target: AnyObject?
    var action: Selector?

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    init(isOn: Bool, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        let r = bounds.insetBy(dx: 1, dy: 1)

        trackLayer.frame = r
        trackLayer.cornerRadius = r.height / 2
        trackLayer.backgroundColor = isOn ? NSColor.systemGreen.cgColor : NSColor.systemGray.cgColor
        layer?.addSublayer(trackLayer)

        let knobD = r.height - 4
        let knobX = isOn ? r.width - knobD - 3 : CGFloat(3)
        let knobY = (r.height - knobD) / 2
        knobLayer.frame = CGRect(x: r.minX + knobX, y: r.minY + knobY, width: knobD, height: knobD)
        knobLayer.cornerRadius = knobD / 2
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.2
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        knobLayer.shadowRadius = 2
        layer?.addSublayer(knobLayer)

        self.isOn = isOn
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on

        let r = bounds.insetBy(dx: 1, dy: 1)
        let knobD = r.height - 4
        let newKnobX = isOn ? r.minX + r.width - knobD - 3 : r.minX + 3
        let newColor = isOn ? NSColor.systemGreen.cgColor : NSColor.systemGray.cgColor

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

            let posAnim = CABasicAnimation(keyPath: "position.x")
            posAnim.fromValue = knobLayer.frame.midX
            posAnim.toValue = newKnobX + knobD / 2
            knobLayer.add(posAnim, forKey: "slide")

            let colorAnim = CABasicAnimation(keyPath: "backgroundColor")
            colorAnim.fromValue = trackLayer.backgroundColor
            colorAnim.toValue = newColor
            trackLayer.add(colorAnim, forKey: "color")

            CATransaction.commit()
        }

        knobLayer.frame.origin.x = newKnobX
        trackLayer.backgroundColor = newColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setOn(!isOn, animated: true)
        if let t = target, let a = action {
            NSApp.sendAction(a, to: t, from: self)
        }
    }
}

// MARK: - App

class ToolManagerApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var toolToggles: [(label: String, plist: String, toggle: ToggleSwitch, spinner: NSProgressIndicator)] = []
    var masterToggle: ToggleSwitch!
    var masterSpinner: NSProgressIndicator!
    var masterEnabled: Bool = true
    var uninstallMode: Bool = false
    var uninstallChecks: [(tool: ToolInfo, check: NSButton)] = []
    let W: CGFloat = 300

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Tools")
            b.target = self
            b.action = #selector(showPanel)
        }
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
    }

    @objc func showPanel() {
        if panel.isVisible && panel.isKeyWindow { panel.orderOut(nil); return }
        uninstallMode = false
        build()
        guard let bf = statusItem.button?.window?.frame else { return }
        let x = bf.midX - W / 2
        let y = bf.minY - panel.frame.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func build() {
        toolToggles.removeAll()
        uninstallChecks.removeAll()
        let cv = NSView()
        let tools = loadTools()
        let runStates = tools.map { isRunning(label: $0.label) }

        // Master is ON if any tool is running
        if !uninstallMode {
            masterEnabled = runStates.contains(true) || tools.isEmpty
        }

        let toolRows: CGFloat = CGFloat(max(tools.count, 1)) * 44
        let h: CGFloat = 12 + 32 + 8 + toolRows + 8 + 28 + 8 + 18
        cv.frame = NSRect(x: 0, y: 0, width: W, height: h)
        panel.setContentSize(NSSize(width: W, height: h))
        var y = h

        if uninstallMode {
            // Uninstall mode header
            y -= 32 + 8
            let ml = NSTextField(labelWithString: "Select Tools to Remove")
            ml.font = .boldSystemFont(ofSize: 14)
            ml.frame = NSRect(x: 14, y: y + 6, width: W - 28, height: 20)
            cv.addSubview(ml)

            // Line
            y -= 1
            let s1 = NSBox(frame: NSRect(x: 12, y: y, width: W - 24, height: 1)); s1.boxType = .separator
            cv.addSubview(s1)

            // Tool checkboxes
            if tools.isEmpty {
                y -= 44
                let e = NSTextField(labelWithString: "No tools installed")
                e.textColor = .secondaryLabelColor; e.font = .systemFont(ofSize: 13)
                e.frame = NSRect(x: 14, y: y + 14, width: W - 28, height: 18)
                cv.addSubview(e)
            } else {
                for tool in tools {
                    y -= 44

                    let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                    cb.frame = NSRect(x: 14, y: y + 14, width: 18, height: 18)
                    cv.addSubview(cb)

                    let nm = NSTextField(labelWithString: tool.name)
                    nm.font = .systemFont(ofSize: 13)
                    nm.frame = NSRect(x: 36, y: y + 24, width: W - 50, height: 16)
                    cv.addSubview(nm)

                    let ds = NSTextField(labelWithString: tool.description)
                    ds.font = .systemFont(ofSize: 10); ds.textColor = .secondaryLabelColor
                    ds.frame = NSRect(x: 36, y: y + 6, width: W - 50, height: 14)
                    cv.addSubview(ds)

                    uninstallChecks.append((tool: tool, check: cb))
                }
            }
        } else {
            // Normal mode — master toggle + tool toggles
            y -= 32 + 8
            let ml = NSTextField(labelWithString: "Jeff's Sic Tools Manager")
            ml.font = .boldSystemFont(ofSize: 14)
            ml.frame = NSRect(x: 14, y: y + 6, width: 220, height: 20)
            cv.addSubview(ml)

            masterToggle = ToggleSwitch(isOn: masterEnabled, frame: NSRect(x: W - 62, y: y + 5, width: 46, height: 24))
            masterToggle.target = self
            masterToggle.action = #selector(masterClicked)
            cv.addSubview(masterToggle)

            masterSpinner = makeSpinner(x: W - 86, y: y + 8)
            cv.addSubview(masterSpinner)

            // Line
            y -= 1
            let s1 = NSBox(frame: NSRect(x: 12, y: y, width: W - 24, height: 1)); s1.boxType = .separator
            cv.addSubview(s1)

            // Tools
            if tools.isEmpty {
                y -= 44
                let e = NSTextField(labelWithString: "No tools installed")
                e.textColor = .secondaryLabelColor; e.font = .systemFont(ofSize: 13)
                e.frame = NSRect(x: 14, y: y + 14, width: W - 28, height: 18)
                cv.addSubview(e)
            } else {
                for (i, tool) in tools.enumerated() {
                    y -= 44

                    let nm = NSTextField(labelWithString: tool.name)
                    nm.font = .systemFont(ofSize: 13)
                    nm.frame = NSRect(x: 14, y: y + 24, width: W - 80, height: 16)
                    cv.addSubview(nm)

                    let ds = NSTextField(labelWithString: tool.description)
                    ds.font = .systemFont(ofSize: 10); ds.textColor = .secondaryLabelColor
                    ds.frame = NSRect(x: 14, y: y + 6, width: W - 80, height: 14)
                    cv.addSubview(ds)

                    let tg = ToggleSwitch(isOn: runStates[i], frame: NSRect(x: W - 62, y: y + 12, width: 46, height: 24))
                    tg.target = self
                    tg.action = #selector(toolClicked(_:))
                    tg.greyed = !masterEnabled
                    cv.addSubview(tg)

                    let sp = makeSpinner(x: W - 86, y: y + 15)
                    cv.addSubview(sp)

                    toolToggles.append((label: tool.label, plist: tool.plist, toggle: tg, spinner: sp))
                }
            }
        }

        // Line
        y -= 1
        let s2 = NSBox(frame: NSRect(x: 12, y: y, width: W - 24, height: 1)); s2.boxType = .separator
        cv.addSubview(s2)

        // Buttons — 3 columns
        y -= 28
        let bw: CGFloat = 86
        let gap: CGFloat = (W - bw * 3) / 4

        if uninstallMode {
            let cb = NSButton(title: "Cancel", target: self, action: #selector(cancelUninstall))
            cb.bezelStyle = .inline
            cb.frame = NSRect(x: gap, y: y + 4, width: bw, height: 20)
            cv.addSubview(cb)

            let rb = NSButton(title: "Remove Selected", target: self, action: #selector(removeSelected))
            rb.bezelStyle = .inline
            rb.contentTintColor = .systemRed
            rb.frame = NSRect(x: gap * 2 + bw, y: y + 4, width: bw, height: 20)
            cv.addSubview(rb)
        } else {
            let eb = NSButton(title: "Edit", target: self, action: #selector(editTools))
            eb.bezelStyle = .inline
            eb.frame = NSRect(x: gap, y: y + 4, width: bw, height: 20)
            cv.addSubview(eb)

            let ub = NSButton(title: "Uninstall", target: self, action: #selector(enterUninstall))
            ub.bezelStyle = .inline
            ub.frame = NSRect(x: gap * 2 + bw, y: y + 4, width: bw, height: 20)
            cv.addSubview(ub)
        }

        let qb = NSButton(title: "Quit", target: self, action: #selector(quit))
        qb.bezelStyle = .inline
        qb.frame = NSRect(x: gap * 3 + bw * 2, y: y + 4, width: bw, height: 20)
        cv.addSubview(qb)

        // Version + auto-update toggle row at bottom
        let versionStr = readCoreVersion()
        let vl = NSTextField(labelWithString: versionStr)
        vl.font = .systemFont(ofSize: 11)
        vl.textColor = .secondaryLabelColor
        vl.frame = NSRect(x: 14, y: 2, width: 80, height: 16)
        cv.addSubview(vl)

        let autoLabel = NSTextField(labelWithString: "Auto-update")
        autoLabel.font = .systemFont(ofSize: 11)
        autoLabel.textColor = .secondaryLabelColor
        autoLabel.frame = NSRect(x: W - 130, y: 2, width: 80, height: 16)
        cv.addSubview(autoLabel)

        let updaterRunning = isRunning(label: "com.custom-tools.updater")
        let autoToggle = ToggleSwitch(isOn: updaterRunning, frame: NSRect(x: W - 52, y: 1, width: 40, height: 20))
        autoToggle.target = self
        autoToggle.action = #selector(autoUpdateToggled(_:))
        cv.addSubview(autoToggle)

        panel.contentView = cv
    }

    func readCoreVersion() -> String {
        let path = NSHomeDirectory() + "/.local/sic-versions"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("core=") {
                let ver = String(trimmed.dropFirst(5))
                return "v" + ver
            }
        }
        return ""
    }

    func makeSpinner(x: CGFloat, y: CGFloat) -> NSProgressIndicator {
        let s = NSProgressIndicator(frame: NSRect(x: x, y: y, width: 16, height: 16))
        s.style = .spinning; s.controlSize = .small; s.isDisplayedWhenStopped = false
        return s
    }

    // MARK: - Actions

    @objc func toolClicked(_ sender: ToggleSwitch) {
        guard let row = toolToggles.first(where: { $0.toggle === sender }) else { return }

        // If master is OFF, just toggle visually — no launchctl
        if !masterEnabled { return }

        // Master is ON — actually load/unload
        let turnOn = sender.isOn
        row.spinner.startAnimation(nil)
        sender.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.launchctl([turnOn ? "load" : "unload", row.plist])
            Thread.sleep(forTimeInterval: 0.3)
            let actual = self?.isRunning(label: row.label) ?? false
            DispatchQueue.main.async {
                sender.setOn(actual, animated: true)
                row.spinner.stopAnimation(nil)
                sender.isEnabled = true
            }
        }
    }

    @objc func masterClicked() {
        let turnOn = masterToggle.isOn
        masterEnabled = turnOn
        masterSpinner.startAnimation(nil)
        masterToggle.isEnabled = false

        // Grey/ungrey tool toggles — positions stay the same
        for row in toolToggles {
            row.toggle.greyed = !turnOn
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if turnOn {
                // Master ON: load tools whose toggles are ON
                for row in self.toolToggles {
                    if row.toggle.isOn && !self.isRunning(label: row.label) {
                        self.launchctl(["load", row.plist])
                    }
                }
            } else {
                // Master OFF: unload ALL running tools
                for row in self.toolToggles {
                    if self.isRunning(label: row.label) {
                        self.launchctl(["unload", row.plist])
                    }
                }
            }

            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.async {
                self.masterSpinner.stopAnimation(nil)
                self.masterToggle.isEnabled = true
            }
        }
    }

    @objc func autoUpdateToggled(_ sender: ToggleSwitch) {
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/com.custom-tools.updater.plist"
        if sender.isOn {
            launchctl(["load", plist])
        } else {
            launchctl(["unload", plist])
        }
    }

    @objc func enterUninstall() {
        uninstallMode = true
        build()
    }

    @objc func cancelUninstall() {
        uninstallMode = false
        build()
    }

    @objc func removeSelected() {
        let selected = uninstallChecks.filter { $0.check.state == .on }.map { $0.tool }
        guard !selected.isEmpty else { return }

        let fm = FileManager.default
        let toolDir = NSHomeDirectory() + "/.local/tools"

        for tool in selected {
            // Unload the service if running
            if isRunning(label: tool.label) {
                launchctl(["unload", tool.plist])
            }
            // Delete script file
            if !tool.script.isEmpty { try? fm.removeItem(atPath: tool.script) }
            // Delete plist file
            if !tool.plist.isEmpty { try? fm.removeItem(atPath: tool.plist) }
            // Delete .tool manifest — find by matching label
            if let files = try? fm.contentsOfDirectory(atPath: toolDir) {
                for file in files where file.hasSuffix(".tool") {
                    let path = toolDir + "/" + file
                    if let c = try? String(contentsOfFile: path, encoding: .utf8), c.contains("LABEL=\(tool.label)") {
                        try? fm.removeItem(atPath: path)
                    }
                }
            }
        }

        uninstallMode = false
        build()
    }

    @objc func editTools() {
        panel.orderOut(nil)
        let terminals = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
        if let terminal = terminals.first {
            terminal.activate()
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Terminal"]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let script = NSAppleScript(source: "tell application \"Terminal\" to do script \"claude\"")
                script?.executeAndReturnError(nil)
            }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Helpers

    func loadTools() -> [ToolInfo] {
        let dir = NSHomeDirectory() + "/.local/tools"
        guard let fs = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return fs.sorted().filter { $0.hasSuffix(".tool") }.compactMap { file in
            guard let c = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else { return nil }
            var n = "", d = "", l = "", p = "", sc = ""
            for line in c.split(separator: "\n") {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("NAME=") { n = String(s.dropFirst(5)) }
                if s.hasPrefix("DESCRIPTION=") { d = String(s.dropFirst(12)) }
                if s.hasPrefix("LABEL=") { l = String(s.dropFirst(6)) }
                if s.hasPrefix("PLIST=") { p = String(s.dropFirst(6)).replacingOccurrences(of: "$HOME", with: NSHomeDirectory()) }
                if s.hasPrefix("SCRIPT=") { sc = String(s.dropFirst(7)).replacingOccurrences(of: "$HOME", with: NSHomeDirectory()) }
            }
            return n.isEmpty || l.isEmpty ? nil : ToolInfo(name: n, description: d, label: l, plist: p, script: sc)
        }
    }

    func isRunning(label: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list", label]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
    }

    func launchctl(_ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}

let app = NSApplication.shared
let delegate = ToolManagerApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
