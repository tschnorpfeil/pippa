# Settings simplification

Product decision: there is no local model choice. The model is fixed per system, and the settings are cut down
radically, because the audience is non-technical people.

Rule used for every surface: keep only what a non-technical person would truly miss. Duplicates of the menu-bar menu,
technical knobs and anything a sensible default covers are gone.

| Default | Own online AI switched on |
|---|---|
| ![Settings, local only](settings-simplification/settings-01-local.png) | ![Settings, own online AI on](settings-simplification/settings-02-online.png) |

Screenshots: `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<dir> PIPPA_SNAPSHOT_ONLY=settings app/.build/debug/Pippa` (demo engine, no
key, nothing leaves the Mac).

## The model is fixed by hardware

One table, `ModelSelector.choose(physicalMemory:)` in `app/Sources/PippaCore/Models.swift`. Changing it is one line.

| Memory | Model | Context |
|---|---|---|
| 8 GB | Qwen3.5 4B Q4 | 16K |
| 16 GB | Gemma 4 12B | 16K |
| 24 GB | Gemma 4 12B | 32K |
| 32 GB and up | Qwen3.6 35B-A3B Q4 | 32K |

`ModelSelector.named(_:)` still builds a choice for one specific catalog model, but only for developers and
measurements (`PIPPA_PI_MODEL`, PippaLive, probes) and for the model already written in Pi's `models.json`
(`PiLocalServer.plan`). Nothing in the UI reaches it.

**Migration.** `settings.json` files with `modelOverride`, `automaticChosen` or `piModel` still load; those keys are
ignored and disappear the next time Pippa writes the file. Everyone gets the model from the table. If that model is
missing, the normal single download question appears, unless the model already sits in LM Studio, Ollama, Hugging
Face and so on (then it is adopted without a download, as before). No code path deletes model files: an earlier choice
stays on disk untouched. The never-called `ModelDownloader.removeOtherModels` was deleted as well.

**`adoptInstalled` removed.** It kept 24 GB Macs on an already downloaded Qwen3.6 35B Q3 after the table moved them to
Gemma 4 12B. It only ever ran in the removed legacy chat path. The Pi path chooses by memory or the saved `piModel`
and never called it, so it prevented no download there. Keeping it would have kept a hidden second model choice.

## Decision table

| Surface | Before | Decision | Why |
|---|---|---|---|
| Settings → Advanced → "Knowledge on this Mac" (model picker, both paths) | Any catalog model that fits memory | **Deleted** → table | Product decision |
| Settings → Advanced → "Already have a model? Choose Files…" | Import GGUF files | **Deleted** | A model choice in disguise. The table's model is still found in other apps automatically |
| `modelOverride`, `automaticChosen`, `piModel` (settings.json) | Saved choice | **Deleted**, read and ignored | See migration |
| "Advanced" disclosure | Hid the items above | **Deleted** | Nothing left behind it |
| "Show on desktop" toggle | Pill on/off | **Deleted** | Same as "Show/Hide Pippa" in the menu-bar menu, which is also the way back |
| "Call Pippa" shortcut | 4 presets + Off | **Keep** | The only fix when ⌃⌥ Space is taken by the input-source switch |
| "Open at login" | Toggle | **Keep** | Common expectation. Turning it on silently is not OK |
| "Pippa's knowledge" row (Load now / Cancel / Try again) | Shown until ready | **Keep** | Status, not a setting. Hidden once ready |
| "Allow Pippa to…" (Reminders and Calendar, Mail) | Status + "Open System Settings" | **Keep** | Only way to recover from a denied permission |
| "Recent tasks" with Undo | List of 6 | **Deleted** | The menu-bar menu has "Recent Tasks" with Undo, and every answer has its own Undo |
| "What Pippa knows" learned-actions list + "Show all" | Per-action history | **Reduced** to one row with "Forget" | Keeps the privacy control. Drops the technical list |
| "Data and log" (size, Show in Finder) | Row | **Deleted**. The version moves to the footer | Logs are reached via Help → "Report a Problem…" |
| Footer privacy sentence | Text | **Keep** (+ version) | Says where content goes |
| Online: Off / Ask / Always picker | 3 modes | **One switch** (on = ask) | The Pi path already treated "Always" as "Ask". Pippa asks before every request |
| Online: service | OpenAI / Anthropic / OpenAI-compatible | **OpenAI, Anthropic**. Compatible only if already saved | A custom server URL is a techie feature. Saved connections keep working |
| Online: model ID, API key (Keychain) | Fields | **Keep** | Required. There is no sign-in alternative |
| Online: context size | Disclosure + field | **Deleted** (default 32,768, saved value kept) | Nobody non-technical knows this number |
| Online: "Test Connection" + "Test and Save" | 2 buttons | **One** "Test and Save" | Testing without saving has no use for the audience |
| Online: "Remove Connection" + "Remove Key" | 2 buttons | **One** "Remove" (removes the key too) | A connection without a key does nothing |
| Guard preset `undo-first` / `ask-all` | Env `PIPPA_GUARD_POLICY` only, no UI | **Keep invisible**, no switch | `undo-first` plus Undo is the product. `ask-all` is for development and support |
| Menu bar: Show/Hide Pippa, Settings…, Check for Updates…, "where it runs" line, Quit | Items | **Keep** | Each is the only place for that action |
| Menu bar: Load knowledge now / Try loading again | Items | **Keep** | Status actions |
| Hidden: `llamaIdleMinutes`, `piInlineShortText`, `PIPPA_*` env | No UI | **Keep hidden** | Not exposed. Defaults are right |
| Reminders vs Calendar target | Chosen in the deadline card, remembered | **Keep** | In context, not a setting |

## Code removed

`PiModelSwitch`, `PiModelChoiceController`/`PiModelChoiceRows`, `PiRPCChat.localModelChanged`,
`PippaEngine.modelOptions/setModelOverride/importModelFiles` (and `ModelOption`, `ModelImportResult`), `LocalEngine`'s
`existingPreference`/`settings`, `ModelSelector.eligible/resolve/adoptInstalled`, `ModelDownloader.removeOtherModels`,
`AppModel.selectModel/importModelFiles`, the online-service probe's "switch model" part, 82 Settings strings and 4 Core strings.
