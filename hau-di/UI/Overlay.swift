import AppKit
import SwiftUI

/// What the floating "pill" at the bottom shows.
enum OverlayMode: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case transcribing
    case correcting
    case success
    case message(String, isError: Bool)
}

@MainActor
final class OverlayModel: ObservableObject {
    /// How many recent levels we keep: enough for the bars to fill the whole pill.
    static let historyCount = 160

    @Published var mode: OverlayMode = .hidden
    /// The pill at the top (below the menu bar) instead of the bottom.
    @Published var atTop = false
    @Published var levels: [Float] = Array(repeating: 0, count: OverlayModel.historyCount)

    func push(level: Float) {
        guard case .recording = mode else { return }
        var updated = levels
        updated.removeFirst()
        updated.append(level)
        levels = updated
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: OverlayModel.historyCount)
    }
}

/// A panel without focus: it never steals the keyboard from the app you are dictating into.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make(size: NSSize) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    var isEnabled = true
    /// Top (below the menu bar) or bottom (above the Dock); applied the next time it is shown.
    var atTop = false {
        didSet { model.atTop = atTop }
    }
    private var panel: OverlayPanel?
    private var hideTask: Task<Void, Never>?
    /// The panel is transparent and does not receive clicks; it is taller so that messages on 2-3 lines fit.
    private let size = NSSize(width: 400, height: 130)

    func show(_ mode: OverlayMode) {
        hideTask?.cancel()
        hideTask = nil
        if case .recording = mode, model.mode != mode { model.resetLevels() }
        model.mode = mode
        guard isEnabled else { return }
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    /// Shows a short message, then hides the pill.
    func flash(_ mode: OverlayMode, duration: TimeInterval = 1.4) {
        show(mode)
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        model.mode = .hidden
        panel?.orderOut(nil)
    }

    /// Hides the pill only if it was left in a state without a timer (Transcribing…, Correcting…, recording);
    /// a short message (Inserted, error) stays until its time runs out.
    func hideIfPersistent() {
        guard hideTask == nil, model.mode != .hidden else { return }
        hide()
    }

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel.make(size: size)
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Centered at the bottom, on the screen where the mouse is.
    private func position(_ panel: OverlayPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let y = atTop ? visible.maxY - size.height - 8 : visible.minY + 18
        let origin = NSPoint(x: visible.midX - size.width / 2, y: y)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            if !model.atTop {
                Spacer(minLength: 0)
            }
            if model.mode != .hidden {
                pill
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            if model.atTop {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }

    /// The same width in every state: it no longer "jumps" when going from recording to transcribing and inserting.
    private static let pillWidth: CGFloat = 340

    private var pill: some View {
        pillContent
            .frame(minHeight: 26)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(width: Self.pillWidth)
            .modifier(PillGlass())
            .padding(model.atTop ? .top : .bottom, 6)
    }

    /// The palette's base colors (the strongest ones), on any theme: on glass, the lighter variant gets lost.
    private static func strong(_ tone: BrandTone) -> Color {
        tone.color(onDark: true)
    }

    /// Three zones, the same in every state: the rhombus on the left and the lock on the right have reserved space
    /// (even when the lock is not shown); the middle (waveform or text) takes all the rest.
    private var pillContent: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 16, height: 16)
            center
                .frame(maxWidth: .infinity)
            trailing
                .frame(width: 16, height: 16)
        }
    }

    /// Left: the status rhombus.
    @ViewBuilder
    private var leading: some View {
        switch model.mode {
        case .recording:
            StatusDiamond(color: Self.strong(.red))
                .frame(width: 14, height: 14)
        case .hidden:
            Color.clear
        case .transcribing:
            StatusDiamond(color: Self.strong(.green), pulsing: true)
                .frame(width: 14, height: 14)
        case .correcting:
            StatusDiamond(color: Self.strong(.orange), pulsing: true)
                .frame(width: 14, height: 14)
        case .success:
            StatusDiamond(color: Self.strong(.purple), glyph: .check)
                .frame(width: 14, height: 14)
        case .message(_, let isError):
            StatusDiamond(color: Self.strong(isError ? .yellow : .gray),
                          glyph: isError ? .exclamation : .info,
                          glyphColor: isError ? Color(red: 0.23, green: 0.16, blue: 0) : .white)
                .frame(width: 14, height: 14)
        }
    }

    /// Middle: the waveform (from one end of the zone to the other) or the text, centered.
    @ViewBuilder
    private var center: some View {
        switch model.mode {
        case .recording:
            WaveformView(levels: model.levels, color: Self.strong(.red))
        case .hidden:
            EmptyView()
        case .transcribing:
            label("Transcribing…")
        case .correcting:
            label("Correcting with Claude…")
        case .success:
            label("Inserted")
        case .message(let text, _):
            label(text)
        }
    }

    /// Right: the lock in hands-free mode; otherwise the space stays empty.
    @ViewBuilder
    private var trailing: some View {
        if case .recording(handsFree: true) = model.mode {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The recording waveform: thin bars across the whole width, one for each recent voice level
/// (the newest on the right).
struct WaveformView: View {
    let levels: [Float]
    var color: Color
    var barWidth: CGFloat = 1
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, Int((proxy.size.width + spacing) / (barWidth + spacing)))
            let recent = Array(levels.suffix(count))
            let bars = Array(repeating: Float(0), count: max(0, count - recent.count)) + recent
            HStack(alignment: .center, spacing: spacing) {
                ForEach(bars.indices, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(2, CGFloat(bars[index]) * maxHeight))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// The pill's background: the system glass. On macOS 26, Liquid Glass; on macOS 14-15, the classic blur.
/// Both follow the options in System Settings: light/dark theme, Reduce Transparency, Increase Contrast.
private struct PillGlass: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    @Environment(\.colorScheme) private var colorScheme

    /// A 1 px (1 pt) border, the inverse of the system theme: black on the light theme (white pill),
    /// white on the dark theme (black pill). The same at the top or at the bottom.
    private var border: Color { colorScheme == .dark ? .white : .black }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
        } else {
            classic(content)
        }
        #else
        classic(content)
        #endif
    }

    private func classic(_ content: Content) -> some View {
        content
            .background(VisualEffectBackground().clipShape(shape))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

/// Blur of whatever is behind the window (NSVisualEffectView), for macOS 14-15.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The panel never becomes active; without this, macOS would draw it as an inactive window.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
