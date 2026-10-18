import XCTest
@testable import PaperCore

final class LearningModelsTests: XCTestCase {
    func testFieldImportDefaultsAndEnums() throws {
        let data = Data("""
        [{"name":"catalyst","type":"string","enum":["A","B"]},{"name":"temperature","type":"number","unit":"K"}]
        """.utf8)
        let fields = try JSONDecoder().decode([ExtractionField].self, from: data)
        try ExtractionField.validate(fields)
        XCTAssertEqual(fields[0].choices, ["A", "B"])
        XCTAssertFalse(fields[0].required)
        XCTAssertEqual(fields[1].unit, "K")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) as! [[String: Any]]
        XCTAssertEqual(encoded[0]["enum"] as? [String], ["A", "B"])
    }
    func testDuplicateNamesRejectedBeforeRunning() {
        XCTAssertThrowsError(try ExtractionField.validate([.init(name: "rate"), .init(name: "rate", type: "number")]))
        XCTAssertThrowsError(try ExtractionField.validate([.init(name: " " )]))
        XCTAssertThrowsError(try ExtractionField.validate([.init(name: "field", type: "unsupported")]))
    }
    func testNestedSchemaAndNumericEnumSurviveImportExport() throws {
        let data = Data("""
        [{"name":"temperature","type":"integer","enum":[300,400]},
         {"name":"samples","type":"array","items":{"type":"object","properties":{"name":{"type":"string"}}}}]
        """.utf8)
        let fields = try JSONDecoder().decode([ExtractionField].self, from: data)
        try ExtractionField.validate(fields)
        let decoded = try JSONDecoder().decode([ExtractionField].self, from: JSONEncoder().encode(fields))
        XCTAssertEqual(decoded[0].constraints["enum"], .array([.number(300), .number(400)]))
        XCTAssertEqual(decoded[1].constraints["items"], fields[1].constraints["items"])
    }
    func testRunHistoryRoundTripsSeparateFromLibrary() throws {
        let run = LearningRun(referenceID: "reference", title: "示例", runID: "run", directory: "/tmp/run",
                              manifestPath: "/tmp/run/manifest.json", artifacts: ["html": "/tmp/run/guide.html"],
                              warnings: ["需核实图表"], mode: "offline")
        let decoded = try JSONDecoder().decode([LearningRun].self, from: JSONEncoder().encode([run]))
        XCTAssertEqual(decoded.first?.referenceID, "reference")
        XCTAssertEqual(decoded.first?.artifacts["html"], "/tmp/run/guide.html")
        XCTAssertEqual(decoded.first?.warnings, ["需核实图表"])
    }
    func testRecoverFailedOrInterruptedReceiptWithoutUIHistory() throws {
        let json = Data("""
        {"run_id":"failed-run","reference_id":"paper","title":"论文","status":"failed","mode":"llm","created_at":"2026-10-17T20:00:23.030012+00:00","error":"模型超时","artifacts":{"source":"/tmp/run/source.json"}}
        """.utf8)
        let run = try XCTUnwrap(LearningRun.recover(manifest: json, directory: URL(fileURLWithPath: "/tmp/run")))
        XCTAssertEqual(run.referenceID, "paper")
        XCTAssertEqual(run.statusLabel, "失败")
        XCTAssertEqual(run.warnings, ["模型超时"])
        XCTAssertEqual(run.artifacts["source"], "/tmp/run/source.json")
        XCTAssertLessThan(run.createdAt.timeIntervalSince1970, 1792270000)
        let interrupted = Data("{\"run_id\":\"run\",\"reference_id\":\"paper\",\"status\":\"running\"}".utf8)
        XCTAssertEqual(try LearningRun.recover(manifest: interrupted, directory: URL(fileURLWithPath: "/tmp/run"))?.status, "interrupted")
    }
    func testRevisionHistoryRetainsOriginalForRetry() throws {
        let data = Data("""
        {"run_id":"revision","reference_id":"paper","status":"completed","mode":"llm","revision_of":"/original/manifest.json"}
        """.utf8)
        let run = try XCTUnwrap(LearningRun.recover(manifest: data, directory: URL(fileURLWithPath: "/revision")))
        XCTAssertEqual(run.revisionOf, "/original/manifest.json")
        XCTAssertEqual(run.statusLabel, "AI 校订")
        let restored = try JSONDecoder().decode(LearningRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(restored.revisionOf, run.revisionOf)
    }
    func testSourceReviewedEditionHasDistinctHistoryLabel() throws {
        let data = Data("""
        {"run_id":"review","reference_id":"paper","status":"completed","mode":"llm","revision_of":"/ai/manifest.json","revision_kind":"source_reviewed_revision"}
        """.utf8)
        var run = try XCTUnwrap(LearningRun.recover(manifest: data, directory: URL(fileURLWithPath: "/review")))
        XCTAssertEqual(run.statusLabel, "原页校核版")
        let restored = try JSONDecoder().decode(LearningRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(restored.revisionKind, "source_reviewed_revision")
        run.status = "failed"
        XCTAssertEqual(run.statusLabel, "失败")
    }
}
