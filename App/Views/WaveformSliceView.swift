import SwiftUI

extension AudioSlice {
    enum Edge: Hashable { case start, end }

    /// Arrow keys move an edge this far; with Shift, `shiftKeyStep`.
    static let keyStep = 0.1
    static let shiftKeyStep = 1.0

    /// Moves one edge by `delta` seconds. It stops at the other edge and at the ends of the audio.
    mutating func move(_ edge: Edge, by delta: Double) {
        switch edge {
        case .start: setStart(start + delta)
        case .end: setEnd(end + delta)
        }
    }

    /// Takes an edge as far as it can go: to the start of the audio or to the other edge for `.low`, the reverse for `.high`.
    mutating func jump(_ edge: Edge, toLowerLimit low: Bool) {
        switch (edge, low) {
        case (.start, true): setStart(0)
        case (.start, false): setStart(duration)
        case (.end, true): setEnd(0)
        case (.end, false): setEnd(duration)
        }
    }

    func position(of edge: Edge) -> Double {
        edge == .start ? start : end
    }
}

struct WaveformSliceView: View {
    @Bindable var model: DocumentModel
    var grid: MIDIGrid? = nil
    var beats: [(time: Double, isDownbeat: Bool)] = []
    /// Called with a time inside the slice when the track is clicked without dragging.
    var onSeek: (Double) -> Void = { _ in }
    @FocusState private var focusedEdge: AudioSlice.Edge?
    @State private var drag: TrackDrag?

    /// A drag on the track: it moves the slice when it starts inside it, otherwise it selects a new one.
    private struct TrackDrag {
        var anchor: Double
        var movesSlice: Bool
        var original: AudioSlice
        var moved = false
    }

    nonisolated static func selectionText(_ slice: AudioSlice) -> String {
        String(format: "Selected %.1f s of %.1f s", slice.span, slice.duration)
    }

