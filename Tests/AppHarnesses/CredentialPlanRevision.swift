import Foundation

@main struct CredentialPlanRevisionCheck {
    static func main() throws {
        let plan = try CredentialPlan(command: "revise", mode: "llm", providerEndpoint: "https://example.test/v1",
                                      providerKeyEnvironment: "TEST_READING_KEY", graphJSON: "unfinished graph config") { _ in
            preconditionFailure("Editorial revision must not parse or request Graphiti credentials")
        }
        precondition(plan.lookups == [.init(environment: "TEST_READING_KEY", secret: .provider)])
        var reads = 0
        let additions = try plan.additions(inherited: ["TEST_READING_KEY": "fixture-only"]) { _ in reads += 1; return "" }
        precondition(additions.isEmpty && reads == 0)
        print("Editorial revision requests only the selected provider credential; inherited values remain untouched.")
    }
}
