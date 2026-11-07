import Foundation
import CoreGraphics

private func event(_ point: CGPoint) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.location = point
    return event
}

@main struct MenuClickFixture {
    static func main() {
        let mode = CommandLine.arguments[1]
        let display = CGRect(x: -3440, y: -300, width: 3440, height: 1440)
        let menu = CGRect(x: -3440, y: -300, width: 3440, height: 42)
        let frame = menuIconFrame(display: display, menuBar: menu)
        let hit = CGPoint(x: frame.midX, y: frame.midY)
        let outside = CGPoint(x: frame.minX - 1, y: frame.midY)
        var clicks = [CGPoint]()
        let logs = DispatchSemaphore(value: 0)
        let tap = MenuClickTap(onClick: { point in
            precondition(Thread.isMainThread)
            clicks.append(point)
        }, log: { _ in logs.signal() })
        tap.setFrame(frame)

        switch mode {
        case "recovery":
            for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
                let input = event(hit)
                var enabled = false
                let output = tap.handle(type, event: input) { enabled = true }
                precondition(enabled)
                precondition(output.takeUnretainedValue() === input)
                precondition(logs.wait(timeout: .now() + 2) == .success)
            }
        case "passthrough":
            let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
            let menu = CGRect(x: 0, y: 0, width: 3440, height: 30)
            precondition(menuIconFrame(display: display, menuBar: menu) ==
                         CGRect(x: 1900, y: 2, width: 28, height: 24))
            precondition(frame == CGRect(x: -1540, y: -292, width: 28, height: 24))
            for (type, point) in [(CGEventType.leftMouseDown, outside), (.leftMouseUp, hit), (.leftMouseDown, hit)] {
                let input = event(point)
                precondition(tap.handle(type, event: input) { preconditionFailure() }.takeUnretainedValue() === input)
                precondition(input.location == point)
            }
            tap.setFrame(nil)
            let hidden = event(hit)
            _ = tap.handle(.leftMouseDown, event: hidden) { preconditionFailure() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(clicks == [hit])
        case "worker":
            let finished = DispatchSemaphore(value: 0)
            MenuClickTap.onWorker {
                precondition(!Thread.isMainThread)
                let loop = CFRunLoopGetCurrent()
                let timer = Timer(timeInterval: 0, repeats: false) { _ in
                    precondition(!Thread.isMainThread)
                    _ = tap.handle(.leftMouseDown, event: event(hit)) { preconditionFailure() }
                    CFRunLoopStop(loop)
                }
                RunLoop.current.add(timer, forMode: .common)
                CFRunLoopRun()
                finished.signal()
            }
            precondition(finished.wait(timeout: .now() + 2) == .success)
            precondition(clicks.isEmpty)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(clicks == [hit])
        default:
            preconditionFailure("Unknown fixture mode")
        }
        print("PASS \(mode)")
    }
}
