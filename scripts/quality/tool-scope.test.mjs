import test from "node:test";
import assert from "node:assert/strict";
import {
  scopedTools,
  installToolScope,
  EXPAND_TOOL,
} from "../../runtime/pippa-tools/tool-scope.mjs";
const all = [
  "read",
  "bash",
  "write",
  "edit",
  "search_files",
  "list_folder",
  "web_search",
  "fetch_content",
  "mcp__pippa__read_document",
  "mcp__pippa__mail_draft",
  "mcp__pippa__reminder_add",
  EXPAND_TOOL,
];
test("document summaries retain readers, search and web but omit unrelated actions", () => {
  const selected = scopedTools(
    "Fass mir diesen Brief kurz zusammen.\nAntworte auf Deutsch und duze mich.",
    all,
  );
  assert.ok(selected.includes("mcp__pippa__read_document"));
  assert.ok(selected.includes("web_search"));
  assert.ok(selected.includes(EXPAND_TOOL));
  assert.ok(!selected.includes("bash"));
  assert.ok(!selected.includes("mcp__pippa__mail_draft"));
});
test("mixed requests, skills, native writes and unknown requests retain all capabilities", () => {
  for (const text of [
    "Fass den Brief zusammen und erstelle eine Erinnerung.",
    "Summarize the file and write a reply email.",
    "/skill:brief Hallo",
    "Mach das bitte auch dort.",
    "Rename this file.",
    "Ändere diesen Brief.",
    "Combine these documents into one PDF.",
    "Mach diese Dateien versandfertig.",
    "Update the document.",
    "Was sehe ich hier?",
  ])
    assert.deepEqual(scopedTools(text, all), all, text);
});
test("chart requests retain every tool, so make_chart stays declared", () => {
  for (const text of [
    "Mach aus den Rechnungen ein Diagramm.",
    "Draw a chart of this table.",
  ])
    assert.deepEqual(scopedTools(text, all), all, text);
});
test("requesting an online lookup alongside a document retains both tools", () => {
  const names = scopedTools(
    "Meine Hausratversicherung: ist die Kündigungsfrist noch drin? Schau auch nach, wie man kündigt.",
    all,
  );
  for (const name of [
    "web_search",
    "search_files",
    "mcp__pippa__read_document",
  ])
    assert.ok(names.includes(name));
});
test("loader and steering cannot declare tools excluded by policy; late registration is scoped", async () => {
  const handlers = {},
    registered = {};
  const allowed = all.filter(
    (n) =>
      ![
        "write",
        "edit",
        "mcp__pippa__mail_draft",
        "mcp__pippa__reminder_add",
      ].includes(n),
  );
  const pi = {
    registerTool: (t) => (registered[t.name] = t),
    on: (n, f) => (handlers[n] = f),
  };
  const request = (names = allowed) => {
    const payload = {
      tools: names.map((name) => ({ type: "function", function: { name } })),
    };
    handlers.before_provider_request({ payload });
    return payload.tools.map((t) => t.function.name);
  };
  installToolScope(pi);
  handlers.session_start();
  handlers.before_agent_start({
    messageType: "user",
    prompt: "Summarize this letter.",
  });
  assert.ok(request().length < allowed.length);
  assert.ok(
    !request([...allowed, "mcp__pippa__late_native_writer"]).includes(
      "mcp__pippa__late_native_writer",
    ),
  );
  await registered[EXPAND_TOOL].execute();
  assert.deepEqual(
    request(),
    allowed.filter((n) => n !== EXPAND_TOOL),
  );
  handlers.before_agent_start({
    messageType: "user",
    prompt: "What is the weather?",
  });
  assert.deepEqual(
    request(),
    allowed.filter((n) => n !== EXPAND_TOOL),
  );
  handlers.session_start();
  handlers.before_agent_start({
    messageType: "user",
    prompt: "Summarize this letter.",
  });
  handlers.input({ streamingBehavior: "steer" });
  assert.deepEqual(
    request(),
    allowed.filter((n) => n !== EXPAND_TOOL),
  );
});

test("a scope without the expansion tool retains all of its approved readers", () => {
  const readers = [
    "read",
    "search_files",
    "mcp__pippa__read_document",
    "mcp__pippa__mail_search",
  ];
  assert.deepEqual(scopedTools("Summarize this letter.", readers), readers);
});

test("remembering document workflows retains save_skill without an expansion round trip", () => {
  for (const prompt of ["Merk dir diesen Ablauf für Rechnungen", "Remember how to compare these documents", "Diesen Rechnungsablauf als Skill behalten"]) {
    const tools = ["read", "save_skill", "remember", "pippa_more_tools"];
    assert.deepEqual(scopedTools(prompt, tools), tools);
  }
});
