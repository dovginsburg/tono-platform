// AnthropicToneAnalyzer.swift
// Calls the Anthropic Messages API. Uses tool-use for guaranteed JSON-shape
// output. Targets claude-haiku-4-5 by default for cost parity with
// gpt-4o-mini (~$0.0006 / rewrite, see SCOPE.md §5.3).

import Foundation

public struct AnthropicToneAnalyzer: ToneAnalyzing {
    public let model: String
    public let apiKey: String
    public let endpoint: URL

    public init(model: String = "claude-haiku-4-5", apiKey: String, endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.model = model
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    public func analyze(_ req: AnalysisRequest) async throws -> ToneAnalysis {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 800,
            "system": TonePrompts.system,
            "tools": [
                [
                    "name": "tone_analysis",
                    "description": "Emit a ToneAnalysis JSON object matching the input_schema.",
                    "input_schema": jsonSchemaObject(),
                ],
            ],
            "tool_choice": ["type": "tool", "name": "tone_analysis"],
            "messages": [
                ["role": "user", "content": TonePrompts.userPrompt(for: req)],
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ToneEngineError.network("no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ToneEngineError.backend("anthropic \(http.statusCode): \(bodyText.prefix(200))")
        }

        // Response: { content: [{ type: "tool_use", input: { risk_level, ... } }] }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw ToneEngineError.decoding("unexpected anthropic response shape")
        }

        for block in content {
            if block["type"] as? String == "tool_use",
               let input = block["input"] {
                let pretty = try JSONSerialization.data(
                    withJSONObject: input,
                    options: [.sortedKeys]
                )
                let text = String(data: pretty, encoding: .utf8) ?? ""
                return try ToneEngine.decode(text)
            }
        }
        throw ToneEngineError.decoding("no tool_use block in response")
    }

    private func jsonSchemaObject() -> [String: Any] {
        guard let data = TonePrompts.jsonSchema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
