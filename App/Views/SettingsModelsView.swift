import AppKit
import SwiftUI

struct SettingsModelsView: View {
    let store: ModelStore
    @State private var pendingDelete: ModelEntry?

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.entries.filter(\.transcribes)) { entry in row(entry) }
            } header: {
                Text("Models")
            } footer: {
                if let error = store.deleteError { Text(error).foregroundStyle(Native.danger) }
            }
            Section {
                ForEach(ModelCatalog.entries.filter { !$0.transcribes }) { entry in row(entry) }
            } header: {
                Text("Helpers")
            } footer: {
                Text(Self.helperUsage)
            }
            Section("Storage") {
                LabeledContent("Models are stored in the app\u{2019}s sandbox container") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
                }
                Text(store.directory.abbreviatedPath).font(.caption.monospaced())
                    .foregroundStyle(Native.fgSecondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .alert("Delete \u{201C}\(pendingDelete?.displayName ?? "")\u{201D}?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { store.delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("Frees \(entry.sizeText). You can download it again later.")
        }
    }

    /// A helper is never picked as the model, so this says where it is switched on.
    static var helperUsage: String {
        let drumModels = ModelCatalog.entries.filter(\.isDrumModel).map(\.displayName).joined(separator: " or ")
        return "Helpers aren\u{2019}t picked as the model. To use the drum separator, open an audio file, choose \(drumModels) "
            + "as the model, then turn on Separate drums first in the inspector\u{2019}s Drums section. "
            + "If the separator isn\u{2019}t downloaded yet, the next run downloads it first. "
            + "The beat tracker works in the Tempo section of the Audio inspector: once it is downloaded, Detect tempo from audio "
            + "also finds downbeats and suggests a time-signature map, which you apply yourself."
    }

    private func row(_ entry: ModelEntry) -> some View {
        HStack(alignment: .top, spacing: Metric.sp5) {
            VStack(alignment: .leading, spacing: Metric.sp2) {
                HStack(spacing: Metric.sp3) {
                    Text(entry.displayName).font(.headline)
                    LicenseBadge(entry: entry)
                    switch entry.access {
                    case .open: EmptyView()
                    case .terms: Text("Licence acceptance").font(.caption).foregroundStyle(Native.fgSecondary)
                    case .huggingFaceGated: Text("Hugging Face gated").font(.caption).foregroundStyle(Native.fgSecondary)
                    }
                }
                Text(entry.attribution).font(.caption).foregroundStyle(Native.fgSecondary)
                if entry.needsDownload {
                    Text("Pinned revision, SHA-256 verified").font(.caption).foregroundStyle(Native.fgSecondary)
                }
            }
            Spacer()
            trailing(entry)
        }
    }

    @ViewBuilder private func trailing(_ entry: ModelEntry) -> some View {
        switch store.state(for: entry) {
        case .notInstalled:
            Button("Download \(entry.sizeText)") { Task { await store.install(entry) } }
        case .downloading(let value):
            HStack {
                ProgressView(value: value).frame(width: Metric.sliderW)
                Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit())
            }
        case .verifying:
            Text("Verifying SHA-256…").font(.caption).foregroundStyle(Native.fgSecondary)
        case .installed:
            if entry.needsDownload {
                Text(entry.sizeText).font(.caption).foregroundStyle(Native.fgSecondary)
                Button { pendingDelete = entry } label: { Label("Delete", systemImage: "trash") }
                    .labelStyle(.iconOnly).help("Delete \(entry.displayName)").accessibilityLabel("Delete \(entry.displayName)")
            } else {
                Text("Built in").font(.caption).foregroundStyle(Native.fgSecondary)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: Metric.sp2) {
                Text(message).font(.caption).foregroundStyle(Native.danger).lineLimit(2)
                Button("Retry") { Task { await store.install(entry) } }
            }
        }
    }
}
