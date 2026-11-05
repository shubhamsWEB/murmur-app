import CLlama
import Foundation
import MurmurIndex

/// Qwen3 on llama.cpp (Metal), in this process: reads a note, an email or what you worked on and writes what to
/// remember, so Murmur's memory needs no Ollama. Greedy, with the model's thinking turned off (an empty think block),
/// and for JSON a grammar that only lets valid JSON out (`LlamaReader.json`). One request at a time.
public final class LlamaReader {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let vocab: OpaquePointer?
    private let template: String?
    private let contextSize: Int32
    public let file: URL
    /// The tokens in the model's memory from the last request: the next one reuses what they share (the same system
    /// prompt, every time), and only the rest is read again.
    private var cached: [llama_token] = []
    /// How many tokens the last request didn't have to read again (for logs and tests).
    public private(set) var reused = 0

    /// JSON objects only, with at most one space or a newline and some indentation between tokens: the stock
    /// json.gbnf allows endless whitespace, which greedy decoding can fall into.
    public static let json = #"""
        root   ::= object
        value  ::= object | array | string | number | ("true" | "false" | "null")
        object ::= "{" ws ( string ":" ws value ( "," ws string ":" ws value )* )? ws "}"
        array  ::= "[" ws ( value ( "," ws value )* )? ws "]"
        string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}) )* "\""
        number ::= "-"? ([0-9] | [1-9] [0-9]{0,15}) ("." [0-9]+)? ([eE] [-+]? [0-9]{1,3})?
        ws     ::= | " " | "\n" [ ]{0,8}
        """#

    public init(file: URL, contextSize: Int32 = 4096) throws {
        _ = LlamaEmbedder.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = LlamaEmbedder.cpuOnly ? 0 : 999
        guard let model = llama_model_load_from_file(file.path, modelParams) else {
            throw WorkerError.failed("can't load \(file.path)")
        }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextSize)
        params.n_batch = 1024
        params.n_ubatch = 512
        params.n_seq_max = 1
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw WorkerError.failed("can't create a llama.cpp context for \(file.lastPathComponent)")
        }
        self.model = model
        self.context = context
        self.file = file
        self.contextSize = contextSize
        vocab = llama_model_get_vocab(model)
        template = llama_model_chat_template(model, nil).map { String(cString: $0) }
    }

    deinit { close() }

    public func close() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
    }

    /// The model's answer to `system` and `user`; JSON (by grammar) when `json`. `maxTokens` caps the answer.
    public func generate(system: String, user: String, json: Bool, maxTokens: Int = 900) throws -> String {
        guard let context, let vocab else { throw WorkerError.failed("the reader is closed") }
        // Room for the answer: the input is cut (from the end of the user's text) to what fits before it.
        let budget = Int(contextSize) - maxTokens - 16
        var prompt = try tokens(self.prompt(system: system, user: user))
        if prompt.count > budget {
            var cut = user
            while prompt.count > budget, cut.count > 200 {
                cut = String(cut.prefix(cut.count * budget / max(prompt.count, 1) - 50))
                prompt = try tokens(self.prompt(system: system, user: cut))
            }
        }
        // What this prompt shares with the last one (its instructions) is already in memory: keep it, drop the rest.
        let memory = llama_get_memory(context)
        var common = zip(cached, prompt).prefix { $0 == $1 }.count
        if common == prompt.count { common -= 1 }   // at least one token must be read, for its logits
        if common > 0, llama_memory_seq_rm(memory, 0, llama_pos(common), -1) {
            reused = common
        } else {
            llama_memory_clear(memory, true)
            common = 0
            reused = 0
        }
        cached = prompt
        // The rest of the prompt, in pieces the batch holds.
        var start = common
        while start < prompt.count {
            let end = min(start + 1024, prompt.count)
            var piece = Array(prompt[start..<end])
            let status = piece.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
            }
            guard status == 0 else { throw WorkerError.failed("llama_decode failed (\(status)) on the prompt") }
            start = end
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if json {
            guard let grammar = llama_sampler_init_grammar(vocab, Self.json, "root") else {
                throw WorkerError.failed("the JSON grammar didn't parse")
            }
            llama_sampler_chain_add(sampler, grammar)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if count > 0 { bytes += piece.prefix(Int(count)).map { UInt8(bitPattern: $0) } }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { break }   // the context is full: what's written so far
            cached.append(token)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chat as the model was trained to see it (its own template), with an empty think block: Qwen3 answers
    /// straight away instead of reasoning first.
    func prompt(system: String, user: String) -> String {
        var text = ""
        let roles = [("system", system), ("user", user)]
        let applied: String? = roles.map { strdup($0.0)! }.withUnsafeBufferPointer { names in
            roles.map { strdup($0.1)! }.withUnsafeBufferPointer { contents in
                defer { names.forEach { free($0) }; contents.forEach { free($0) } }
                var messages = (0..<roles.count).map { llama_chat_message(role: names[$0], content: contents[$0]) }
                var buffer = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 512)
                var length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                if length > Int32(buffer.count) {
                    buffer = [CChar](repeating: 0, count: Int(length) + 1)
                    length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                }
                guard length > 0 else { return nil }
                return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        text = applied ?? "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        if (template ?? "").contains("<think>") || file.lastPathComponent.lowercased().contains("qwen3") {
            text += "<think>\n\n</think>\n\n"
        }
        return text
    }

    private func tokens(_ text: String) throws -> [llama_token] {
        let count = Int32(text.utf8.count) + 16
        var out = [llama_token](repeating: 0, count: Int(count))
        let made = llama_tokenize(vocab, text, Int32(text.utf8.count), &out, count, true, true)
        guard made >= 0 else { throw WorkerError.failed("couldn't tokenize the prompt") }
        return Array(out.prefix(Int(made)))
    }
}