    /// Ruler tick spacing in seconds: the smallest round step that keeps the `m:ss` labels apart at this width.
    nonisolated static func tickStep(duration: Double, width: CGFloat) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]
        let minimumGap = Double(Metric.sp10)
        let perSecond = Double(max(width, 1)) / max(duration, AudioSlice.step)
        return steps.first { $0 * perSecond >= minimumGap } ?? steps[steps.count - 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.sp4) {
            ViewThatFits(in: .horizontal) {
                header(showsTitle: true)
                header(showsTitle: false)
            }
            VStack(spacing: 0) {
                Canvas { context, size in drawRuler(context, size) }
                    .frame(height: Metric.sp7)
                    .accessibilityHidden(true)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let duration = max(model.slice.duration, AudioSlice.step)
                    let x0 = width * model.slice.start / duration
                    let x1 = width * model.slice.end / duration
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Token.regionFill).frame(width: max(0, x1 - x0)).offset(x: x0)
                        Canvas { context, size in drawWave(context, size, from: x0, to: x1) }
                            .contentShape(Rectangle())
                            .gesture(trackGesture(width: width, duration: duration))
                        Rectangle().fill(Token.regionDim).frame(width: x0).allowsHitTesting(false)
                        Rectangle().fill(Token.regionDim).frame(width: max(0, width - x1)).offset(x: x1).allowsHitTesting(false)
                        handle(.start, at: x0) { model.slice.setStart($0 / width * duration) }
                        handle(.end, at: x1) { model.slice.setEnd($0 / width * duration) }
                    }
                }
                .frame(height: Metric.overviewH)
            }
            .background(Token.surfaceSunken, in: RoundedRectangle(cornerRadius: Metric.rControl))
            .clipShape(RoundedRectangle(cornerRadius: Metric.rControl))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Waveform")
        }
        .padding(Metric.sp5)
        .background(Token.surfaceRaised, in: RoundedRectangle(cornerRadius: Metric.rPanel))
        .overlay(RoundedRectangle(cornerRadius: Metric.rPanel).strokeBorder(Token.border))
        .padding(.horizontal, Metric.sp6).padding(.top, Metric.sp4)
    }

    /// The title goes first when the column is too narrow for everything on one line.
    private func header(showsTitle: Bool) -> some View {
        HStack(spacing: Metric.sp4) {
            if showsTitle { Text("Waveform").font(.headline) }
            Text(Self.selectionText(model.slice)).monospacedDigit().foregroundStyle(Native.fgSecondary).lineLimit(1)
            Spacer(minLength: Metric.sp4)
            Toggle("Original timeline", isOn: Binding(
                get: { !model.slice.relativeTimeline },
                set: { model.slice.relativeTimeline = !$0 }))
                .toggleStyle(.switch).controlSize(.small).fixedSize()
            Button("Reset") { model.slice.reset() }
        }
    }

    private func drawRuler(_ context: GraphicsContext, _ size: CGSize) {
        let duration = model.slice.duration
        guard duration > 0 else { return }
        let step = Self.tickStep(duration: duration, width: size.width)
        var seconds = 0.0
        while seconds < duration - step * 0.4 {
            let x = size.width * seconds / duration
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: size.height * 0.5))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tick, with: .color(Token.gridBar), lineWidth: Metric.hairline)
            let label = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
            context.draw(Text(label).font(.system(size: TypeScale.micro).monospacedDigit()).foregroundStyle(Native.fgSecondary),
                         at: CGPoint(x: x + Metric.sp2, y: size.height * 0.4), anchor: .leading)
            seconds += step
        }
    }

    private func drawWave(_ context: GraphicsContext, _ size: CGSize, from x0: CGFloat, to x1: CGFloat) {
        let mid = size.height / 2
        let count = max(model.peaks.count, 1)
        for (i, peak) in model.peaks.enumerated() {
            let x = size.width * (CGFloat(i) + 0.5) / CGFloat(count)
            var path = Path()
            path.move(to: CGPoint(x: x, y: mid - CGFloat(peak.max) * mid))
            path.addLine(to: CGPoint(x: x, y: mid - CGFloat(peak.min) * mid))
            context.stroke(path, with: .color(x >= x0 && x <= x1 ? Token.waveSel : Token.wave), lineWidth: Metric.hairline)
        }
        let duration = model.slice.duration
        guard duration > 0 else { return }
        if let grid {
            for line in RollDrawing.gridLines(grid: grid, from: 0, to: model.slice.span) {
                let x = size.width * (model.slice.start + line.seconds) / duration
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(line.isBar ? Token.gridBar : Token.gridBeat),
                               lineWidth: line.isBar ? 1.5 : Metric.hairline)
            }
        }
        for beat in beats where beat.time >= model.slice.start && beat.time <= model.slice.end {
            let x = size.width * beat.time / duration
            var marker = Path()
            marker.addEllipse(in: CGRect(x: x - (beat.isDownbeat ? 3 : 2), y: 2,
                                         width: beat.isDownbeat ? 6 : 4, height: beat.isDownbeat ? 6 : 4))
            context.fill(marker, with: .color(beat.isDownbeat ? Token.accentText : Token.gridBar))
        }
    }

    private func trackGesture(width: CGFloat, duration: Double) -> some Gesture {
        func time(_ x: CGFloat) -> Double { min(max(0, Double(x / max(width, 1)) * duration), duration) }
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let anchor = time(value.startLocation.x)
                var current = drag ?? TrackDrag(anchor: anchor, movesSlice: model.slice.contains(anchor), original: model.slice)
                current.moved = current.moved || abs(value.translation.width) >= Metric.sp2
                if current.moved {
                    var slice = current.original
                    if current.movesSlice {
                        slice.shift(by: time(value.location.x) - anchor)
                    } else {
                        slice.select(from: anchor, to: time(value.location.x))
                    }
                    model.slice = slice
                }
                drag = current
            }
            .onEnded { value in
                if drag?.moved != true {
                    let seconds = time(value.startLocation.x) - model.slice.start
                    onSeek(min(max(0, seconds), model.slice.span))
                }
                drag = nil
            }
    }

    private func title(_ edge: AudioSlice.Edge) -> String {
        edge == .start ? "Slice start" : "Slice end"
    }

    private func handle(_ edge: AudioSlice.Edge, at x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle().fill(Token.handle).frame(width: Metric.sp2)
            .overlay(Rectangle().fill(.clear).frame(width: Metric.sp6).contentShape(Rectangle()))
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                focusedEdge = edge
                onDrag(x + $0.translation.width)
            })
            .focusable()
            .focused($focusedEdge, equals: edge)
            .onKeyPress(phases: [.down, .repeat]) { press in key(press, edge) }
            .accessibilityRepresentation {
                Slider(value: Binding(get: { model.slice.position(of: edge) },
                                      set: { value in adjust(edge) { $0.move(edge, by: value - $0.position(of: edge)) } }),
                       in: 0...max(model.slice.duration, AudioSlice.step), step: AudioSlice.keyStep) { Text(title(edge)) }
                    .accessibilityValue(PlaybackEngine.timeText(seconds: model.slice.position(of: edge)))
                    .accessibilityHint("Left and right arrows move it by a tenth of a second, with Shift by a second. Home and End go to its limits.")
            }
            // Padding rather than `.offset`, so the element's frame (and its focus ring) sit where the handle is drawn.
            .padding(.leading, max(0, x - Metric.sp1))
    }

    private func key(_ press: KeyPress, _ edge: AudioSlice.Edge) -> KeyPress.Result {
        let step = press.modifiers.contains(.shift) ? AudioSlice.shiftKeyStep : AudioSlice.keyStep
        switch press.key {
        case .leftArrow: adjust(edge) { $0.move(edge, by: -step) }
        case .rightArrow: adjust(edge) { $0.move(edge, by: step) }
        case .home: adjust(edge) { $0.jump(edge, toLowerLimit: true) }
        case .end: adjust(edge) { $0.jump(edge, toLowerLimit: false) }
        default: return .ignored
        }
        return .handled
    }

    /// Applies the change, then says where the edge ended up, which may differ from what was asked for.
    private func adjust(_ edge: AudioSlice.Edge, _ change: (inout AudioSlice) -> Void) {
        change(&model.slice)
        AccessibilityNotification.Announcement("\(title(edge)) \(PlaybackEngine.timeText(seconds: model.slice.position(of: edge)))").post()
    }
}
