import AppKit
import SwiftUI

/// The copy button (menu bar panel, history): the icon without a border, with a background on hover;
/// after a click it turns into a checkmark for a second, to show that the text was copied.
struct CopyIconButton: View {
    let text: String
    @State private var copied = false

    // Explicit: with a private @State property, the synthesized initializer is not visible from other files.
    init(text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(HoverIconButtonStyle())
        .hoverHint(copied ? "Copied" : "Copy", alignment: .trailing)
        .accessibilityLabel("Copy")
    }
}

/// The style of the small icon buttons (copy, delete): no border, with a subtle background on hover and on press.
/// `destructive` colors the icon red on hover (delete).
struct HoverIconButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        HoverIconLabel(configuration: configuration, destructive: destructive)
    }
}

private struct HoverIconLabel: View {
    let configuration: ButtonStyleConfiguration
    let destructive: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .frame(width: 14, height: 14)
            .padding(4)
            .foregroundStyle(destructive && hovering ? Color.red : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
