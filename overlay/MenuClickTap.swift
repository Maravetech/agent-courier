import Foundation
import CoreGraphics

final class MenuClickTap {
    private let lock = NSLock()
    private var frame: CGRect?
    private var port: CFMachPort? // Used only on the listener thread.
    private let onClick: (CGPoint) -> Void
    private let log: (String) -> Void

    init(onClick: @escaping (CGPoint) -> Void, log: @escaping (String) -> Void) {
        self.onClick = onClick
        self.log = log
    }

    func setFrame(_ frame: CGRect?) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func start() {
        Self.onWorker { self.listen() }
    }

    static func onWorker(_ work: @escaping () -> Void) {
        Thread.detachNewThread { work() }
    }

    private func listen() {
        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<MenuClickTap>.fromOpaque(context).takeUnretainedValue()
                return listener.handle(type, event: event) {
                    if let port = listener.port { CGEvent.tapEnable(tap: port, enable: true) }
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            log("menu_click_unavailable: event tap failed")
            return
        }
        port = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    func handle(_ type: CGEventType, event: CGEvent, reenable: () -> Void) -> Unmanaged<CGEvent> {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reenable()
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user_input"
            DispatchQueue.global(qos: .utility).async { [log] in log("menu_click_reenabled: \(reason)") }
        case .leftMouseDown:
            let point = event.location
            lock.lock()
            let hit = frame?.contains(point) == true
            lock.unlock()
            if hit { DispatchQueue.main.async { [onClick] in onClick(point) } }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
}

func menuIconFrame(display: CGRect, menuBar: CGRect?) -> CGRect {
    let x = min(display.maxX - 200, display.midX + 180)
    let y = menuBar.map { $0.minY + max(0, floor(($0.height - 26) / 2)) } ?? display.minY + 2
    return CGRect(x: x, y: y, width: 28, height: 24).integral
}

func currentMenuIconFrame() -> CGRect {
    let display = CGDisplayBounds(CGMainDisplayID())
    let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let menu = windows.lazy.compactMap { window -> CGRect? in
        guard window[kCGWindowLayer as String] as? Int == menuLevel,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              abs(frame.minX - display.minX) < 1, abs(frame.minY - display.minY) < 1,
              abs(frame.width - display.width) < 1, (24...120).contains(frame.height) else { return nil }
        return frame
    }.first
    return menuIconFrame(display: display, menuBar: menu)
}
