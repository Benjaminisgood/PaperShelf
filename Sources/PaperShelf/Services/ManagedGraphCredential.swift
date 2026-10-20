import Foundation
import Darwin

enum ManagedGraphCredential {
    /// The managed local database has a private Docker environment file.
    /// Never reuse that credential for a user-supplied remote URI.
    static func password(for configuration: [String: Any]) -> String? {
        guard (configuration["backend"] as? String ?? "neo4j") == "neo4j",
              configuration["uri"] as? String == "bolt://127.0.0.1:17687",
              (configuration["user"] as? String ?? "neo4j") == "neo4j",
              (configuration["password_environment"] as? String ?? "NEO4J_PASSWORD") == "NEO4J_PASSWORD" else { return nil }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperShelf/graph-service/neo4j.env")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("NEO4J_PASSWORD=") {
            let value = String(line.dropFirst("NEO4J_PASSWORD=".count))
            if !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) { return value }
        }
        return nil
    }
}
