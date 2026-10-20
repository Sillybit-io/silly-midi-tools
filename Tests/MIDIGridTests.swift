import Foundation
import Testing
@testable import SillyMIDITools

struct MIDIGridTests {
    @Test func quarterBeatAndBarLengths() {
        let threeFour = MIDIGrid(bpm: 90, numerator: 3, denominator: 4)
        #expect(abs(threeFour.secondsPerQuarter - 2.0 / 3) < 1e-9)
        #expect(abs(threeFour.secondsPerBeat - 2.0 / 3) < 1e-9)
        #expect(threeFour.beatsPerBar == 3)
        #expect(threeFour.secondsPerBar == 2)

        let sixEight = MIDIGrid(bpm: 120, numerator: 6, denominator: 8)
        #expect(sixEight.secondsPerBeat == 0.25)
        #expect(sixEight.beatsPerBar == 6)
        #expect(sixEight.secondsPerBar == 1.5)
        #expect(sixEight.meters[0].denominatorPower == 3)
        #expect(threeFour.meters[0].denominatorPower == 2)
    }

    @Test func invalidValuesAreClampedAndChangesNormalized() {
        #expect(MIDIGrid(bpm: 999, numerator: 40, denominator: 5) == MIDIGrid(bpm: 300, numerator: 32, denominator: 4))
        #expect(MIDIGrid(bpm: 0, numerator: 0, denominator: 4).bpm == 20)
        #expect(MIDIGrid(bpm: 95.678, numerator: 3, denominator: 4).bpm == 95.68)
        let duplicate = MIDIGrid(bpm: 120, meters: [MeterChange(bar: 7, numerator: 4, denominator: 4),
                                                    MeterChange(bar: 0, numerator: 3, denominator: 8)])
        #expect(duplicate.meters == [MeterChange(bar: 0, numerator: 3, denominator: 8)])
        let many = MIDIGrid(bpm: 120, meters: (0..<300).reversed().map { MeterChange(bar: $0, numerator: 4, denominator: 4) })
        #expect(many.meters.count == 256)
        #expect(many.meters[0].bar == 0)
    }

    @Test func meterMapWalksWholeBars() {
        let first = MeterChange(bar: 0, numerator: 4, denominator: 4)
        let second = MeterChange(bar: 4, numerator: 3, denominator: 4)
        let grid = MIDIGrid(bpm: 120, meters: [first, second])
        #expect(grid.seconds(ofBar: 5) == 9.5)
        let position = grid.barBeat(atSeconds: 9.5)
        #expect(position.bar == 6)
        #expect(position.beat == 1)
        #expect(grid.segment(atSeconds: 7.9).meter == first)
        #expect(grid.segment(atSeconds: 8).meter == second)
        #expect(grid.segment(atSeconds: 8).secondsPerBar == 1.5)
        #expect(grid.timeSignatureEvents.map(\.tick) == [0, 7680])
        #expect(grid.timeSignatureEvents.map(\.numerator) == [4, 3])
        #expect(grid.timeSignatureEvents.map(\.denominatorPower) == [2, 2])
        #expect(grid.hasMeterChanges)
        #expect(grid.title == "120 BPM · 4/4 · 1 meter change")
        #expect(MIDIGrid(bpm: 95, numerator: 3, denominator: 4).title == "95 BPM · 3/4")
    }
}
