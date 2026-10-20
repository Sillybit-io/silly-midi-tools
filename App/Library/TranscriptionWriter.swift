import Foundation
import Observation
import CryptoKit

enum TranscriptionWriterError: LocalizedError, Equatable {
    case noFolder
    case cannotWrite(file: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noFolder: "Choose a working folder first."
        case .cannotWrite(let file, let reason): "Couldn\u{2019}t save \u{201C}\(file)\u{201D} in the MIDI folder. \(reason)"
        }
    }
}

/// Saves a finished or cancelled transcription as a new version of its audio, in `MIDI/{audio name} - {model ID}.mid`.
/// The file remembers its source, model and version. A finished result is never replaced; only a cancelled run's partial
/// file is, by a later run of the same audio and model. A file the user has edited is never touched.
@MainActor @Observable
final class TranscriptionWriter {
    /// What the writer needs to know about a run, taken when the run starts.
    struct Run: Sendable {
        var source: URL
        var sourceID: String
        var title: String
        var modelID: String?
        var notice: String?
        var slice: AudioSlice
        var grid: MIDIGrid = .standard
    }

    enum Status: Equatable {
        case idle
        case saved(URL, version: Int, partial: Bool)
        /// A cancelled run left an earlier complete result alone. Its version is nil when it was saved before versions existed.
        case keptPrevious(URL, version: Int?)
        case empty
        case failed(String)
    }

    enum Outcome: Equatable {
        case saved(URL, version: Int)
        case kept(URL, version: Int?)
    }

    private(set) var status: Status = .idle
    private(set) var notice: String?
    enum RegridResult: Equatable { case updated, notUpdated }
    private struct SavedRun {
        let url: URL
        let version: Int
        let partial: Bool
        let notes: [NoteEvent]
        var run: Run
        var digest: SHA256.Digest
    }
    @ObservationIgnored private var lastSaved: SavedRun?
    @ObservationIgnored private var pending: (notes: [NoteEvent], run: Run, partial: Bool)?
    @ObservationIgnored private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Identifies the audio a file came from without its path, which would name the user's folders and account: the id of
    /// the bookmarked reference that points at it, or else its file name in the Audio folder.
    nonisolated static func sourceIdentifier(for url: URL, references: [AudioReference]) -> String {
        if let reference = references.first(where: { $0.lastPath == url.path }) {
            return MIDIProvenance.referencePrefix + reference.id.uuidString
        }
        return MIDIProvenance.audioPrefix + url.lastPathComponent
    }

    /// Call once when a run reaches a terminal state. Streaming and failed runs write nothing.
    func finish(_ state: TranscriptionSession.State, notes: [NoteEvent], run: Run, folder: URL?) {
        switch state {
        case .done: save(notes, run: run, partial: false, folder: folder)
        case .cancelled: save(notes, run: run, partial: true, folder: folder)
        case .idle, .loading, .running, .refining, .failed: break
        }
    }

    /// Tries the last save again, for example after the folder was made writable.
    func retry(folder: URL?) {
        guard let pending else { return }
        save(pending.notes, run: pending.run, partial: pending.partial, folder: folder)
    }

    /// Keeps a failed first save in step with user edits without changing its captured slice.
    func updatePendingGrid(_ grid: MIDIGrid) {
        guard case .failed = status, var pending else { return }
        pending.run.grid = grid
        self.pending = pending
    }

    func discardPending() {
        guard case .failed = status else { return }
        pending = nil
        status = .idle
    }

    @discardableResult
    func regrid(to grid: MIDIGrid) -> RegridResult {
        let changed = "The saved file was changed outside the app, so it was left as it is."
        guard case .saved(let url, let version, let partial) = status,
              var saved = lastSaved, saved.url == url, saved.version == version, saved.partial == partial else {
            notice = "There is no current saved result to update."
            return .notUpdated
        }
        guard let original = try? Data(contentsOf: url), SHA256.hash(data: original) == saved.digest,
              let provenance = try? MIDIImporter.decode(original).provenance,
              provenance.source == saved.run.sourceID, provenance.modelID == saved.run.modelID,
              provenance.version == version, provenance.sourceName == saved.run.title,
              provenance.partial == partial, !provenance.edited else {
            notice = changed
            return .notUpdated
        }
        var updatedRun = saved.run
        updatedRun.grid = grid
        let staging = url.deletingLastPathComponent().appending(path: ".regrid-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            var options = Self.options(for: updatedRun, version: version, partial: partial)
            options.grid = grid
            let data = try MIDIBuilder.build(notes: saved.notes, options: options)
            try data.write(to: staging)
            // Check again after staging, just before replacement; an external edit must win.
            guard let current = try? Data(contentsOf: url), SHA256.hash(data: current) == saved.digest else {
                notice = changed
                return .notUpdated
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: staging)
            saved.run = updatedRun
            saved.digest = SHA256.hash(data: data)
            lastSaved = saved
            notice = nil
            return .updated
        } catch {
            notice = "The saved file could not be updated. It was left as it is."
            return .notUpdated
        }
    }

    func reset() {
        status = .idle
        pending = nil
        lastSaved = nil
        notice = nil
    }

