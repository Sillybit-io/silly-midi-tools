import SwiftUI

/// Play/Pause, Stop, the position as time and bar.beat, and Loop. The Audio screen and the MIDI editor share it,
/// and the Controls menu drives the same `PlaybackEngine`, so the buttons and the menu can't disagree.
struct TransportView: View {
    @Bindable var playback: PlaybackEngine
    let toggle: () -> Void

    var body: some View {
        // Each button already fills a 36-pt toolbar cell, so any spacing on top spreads them wider than a system group.
        HStack(spacing: 0) {
            Button(action: toggle) {
                Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .help("Stop")
                .accessibilityLabel("Stop")
            Toggle(isOn: $playback.loops) { Label("Loop", systemImage: "repeat") }
                .toggleStyle(.button)
                .help("Loop (L)")
                .accessibilityLabel("Loop")
                .accessibilityValue(playback.loops ? "On" : "Off")
            Toggle(isOn: $playback.click) { Label("Click", systemImage: "metronome") }
                .toggleStyle(.button)
                .help("Click (C)")
                .accessibilityLabel("Click")
                .accessibilityValue(playback.click ? "On" : "Off")
            // The hidden text is the widest the readout gets for this audio, so the toolbar never moves while playing.
            // Any room it leaves goes before the readout, which keeps the inset after it as wide as the one before Play.
            ZStack(alignment: .trailing) {
                Text(Self.readout(playback.duration, grid: playback.grid)).hidden().accessibilityHidden(true)
                Text(Self.readout(playback.position, grid: playback.grid))
            }
            .font(.body.monospacedDigit()).foregroundStyle(Native.fgSecondary).lineLimit(1)
            .padding(.leading, Metric.sp2).padding(.trailing, Metric.sp5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
                .accessibilityValue("\(PlaybackEngine.timeText(seconds: playback.position)), bar \(PlaybackEngine.barBeat(seconds: playback.position, grid: playback.grid).bar) beat \(PlaybackEngine.barBeat(seconds: playback.position, grid: playback.grid).beat)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
    }

    private static func readout(_ seconds: Double, grid: MIDIGrid) -> String {
        "\(PlaybackEngine.timeText(seconds: seconds)) \u{00B7} \(PlaybackEngine.barBeatText(seconds: seconds, grid: grid))"
    }
}
