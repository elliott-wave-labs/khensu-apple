// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A devnet description as written by khensu-devnet to `devnet.json`.
///
/// The app keeps the JSON verbatim and hands it to the core, which owns the
/// schema; this type only checks that it is a JSON object and pulls out what
/// the debug screen shows (network name, endpoint count).
public struct DevnetConfig: Hashable, Sendable, Codable {
    public let json: Data
    public let name: String
    public let endpoints: [String]

    public init(json: Data) throws(KhensuError) {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: json) } catch {
            throw .invalidDevnetConfig("not JSON")
        }
        guard let dict = object as? [String: Any] else { throw .invalidDevnetConfig("expected a JSON object") }
        self.json = json
        self.name = (dict["network"] ?? dict["name"] ?? dict["chain_id"]) as? String ?? "devnet"
        var found: [String] = []
        Self.collectEndpoints(dict, into: &found)
        guard !found.isEmpty else { throw .invalidDevnetConfig("no endpoints found") }
        self.endpoints = found
    }

    public init(string: String) throws(KhensuError) {
        try self.init(json: Data(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// Any string value that looks like `scheme://host` or `host:port`.
    private static func collectEndpoints(_ value: Any, into out: inout [String]) {
        switch value {
        case let s as String:
            if s.contains("://") || s.range(of: #"^[A-Za-z0-9.\-\[\]:]+:\d{2,5}$"#, options: .regularExpression) != nil {
                out.append(s)
            }
        case let d as [String: Any]:
            for k in d.keys.sorted() { collectEndpoints(d[k]!, into: &out) }
        case let a as [Any]:
            for v in a { collectEndpoints(v, into: &out) }
        default: break
        }
    }
}
