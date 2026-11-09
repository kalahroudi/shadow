import Foundation

/// Recorded-shape fixtures. SSE: Ollama's and OpenAI's chat-completions streams; stream-json: the Claude CLI's.
enum LLMFixtures {
    static func chunk(_ content: String, role: Bool = true, finish: String? = nil, extra: String = "") -> String {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let r = role ? "\"role\":\"assistant\"," : ""
        let f = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"m\",\(extra)\"choices\":[{\"index\":0,\"delta\":{\(r)\"content\":\"\(escaped)\"},\"finish_reason\":\(f)}]}\n\n"
    }

    static let ollamaSSE = chunk("Use ") + chunk("the **STAR** ") + chunk("method.\n- Situation") + chunk("", finish: "stop") + "data: [DONE]\n\n"
    static let ollamaText = ["Use ", "the **STAR** ", "method.\n- Situation"]

    /// OpenAI starts with a role-only chunk, carries `usage: null`, and may send keep-alive comments.
    static let openAISSE = ": keep-alive\n\n"
        + "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"model\":\"gpt\",\"usage\":null,\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n"
        + chunk("Hello", role: false) + chunk(", world", role: false) + chunk("", role: false, finish: "stop") + "data: [DONE]\n\n"
    static let openAIText = ["Hello", ", world"]

    static let modelsJSON = """
    {"object":"list","data":[{"id":"llama3.2:latest","object":"model","created":1,"owned_by":"library"},{"id":"qwen2.5:7b","object":"model","created":2,"owned_by":"library"}]}
    """

    static func line(_ json: String) -> String { json + "\n" }
    static let cliInit = line(#"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"s","tools":[],"mcp_servers":[]}"#)
    static func cliDelta(_ text: String) -> String {
        line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"session_id":"s"}"#)
    }
    static func cliAssistant(_ text: String) -> String {
        line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"session_id":"s"}"#)
    }
    static func cliResult(_ text: String, isError: Bool = false) -> String {
        line(#"{"type":"result","subtype":"\#(isError ? "error_during_execution" : "success")","is_error":\#(isError),"result":"\#(text)","session_id":"s"}"#)
    }
    static let cliNormal = cliInit + cliDelta("2+2 is") + cliDelta(" 4.") + cliAssistant("2+2 is 4.") + cliResult("2+2 is 4.")
}
