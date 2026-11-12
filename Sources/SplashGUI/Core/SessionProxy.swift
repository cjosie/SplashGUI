import Foundation
import Network

// A loopback HTTP proxy that fronts the PUBLIC serve port while logging is on:
//     clients ──► proxy :<public> ──► engine :<internal>
// Forwarding is a dumb byte pipe and NEVER depends on the logging layer: the parsers
// are a tee that consumes copies. Anything unparseable still flows; at worst the
// record is flagged malformed. Only /v1/* is recorded; /status, the webui, etc.
// proxy silently.
//
// The parse layer below the transport is pure and harness-tested (head parse, chunked
// framing, SSE reassembly, OpenAI chat/responses shapes, request summary).
nonisolated enum HTTPParse {
    struct Head {
        var method: String?     // request
        var path: String?       // request
        var status: Int?        // response
        var headers: [String: String]   // lowercased keys
    }

    // Index just past the CRLFCRLF, else nil.
    static func findHeadEnd(_ buf: Data) -> Int? {
        let bytes = [UInt8](buf)
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                return i + 4
            }
            i += 1
        }
        return nil
    }

    static func parseHead(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { return nil }
        lines.removeFirst()
        var h = Head(headers: [:])
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0].uppercased().hasPrefix("HTTP/"), let code = Int(parts[1]) {
            h.status = code            // "HTTP/1.1 200 OK"
        } else if parts.count >= 2 {
            h.method = String(parts[0]); h.path = String(parts[1])   // "POST /v1/... HTTP/1.1"
        } else {
            return nil
        }
        for line in lines where !line.isEmpty {
            // Continuation lines (obs-fold) are ancient; tolerate by ignoring lines
            // without a colon rather than failing the whole head.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { h.headers[k] = v }
        }
        return h
    }

    enum Framing { case length(Int), chunked, none }

    static func bodyFraming(head: Head) -> Framing {
        if (head.headers["transfer-encoding"] ?? "").lowercased().contains("chunked") { return .chunked }
        if let cl = head.headers["content-length"], let n = Int(cl) { return .length(n) }
        if let m = head.method, ["POST", "PUT", "PATCH"].contains(m.uppercased()) {
            return .length(0)   // POST without a declared body: empty
        }
        return .none
    }

    // Incremental chunked-transfer decoder: feed wire bytes, get body bytes back.
    final class ChunkedDecoder {
        private var buf = Data()
        private var done = false
        var isComplete: Bool { done }

        func feed(_ data: Data) -> Data {
            if done { return Data() }
            buf.append(data)
            var out = Data()
            while true {
                guard let idx = Self.findCRLF(buf) else { break }
                // Chunk sizes are HEX per RFC 7230 ("1f\r\n" = 31 bytes); extensions
                // (";name=value") ride on the size line.
                let sizeText = String(decoding: buf.subdata(in: 0..<idx), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let sizeHex = sizeText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeText
                guard let size = Int(sizeHex, radix: 16) else { break }
                if size == 0 {
                    // Trailing headers run to the next blank line; swallow what we have.
                    buf.removeAll(); done = true; break
                }
                let bodyStart = idx + 2
                guard buf.count >= bodyStart + size + 2 else { break }
                out.append(buf.subdata(in: bodyStart..<(bodyStart + size)))
                buf.removeSubrange(0..<(bodyStart + size + 2))
            }
            return out
        }

        private static func findCRLF(_ d: Data) -> Data.Index? {
            var i = d.startIndex
            while i < d.endIndex {
                if d[i] == 13, d.index(after: i) < d.endIndex, d[d.index(after: i)] == 10 { return i }
                i += 1
            }
            return nil
        }
    }

    // The JSON body assembled from a request we captured, minus anything unparsable.
    struct RequestSummary {
        var model: String?
        var stream = false
        var systemChars = 0
        var toolNames: [String] = []
    }

    static func summarizeRequest(_ body: Data) -> RequestSummary {
        var s = RequestSummary()
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return s }
        s.model = obj["model"] as? String
        s.stream = (obj["stream"] as? Bool) ?? false
        if let msgs = obj["messages"] as? [[String: Any]] {
            s.systemChars = msgs.filter { ($0["role"] as? String) == "system" }
                .reduce(into: 0) { acc, m in acc += (m["content"] as? String)?.count ?? 0 }
        }
        if let tools = obj["tools"] as? [[String: Any]] {
            s.toolNames = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
        return s
    }
}

