import CoreGraphics
import Testing
@testable import SillyMIDITools

struct PianoRollLayoutTests {
    private func note(_ onset: Double, _ offset: Double, _ pitch: Int) -> NoteEvent {
        NoteEvent(onset: onset, offset: offset, pitch: pitch, program: 0, isDrum: false, instrument: "acoustic_piano", velocity: nil, pitchBends: nil)
    }

    @Test func mapsTimeToX() {
        let layout = PianoRollLayout(pixelsPerSecond: 100, xOrigin: 200)
        #expect(layout.x(seconds: 2) == 400)
        #expect(layout.seconds(atX: 400) == 2)
    }

    @Test func mapsPitchToY() {
        let layout = PianoRollLayout(laneHeight: 8, topPitch: 127)
        #expect(layout.y(pitch: 60) == 536)
    }

    @Test func rectSpansTheNoteDuration() {
        let layout = PianoRollLayout(pixelsPerSecond: 100, xOrigin: 0, laneHeight: 8)
        let r = layout.rect(for: note(1, 1.5, 60))
        #expect(r.minX == 100)
        #expect(r.width == 50)
    }

    @Test func visibleRangeReturnsOnlyOverlappingNotes() {
        let layout = PianoRollLayout()
        let notes = [note(0, 1, 60), note(4, 5, 62), note(9, 10, 64)]
        #expect(layout.visibleNotes(notes, from: 3.5, to: 6).map(\.pitch) == [62])
    }

    @Test func rulerLinesFollowEachMeter() {
        let sixEight = RollDrawing.gridLines(grid: MIDIGrid(bpm: 120, numerator: 6, denominator: 8), from: 0, to: 3)
        #expect(sixEight.count == 13)
        for (index, line) in sixEight.enumerated() {
            #expect(abs(line.seconds - Double(index) * 0.25) < 1e-9)
            #expect(line.isBar == (index % 6 == 0))
        }
        #expect(sixEight.compactMap(\.barNumber) == [1, 2, 3])

        let threeFour = RollDrawing.gridLines(grid: MIDIGrid(bpm: 90, numerator: 3, denominator: 4), from: 0, to: 3)
        #expect(threeFour.count == 5)
        for (index, line) in threeFour.enumerated() {
            #expect(abs(line.seconds - Double(index) * 2 / 3) < 1e-9)
            #expect(line.isBar == (index % 3 == 0))
        }
        #expect(threeFour.filter(\.isBar).map(\.seconds) == [0, 2])
        #expect(threeFour.compactMap(\.barNumber) == [1, 2])

        let fourFour = RollDrawing.gridLines(grid: .standard, from: 0, to: 3)
        #expect(fourFour.count == 7)
        for (index, line) in fourFour.enumerated() {
            #expect(line.seconds == Double(index) * 0.5)
            #expect(line.isBar == (index % 4 == 0))
        }
        #expect(fourFour.filter(\.isBar).map(\.seconds) == [0, 2])
        #expect(fourFour.compactMap(\.barNumber) == [1, 2])
    }

    @Test func meterChangeKeepsContinuousBarNumbersAndClampsNegativeTime() {
        let grid = MIDIGrid(bpm: 120, meters: [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                                MeterChange(bar: 4, numerator: 3, denominator: 4)])
        let lines = RollDrawing.gridLines(grid: grid, from: 0, to: 10)
        #expect(lines.count == 21)
        for (index, line) in lines.enumerated() {
            #expect(line.seconds == Double(index) * 0.5)
        }
        let bars = lines.filter(\.isBar)
        #expect(bars.map(\.seconds) == [0, 2, 4, 6, 8, 9.5])
        #expect(bars.compactMap(\.barNumber) == [1, 2, 3, 4, 5, 6])

        let scrolled = RollDrawing.gridLines(grid: grid, from: 8.2, to: 10)
        #expect(scrolled.map(\.seconds) == [8.5, 9, 9.5, 10])
        #expect(scrolled.compactMap(\.barNumber) == [6])
        #expect(scrolled.allSatisfy { $0.seconds >= 8.2 })

        let beforeZero = RollDrawing.gridLines(grid: grid, from: -2, to: 1)
        #expect(beforeZero.map(\.seconds) == [0, 0.5, 1])
        #expect(beforeZero.allSatisfy { $0.seconds >= 0 })
        #expect(beforeZero.compactMap(\.barNumber) == [1])
    }
}
