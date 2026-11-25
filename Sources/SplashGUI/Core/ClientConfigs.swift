import Foundation

// The coding clients the Provider tab writes configs for. The OpenCode shape mirrors the engine's
// own connector (install/clients.py _opencode, engine 1.5.0, unchanged since 1.3.2); Claude Code
// and Codex mirror _claude and _codex. Zed's shape is from its current docs.
enum ProviderClient: String, CaseIterable, Identifiable {
    case opencode = "OpenCode"
    case zed = "Zed"
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case pi = "Pi"

    var id: String { rawValue }

    var tooltip: String {
        "The tool to write a config for. Each one gets the endpoint, the model, its context limit and the sampling below, in that tool's own format."
    }

    // Which sampling fields actually reach this client's requests. OpenCode merges the model's
    // `body` into the request body verbatim (V2; verified live against 2.2.2 with an echo
    // server); Zed carries temperature only (agent.model_parameters); Claude Code, Codex and
    // Pi expose no sampling knobs — their requests set what they themselves want.
    func carries(_ field: SamplingField) -> Bool {
        switch self {
        case .opencode: return field != .maxTokens
        case .zed: return field == .temperature
        case .claudeCode, .codex: return false
        case .pi: return field != .maxTokens
        }
    }

    var configCaption: String {
        switch self {
        case .opencode: return "opencode.json: add this providers block; your model and agent defaults stay untouched"
        case .zed: return "settings.json for Zed (AI section)"
        case .claudeCode: return "settings.json: the env block for ~/.claude/settings.json"
        case .codex: return "config.toml for ~/.codex/config.toml"
        case .pi: return "models.json: merge this providers block into ~/.pi/agent/models.json"
        }
    }

    var saveName: String {
        switch self {
        case .opencode: return "opencode-splash.json"
        case .zed: return "zed-splash-settings.json"
        case .claudeCode: return "claude-code-splash-env.json"
        case .codex: return "codex-splash-config.toml"
        case .pi: return "pi-splash-models.json"
        }
    }

    var filePattern: String {
        switch self {
        case .codex: return "toml"
        default: return "json"
        }
    }
}

enum SamplingField {
    case temperature, topP, topK, presencePenalty, minP, maxTokens, seed
}

// Everything the config text is built from, resolved by AppModel (granted window when the server runs).
struct ClientConfigContext {
    let client: ProviderClient
    let modelID: String
    let label: String
    // The machine the client runs on: loopback for this Mac, the LAN address for another one.
    var host: String = "127.0.0.1"
    let port: Int
    let contextTokens: Int
    let inputModalities: [String]
    let sampling: SamplingDefaults
    // The model card's thinking-off set, when the model has a card; Pi writes it as samplingParamsByThinkingLevel.off.
    var offSampling: SamplingDefaults? = nil
    // Reasoning levels this model accepts; defaults to every level Splash's API takes.
    var efforts: [String] = CatalogModel.allEfforts
    // Whether the server renders a later system message in place (Pi's compat flag).
    var laterSystem: Bool = false
}

enum ClientConfigs {
    // The output allowance OpenCode and Zed reserve: CLIENT_RESPONSE_TOKENS in the engine connector, or a quarter of the window when less.
    static func responseTokens(context: Int) -> Int {
        min(32_768, max(1, context / 4))
    }

    static func text(for ctx: ClientConfigContext) -> String {
        switch ctx.client {
        case .opencode: return opencode(ctx)
        case .zed: return zed(ctx)
        case .claudeCode: return claudeCode(ctx)
        case .codex: return codex(ctx)
        case .pi: return pi(ctx)
        }
    }

    // MARK: - OpenCode

    private static func json(_ obj: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        // JSONSerialization escapes every "/" as "\/"; it is the only sequence it produces this way, safe to undo in the preview.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    // JSONSerialization prints a Double's full binary expansion; a decimal from Swift's shortest description round-trips cleanly.
    private static func decimal(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(value))
    }

    // One writer for the five sampling fields plus the optional seed.
    private static func samplingBody(_ s: SamplingDefaults) -> [String: Any] {
        var body: [String: Any] = [
            "temperature": decimal(s.temperature),
            "top_p": decimal(s.topP),
            "top_k": s.topK,
            "presence_penalty": decimal(s.presencePenalty),
            "min_p": decimal(s.minP),
        ]
        if let seed = s.seed { body["seed"] = seed }
        return body
    }