// OpenAI chat-completions and Responses shapes, both streaming and not, folded into a
// SessionRecord. Shape-based on purpose: unknown fields are ignored, unknown top-level
// shapes flip parsed=false and keep the raw body so nothing is ever silently dropped.
nonisolated final class SSEReassembler {
    private var lineBuf = ""
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var toolCalls: [Int: SessionRecord.ToolCall] = [:]   // chat: by index
    private var toolOrder: [Int] = []
    private(set) var finishReason: String?
    var usage: SessionRecord.Usage?
    private(set) var sawDone = false
    private(set) var sawUnknown = false

    func feed(_ data: Data) {
        lineBuf += String(decoding: data, as: UTF8.self)
        while let nl = lineBuf.firstIndex(of: "\n") {
            let raw = String(lineBuf[lineBuf.startIndex..<nl]).trimmingCharacters(in: .init(charactersIn: "\r"))
            lineBuf = String(lineBuf[lineBuf.index(after: nl)...])
            consume(line: raw)
        }
    }

    private func consume(line: String) {
        guard line.hasPrefix("data:") else { return }   // event:/id:/retry:/comments: ignorable
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == "[DONE]" { sawDone = true; return }
        guard let j = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: j) as? [String: Any] else {
            sawUnknown = true; return
        }
        if let type = obj["type"] as? String {
            applyResponsesEvent(type, obj)
            return
        }
        applyChatChunk(obj)
    }

    private func applyChatChunk(_ obj: [String: Any]) {
        if let u = obj["usage"] as? [String: Any] { usage = HTTPParseTee.chatUsage(u) }
        guard let choices = obj["choices"] as? [[String: Any]], let c = choices.first else { return }
        if let fr = c["finish_reason"] as? String { finishReason = fr }
        guard let delta = c["delta"] as? [String: Any] else { return }
        if let t = delta["content"] as? String { text += t }
        if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String { reasoning += r }
        if let tcs = delta["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                let idx = (tc["index"] as? Int) ?? 0
                var entry = toolCalls[idx] ?? SessionRecord.ToolCall()
                if toolCalls[idx] == nil { toolOrder.append(idx) }
                if let id = tc["id"] as? String { entry.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let n = fn["name"] as? String { entry.name = (entry.name ?? "") + n }
                    if let a = fn["arguments"] as? String { entry.argumentsJSON = (entry.argumentsJSON ?? "") + a }
                }
                toolCalls[idx] = entry
            }
        }
    }

    private func applyResponsesEvent(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "response.output_text.delta":
            if let d = obj["delta"] as? String { text += d }
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            if let d = obj["delta"] as? String { reasoning += d }
        case "response.function_call_arguments.delta":
            let key = (obj["item_id"] as? String)?.hashValue ?? toolOrder.count
            var entry = toolCalls[key] ?? SessionRecord.ToolCall()
            if toolCalls[key] == nil { toolOrder.append(key) }
            if let id = obj["item_id"] as? String { entry.id = id }
            if let d = obj["delta"] as? String { entry.argumentsJSON = (entry.argumentsJSON ?? "") + d }
            toolCalls[key] = entry
        case "response.completed":
            if let resp = obj["response"] as? [String: Any] {
                finishReason = resp["status"] as? String
                if let u = resp["usage"] as? [String: Any] { usage = HTTPParseTee.responsesUsage(u) }
            }
        case "response.created", "response.in_progress", "response.output_item.added",
             "response.output_item.done", "response.content_part.added", "response.content_part.done",
             "response.output_text.done", "response.function_call_arguments.done",
             "response.refusal.delta", "response.refusal.done":
            break   // lifecycle events; the payloads above carry the content
        default:
            sawUnknown = true
        }
    }

    func result() -> (text: String, reasoning: String, toolCalls: [SessionRecord.ToolCall],
                      finish: String?, usage: SessionRecord.Usage?, sawUnknown: Bool, sawDone: Bool) {
        let calls = toolOrder.compactMap { toolCalls[$0] }
        return (text, reasoning, calls, finishReason, usage, sawUnknown, sawDone)
    }
}

