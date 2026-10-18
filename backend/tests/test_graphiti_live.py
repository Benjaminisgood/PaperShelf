"""Opt-in Graphiti/Neo4j integration test using an explicit synthetic model server.

This verifies the real SDK, HTTP protocol, graph persistence and search. It does
not evaluate an AI model or scientific extraction quality.
"""
import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import uuid

from papershelf_pipeline.integrations import graphiti_ingest, graphiti_search, _field_key, _decoded_value


FACT = "Synthetic catalyst Pt-A is supported by synthetic support Silica-B."


class SyntheticModelHandler(BaseHTTPRequestHandler):
    calls = []
    edge_calls = 0

    def log_message(self, *_arguments):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.calls.append(self.path)
        if self.path.endswith("/embeddings"):
            inputs = request["input"]
            count = 1 if isinstance(inputs, str) else len(inputs)
            body = {"object": "list", "model": "synthetic-embedding",
                    "data": [{"object": "embedding", "index": index,
                              "embedding": [1.0] + [0.0] * 1535} for index in range(count)],
                    "usage": {"prompt_tokens": count, "total_tokens": count}}
        else:
            schema = request.get("response_format", {}).get("json_schema", {})
            name = schema.get("name")
            if name == "ExtractedEntities":
                answer = {"extracted_entities": [{"name": name, "entity_type_id": 1, "episode_indices": [0]}
                                                 for name in ("Pt-A", "Silica-B")]}
            elif name == "ExtractedEdges":
                type(self).edge_calls += 1
                answer = {"edges": [{"source_entity_name": "Pt-A", "target_entity_name": "Silica-B",
                                     "relation_type": "SUPPORTED_BY", "fact": FACT,
                                     "valid_at": "2026-10-18T00:00:00Z", "invalid_at": None,
                                     "episode_indices": [0]}]}
                if type(self).edge_calls == 1:
                    # A compatible online provider really returned a wrong key.
                    # The adapter must request a complete corrected response.
                    answer["edges"][0]["wrong_source_key"] = answer["edges"][0].pop("source_entity_name")
            elif name == "SummarizedEntities":
                answer = {"summaries": [{"name": name, "summary": FACT} for name in ("Pt-A", "Silica-B")]}
            elif name == "NodeResolutions":
                answer = {"entity_resolutions": [{"id": index, "name": name, "duplicate_candidate_id": -1}
                                                  for index, name in enumerate(("Pt-A", "Silica-B"))]}
            elif name == "PaperRecord":
                answer = {_field_key("产率 (%)"): 88.2, "实验条件": {"温度": 373, "气氛": "Ar"}}
            else:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": f"Unsupported synthetic response model: {name}"}).encode())
                return
            body = {"id": "synthetic-response", "object": "chat.completion", "created": 1,
                    "model": "synthetic-chat", "choices": [{"index": 0, "finish_reason": "stop",
                    "message": {"role": "assistant", "content": json.dumps(answer)}}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


@unittest.skipUnless(os.environ.get("PAPERSHELF_TEST_NEO4J_URI"), "requires explicit QA Neo4j service")
class LiveGraphitiTests(unittest.TestCase):
    def test_real_ingestion_deduplication_search_and_temporal_provenance(self):
        group = "papershelf_test_" + uuid.uuid4().hex
        SyntheticModelHandler.calls = []
        SyntheticModelHandler.edge_calls = 0
        server = ThreadingHTTPServer(("127.0.0.1", 0), SyntheticModelHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        config = {"uri": os.environ["PAPERSHELF_TEST_NEO4J_URI"], "user": "neo4j",
                  "password_environment": "PAPERSHELF_TEST_NEO4J_PASSWORD", "group_id": group,
                  "endpoint": f"http://127.0.0.1:{server.server_port}/v1", "api_key_environment": None,
                  "model": "synthetic-chat", "embedding_model": "synthetic-embedding",
                  "entity_fields": [{"name": "产率 (%)", "type": "number"},
                    {"name": "实验条件", "type": "object", "properties": {
                        "温度": {"type": "number"}, "气氛": {"type": "string", "enum": ["Ar", "He"]}}}]}
        try:
            with tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / "synthetic.md"
                source.write_text(FACT + "\nThis is synthetic software test data, not a research claim.")
                first = graphiti_ingest(source, {"title": "Synthetic test"}, config)
                second = graphiti_ingest(source, {"title": "Synthetic test"}, config)
                self.assertEqual(first["episodes"][0]["status"], "ingested")
                self.assertEqual(first["episodes"][0]["nodes"], 2)
                self.assertEqual(first["episodes"][0]["edges"], 1)
                self.assertEqual(SyntheticModelHandler.edge_calls, 2)
                self.assertEqual(second["episodes"][0]["status"], "existing")
                self.assertEqual(first["episodes"][0]["extraction_snapshot"], second["episodes"][0]["extraction_snapshot"])
                self.assertEqual(first["episodes"][0]["extraction_snapshot"]["extraction_fingerprint"], first["extraction_fingerprint"])
                results = graphiti_search("Pt-A Silica-B supported", config)
                self.assertTrue(results["facts"])
                fact = results["facts"][0]
                self.assertEqual(fact["fact"], FACT)
                self.assertEqual(fact["group_id"], group)
                self.assertIn(first["episodes"][0]["uuid"], fact["episodes"])
                self.assertEqual(fact["sources"][0]["content"], source.read_text())
                self.assertEqual(fact["sources"][0]["metadata"]["title"], "Synthetic test")
                self.assertIsNotNone(fact["valid_at"])
                self.assertTrue(any(path.endswith("/embeddings") for path in SyntheticModelHandler.calls))
                self.assertTrue(any(path.endswith("/chat/completions") for path in SyntheticModelHandler.calls))
                async def read_properties():
                    from neo4j import AsyncGraphDatabase
                    async with AsyncGraphDatabase.driver(config["uri"], auth=("neo4j", os.environ["PAPERSHELF_TEST_NEO4J_PASSWORD"])) as driver:
                        records, _, _ = await driver.execute_query("MATCH (n:Entity {group_id: $group}) RETURN properties(n) AS properties", group=group)
                        return [record["properties"] for record in records]
                properties = asyncio.run(read_properties())
                self.assertEqual(len(properties), 2)
                self.assertEqual(_decoded_value(properties[0]["实验条件"]), {"温度": 373, "气氛": "Ar"})
                self.assertEqual(properties[0][_field_key("产率 (%)")], 88.2)
                snapshot_nodes = first["episodes"][0]["extraction_snapshot"]["nodes"]
                self.assertEqual(_decoded_value(snapshot_nodes[0]["attributes"]["实验条件"]), {"温度": 373, "气氛": "Ar"})
        finally:
            server.shutdown()
            server.server_close()
            async def cleanup():
                from neo4j import AsyncGraphDatabase
                async with AsyncGraphDatabase.driver(config["uri"], auth=("neo4j", os.environ["PAPERSHELF_TEST_NEO4J_PASSWORD"])) as driver:
                    await driver.execute_query("MATCH (n {group_id: $group}) DETACH DELETE n", group=group)
            asyncio.run(cleanup())


if __name__ == "__main__":
    unittest.main()
