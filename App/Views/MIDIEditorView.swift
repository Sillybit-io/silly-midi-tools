import AppKit
import SwiftUI

enum MIDITool: String, CaseIterable, Identifiable {
    case select, draw, erase

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var key: String {
        switch self {
        case .select: "v"
        case .draw: "d"
        case .erase: "e"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .draw: "pencil"
        case .erase: "eraser"
        }
    }
}

/// One open MIDI file: its document plus the editor's own view state.
@MainActor @Observable
final class MIDIEditorModel {
    let id = UUID()
    private(set) var url: URL
    let document: MIDIDocument
    var provenance: MIDIProvenance?
    /// The file as it was when opened or last saved; a save refuses to overwrite a file that no longer matches.
    var fingerprint: FileFingerprint?
    var tool: MIDITool = .select
    var pixelsPerSecond: CGFloat = Metric.ppsEditor
    var showExport = false
    let playback = PlaybackEngine()

    init(url: URL, imported: ImportedMIDI, fingerprint: FileFingerprint? = nil) {
        self.url = url
        self.fingerprint = fingerprint
        provenance = imported.provenance
        document = MIDIDocument(sourceName: url.lastPathComponent, imported: imported)
    }

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Notes from Basic Pitch are one undifferentiated track, drawn in the neutral colour and called Notes.
    var isSingleTrackTranscription: Bool { provenance?.modelID == AppPreferences.fallbackModelID }

    private func isUndifferentiated(_ track: String) -> Bool {
        isSingleTrackTranscription && track == document.tracks.first?.id
    }

    func colour(forTrack track: String) -> Color {
        isUndifferentiated(track) ? InstrumentColor.color(forFamily: "all") : InstrumentColor.color(for: track)
    }

    /// A hit on a drum track takes its kit piece's colour; any other note takes its track's.
    func colour(for note: EditorNote) -> Color {
        document.tracks.first { $0.id == note.track }?.isDrums == true
            ? DrumKit.piece(forPitch: note.pitch).colour : colour(forTrack: note.track)
    }

    /// The pitches carrying drum hits, named and coloured for the key column.
    var drumLanes: [Int: (label: String, colour: Color)] {
        let drumTracks = Set(document.tracks.filter(\.isDrums).map(\.id))
        guard !drumTracks.isEmpty else { return [:] }
        let document = document
        return DrumKit.lanes(pitches: document.notes.lazy.filter { drumTracks.contains($0.track) && document.isVisible($0) }.map(\.pitch))
    }

    func displayName(ofTrack track: String) -> String {
        if isUndifferentiated(track) { return "Notes" }
        let name = document.tracks.first { $0.id == track }?.name ?? track.replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The notes as a slice that starts at zero and ends after the last note, for exporting the edited file.
    var exportSlice: AudioSlice {
        AudioSlice(duration: max(AudioSlice.step, document.notes.map(\.end).max() ?? 0))
    }

    /// Renames the file on disk. The document, its edits and its undo steps stay as they are.
    @discardableResult
    func rename(to name: String) throws -> URL {
        let renamed = try MIDIFileName.rename(url, to: name)
        url = renamed
        fingerprint = FileFingerprint.of(renamed)
        return renamed
    }

    /// The playback groups to switch off: every track that isn't audible. Matches `PlaybackEngine.groupKey`.
    var silencedGroups: Set<String> {
        Set(document.tracks.filter { !document.isAudible(track: $0.id) }.map { $0.isDrums ? "drums" : $0.id })
    }

    /// Gives the engine the document's notes and the end of the last one as the loop end.
    func syncPlayback() {
        playback.grid = document.grid
        playback.duration = document.notes.map(\.end).max() ?? 0
        playback.replace(notes: document.noteEvents)
        playback.setSilenced(silencedGroups)
    }

    func togglePlayback() {
        if playback.isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
    }

    static func load(_ url: URL) throws -> MIDIEditorModel {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MIDIImportError.readFailed(url.lastPathComponent)
        }
        return MIDIEditorModel(url: url, imported: try MIDIImporter.decode(data), fingerprint: FileFingerprint.of(url))
    }
}

/// The editable piano roll. Every change goes through `MIDIDocument`, so it is undoable; while a drag is in progress
/// the roll only previews the result of the same pure edit and commits once when the pointer is released.
struct MIDIEditorView: View {
    @Bindable var editor: MIDIEditorModel
    @Environment(\.undoManager) private var undoManager
    @Environment(MIDISaveCoordinator.self) private var coordinator
    @Environment(AppPreferences.self) private var preferences
    @State private var scroll = ScrollPosition()
    @State private var offset = CGPoint.zero
    @State private var session: Session?
    @State private var preview: [EditorNote]?
    @FocusState private var focused: Bool