// Shared shape helpers for the non-streaming side.
nonisolated enum HTTPParseTee {
    static func chatUsage(_ u: [String: Any]) -> SessionRecord.Usage {
        var x = SessionRecord.Usage()
        x.input = u["prompt_tokens"] as? Int
        x.output = u["completion_tokens"] as? Int
        x.reasoning = (u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        x.cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return x
    }
    static func responsesUsage(_ u: [String: Any]) -> SessionRecord.Usage {
        var x = SessionRecord.Usage()
        x.input = u["input_tokens"] as? Int
        x.output = u["output_tokens"] as? Int
        x.reasoning = (u["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        x.cached = (u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return x
    }

    // Non-streaming JSON body → record fields; nil parsed flag means unknown shape.
    static func parseJSONBody(_ data: Data)
        -> (text: String?, reasoning: String?, toolCalls: [SessionRecord.ToolCall]?,
            finish: String?, usage: SessionRecord.Usage?, parsed: Bool) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil, nil, nil, false)
        }
        // chat.completions
        if let choices = obj["choices"] as? [[String: Any]], let c = choices.first,
           let msg = c["message"] as? [String: Any] {
            var calls: [SessionRecord.ToolCall] = []
            if let tcs = msg["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    var e = SessionRecord.ToolCall()
                    e.id = tc["id"] as? String
                    if let fn = tc["function"] as? [String: Any] {
                        e.name = fn["name"] as? String
                        e.argumentsJSON = fn["arguments"] as? String
                    }
                    calls.append(e)
                }
            }
            let r = (msg["reasoning_content"] ?? msg["reasoning"]) as? String
            var usage: SessionRecord.Usage?
            if let u = obj["usage"] as? [String: Any] { usage = chatUsage(u) }
            return (msg["content"] as? String, r, calls.isEmpty ? nil : calls,
                    c["finish_reason"] as? String, usage, true)
        }
        // Responses API object
        if let output = obj["output"] as? [[String: Any]] {
            var text = "", reasoning = ""
            var calls: [SessionRecord.ToolCall] = []
            for item in output {
                switch item["type"] as? String {
                case "message":
                    for part in (item["content"] as? [[String: Any]]) ?? [] {
                        if (part["type"] as? String) == "output_text", let t = part["text"] as? String { text += t }
                    }
                case "reasoning":
                    for part in (item["summary"] as? [[String: Any]]) ?? [] {
                        if let t = part["text"] as? String { reasoning += t }
                    }
                case "function_call":
                    var e = SessionRecord.ToolCall()
                    e.id = item["call_id"] as? String
                    e.name = item["name"] as? String
                    e.argumentsJSON = item["arguments"] as? String
                    calls.append(e)
                default: break
                }
            }
            var usage: SessionRecord.Usage?
            if let u = obj["usage"] as? [String: Any] { usage = responsesUsage(u) }
            return (text, reasoning.isEmpty ? nil : reasoning, calls.isEmpty ? nil : calls,
                    obj["status"] as? String, usage, true)
        }
        return (nil, nil, nil, nil, nil, false)
    }
}

