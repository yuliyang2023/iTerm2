import XCTest
@testable import iTerm2SharedARC

final class ChatMarkdownExporterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)
    private let chat = Chat(title: "Export test", permissions: "", modelName: "test-model")

    private func message(_ content: Message.Content, author: Participant = .agent) -> Message {
        Message(chatID: chat.id, author: author, content: content, sentDate: date, uniqueID: UUID())
    }

    func testExportPreservesMarkdownOrderAndOmitsInternalContextAndDeltas() throws {
        let messages = [
            message(.plainText("User question", context: "PRIVATE CONTEXT"), author: .user),
            message(.markdown("AI reply\n\n```sh\necho hello\n```")),
            message(.append(string: "DUPLICATE DELTA", uuid: UUID())),
            message(.commit(UUID())),
            message(.setPermissions([])),
            message(.multipart([.context("HIDDEN CONTEXT"), .markdown("Follow-up")], vectorStoreID: nil))
        ]
        let result = ChatMarkdownExporter.markdown(chat: chat, messages: messages, exportedAt: date)
        XCTAssertTrue(result.contains("AI reply\n\n```sh\necho hello\n```"))
        let user = try XCTUnwrap(result.range(of: "User question"))
        let ai = try XCTUnwrap(result.range(of: "AI reply"))
        let followUp = try XCTUnwrap(result.range(of: "Follow-up"))
        XCTAssertLessThan(user.lowerBound, ai.lowerBound)
        XCTAssertLessThan(ai.lowerBound, followUp.lowerBound)
        XCTAssertFalse(result.contains("PRIVATE CONTEXT"))
        XCTAssertFalse(result.contains("HIDDEN CONTEXT"))
        XCTAssertFalse(result.contains("DUPLICATE DELTA"))
        XCTAssertTrue(result.contains("## User — 1970-01-01T00:00:00Z"))
    }

    func testTerminalOutputCannotCloseItsCodeFence() {
        let command = TerminalCommand(command: "echo hello", output: "before\n```\nafter",
                                      exitCode: 7, url: URL(string: "https://example.com")!)
        let result = ChatMarkdownExporter.markdown(chat: chat, messages: [message(.terminalCommand(command))])
        XCTAssertTrue(result.contains("```sh\necho hello\n```"))
        XCTAssertTrue(result.contains("````\nbefore\n```\nafter\n````"))
        XCTAssertTrue(result.contains("Exit code: 7"))
    }

    func testToolResultsAndAttachmentsAreExportedWithoutEmbeddingFileContents() {
        let tool = ExternalRemoteCommand(llmMessage: LLM.Message(role: .assistant, content: ""),
                                         name: "read", argsJSON: "{\"path\":\"test\"}",
                                         markdownDescription: "Read test")
        let file = LLM.Message.Attachment(inline: false, id: "attachment",
                                         type: .file(.init(name: "report.txt", content: Data("PRIVATE FILE".utf8),
                                                           mimeType: "text/plain", localPath: "/private/report.txt")))
        let result = ChatMarkdownExporter.markdown(chat: chat, messages: [
            message(.remoteCommandRequest(.external(tool), safe: nil)),
            message(.remoteCommandResponse(.success("tool output"), UUID(), "read", nil), author: .user),
            message(.multipart([.attachment(file)], vectorStoreID: nil))
        ])
        XCTAssertTrue(result.contains("## Tool call"))
        XCTAssertTrue(result.contains("```json\n{\"path\":\"test\"}\n```"))
        XCTAssertTrue(result.contains("## Tool result"))
        XCTAssertTrue(result.contains("tool output"))
        XCTAssertTrue(result.contains("report\\.txt"))
        XCTAssertTrue(result.contains("file contents are not embedded"))
        XCTAssertFalse(result.contains("PRIVATE FILE"))
        XCTAssertFalse(result.contains("/private/report.txt"))
    }

    func testInProgressSnapshotAndSafeFilename() {
        let result = ChatMarkdownExporter.markdown(chat: chat, messages: [], turnInProgress: true)
        XCTAssertTrue(result.contains("latest reply may be incomplete"))
        XCTAssertEqual(ChatMarkdownExporter.suggestedFilename(title: " /a:b\\c\n "), "a b c.md")
        XCTAssertEqual(ChatMarkdownExporter.suggestedFilename(title: ".."), "AI Chat.md")
        XCTAssertLessThanOrEqual(ChatMarkdownExporter.suggestedFilename(title: String(repeating: "终端", count: 100)).utf8.count, 183)
    }
}
