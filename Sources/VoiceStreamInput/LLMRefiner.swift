import Foundation

enum LLMRefinerError: LocalizedError {
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "LLM 返回格式无效。"
        case .serverError(let message):
            return message
        }
    }
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

struct ChatCompletionResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        let message: ChatMessage
    }

    let choices: [Choice]
}

actor LLMRefiner {
    func refine(_ text: String, configuration: LLMConfiguration) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        let endpoint = configuration.baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let payload = ChatCompletionRequest(
            model: configuration.model,
            messages: [
                ChatMessage(
                    role: "system",
                    content: """
                    你是极度保守的语音转录纠错器。
                    只修复非常明显的识别错误。
                    只允许：
                    1. 修复中文同音错字。
                    2. 把被错误音译成中文的英文技术术语改回正确英文，如 配森->Python，杰森->JSON。
                    3. 修复显而易见的中英文混输错误。
                    严禁改写、润色、扩写、缩写、删减、调整语气、补充标点风格。
                    如果原文看起来已经正确，必须逐字原样返回。
                    只返回最终文本本身，不要解释，不要加引号，不要 Markdown。
                    """
                ),
                ChatMessage(role: "user", content: text)
            ],
            temperature: 0
        )

        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMRefinerError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "LLM 请求失败。"
            throw LLMRefinerError.serverError(message)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LLMRefinerError.invalidResponse
        }

        let refined = content.trimmingCharacters(in: .newlines)
        return refined.isEmpty ? text : refined
    }
}
