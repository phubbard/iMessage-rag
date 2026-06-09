import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// HTTP Basic auth. The whole app sits behind this — it's the family's private
/// history, so even on the LAN we require credentials. Bind to a LAN interface,
/// never expose to the internet (PLAN §12).
struct BasicAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let user: String
    let password: String

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        if let provided = Self.credentials(request), constantTimeEqual(provided.0, user),
           constantTimeEqual(provided.1, password) {
            return try await next(request, context)
        }
        return Response(
            status: .unauthorized,
            headers: [.wwwAuthenticate: "Basic realm=\"imessage-rag\", charset=\"UTF-8\""],
            body: .init(byteBuffer: .init(string: "Authentication required\n")))
    }

    static func credentials(_ request: Request) -> (String, String)? {
        guard let header = request.headers[.authorization],
              header.lowercased().hasPrefix("basic "),
              let data = Data(base64Encoded: String(header.dropFirst(6))),
              let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":")
        else { return nil }
        return (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
    }
}

/// Length-independent-ish constant-time string compare to avoid timing leaks.
private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for i in 0..<max(x.count, y.count) {
        let xi = i < x.count ? Int(x[i]) : 0
        let yi = i < y.count ? Int(y[i]) : 0
        diff |= xi ^ yi
    }
    return diff == 0
}
