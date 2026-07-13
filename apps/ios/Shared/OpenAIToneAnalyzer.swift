// OpenAIToneAnalyzer.swift
// Calls the OpenAI Chat Completions API with response_format=json_schema
// using the schema defined in TonePrompts.jsonSchema. Targets gpt-4o-mini
// by default — see SCOPE.md §5.3 unit economics: ~$0.0006 / rewrite.

import Foundation

public struct OpenAIToneAnalyzer: ToneAnalyzing {
    public let model: String
    public let apiKey: String
    public let endpoint: URL

    public init(model: String = "gpt-4o-mini", apiKey: String, endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.model = model
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    public func analyze(_ req: AnalysisRequest) async throws -> ToneAnalysis {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.4,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "ToneAnalysis",
                    "schema": jsonSchemaObject(),
                    "strict": true,
                ],
            ],
            "messages": [
                ["role": "system", "content": TonePrompts.system],
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
            throw ToneEngineError.backend("openai \(http.statusCode): \(bodyText.prefix(200))")
        }

        // Parse { choices: [{ message: { content: "<json>" }}] }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw ToneEngineError.decoding("unexpected openai response shape")
        }

        return try ToneEngine.decode(content)
    }

    /// Decode the JSON-schema string (a JSON object) into a [String: Any]
    /// suitable for JSONSerialization. Avoids re-encoding the schema as text.
    private func jsonSchemaObject() -> [String: Any] {
        guard let data = TonePrompts.jsonSchema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