    private func save(_ notes: [NoteEvent], run: Run, partial: Bool, folder: URL?) {
        guard !notes.isEmpty else {
            status = .empty
            pending = nil
            return
        }
        pending = (notes, run, partial)
        guard let folder else {
            status = .failed(TranscriptionWriterError.noFolder.localizedDescription)
            return
        }
        do {
            let result = try Self.writeWithDigest(notes, run: run, partial: partial, in: folder, fileManager: fileManager)
            switch result.outcome {
            case .saved(let url, let version):
                status = .saved(url, version: version, partial: partial)
                if let digest = result.digest { lastSaved = SavedRun(url: url, version: version, partial: partial, notes: notes, run: run, digest: digest) }
            case .kept(let url, let version): status = .keptPrevious(url, version: version)
            }
            pending = nil
            notice = nil
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The MIDI files in `folder` whose own metadata says they were made from `sourceID`, in name order.
    nonisolated static func linkedOutputs(sourceID: String, in folder: URL, fileManager: FileManager = .default) -> [(url: URL, provenance: MIDIProvenance)] {
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { ["mid", "midi"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let provenance = MIDIImporter.info(at: url)?.provenance, provenance.source == sourceID else { return nil }
                return (url, provenance)
            }
    }

    /// `{audio name} - {model ID}`. The ID keeps the name plain and stable; the app shows the model's own name instead.
    nonisolated static func baseName(title: String, modelID: String?) -> String {
        modelID.map { "\(title) - \($0)" } ?? title
    }

    /// Whether `name` is one the writer gives, `{base}` or `{base} 2` and on, either today's or the plain
    /// `{audio name}` used before versions. Anything else was renamed by the user.
    nonisolated static func isDefaultName(_ name: String, title: String, modelID: String?) -> Bool {
        let bases = Set([baseName(title: title, modelID: modelID), title])
        return bases.contains { base in
            if name == base { return true }
            guard name.hasPrefix("\(base) "), let number = Int(name.dropFirst(base.count + 1)) else { return false }
            return number >= 2
        }
    }

    /// One more than any version of the source so far. Files from before versions count too, so the numbers the library
    /// gives them stay free.
    nonisolated static func nextVersion(after linked: [(url: URL, provenance: MIDIProvenance)]) -> Int {
        max(linked.compactMap(\.provenance.version).max() ?? 0, linked.count) + 1
    }

    /// Writes the notes as a new version of the source, or over the unfinished partial file of the same model, which keeps
    /// its version. A cancelled run leaves a finished result of the same model in place and writes nothing.
    /// A finished result, a file with hand edits, and one that isn't recognisably this source's are never touched.
    nonisolated static func write(_ notes: [NoteEvent], run: Run, partial: Bool, in folder: URL, fileManager: FileManager = .default) throws -> Outcome {
        try writeWithDigest(notes, run: run, partial: partial, in: folder, fileManager: fileManager).outcome
    }

    nonisolated private static func options(for run: Run, version: Int, partial: Bool) -> MIDIExportOptions {
        var options = MIDIExportOptions()
        options.title = run.title
        options.sliceStart = run.slice.start
        options.sliceLength = run.slice.span
        options.relativeTimeline = run.slice.relativeTimeline
        options.grid = run.grid
        options.copyright = run.notice
        options.provenance = MIDIProvenance(source: run.sourceID, sourceName: run.title, modelID: run.modelID, version: version,
                                            edited: false, partial: partial)
        return options
    }

    nonisolated private static func writeWithDigest(_ notes: [NoteEvent], run: Run, partial: Bool, in folder: URL,
                                                    fileManager: FileManager) throws -> (outcome: Outcome, digest: SHA256.Digest?) {
        let linked = linkedOutputs(sourceID: run.sourceID, in: folder, fileManager: fileManager)
        let sameModel = linked.filter { $0.provenance.modelID == run.modelID && !$0.provenance.edited }
        if partial, let complete = sameModel.first(where: { !$0.provenance.partial }) {
            return (.kept(complete.url, version: complete.provenance.version), nil)
        }
        let unfinished = sameModel.first { $0.provenance.partial }
        let destination = unfinished?.url
            ?? LibraryNaming.uniqueURL(base: baseName(title: run.title, modelID: run.modelID), ext: "mid", in: folder, fileManager: fileManager)
        let version = unfinished?.provenance.version ?? nextVersion(after: linked)
        let name = destination.lastPathComponent

        let options = options(for: run, version: version, partial: partial)

        let staging = folder.appending(path: ".save-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            let data = try MIDIBuilder.build(notes: notes, options: options)
            try data.write(to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            return (.saved(destination, version: version), SHA256.hash(data: data))
        } catch {
            try? fileManager.removeItem(at: staging)
            throw TranscriptionWriterError.cannotWrite(file: name, reason: reason(for: error))
        }
    }

    nonisolated static func reason(for error: Error) -> String {
        switch (error as? CocoaError)?.code {
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly: "The folder isn\u{2019}t writable."
        case .fileWriteOutOfSpace: "The disk is full."
        default: "The file couldn\u{2019}t be written."
        }
    }
}
