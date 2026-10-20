import SwiftUI

/// Drawing shared by the read-only Audio roll and the MIDI editor. Hit testing is deliberately not here.
enum RollDrawing {
    private static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]

    struct GridLine {
        let seconds: Double
        let barNumber: Int?

        var isBar: Bool { barNumber != nil }
    }

    static func gridLines(grid: MIDIGrid = .standard, from: Double, to: Double) -> [GridLine] {
        guard to.isFinite, to >= 0, from.isFinite, from <= to else { return [] }
        let start = max(0, from)
        var lines: [GridLine] = []
        for (index, meter) in grid.meters.enumerated() {
            let segmentStart = grid.seconds(ofBar: meter.bar)
            let segmentEnd = index + 1 < grid.meters.count ? grid.seconds(ofBar: grid.meters[index + 1].bar) : .infinity
            guard segmentStart <= to, segmentEnd > start else { continue }
            let beat = grid.segment(atSeconds: segmentStart).secondsPerBeat
            var beatIndex = max(0, Int(((start - segmentStart) / beat).rounded(.down)))
            while true {
                let seconds = segmentStart + Double(beatIndex) * beat
                if seconds > to + 1e-9 || seconds >= segmentEnd - 1e-9 { break }
                if seconds >= start {
                    let barNumber = beatIndex % meter.numerator == 0 ? meter.bar + beatIndex / meter.numerator + 1 : nil
                    lines.append(GridLine(seconds: seconds, barNumber: barNumber))
                }
                beatIndex += 1
            }
        }
        return lines
    }

    static func isBlack(_ pitch: Int) -> Bool { blackKeys.contains(pitch % 12) }

    static func contentHeight(pitches: ClosedRange<Int>) -> CGFloat {
        CGFloat(pitches.count) * Metric.rowH
    }

    static func ruler(_ context: GraphicsContext, _ size: CGSize, _ layout: PianoRollLayout, grid: MIDIGrid = .standard) {
        for line in gridLines(grid: grid, from: layout.seconds(atX: 0), to: layout.seconds(atX: size.width)) {
            guard let barNumber = line.barNumber else { continue }
            let x = layout.x(seconds: line.seconds)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: size.height * 0.45))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tick, with: .color(Token.gridBar), lineWidth: Metric.hairline)
            context.draw(Text("\(barNumber)").font(.system(size: TypeScale.caption)).foregroundStyle(Native.fgSecondary),
                         at: CGPoint(x: x + Metric.sp2, y: size.height * 0.3), anchor: .leading)
        }
    }

    /// `lanes` names the pitches that carry drum hits: such a row is a plain key with a colour bar and the piece's name,
    /// because on a drum track the row is a kit piece, not a note.
    static func keys(_ context: GraphicsContext, _ size: CGSize, pitches: ClosedRange<Int>, yOffset: CGFloat,
                     lanes: [Int: (label: String, colour: Color)] = [:]) {
        for pitch in pitches {
            let y = CGFloat(pitches.upperBound - pitch) * Metric.rowH - yOffset
            guard y + Metric.rowH >= 0, y <= size.height else { continue }
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Metric.rowH)), with: .color(Token.keyWhite))
            if let lane = lanes[pitch] {
                context.fill(Path(CGRect(x: 0, y: y, width: Metric.sp2, height: Metric.rowH)), with: .color(lane.colour))
                context.draw(Text(lane.label).font(.system(size: TypeScale.micro)).foregroundStyle(Token.keyLabel),
                             at: CGPoint(x: size.width - Metric.sp2, y: y + Metric.rowH / 2), anchor: .trailing)
                continue
            }
            if isBlack(pitch) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width * 0.6, height: Metric.rowH)), with: .color(Token.keyBlack))
            }
            if pitch % 12 == 0 {
                context.draw(Text("C\(pitch / 12 - 1)").font(.system(size: TypeScale.micro)).foregroundStyle(Token.keyLabel),
                             at: CGPoint(x: size.width - Metric.sp2, y: y + Metric.rowH / 2), anchor: .trailing)
            }
        }
    }

    /// Lanes and beat lines. `context` is already translated so y is content-space; `top`/`bottom` bound what is visible.
    static func grid(_ context: GraphicsContext, _ size: CGSize, _ layout: PianoRollLayout, pitches: ClosedRange<Int>, top: CGFloat, bottom: CGFloat,
                     grid: MIDIGrid = .standard) {
        for pitch in pitches {
            let y = layout.y(pitch: pitch)
            guard y + Metric.rowH >= top, y <= bottom else { continue }
            if isBlack(pitch) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Metric.rowH)), with: .color(Token.gridBeat))
            }
            if pitch % 12 == 0 {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y + Metric.rowH))
                line.addLine(to: CGPoint(x: size.width, y: y + Metric.rowH))
                context.stroke(line, with: .color(Token.gridBar), lineWidth: Metric.hairline)
            }
        }
        for beatLine in gridLines(grid: grid, from: layout.seconds(atX: 0), to: layout.seconds(atX: size.width)) {
            let x = layout.x(seconds: beatLine.seconds)
            var line = Path()
            line.move(to: CGPoint(x: x, y: top))
            line.addLine(to: CGPoint(x: x, y: bottom))
            context.stroke(line, with: .color(beatLine.isBar ? Token.gridBar : Token.gridBeat), lineWidth: Metric.hairline)
        }
    }

    static func note(_ context: GraphicsContext, rect: CGRect, color: Color, selected: Bool = false) {
        let path = Path(roundedRect: rect, cornerRadius: Metric.rNote)
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(selected ? Token.fg : Token.noteEdge), lineWidth: selected ? Metric.strongLine : Metric.hairline)
    }

    static func line(_ context: GraphicsContext, x: CGFloat, top: CGFloat, bottom: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: bottom))
        context.stroke(path, with: .color(color), lineWidth: Metric.strongLine)
    }
}