extension Data {
    fileprivate func hexTrimmed() -> String {
        String(decoding: self, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// MARK: - transport

// NWListener byte pipe with the tee bolted on. One Flow per client connection;
// everything runs on the proxy's serial queue so the Flow state machines need no
// locks. Callbacks capture Flow strongly only for the duration of a receive; the
// proxy keeps the connection table.
final class SessionProxy: @unchecked Sendable {
    struct Policy {
        var logLocal = true       // loopback peers
        var logLAN = false        // non-loopback peers (only reachable when LAN serve is on)
    }

    let publicPort: Int
    private let internalPort: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "splashgui.sessionproxy")
    private var flows: [ObjectIdentifier: Flow] = [:]
    // The policy is mutable so the Logging tab's "Also record LAN clients" toggle takes effect
    // on the next request, not the next Start. Guarded because the UI writes it on the main
    // thread while the proxy queue reads it.
    private let policyLock = NSLock()
    private var storedPolicy: Policy
    private var policy: Policy {
        policyLock.lock(); defer { policyLock.unlock() }
        return storedPolicy
    }
    private let log: SessionLog
    var onNote: ((String) -> Void)?     // fires on a background queue; callers hop

    init(publicPort: Int, internalPort: Int, lanBind: Bool, policy: Policy, log: SessionLog) throws {
        self.publicPort = publicPort
        self.internalPort = internalPort
        self.storedPolicy = policy
        self.log = log
        guard let port = NWEndpoint.Port(rawValue: UInt16(publicPort)) else {
            throw InstallError.preflight("Logging proxy port \(publicPort) is out of range.")
        }
        let params = NWParameters.tcp
        // The port rides in requiredLocalEndpoint; passing it to NWListener(using:on:)
        // as well throws EINVAL (two sources of truth for the bind).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: lanBind ? "0.0.0.0" : "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        for f in flows.values { f.teardown() }
        flows.removeAll()
    }

    // Live policy change from the Logging tab; applies to requests that arrive after it.
    func updatePolicy(_ p: Policy) {
        policyLock.lock(); storedPolicy = p; policyLock.unlock()
    }

    private func accept(_ client: NWConnection) {
        // `endpoint` is the peer for a listener-accepted connection; `currentPath` is the
        // authoritative source once the path exists. Unknown shapes count as remote, so a
        // LAN client is never recorded by accident when the toggle is off.
        let peer = client.currentPath?.remoteEndpoint ?? client.endpoint
        let loopback = Self.isLoopbackEndpoint(peer)
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(internalPort))!, using: .tcp)
        let flow = Flow(client: client, upstream: upstream, loopback: loopback,
                        policy: policy, log: log, queue: queue,
                        onNote: { [weak self] msg in self?.onNote?(msg) },
                        onDead: { [weak self] in
                            self?.queue.async { self?.flows[ObjectIdentifier(client)] = nil }
                        })
        flows[ObjectIdentifier(client)] = flow
        flow.begin()
    }

    // Pure rule the harness pins: does this peer get RECORDED (everything always gets piped)?
    nonisolated static func shouldRecord(policy: Policy, loopbackPeer: Bool) -> Bool {
        loopbackPeer ? policy.logLocal : policy.logLAN
    }

    // Loopback peers are this Mac's own clients. IPv4-mapped IPv6 normalizes to "127.x" in
    // NWEndpoint.Host's description, so the prefix check covers it.
    nonisolated static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let h = String(describing: host).lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    // Free-port pick for the engine behind the proxy: probe-bind starting at public+1.
    nonisolated static func pickInternalPort(publicPort: Int, tries: Int = 32) -> Int? {
        for candidate in (publicPort + 1)...(publicPort + tries) {
            guard candidate < 65_536 else { break }
            if isPortFree(candidate) { return candidate }
        }
        return nil
    }

    nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

extension SessionProxy {
    private final class Flow {
        private let client: NWConnection
        private let upstream: NWConnection
        private let loopback: Bool
        private let policy: SessionProxy.Policy
        private let log: SessionLog
        private let queue: DispatchQueue
        private let onDead: () -> Void
        private let onNote: (String) -> Void

        // request side
        private var reqBuf = Data()
        private var record: SessionRecord?
        private var recordWanted = false
        private var reqDone = false
        private var reqBody = Data()
        private var reqNeed = -1                       // -1 unknown, 0..n remaining, -2 chunked
        private var reqChunker: HTTPParse.ChunkedDecoder?
        // response side
        private var respBuf = Data()
        private var respMode: RespMode = .head
        private var respSSE: SSEReassembler?
        private var respJSON = Data()
        private var respNeed = -1
        private var respChunker: HTTPParse.ChunkedDecoder?
        private var respStatus: Int?
        private var finalized = false
        private var beganUpstream = false

        enum RespMode { case head, sse, json, ignore }

        private static let headCap = 64 * 1024
        private static let bodyCap = 8 * 1024 * 1024

        init(client: NWConnection, upstream: NWConnection, loopback: Bool,
             policy: SessionProxy.Policy, log: SessionLog, queue: DispatchQueue,
             onNote: @escaping (String) -> Void, onDead: @escaping () -> Void) {
            self.client = client; self.upstream = upstream; self.loopback = loopback
            self.policy = policy; self.log = log; self.queue = queue
            self.onNote = onNote; self.onDead = onDead
        }

