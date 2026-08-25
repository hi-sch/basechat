import Foundation
import Network
import Observation
import SwiftUI

/// A loopback HTTP endpoint that hands the running model to another process —
/// a coding agent, usually.
///
/// `basert serve` already speaks the OpenAI wire format, but on a port picked
/// at launch and behind a key that is regenerated every time a model starts,
/// so nothing outside the app can be pointed at it in advance. This sits in
/// front of it: a fixed port, an optional key of the user's choosing, and
/// loopback-only binding unless that is turned off.
///
/// While it runs the window is put out of the way — two drivers on one
/// conversation is a race nobody wins.
@Observable
@MainActor
final class LocalServer {

    struct Settings: Equatable {
        var port = 8788
        /// Optional. When set, a request must carry it as a bearer token.
        var token = ""
        /// Off binds every interface, so other machines on the network can
        /// reach the model too.
        var loopbackOnly = true
    }

    var settings = Settings()
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var requests = 0
    /// The last request line, so the panel shows something is happening.
    private(set) var lastRequest = ""

    private var listener: NWListener?
    private weak var runtime: Runtime?
    private static let queue = DispatchQueue(label: "co.basecompute.BaseChat.local-server")

    var host: String { settings.loopbackOnly ? "127.0.0.1" : "0.0.0.0" }
    var address: String { "http://\(host):\(settings.port)" }

    init() {
        let defaults = UserDefaults.standard
        if let port = defaults.object(forKey: "localServerPort") as? Int { settings.port = port }
        settings.token = defaults.string(forKey: "localServerToken") ?? ""
        if let loopback = defaults.object(forKey: "localServerLoopback") as? Bool {
            settings.loopbackOnly = loopback
        }
    }

    // MARK: - Lifecycle

