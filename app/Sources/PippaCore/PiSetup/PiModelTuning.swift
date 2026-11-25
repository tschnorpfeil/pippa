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
    /// Pi 1.6.0's fixed margin (`CONTEXT_SAFETY_TOKENS` in pi-ai `simple-options.js`): `clampMaxTokensToContext`
    /// caps `max_tokens` at `contextWindow - input - 4096`, so the answer only gets room beyond this margin.
    public static let piContextSafetyTokens = 4096

    /// Room for the answer at the compaction threshold: the answer limit (at most a quarter of the window) plus Pi's
    /// safety margin, capped at seven sixteenths of the window so the threshold stays usable
    /// (4k/4096: 1792, 16k/4096: 7168, 32k/4096: 8192, 32k/16384: 12288).
    public static func reserveTokens(contextWindow: Int, maxTokens: Int) -> Int {
        min(contextWindow * 7 / 16, min(maxTokens, contextWindow / 4) + piContextSafetyTokens)
    }

    /// What stays verbatim after compacting: an eighth of the window (16k: 2048, 32k: 4096). Pi estimates kept
    /// tokens as `chars / 4`, which undercounts code and HTML by about 1.86x; a larger budget lets one big tool call
    /// pin the cut point and leaves `prepareCompaction` nothing to summarize.
    public static func keepRecentTokens(contextWindow: Int) -> Int {
        contextWindow / 8
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
