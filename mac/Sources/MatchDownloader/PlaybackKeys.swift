import AVKit
import MatchCore

/// Keyboard control for the playback window. Space, the arrow keys and a few letters, like a video player
/// on a phone with a keyboard attached: nothing on screen changes.
enum PlayerCommand: Equatable {
    case togglePlay, seek(Double), volume(Float), toggleMute, step(Int), faster, slower, restart, finish, fullScreen, close

    /// Keys held down repeat for skipping and volume, but not for play/pause or full screen.
    var repeats: Bool {
        switch self { case .seek, .volume, .step: true; default: false }
    }

    static func from(_ event: NSEvent) -> PlayerCommand? {
        // Leave Command, Control and Option combinations to the menu bar.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: return .togglePlay          // space
        case 123: return .seek(shift ? -10 : -5)   // left arrow
        case 124: return .seek(shift ? 10 : 5)     // right arrow
        case 125: return .volume(-0.1)       // down arrow
        case 126: return .volume(0.1)        // up arrow
        case 115: return .restart            // home
        case 119: return .finish             // end
        case 53: return .close               // escape
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": return .togglePlay
        case "j": return .seek(-10)
        case "l": return .seek(10)
        case "m": return .toggleMute
        case "f": return .fullScreen
        case ",": return .step(-1)
        case ".": return .step(1)
        case "[": return .slower
        case "]": return .faster
        case "0": return .restart
        default: return nil
        }
    }
}

@MainActor
enum PlayerController {
    static func perform(_ command: PlayerCommand, on player: AVPlayer, window: NSWindow?) {
        let duration = player.currentItem?.duration.seconds
        let current = player.currentTime().seconds
        func seek(to seconds: Double) {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        switch command {
        case .togglePlay:
            if player.rate != 0 { player.pause() }
            else {
                // After the end, play again from the start.
                if PlaybackMath.isAtEnd(current: current, duration: duration) { seek(to: 0) }
                player.play()
            }
        case .seek(let delta):
            seek(to: PlaybackMath.seekTarget(current: current, delta: delta, duration: duration))
        case .volume(let delta):
            player.isMuted = false
            player.volume = PlaybackMath.volume(player.volume, delta: Float(delta))
        case .toggleMute:
            player.isMuted.toggle()
        case .step(let count):
            player.pause()
            player.currentItem?.step(byCount: count)
        case .faster, .slower:
            let rate = Float(PlaybackMath.nextRate(from: Double(player.defaultRate), up: command == .faster))
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        case .restart:
            seek(to: 0)
        case .finish:
            if let duration, duration.isFinite { seek(to: duration) }
        case .fullScreen:
            window?.toggleFullScreen(nil)
        case .close:
            if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { window?.performClose(nil) }
        }
    }
}

/// The system player, with the keys above handled when it is the one being used.
/// AVPlayerView hands keyboard focus to an inner view that steps a single frame on the arrow keys, so a keyDown
/// override never sees them. A key monitor for this window answers first instead.
final class KeyPlayerView: AVPlayerView {
    var handle: ((PlayerCommand, NSWindow?) -> Void)?
    private var monitor: Any?
    private var becameKey: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let becameKey { NotificationCenter.default.removeObserver(becameKey); self.becameKey = nil }
        guard handle != nil, let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Monitors run on the main thread; the event is only read here.
            nonisolated(unsafe) let key = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, key.window === self.window else { return false }
                return self.route(key)
            }
            return handled ? nil : event
        }
        becameKey = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.window?.makeFirstResponder(self) } }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if handle != nil { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
    /// Also answer when the key reaches the view normally.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, route(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !route(event) { super.keyDown(with: event) }
    }
    /// True when the key is one of ours (acted on, or ignored because it is a repeat of a key that fires once).
    private func route(_ event: NSEvent) -> Bool {
        guard let handle, let command = PlayerCommand.from(event) else { return false }
        if !(event.isARepeat && !command.repeats) { handle(command, window) }
        return true
    }
}

