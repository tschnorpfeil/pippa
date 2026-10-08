# Upstream PR draft for ggml-org/llama.cpp (not submitted)

Based on tag b11503 (03aa006acb547549162a00dddeab3d3b38ebf7b2). Pippa carries the same change as
`app/Packaging/llama-patches/k2-horizon-think-tags.patch` until upstream has it.

## Title

`chat: K2 Horizon parser accepts every reasoning effort's think end tag`

## Description

### Problem

The K2 Horizon PEG parser (`common/parsers/k2-horizon.cpp`) derives its thinking end tag from the requested
`reasoning_effort`: `</ifm|think_faster>` for `low`, `</ifm|think_fast>` for `medium`, `</ifm|think>` otherwise. It accepts
only that one tag. The model does not follow this strictly: especially in the turn after a tool result, K2 Horizon opens
with the effort-specific tag from the template but then writes `<ifm|think> ... </ifm|think>` (the plain tag). The parser
never sees its end tag, so everything that follows, including `<ifm|tool_calls>...</ifm|tool_calls>`, stays inside
`reasoning_content`. The response has `finish_reason: "stop"`, empty `content` and no `tool_calls`; agent clients end the
turn with nothing.

### Reproduction

1. `llama-server -m K2-Horizon-7B-Q4_K_M.gguf --jinja`
2. Use any OpenAI-compatible client with tools (we hit it with the Pi coding agent): send a request with a tool, e.g.
   `get_weather`, `"reasoning_effort": "low"`, then answer the tool call with a `tool` message and let the model continue
   (a multi-step task that needs a second tool call after the first result).
3. After the tool result the model often emits `<ifm|think>...</ifm|think><ifm|tool_calls>...`. With `low` the parser
   waits for `</ifm|think_faster>`, so the tool call lands in `reasoning_content`.

Measured on K2 Horizon 7B Q4_K_M with repeated agent runs, counting runs that produced the expected tool call:

| build | effort | OK |
|---|---|---|
| b11503 | low | 24/30 |
| b11503 | medium | 0/20 |
| b11503 + this change | low | 19/20, no leaked tags |

### Fix

The reasoning block ends at any of `</ifm|think>`, `</ifm|think_fast>`, `</ifm|think_faster>`. The tag that matches the
effort stays first (so generation prompts and `thinking_end_tags[0]` users behave as before). All three start tags are added
to the preserved tokens so they are never split or rendered as text.

```diff
--- a/common/parsers/k2-horizon.cpp
+++ b/common/parsers/k2-horizon.cpp
@@ -46,11 +46,18 @@
     const std::string ARG_VAL_END   = "</ifm|arg_value>";
 
     data.thinking_start_tag = THINK_START;
+    // The model does not always close with the tag the template opened: after tool results it often writes
+    // <ifm|think>...</ifm|think> even for medium/low effort. Accept every effort's end tag.
     data.thinking_end_tags  = { THINK_END };
+    for (const char * tag : { "</ifm|think>", "</ifm|think_fast>", "</ifm|think_faster>" }) {
+        if (tag != THINK_END) {
+            data.thinking_end_tags.push_back(tag);
+        }
+    }
 
     data.preserved_tokens = data.thinking_end_tags;
     data.preserved_tokens.insert(data.preserved_tokens.end(), {
-        THINK_START, SECTION_START, SECTION_END, CALL_START, CALL_END,
+        "<ifm|think>", "<ifm|think_fast>", "<ifm|think_faster>", SECTION_START, SECTION_END, CALL_START, CALL_END,
         ARG_KEY, ARG_KEY_END, ARG_TYPE, ARG_TYPE_END, ARG_VAL, ARG_VAL_END,
     });
 
```

### Testing

- New cases in `tests/test-chat.cpp` (below): a `low`/`medium` request whose output closes with `</ifm|think>`.
- Manual: K2 Horizon 7B with tools and `reasoning_effort: low` through Pi; tool calls arrive as `tool_calls`,
  `reasoning_content` holds no `<ifm|tool_calls>`.

Notes for reviewers: AI-assisted; I read and tested the change myself.

## Suggested test case for tests/test-chat.cpp

In the `// K2 Horizon` block (after the existing tool-call cases, same `tst` and `special_function_tool`).
`reasoning_effort` is passed through `chat_template_kwargs`; adjust to however the harness exposes `extra_context`
if that differs:

```cpp
        // The model may close the reasoning with the plain tag even when the template opened the low/medium variant.
        for (const char * effort : { "low", "medium" }) {
            tst.test(
                   "I'm\nthinking</ifm|think><ifm|tool_calls>\n"
                   "<ifm|tool_call>special_function\n"
                   "<ifm|arg_key>arg1</ifm|arg_key>\n"
                   "<ifm|arg_value>1</ifm|arg_value>\n"
                   "</ifm|tool_call>\n"
                   "</ifm|tool_calls>")
                .reasoning_format(COMMON_REASONING_FORMAT_AUTO)
                .chat_template_kwargs({ { "reasoning_effort", std::string("\"") + effort + "\"" } })
                .tools({ special_function_tool })
                .expect(message_assist_call_thoughts)
                .run();
        }

        // And the matching tag keeps working.
        tst.test("I'm\nthinking</ifm|think_faster>Hello, world!\nWhat's up?")
            .reasoning_format(COMMON_REASONING_FORMAT_AUTO)
            .chat_template_kwargs({ { "reasoning_effort", R"("low")" } })
            .expect(message_assist_thoughts)
            .run();
```

Without the change the first case fails: for `low`/`medium` the tool call text ends up in `reasoning_content`.
(Not built against upstream test-chat.cpp here, verify before submitting.)
