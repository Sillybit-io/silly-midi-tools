import SwiftUI

struct TempoFieldsView: View {
    @Binding var grid: MIDIGrid
    let showsMeterChanges: Bool

    private let denominators = [1, 2, 4, 8, 16, 32]

    var body: some View {
        LabeledContent("Tempo") {
            TextField("BPM", value: bpm, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 72)
                .accessibilityLabel("Tempo in BPM")
        }
        meterControls(at: 0)
        if showsMeterChanges {
            ForEach(grid.meters.dropFirst(), id: \.bar) { change in
                HStack {
                    TextField("From bar", value: bar(for: change.bar), format: .number)
                        .frame(width: 64)
                        .accessibilityLabel("Meter change from bar \(change.bar + 1)")
                    meterControls(at: change.bar)
                    Button("Remove meter change", systemImage: "minus.circle") { remove(at: change.bar) }
                        .accessibilityLabel("Remove meter change from bar \(change.bar + 1)")
                }
            }
            Button("Add meter change") {
                let last = grid.meters[grid.meters.count - 1]
                grid = MIDIGrid(bpm: grid.bpm, meters: grid.meters + [MeterChange(bar: last.bar + min(8, Int.max - last.bar), numerator: last.numerator,
                                                                                 denominator: last.denominator)])
            }
            .disabled(grid.meters.count >= 256 || grid.meters.last?.bar == Int.max)
            .accessibilityLabel("Add meter change")
        }
    }

    private var bpm: Binding<Double> {
        Binding(get: { grid.bpm }, set: { grid = MIDIGrid(bpm: $0, meters: grid.meters) })
    }

    private func meterControls(at bar: Int) -> some View {
        let change = grid.meters.first { $0.bar == bar } ?? grid.meters[0]
        return HStack {
            Stepper(value: numerator(for: bar), in: 1...32) {
                Text("\(change.numerator) beats")
            }
            .accessibilityLabel(bar == 0 ? "Time signature numerator" : "Numerator from bar \(bar + 1)")
            Picker("Beat note", selection: denominator(for: bar)) {
                ForEach(denominators, id: \.self) { Text("\($0)").tag($0) }
            }
            .accessibilityLabel(bar == 0 ? "Time signature denominator" : "Denominator from bar \(bar + 1)")
        }
    }

    private func numerator(for bar: Int) -> Binding<Int> {
        Binding(get: { grid.meters.first { $0.bar == bar }?.numerator ?? 4 }, set: { value in
            replace(at: bar) { MeterChange(bar: bar, numerator: value, denominator: $0.denominator) }
        })
    }

    private func denominator(for bar: Int) -> Binding<Int> {
        Binding(get: { grid.meters.first { $0.bar == bar }?.denominator ?? 4 }, set: { value in
            replace(at: bar) { MeterChange(bar: bar, numerator: $0.numerator, denominator: value) }
        })
    }

    private func bar(for bar: Int) -> Binding<Int> {
        Binding(get: { (grid.meters.first { $0.bar == bar }?.bar ?? bar) + 1 }, set: { value in
            let index = grid.meters.firstIndex { $0.bar == bar } ?? 1
            let earliest = grid.meters[index - 1].bar + 1
            let latest = index + 1 < grid.meters.count ? grid.meters[index + 1].bar - 1 : Int.max
            replace(at: bar) { MeterChange(bar: min(max(value <= 1 ? 0 : value - 1, earliest), max(earliest, latest)),
                                                  numerator: $0.numerator, denominator: $0.denominator) }
        })
    }

    private func replace(at bar: Int, with edit: (MeterChange) -> MeterChange) {
        guard let index = grid.meters.firstIndex(where: { $0.bar == bar }) else { return }
        var meters = grid.meters
        meters[index] = edit(meters[index])
        grid = MIDIGrid(bpm: grid.bpm, meters: meters)
    }

    private func remove(at bar: Int) {
        grid = MIDIGrid(bpm: grid.bpm, meters: grid.meters.filter { $0.bar != bar })
    }
}
