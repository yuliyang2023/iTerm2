import Foundation

// Export the canonical display history, including tool requests/results that
// are hidden as separate bubbles. Never export provider context or wire blobs.
enum ChatMarkdownExporter {
    static func markdown(chat: Chat,
                         messages: [Message],
                         exportedAt: Date = Date(),
                         turnInProgress: Bool = false) -> String {
        let dates = ISO8601DateFormatter()
        var sections = [
            "# \(escapedLabel(chat.title))",
            "- Created: \(dates.string(from: chat.creationDate))\n- Exported: \(dates.string(from: exportedAt))"
        ]
        if let model = chat.modelName {
            sections.append("- Model: \(escapedLabel(model))")
        }
        if turnInProgress {
            sections.append("*This conversation is still in progress. The latest reply may be incomplete.*")
        }
        for message in messages {
            guard let body = body(for: message.content), !body.isEmpty else { continue }
            let role: String
            switch message.content {
            case .remoteCommandResponse: role = "Tool result"
            case .remoteCommandRequest, .selectSessionRequest: role = "Tool call"
            case .terminalCommand: role = "Terminal"
            case .clientLocal, .watcherEvent, .unsupported: role = "System"
            default: role = message.author == .user ? "User" : "AI"
            }
            sections.append("## \(role) — \(dates.string(from: message.sentDate))\n\n\(body)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func suggestedFilename(title: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = title.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 180 { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { name = "AI Chat" }
        return name + ".md"
    }

    private static func body(for content: Message.Content) -> String? {
        switch content {
        case .plainText(let text, _), .markdown(let text):
            return text
        case .multipart(let parts, _):
            return parts.compactMap { part -> String? in
                switch part {
                case .plainText(let text), .markdown(let text): return text
                case .attachment(let attachment): return attachmentBody(attachment)
                case .context: return nil
                }
            }.joined(separator: "\n\n")
        case .explanationRequest(let request):
            var parts = [request.question]
            if let command = request.command {
                parts.append("### Command\n\n" + codeBlock(command, language: "sh"))
            }
            parts.append("### Terminal content\n\n" + codeBlock(request.originalString.string))
            if request.truncated { parts.append("*The original terminal content was truncated.*") }
            return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .explanationResponse(_, _, let markdown):
            return markdown
        case .terminalCommand(let command):
            var parts = ["### Command\n\n" + codeBlock(command.command, language: "sh")]
            if let directory = command.directory {
                parts.append("Directory: " + escapedLabel(directory))
            }
            parts.append("### Output\n\n" + codeBlock(command.output))
            parts.append("Exit code: \(command.exitCode)")
            return parts.joined(separator: "\n\n")
        case .remoteCommandRequest(let payload, _):
            let arguments: String?
            switch payload {
            case .classic: arguments = payload.llmMessage.function_call?.arguments
            case .external(let external): arguments = external.argsJSON
            }
            let title = "Tool: " + escapedLabel(payload.name)
            if let arguments { return title + "\n\n" + codeBlock(arguments, language: "json") }
            return title + "\n\n" + payload.markdownDescription
        case .remoteCommandResponse(let result, _, let name, _):
            let title = "Tool: " + escapedLabel(name)
            switch result {
            case .success(let output): return title + "\n\n" + codeBlock(output)
            case .failure(let error): return title + "\n\nFailed:\n\n" + codeBlock(error.localizedDescription)
            }
        case .selectSessionRequest(let original, _):
            return body(for: original.content)
        case .clientLocal(let local):
            if case .notice(let text) = local.action { return text }
            return nil
        case .watcherEvent(let event):
            return event.detail
        case .unsupported:
            return "This message requires a newer version of iTerm2 to view."
        case .renameChat, .append, .appendAttachment, .commit, .userCommand,
                .setPermissions, .vectorStoreCreated:
            // Deltas have already been applied to their canonical message.
            return nil
        }
    }

    private static func attachmentBody(_ attachment: LLM.Message.Attachment) -> String? {
        switch attachment.type {
        case .code(let code): return codeBlock(code)
        case .file(let file):
            return "Attachment: \(escapedLabel(file.name)) (\(escapedLabel(file.mimeType))); file contents are not embedded."
        case .fileID(_, let name):
            return "Attachment: \(escapedLabel(name)); file contents are not embedded."
        case .statusUpdate: return nil
        }
    }

    private static func escapedLabel(_ text: String) -> String {
        let singleLine = text.components(separatedBy: .newlines).joined(separator: " ")
        return singleLine.reduce(into: "") { result, character in
            if "\\`*_{}[]<>()#+-.!|".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func codeBlock(_ text: String, language: String = "") -> String {
        var longestRun = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let newline = text.hasSuffix("\n") ? "" : "\n"
        return "\(fence)\(language)\n\(text)\(newline)\(fence)"
    }
}
