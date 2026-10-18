import Foundation

/// Chooses credential destinations without reading a keychain or contacting a
/// service. The caller supplies the parser so unrelated commands never inspect
/// an unfinished Graphiti configuration.
struct CredentialPlan {
    enum Secret: String, Equatable {
        case provider = "api-key"
        case embedding = "embedding-key"
        case graphPassword = "graph-password"
    }

    struct Lookup: Equatable {
        let environment: String
        let secret: Secret
    }

    let lookups: [Lookup]
    let managedGraphConfiguration: [String: String]

    init(command: String, mode: String, providerEndpoint: String, providerKeyEnvironment: String,
         graphJSON: String, parseGraph: (String) throws -> [String: Any]) throws {
        let graph = ["run", "graph-search", "graph-ingest"].contains(command) ? try parseGraph(graphJSON) : [:]
        let requiresGraph = command == "run" ? graph["enabled"] as? Bool == true : ["graph-search", "graph-ingest"].contains(command)
        let requiresGraphModel = requiresGraph && command != "graph-search"
        let requiresEmbedding = requiresGraph && graph["embedding_backend"] as? String != "fastembed"
        let graphKey = Self.environmentName(graph, key: "api_key_environment", alias: "apiKeyEnvironment", fallback: "OPENAI_API_KEY")
        let embeddingKey = Self.environmentName(graph, key: "embedding_api_key_environment", fallback: graphKey)
        if requiresGraph {
            try Self.validateGraphDestinations(providerEndpoint: providerEndpoint, providerKeyEnvironment: providerKeyEnvironment,
                                               graph: graph, model: requiresGraphModel, embedding: requiresEmbedding)
        }
        var requests: [Lookup] = []
        func add(_ environment: String?, _ secret: Secret) throws {
            guard let environment else { return }
            guard environment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw CredentialPlanError("密钥环境变量名称无效：\(environment)")
            }
            if let existing = requests.first(where: { $0.environment == environment }) {
                guard existing.secret == secret else {
                    throw CredentialPlanError("模型、嵌入或数据库密码不能用同一个环境变量存放不同凭据：\(environment)")
                }
                return
            }
            requests.append(Lookup(environment: environment, secret: secret))
        }
        let providerNeeded = (["run", "agent"].contains(command) && mode == "llm") || command.hasPrefix("provider-")
            || (requiresGraphModel && graphKey == providerKeyEnvironment)
            || (requiresEmbedding && embeddingKey == providerKeyEnvironment)
        if providerNeeded { try add(providerKeyEnvironment, .provider) }
        let backend = graph["backend"] as? String ?? "neo4j"
        let passwordEnvironment = Self.environmentName(graph, key: "password_environment", fallback: backend == "neo4j" ? "NEO4J_PASSWORD" : nil)
        if requiresGraph {
            try add(passwordEnvironment, .graphPassword)
            if requiresEmbedding, embeddingKey != providerKeyEnvironment { try add(embeddingKey, .embedding) }
        }
        lookups = requests
        var managed: [String: String] = ["backend": backend]
        if let uri = graph["uri"] as? String { managed["uri"] = uri }
        if let passwordEnvironment { managed["password_environment"] = passwordEnvironment }
        managedGraphConfiguration = managed
    }

    /// Existing nonempty process credentials always win. This function never
    /// returns or prints the inherited values; only new environment additions.
    func additions(inherited: [String: String], load: (Secret) throws -> String) throws -> [String: String] {
        var result: [String: String] = [:]
        for lookup in lookups where inherited[lookup.environment]?.isEmpty != false {
            let value = try load(lookup.secret)
            if !value.isEmpty { result[lookup.environment] = value }
        }
        return result
    }

    static func validateGraphDestinations(providerEndpoint: String, providerKeyEnvironment: String,
                                          graph: [String: Any], model: Bool = true, embedding: Bool = true) throws {
        let graphKey = environmentName(graph, key: "api_key_environment", alias: "apiKeyEnvironment", fallback: "OPENAI_API_KEY")
        let endpoint = graph["endpoint"] as? String ?? "https://api.openai.com/v1"
        var destinations: [(String?, String)] = model ? [(graphKey, endpoint)] : []
        if embedding && graph["embedding_backend"] as? String != "fastembed" {
            destinations.append((environmentName(graph, key: "embedding_api_key_environment", fallback: graphKey),
                                 graph["embedding_endpoint"] as? String ?? endpoint))
        }
        for (environment, destination) in destinations where environment == providerKeyEnvironment {
            if normalized(destination) != normalized(providerEndpoint) {
                throw CredentialPlanError("Graphiti 或嵌入服务与研读服务地址不同，不能共用当前密钥环境变量。请更新地址，或配置独立的凭据环境变量。")
            }
        }
        for (environment, destination) in destinations {
            guard let environment else { continue }
            if destinations.contains(where: { $0.0 == environment && normalized($0.1) != normalized(destination) }) {
                throw CredentialPlanError("Graphiti 与嵌入服务地址不同，不能共用同一个密钥环境变量。请为不同服务配置独立凭据。")
            }
        }
    }

    private static func normalized(_ endpoint: String) -> String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Match Python config.get precedence, including explicit null/no-key.
    private static func environmentName(_ value: [String: Any], key: String, alias: String? = nil, fallback: String?) -> String? {
        if let raw = value[key] { return (raw as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let alias, let raw = value[alias] { return (raw as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return fallback
    }
}

private struct CredentialPlanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
