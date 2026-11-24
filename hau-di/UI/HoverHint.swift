import AppKit
import SwiftUI

/// Custom tooltip: a small bubble above the element, after 0.3 s of hover. The native tooltip (`.help`) only shows up
/// after a few seconds and looks like a browser title; in the menu bar panel we use this bubble instead.
/// The bubble sticks out upward, over the elements above (drawn before it), so it does not need a zIndex.
/// Opaque background, no material and no shadow: a material inside the macOS 26 glass panel made the glass of the
/// whole panel redraw (it turned transparent, with the reflections of the menu bar).
struct HoverHint: ViewModifier {
    let text: String
    /// How the bubble is aligned to the element: .leading for elements on the left, .trailing for those on the
    /// right (so that it does not stick out of the window), .center otherwise.
    var alignment: HorizontalAlignment = .center
    @State private var visible = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: Alignment(horizontal: alignment, vertical: .top)) {
                if visible {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                        // A zero-height frame pinned to the element's top edge, with the bubble aligned to its bottom:
                        // the bubble grows upward, above the element, however tall it is (no alignmentGuide,
                        // which on the Mac is not applied here and leaves the bubble over the row).
                        .frame(height: 0, alignment: .bottom)
                        .offset(y: -4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) { visible = true }
                    }
                } else {
                    withAnimation(.easeIn(duration: 0.08)) { visible = false }
                }
            }
            .accessibilityHint(text)
    }
}

extension View {
    /// Help bubble on hover (see HoverHint).
    func hoverHint(_ text: String, alignment: HorizontalAlignment = .center) -> some View {
        modifier(HoverHint(text: text, alignment: alignment))
    }
}
