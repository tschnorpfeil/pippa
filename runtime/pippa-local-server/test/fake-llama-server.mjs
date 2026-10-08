// Stand-in for llama-server (no model): `--help` lists flags; otherwise HTTP on 127.0.0.1:<--port> with /health
// (503 while "loading" for $FAKE_LLAMA_LOAD_MS, then 200) and /slots, both only with `Bearer $LLAMA_API_KEY` when a key
// is set. Each start appends {args, key, pid} to $FAKE_LLAMA_LOG. A file at $FAKE_LLAMA_BUSY makes slot 0 "processing".
import { appendFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";

const args = process.argv.slice(2);
if (args.includes("--help")) {
	console.log("--host --port --alias --jinja --ctx-size --parallel --no-webui --slot-save-path --swa-full");
	process.exit(0);
}
const key = process.env.LLAMA_API_KEY ?? "";
if (process.env.FAKE_LLAMA_LOG) appendFileSync(process.env.FAKE_LLAMA_LOG, JSON.stringify({ args, key, pid: process.pid }) + "\n");
const port = Number(args[args.indexOf("--port") + 1]);
const readyAt = Date.now() + (Number(process.env.FAKE_LLAMA_LOAD_MS) || 300);
let task = 0;
createServer((req, res) => {
	if (key && req.headers.authorization !== `Bearer ${key}`) {
		res.writeHead(401).end();
		return;
	}
	if (req.url === "/health") {
		const ready = Date.now() >= readyAt;
		res.writeHead(ready ? 200 : 503, { "Content-Type": "application/json" }).end(ready ? '{"status":"ok"}' : '{"error":"loading"}');
	} else if (req.url === "/slots") {
		const busy = !!process.env.FAKE_LLAMA_BUSY && existsSync(process.env.FAKE_LLAMA_BUSY);
		if (busy) task++;
		res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify([{ id: 0, id_task: task, is_processing: busy }]));
	} else if (req.method === "POST" && req.url === "/v1/chat/completions") {
		// Just enough of a streamed answer for a real `pi -p` run.
		req.resume();
		req.on("end", () => {
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			const chunk = (delta, finish = null) =>
				`data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "fake", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
			res.end(chunk({ role: "assistant", content: "pong" }) + chunk({}, "stop") + "data: [DONE]\n\n");
		});
	} else {
		res.writeHead(404).end();
	}
}).listen(port, "127.0.0.1");
process.on("SIGTERM", () => process.exit(0));
