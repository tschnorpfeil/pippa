import Foundation

/// What Pi needs to know about a local model beyond id and context: how it thinks and when to compact.
///
/// Thinking: Pi steers it per request (`chat_template_kwargs`, models.md "Configure sampling by thinking level"),
/// so Pi's llama-server no longer starts with `--reasoning off`. The startup level per model is Pi's
/// `modelThinkingLevels` setting; Pippa writes its default once and leaves a level the person chose alone.
///
/// Compaction: Pi compacts when `context > contextWindow − reserveTokens` (compaction.md). The defaults
/// (`reserveTokens` 16384, `keepRecentTokens` 20000) would put that threshold at 0 for a 16k model, so Pippa sets
/// both per `pippa-local/<id>` in `compaction.modelOverrides`.
public enum PiReasoningStyle: String, Sendable, Equatable {
    /// K2 Horizon: `chat_template_kwargs.reasoning_effort`. The template always thinks at least "low", so Pi's
    /// "off" maps to "low" as well.
    case reasoningEffort
    /// Qwen 3.x: `chat_template_kwargs.enable_thinking` (the same map Pi's own llama.cpp provider uses).
    case enableThinking

    public static func of(modelKey key: String) -> PiReasoningStyle? {
        if key.hasPrefix("k2-") { return .reasoningEffort }
        if key.hasPrefix("qwen3") { return .enableThinking }
        return nil
    }

    /// Fields added to the model's entry in models.json.
    public var modelFields: [String: Any] {
        switch self {
        case .reasoningEffort:
            return ["reasoning": true,
                    "thinkingLevelMap": ["off": "low", "minimal": NSNull(), "low": "low", "medium": "medium", "high": "high",
                                         "xhigh": NSNull(), "max": NSNull()] as [String: Any],
                    "compat": ["thinkingFormat": "chat-template",
                               "chatTemplateKwargs": ["reasoning_effort": ["$var": "thinking.effort"], "tool_call_format": "xml"] as [String: Any]]
                        as [String: Any]]
        case .enableThinking:
            return ["reasoning": true,
                    "thinkingLevelMap": ["off": "off", "minimal": NSNull(), "low": NSNull(), "medium": "medium", "high": NSNull(),
                                         "xhigh": NSNull(), "max": NSNull()] as [String: Any],
                    "compat": ["thinkingFormat": "qwen-chat-template"]]
        }
    }
}

public enum PiModelTuning {
    /// Room for the answer: the answer limit Pippa gives every local model (`PiProviderModel.maxTokens`).
    public static func reserveTokens(contextWindow: Int, maxTokens: Int) -> Int {
        min(maxTokens, contextWindow / 4)
    }

    /// What stays verbatim after compacting: about three eighths of the window (16k: 6144, 32k: 12288).
    /// Not measured yet; the point is a threshold above 0.
    public static func keepRecentTokens(contextWindow: Int) -> Int {
        contextWindow * 3 / 8
    }

    /// Key in Pi's per-model settings.
    public static func settingsKey(modelID: String) -> String { PiInstaller.providerKey + "/" + modelID }

    /// Merges Pippa's per-model values into Pi's settings document. Compaction values for `pippa-local` models are
    /// Pippa's and always set; a thinking level is only added where none is set yet.
    public static func merge(into document: [String: Any], models: [PiProviderModel], catalog: ModelCatalog = .bundled()) -> [String: Any] {
        var document = document
        var compaction = document["compaction"] as? [String: Any] ?? [:]
        var overrides = compaction["modelOverrides"] as? [String: Any] ?? [:]
        var levels = document["modelThinkingLevels"] as? [String: Any] ?? [:]
        for model in models {
            let key = settingsKey(modelID: model.id)
            overrides[key] = ["reserveTokens": reserveTokens(contextWindow: model.contextWindow, maxTokens: model.maxTokens),
                              "keepRecentTokens": keepRecentTokens(contextWindow: model.contextWindow)]
            if levels[key] == nil, PiReasoningStyle.of(modelKey: model.id) != nil, let level = catalog.model(model.id)?.thinking {
                levels[key] = level
            }
        }
        compaction["modelOverrides"] = overrides
        document["compaction"] = compaction
        if !levels.isEmpty { document["modelThinkingLevels"] = levels }
        return document
    }
}
