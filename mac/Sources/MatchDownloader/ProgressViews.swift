import SwiftUI
import MatchCore

/// "42% · 1 min left": the same words everywhere a download's progress is shown.
enum ProgressText {
    static func summary(_ progress: ClipProgress?) -> String? {
        guard let fraction = progress?.fraction else { return nil }
        let percent = "\(Int((fraction * 100).rounded()))%"
        guard let eta = progress?.eta else { return percent }
        return percent + " · " + remaining(eta)
    }
    static func remaining(_ seconds: Double) -> String {
        seconds < 60 ? "under a minute left" : "about \(Int((seconds / 60).rounded(.up))) min left"
    }
}

/// The filled part of a bar, drawn inside the same rectangle as its track so it can never sit anywhere else.
struct BarFill: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let width = max(rect.height, rect.width * min(max(fraction, 0), 1))
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), cornerRadius: rect.height / 2)
    }
}

/// A slim determinate bar. No animation of its own: the fill steps forward as the engine reports progress, and the
/// track and fill share one frame, so nothing about it moves up, down or sideways.
struct SlimBar: View {
    let fraction: Double
    var height: CGFloat
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.14))
            BarFill(fraction: fraction).fill(Color.blue)
        }
        .frame(height: height)
    }
}

/// The Status cell. A ring shows activity (filled in when the engine knows how far along it is) and
/// a hairline along the bottom shows progress at a glance. Pointing at the cell expands the hairline
/// into a bar and swaps the label for the percentage and time left. The row never changes height.
struct StatusCell: View {
    let clip: Clip
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = clip.isActive ? clip.progress?.fraction : nil
        let expanded = hovering && fraction != nil
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) {
                if clip.isActive {
                    if let fraction { ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small) }
                    else { ProgressView().controlSize(.small) }
                }
                Text(expanded ? ProgressText.summary(clip.progress) ?? Labels.status(clip.status) : Labels.status(clip.status))
                    .monospacedDigit().lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.bottom, expanded ? 4 : 0)
            if let fraction {
                SlimBar(fraction: fraction, height: expanded ? 5 : 2)
                    .opacity(expanded ? 1 : 0.7)
                    .padding(.bottom, expanded ? 1 : 3)
            }
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: expanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Labels.status(clip.status))
        .accessibilityValue(ProgressText.summary(clip.progress) ?? "")
    }
}

/// The inspector's version: always visible, with the full sentence.
struct InspectorProgress: View {
    let clip: Clip
    var body: some View {
        if clip.isActive {
            // One fixed-height block, so nothing below it moves when updates arrive.
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = clip.progress?.fraction { SlimBar(fraction: fraction, height: 6) }
                else { Capsule().fill(Color.primary.opacity(0.14)).frame(height: 6) }
                Text(ProgressText.summary(clip.progress) ?? "Working…").font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .frame(height: 34, alignment: .top)
            .accessibilityElement(children: .combine)
        }
    }
}
