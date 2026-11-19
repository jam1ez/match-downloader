import SwiftUI
import MatchCore

/// One slider for the whole clip: the left thumb is where it starts, the right thumb is where it ends, and the
/// filled stretch between them is what gets saved. The thin mark is the official match start. Thumbs move in
/// 5 second steps and stay at least 5 seconds apart (Sliders.md: min on the leading side, a label, live feedback).
struct ClipRangeSlider: View {
    @Binding var startAdjust: Double
    @Binding var endAdjust: Double
    let baseStart: Double   // seconds from the match start where the clip would start with no adjustment
    let baseEnd: Double
    private let step = 5.0
    var startLimits: ClosedRange<Double> = -60...60
    var endLimits: ClosedRange<Double> = -60...120
    private enum Edge: Hashable { case start, end }
    @FocusState private var focus: Edge?
    @State private var dragging: Edge?

    private var lower: Double { baseStart + startLimits.lowerBound }
    private var upper: Double { baseEnd + endLimits.upperBound }
    private var startT: Double { baseStart + startAdjust }
    private var endT: Double { baseEnd + endAdjust }

    private func move(_ edge: Edge, toSeconds t: Double) {
        switch edge {
        case .start:
            let value = ((t - baseStart) / step).rounded() * step
            startAdjust = min(max(value, startLimits.lowerBound), min(startLimits.upperBound, endT - step - baseStart))
        case .end:
            let value = ((t - baseEnd) / step).rounded() * step
            endAdjust = max(min(value, endLimits.upperBound), max(endLimits.lowerBound, startT + step - baseEnd))
        }
    }
    private func nudge(_ edge: Edge, by amount: Double) { move(edge, toSeconds: (edge == .start ? startT : endT) + amount) }
    private func name(_ edge: Edge) -> String { edge == .start ? "Clip start" : "Clip end" }
    private func spoken(_ t: Double) -> String { t < 0 ? "\(Int(-t)) seconds before the match" : "\(Int(t)) seconds into the match" }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = max(upper - lower, 1)
            let position: (Double) -> CGFloat = { CGFloat(($0 - lower) / span) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1.5, height: 14).offset(x: position(0) - 0.75)
                Capsule().fill(Color.accentColor).frame(width: max(0, position(endT) - position(startT)), height: 4).offset(x: position(startT))
                thumb(.start).offset(x: position(startT) - 11)
                thumb(.end).offset(x: position(endT) - 11)
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(name: "clipTrack")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTrack")).onChanged { drag in
                    let t = lower + Double(drag.location.x / max(width, 1)) * span
                    // Grab whichever thumb is closer to where the pointer went down.
                    let edge: Edge = dragging ?? (abs(t - startT) <= abs(t - endT) ? .start : .end)
                    dragging = edge; focus = edge; move(edge, toSeconds: t)
                }.onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 28)
    }

    private func thumb(_ edge: Edge) -> some View {
        Circle().fill(.white).frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            .focusable().focused($focus, equals: edge)
            .onKeyPress(.leftArrow) { nudge(edge, by: -step); return .handled }
            .onKeyPress(.rightArrow) { nudge(edge, by: step); return .handled }
            .accessibilityElement()
            .accessibilityLabel(name(edge))
            .accessibilityValue(spoken(edge == .start ? startT : endT))
            .accessibilityAdjustableAction { direction in nudge(edge, by: direction == .increment ? step : -step) }
    }
}
