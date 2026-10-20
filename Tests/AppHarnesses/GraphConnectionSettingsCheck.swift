import Foundation

@main struct GraphConnectionSettingsCheck {
    static func main() throws {
        let endpoint = "https://reading.example/v1"
        let model = "reading-model"
        let environment = "READING_KEY"
        var fresh = try GraphConnectionSettings(json: "{}")
        precondition(fresh.usesLocalDatabase && fresh.usesLocalEmbedding && !fresh.enabled)
        fresh.prepareForEditing(endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        fresh.set("enabled", true)
        precondition(fresh.string("uri") == GraphConnectionSettings.localURI)
        precondition(fresh.string("api_key_environment") == environment)
        precondition(fresh.values["use_main_model"] as? Bool == true)
        fresh.setUsesMainModel(false, endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        precondition(fresh.string("api_key_environment") == "PAPERSHELF_GRAPH_API_KEY")
        fresh.setUsesLocalEmbedding(false)
        precondition(fresh.string("embedding_api_key_environment") == "PAPERSHELF_EMBEDDING_API_KEY")
        precondition(fresh.integer("embedding_dimensions", fallback: 0) == 1536)

        let legacy = #"{"enabled":true,"backend":"neo4j","uri":"neo4j+s://graph.example","user":"researcher","password_environment":"CUSTOM_PASSWORD","endpoint":"https://graph.example/v1","model":"graph-model","small_model":"small-graph-model","api_key_environment":"CUSTOM_GRAPH_KEY","embedding_endpoint":"https://embedding.example/v1","embedding_model":"custom-embedding","embedding_api_key_environment":"CUSTOM_EMBEDDING_KEY","embedding_dimensions":1024,"entity_types":{"Catalyst":{"description":"retain this","fields":[]}},"max_coroutines":2}"#
        var custom = try GraphConnectionSettings(json: legacy)
        precondition(!custom.usesMainModel(endpoint: endpoint, model: model, apiKeyEnvironment: environment))
        precondition(!custom.usesLocalEmbedding && !custom.usesLocalDatabase)
        let unchanged = try GraphConnectionSettings.synchronizingMainModel(in: legacy, endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        precondition(unchanged == legacy)
        let customSmallModel = #"{"endpoint":"https://reading.example/v1","model":"reading-model","small_model":"separate-small-model","api_key_environment":"READING_KEY"}"#
        let preservedSmallModel = try GraphConnectionSettings.synchronizingMainModel(in: customSmallModel,
            endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        precondition(preservedSmallModel == customSmallModel)
        let otherLocalDatabase = try GraphConnectionSettings(json: #"{"uri":"bolt://localhost:17687"}"#)
        precondition(!otherLocalDatabase.usesLocalDatabase, "Automatic credentials must match the managed service URI")
        let customLocalPassword = try GraphConnectionSettings(json: #"{"uri":"bolt://127.0.0.1:17687","password_environment":"CUSTOM_PASSWORD"}"#)
        precondition(!customLocalPassword.usesLocalDatabase)
        custom.prepareForEditing(endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        custom.setUsesMainModel(true, endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        let syncedJSON = try GraphConnectionSettings.synchronizingMainModel(in: custom.json(), endpoint: "https://updated.example/v1", model: "updated-model", apiKeyEnvironment: "UPDATED_KEY")
        var synced = try GraphConnectionSettings(json: syncedJSON)
        precondition(synced.string("endpoint") == "https://updated.example/v1")
        precondition(synced.string("model") == "updated-model")
        synced.setUsesMainModel(false, endpoint: endpoint, model: model, apiKeyEnvironment: environment)
        precondition(synced.string("endpoint") == "https://graph.example/v1")
        precondition(synced.string("model") == "graph-model")
        precondition(synced.string("small_model") == "small-graph-model")
        precondition(synced.string("api_key_environment") == "CUSTOM_GRAPH_KEY")
        synced.setUsesLocalDatabase(true)
        precondition(synced.string("uri") == GraphConnectionSettings.localURI)
        synced.setUsesLocalDatabase(false)
        precondition(synced.string("uri") == "neo4j+s://graph.example")
        precondition(synced.string("user") == "researcher")
        precondition(synced.string("password_environment") == "CUSTOM_PASSWORD")
        synced.setUsesLocalEmbedding(true)
        precondition(synced.usesLocalEmbedding)
        synced.setUsesLocalEmbedding(false)
        precondition(!synced.usesLocalEmbedding)
        precondition(synced.string("embedding_endpoint") == "https://embedding.example/v1")
        precondition(synced.integer("embedding_dimensions", fallback: 0) == 1024)
        precondition(synced.values["entity_types"] is [String: Any])
        precondition(synced.integer("max_coroutines", fallback: 0) == 2)
        let prepared = try GraphConnectionSettings.preparingCredentials(in: synced.json(), graphKeyChanged: true,
                                                                       embeddingKeyChanged: true, passwordChanged: true)
        let credentials = try GraphConnectionSettings(json: prepared)
        precondition(credentials.string("api_key_environment") == "PAPERSHELF_GRAPH_API_KEY")
        precondition(credentials.string("embedding_api_key_environment") == "PAPERSHELF_EMBEDDING_API_KEY")
        precondition(credentials.string("password_environment") == "CUSTOM_PASSWORD")
        precondition(credentials.values["entity_types"] is [String: Any])
        let legacyShared = #"{"endpoint":"https://reading.example/v1/","model":"reading-model","api_key_environment":"READING_KEY","entity_types":{}}"#
        let migrated = try GraphConnectionSettings(json: GraphConnectionSettings.synchronizingMainModel(in: legacyShared,
                                      endpoint: endpoint, model: model, apiKeyEnvironment: environment))
        precondition(migrated.values["use_main_model"] as? Bool == true)
        do {
            _ = try GraphConnectionSettings(json: "unfinished")
            preconditionFailure("Invalid advanced JSON must not be silently replaced")
        } catch {}
        print("Graph form defaults, model synchronization, custom-connection round trips and advanced-option preservation passed.")
    }
}
