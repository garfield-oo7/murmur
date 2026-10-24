import SwiftUI

/// First-run setup: the two permissions plus the speech model download.
struct SetupView: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Murmur").font(.title2.bold())
                Text("Hold \(model.hotkey.displayName) anywhere, speak, and let go to type what you said.")
                    .foregroundStyle(.secondary)
            }

            SetupRow(
                icon: "mic",
                title: "Microphone",
                detail: "Hears you only while you hold the hotkey.",
                isDone: permissions.microphoneGranted
            ) {
                Button(permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                    Task { await permissions.requestMicrophone() }
                }
            }

            SetupRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Lets Murmur type the text into the app you're using.",
                isDone: permissions.accessibility
            ) {
                Button("Open Settings") { permissions.requestAccessibility() }
            }

            SetupRow(
                icon: "waveform",
                title: "Speech model",
                detail: modelDetail,
                isDone: model.speechModel.state == .ready
            ) {
                modelAction
            }

            HStack {
                Spacer()
                Button("Done") { model.closeSetup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(permissions.allGranted && model.speechModel.state == .ready))
            }
        }
        .padding(24)
        .frame(width: 460)
        .task {
            await model.speechModel.refresh()
            // Accessibility has no change notification; poll while the window is open.
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var modelDetail: String {
        switch model.speechModel.state {
        case .checking: "Checking…"
        case .unsupported: "On-device speech isn't available for English (US) on this Mac."
        case .needsDownload: "English (US), runs entirely on this Mac."
        case .downloading(let p): "Downloading… \(Int(p * 100))%"
        case .ready: "English (US), runs entirely on this Mac."
        case .failed(let message): "Download failed: \(message)"
        }
    }

    @ViewBuilder private var modelAction: some View {
        switch model.speechModel.state {
        case .needsDownload, .failed:
            Button("Download") { Task { await model.speechModel.install() } }
        case .downloading(let p):
            ProgressView(value: p).frame(width: 80)
        default:
            EmptyView()
        }
    }
}

private struct SetupRow<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            } else {
                action()
            }
        }
    }
}
