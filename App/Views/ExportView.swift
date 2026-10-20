import SwiftUI
import UniformTypeIdentifiers

/// Builds the file the toolbar's Export… button saves and the footer's chip drags out. Neither carries the `smt:` text
/// or anything else that names the source audio's folder, and both leave out notes outside C1–B6, which the editor
/// can't show. Left at its defaults, as the chip does, the file has no licence notice and no pitch bends.
enum MIDIExport {
    static let comment = "Exported from Silly MIDI Tools"

    static func exportable(_ notes: [NoteEvent]) -> [NoteEvent] {
        notes.filter { MIDIEditing.pitchRange.contains($0.pitch) }
    }

    static func item(notes: [NoteEvent], entry: ModelEntry?, slice: AudioSlice, name: String,
                     grid: MIDIGrid = .standard, embedNotice: Bool = false, pitchBends: Bool = false, keyInName: Bool = true) -> MIDIExportItem {
        var options = MIDIExportOptions()
        options.grid = grid
        options.sliceStart = slice.start
        options.sliceLength = slice.span
        options.relativeTimeline = slice.relativeTimeline
        options.title = name
        options.copyright = embedNotice ? (entry?.exportNotice ?? "") : nil
        options.comment = comment
        options.includesPitchBends = pitchBends
        let kept = exportable(notes)
        return MIDIExportItem(notes: kept, options: options, name: fileName(notes: kept, name: name, keyInName: keyInName))
    }

    static func fileName(notes: [NoteEvent], name: String, keyInName: Bool = true) -> String {
        keyInName ? ExportNaming.fileName(base: name, key: KeyDetector.rank(notes: exportable(notes)).first) : name
    }
}

struct ExportView: View {
    let notes: [NoteEvent]
    let entry: ModelEntry?
    let slice: AudioSlice
    let name: String
    var grid: MIDIGrid = .standard

    @Binding var showNotice: Bool
    @State private var embedNotice = true
    @State private var pitchBends = false
    @State private var keyInName = true
    @State private var exporting = false
    @State private var item: MIDIExportItem?

    private var notice: String { entry?.exportNotice ?? "" }
    private var hasPitchBends: Bool { notes.contains { !($0.pitchBends ?? []).isEmpty } }

    private var fileName: String { MIDIExport.fileName(notes: notes, name: name, keyInName: keyInName) }

    var body: some View {
        // Drawn like Save and Transcribe, so the three actions share one height and inset.
        Button { showNotice = true } label: {
            CapsuleActionLabel(title: "Export\u{2026}", systemImage: "square.and.arrow.up", isPrimary: false, isEnabled: !notes.isEmpty)
        }
        .buttonStyle(.plain)
        .help("Export MIDI (\u{2318}E)")
        .accessibilityLabel("Export MIDI\u{2026}")
        .disabled(notes.isEmpty)
        .sheet(isPresented: $showNotice) {
            VStack(alignment: .leading, spacing: Metric.sp5) {
                Text("Export MIDI").font(.title3.bold())
                Text(notice.isEmpty ? "No licence notice for this model." : notice)
                Toggle("Embed this notice in the MIDI file", isOn: $embedNotice)
                if hasPitchBends {
                    Toggle("Include pitch bends (for a \u{00B1}2 semitone bend range)", isOn: $pitchBends)
                }
                Toggle("Add the detected key to the file name (\(fileName).mid)", isOn: $keyInName)
                HStack {
                    Spacer()
                    Button("Cancel") { showNotice = false }
                    Button("Export") {
                        item = MIDIExport.item(notes: notes, entry: entry, slice: slice, name: name, grid: grid,
                                               embedNotice: embedNotice, pitchBends: pitchBends, keyInName: keyInName)
                        showNotice = false
                        exporting = true
                    }.buttonStyle(.borderedProminent)
                }
            }
            .padding(Metric.sp7).frame(width: Metric.sheetW)
        }
        .fileExporter(isPresented: $exporting, item: item, contentTypes: [.midi], defaultFilename: "\(fileName).mid") { result in
            switch result {
            case .success(let url): debugLog(.export, "Exported to \(url.path).")
            case .failure(let error): debugLog(.export, "Export failed: \(String(reflecting: error))")
            }
            MIDIExportItem.clearTemporaryFiles()
        } onCancellation: {
            debugLog(.export, "Export cancelled.")
            MIDIExportItem.clearTemporaryFiles()
        }
    }
}

/// The MIDI file as an object to drag into a DAW or Finder. It sits in the footer, which stays in view whatever the
/// inspector shows. A file name on its own read as a label, so the chip looks like a file and says what to do with it:
/// Finder's MIDI icon, "Drag into your DAW", the name, a grab pointer and a highlight on hover. It is left out until
/// there are notes to drag.
struct MIDIDragChip: View {
    let notes: [NoteEvent]
    let entry: ModelEntry?
    let slice: AudioSlice
    let name: String
    var grid: MIDIGrid = .standard

    @State private var hovering = false

    private static let fileIcon = NSWorkspace.shared.icon(for: .midi)

    var body: some View {
        if !MIDIExport.exportable(notes).isEmpty {
            let file = "\(MIDIExport.fileName(notes: notes, name: name)).mid"
            let shape = RoundedRectangle(cornerRadius: Metric.rRow)
            HStack(spacing: Metric.sp3) {
                Image(nsImage: Self.fileIcon).resizable().frame(width: Metric.dragIcon, height: Metric.dragIcon)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Drag into your DAW").font(.caption.weight(.semibold)).foregroundStyle(Native.fg)
                    Text(file).font(.caption2).foregroundStyle(Native.fgSecondary).truncationMode(.middle)
                }
                .lineLimit(1)
            }
            .padding(.leading, Metric.sp2).padding(.trailing, Metric.sp5).padding(.vertical, Metric.sp1)
            .frame(maxWidth: Metric.dragChipW, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(hovering ? Token.accentSoft : Token.surfaceSunken, in: shape)
            .overlay(shape.strokeBorder(hovering ? Token.accent : Token.borderStrong))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .pointerStyle(.grabIdle)
            .draggable(MIDIExport.item(notes: notes, entry: entry, slice: slice, name: name, grid: grid)) {
                Label {
                    Text(file)
                } icon: {
                    Image(nsImage: Self.fileIcon).resizable().frame(width: Metric.dragIcon, height: Metric.dragIcon)
                }
            }
            .help("Drag this MIDI file onto a track in your DAW, or into a Finder window")
            .accessibilityLabel("MIDI file \(file), drag into a DAW or Finder")
        }
    }
}
