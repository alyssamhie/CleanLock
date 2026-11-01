import AppKit
import ApplicationServices

// Event types are used by raw value because gesture types have no CGEventType case.
func mask(_ types: [UInt32]) -> UInt64 { types.reduce(0) { $0 | (UInt64(1) << UInt64($1)) } }

let keyboardMask = mask([10, 11, 12, 14])  // keyDown, keyUp, flagsChanged, media/function keys
let trackpadMask = mask([1, 2, 3, 4, 5, 6, 7, 18, 19, 20, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32, 34])  // mouse, scroll, gestures

let leftCommandFlag: UInt64 = 0x08
let rightCommandFlag: UInt64 = 0x10
let holdToUnlockSeconds: TimeInterval = 2

var blockedMask: UInt64 = 0
var bothCommandsHeld = false
var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged {
        let flags = event.flags.rawValue
        bothCommandsHeld = flags & leftCommandFlag != 0 && flags & rightCommandFlag != 0
    }
    let raw = UInt64(type.rawValue)
    if raw < 64 && (blockedMask >> raw) & 1 == 1 { return nil }
    return Unmanaged.passUnretained(event)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let keyboardBox = NSButton(checkboxWithTitle: "Lock keyboard", target: nil, action: nil)
    let trackpadBox = NSButton(checkboxWithTitle: "Lock trackpad and mouse", target: nil, action: nil)
    let durationPopup = NSPopUpButton()
    let lockButton = NSButton(title: "Lock", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let countdownLabel = NSTextField(labelWithString: "")
    let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    let setupStack = NSStackView()
    let lockedStack = NSStackView()

    let durations: [(String, TimeInterval)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]
    var unlockAt = Date()
    var heldSince: Date?
    var ticker: Timer?
    var awakeActivity: NSObjectProtocol?
    var cursorFrozen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit CleanLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(appItem)

        keyboardBox.state = .on
        trackpadBox.state = .on
        durations.forEach { durationPopup.addItem(withTitle: $0.0) }
        durationPopup.selectItem(at: 1)
        let durationRow = NSStackView(views: [NSTextField(labelWithString: "Auto-unlock after"), durationPopup])

        lockButton.target = self
        lockButton.action = #selector(lock)
        lockButton.keyEquivalent = "\r"
        lockButton.controlSize = .large

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "To unlock early, hold both ⌘ keys for 2 seconds."

        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 14
        [keyboardBox, trackpadBox, durationRow, statusLabel, lockButton].forEach(setupStack.addArrangedSubview)

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Locked. Hold both ⌘ keys for 2 seconds to unlock.")
        hint.alignment = .center
        unlockButton.target = self
        unlockButton.action = #selector(unlock)

        lockedStack.orientation = .vertical
        lockedStack.spacing = 14
        [countdownLabel, hint, unlockButton].forEach(lockedStack.addArrangedSubview)
        lockedStack.isHidden = true

        let content = window.contentView!
        for stack in [setupStack, lockedStack] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            ])
        }

        window.title = "CleanLock"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func installTapIfNeeded() -> Bool {
        if eventTap != nil { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: keyboardMask | trackpadMask,
                                          callback: tapCallback, userInfo: nil) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        eventTap = tap
        return true
    }

    @objc func lock() {
        let lockKeyboard = keyboardBox.state == .on
        let lockTrackpad = trackpadBox.state == .on
        guard lockKeyboard || lockTrackpad else {
            statusLabel.stringValue = "Tick keyboard, trackpad, or both."
            return
        }
        guard installTapIfNeeded() else {
            statusLabel.stringValue = "Allow CleanLock in System Settings > Privacy & Security > Accessibility, then click Lock again."
            return
        }

        blockedMask = (lockKeyboard ? keyboardMask : 0) | (lockTrackpad ? trackpadMask : 0)
        if lockTrackpad { cursorFrozen = CGAssociateMouseAndMouseCursorPosition(0) == .success }
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Cleaning")

        unlockAt = Date().addingTimeInterval(durations[durationPopup.indexOfSelectedItem].1)
        heldSince = nil
        bothCommandsHeld = false
        unlockButton.isHidden = lockTrackpad  // Clicks cannot reach it while the trackpad is locked.
        setupStack.isHidden = true
        lockedStack.isHidden = false
        window.level = .screenSaver
        tick()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func tick() {
        let remaining = unlockAt.timeIntervalSinceNow
        if remaining <= 0 { unlock(); return }
        countdownLabel.stringValue = String(format: "%d:%02d", Int(remaining.rounded(.up)) / 60, Int(remaining.rounded(.up)) % 60)

        if bothCommandsHeld {
            let since = heldSince ?? Date()
            heldSince = since
            if Date().timeIntervalSince(since) >= holdToUnlockSeconds { unlock() }
        } else {
            heldSince = nil
        }
    }

    @objc func unlock() {
        blockedMask = 0
        ticker?.invalidate()
        ticker = nil
        if cursorFrozen {
            CGAssociateMouseAndMouseCursorPosition(1)
            cursorFrozen = false
        }
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        window.level = .normal
        lockedStack.isHidden = true
        setupStack.isHidden = false
        statusLabel.stringValue = "Unlocked. To unlock early next time, hold both ⌘ keys for 2 seconds."
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
