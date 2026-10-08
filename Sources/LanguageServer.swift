import Foundation

struct LSPFramer {
    private var buffer = Data()
    private var expected: Int?
    mutating func feed(_ chunk: Data) throws -> [[String: Any]] {
        buffer.append(chunk)
        var messages: [[String: Any]] = []
        while true {
            if expected == nil {
                guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= 8192 else { throw LanguageFailure.invalidMessage }; break
                }
                guard boundary.lowerBound - buffer.startIndex <= 8192 else { throw LanguageFailure.invalidMessage }
                let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                guard let length, length >= 0, length <= 8 * 1024 * 1024 else { throw LanguageFailure.invalidMessage }
                expected = length; buffer.removeSubrange(..<boundary.upperBound)
            }
            guard let length = expected, buffer.count >= length else { break }
            let body = buffer.prefix(length)
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw LanguageFailure.invalidMessage }
            messages.append(message); buffer.removeFirst(length); expected = nil
        }
        return messages
    }
    static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= 8 * 1024 * 1024 else { throw LanguageFailure.invalidMessage }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8); data.append(body); return data
    }
}

/// Independent state/read and serial-write queues: a stalled stdin cannot block request timeouts.
final class LSPConnection: @unchecked Sendable {
    private let state = DispatchQueue(label: "TypstEdit.lsp.state", qos: .utility)
    private let writes = DispatchQueue(label: "TypstEdit.lsp.write", qos: .utility)
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var framer = LSPFramer()
    private var pending: [String: (CheckedContinuation<Any, Error>, DispatchWorkItem)] = [:]
    private var cancelled: Set<String> = []
    private var closed = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private let options: [String: Any]
    init(executable: String, root: URL, options: [String: Any]) throws {
        self.options = options
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["lsp"]
        process.currentDirectoryURL = root
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.state.async { [weak self] in self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] _ in self?.close() }
        do { try process.run() }
        catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }
    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 8) async throws -> Any {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                state.async { [weak self] in
                    guard let self else { continuation.resume(throwing: LanguageFailure.stopped); return }
                    guard !self.closed else { continuation.resume(throwing: LanguageFailure.stopped); return }
                    if self.cancelled.remove(id) != nil { continuation.resume(throwing: CancellationError()); return }
                    guard self.pending.count < 32 else { continuation.resume(throwing: LanguageFailure.stale); return }
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, let item = self.pending.removeValue(forKey: id) else { return }
                        item.0.resume(throwing: LanguageFailure.timeout)
                        self.send(["jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": id]])
                    }
                    self.pending[id] = (continuation, deadline)
                    self.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                    self.state.asyncAfter(deadline: .now() + timeout, execute: deadline)
                }
            }
        }, onCancel: { [weak self] in
            self?.state.async { [weak self] in
                guard let self, !self.closed else { return }
                if let item = self.pending.removeValue(forKey: id) {
                    item.1.cancel(); item.0.resume(throwing: CancellationError())
                    self.send(["jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": id]])
                } else {
                    self.cancelled.insert(id)
                    self.state.asyncAfter(deadline: .now() + 1) { [weak self] in self?.cancelled.remove(id) }
                }
            }
        })
    }
    func notify(_ method: String, params: [String: Any]) {
        state.async { [weak self] in self?.send(["jsonrpc": "2.0", "method": method, "params": params]) }
    }
    private func send(_ message: [String: Any]) {
        guard !closed else { return }
        do {
            let bytes = try LSPFramer.encode(message)
            writes.async { [weak self] in
                guard let self else { return }
                do { try self.input.fileHandleForWriting.write(contentsOf: bytes) }
                catch { self.close() }
            }
        } catch { close() }
    }
    private func receive(_ data: Data) {
        guard !closed else { return }
        guard !data.isEmpty else { close(); return }
        do {
            for message in try framer.feed(data) {
                if let method = message["method"] as? String {
                    guard let id = message["id"] else { continue }
                    let result: Any
                    switch method {
                    case "workspace/configuration":
                        let items = (message["params"] as? [String: Any])?["items"] as? [Any] ?? []
                        result = items.map { _ in options }
                    case "workspace/applyEdit": result = ["applied": false, "failureReason": "No unsolicited edits"]
                    default: result = NSNull()
                    }
                    send(["jsonrpc": "2.0", "id": id, "result": result]); continue
                }
                guard let id = message["id"] as? String, let item = pending.removeValue(forKey: id) else { continue }
                item.1.cancel()
                if let error = message["error"] as? [String: Any] {
                    item.0.resume(throwing: LanguageFailure.server(error["message"] as? String ?? "Language request failed"))
                } else { item.0.resume(returning: message["result"] ?? NSNull()) }
            }
        } catch { close() }
    }
    func isUsable() async -> Bool {
        await withCheckedContinuation { continuation in state.async { [self] in continuation.resume(returning: !closed && process.isRunning) } }
    }
    var processID: Int32 { process.processIdentifier }
    func shutdown() async {
        _ = try? await request("shutdown", params: [:], timeout: 1)
        notify("exit", params: [:])
        try? await Task.sleep(for: .milliseconds(50))
        close()
        await withCheckedContinuation { continuation in
            state.async { [self] in
                if stopped { continuation.resume() } else { stopWaiters.append(continuation) }
            }
        }
    }
    func close() {
        state.async { [self] in
            guard !closed else { return }
            closed = true
            output.fileHandleForReading.readabilityHandler = nil
            for item in pending.values { item.1.cancel(); item.0.resume(throwing: LanguageFailure.stopped) }
            pending.removeAll(); cancelled.removeAll(); framer = LSPFramer()
            let process = self.process, input = self.input, output = self.output
            // Stop on a separate queue even when the writer is blocked on a broken server.
            DispatchQueue.global(qos: .utility).async { [self] in
                CLIProcess.stopAndWait(process)
                try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
                state.async { [self] in
                    stopped = true
                    for waiter in stopWaiters { waiter.resume() }; stopWaiters.removeAll()
                }
            }
        }
    }
    deinit { output.fileHandleForReading.readabilityHandler = nil }
}

