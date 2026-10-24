// Verify that tool changes reach real Pi's next provider request, including policy exclusions.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI ?? (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE ?? (payload ? join(payload, "bin/node") : process.execPath);
test(
  "real Pi scopes the initial request and expands only launch-approved tools",
  { skip: !cli, timeout: 30000 },
  async () => {
    const root = await mkdtemp(resolve(".build/scope-real-"));
    const agent = join(root, "agent");
    await mkdir(agent);
    const bodies = [];
    const server = createServer(async (req, res) => {
      let raw = "";
      for await (const c of req) raw += c;
      bodies.push(JSON.parse(raw));
      res.writeHead(200, { "content-type": "text/event-stream" });
      const chunk = (delta, finish_reason) =>
        `data: ${JSON.stringify({ id: "test", object: "chat.completion.chunk", created: 0, model: "fixture", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
      if (bodies.length === 1) {
        res.write(
          chunk(
            {
              role: "assistant",
              tool_calls: [
                {
                  index: 0,
                  id: "expand",
                  type: "function",
                  function: { name: "pippa_more_tools", arguments: "{}" },
                },
              ],
            },
            null,
          ),
        );
        res.write(chunk({}, "tool_calls"));
      } else res.write(chunk({ role: "assistant", content: "Ready." }, "stop"));
      res.end("data: [DONE]\n\n");
    });
    let child;
    try {
      await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
      await writeFile(
        join(agent, "models.json"),
        JSON.stringify({
          providers: {
            fixture: {
              api: "openai-completions",
              apiKey: "fixture",
              baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
              models: [
                { id: "fixture", contextWindow: 16000, maxTokens: 1000 },
              ],
            },
          },
        }),
      );
      child = spawn(
        node,
        [
          cli,
          "--no-session",
          "--no-context-files",
          "--no-skills",
          "--no-extensions",
          "--extension",
          resolve("runtime/pippa-tools/pippa-assist.ts"),
          "--tools",
          "read,bash,pippa_more_tools",
          "--provider",
          "fixture",
          "--model",
          "fixture",
          "-p",
          "Summarize this document.",
        ],
        {
          cwd: root,
          env: {
            HOME: root,
            PATH: process.env.PATH,
            PI_CODING_AGENT_DIR: agent,
            PI_OFFLINE: "1",
            PI_SKIP_VERSION_CHECK: "1",
          },
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let output = "",
        errors = "";
      child.stdout.on("data", (b) => (output += b));
      child.stderr.on("data", (b) => (errors += b));
      const code = await new Promise((ok, no) => {
        child.on("error", no);
        child.on("exit", ok);
      });
      assert.equal(code, 0, errors);
      assert.equal(output.trim(), "Ready.");
      assert.equal(bodies.length, 2);
      const names = (i) => bodies[i].tools.map((t) => t.function.name).sort();
      assert.deepEqual(names(0), ["pippa_more_tools", "read"]);
      assert.deepEqual(names(1), ["bash", "read"]);
      assert.ok(
        bodies.every(
          (b) =>
            !b.tools.some((t) => ["write", "edit"].includes(t.function.name)),
        ),
      );
    } finally {
      if (child && child.exitCode === null) child.kill();
      await new Promise((ok) => server.close(ok));
      await rm(root, { recursive: true, force: true });
    }
  },
);