/// Headless check of every command against a real AVPlayer and a short test video (`--verify-player <file>`).
@MainActor
enum PlayerVerification {
    static func run(url: URL) async throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ ok: Bool, _ what: String) throws { if !ok { throw Failure(description: what) } }
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        for _ in 0..<100 where player.currentItem?.duration.seconds.isFinite != true { try await Task.sleep(for: .milliseconds(50)) }
        let duration = player.currentItem?.duration.seconds ?? 0
        try expect(duration > 12, "test video should be longer than 12 s, got \(duration)")
        func wait() async throws { try await Task.sleep(for: .milliseconds(500)) }
        func time() -> Double { player.currentTime().seconds }

        PlayerController.perform(.togglePlay, on: player, window: nil); try await wait()
        try expect(player.rate != 0, "space starts playback")
        PlayerController.perform(.togglePlay, on: player, window: nil); try await wait()
        try expect(player.rate == 0, "space pauses playback")

        PlayerController.perform(.restart, on: player, window: nil); try await wait()
        PlayerController.perform(.seek(5), on: player, window: nil); try await wait()
        try expect(abs(time() - 5) < 0.3, "right arrow skips 5 s, at \(time())")
        PlayerController.perform(.seek(-5), on: player, window: nil); try await wait()
        try expect(time() < 0.3, "left arrow skips back 5 s, at \(time())")
        PlayerController.perform(.seek(-5), on: player, window: nil); try await wait()
        try expect(time() == 0 || time() < 0.1, "skipping back never goes before the start")
        PlayerController.perform(.seek(10), on: player, window: nil); try await wait()
        try expect(abs(time() - 10) < 0.3, "L skips 10 s, at \(time())")

        let before = time()
        PlayerController.perform(.step(1), on: player, window: nil); try await wait()
        try expect(time() > before && time() - before < 0.5, "period steps one frame, moved \(time() - before)")

        PlayerController.perform(.finish, on: player, window: nil); try await wait()
        try expect(abs(time() - duration) < 0.5, "end jumps to the end")
        PlayerController.perform(.togglePlay, on: player, window: nil); try await wait()
        try expect(time() < 2 && player.rate != 0, "space at the end plays again from the start, at \(time())")
        PlayerController.perform(.togglePlay, on: player, window: nil)

        player.volume = 0.5
        PlayerController.perform(.volume(0.1), on: player, window: nil)
        try expect(abs(player.volume - 0.6) < 0.01, "up arrow raises volume, \(player.volume)")
        for _ in 0..<12 { PlayerController.perform(.volume(-0.1), on: player, window: nil) }
        try expect(player.volume == 0, "volume stops at 0")
        PlayerController.perform(.toggleMute, on: player, window: nil)
        try expect(player.isMuted, "M mutes")
        PlayerController.perform(.toggleMute, on: player, window: nil)

        player.defaultRate = 1
        PlayerController.perform(.faster, on: player, window: nil)
        try expect(player.defaultRate == 1.25, "] speeds up, \(player.defaultRate)")
        PlayerController.perform(.slower, on: player, window: nil); PlayerController.perform(.slower, on: player, window: nil)
        try expect(player.defaultRate == 0.75, "[ slows down, \(player.defaultRate)")
        player.pause()

        // The real responder chain: key presses sent to a window holding the player view.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        let view = KeyPlayerView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        view.controlsStyle = .floating; view.player = player
        view.handle = { command, window in PlayerController.perform(command, on: player, window: window) }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        func press(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = [.numericPad, .function]) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
        PlayerController.perform(.restart, on: player, window: nil); try await wait()
        PlayerController.perform(.seek(10), on: player, window: nil); try await wait()
        press(124, "\u{F703}"); try await wait()
        try expect(abs(time() - 15) < 0.4, "right arrow through the window skips 5 s, at \(time())")
        press(123, "\u{F702}"); try await wait()
        try expect(abs(time() - 10) < 0.4, "left arrow through the window skips back 5 s, at \(time())")
        press(124, "\u{F703}", flags: [.numericPad, .function, .shift]); try await wait()
        try expect(abs(time() - 20) < 0.4, "shift-right through the window skips 10 s, at \(time())")
        press(49, " ", flags: []); try await wait()
        try expect(player.rate != 0, "space through the window plays")
        press(49, " ", flags: []); try await wait()
        try expect(player.rate == 0, "space through the window pauses")
        window.orderOut(nil)

        // Real key events map to the right commands.
        func key(_ code: UInt16, _ chars: String = "", shift: Bool = false, command: Bool = false) -> PlayerCommand? {
            var flags: NSEvent.ModifierFlags = []
            if shift { flags.insert(.shift) }
            if command { flags.insert(.command) }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            return PlayerCommand.from(event)
        }
        try expect(key(49, " ") == .togglePlay, "space key")
        try expect(key(123) == .seek(-5) && key(124) == .seek(5), "arrow keys skip 5 s")
        try expect(key(123, shift: true) == .seek(-10) && key(124, shift: true) == .seek(10), "shift-arrows skip 10 s")
        try expect(key(125) == .volume(-0.1) && key(126) == .volume(0.1), "up and down arrows change volume")
        try expect(key(40, "k") == .togglePlay && key(38, "j") == .seek(-10) && key(37, "l") == .seek(10), "K, J, L")
        try expect(key(46, "m") == .toggleMute && key(3, "f") == .fullScreen && key(53) == .close, "M, F, Escape")
        try expect(key(49, " ", command: true) == nil && key(123, command: true) == nil, "command combinations are left to the menu bar")
        try expect(key(0, "a") == nil, "other keys are ignored")
    }
}
