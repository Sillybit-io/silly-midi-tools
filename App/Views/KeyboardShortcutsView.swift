import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let sections: [(title: String, rows: [(keys: String, action: String)])] = [
        ("General", [
            ("\u{2318}O", "Open Audio\u{2026}"), ("\u{21E7}\u{2318}O", "Import MIDI\u{2026}"), ("\u{2318}S", "Save the MIDI file"),
            ("\u{2318}E", "Export MIDI\u{2026}"), ("\u{2318},", "Settings"), ("\u{2318}1", "Audio"), ("\u{2318}2", "MIDI Editor"),
            ("\u{2325}\u{2318}I", "Show or hide the inspector"), ("\u{2318}+  \u{2318}\u{2212}", "Zoom in, zoom out"), ("\u{2318}/", "Keyboard Shortcuts"),
        ]),
        ("Transcribe", [
            ("\u{21A9}", "Transcribe"), ("\u{2318}.", "Cancel the run"),
        ]),
        ("Controls", [
            ("C", "Turn the click on or off"),
        ]),
        ("MIDI editor", [
            ("V  D  E", "Select, Draw and Erase tools"), ("\u{2318}A", "Select all notes"), ("\u{232B}", "Delete the selected notes"),
            ("\u{2191}  \u{2193}", "Transpose by a semitone (\u{21E7} for an octave)"), ("\u{2190}  \u{2192}", "Nudge by one snap step"),
            ("Q", "Quantize the selection, or everything"), ("\u{2318}Z  \u{21E7}\u{2318}Z", "Undo, redo"), ("Esc", "Deselect"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.sp6) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.sp6) {
                    ForEach(Self.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: Metric.sp3) {
                            Text(section.title).font(.headline)
                            ForEach(section.rows, id: \.action) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.action)
                                    Spacer()
                                    Text(row.keys).font(.body.monospaced()).foregroundStyle(Native.fgSecondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metric.sp8)
        .frame(width: Metric.sheetW + Metric.sp10, height: Metric.aboutH)
    }
}
