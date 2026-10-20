# User guide

Everything Silly MIDI Tools does, in detail. For a quick start, see the [README](../README.md).

## First launch

1. Unzip the download by double-clicking it in Finder, or run `ditto -x -k <zip file> .`. Plain `unzip` drops signature data from the bundled Metal libraries. Move `SillyMIDITools.app` to `/Applications`.
2. The app is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch. Clear the quarantine flag once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/SillyMIDITools.app
   ```

   Or open the app, then go to System Settings, Privacy & Security, and choose **Open Anyway**. On recent macOS versions, right-click and Open no longer works for unsigned apps.
3. On first launch the Welcome sheet asks where to keep your files. Press **Continue** and choose a folder, or create one (the suggestion is `Silly MIDI Tools` in your Documents folder). The app is sandboxed, so it can only use a folder you have picked. See [Working folder](#working-folder).
4. Drop an audio file onto the window, or press Command-O. WAV, MP3, FLAC, M4A, AIFF and anything else Core Audio decodes are supported.
5. Choose a model in the inspector on the right (it is open by default; the button at the far right of the toolbar hides it). Basic Pitch is selected for you and works straight away. The other models download on first use (see [Models](MODELS.md)).
6. Press **Transcribe**. The result is saved in your working folder as a MIDI file, and you can open it in the editor.

## Working folder

The app keeps everything in one folder you choose, with two subfolders it creates:

- `Audio/` holds the audio you add.
- `MIDI/` holds every transcription and every edit, saved automatically.

The sidebar lists both folders and updates when files appear or disappear, including changes made in Finder. The folder is remembered across launches with a security-scoped bookmark. If you cancel the folder panel, nothing is chosen and the Welcome sheet stays until you pick a folder.

**Adding audio.** In Settings, General, **When you add audio** decides what happens to a file you open or drop:

- **Copy into the Audio folder** (the default) copies it. The original is not touched.
- **Leave it where it is** keeps a bookmark to the file. If it is later moved or deleted, its sidebar row shows a warning; use the row's context menu, **Relink…**, to point it at the file again, or **Remove from Library**.

**Changing the folder** (Settings, General, **Choose…** or **Reset to Default…**) only changes where the app looks. It does not move or delete any file in the old folder.

## Audio, slices and transcription

- **Audio input.** Drop or open a file and see its waveform with a time ruler. Drag the handles to change the slice, drag across empty waveform to pick a new slice, drag inside the slice to move it, and click to move the playhead. A slice is at least 0.5 s long. Exported notes can keep the original timeline or start at zero.
- **Streaming piano roll.** Notes appear while a MuScriptor run is still going, coloured by instrument. Show or hide instruments with the legend. Cancel keeps the notes found so far.
- **Instruments, device and threads.** For MuScriptor you can restrict the transcription to chosen instruments, pick the compute device (Auto, a GPU, or CPU) and set the thread count.
- **Drums.** ADTOF reads the drums in a full mix (five kit pieces, non-commercial). Onsets and Frames Drums gives eight kit pieces with predicted velocity but was trained on isolated drums, so use it on e-kit recordings, drum stems and loops. Hits are coloured by kit piece, the key column names each lane that has hits, and the legend counts hits per piece. **Separate drums first** (optional) isolates the drums with HT-Demucs before either model listens; it is very slow, many times the audio's length on an Intel Mac, so use it on short slices. The switch is in the inspector's Drums section, which appears when a drum model is picked. The separator is listed under Helpers in Settings, Models, and the first run with the switch on downloads it if it isn't there yet.
- **Hand percussion.** For a darbuka, doumbek, bendir or similar hand drum playing on its own. It finds each stroke and labels it low (doum, written as General MIDI Low Conga) or high (tek or ka, written as Open Hi Conga). It is signal processing built into the app, not a trained model, because no open model for hand drums that may be used commercially exists: there is nothing to download, and the app's own Apache-2.0 licence covers it. It cannot tell tek from ka, which are the same sound played by each hand. The two drum-kit models are not for hand drums: on darbuka recordings they find many of the strokes but label most of them as one tom, not as doum and tek, and both missed an isolated low hit entirely.
- **Note velocity.** The piano and OaF drum models predict velocity themselves. For MuScriptor, ADTOF and Hand percussion, which have none, a toggle (on by default) estimates velocity from the audio's loudness at each onset. Basic Pitch notes use the amplitude it reports.
- **Key and scale detection.** Ranks major, minor, dorian, phrygian, lydian, mixolydian and locrian in all twelve keys, from the transcribed notes, or from the audio file with the Detect from audio button.
- **Switching files during a run.** A transcription keeps going if you open another file. The sidebar row shows **Transcribing…**, and opening that file again brings back its progress or its result. Only one file is transcribed at a time, so Transcribe on another file waits until it ends.

## Versions and auto-save

- **Auto-save and versions.** When a run finishes, or when you cancel one that already found notes, the result is saved as a new version in `MIDI/{audio name} - {model ID}.mid`, for example `song - basic-pitch.mid`. A name that is taken gets a number, as in `song - basic-pitch 2.mid`. The file remembers its source audio, model and version number. It names the audio by its file name, never by the folders it sits in, and the app removes the folder path from files saved by older versions when it opens the working folder. Transcribing again, with the same model or another one, never replaces a finished result, so you can compare models side by side.
- **Cancelled runs.** A cancelled run is saved as a partial version. The next run of the same audio and model finishes that file in place, and it keeps its version number. A cancelled run never replaces a finished result: if the same audio and model already have one, the partial notes are not saved.
- **Your edits are never overwritten.** A file you have edited is left alone, and a file that is not this audio's output is never touched.
- **Versions in the sidebar.** The MIDI section groups the transcriptions of each audio file under the audio's name, oldest first, as Version 1, Version 2 and so on. Each row shows the model's name, the note count, and Edited or Partial when either applies. Audio with one transcription shows a single row, a file you renamed keeps your name, and an imported file is a row of its own. Hover over a row to see its file name. Files saved before versions existed keep their names and are numbered in the order they were created.

## MIDI editor

- **Editing.** Select a `.mid` file in the sidebar. It has Select, Draw and Erase tools, click, Shift-click and box selection, snapped move and resize, a velocity lane, a snap grid (1/4 to 1/32 note, or off), Quantize, transpose, nudge, and Undo and Redo. Notes live between C1 and B6. Each track can be muted, soloed or hidden without changing a note. The inspector lets you type a note's start, length and velocity, rename the file (the name stays unique in the folder), and draw on a new instrument track picked from **Draw on**. With notes selected, the velocity lane only changes those.
- **Save and unsaved changes.** Command-S saves the file in place and marks it as edited. Switching files, closing the window or quitting asks whether to save, discard or cancel. A save that fails keeps your edits and says why. A save refuses to overwrite a file that changed on disk after you opened it.
- **Import.** **Import MIDI…** (Shift-Command-O) copies a Standard MIDI File (type 0 or 1, with the usual ticks-per-beat timing) into `MIDI/` byte for byte. A file that is not valid MIDI, is damaged, or uses SMPTE or type 2 timing is refused and nothing is written. Notes outside C1 to B6 are skipped and counted.

## Playback and export

- **Playback.** Play the notes through the built-in General MIDI sound bank, next to the original audio. Mix between the two with one slider, change the speed from 0.5x to 2x, and loop the slice. Play, Stop and Loop work on both screens, and the position shows time and bar.beat. Space plays and pauses, L toggles Loop, C toggles the click, and clicking the ruler moves the playhead. Settings can make the roll follow the playhead. Playback needs an audio output device.
- **MIDI export.** Type 1 Standard MIDI File with one track per instrument. Drag the **Drag into your DAW** tile in the footer, next to the zoom slider, onto a track in your DAW or into Finder, or use Export (Command-E). Both leave out notes outside C1 to B6 and add the line "Exported from Silly MIDI Tools". The dragged file has no licence notice and no pitch bends. The export sheet can embed the model's licence notice, include Basic Pitch's pitch bends (written for a ±2 semitone bend range), and add the detected key to the file name, for example `Song - Eb minor.mid`.
- **Licences in the app.** The About window lists every third-party component and its licence text.

### Tempo and the click

- **You set the tempo and time signature.** A new recording starts from Settings, General, which holds 120 BPM in 4/4 until you change it. The Audio inspector's **Tempo** section and the MIDI editor's inspector have the same fields: the tempo in quarter notes per minute (20 to 300, two decimals), the beats per bar (1 to 32) and the beat note (1, 2, 4, 8, 16 or 32). A value outside a range is clamped, not refused. The beat note is always your choice; no model decides it. 120 BPM in 6/8 is 0.25 s per eighth note and a 1.5 s bar.
- **Meter changes.** **Add meter change** adds a change eight bars after the last one with the same meter; set the bar it starts at and its own beats and beat note, or remove it. Changes fall on whole bars, each is written to the file as one time-signature event, and the roll, the waveform's bar lines, the bar.beat readout and the click all follow them. Every edit is one undo step: in the editor the file shows Edited until you save, and on the Audio screen Command-Z and Shift-Command-Z undo and redo tempo, meter and **Use** actions.
- **The notes never move.** Changing the tempo or the meter changes the grid, the bars, the click and the file's ticks, not when a note sounds. Notes keep their times in seconds, so they stay in time with the audio whatever the grid says.
- **After a run.** Changing the tempo or meter after a run rewrites that run's saved version in place, with the same version number, only while the file is still exactly what the app wrote. A file you edited, or that a DAW or another app changed, is left alone and the footer says the saved file was not updated. If the first save failed, **Try Saving Again** saves it with the new tempo.
- **Bar 1 is the start of the slice.** If you move the slice start after a run, by hand or with **Use map** or **Start slice at first beat**, the notes no longer line up with the audio: they are hidden, silent and left out of export, and the footer says to transcribe again. The version already saved is not touched, and moving the slice back doesn't bring the old notes back; press **Transcribe Again**. A beat too near the end of the slice can't become bar 1, because the slice stays at least 0.5 s long: the app says so and changes nothing.
- **Click.** The Click button in the transport, Controls, Click, or the C key plays a woodblock on every beat, higher on beat 1 of each bar. It follows the meter changes, runs before any notes exist, and doesn't change how the notes play.
- **Tempo from notes.** After each run on the Audio screen, and after each edit in the editor, the inspector ranks up to three tempos by how well the notes fall on a sixteenth-note grid, and marks half and double time. With fewer than eight separate note onsets, or when nothing fits, it says **No clear pulse**.
- **Tempo from audio.** **Detect from audio** works on the selected slice. With the Beat This! helper downloaded (Settings, Models, Helpers, 82 MB, offered as a download button in the Tempo section) it finds beats and downbeats, draws the beats on the waveform, says whether the tempo is steady or varies, and suggests a tempo and a meter map from the downbeats. Without it, or with **Quick estimate**, a quick estimate of one tempo and its beats comes from the audio's onsets. The detected rate counts pulses in your beat note, so with an eighth-note beat, 120 pulses per minute is offered as 60 quarter-note BPM, and the bar lasts as long as the beats it was measured from. **Meter unclear** means the downbeats don't give a steady count, and no map is offered.
- **Check alignment.** After a run, **Check alignment** says what share of the notes sit on an audio onset and how early or late they are. It needs a result that still matches the slice and at least eight separate note onsets, and says **No clear match** when too few notes land on an onset. It never moves a note.
- **Use is always your decision.** **Use** on a tempo sets the BPM. **Use map** sets the BPM and the meter together and starts the slice at the first downbeat. **Start slice at first beat** moves bar 1 to the first detected beat. Each is one undo step.
- **Import and export.** Import reads the first tempo, rounded to two decimals, and every time signature, rounded to the nearest whole bar; a file with none opens at 120 BPM in 4/4. With the waveform's **Original timeline** switch off (the default), notes start at zero, bar 1 is the start of the slice and the meter changes are counted from there. With it on, the grid starts at the beginning of the recording and the notes sit where they are in it, so the bars match the song from its first second.

## Keyboard shortcuts

Help, **Keyboard Shortcuts** (Command-/) lists them all. The main ones:

| Keys | Action |
| --- | --- |
| Command-O, Shift-Command-O | Open audio, import MIDI |
| Command-S | Save the MIDI file |
| Command-E | Export MIDI |
| Command-1, Command-2 | Audio, MIDI editor |
| Option-Command-I | Show or hide the inspector |
| Command-+, Command-- | Zoom |
| Space, L, C | Play or pause, Loop, Click |
| V, D, E | Select, Draw, Erase (MIDI editor) |
| Up and Down arrows | Transpose by a semitone (Shift: an octave) |
| Left and Right arrows | Nudge by one snap step |
| Option-Left, Option-Right | Previous and next note |
| Q | Quantize the selection, or everything |
| Left and Right on a slice handle | Move it 0.1 s (Shift: 1 s); Home and End go to its limits |

## Troubleshooting

If something goes wrong or the app crashes, turn on **Save debug logs** in Settings, General, Troubleshooting. It takes effect at once, without a relaunch, and stays on until you turn it off.

- Each launch writes one file to `Logs/` in your working folder, for example `Logs/2026-10-06 14.30.12.log`. The newest 10 are kept. **Show Logs in Finder** opens the folder.
- A log starts with the app version, the macOS version and the Mac. Then there is one timestamped line for each thing the app does: opening, dropping and decoding files, each stage of a transcription with the app's memory use, the engine's own output, model downloads, licence checks, playback, and MIDI saves and exports.
- After a crash, the log ends with the reason, for example Swift's `Fatal error: Index out of range` or an uncaught exception, and the stack. The next launch says that the previous session crashed and repeats its last lines.
- macOS still writes its own report to `~/Library/Logs/DiagnosticReports/SillyMIDITools-<date>.ips`. When you report a crash, attach both files.
- Logs name your files and folders. They never contain your Hugging Face token or your audio. Read a log before you post it publicly.

When the switch is off, nothing is written.

## Known limits

- Release builds are Apple silicon only, and are not notarized.
- The piano model handles one instrument; on other music it reports piano notes for whatever it hears.
- OaF Drums was trained on isolated drums and finds little in a full mix; on its synthetic test clip it detects far fewer hits than ADTOF.
- Hand percussion was checked on two clean solo darbuka recordings, where it reads Maksum and Saidi stroke for stroke. It has not been tried on other hand drums, other players or noisy rooms. Two groups of strokes is all it separates, so a djembe's third tone or a darbuka's slap is labelled low or high.
- Velocity estimated for MuScriptor, ADTOF and Hand percussion is relative loudness, not a measurement of how hard a note was played.
- Key detection ranks likely keys; modes that share most of their notes (for example dorian and natural minor) can be close.
- OGG files are not decoded.
- Audio longer than 1 hour can't be opened, because the whole recording is kept in memory. Split a longer file first.
- A file holds one tempo. A song whose tempo changes has to be transcribed in sections, one slice at a time. Importing a file converts its later tempo changes into real time, and a time-signature change in the middle of a bar moves to the nearest bar line.
- Tempo and meter suggestions are readings of the notes and the audio, not facts: half and double time are both valid for most music, and Beat This! can be unsure about the downbeats. Nothing is applied until you press Use.
- Saving from the editor writes notes, velocities and track instruments only. Pitch bends, controllers such as sustain, and lyrics in a file you edit are not kept.
- Importing type 2 and SMPTE-timed MIDI files is not supported.
