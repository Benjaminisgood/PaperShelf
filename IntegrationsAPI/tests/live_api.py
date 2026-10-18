#!/usr/bin/env python3
"""Exercise the real Network listener + CLI/MCP against an isolated in-memory library."""
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse

harness, cli = map(str, map(Path, sys.argv[1:3]))
checks = 0
def check(value, message):
    global checks
    assert value, message
    checks += 1

with tempfile.TemporaryDirectory(prefix="papershelf-local-api-qa-") as temporary:
    root = Path(temporary)
    for mode in ("readonly", "write"):
        work = root / mode
        process = subprocess.Popen([harness, str(work), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            connection_file = work / "LocalAPI/connection.json"
            for attempt in range(200):
                if connection_file.exists(): break
                if process.poll() is not None: raise RuntimeError(process.stderr.read().decode())
                time.sleep(.05)
            info = json.loads(connection_file.read_text())
            check(connection_file.stat().st_mode & 0o777 == 0o600, "private token file")
            endpoint = urlparse(info["baseURL"])
            def request(method, route, payload=None, headers=None, auth=True):
                extra = {"Authorization": "Bearer " + info["token"]} if auth else {}
                if isinstance(payload, dict):
                    payload = json.dumps(payload).encode()
                    extra["Content-Type"] = "application/json"
                extra.update(headers or {})
                connection = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=10)
                connection.request(method, "/api/v1" + route, body=payload, headers=extra)
                response = connection.getresponse()
                body = json.loads(response.read())
                connection.close()
                return response.status, body, dict(response.getheaders())
            check(request("GET", "/status", auth=False)[0] == 401, "unauthenticated status rejected")
            check(request("GET", "/status", headers={"Origin":"https://evil.example"})[0] == 403, "foreign Origin rejected")
            check(request("GET", "/status", headers={"Host":"evil.example"})[0] == 403, "DNS rebinding Host rejected")
            check(request("OPTIONS", "/papers", headers={"Origin":"https://localhost:3456", "Access-Control-Request-Method":"POST"}, auth=False)[0] == 200, "approved origin preflight")
            status, value, _ = request("GET", "/status")
            check(status == 200 and value["readOnly"] == (mode == "readonly"), "actual policy")
            status, value, _ = request("GET", "/search?q=Fixture")
            check(status == 200 and value["total"] == 1 and value["items"][0]["title"] == "API Fixture", "search response")
            paper = value["items"][0]["id"]
            check("abstract" not in value["items"][0] and "pdfPath" not in value["items"][0], "private includes default off")
            check(request("GET", f"/papers/{paper}?include=abstract")[1]["abstract"] == "Full abstract", "include opt-in")
            check(request("GET", f"/papers/{paper}/csl")[1]["author"][0] == {"family":"Doe","given":"Jane"}, "CSL names")
            command = [cli, "--connection", str(connection_file)]
            result = subprocess.run(command + ["search", "Fixture"], capture_output=True, text=True, check=True)
            check(json.loads(result.stdout)["total"] == 1, "real CLI connection")
            messages = [
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}},
                {"jsonrpc":"2.0","id":2,"method":"tools/list"},
                {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"Fixture"}}},
            ]
            result = subprocess.run(command + ["mcp"], input="\n".join(map(json.dumps,messages))+"\n", capture_output=True,text=True,check=True)
            replies = list(map(json.loads,result.stdout.splitlines()))
            check(len(replies) == 3 and not replies[2]["result"]["isError"], "real MCP initialize/list/call")
            names = {tool["name"] for tool in replies[1]["result"]["tools"]}
            check(("create_paper" in names) == (mode == "write"), "MCP advertises only permitted write tools")
            if mode == "readonly":
                check(request("POST","/papers",{"title":"Blocked"})[0] == 403,"readonly create rejected")
                check(request("PUT",f"/papers/{paper}/pdf",b"%PDF-bad",{"Content-Type":"application/pdf"})[0] == 403,"readonly attachment rejected")
                continue
            check(request("POST","/papers",{"title":"Created","year":"2025"})[0] == 201,"create")
            check(request("POST","/papers",{"title":"Created","year":"2025"})[1]["status"] == "skipped","duplicate skip")
            check(request("POST","/papers",{"title":"Updated","doi":"10.1234/fixture","duplicatePolicy":"replace","extraFields":{"new":"value"}})[0] == 201,"duplicate replace")
            value = request("GET",f"/papers/{paper}?include=library")[1]
            check(value["notes"] == "User notes" and value["rating"] == 5 and value["isRead"] and value["isFavorite"] and value["citationKey"] == "Doe2024" and value["extraFields"] == {"custom":"keep","new":"value"},"replace preserves user annotations and fields")
            check(request("PUT",f"/papers/{paper}/pdf",b"%PDF-bad",{"Content-Type":"application/pdf"})[0] == 422,"invalid PDF rejected")
            check(request("PUT",f"/papers/{paper}/pdf",{"path":"/etc/passwd"})[0] == 403,"untrusted path rejected")
            check(request("PUT",f"/papers/{paper}/pdf",{"path":str(work/"trusted/fixture.pdf")})[0] == 200,"trusted PDF attached")
            check(request("PUT",f"/papers/{paper}/pdf",{"path":str(work/"trusted/fixture.pdf")})[0] == 409,"replace PDF requires force")
            data = (work/"trusted/fixture.pdf").read_bytes()
            check(request("PUT",f"/papers/{paper}/pdf?force=true",data,{"Content-Type":"application/pdf"})[0] == 200,"explicit PDF bytes replacement")
            check((work/"trusted/fixture.pdf").read_bytes() == data,"source PDF unchanged")
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    export = root / "papershelf-library"
    subprocess.run([cli,"export-skill",str(export)],check=True,stdout=subprocess.DEVNULL)
    check((export/"SKILL.md").exists() and (export/"scripts/papershelf.sh").stat().st_mode & 0o111,"portable Skill export")
    check(subprocess.run([cli,"export-skill",str(export)],capture_output=True).returncode != 0,"Skill export never overwrites")
print(json.dumps({"checks":checks,"result":"passed","library":"isolated in-memory fixture; production library untouched"}))