struct PianoRollView: View {
    let notes: [NoteEvent]
    let duration: Double
    let finalizedThrough: Double
    var playhead: Double?
    let hidden: Set<String>
    @Binding var pixelsPerSecond: CGFloat
    var grid: MIDIGrid = .standard
    /// Scrolls to keep the playhead in view while it moves.
    var follows = false
    /// Called with the time under a click on the ruler.
    var onSeek: ((Double) -> Void)?
    /// Draws every note in the neutral colour (one undifferentiated track).
    var neutralColour = false
    var showsEmptyState = false

    @State private var zoomAtStart: CGFloat?
    @State private var offset = CGPoint.zero
    @State private var scroll = ScrollPosition()

    static let lowPitch = 21
    static let highPitch = 108
    private var pitches: ClosedRange<Int> { Self.lowPitch...Self.highPitch }

    var body: some View {
        GeometryReader { proxy in
            let layout = PianoRollLayout(pixelsPerSecond: pixelsPerSecond, xOrigin: -offset.x,
                                         laneHeight: Metric.rowH, topPitch: Self.highPitch)
            let contentWidth = max(proxy.size.width - Metric.keysW, layout.contentWidth(duration: duration) + Metric.sp10)
            let contentHeight = RollDrawing.contentHeight(pitches: pitches)
            let xOffset = offset.x, yOffset = offset.y
            let lanes = DrumKit.lanes(pitches: notes.lazy.filter { $0.isDrum && !hidden.contains($0.instrument) }.map(\.pitch))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Token.surfaceSunken.frame(width: Metric.keysW, height: Metric.rulerH)
                    Canvas { context, size in RollDrawing.ruler(context, size, layout, grid: grid) }
                        .frame(height: Metric.rulerH).background(Token.surfaceSunken)
                        .gesture(SpatialTapGesture().onEnded { onSeek?(layout.seconds(atX: $0.location.x)) })
                        .help("Click to move the playhead")
                        .accessibilityLabel("Ruler")
                        .accessibilityHint("Click to move the playhead")
                }
                HStack(spacing: 0) {
                    Canvas { context, size in RollDrawing.keys(context, size, pitches: pitches, yOffset: yOffset, lanes: lanes) }
                        .frame(width: Metric.keysW)
                    ZStack {
                        ScrollView([.horizontal, .vertical]) {
                            Color.clear.frame(width: contentWidth, height: contentHeight)
                        }
                        .defaultScrollAnchor(UnitPoint(x: 0, y: 0.62))
                        .scrollPosition($scroll)
                        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, new in
                            offset = CGPoint(x: max(0, new.x), y: max(0, new.y))
                        }
                        .overlay {
                            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                                draw(context, size, layout, xOffset: xOffset, yOffset: yOffset)
                            }
                            .allowsHitTesting(false)
                        }
                        .gesture(MagnifyGesture().onChanged { value in
                            let base = zoomAtStart ?? pixelsPerSecond
                            zoomAtStart = base
                            pixelsPerSecond = min(Metric.ppsMax, max(Metric.ppsMin, base * value.magnification))
                        }.onEnded { _ in zoomAtStart = nil })
                        if showsEmptyState { emptyState }
                    }
                }
            }
            .background(Token.surface)
            .onChange(of: playhead) { _, seconds in follow(seconds, viewport: proxy.size.width - Metric.keysW) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Piano roll")
            .accessibilityValue("\(notes.count) notes")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Metric.sp4) {
            Image(systemName: "waveform.badge.plus").font(.largeTitle).foregroundStyle(Native.fgSecondary)
            Text("Ready to Transcribe").font(.title2.bold())
            Text("Drag the handles to transcribe only a slice, pick a model, then press Transcribe. Notes appear here as the model works.")
                .multilineTextAlignment(.center).foregroundStyle(Native.fgSecondary)
            Text("↩").foregroundStyle(Native.muted)
        }
        .padding(Metric.sp8)
        .frame(maxWidth: Metric.sheetW)
        .background(Token.surfaceRaised.opacity(0.92), in: RoundedRectangle(cornerRadius: Metric.rPanel))
        .overlay(RoundedRectangle(cornerRadius: Metric.rPanel).strokeBorder(Token.border))
        .accessibilityElement(children: .combine)
    }

    private func follow(_ seconds: Double?, viewport: CGFloat) {
        guard follows, let seconds,
              let target = PlaybackEngine.followOffset(playheadX: CGFloat(seconds) * pixelsPerSecond, offsetX: offset.x, viewport: viewport)
        else { return }
        scroll.scrollTo(point: CGPoint(x: target, y: offset.y))
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, _ layout: PianoRollLayout, xOffset: CGFloat, yOffset: CGFloat) {
        var context = context
        context.translateBy(x: 0, y: -yOffset)
        let top = yOffset, bottom = yOffset + size.height
        RollDrawing.grid(context, size, layout, pitches: pitches, top: top, bottom: bottom, grid: grid)
        let visible = layout.visibleNotes(notes, from: layout.seconds(atX: 0), to: layout.seconds(atX: size.width))
        for note in visible where !hidden.contains(note.instrument) && pitches.contains(note.pitch) {
            let colour = neutralColour ? InstrumentColor.color(forFamily: "all")
                : note.isDrum ? DrumKit.piece(forPitch: note.pitch).colour : InstrumentColor.color(for: note.instrument)
            RollDrawing.note(context, rect: layout.rect(for: note), color: colour)
        }
        if finalizedThrough > 0 { RollDrawing.line(context, x: layout.x(seconds: finalizedThrough), top: top, bottom: bottom, color: Native.fgSecondary) }
        if let playhead { RollDrawing.line(context, x: layout.x(seconds: playhead), top: top, bottom: bottom, color: Token.playhead) }
    }
}