    // This snippet only adds the provider — deliberately no root `model`, `small_model` or `agents`
    // (the user's defaults; overriding them pointed every agent at Splash). Splash appears as one
    // more /models entry; its reasoning efforts as /variants.
    private static func opencode(_ ctx: ClientConfigContext) -> String {
        let out = responseTokens(context: ctx.contextTokens)
        let modalities = ctx.inputModalities
        // Sampling rides in the model's `body`, which V2 merges into the request body verbatim (V1's `options` was the old path).
        let body = samplingBody(ctx.sampling)

        // One variant per effort Splash accepts; Splash reads snake_case `reasoning_effort` from the body, so the overlay is the reliable path.
        let variants: [[String: Any]] = ctx.efforts.map { effort in
            ["id": effort, "body": ["reasoning_effort": effort]]
        }
        let reasoningEfforts = ctx.efforts.filter { $0 != "none" }
        let reasoning: [String: Any] = [
            "supported": true,
            "toggle": ctx.efforts.contains("none"),
            "effort": reasoningEfforts,
        ]
        let model: [String: Any] = [
            "name": ctx.label,
            "capabilities": [
                "tools": true,
                "input": modalities,
                "output": ["text"],
                "reasoning": reasoning,
            ],
            // Splash streams thinking in reasoning_content and reads the cap as max_tokens, so tell the OpenAI-compatible package both.
            "compatibility": [
                "reasoningField": "reasoning_content",
                "maxTokensField": "max_tokens",
            ],
            "limit": ["context": ctx.contextTokens,
                      "input": ctx.contextTokens - out,
                      "output": out],
            "body": body,
            "variants": variants,
        ]
        let root: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "providers": [
                "splashgui": [
                    "name": "SplashGUI",
                    "package": "@opencode/ai/providers/openai-compatible",
                    "settings": [
                        "baseURL": "http://\(ctx.host):\(ctx.port)/v1",
                        "apiKey": "local",
                    ],
                    "models": [ctx.modelID: model],
                ]
            ],
        ]
        return json(root)
    }

    // MARK: - Zed

    private static func zed(_ ctx: ClientConfigContext) -> String {
        let modalities = ctx.inputModalities
        var model: [String: Any] = [
            "name": ctx.modelID,
            "display_name": ctx.label,
            "max_tokens": ctx.contextTokens,
            "max_output_tokens": responseTokens(context: ctx.contextTokens),
            // Splash streams thinking in a dedicated reasoning_content field and takes the output cap as max_tokens; tool calling works.
            "capabilities": [
                "tools": true,
                "images": modalities != ["text"],
                "parallel_tool_calls": false,
                "prompt_cache_key": false,
                "chat_completions": true,
                "interleaved_reasoning": true,
                "max_tokens_parameter": true,
            ],
        ]
        if let effort = ctx.sampling.reasoningEffort, effort != "none" {
            // Tells Zed which effort to send when thinking is on; unset = the server default.
            model["reasoning_effort"] = effort
        }
        var root: [String: Any] = [
            "language_models": [
                "openai_compatible": [
                    "splash": [
                        "api_url": "http://\(ctx.host):\(ctx.port)/v1",
                        "available_models": [model],
                    ]
                ]
            ]
        ]
        // Zed carries temperature per model (agent.model_parameters); the provider is omitted so the
        // entry matches Zed's provider key regardless of its exact spelling. Keys stay out of
        // settings.json — Zed wants SPLASH_API_KEY in the environment (generated from the provider name).
        if ctx.sampling.temperature > 0 {
            root["agent"] = ["model_parameters": [["model": ctx.modelID,
                                                   "temperature": ctx.sampling.temperature]]]
        }
        return json(root)
    }

    // MARK: - Claude Code

    private static func claudeCode(_ ctx: ClientConfigContext) -> String {
        // Mirrors the engine connector's _claude environment. ANTHROPIC_BASE_URL takes the bare
        // server URL (Claude Code appends /v1/messages itself); no sampling fields — Claude Code sets its own.
        let env: [String: Any] = [
            "ANTHROPIC_BASE_URL": "http://\(ctx.host):\(ctx.port)",
            "ANTHROPIC_AUTH_TOKEN": "local",
            "ANTHROPIC_MODEL": ctx.modelID,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": ctx.modelID,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": ctx.modelID,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": ctx.modelID,
            "ANTHROPIC_SMALL_FAST_MODEL": ctx.modelID,
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": String(ctx.contextTokens),
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": String(ctx.contextTokens),
        ]
        return json(["env": env])
    }

    // MARK: - Codex

    private static func codex(_ ctx: ClientConfigContext) -> String {
        // Mirrors the engine connector's _codex -c overrides; wire_api = responses (Codex speaks /v1/responses, which Splash serves).
        """
        model = "\(ctx.modelID)"
        model_provider = "splash"
        model_context_window = \(ctx.contextTokens)
        model_auto_compact_token_limit = \(ctx.contextTokens * 9 / 10)
        web_search = "disabled"

        [model_providers.splash]
        name = "Splash"
        base_url = "http://\(ctx.host):\(ctx.port)/v1"
        env_key = "SPLASH_API_KEY"
        wire_api = "responses"
        """
    }

    // MARK: - Pi

    // Mirrors the engine's `splash pi` connector (install/clients.py _write_pi_provider): a provider named
    // for the server, an openai-completions endpoint, and one model entry. Pi reads custom providers from
    // models.json in its agent directory; the block merges beside the user's other providers.
    private static func pi(_ ctx: ClientConfigContext) -> String {
        let provider = ctx.port == RunConfig.defaultPort ? "splash" : "splash-\(ctx.port)"
        var model: [String: Any] = [
            "id": ctx.modelID,
            "reasoning": true,
            // Pi sends no effort when thinking is off (leaving the template's default); "none" turns it off.
            "thinkingLevelMap": ["off": "none"],
            // Pi accepts only text and image; any other entry invalidates the whole file.
            "input": ctx.inputModalities.contains("image") ? ["text", "image"] : ["text"],
            "contextWindow": ctx.contextTokens,
            // Pi lowers this per request to what its context leaves; the engine writes the same 32,768 allowance.
            "maxTokens": 32_768,
        ]
        if ctx.laterSystem {
            // Pi otherwise folds the system messages it adds as a session goes on into the first one,
            // changing the prompt from its start so the server re-reads it all.
            model["compat"] = ["supportsMidConvoSystemMessages": true]
        }
        // Pi's free-form sampling defaults, merged into every request. The card's thinking-off set rides
        // beside them so no-think turns can use different values (Pi's level key is "off"; Splash's is "none").
        model["samplingParams"] = samplingBody(ctx.sampling)
        if let off = ctx.offSampling {
            model["samplingParamsByThinkingLevel"] = ["off": samplingBody(off)]
        }
        let root: [String: Any] = [
            "providers": [
                provider: [
                    "baseUrl": "http://\(ctx.host):\(ctx.port)/v1",
                    "api": "openai-completions",
                    "apiKey": "local",
                    "models": [model],
                ]
            ]
        ]
        return json(root)
    }
}
