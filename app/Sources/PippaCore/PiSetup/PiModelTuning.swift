import Foundation

/// What Pi needs to know about a local model beyond id and context: how it thinks and when to compact.
///
/// Thinking: Pi steers it per request (`chat_template_kwargs`, models.md "Configure sampling by thinking level").
/// The startup level per model is Pi's `modelThinkingLevels` setting; Pippa writes its default once and leaves a level
/// the person chose alone.
///
/// Compaction: Pi compacts when `context > contextWindow − reserveTokens` (compaction.md). The defaults
/// (`reserveTokens` 16384, `keepRecentTokens` 20000) would put that threshold at 0 for a 16k model, so Pippa sets
/// both per `pippa-local/<id>` in `compaction.modelOverrides`.
public enum PiReasoningStyle: String, Codable, Sendable, Equatable {
    /// Qwen 3.5 and its fine-tunes (Ornith): `chat_template_kwargs.enable_thinking`.
    case enableThinking
    /// OpenAI-style `reasoning_effort` (Inkling 2 Mini: none/minimal/low/medium/high/xhigh).
    case reasoningEffort

    public static func of(modelKey key: String, catalog: ModelCatalog = .bundled()) -> PiReasoningStyle? {
        if let declared = catalog.model(key)?.reasoningStyle { return declared }
        if key.hasPrefix("ornith") || key.hasPrefix("qwen3") { return .enableThinking }
        if key.hasPrefix("inkling") { return .reasoningEffort }
        return nil
    }

    /// Fields added to the model's entry in models.json.
    public var modelFields: [String: Any] {
        switch self {
        case .enableThinking:
            ["reasoning": true,
             "thinkingLevelMap": ["off": "off", "minimal": NSNull(), "low": NSNull(), "medium": "medium", "high": NSNull(),
                                  "xhigh": NSNull(), "max": NSNull()] as [String: Any],
             "compat": ["thinkingFormat": "qwen-chat-template"]]
        case .reasoningEffort:
            ["reasoning": true,
             "thinkingLevelMap": ["off": "none", "minimal": "minimal", "low": "low", "medium": "medium", "high": "high",
                                  "xhigh": "xhigh", "max": NSNull()] as [String: Any],
             "compat": ["supportsReasoningEffort": true, "maxTokensField": "max_tokens",
                        "supportsDeveloperRole": false, "supportsStore": false, "supportsUsageInStreaming": true] as [String: Any]]
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
            guard PiReasoningStyle.of(modelKey: model.id, catalog: catalog) != nil, let level = catalog.model(model.id)?.thinking else { continue }
            if levels[key] == nil { levels[key] = level }
        }
        compaction["modelOverrides"] = overrides
        document["compaction"] = compaction
        if !levels.isEmpty { document["modelThinkingLevels"] = levels }
        return document
    }
}
