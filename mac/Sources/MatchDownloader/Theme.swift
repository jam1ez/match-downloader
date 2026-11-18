import SwiftUI
import AppKit
import MatchCore

/// The soft charcoal look of the first version (web/mac/app.css), built on system components:
/// quiet fills with hairline edges, grey table selection, and compact controls. Colors that the
/// system already provides (text, materials, sidebar and inspector panels) are left to the system.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
    /// Window content behind tables and lists (--canvas).
    static let canvas = dynamic(light: 0xfbfbfd, dark: 0x1c1c1e)
    static let allianceRed = dynamic(light: 0xe5322d, dark: 0xff5a52)
    static let allianceBlue = dynamic(light: 0x1677ff, dark: 0x3d9bff)
    /// Muted grey used for selected table rows instead of the saturated accent colour.
    static let selection = dynamic(light: 0x68686d, dark: 0x4a4a4f)
    static let fill = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.10)
}

extension View {
    /// Grey selected rows. System tables take their selection colour from the tint.
    func mutedSelection() -> some View { tint(Theme.selection) }
    /// A quiet capsule: soft fill, hairline edge (filters, scope controls).
    func softCapsule() -> some View {
        background(Theme.fill, in: .capsule).overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
    /// A capsule that floats over scrolling rows, so it needs a material behind it.
    func floatingCapsule() -> some View {
        background(.regularMaterial, in: .capsule).overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
    /// A rounded card with a soft fill and hairline edge (alliance scorecards, notes).
    func softCard(radius: CGFloat = 12) -> some View {
        background(Theme.fill, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
    /// Compact pill buttons for the inspector.
    func inspectorButton() -> some View { buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular) }
}

struct InspectorHeading: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.bold)).textSelection(.enabled)
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Right-aligned labels beside their values; empty values are left out.
struct InspectorFacts: View {
    let rows: [(String, String)]
    init(_ rows: [(String, String)]) { self.rows = rows }
    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(value).textSelection(.enabled)
                }
            }
        }.font(.callout)
    }
}

/// A single coloured dot for a download's state, with its name for VoiceOver and as a tooltip.
struct StatusDot: View {
    let status: String?
    private var color: Color {
        switch ClipStatus(rawValue: status ?? "") {
        case .ready: .green
        case .needsReview: .orange
        case .failed: .red
        case .queued, .downloading, .analyzing, .processing: .blue
        default: .secondary
        }
    }
    var body: some View {
        if let status {
            let label = Labels.status(status)
            Circle().fill(color).frame(width: 9, height: 9).help(label)
                .accessibilityElement().accessibilityLabel("Download: \(label)")
        }
    }
}
