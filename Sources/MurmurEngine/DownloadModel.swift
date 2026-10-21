import MurmurIndex
import Foundation

/// `murmur-engine download-model [--to DIR]`: the model files into DIR (default: Murmur's own Models folder), for shells that
/// set Murmur up on first launch (the Mac app downloads them itself, with the same `FileFetcher`). A file already in the
/// Hugging Face cache is copied from there; anything else is downloaded, picking up where an earlier try stopped. Every
/// file is checked (size, SHA-256) before it gets its name, so a file there is a good one.
///
/// JSON lines on stdout:
///   {"event":"file","name":…,"bytes":n,"from":"cache|download"}             a file started
///   {"event":"progress","name":…,"bytes":n,"total":n,"all_bytes":n,"all_total":n}   at most 5 times a second
///   {"event":"waiting"}                                                     no network yet: it waits for one
///   {"event":"verifying","name":…}                                          the SHA-256 check (about a second)
///   {"event":"retry","message":…,"seconds":n}                               a failure it will try again after
///   {"event":"done","folder":…} | {"event":"error","message":…}             the end (exit 0 | 1)
func downloadModel(_ args: Arguments) throws -> Int32 {
    let folder = args.values["--to"].map(Arguments.folderURL) ?? ModelFiles.installed
    return try download(ModelFiles.missing(in: folder), total: ModelFiles.totalBytes, into: folder, useCache: true)
}

/// `murmur-engine download-speech-model [--model english|multilingual] [--to DIR]`: the speech model the Windows and
/// Linux app dictates with (`SpeechModelFiles`), into DIR (default: Murmur's Speech Models/<model>). The same events.
func downloadSpeechModel(_ args: Arguments) throws -> Int32 {
    let name = args.values["--model"] ?? SpeechModelFiles.english.rawValue
    guard let model = SpeechModelFiles(rawValue: name) else {
        throw CLIError("no speech model called \(name): english or multilingual")
    }
    let folder = args.values["--to"].map(Arguments.folderURL) ?? model.installed
    return try download(model.missing(in: folder), total: model.totalBytes, into: folder, useCache: false)
}

/// Downloads `missing` into `folder` (each file checked before it gets its name), saying how it goes as JSON lines.
/// `useCache`: copy a file from the Hugging Face cache when it's there (the embedding model's pinned snapshot).
private func download(_ missing: [ModelFiles.File], total: Int64, into folder: URL, useCache: Bool) throws -> Int32 {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var done = total - missing.reduce(0) { $0 + $1.bytes }
    for file in missing {
        let final = folder.appendingPathComponent(file.name)
        if useCache, let cached = ModelFiles.cachedCopy(of: file), (try? ModelFiles.sha256(of: cached)) == file.sha256 {
            emit(["event": "file", "name": file.name, "bytes": file.bytes, "from": "cache"])
            let partial = folder.appendingPathComponent(file.name + ".partial")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.copyItem(at: cached, to: partial)
            try FileManager.default.moveItem(at: partial, to: final)
            done += file.bytes
            continue
        }
        emit(["event": "file", "name": file.name, "bytes": file.bytes, "from": "download"])
        var failures = 0
        while true {
            switch fetch(file, into: folder, before: done, total: total) {
            case .downloaded(let partial):
                emit(["event": "verifying", "name": file.name])
                guard try ModelFiles.sha256(of: partial) == file.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    failures += 1
                    guard failures < 3 else {
                        emit(["event": "error", "message": "\(file.name) arrived damaged, three times"])
                        return 1
                    }
                    emit(["event": "retry", "message": "\(file.name) arrived damaged", "seconds": 0])
                    continue
                }
                try FileManager.default.moveItem(at: partial, to: final)
                done += file.bytes
            case .failed(let message, let retry):
                failures += 1
                guard retry, failures <= 20 else {
                    emit(["event": "error", "message": message])
                    return 1
                }
                // A flaky link resumes where it stopped: 2, 4, 8 … seconds apart, a minute at most.
                let seconds = min(60, 1 << min(failures, 6))
                emit(["event": "retry", "message": message, "seconds": seconds])
                Thread.sleep(forTimeInterval: Double(seconds))
                continue
            }
            break
        }
    }
    emit(["event": "done", "folder": folder.path])
    return 0
}

/// One try at one file: blocks until `FileFetcher` is through with it.
private func fetch(_ file: ModelFiles.File, into folder: URL, before done: Int64, total: Int64) -> FileFetcher.Outcome {
    let finished = DispatchSemaphore(value: 0)
    let result = OutcomeBox()
    let fetcher = FileFetcher(file: file, folder: folder, progress: { written in
        emit(["event": "progress", "name": file.name, "bytes": written, "total": file.bytes,
              "all_bytes": done + written, "all_total": total])
    }, waiting: {
        emit(["event": "waiting"])
    }, done: { outcome in
        result.outcome = outcome
        finished.signal()
    })
    fetcher.start()
    finished.wait()
    return result.outcome ?? .failed("the download stopped", retry: true)
}

private final class OutcomeBox: @unchecked Sendable {   // written once, before the semaphore is signalled
    var outcome: FileFetcher.Outcome?
}
