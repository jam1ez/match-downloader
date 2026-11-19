import SwiftUI
import MatchCore

struct WorkspaceActions {
    var addEvents: () -> Void
    var clipFromLink: () -> Void
}
struct MatchActions {
    var preview: () -> Void
    var position: () -> Void
    var download: () -> Void
    var hasVideo: Bool
    var singleMatch: Bool
}
private struct WorkspaceActionsKey: FocusedValueKey { typealias Value = WorkspaceActions }
private struct MatchActionsKey: FocusedValueKey { typealias Value = MatchActions }
extension FocusedValues {
    var workspaceActions: WorkspaceActions? { get { self[WorkspaceActionsKey.self] } set { self[WorkspaceActionsKey.self] = newValue } }
    var matchActions: MatchActions? { get { self[MatchActionsKey.self] } set { self[MatchActionsKey.self] = newValue } }
}
struct MatchCommands: Commands {
    @FocusedValue(\.workspaceActions) private var workspace
    @FocusedValue(\.matchActions) private var match
    @AppStorage("filters.visible") private var filters = true
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "workspace") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Add Events…") { workspace?.addEvents() }.keyboardShortcut("n").disabled(workspace == nil)
            Button("Clip from Link…") { workspace?.clipFromLink() }.keyboardShortcut("l").disabled(workspace == nil)
        }
        CommandMenu("Match") {
            Button("Preview") { match?.preview() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(match?.hasVideo != true)
            Button("Set Video Position…") { match?.position() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(match?.singleMatch != true)
            Button("Download…") { match?.download() }.keyboardShortcut("d").disabled(match?.hasVideo != true)
        }
        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .sidebar) { Toggle("Show Filters", isOn: $filters).keyboardShortcut("f", modifiers: [.command, .shift]) }
    }
}