        func begin() {
            client.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: self?.queue.async { self?.startUpstream() }
                case .failed, .cancelled: self?.queue.async { self?.clientGone() }
                default: break
                }
            }
            client.start(queue: queue)
        }

        private func startUpstream() {
            guard !beganUpstream else { return }
            beganUpstream = true
            upstream.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: self?.queue.async { self?.pumpClient(); self?.pumpUpstream() }
                case .failed: self?.queue.async { self?.upstreamGone(error: "connect failed") }
                case .cancelled: self?.queue.async { self?.upstreamGone(error: nil) }
                default: break
                }
            }
            upstream.start(queue: queue)
        }

        // MARK: client → upstream

        private func pumpClient() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                self?.queue.async {
                    guard let self else { return }
                    if let d = data, !d.isEmpty { self.teeRequest(d) }
                    if let d = data, !d.isEmpty {
                        self.upstream.send(content: d, completion: .contentProcessed { [weak self] e in
                            if e != nil { self?.queue.async { self?.upstreamGone(error: "send failed") } }
                        })
                    }
                    if complete || error != nil { self.clientGone(); return }
                    self.pumpClient()
                }
            }
        }

        private func teeRequest(_ data: Data) {
            if recordWanted, !reqDone {
                consumeReqBody(data)
                return
            }
            guard record == nil, !finalized else { return }
            reqBuf.append(data)
            if reqBuf.count > Self.headCap { malformed(note: "head too large"); return }
            guard let end = HTTPParse.findHeadEnd(reqBuf) else { return }
            guard let head = HTTPParse.parseHead(reqBuf[reqBuf.startIndex..<reqBuf.startIndex + end]) else {
                malformed(note: "unparseable head"); return
            }
            let path = head.path ?? ""
            reqBuf = Data(reqBuf.dropFirst(end))
            guard path.hasPrefix("/v1/") else { return }          // pipe silently, no record
            recordWanted = SessionProxy.shouldRecord(policy: policy, loopbackPeer: loopback)
            guard recordWanted else { return }
            record = SessionRecord(tsStart: Date(), clientHint: head.headers["user-agent"],
                                   clientLoopback: loopback, path: path)
            switch HTTPParse.bodyFraming(head: head) {
            case .none: reqNeed = 0
            case .length(let n): reqNeed = n
            case .chunked: reqNeed = -2; reqChunker = HTTPParse.ChunkedDecoder()
            }
            consumeReqBody(reqBuf)                                // head + body may share a read
            reqBuf = Data()
        }

        private func consumeReqBody(_ data: Data) {
            guard recordWanted, !reqDone else { return }
            if reqNeed == -2 {
                if let out = reqChunker?.feed(data) { reqBody.append(out) }
                if reqChunker?.isComplete == true { finishRequest() }
                return
            }
            reqBody.append(data)
            reqNeed -= data.count
            if reqNeed <= 0 { finishRequest() }
        }

        private func finishRequest() {
            guard !reqDone else { return }
            reqDone = true
            guard var rec = record else { return }
            if reqBody.count > Self.bodyCap {
                rec.error = "malformed"; rec.parsed = false
                record = rec; return
            }
            rec.requestJSON = String(data: reqBody, encoding: .utf8)
            let s = HTTPParse.summarizeRequest(reqBody)
            rec.model = s.model; rec.stream = s.stream
            rec.systemChars = s.systemChars; rec.toolNames = s.toolNames.isEmpty ? nil : s.toolNames
            record = rec
        }

        private func malformed(note: String) {
            guard recordWanted || record != nil else { reqBuf = Data(); return }
            var rec = record ?? SessionRecord(tsStart: Date(), path: "/v1/malformed")
            rec.error = "malformed"
            record = rec
            onNote("logging: malformed request (\(note)) — traffic unaffected")
        }

        // MARK: upstream → client

        private func pumpUpstream() {
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                self?.queue.async {
                    guard let self else { return }
                    if let d = data, !d.isEmpty { self.client.send(content: d, completion: .contentProcessed { _ in }) }
                    if let d = data, !d.isEmpty { self.teeResponse(d) }
                    if complete || error != nil { self.upstreamGone(error: error == nil ? nil : "upstream closed"); return }
                    self.pumpUpstream()
                }
            }
        }

        private func teeResponse(_ data: Data) {
            guard recordWanted else { return }
            switch respMode {
            case .head:
                respBuf.append(data)
                if respBuf.count > Self.headCap { respMode = .ignore; return }
                guard let end = HTTPParse.findHeadEnd(respBuf) else { return }
                if let h = HTTPParse.parseHead(respBuf[respBuf.startIndex..<respBuf.startIndex + end]) {
                    respStatus = h.status
                    let ct = h.headers["content-type"] ?? ""
                    if ct.contains("text/event-stream") { respMode = .sse; respSSE = SSEReassembler() }
                    else if ct.contains("json") {
                        respMode = .json
                        switch HTTPParse.bodyFraming(head: h) {
                        case .length(let n): respNeed = n
                        case .chunked: respNeed = -2; respChunker = HTTPParse.ChunkedDecoder()
                        case .none: respNeed = 0
                        }
                    } else { respMode = .ignore }
                    respBuf = Data(respBuf.dropFirst(end))
                    if !respBuf.isEmpty { teeResponse(respBuf); respBuf = Data() }
                } else { respMode = .ignore }
            case .sse:
                respSSE?.feed(data)
                if respSSE?.result().sawDone == true { finalize(error: nil) }
            case .json:
                if respNeed == -2 {
                    if let out = respChunker?.feed(data) { respJSON.append(out) }
                    if respChunker?.isComplete == true { finishResponseJSON() }
                } else {
                    respJSON.append(data)
                    if respNeed >= 0, respJSON.count >= respNeed { finishResponseJSON() }
                }
            case .ignore:
                break
            }
        }

        private func finishResponseJSON() {
            defer { finalize(error: nil) }
            guard var rec = record, respMode == .json else { return }
            let p = HTTPParseTee.parseJSONBody(respJSON)
            if p.parsed {
                rec.responseText = p.text; rec.responseReasoning = p.reasoning
                rec.toolCalls = p.toolCalls; rec.finishReason = p.finish; rec.usage = p.usage
                rec.parsed = true
            } else {
                rec.parsed = false
                rec.rawResponse = String(data: respJSON, encoding: .utf8)
            }
            record = rec
        }

        // MARK: lifecycle

        private func finalize(error: String?) {
            guard !finalized, var rec = record else { return }
            finalized = true
            let now = Date()
            rec.tsEnd = now
            rec.durationMs = Int(now.timeIntervalSince(rec.tsStart) * 1000)
            rec.status = respStatus
            if let sse = respSSE {
                let r = sse.result()
                rec.responseText = r.text.isEmpty ? nil : r.text
                rec.responseReasoning = r.reasoning.isEmpty ? nil : r.reasoning
                rec.toolCalls = r.toolCalls.isEmpty ? nil : r.toolCalls
                rec.finishReason = r.finish
                rec.usage = r.usage
                if r.sawUnknown { rec.parsed = false }
            }
            if error != nil { rec.error = error }
            log.write(rec)
            record = nil
            recordWanted = false
            // keep-alive: a clean completed exchange re-arms the parser for the next request.
            if error == nil {
                reqBuf = Data(); reqDone = false; reqBody = Data(); reqNeed = -1; reqChunker = nil
                respBuf = Data(); respMode = .head; respSSE = nil; respJSON = Data()
                respNeed = -1; respChunker = nil; respStatus = nil; finalized = false
            }
        }

        private func clientGone() {
            if record != nil, !finalized { finalize(error: "client-abort") }
            teardown()
        }

        private func upstreamGone(error: String?) {
            if error != nil, record != nil, !finalized {
                if respStatus == nil, let rec = record, rec.requestJSON != nil || reqDone {
                    let body = Data("HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".utf8)
                    client.send(content: body, completion: .contentProcessed { _ in })
                }
                finalize(error: "upstream-error")
            } else if record != nil, !finalized {
                // Clean upstream close mid-response (some servers close instead of [DONE]).
                finalize(error: respStatus == nil ? "upstream-error" : nil)
            }
            teardown()
        }

        func teardown() {
            client.cancel(); upstream.cancel()
            onDead()
        }
    }
}
