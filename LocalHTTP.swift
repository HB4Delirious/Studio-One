import Foundation
import Network

/// The plumbing both local HTTP servers share — the Stream Deck's control port
/// and the request line: read one request, write one response, close. Neither
/// needs keep-alive; their clients make a handful of small round trips.
enum LocalHTTP {

    struct Request {
        let method: String
        let path: String
        /// Names lowercased.
        let headers: [String: String]
        let body: Data
    }

    /// Reads until one whole request, body included, has arrived and hands it
    /// to `handle` — on the connection's queue. Closes the connection instead
    /// if the client stops sending first, or sends more than `limit` bytes.
    static func receive(on connection: NWConnection, limit: Int, buffer: Data = Data(),
                        handle: @escaping @Sendable (Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) { return handle(request) }
            if complete || error != nil || buffer.count > limit { return connection.cancel() }
            receive(on: connection, limit: limit, buffer: buffer, handle: handle)
        }
    }

    /// Nil until the headers and `Content-Length` bytes of body are in.
    static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]),
                       headers: headers, body: Data(body.prefix(length)))
    }

    static func respond(_ status: Int, type: String, body: Data, headers: [String: String] = [:],
                        on connection: NWConnection) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 416: "Range Not Satisfiable", 500: "Internal Server Error"][status] ?? "Error"
        let extra = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + (headers["Cache-Control"] == nil ? "Cache-Control: no-store\r\n" : "")
            + extra
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// A file, or the part of it a `Range` header asks for: Safari won't
    /// play audio from a server that can't send parts. `download` names it
    /// for saving rather than playing.
    static func respondFile(_ url: URL, type: String, range: String?, download: String? = nil,
                            on connection: NWConnection) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            return respond(404, type: "text/plain", body: Data("not found".utf8), on: connection)
        }
        var headers = ["Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600"]
        if let download {
            let plain = String(download.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? $0 : "_" })
            let encoded = download.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? plain
            headers["Content-Disposition"] = "attachment; filename=\"\(plain)\"; filename*=UTF-8''\(encoded)"
        }
        switch byteRange(range, size: data.count) {
        case .whole:
            respond(200, type: type, body: data, headers: headers, on: connection)
        case .part(let part):
            headers["Content-Range"] = "bytes \(part.lowerBound)-\(part.upperBound)/\(data.count)"
            respond(206, type: type, body: data.subdata(in: part.lowerBound..<(part.upperBound + 1)),
                    headers: headers, on: connection)
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(data.count)"
            respond(416, type: type, body: Data(), headers: headers, on: connection)
        }
    }

    enum ByteRange: Equatable {
        case whole
        case part(ClosedRange<Int>)
        case unsatisfiable
    }

    /// One range of "bytes=a-b", "bytes=a-" or "bytes=-n"; anything else,
    /// or several ranges, is answered with the whole file.
    static func byteRange(_ header: String?, size: Int) -> ByteRange {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return .whole }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .whole }
        let first = Int(parts[0]), last = Int(parts[1])
        switch (first, last) {
        case let (start?, end?):
            guard start <= end else { return .whole }
            guard start < size else { return .unsatisfiable }
            return .part(start...min(end, size - 1))
        case let (start?, nil) where parts[1].isEmpty:
            guard start < size else { return .unsatisfiable }
            return .part(start...(size - 1))
        case let (nil, count?) where parts[0].isEmpty:
            guard count > 0, size > 0 else { return .unsatisfiable }
            return .part(max(0, size - count)...(size - 1))
        default:
            return .whole
        }
    }

    static func respond(_ status: Int, json: Any, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(status, type: "application/json", body: body, on: connection)
    }
}