    func start(runtime: Runtime) {
        guard !isRunning else { return }
        error = nil
        requests = 0
        lastRequest = ""
        persist()

        guard settings.port > 0, settings.port < 65536,
              let port = NWEndpoint.Port(rawValue: UInt16(settings.port))
        else {
            error = "\(settings.port) is not a usable port."
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if settings.loopbackOnly {
            // The address to bind is carried by the parameters, and passing the
            // port a second time through `on:` is rejected outright — EINVAL,
            // not a listener that quietly binds the wrong interface.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        }

        do {
            let listener = settings.loopbackOnly
                ? try NWListener(using: parameters)
                : try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.note(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.start(queue: Self.queue)
            self.listener = listener
            self.runtime = runtime
            isRunning = true
        } catch {
            self.error = "Could not listen on port \(settings.port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(settings.port, forKey: "localServerPort")
        defaults.set(settings.token, forKey: "localServerToken")
        defaults.set(settings.loopbackOnly, forKey: "localServerLoopback")
    }

    private func note(_ state: NWListener.State) {
        switch state {
        case .failed(let failure):
            error = failure.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - One exchange

    private func serve(_ connection: NWConnection) {
        connection.start(queue: Self.queue)
        Task { @MainActor in
            defer { connection.cancel() }
            guard let request = try? await Self.readRequest(connection) else { return }
            requests += 1
            lastRequest = "\(request.method) \(request.path)"
            await respond(to: request, on: connection)
        }
    }

    private struct Request {
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var body = Data()
    }

    private func respond(to request: Request, on connection: NWConnection) async {
        // Preflight, so a browser-based agent can talk to it too.
        guard request.method != "OPTIONS" else {
            await Self.reply(status: 204, json: "", on: connection)
            return
        }

        if !settings.token.isEmpty {
            let bearer = request.headers["authorization"]?
                .replacingOccurrences(of: "Bearer ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let offered = bearer ?? request.headers["x-api-key"]
            guard offered == settings.token else {
                await Self.reply(status: 401, json: Self.problem("Bad or missing key."), on: connection)
                return
            }
        }

        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        switch (request.method, path) {
        case ("GET", "/"), ("GET", "/health"):
            let model = runtime?.serverModelID ?? ""
            let ready = runtime?.status.isReady == true
            await Self.reply(status: 200,
                             json: #"{"ok":\#(ready),"model":"\#(Self.escape(model))"}"#,
                             on: connection)
        case ("GET", "/v1"), ("GET", "/v1/"):
            // The address the panel shows is the one an OpenAI client wants as
            // its base URL, so it ends in `/v1` — and someone who copies it will
            // open it. Answer with what lives underneath rather than a 404.
            await Self.reply(status: 200, json: Self.index, on: connection)
        case (_, let endpoint) where endpoint.hasPrefix("/v1/"):
            await proxy(request, path: endpoint, on: connection)
        default:
            await Self.reply(status: 404, json: Self.problem("No such endpoint."), on: connection)
        }
    }

    /// Forwards an OpenAI-shaped call to `basert serve` and relays the answer
    /// back as it arrives, so a streamed completion stays streamed.
    private func proxy(_ request: Request, path: String, on connection: NWConnection) async {
        guard let runtime, runtime.status.isReady else {
            await Self.reply(status: 503, json: Self.problem("No model is running in BaseChat."),
                             on: connection)
            return
        }

        var call = URLRequest(url: runtime.apiURL.appendingPathComponent(String(path.dropFirst())))
        call.httpMethod = request.method
        call.timeoutInterval = 600
        call.setValue("Bearer \(runtime.apiToken)", forHTTPHeaderField: "Authorization")
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !request.body.isEmpty { call.httpBody = request.body }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: call)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"

            // No Content-Length and no chunk framing: every reply carries
            // `Connection: close`, so the close *is* the end of the body — which
            // is exactly what lets a token stream go out chunk by chunk.
            await Self.send(Data(Self.head(status: status, type: type).utf8), on: connection)

            var pending = Data()
            for try await byte in bytes {
                pending.append(byte)
                // SSE frames are line-based, so flush on newline rather than
                // holding tokens back for a buffer that may never fill.
                if byte == 0x0A {
                    await Self.send(pending, on: connection)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            await Self.send(pending, on: connection, close: true)
        } catch {
            await Self.reply(status: 502, json: Self.problem(error.localizedDescription), on: connection)
        }
    }

    // MARK: - HTTP

    private static func head(status: Int, type: String) -> String {
        [
            "HTTP/1.1 \(status) \(reason(status))",
            "Content-Type: \(type)",
            "Cache-Control: no-store",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: *",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
    }

    private static func reply(status: Int, json: String, on connection: NWConnection) async {
        let body = Data(json.utf8)
        let head = [
            "HTTP/1.1 \(status) \(reason(status))",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: *",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        await send(Data(head.utf8) + body, on: connection, close: true)
    }

    /// What `/v1` answers with: use this address as a base URL, and here is
    /// what it carries.
    private static let index = """
    {"object":"list","base_url":"this URL","endpoints":\
    ["/v1/models","/v1/chat/completions","/v1/completions","/v1/embeddings"],\
    "served_by":"BaseChat"}
    """

    private static func problem(_ message: String) -> String {
        #"{"error":{"message":"\#(escape(message))","type":"basechat_local_server"}}"#
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    private enum Failure: Error { case malformed }

    /// Reads one request: the head up to the blank line, then exactly as many
    /// body bytes as `Content-Length` promised.
    private static func readRequest(_ connection: NWConnection) async throws -> Request {
        var buffer = Data()
        var head: (method: String, path: String, headers: [String: String])?
        var expected = 0

        while true {
            if head == nil, let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let raw = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
                var lines = raw.components(separatedBy: "\r\n")
                guard !lines.isEmpty else { throw Failure.malformed }
                let start = lines.removeFirst().split(separator: " ")
                guard start.count >= 2 else { throw Failure.malformed }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).lowercased()] =
                        String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                head = (String(start[0]).uppercased(), String(start[1]), headers)
                expected = Int(headers["content-length"] ?? "") ?? 0
                buffer.removeSubrange(..<split.upperBound)
            }

            if let head, buffer.count >= expected {
                return Request(method: head.method, path: head.path, headers: head.headers,
                               body: Data(buffer.prefix(expected)))
            }

            guard let chunk = try await receive(connection) else {
                guard let head else { throw Failure.malformed }
                return Request(method: head.method, path: head.path, headers: head.headers,
                               body: Data(buffer))
            }
            buffer.append(chunk)
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data?.isEmpty == false) ? data : nil)
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection, close: Bool = false) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, isComplete: close,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

// MARK: - The address

/// The endpoint, with the whole address acting as its own copy button — this
/// string exists to be pasted into something else.
struct ServerAddress: View {
    let url: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(url)
                    .font(.callout.monospaced())
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(copied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Click to copy")
        .animation(.easeOut(duration: 0.12), value: copied)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

// MARK: - Settings sheet

struct LocalServerSheet: View {
    @Environment(LocalServer.self) private var server
    @Environment(Runtime.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    @State private var copiedExample = false

    var body: some View {
        @Bindable var server = server

        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Serves the loaded model over HTTP in the OpenAI format, so a coding "
                     + "agent can point at one fixed address instead of the port BaseRT "
                     + "happened to pick. The window is put aside while it runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Port").gridColumnAlignment(.trailing)
                        TextField("8788", value: $server.settings.port,
                                  format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .disabled(server.isRunning)
                    }
                    GridRow {
                        Text("Key").gridColumnAlignment(.trailing)
                        TextField("Optional — sent as a bearer token",
                                  text: $server.settings.token)
                            .textFieldStyle(.roundedBorder)
                            .disabled(server.isRunning)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("Loopback only — this Mac cannot be reached from the network",
                               isOn: $server.settings.loopbackOnly)
                            .disabled(server.isRunning)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    if server.isRunning {
                        ServerAddress(url: "\(server.address)/v1")
                        example
                    } else {
                        Text("Stopped")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if server.isRunning {
                        Text("\(server.requests) requests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = server.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !runtime.status.isReady, !server.isRunning {
                    Text("No model is running yet — start one first, or the endpoint will "
                         + "answer 503 until it is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Divider()
            footer
        }
        .frame(width: 460)
    }

    /// A request that works as pasted, so the first thing tried against the
    /// endpoint is known-good rather than hand-assembled. Sits beside the
    /// address, which is the other thing on this panel meant to be taken away.
    private var example: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(exampleCurl, forType: .string)
            copiedExample = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copiedExample = false
            }
        } label: {
            Label("curl", systemImage: copiedExample ? "checkmark" : "terminal")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .animation(.easeOut(duration: 0.12), value: copiedExample)
        .help(copiedExample ? "Copied" : "Copy an example request:\n\n" + exampleCurl)
    }

    /// Built from what is actually configured — the port in the field, the key
    /// if there is one, and the id the server registered.
    private var exampleCurl: String {
        let model = runtime.serverModelID ?? runtime.selectedModel ?? "local-model"
        var lines = ["curl \(server.address)/v1/chat/completions \\",
                     "  -H 'Content-Type: application/json' \\"]
        if !server.settings.token.isEmpty {
            lines.append("  -H 'Authorization: Bearer \(server.settings.token)' \\")
        }
        let body = #"{"model":"\#(model)","messages":[{"role":"user","content":"Say hello."}],"stream":true}"#
        lines.append("  -N -d '\(body)'")
        return lines.joined(separator: "\n")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tint)
            Text("Local Server").font(.headline)
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            if server.isRunning {
                Button("Stop Server", role: .destructive) { server.stop() }
                    .buttonStyle(.glassProminent)
            } else {
                Button("Start Server") { server.start(runtime: runtime) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

// MARK: - What the window shows while it runs

/// Covers the app while the endpoint is up: nothing here should be typed into
/// from two places at once, and there has to be one obvious way back.
struct LocalServerCurtain: View {
    let server: LocalServer

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Local Server Running").font(.headline)
                ServerAddress(url: "\(server.address)/v1")
                Text("BaseChat is being driven from outside. The window stays out of the way "
                     + "until the server is stopped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !server.lastRequest.isEmpty {
                    Text("\(server.requests) requests · last \(server.lastRequest)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("Stop Server") { server.stop() }
                    .buttonStyle(.glassProminent)
            }
            .padding(30)
            .frame(maxWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}
