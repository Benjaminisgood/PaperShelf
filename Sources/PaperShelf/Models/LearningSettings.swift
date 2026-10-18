import Foundation
import PaperCore

struct LearningSettings: Codable {
    var pythonPath = ""
    var backendPath = ""
    var mode = "offline"
    var baseURL = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    var model = "qwen3.7-plus"
    var apiKeyEnvironment = "PAPERSHELF_API_KEY"
    var readerContext = ""
    var automaticallyGenerate = false
    var fields = ExtractionField.defaults
    var graphitiJSON = "{}"
    var paper2agentJSON = "{}"
    var providerJSON = "{\"stream\": true, \"timeout\": 240, \"extra_body\": {\"enable_thinking\": false}}"
    var chunkCharacters = 3000

    init() {}
    private enum CodingKeys: String, CodingKey {
        case pythonPath, backendPath, mode, baseURL, model, apiKeyEnvironment, readerContext, automaticallyGenerate, fields
        case graphitiJSON, paper2agentJSON, providerJSON, chunkCharacters
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pythonPath = try values.decodeIfPresent(String.self, forKey: .pythonPath) ?? pythonPath
        backendPath = try values.decodeIfPresent(String.self, forKey: .backendPath) ?? backendPath
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? mode
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? model
        apiKeyEnvironment = try values.decodeIfPresent(String.self, forKey: .apiKeyEnvironment) ?? apiKeyEnvironment
        readerContext = try values.decodeIfPresent(String.self, forKey: .readerContext) ?? readerContext
        automaticallyGenerate = try values.decodeIfPresent(Bool.self, forKey: .automaticallyGenerate) ?? automaticallyGenerate
        fields = try values.decodeIfPresent([ExtractionField].self, forKey: .fields) ?? fields
        graphitiJSON = try values.decodeIfPresent(String.self, forKey: .graphitiJSON) ?? graphitiJSON
        paper2agentJSON = try values.decodeIfPresent(String.self, forKey: .paper2agentJSON) ?? paper2agentJSON
        providerJSON = try values.decodeIfPresent(String.self, forKey: .providerJSON) ?? providerJSON
        chunkCharacters = try values.decodeIfPresent(Int.self, forKey: .chunkCharacters) ?? chunkCharacters
    }
}