    private static let pitches = MIDIEditing.pitchRange

    private var document: MIDIDocument { editor.document }

    private struct Session {
        enum Mode {
            case none
            case marquee(base: Set<Int>)
            case move
            case resize
            case draw(time: Double, pitch: Int)
            case erase
        }

        var mode: Mode
        var start: CGPoint
        var startGrid: CGPoint
        var currentGrid: CGPoint
        var ids: Set<Int> = []
        var moved = false
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = PianoRollLayout(pixelsPerSecond: editor.pixelsPerSecond, xOrigin: -offset.x,
                                         laneHeight: Metric.rowH, topPitch: Self.pitches.upperBound)
            let extent = max(8, (document.notes.map(\.end).max() ?? 0) + 4)
            let contentWidth = max(proxy.size.width - Metric.keysW, layout.contentWidth(duration: extent))
            let contentHeight = RollDrawing.contentHeight(pitches: Self.pitches)
            let yOffset = offset.y
            let lanes = editor.drumLanes
            let playhead: Double? = editor.playback.isPlaying || editor.playback.position > 0 ? editor.playback.position : nil
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Token.surfaceSunken.frame(width: Metric.keysW, height: Metric.rulerH)
                    Canvas { context, size in RollDrawing.ruler(context, size, layout, grid: document.grid) }
                        .frame(height: Metric.rulerH).background(Token.surfaceSunken)
                        .gesture(SpatialTapGesture().onEnded { editor.playback.seek(to: layout.seconds(atX: $0.location.x)) })
                        .help("Click to move the playhead")
                        .accessibilityLabel("Ruler")
                        .accessibilityHint("Click to move the playhead")
                }
                HStack(spacing: 0) {
                    Canvas { context, size in RollDrawing.keys(context, size, pitches: Self.pitches, yOffset: yOffset, lanes: lanes) }
                        .frame(width: Metric.keysW)
                    ScrollView([.horizontal, .vertical]) {
                        Color.clear.frame(width: contentWidth, height: contentHeight)
                    }
                    .defaultScrollAnchor(UnitPoint(x: 0, y: 0.45))
                    .scrollPosition($scroll)
                    .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, new in
                        offset = CGPoint(x: max(0, new.x), y: max(0, new.y))
                    }
                    .overlay {
                        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                            draw(context, size, layout, yOffset: yOffset, playhead: playhead)
                        }
                        .allowsHitTesting(false)
                    }
                    .gesture(editGesture(layout))
                    .onContinuousHover { phase in updateCursor(phase, layout) }
                }
                Divider()
                HStack(spacing: 0) {
                    Text("Vel").font(.caption).foregroundStyle(Native.fgSecondary)
                        .frame(width: Metric.keysW, height: Metric.velH).background(Token.surfaceSunken)
                    MIDIVelocityLaneView(document: document, layout: layout, colour: editor.colour(for:))
                }
                Divider()
                MIDIEditorFooterView(editor: editor, document: document)
            }
            .background(Token.surface)
            .onChange(of: playhead) { _, seconds in follow(seconds, viewport: proxy.size.width - Metric.keysW) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("MIDI editor")
            .accessibilityValue("\(document.notes.count) notes, \(document.selection.count) selected")
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress { handle($0) }
        .onCommand(#selector(NSResponder.selectAll(_:))) { document.selectAll() }
        .onDeleteCommand { document.deleteSelection() }
        .onChange(of: undoManager, initial: true) { _, manager in document.undoManager = manager }
        .onChange(of: document.revision, initial: true) { editor.syncPlayback() }
        .onChange(of: editor.silencedGroups) { _, groups in editor.playback.setSilenced(groups) }
        .toolbar {
            ToolbarItem {
                TransportView(playback: editor.playback, toggle: editor.togglePlayback)
            }
            ToolbarItem {
                Picker("Tool", selection: $editor.tool) {
                    ForEach(MIDITool.allCases) { tool in
                        Label {
                            Text("\(tool.title) (\(tool.key.uppercased()))")
                        } icon: {
                            // The segment reads its accessibility name from the image, not the label's text.
                            Image(systemName: tool.symbol).accessibilityLabel(tool.title)
                        }
                        .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .help("Select (V), Draw (D), Erase (E)")
            }
            ToolbarItemGroup {
                Button { document.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!(document.revision >= 0 && document.canUndo)).help("Undo")
                Button { document.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!(document.revision >= 0 && document.canRedo)).help("Redo")
            }
            ToolbarSpacer(.fixed)
            // The capsule draws its own background, so it stays out of the undo and redo glass.
            ToolbarItem {
                Button { coordinator.save(editor) } label: {
                    CapsuleActionLabel(title: "Save", systemImage: "square.and.arrow.down", isPrimary: document.isDirty, isEnabled: document.isDirty)
                }
                .buttonStyle(.plain)
                .disabled(!document.isDirty).help("Save (\u{2318}S)")
                .accessibilityValue(document.isDirty ? "Unsaved changes" : "No unsaved changes")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem {
                ExportView(notes: document.noteEvents, entry: ModelCatalog.entry(id: editor.provenance?.modelID),
                           slice: editor.exportSlice, name: editor.name, grid: document.grid, showNotice: $editor.showExport)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem { InspectorToggle() }
        }
    }

    // MARK: Drawing

    private func follow(_ seconds: Double?, viewport: CGFloat) {
        guard preferences.followPlayhead, let seconds,
              let target = PlaybackEngine.followOffset(playheadX: CGFloat(seconds) * editor.pixelsPerSecond, offsetX: offset.x, viewport: viewport)
        else { return }
        scroll.scrollTo(point: CGPoint(x: target, y: offset.y))
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, _ layout: PianoRollLayout, yOffset: CGFloat, playhead: Double?) {
        var context = context
        context.translateBy(x: 0, y: -yOffset)
        let top = yOffset, bottom = yOffset + size.height
        RollDrawing.grid(context, size, layout, pitches: Self.pitches, top: top, bottom: bottom, grid: document.grid)
        for note in preview ?? document.notes where document.isVisible(note) {
            let rect = MIDIEditing.rect(of: note, in: layout)
            guard rect.maxX >= 0, rect.minX <= size.width, rect.maxY >= top, rect.minY <= bottom else { continue }
            let level = 0.4 + 0.6 * Double(note.velocity) / 127
            let color = editor.colour(for: note).opacity(document.isAudible(note) ? level : 0.3)
            RollDrawing.note(context, rect: rect, color: color, selected: document.selection.contains(note.id))
        }
        if let playhead { RollDrawing.line(context, x: layout.x(seconds: playhead), top: top, bottom: bottom, color: Token.playhead) }
        guard let session else { return }
        switch session.mode {
        case .draw(let time, let pitch):
            let length = MIDIEditing.drawLength(dragSeconds: dragSeconds(session), grid: document.snap, quarter: document.grid.secondsPerQuarter)
            let ghost = EditorNote(id: -1, track: document.drawTrackID, pitch: pitch,
                                   start: MIDIEditing.snapFloor(time, to: document.snap, quarter: document.grid.secondsPerQuarter),
                                   duration: length, velocity: MIDIEditing.defaultVelocity)
            RollDrawing.note(context, rect: MIDIEditing.rect(of: ghost, in: layout), color: editor.colour(for: ghost).opacity(0.7), selected: true)
        case .marquee where session.moved:
            let box = CGRect(x: min(session.startGrid.x, session.currentGrid.x), y: min(session.startGrid.y, session.currentGrid.y),
                             width: abs(session.currentGrid.x - session.startGrid.x), height: abs(session.currentGrid.y - session.startGrid.y))
            context.fill(Path(box), with: .color(Token.accentSoft))
            context.stroke(Path(box), with: .color(Token.accent), lineWidth: Metric.hairline)
        default:
            break
        }
    }

    // MARK: Pointer

    private func dragSeconds(_ session: Session) -> Double {
        Double((session.currentGrid.x - session.startGrid.x) / editor.pixelsPerSecond)
    }

    private func editGesture(_ layout: PianoRollLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if session == nil { begin(at: value.startLocation, layout) }
                update(to: value.location, layout)
            }
            .onEnded { value in
                update(to: value.location, layout)
                finish()
            }
    }

    private func gridPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x, y: location.y + offset.y)
    }

    private func begin(at location: CGPoint, _ layout: PianoRollLayout) {
        focused = true
        let point = gridPoint(location)
        let hit = MIDIEditing.hit(at: point, notes: document.notes, layout: layout, hiddenTracks: document.hiddenTracks)
        let shift = NSEvent.modifierFlags.contains(.shift)
        var session = Session(mode: .none, start: location, startGrid: point, currentGrid: point)
        if editor.tool == .erase {
            session.mode = .erase
            if let hit { session.ids = [hit.id] }
            preview = document.notes.filter { !session.ids.contains($0.id) }
        } else if let hit {
            if shift {
                document.toggleSelection(hit.id)
            } else {
                if !document.selection.contains(hit.id) { document.select(hit.id) }
                session.ids = document.selection
                if case .resizeEdge = hit { session.mode = .resize } else { session.mode = .move }
            }
        } else if editor.tool == .draw {
            session.mode = .draw(time: layout.seconds(atX: location.x), pitch: MIDIEditing.pitch(atGridY: point.y))
        } else {
            let base = shift ? document.selection : []
            if !shift { document.clearSelection() }
            session.mode = .marquee(base: base)
        }
        self.session = session
    }

    private func update(to location: CGPoint, _ layout: PianoRollLayout) {
        guard var session else { return }
        session.currentGrid = gridPoint(location)
        session.moved = session.moved || abs(location.x - session.start.x) >= Metric.dragSlop || abs(location.y - session.start.y) >= Metric.dragSlop
        let seconds = dragSeconds(session)
        switch session.mode {
        case .none, .draw:
            break
        case .marquee(let base):
            if session.moved {
                let box = MIDIEditing.marquee(from: session.startGrid, to: session.currentGrid, layout: layout)
                document.selectNotes(inTime: box.time, pitches: box.pitches, additiveTo: base)
            }
        case .move:
            if session.moved {
                let steps = MIDIEditing.semitones(forDragY: location.y - session.start.y)
                preview = MIDIEditing.move(document.notes, ids: session.ids, deltaTime: seconds, deltaPitch: steps,
                                           grid: document.snap, quarter: document.grid.secondsPerQuarter)
            }
        case .resize:
            if session.moved {
                preview = MIDIEditing.resize(document.notes, ids: session.ids, delta: seconds,
                                             grid: document.snap, quarter: document.grid.secondsPerQuarter)
            }
        case .erase:
            if let hit = MIDIEditing.hit(at: session.currentGrid, notes: document.notes, layout: layout, hiddenTracks: document.hiddenTracks) {
                session.ids.insert(hit.id)
            }
            preview = document.notes.filter { !session.ids.contains($0.id) }
        }
        self.session = session
    }

    /// Commits the whole gesture as one undoable edit.
    private func finish() {
        guard let session else { return }
        defer {
            self.session = nil
            preview = nil
        }
        let seconds = dragSeconds(session)
        let steps = MIDIEditing.semitones(forDragY: session.currentGrid.y - session.startGrid.y)
        switch session.mode {
        case .none, .marquee:
            break
        case .move:
            if session.moved { document.move(session.ids, deltaTime: seconds, deltaPitch: steps) }
        case .resize:
            if session.moved { document.resize(session.ids, delta: seconds) }
        case .draw(let time, let pitch):
            document.draw(at: time, pitch: pitch, length: MIDIEditing.drawLength(dragSeconds: seconds, grid: document.snap,
                                                                                quarter: document.grid.secondsPerQuarter))
        case .erase:
            document.erase(session.ids)
        }
    }

    private func updateCursor(_ phase: HoverPhase, _ layout: PianoRollLayout) {
        guard case .active(let location) = phase else {
            NSCursor.arrow.set()
            return
        }
        let hit = MIDIEditing.hit(at: gridPoint(location), notes: document.notes, layout: layout, hiddenTracks: document.hiddenTracks)
        if case .resizeEdge = hit, editor.tool != .erase {
            NSCursor.resizeLeftRight.set()
        } else if editor.tool == .draw, hit == nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        if press.modifiers.contains(.command) {
            guard press.characters == "a" else { return .ignored }
            document.selectAll()
            return .handled
        }
        if press.modifiers.contains(.option), press.key == .leftArrow || press.key == .rightArrow {
            if let note = document.selectAdjacent(press.key == .rightArrow ? 1 : -1) {
                let name = MIDIEditorInspectorView.pitchName(note.pitch)
                AccessibilityNotification.Announcement(String(format: "%@, %.2f seconds, velocity %d", name, note.start, note.velocity)).post()
            }
            return .handled
        }
        switch press.key {
        case .space: editor.togglePlayback()
        case .delete, .deleteForward: document.deleteSelection()
        case .upArrow: document.transpose(by: shift ? 12 : 1)
        case .downArrow: document.transpose(by: shift ? -12 : -1)
        case .leftArrow: document.nudge(steps: -1)
        case .rightArrow: document.nudge(steps: 1)
        case .escape: document.clearSelection()
        default:
            let character = press.characters.lowercased()
            if let tool = MIDITool.allCases.first(where: { $0.key == character }) {
                editor.tool = tool
            } else if character == "q" {
                document.quantize()
            } else if character == "l" {
                editor.playback.loops.toggle()
            } else if character == "c" {
                editor.playback.click.toggle()
            } else {
                return .ignored
            }
        }
        return .handled
    }
}

private struct MIDIEditorFooterView: View {
    @Bindable var editor: MIDIEditorModel
    @Bindable var document: MIDIDocument

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metric.sp6) {
                summaryText
                Spacer(minLength: Metric.sp4)
                exportChip
                snapControl
                quantizeButton
                speedControl
                zoomControl
            }
            VStack(alignment: .leading, spacing: Metric.sp3) {
                HStack(spacing: Metric.sp6) { summaryText; Spacer(minLength: Metric.sp4); exportChip; zoomControl }
                HStack(spacing: Metric.sp6) { snapControl; quantizeButton; speedControl; Spacer(minLength: 0) }
            }
            VStack(alignment: .leading, spacing: Metric.sp3) {
                summaryText
                HStack(spacing: Metric.sp6) { exportChip; Spacer(minLength: 0); zoomControl }
                HStack(spacing: Metric.sp6) { snapControl; quantizeButton; speedControl; Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, Metric.sp6).padding(.vertical, Metric.sp4)
    }

    private var exportChip: some View {
        MIDIDragChip(notes: document.noteEvents, entry: ModelCatalog.entry(id: editor.provenance?.modelID),
                     slice: editor.exportSlice, name: editor.name, grid: document.grid)
    }

    private var summaryText: some View {
        Text(summary).font(.caption).foregroundStyle(Native.fgSecondary).lineLimit(1)
    }

    private var snapControl: some View {
        HStack(spacing: Metric.sp3) {
            Text("Snap").font(.caption).fixedSize()
            Picker("Snap", selection: $document.snap) {
                ForEach(SnapGrid.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().controlSize(.small).fixedSize()
        }
    }

    private var quantizeButton: some View {
        Button(document.selection.isEmpty ? "Quantize All" : "Quantize Selection") { document.quantize() }
            .controlSize(.small).fixedSize()
            .disabled(document.snap == .off || document.notes.isEmpty)
    }

    private var speedControl: some View {
        HStack(spacing: Metric.sp3) {
            Text("Speed").font(.caption).fixedSize()
            Slider(value: Binding(get: { Double(editor.playback.rate) }, set: { editor.playback.rate = Float($0) }), in: 0.5...2)
                .frame(width: Metric.sliderW).accessibilityLabel("Playback speed")
            Text(String(format: "%.2f\u{00D7}", editor.playback.rate)).font(.caption.monospacedDigit()).frame(width: Metric.readoutW, alignment: .leading)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: Metric.sp3) {
            Image(systemName: "minus").font(.caption)
            Slider(value: $editor.pixelsPerSecond, in: Metric.ppsEditorMin...Metric.ppsMax).frame(width: Metric.sliderW).accessibilityLabel("Zoom")
            Image(systemName: "plus").font(.caption)
        }
    }

    private var summary: String {
        MIDIEditorView.summary(notes: document.notes, selection: document.selection, trackName: editor.displayName(ofTrack:),
                     skipped: document.skippedNotes)
    }
}

extension MIDIEditorView {
    /// The footer line, in the prototype's wording.
    static func summary(notes: [EditorNote], selection: Set<Int>, trackName: (String) -> String, skipped: Int) -> String {
        let selected = notes.filter { selection.contains($0.id) }
        if selected.count == 1, let note = selected.first {
            return "\(MIDIEditorInspectorView.pitchName(note.pitch)) \u{00B7} \(trackName(note.track)) \u{00B7} "
                + String(format: "%.2f s", note.start) + " \u{2014} 1 of \(notes.count) selected"
        }
        if !selected.isEmpty { return "\(selected.count) of \(notes.count) notes selected" }
        var text = "\(notes.count) \(notes.count == 1 ? "note" : "notes") \u{00B7} drag empty space to select, \u{2325}\u{2190} \u{2325}\u{2192} to step through notes, D to draw, E to erase"
        if skipped > 0 { text += " \u{00B7} \(skipped) outside C1\u{2013}B6 skipped" }
        return text
    }
}
