import Foundation

@main struct CredentialPlanDirectSettingsCheck {
    static func main() throws {
        let providerEndpoint = "https://reading.example.test/v1"
        let providerEnvironment = "PAPERSHELF_API_KEY"
        let graphEnvironment = "PAPERSHELF_GRAPH_API_KEY"
        let embeddingEnvironment = "PAPERSHELF_EMBEDDING_API_KEY"

        func plan(_ command: String, mode: String = "llm", graph: [String: Any] = [:]) throws -> CredentialPlan {
            try CredentialPlan(command: command, mode: mode, providerEndpoint: providerEndpoint,
                               providerKeyEnvironment: providerEnvironment, graphJSON: "fixture-only") { _ in graph }
        }
        func mustReject(_ graph: [String: Any]) {
            do { _ = try plan("graph-ingest", graph: graph); preconditionFailure("Invalid destinations must be rejected") }
            catch { }
        }

        let reading = try plan("provider-probe")
        precondition(reading.lookups == [.init(environment: providerEnvironment, secret: .provider)])
        var reads: [CredentialPlan.Secret] = []
        let saved = try reading.additions(inherited: [providerEnvironment: "fixture-inherited"]) {
            reads.append($0)
            return "fixture-saved"
        }
        precondition(saved == [providerEnvironment: "fixture-saved"] && reads == [.provider])
        let inherited = [providerEnvironment: "fixture-inherited"]
        let noSaved = try reading.additions(inherited: inherited) { _ in "" }
        precondition(inherited.merging(noSaved) { _, new in new } == inherited)
        let noCredential = try reading.additions(inherited: [:]) { _ in "" }
        precondition(noCredential.isEmpty)
        struct UnavailableCredential: Error { }
        let unavailable = try reading.additions(inherited: inherited) { _ in throw UnavailableCredential() }
        precondition(inherited.merging(unavailable) { _, new in new } == inherited)
        for missingFallback in [[:], [providerEnvironment: ""], ["UNRELATED_API_KEY": "fixture-unrelated"]] {
            do {
                _ = try reading.additions(inherited: missingFallback) { _ in throw UnavailableCredential() }
                preconditionFailure("Credential read failure without the matching inherited value must surface")
            } catch is UnavailableCredential { }
        }

        var graph: [String: Any] = ["enabled": true, "backend": "neo4j", "uri": "bolt://graph.example.test:7687",
                                    "endpoint": "https://graph.example.test/v1", "api_key_environment": graphEnvironment,
                                    "embedding_backend": "fastembed", "password_environment": "PAPERSHELF_GRAPH_PASSWORD"]
        let independent = try plan("run", graph: graph)
        precondition(independent.lookups == [
            .init(environment: providerEnvironment, secret: .provider),
            .init(environment: "PAPERSHELF_GRAPH_PASSWORD", secret: .graphPassword),
            .init(environment: graphEnvironment, secret: .graphProvider)
        ])
        let values: [CredentialPlan.Secret: String] = [.provider: "fixture-reading", .graphProvider: "fixture-graph",
                                                      .graphPassword: "fixture-password", .embedding: "fixture-embedding"]
        let populated = try independent.additions(inherited: [:]) { values[$0] ?? "" }
        precondition(populated[graphEnvironment] == values[.graphProvider])
        precondition(populated["PAPERSHELF_GRAPH_PASSWORD"] == values[.graphPassword])
        precondition(populated[embeddingEnvironment] == nil)

        let localSearch = try plan("graph-search", graph: graph)
        precondition(localSearch.lookups == [.init(environment: "PAPERSHELF_GRAPH_PASSWORD", secret: .graphPassword)])
        graph["embedding_backend"] = "openai"
        let sharedSearch = try plan("graph-search", graph: graph)
        precondition(sharedSearch.lookups == [
            .init(environment: "PAPERSHELF_GRAPH_PASSWORD", secret: .graphPassword),
            .init(environment: graphEnvironment, secret: .graphProvider)
        ])
        let sharedIngest = try plan("graph-ingest", graph: graph)
        precondition(sharedIngest.lookups == sharedSearch.lookups)
        graph["embedding_api_key_environment"] = embeddingEnvironment
        graph["embedding_endpoint"] = "https://embedding.example.test/v1"
        let separateIngest = try plan("graph-ingest", graph: graph)
        precondition(separateIngest.lookups == [
            .init(environment: "PAPERSHELF_GRAPH_PASSWORD", secret: .graphPassword),
            .init(environment: graphEnvironment, secret: .graphProvider),
            .init(environment: embeddingEnvironment, secret: .embedding)
        ])
        let separateSearch = try plan("graph-search", graph: graph)
        precondition(separateSearch.lookups == [
            .init(environment: "PAPERSHELF_GRAPH_PASSWORD", secret: .graphPassword),
            .init(environment: embeddingEnvironment, secret: .embedding)
        ])

        for command in ["doctor", "build", "list"] {
            let unrelated = try CredentialPlan(command: command, mode: "llm", providerEndpoint: providerEndpoint,
                                               providerKeyEnvironment: providerEnvironment, graphJSON: "unfinished") { _ in
                preconditionFailure("Unrelated commands must not inspect Graphiti settings")
            }
            precondition(unrelated.lookups.isEmpty)
            _ = try unrelated.additions(inherited: [:]) { _ in preconditionFailure("No unrelated credential reads") }
        }
        graph["enabled"] = false
        let offline = try plan("run", mode: "offline", graph: graph)
        precondition(offline.lookups.isEmpty)

        graph["api_key_environment"] = providerEnvironment
        mustReject(graph)
        graph["endpoint"] = providerEndpoint + "/"
        let matchingEndpoint = try plan("graph-ingest", graph: graph)
        precondition(matchingEndpoint.lookups.contains(.init(environment: providerEnvironment, secret: .provider)))
        graph["embedding_api_key_environment"] = providerEnvironment
        mustReject(graph)
        graph["embedding_endpoint"] = providerEndpoint
        graph["password_environment"] = providerEnvironment
        mustReject(graph)
        graph["password_environment"] = "INVALID-NAME"
        mustReject(graph)

        graph = ["backend": "falkordb", "api_key_environment": NSNull(), "embedding_api_key_environment": NSNull(),
                 "password_environment": NSNull()]
        let anonymous = try plan("graph-ingest", graph: graph)
        precondition(anonymous.lookups.isEmpty)
        precondition(CredentialPlan.Secret.allCases.count == 4)
        print("Direct settings credential routing passed: saved priority, environment fallback, independent Graphiti key, embedding reuse, command scoping, and destination validation.")
    }
}
