#if !os(Windows)
import Foundation
import LlamaRuntime
import MurmurIndex
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `murmur-engine memory-service [--socket PATH] [--idle SECONDS]`: the models Murmur's memory runs, on a Unix socket
/// in Application Support, shared by the app and its screen-memory helper (whichever needs it first starts it):
///
/// - embed: EmbeddingGemma 2, file search's own model (text part, 0.25 GB), for search by meaning;
/// - generate: the reading model (Qwen3 on llama.cpp: `LlamaReader`), which writes memories from what it reads.
///
/// One request per connection, one JSON line each way:
///   → {"op": "embed", "texts": [...], "query": true}          ← {"vectors": ["<base64 float32>", ...]}
///   → {"op": "generate", "system": …, "user": …, "json": true, "max": 900}   ← {"text": …}
///   ← {"error": …} when it can't
/// Answered one at a time, at background priority. The reading model (2.5 GB) is freed two minutes after its last use;
/// the embedder stays while commands keep asking; the service exits after `--idle` seconds (default 300) with none.
func memoryService(_ args: Arguments) -> Int32 {
    #if os(macOS)
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
    #endif
    let path = args.values["--socket"] ?? ReaderModelFiles.socket.path
    let idle = Double(args.values["--idle"] ?? "") ?? 300
    guard let server = UnixSocket.listen(at: path) else { return 0 }   // another one already listens there
    defer { close(server); unlink(path) }
    var reader: LlamaReader?
    var embedder: LlamaEmbedder?
    var last = Date(), lastGenerate = Date()
    while Date().timeIntervalSince(last) < idle {
        if reader != nil, Date().timeIntervalSince(lastGenerate) > 120 {
            reader?.close()
            reader = nil
        }
        guard let client = UnixSocket.accept(server, timeout: 1) else { continue }
        defer { close(client) }
        last = Date()
        guard let line = UnixSocket.readLine(client, timeout: 30),
              let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        var reply: [String: Any]
        do {
            switch request["op"] as? String ?? "generate" {
            case "embed":
                if embedder == nil { embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: true) }
                let query = request["query"] as? Bool ?? false
                let texts = (request["texts"] as? [String] ?? []).map {
                    query ? Prompts.query($0) : Prompts.document(title: nil, text: $0)
                }
                let vectors = try embedder!.embedTexts(texts)
                reply = ["vectors": vectors.map { vector in vector.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() } }]
            default:
                // Asked for speed (the user is away and the Mac plugged in): normal priority for this request, so macOS
                // doesn't throttle the GPU; background again after.
                let fast = request["fast"] as? Bool ?? false
                #if os(macOS)
                if fast { setpriority(PRIO_DARWIN_PROCESS, 0, 0) }
                defer { if fast { setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) } }
                #endif
                if reader == nil {
                    guard let file = ReaderModelFiles.installed() else {
                        throw WorkerError.notFound("the reading model isn't downloaded yet")
                    }
                    reader = try LlamaReader(file: file)
                }
                let text = try reader!.generate(system: request["system"] as? String ?? "",
                                                user: request["user"] as? String ?? "",
                                                json: request["json"] as? Bool ?? false,
                                                maxTokens: (request["max"] as? NSNumber)?.intValue ?? 900)
                lastGenerate = Date()
                reply = ["text": text, "model": reader!.file.lastPathComponent, "reused": reader!.reused]
            }
        } catch {
            reply = ["error": "\(error)"]
        }
        if let data = try? JSONSerialization.data(withJSONObject: reply) {
            UnixSocket.write(client, data + Data("\n".utf8))
        }
        last = Date()
    }
    reader?.close()
    embedder?.close()
    return 0
}
#endif
