import SwiftUI

/// Keeps a player window at the video's shape, so the picture fills it with no black bars.
/// The window opens at a normal size (never full screen) and resizing keeps the ratio.
struct WindowAspect: NSViewRepresentable {
    let ratio: CGFloat
    func makeNSView(context: Context) -> AspectView { AspectView(ratio: ratio) }
    func updateNSView(_ view: AspectView, context: Context) { view.ratio = ratio }

    final class AspectView: NSView {
        var ratio: CGFloat { didSet { if ratio != oldValue { fit() } } }
        init(ratio: CGFloat) { self.ratio = ratio; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); fit() }
        private func fit() {
            // Wait a tick so SwiftUI has finished sizing the window first.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, ratio.isFinite, ratio > 0.2, ratio < 5,
                      !window.styleMask.contains(.fullScreen) else { return }
                window.contentAspectRatio = NSSize(width: ratio * 1000, height: 1000)
                let screen = window.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
                var width = min(max(window.contentRect(forFrameRect: window.frame).width, 640), screen.width * 0.7)
                if width / ratio > screen.height * 0.7 { width = screen.height * 0.7 * ratio }
                window.setContentSize(NSSize(width: width.rounded(), height: (width / ratio).rounded()))
            }
        }
    }
}
