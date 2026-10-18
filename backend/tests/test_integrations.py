import asyncio
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch

from papershelf_pipeline import integrations as integration


class IntegrationTests(unittest.TestCase):
    def test_chunks_preserve_every_character(self):
        text = ("第一段\n\nA scientific result.\n" * 130) + "最后一行"
        chunks = list(integration._chunks(text, 256))
        self.assertEqual("".join(part for _, part in chunks), text)
        self.assertEqual(chunks[-1][0] + len(chunks[-1][1]), len(text))

    def test_health_does_not_disclose_secrets(self):
        with patch.dict(os.environ, {"PAPERSHELF_TEST_SECRET": "DO-NOT-EXPOSE"}):
            report = integration.integration_status({"graphiti": {"api_key_environment": "PAPERSHELF_TEST_SECRET"}})
        self.assertTrue(report["graphiti"]["key_available"])
        self.assertNotIn("DO-NOT-EXPOSE", json.dumps(report))
        self.assertFalse(report["graphiti"]["connection_tested"])

    def test_bundle_copies_entire_upstream_without_claiming_agent_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paper = root / "paper.md"
            paper.write_text("# Test paper\nFull original source.")
            job = root / "job"
            report = integration.create_paper2agent_bundle(paper, job)
            self.assertEqual(report["status"], "prepared")
            self.assertEqual(report["verification"], "not_run")
            self.assertTrue((job / ".agents/skills/paper2agent/paper2skill/SKILL.md").is_file())
            self.assertTrue((job / ".agents/skills/paper2agent/paper2mcp/SKILL.md").is_file())
            self.assertEqual((job / "input/paper.md").read_text(), paper.read_text())
            with self.assertRaises(integration.IntegrationError):
                integration.create_paper2agent_bundle(paper, job)

    def test_codex_command_keeps_workspace_sandbox(self):
        command = integration._host_command(Path("/tmp/paper job"), {"host": "codex", "host_executable": "/bin/codex"})
        self.assertIn("workspace-write", command)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", command)
        self.assertIn("/tmp/paper job", command)

    @unittest.skipUnless(integration._version("openai"), "optional OpenAI-compatible SDK not installed")
    def test_provider_options_keep_upstream_structured_request_and_reject_credentials(self):
        from types import SimpleNamespace
        completions = SimpleNamespace(create=AsyncMock(return_value="response"))
        client = SimpleNamespace(chat=SimpleNamespace(completions=completions), base_url="http://localhost/v1/")
        with patch("openai.AsyncOpenAI", return_value=client) as constructor:
            configured = integration._configured_chat_client({"extra_body": {"enable_thinking": False}, "timeout_seconds": 240}, "test", "http://localhost/v1")
            result = asyncio.run(configured.chat.completions.create(model="qwen", messages=[], response_format={"type": "json_object"}))
        self.assertEqual(result, "response")
        self.assertEqual(completions.create.await_args.kwargs["extra_body"], {"enable_thinking": False})
        self.assertEqual(completions.create.await_args.kwargs["response_format"], {"type": "json_object"})
        self.assertEqual(constructor.call_args.kwargs["timeout"], 240)
        self.assertEqual(configured.base_url, client.base_url)
        with self.assertRaises(integration.IntegrationError):
            integration._configured_chat_client({"extra_body": {"nested": {"apiKey": "secret"}}}, "test", "http://localhost/v1")

    def test_host_success_is_distinct_from_scientific_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paper = root / "paper.md"
            paper.write_text("A source paper")
            job = root / "job"
            integration.create_paper2agent_bundle(paper, job, {"host_executable": "/usr/bin/true"})
            report = integration._run_job(job)
            self.assertEqual(report["status"], "host_completed")
            self.assertEqual(report["verification"], "review_upstream_reports")

    def test_cancel_stops_only_verified_job_process_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paper = root / "paper.md"
            paper.write_text("A synthetic test paper")
            host = root / "fake-coding-host"
            host.write_text("#!/bin/sh\nsleep 60\n")
            host.chmod(0o700)
            job = root / "job"
            integration.create_paper2agent_bundle(paper, job, {"host_executable": str(host)})
            integration.paper2agent_launch(job)
            for _ in range(100):
                status = integration.paper2agent_status(job)
                if status["status"] == "running":
                    break
                time.sleep(0.02)
            self.assertEqual(status["status"], "running")
            self.assertEqual(integration.paper2agent_cancel(job)["status"], "cancellation_requested")
            for _ in range(100):
                status = integration.paper2agent_status(job)
                if status["status"] == "cancelled":
                    break
                time.sleep(0.02)
            self.assertEqual(status["status"], "cancelled")

    def test_resume_preserves_evidence_and_clears_previous_terminal_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paper = root / "paper.md"
            paper.write_text("Retained source")
            job = root / "job"
            manifest = integration.create_paper2agent_bundle(paper, job)
            manifest.update(status="failed", exit_code=1, finished_at="old-time", error="old-error")
            integration._write_json(job / "job.json", manifest)
            (job / "events.jsonl").write_text("prior evidence\n")
            (job / "final-response.md").write_text("Previous failure result")
            (job / "review").mkdir()
            (job / "review/check.json").write_text('{"reviewed": true}')
            with patch.object(integration, "paper2agent_launch", side_effect=lambda directory, config: json.loads((directory / "job.json").read_text())):
                resumed = integration.paper2agent_resume(job)
            self.assertEqual(resumed["status"], "prepared")
            self.assertEqual((Path(resumed["previous_run"]) / "events.jsonl").read_text(), "prior evidence\n")
            self.assertEqual((Path(resumed["previous_run"]) / "final-response.md").read_text(), "Previous failure result")
            self.assertFalse((job / "final-response.md").exists())
            self.assertEqual((job / "review/check.json").read_text(), '{"reviewed": true}')
            for field in ("exit_code", "finished_at", "error", "worker_live"):
                self.assertNotIn(field, resumed)
            with self.assertRaises(integration.IntegrationError):
                integration.paper2agent_resume(job)


