import Foundation

/// Form edits change only their own keys; advanced Graphiti options survive.
struct GraphConnectionSettings {
    static let localURI = "bolt://127.0.0.1:17687"
    static let localEmbeddingModel = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    private(set) var values: [String: Any]

    init(json: String) throws {
        let data = Data((json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : json).utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphConnectionSettingsError("图谱高级配置须为 JSON 对象。")
        }
        values = object
    }

    var enabled: Bool { values["enabled"] as? Bool ?? false }
    var backend: String { string("backend", fallback: "neo4j") }
    var usesLocalDatabase: Bool {
        values.isEmpty || (backend == "neo4j" && string("uri") == Self.localURI
            && string("user", fallback: "neo4j") == "neo4j"
            && string("password_environment", fallback: "NEO4J_PASSWORD") == "NEO4J_PASSWORD")
    }
    var usesLocalEmbedding: Bool {
        string("embedding_backend", fallback: values.isEmpty ? "fastembed" : "openai") == "fastembed"
    }

    func string(_ key: String, fallback: String = "") -> String { values[key] as? String ?? fallback }
    func integer(_ key: String, fallback: Int) -> Int { values[key] as? Int ?? fallback }

    func usesMainModel(endpoint: String, model: String, apiKeyEnvironment: String) -> Bool {
        if let explicit = values["use_main_model"] as? Bool { return explicit }
        if values.isEmpty { return true }
        return normalized(string("endpoint")) == normalized(endpoint)
            && string("model") == model
            && string("small_model", fallback: model) == model
            && string("api_key_environment", fallback: string("apiKeyEnvironment", fallback: "OPENAI_API_KEY")) == apiKeyEnvironment
    }

    mutating func prepareForEditing(endpoint: String, model: String, apiKeyEnvironment: String) {
        if values.isEmpty {
            values = [
                "enabled": false, "backend": "neo4j", "uri": Self.localURI, "user": "neo4j",
                "password_environment": "NEO4J_PASSWORD", "group_id": "papershelf",
                "provider": "openai-compatible", "endpoint": endpoint, "model": model,
                "small_model": model, "api_key_environment": apiKeyEnvironment, "use_main_model": true,
                "extra_body": ["enable_thinking": false], "timeout_seconds": 240, "omit_temperature": true,
                "structured_output_mode": "json_object", "embedding_backend": "fastembed",
                "local_embedding_model": Self.localEmbeddingModel, "embedding_dimensions": 384,
                "episode_characters": 12000
            ]
        } else if values["use_main_model"] == nil {
            values["use_main_model"] = usesMainModel(endpoint: endpoint, model: model, apiKeyEnvironment: apiKeyEnvironment)
        }
    }

    mutating func set(_ key: String, _ value: Any) { values[key] = value }

    mutating func setUsesMainModel(_ useMain: Bool, endpoint: String, model: String, apiKeyEnvironment: String) {
        let wasMain = usesMainModel(endpoint: endpoint, model: model, apiKeyEnvironment: apiKeyEnvironment)
        if useMain && !wasMain {
            values["papershelf_custom_model"] = snapshot(Self.modelKeys)
        } else if !useMain && wasMain {
            if let custom = values["papershelf_custom_model"] as? [String: Any] {
                restore(custom, keys: Self.modelKeys)
            } else {
                values["api_key_environment"] = "PAPERSHELF_GRAPH_API_KEY"
                values.removeValue(forKey: "apiKeyEnvironment")
            }
        }
        values["use_main_model"] = useMain
        if useMain { synchronizeModel(endpoint: endpoint, model: model, apiKeyEnvironment: apiKeyEnvironment) }
    }

