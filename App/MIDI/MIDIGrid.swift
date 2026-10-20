import Foundation

struct MeterChange: Equatable, Sendable {
    let bar: Int
    let numerator: Int
    let denominator: Int

    var denominatorPower: Int { denominator.trailingZeroBitCount }
}

struct MIDIGrid: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let meter: MeterChange
        let startSeconds: Double
        let secondsPerQuarter: Double

        var bar: Int { meter.bar }
        var numerator: Int { meter.numerator }
        var denominator: Int { meter.denominator }
        var beatsPerBar: Int { numerator }
        var secondsPerBeat: Double { secondsPerQuarter * 4 / Double(denominator) }
        var secondsPerBar: Double { Double(beatsPerBar) * secondsPerBeat }
    }

    let bpm: Double
    let meters: [MeterChange]

    static let standard = MIDIGrid(bpm: 120, numerator: 4, denominator: 4)

    init(bpm: Double, numerator: Int, denominator: Int) {
        self.init(bpm: bpm, meters: [MeterChange(bar: 0, numerator: numerator, denominator: denominator)])
    }

    init(bpm: Double, meters: [MeterChange]) {
        self.bpm = (min(300, max(20, bpm.isFinite ? bpm : 120)) * 100).rounded() / 100
        var byBar: [Int: MeterChange] = [:]
        for (index, change) in meters.enumerated() {
            let bar = index == 0 ? 0 : max(0, change.bar)
            byBar[bar] = MeterChange(bar: bar, numerator: min(32, max(1, change.numerator)),
                                     denominator: [1, 2, 4, 8, 16, 32].contains(change.denominator) ? change.denominator : 4)
        }
        if byBar[0] == nil { byBar[0] = MeterChange(bar: 0, numerator: 4, denominator: 4) }
        self.meters = byBar.values.sorted { $0.bar < $1.bar }.prefix(256).map { $0 }
    }

    var secondsPerQuarter: Double { 60 / bpm }
    var secondsPerBeat: Double { secondsPerQuarter * 4 / Double(meters[0].denominator) }
    var beatsPerBar: Int { meters[0].numerator }
    var secondsPerBar: Double { Double(beatsPerBar) * secondsPerBeat }
    var hasMeterChanges: Bool { meters.count > 1 }

    var title: String {
        let count = meters.count - 1
        let first = meters[0]
        let base = "\(bpm.formatted(.number.precision(.fractionLength(0...2)))) BPM · \(first.numerator)/\(first.denominator)"
        return count == 0 ? base : "\(base) · \(count) meter \(count == 1 ? "change" : "changes")"
    }

    func segment(atSeconds seconds: Double) -> Segment {
        let time = seconds.isFinite ? max(0, seconds) : 0
        var current = Segment(meter: meters[0], startSeconds: 0, secondsPerQuarter: secondsPerQuarter)
        for meter in meters.dropFirst() {
            let start = current.startSeconds + Double(meter.bar - current.bar) * current.secondsPerBar
            if time < start { break }
            current = Segment(meter: meter, startSeconds: start, secondsPerQuarter: secondsPerQuarter)
        }
        return current
    }

    func seconds(ofBar bar: Int) -> Double {
        let target = max(0, bar)
        var current = Segment(meter: meters[0], startSeconds: 0, secondsPerQuarter: secondsPerQuarter)
        for meter in meters.dropFirst() where meter.bar <= target {
            current = Segment(meter: meter, startSeconds: current.startSeconds + Double(meter.bar - current.bar) * current.secondsPerBar,
                              secondsPerQuarter: secondsPerQuarter)
        }
        return current.startSeconds + Double(target - current.bar) * current.secondsPerBar
    }

    func barBeat(atSeconds seconds: Double) -> (bar: Int, beat: Int) {
        let time = seconds.isFinite ? max(0, seconds) : 0
        let current = segment(atSeconds: time)
        let elapsedBeats = max(0, Int(((time - current.startSeconds) / current.secondsPerBeat).rounded(.down)))
        return (current.bar + elapsedBeats / current.beatsPerBar + 1, elapsedBeats % current.beatsPerBar + 1)
    }

    var timeSignatureEvents: [(tick: Int, numerator: Int, denominatorPower: Int)] {
        var ticks = 0
        var previous = meters[0]
        return meters.map { meter in
            ticks += (meter.bar - previous.bar) * previous.numerator * (1920 / previous.denominator)
            previous = meter
            return (ticks, meter.numerator, meter.denominatorPower)
        }
    }
}
