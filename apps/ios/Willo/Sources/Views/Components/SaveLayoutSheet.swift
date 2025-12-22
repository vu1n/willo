import SwiftUI

/// Sheet for naming and saving a layout captured from the current zellij session
struct SaveLayoutSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var layoutStore: LayoutStore

    @State private var layoutName: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFieldFocused: Bool

    /// Callback to capture the layout from the terminal
    let onCaptureLayout: (@escaping (Result<String, Error>) -> Void) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.terminalMagenta.opacity(0.3), Color.terminalMagenta.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 80, height: 80)
                            .glowEffect(color: .terminalMagenta, radius: 12)

                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.terminalMagenta)
                    }

                    Text("SAVE CURRENT LAYOUT")
                        .font(.willoSectionHeader)
                        .tracking(2)
                        .foregroundStyle(Color.textSecondary)

                    Text("Capture your current zellij pane arrangement")
                        .font(.willoCaption)
                        .foregroundStyle(Color.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Name input
                VStack(alignment: .leading, spacing: 8) {
                    Text("LAYOUT NAME")
                        .font(.willoSectionHeader)
                        .tracking(1)
                        .foregroundStyle(Color.textTertiary)

                    TextField("e.g., My Dev Setup", text: $layoutName)
                        .font(.willoMono(.body))
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .recessedPanel(cornerRadius: 10)
                        .focused($isNameFieldFocused)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                }
                .padding(.horizontal, 20)

                // Error message
                if let errorMessage = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.terminalRed)

                        Text(errorMessage)
                            .font(.willoCaption)
                            .foregroundStyle(Color.terminalRed)
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        saveLayout()
                    } label: {
                        HStack(spacing: 10) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                            }

                            Text(isSaving ? "CAPTURING..." : "SAVE LAYOUT")
                                .font(.willoMono(.subheadline, weight: .bold))
                                .tracking(1)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.terminalMagenta, Color.terminalMagenta.opacity(0.8)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                        .shadow(color: Color.terminalMagenta.opacity(0.3), radius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(layoutName.isEmpty || isSaving)
                    .opacity(layoutName.isEmpty || isSaving ? 0.5 : 1)

                    Button {
                        dismiss()
                    } label: {
                        Text("CANCEL")
                            .font(.willoMono(.subheadline, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(Color.machineDark)
            .overlay {
                ScanLinesView(opacity: 0.015)
                    .allowsHitTesting(false)
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            isNameFieldFocused = true
        }
    }

    private func saveLayout() {
        guard !layoutName.isEmpty else { return }

        isSaving = true
        errorMessage = nil

        // Capture the layout from the terminal
        onCaptureLayout { result in
            switch result {
            case .success(let kdlContent):
                // Save to layout store
                let _ = layoutStore.addLayout(name: layoutName, kdlContent: kdlContent)

                // Success - dismiss the sheet
                dismiss()

            case .failure(let error):
                // Show error
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

#if DEBUG
#Preview {
    SaveLayoutSheet { completion in
        // Simulate capture delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            completion(.success("""
            layout {
                pane size=1 borderless=true {
                    plugin location="compact-bar"
                }
                pane
            }
            """))
        }
    }
    .environmentObject(LayoutStore())
}
#endif
