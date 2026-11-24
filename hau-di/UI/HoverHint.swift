import AppKit
import SwiftUI

/// Tooltip propriu: un balon mic deasupra elementului, dupa 0,3 s de hover. Tooltip-ul nativ (`.help`) apare abia
/// dupa cateva secunde si arata ca title-ul din browser; in panoul din bara de meniu folosim balonul acesta.
/// Balonul iese in sus, peste elementele de deasupra (desenate inaintea lui), deci nu are nevoie de zIndex.
/// Fond opac, fara material si fara umbra: un material in panoul de sticla din macOS 26 facea sticla intregului
/// panou sa se redeseneze (devenea transparenta, cu reflexiile barii de meniu).
struct HoverHint: ViewModifier {
    let text: String
    /// Unde se aliniaza balonul fata de element: .leading pentru elementele din stanga, .trailing pentru cele din
    /// dreapta (ca sa nu iasa din fereastra), .center in rest.
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
                        // Un cadru de inaltime zero lipit de marginea de sus a elementului, cu balonul aliniat jos:
                        // balonul creste in sus, deasupra elementului, oricat de inalt ar fi (fara alignmentGuide,
                        // care pe Mac nu se aplica aici si lasa balonul peste rand).
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
    /// Balon de ajutor la hover (vezi HoverHint).
    func hoverHint(_ text: String, alignment: HorizontalAlignment = .center) -> some View {
        modifier(HoverHint(text: text, alignment: alignment))
    }
}
