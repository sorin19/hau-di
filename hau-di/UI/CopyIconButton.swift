import AppKit
import SwiftUI

/// Butonul de copiere (panoul din bara de meniu, istoric): iconul fara chenar, cu fundal la hover;
/// dupa click devine o bifa pentru o secunda, ca sa se vada ca s-a copiat.
struct CopyIconButton: View {
    let text: String
    @State private var copied = false

    // Explicit: cu o proprietate @State privata, initializatorul generat nu se vede din alte fisiere.
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

/// Stilul butoanelor mici cu icon (copiere, stergere): fara chenar, cu un fundal discret la hover si la apasare.
/// `destructive` coloreaza iconul in rosu la hover (stergere).
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