@unittest.skipUnless(integration._version("markitdown"), "pinned MarkItDown runtime not installed")
class MarkItDownTests(unittest.TestCase):
    def test_actual_html_conversion_retains_unicode_and_table(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "paper.html"
            source.write_text('<html><body><h1>催化剂结果</h1><p>Full source preserved</p><table><tr><th>温度</th><th>Rate</th></tr><tr><td>373</td><td>2.5</td></tr></table></body></html>')
            result = integration.convert_with_markitdown(source)
            self.assertIn("催化剂结果", result["markdown"])
            self.assertIn("373", result["markdown"])
            self.assertIn("2.5", result["markdown"])
            self.assertEqual(result["engine"], "markitdown")


@unittest.skipUnless(integration._version("graphiti-core"), "pinned Graphiti runtime not installed")
class GraphitiAdapterTests(unittest.TestCase):
    def test_schema_retry_preserves_full_context_and_does_not_repair_model_output(self):
        from graphiti_core.llm_client.config import LLMConfig
        from graphiti_core.llm_client.openai_generic_client import OpenAIGenericClient
        from graphiti_core.prompts.models import Message
        from pydantic import BaseModel, ValidationError

        class Edge(BaseModel):
            source_entity_name: str
            target_entity_name: str

        class ExtractedEdges(BaseModel):
            edges: list[Edge]

        source = "Retain every original source sentence.\n" * 200
        messages = [Message(role="system", content="Extract relations."), Message(role="user", content=source)]
        invalid = {"edges": [{"source_elementary_reaction": "A", "target_entity_name": "B"}]}
        valid = {"edges": [{"source_entity_name": "A", "target_entity_name": "B"}]}
        client = integration._validated_graph_llm(config=LLMConfig(api_key="test"), client=object())
        with patch.object(OpenAIGenericClient, "_generate_response", AsyncMock(side_effect=[invalid, valid])) as upstream:
            result = asyncio.run(client._generate_response(messages, ExtractedEdges))
        self.assertEqual(result, valid)
        self.assertEqual(upstream.await_count, 2)
        retry_messages = upstream.await_args_list[1].args[0]
        self.assertEqual(retry_messages[1].content, source)
        self.assertIn(json.dumps(invalid), retry_messages[-1].content)
        self.assertIn("source_entity_name", retry_messages[-1].content)
        self.assertEqual(len(messages), 2)
        self.assertEqual(messages[1].content, source)
        self.assertNotIn("source_entity_name", invalid["edges"][0])
        with patch.object(OpenAIGenericClient, "_generate_response", AsyncMock(return_value=invalid)) as upstream:
            with self.assertRaises(ValidationError):
                asyncio.run(client._generate_response(messages, ExtractedEdges))
        self.assertEqual(upstream.await_count, 3)

    def test_custom_fields_use_real_graphiti_pydantic_models(self):
        models = integration._entity_types({"entity_types": {"Catalyst": {"fields": [
            {"name": "temperature", "type": "number"}, {"name": "support", "type": "text"}]}}})
        self.assertEqual(models["Catalyst"](temperature=300, support="silica").temperature, 300)
        self.assertIsNone(models["Catalyst"]().support)

    def test_entity_fields_preserve_nested_types_enum_and_original_names(self):
        model = integration._entity_types({"entity_fields": [
            {"name": "产率 (%)", "type": "number"},
            {"name": "name", "type": "string"},
            {"name": "实验条件", "type": "object", "properties": {
                "温度": {"type": "number"}, "气氛": {"type": "string", "enum": ["Ar", "He"]}},
             "required_properties": ["温度"]},
            {"name": "循环", "type": "array", "items": {"type": "integer"}}]})["PaperRecord"]
        payload = {integration._field_key("产率 (%)"): 88.2, integration._field_key("name"): "Pt",
                   "实验条件": {"温度": 373, "气氛": "Ar"}, "循环": [1, 2]}
        result = model(**payload)
        self.assertEqual(result.实验条件.温度, 373)
        self.assertEqual(model.__papershelf_field_names__[integration._field_key("name")], "name")
        self.assertEqual(model.model_json_schema()["properties"]["循环"]["anyOf"][0]["type"], "array")
        encoded = integration._storage_value(payload["实验条件"])
        self.assertEqual(model(**{**payload, "实验条件": encoded}).实验条件.气氛, "Ar")
        with self.assertRaises(ValueError):
            model(**{**payload, "实验条件": {"温度": 373, "气氛": "N2"}})
        with self.assertRaises(ValueError):
            model(**{**payload, "实验条件": {"气氛": "Ar"}})

    def test_real_sdk_clients_accept_compatible_endpoint(self):
        with patch.dict(os.environ, {"PAPERSHELF_TEST_API": "test", "PAPERSHELF_TEST_DB": "test"}):
            client = integration._graph_client({"uri": "bolt://localhost:7687",
                "password_environment": "PAPERSHELF_TEST_DB", "api_key_environment": "PAPERSHELF_TEST_API",
                "endpoint": "http://127.0.0.1:12345/v1", "model": "test-model"})
            self.assertEqual(str(client.llm_client.client.base_url), "http://127.0.0.1:12345/v1/")
            asyncio.run(client.close())

    def test_token_plan_omits_temperature_and_local_embedding_needs_no_embedding_key(self):
        from openai import NOT_GIVEN
        import numpy as np
        with patch.dict(os.environ, {"PAPERSHELF_TEST_API": "test", "PAPERSHELF_TEST_DB": "test"}), patch("fastembed.TextEmbedding") as embedding:
            embedding.return_value.embed.side_effect = lambda texts: (np.array([float(len(text)), 1.0]) for text in texts)
            client = integration._graph_client({"uri": "bolt://localhost:7687",
                "password_environment": "PAPERSHELF_TEST_DB", "api_key_environment": "PAPERSHELF_TEST_API",
                "endpoint": "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", "model": "auto",
                "embedding_backend": "fastembed", "embedding_api_key_environment": "PAPERSHELF_NONEXISTENT_EMBEDDING_KEY"})
            self.assertIs(client.llm_client.temperature, NOT_GIVEN)
            self.assertEqual(asyncio.run(client.embedder.create_batch(["中文", "all source text"])), [[2.0, 1.0], [15.0, 1.0]])
            self.assertEqual(asyncio.run(client.embedder.create("query")), [5.0, 1.0])
            asyncio.run(client.close())

    def test_ingest_passes_entire_source_and_preserves_provenance(self):
        from graphiti_core.errors import NodeNotFoundError
        from types import SimpleNamespace
        source = "Every source sentence\n" * 100
        client = SimpleNamespace(build_indices_and_constraints=AsyncMock(), close=AsyncMock(),
                                 retrieve_episodes=AsyncMock(return_value=[]),
                                 driver=SimpleNamespace(execute_query=AsyncMock(return_value=([], None, None))))
        client.add_episode = AsyncMock(side_effect=lambda **kwargs: SimpleNamespace(
            episode=SimpleNamespace(uuid=kwargs["uuid"], save=AsyncMock()), nodes=[], edges=[]))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "source.md"
            path.write_text(source)
            with patch.object(integration, "_graph_client", return_value=client), patch(
                "graphiti_core.nodes.EpisodicNode.get_by_uuid", AsyncMock(side_effect=NodeNotFoundError("missing"))), patch(
                "graphiti_core.nodes.EpisodicNode.save", AsyncMock()):
                result = integration.graphiti_ingest(path, {"title": "Study"}, {"episode_characters": 256})
            self.assertEqual("".join(call.kwargs["episode_body"] for call in client.add_episode.await_args_list), source)
            self.assertEqual(result["characters"], len(source))
            self.assertEqual(client.close.await_count, 1)
            first = client.add_episode.await_args_list[0].kwargs
            self.assertEqual(json.loads(first["source_description"])["character_offset"], 0)
            self.assertEqual(first["group_id"], "papershelf")

    def test_changed_custom_schema_creates_a_version_and_preserves_prior_snapshot(self):
        from graphiti_core.errors import NodeNotFoundError
        from graphiti_core.nodes import EntityNode
        from types import SimpleNamespace
        database, snapshots = {}, {}
        node = EntityNode(name="Synthetic material", group_id="papershelf", attributes={"temperature": 300})

        async def get_episode(_driver, episode_uuid):
            if episode_uuid not in database:
                raise NodeNotFoundError("missing")
            return database[episode_uuid]

        async def save_episode(episode, _driver):
            database[episode.uuid] = episode

        async def query(cypher, **parameters):
            if "SET e.papershelf_extraction_snapshot" in cypher:
                snapshots[parameters["uuid"]] = json.loads(parameters["snapshot"])
                return [], None, None
            return [{"snapshot": json.dumps(snapshots[parameters["uuid"]])}], None, None

        async def add_episode(**arguments):
            # Reusing the live entity emulates Graphiti's later entity merge.
            if "method" in arguments["entity_types"]["PaperRecord"].model_fields:
                node.attributes["method"] = "Updated schema value"
            return SimpleNamespace(episode=database[arguments["uuid"]], nodes=[node], edges=[])

        client = SimpleNamespace(build_indices_and_constraints=AsyncMock(), close=AsyncMock(),
                                 retrieve_episodes=AsyncMock(return_value=[]), add_episode=AsyncMock(side_effect=add_episode),
                                 driver=SimpleNamespace(execute_query=AsyncMock(side_effect=query)))
        config = {"entity_fields": [{"name": "temperature", "type": "number"}]}
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.md"
            source.write_text("Synthetic material was measured at 300 K.")
            with patch.object(integration, "_graph_client", return_value=client), patch(
                "graphiti_core.nodes.EpisodicNode.get_by_uuid", new=get_episode), patch(
                "graphiti_core.nodes.EpisodicNode.save", new=save_episode):
                first = integration.graphiti_ingest(source, config=config)
                repeated = integration.graphiti_ingest(source, config={**config, "api_key_environment": "ROTATED_KEY_NAME"})
                second = integration.graphiti_ingest(source, config={"entity_fields": config["entity_fields"] + [{"name": "method", "type": "string"}]})
            first_id, second_id = first["episodes"][0]["uuid"], second["episodes"][0]["uuid"]
            self.assertEqual(repeated["episodes"][0]["uuid"], first_id)
            self.assertEqual(repeated["episodes"][0]["status"], "existing")
            self.assertNotEqual(first_id, second_id)
            self.assertEqual(client.add_episode.await_count, 2)
            self.assertEqual(len(database), 2)
            self.assertEqual(snapshots[first_id]["nodes"][0]["attributes"], {"temperature": 300})
            self.assertEqual(snapshots[second_id]["nodes"][0]["attributes"]["method"], "Updated schema value")
            self.assertEqual(repeated["episodes"][0]["extraction_snapshot"], snapshots[first_id])

    def test_search_returns_complete_sources_only_from_the_selected_group(self):
        from types import SimpleNamespace
        full_text = "All source text retained.\n" * 1500
        inside = {"uuid": "inside", "name": "Source episode", "group_id": "papershelf", "content": full_text,
                  "source_description": json.dumps({"markdown_path": "/local/source.md", "sha256": "abc", "character_offset": 0,
                      "metadata": {"title": "Study", "source_path": "/local/source.pdf"}}),
                  "reference_time": None, "created_at": None}
        outside = {**inside, "uuid": "outside", "group_id": "another-group", "content": "Must not be disclosed"}
        fact = {"group_id": "papershelf", "fact": "Reported fact", "episodes": ["inside", "outside"]}
        foreign_fact = {"group_id": "another-group", "fact": "Must not be disclosed", "episodes": ["outside"]}
        client = SimpleNamespace(close=AsyncMock(), search=AsyncMock(return_value=[
            SimpleNamespace(group_id="papershelf", model_dump=lambda **kwargs: dict(fact)),
            SimpleNamespace(group_id="another-group", model_dump=lambda **kwargs: dict(foreign_fact))]),
            driver=SimpleNamespace(execute_query=AsyncMock(return_value=([inside, outside], None, None))))
        with patch.object(integration, "_graph_client", return_value=client) as constructor:
            result = integration.graphiti_search("query", {"group_id": "papershelf", "embedding_backend": "fastembed", "api_key_environment": "PRIVATE_KEY"})
        self.assertIsNone(constructor.call_args.args[0]["api_key_environment"])
        self.assertEqual(len(result["facts"]), 1)
        self.assertEqual(result["facts"][0]["episodes"], ["inside"])
        self.assertEqual(result["facts"][0]["sources"][0]["content"], full_text)
        self.assertEqual(result["facts"][0]["sources"][0]["source_path"], "/local/source.pdf")
        self.assertNotIn("Must not be disclosed", json.dumps(result))
        self.assertEqual(client.driver.execute_query.await_args.kwargs["group"], "papershelf")
        self.assertEqual(client.close.await_count, 1)

    def test_remote_embedding_search_keeps_embedding_key_without_requiring_llm_key(self):
        from types import SimpleNamespace
        for config, expected in [
            ({"api_key_environment": "MODEL_KEY", "embedding_api_key_environment": "EMBED_KEY"}, "EMBED_KEY"),
            ({"apiKeyEnvironment": "LEGACY_KEY"}, "LEGACY_KEY"),
            ({}, "OPENAI_API_KEY"),
            ({"embedding_api_key_environment": None}, None)]:
            with self.subTest(config=config):
                client = SimpleNamespace(search=AsyncMock(return_value=[]), close=AsyncMock())
                with patch.object(integration, "_graph_client", return_value=client) as constructor:
                    integration.graphiti_search("query", config)
                selected = constructor.call_args.args[0]
                self.assertIsNone(selected["api_key_environment"])
                self.assertEqual(selected["embedding_api_key_environment"], expected)

    def test_search_warns_on_nonwhitespace_controls_without_altering_source_or_fact(self):
        from types import SimpleNamespace
        for content, warning_expected in [("Ea = 14.54 kcal mol\x031", True), ("ordinary\ttext\n\r\f\v", False)]:
            with self.subTest(content=repr(content)):
                source = {"uuid": "source", "name": "Paper", "group_id": "papershelf", "content": content,
                          "source_description": "{}", "reference_time": None, "created_at": None}
                raw_fact = {"group_id": "papershelf", "fact": "Retain model's unreviewed result", "episodes": ["source"]}
                client = SimpleNamespace(close=AsyncMock(), search=AsyncMock(return_value=[
                    SimpleNamespace(group_id="papershelf", model_dump=lambda **kwargs: dict(raw_fact))]),
                    driver=SimpleNamespace(execute_query=AsyncMock(return_value=([source], None, None))))
                with patch.object(integration, "_graph_client", return_value=client):
                    result = integration.graphiti_search("query")
                fact = result["facts"][0]
                self.assertEqual(fact["fact"], raw_fact["fact"])
                self.assertEqual(fact["sources"][0]["content"], content)
                self.assertEqual(bool(fact.get("source_warnings")), warning_expected)
                if warning_expected:
                    self.assertIn("U+0003", fact["source_warnings"][0])
                    self.assertIn("source", fact["source_warnings"][0])


if __name__ == "__main__":
    unittest.main()
