// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A devnet description as written by khensu-devnet to `devnet.json`.
///
/// The app keeps the JSON verbatim and hands it to the core, which owns the
/// schema; this type only checks that it is a JSON object and pulls out what
/// the debug screen shows. Directory v2 (khensu-core 0.2) is the genesis epoch
/// header plus base64 leases, so the node endpoints are not visible here: the
/// core reports them once it has loaded the directory. Directory v1 listed
/// nodes with plain endpoints, which are still collected.
public struct DevnetConfig: Hashable, Sendable, Codable {
    public let json: Data
    public let name: String
    /// Directory format version (1 or 2); 0 when the file does not say.
    public let version: Int
    /// Nodes in the directory: leases in v2, endpoints found in v1.
    public let nodeCount: Int
    /// Plain endpoints found in the JSON (v1 only; empty for v2).
    public let endpoints: [String]
    /// Rules the header carries (v2): tick, committee size, replicas.
    public let rules: [String: Int]

    public init(json: Data) throws(KhensuError) {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: json) } catch {
            throw .invalidDevnetConfig("not JSON")
        }
        guard let dict = object as? [String: Any] else { throw .invalidDevnetConfig("expected a JSON object") }
        self.json = json
        self.name = (dict["network"] ?? dict["name"] ?? dict["chain_id"]) as? String ?? "devnet"
        self.version = dict["version"] as? Int ?? 0
        var found: [String] = []
        var rules: [String: Int] = [:]
        if version >= 2 {
            guard let leases = dict["leases"] as? [Any], !leases.isEmpty else {
                throw .invalidDevnetConfig("no leases in the directory")
            }
            guard dict["header"] is String else { throw .invalidDevnetConfig("no epoch header in the directory") }
            self.nodeCount = leases.count
            for (k, v) in dict["rules"] as? [String: Any] ?? [:] {
                if let n = v as? Int { rules[k] = n }
            }
        } else {
            Self.collectEndpoints(dict, into: &found)
            guard !found.isEmpty else { throw .invalidDevnetConfig("no endpoints found") }
            self.nodeCount = found.count
        }
        self.endpoints = found
        self.rules = rules
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
