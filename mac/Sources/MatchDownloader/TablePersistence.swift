import SwiftUI

/// HIG lists-and-tables.md > Desktop: preserve people's column resizing with
/// SwiftUI's column customization; this bridge only removes the ruled lines.
struct TablePersistence: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(from: view, name: name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.attach(from: view, name: name) }
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor final class Coordinator {
        weak var table: NSTableView?
        var scheduled = false
        func attach(from marker: NSView, name: String) {
            guard table == nil, !scheduled else { return }; scheduled = true
            Task { @MainActor [weak marker, weak self] in
                defer { self?.scheduled = false }
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let marker, let self else { return }
                    var parent = marker.superview
                    for _ in 0..<5 {
                        guard let view = parent else { break }
                        if let table = findTable(view) {
                            // No NSTableView column autosave: with hidden columns it fights SwiftUI's own
                            // column customization (which already remembers widths, order and visibility)
                            // and sends the table into a layout loop.
                            // Less clutter: no ruled lines between rows or columns; spacing and the
                            // soft row bands separate the content instead.
                            table.gridStyleMask = []
                            self.table = table; return
                        }
                        parent = view.superview
                    }
                }
            }
        }
        private func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(child) { return table } }
            return nil
        }
    }
}
