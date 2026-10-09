# K2 Horizon think tags: upstream fix for ggml-org/llama.cpp (not submitted)

Pippa carries the fix as `app/Packaging/llama-patches/k2-horizon-think-tags.patch` until upstream has it.
Checked 2026-10-09: no issue or PR about this upstream; `common/parsers/k2-horizon.cpp` on master (3d65c90)
still accepts only the requested effort's end tag.

## Rules that apply (CONTRIBUTING.md, AGENTS.md of llama.cpp)

- Bug fixes need a reproducible **issue first** and a regression test that fails before and passes after.
- AI-written issue texts, PR descriptions, commit messages and reviewer replies are **prohibited** (PR gets closed,
  account can be banned). Automated submissions too. AI use in the code must be disclosed in the PR template.
- The person submitting must understand and be able to explain every line without AI help.

So: the owner writes issue, commit message and PR text in their own words and submits them. Nothing here is a
ready-made text to paste.

## Facts for the issue (own words)

- Model: K2 Horizon 7B Q4_K_M, llama-server b11503 `--jinja`, client Pi 1.1.0 with tools.
- `reasoning_effort` low/medium: the generation prompt opens `<ifm|think_faster>` / `<ifm|think_fast>`. After a
  tool result the model often closes with `</ifm|think>`. The parser waits for the effort's own end tag, so the
  tool call ends up in `reasoning_content`, `content` and `tool_calls` are empty, the agent turn ends.
- Measured on the official build (Pi tool loop, 2026-10-08): low 24/30 OK, medium 0/20, high 30/30.
  Patched: low 19/20, no tool call in reasoning.
- Probably related: the template renders past assistant reasoning (`reasoning_content`) always as
  `<ifm|think>...</ifm|think>` (IFM-K2-Horizon.jinja, branch `message.reasoning_content`), so the model sees that tag in
  the history. Not proven, keep it as a guess.

## The change (verified on master 3d65c90)

`common/parsers/k2-horizon.cpp`, after `data.thinking_end_tags = { THINK_END };`:

```cpp
    // The model may close with another effort's tag (often </ifm|think> after tool results), keep THINK_END first for the reasoning budget
    data.thinking_end_tags  = { THINK_END };
    for (const std::string tag : { "</ifm|think>", "</ifm|think_fast>", "</ifm|think_faster>" }) {
        if (tag != THINK_END) {
            data.thinking_end_tags.push_back(tag);
        }
    }
```

Why it is shaped like this:
- Several end tags is the existing pattern (deepseek, qwen3-coder, ling3 parsers).
- The first end tag matters: the server passes `thinking_end_tags` as `reasoning_budget_end_tags`, and the budget
  forces the first one. So the effort's own tag stays first.
- `preserved_tokens` is built from `thinking_end_tags`, so the extra tags are covered without another change.

Regression test in `tests/test-chat.cpp`, K2 Horizon block (before the `empty_args` test): for medium and low, the
own end tag and `</ifm|think>` followed by a tool call must give `message_assist_call_thoughts`.

```cpp
        // Lower efforts open <ifm|think_fast>/<ifm|think_faster>, the model may close with any effort's tag
        for (const std::string effort : { "medium", "low" }) {
            const std::string own_end = effort == "medium" ? "</ifm|think_fast>" : "</ifm|think_faster>";
            for (const std::string end : { own_end, std::string("</ifm|think>") }) {
                tst.test(
                       "I'm\nthinking" + end + "<ifm|tool_calls>\n"
                       "<ifm|tool_call>special_function\n"
                       "<ifm|arg_key>arg1</ifm|arg_key>\n"
                       "<ifm|arg_value>1</ifm|arg_value>\n"
                       "</ifm|tool_call>\n"
                       "</ifm|tool_calls>")
                    .reasoning_format(COMMON_REASONING_FORMAT_AUTO)
                    .tools({ special_function_tool })
                    .chat_template_kwargs({ { "reasoning_effort", "\"" + effort + "\"" } })
                    .expect(message_assist_call_thoughts)
                    .run();
            }
        }
```

Result: without the fix `test-chat` aborts at medium + `</ifm|think>` (the whole tool call is in the reasoning);
with the fix `[chat] All tests passed!`. Build: `cmake -B build -DLLAMA_BUILD_TESTS=ON && cmake --build build -t test-chat`.

## Steps for the owner

1. Read and understand the change and the test (about 25 lines).
2. Open an issue with the facts above, in your own words.
3. Fork, apply the change on current master, build and run `test-chat` yourself.
4. Commit message and PR text in your own words, link the issue, fill in the AI disclosure in the template.
5. Once merged and in a release: bump llama.cpp in Pippa, delete the patch, and re-measure low against high.