actor TypstLanguageService {
    static let shared = TypstLanguageService()
    private var connection: LSPConnection?
    private var key = ""
    private var initializing: Task<Void, Error>?
    private var documents: [String: (String, Int)] = [:]
    private var idle: Task<Void, Never>?
    private var idleToken = UUID()
    private var generation = UUID()
    private var retiring: Task<Void, Never>?
    func stop() {
        idleToken = UUID()
        idle?.cancel(); idle = nil; initializing?.cancel(); initializing = nil
        if let old = connection {
            let previous = retiring
            retiring = Task { await previous?.value; await old.shutdown() }
        }
        connection = nil; key = ""; documents.removeAll(); generation = UUID()
    }
    private func client(_ document: LanguageDocument) async throws -> LSPConnection {
        guard !Task.isCancelled else { throw CancellationError() }
        if let existing = connection {
            let usable = await existing.isUsable()
            try Task.checkCancellation()
            if !usable, connection === existing { stop() }
        }
        if connection == nil || key != document.key {
            if connection != nil { stop() }
            let token = generation, retired = retiring
            await retired?.value
            try Task.checkCancellation()
            // Another request may have installed a client while this actor was awaiting retirement.
            if connection != nil { return try await client(document) }
            guard generation == token else { throw CancellationError() }
            var options: [String: Any] = ["exportPdf": "never", "previewFeature": "disable", "semanticTokens": "disable",
                "formatterMode": "typstyle", "formatterPrintWidth": 100, "formatterIndentSize": 2,
                "compileStatus": "disable", "rootPath": document.root.path, "systemFonts": !document.fontArguments.contains("--ignore-system-fonts")]
            var paths: [String] = []
            for index in document.fontArguments.indices where document.fontArguments[index] == "--font-path" && index + 1 < document.fontArguments.count { paths.append(document.fontArguments[index + 1]) }
            options["fontPaths"] = paths
            let client = try LSPConnection(executable: document.executable, root: document.root, options: options)
            connection = client; key = document.key
            resetIdle()
            initializing = Task {
                let response = try await client.request("initialize", params: [
                    "processId": ProcessInfo.processInfo.processIdentifier,
                    "clientInfo": ["name": "TypstEdit"], "rootUri": document.root.absoluteString,
                    "workspaceFolders": [["uri": document.root.absoluteString, "name": document.root.lastPathComponent]],
                    "capabilities": ["general": ["positionEncodings": ["utf-16"]],
                        "textDocument": ["completion": ["completionItem": ["snippetSupport": true, "documentationFormat": ["plaintext", "markdown"]]],
                            "hover": ["contentFormat": ["plaintext", "markdown"]], "formatting": ["dynamicRegistration": false]]],
                    "initializationOptions": options
                ], timeout: 15)
                guard let capabilities = (response as? [String: Any])?["capabilities"] as? [String: Any] else { throw LanguageFailure.invalidMessage }
                if let encoding = capabilities["positionEncoding"] as? String, encoding != "utf-16" { throw LanguageFailure.invalidMessage }
                client.notify("initialized", params: [:])
            }
        }
        guard let client = connection, let initializing else { throw LanguageFailure.stopped }
        do { try await initializing.value }
        catch { if connection === client { stop() }; throw error }
        guard !Task.isCancelled, connection === client, key == document.key else { throw CancellationError() }
        return client
    }
    private func synchronize(_ document: LanguageDocument, client: LSPConnection) {
        // A single shared service retains only the currently requested document snapshot.
        for uri in Array(documents.keys) where uri != document.uri {
            client.notify("textDocument/didClose", params: ["textDocument": ["uri": uri]])
            documents.removeValue(forKey: uri)
        }
        if let old = documents[document.uri] {
            if old.0 != document.source {
                let version = old.1 + 1
                client.notify("textDocument/didChange", params: ["textDocument": ["uri": document.uri, "version": version], "contentChanges": [["range": ["start": ["line": 0, "character": 0], "end": LSPText(old.0).position((old.0 as NSString).length)], "text": document.source]]])
                documents[document.uri] = (document.source, version)
            }
        } else {
            client.notify("textDocument/didOpen", params: ["textDocument": ["uri": document.uri, "languageId": "typst", "version": 1, "text": document.source]])
            documents[document.uri] = (document.source, 1)
        }
    }
    private func resetIdle() {
        idle?.cancel()
        idleToken = UUID()
        let token = idleToken
        idle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self else { return }
            await self.stopIfIdle(token)
        }
    }
    private func stopIfIdle(_ token: UUID) { if idleToken == token { stop() } }
    func request(_ method: String, document: LanguageDocument, position: Int? = nil) async throws -> Any {
        let client = try await client(document)
        synchronize(document, client: client); resetIdle()
        var params: [String: Any] = ["textDocument": ["uri": document.uri]]
        if let position { params["position"] = LSPText(document.source).position(position) }
        if method == "textDocument/completion" { params["context"] = ["triggerKind": 1] }
        if method == "textDocument/formatting" { params["options"] = ["tabSize": 2, "insertSpaces": true] }
        let result: Any
        do { result = try await client.request(method, params: params) }
        catch is CancellationError { throw CancellationError() }
        catch { if connection === client { stop() }; throw error }
        guard !Task.isCancelled, connection === client else { throw CancellationError() }
        return result
    }
    func close(file: URL) {
        guard documents.removeValue(forKey: file.absoluteString) != nil else { return }
        connection?.notify("textDocument/didClose", params: ["textDocument": ["uri": file.absoluteString]])
        if documents.isEmpty { stop() }
    }
}