    mutating func setUsesLocalDatabase(_ local: Bool) {
        let wasLocal = usesLocalDatabase
        if local && !wasLocal {
            values["papershelf_custom_database"] = snapshot(Self.databaseKeys)
            values["backend"] = "neo4j"
            values["uri"] = Self.localURI
            values["user"] = "neo4j"
            values["password_environment"] = "NEO4J_PASSWORD"
        } else if !local && wasLocal {
            if let custom = values["papershelf_custom_database"] as? [String: Any] {
                restore(custom, keys: Self.databaseKeys)
            } else {
                values["backend"] = "neo4j"
                values["uri"] = "bolt://localhost:7687"
                values["password_environment"] = "NEO4J_PASSWORD"
            }
        }
    }

    mutating func setUsesLocalEmbedding(_ local: Bool) {
        let wasLocal = usesLocalEmbedding
        if local && !wasLocal {
            values["papershelf_custom_embedding"] = snapshot(Self.embeddingKeys)
            values["embedding_backend"] = "fastembed"
            if values["local_embedding_model"] == nil { values["local_embedding_model"] = Self.localEmbeddingModel }
            values["embedding_dimensions"] = 384
        } else if !local && wasLocal {
            if let custom = values["papershelf_custom_embedding"] as? [String: Any] {
                restore(custom, keys: Self.embeddingKeys)
            } else {
                values["embedding_backend"] = "openai"
                values["embedding_endpoint"] = "https://api.openai.com/v1"
                values["embedding_model"] = "text-embedding-3-small"
                values["embedding_dimensions"] = 1536
                values["embedding_api_key_environment"] = "PAPERSHELF_EMBEDDING_API_KEY"
            }
        }
    }

    func json() throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func synchronizingMainModel(in json: String, endpoint: String, model: String, apiKeyEnvironment: String) throws -> String {
        var configuration = try Self(json: json)
        guard !configuration.values.isEmpty,
              configuration.usesMainModel(endpoint: endpoint, model: model, apiKeyEnvironment: apiKeyEnvironment) else { return json }
        configuration.values["use_main_model"] = true
        configuration.synchronizeModel(endpoint: endpoint, model: model, apiKeyEnvironment: apiKeyEnvironment)
        return try configuration.json()
    }

    static func preparingCredentials(in json: String, graphKeyChanged: Bool, embeddingKeyChanged: Bool, passwordChanged: Bool) throws -> String {
        guard graphKeyChanged || embeddingKeyChanged || passwordChanged else { return json }
        var configuration = try Self(json: json)
        if graphKeyChanged && configuration.values["use_main_model"] as? Bool != true {
            configuration.values["api_key_environment"] = "PAPERSHELF_GRAPH_API_KEY"
            configuration.values.removeValue(forKey: "apiKeyEnvironment")
        }
        if embeddingKeyChanged { configuration.values["embedding_api_key_environment"] = "PAPERSHELF_EMBEDDING_API_KEY" }
        if passwordChanged && configuration.string("password_environment").isEmpty {
            configuration.values["password_environment"] = "NEO4J_PASSWORD"
        }
        return try configuration.json()
    }

    private mutating func synchronizeModel(endpoint: String, model: String, apiKeyEnvironment: String) {
        values["endpoint"] = endpoint
        values["model"] = model
        values["small_model"] = model
        values["api_key_environment"] = apiKeyEnvironment
        values.removeValue(forKey: "apiKeyEnvironment")
    }

    private func snapshot(_ keys: [String]) -> [String: Any] {
        values.filter { keys.contains($0.key) }
    }

    private mutating func restore(_ snapshot: [String: Any], keys: [String]) {
        for key in keys { values.removeValue(forKey: key) }
        for (key, value) in snapshot { values[key] = value }
    }

    private func normalized(_ endpoint: String) -> String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static let modelKeys = ["endpoint", "model", "small_model", "api_key_environment", "apiKeyEnvironment"]
    private static let databaseKeys = ["backend", "uri", "user", "password_environment", "host", "port", "database"]
    private static let embeddingKeys = ["embedding_backend", "embedding_endpoint", "embedding_model", "embedding_dimensions", "embedding_api_key_environment"]
}

private struct GraphConnectionSettingsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
