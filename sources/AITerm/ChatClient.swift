//
//  ChatClient.swift
//  iTerm2
//
//  Created by George Nachman on 2/12/25.
//

// High level interface for AI chat clients.
@MainActor
class ChatClient {
    enum RemoteCommandDecision: String {
        case allowOnce, allowAlways, denyOnce, denyAlways, rejectAndRevise
    }

    private class RemoteRequest {
        let chatID: String
        let command: RemoteCommand
        let safe: Bool?
        var targetSessionID: String?
        var pending = true

        init(chatID: String, command: RemoteCommand, safe: Bool?) {
            self.chatID = chatID
            self.command = command
            self.safe = safe
        }
    }
    // Retain consumed IDs so delayed phone approvals and session-picker callbacks
    // cannot resurrect a request after Stop. Approvals themselves are not durable.
    private var remoteRequests = [UUID: RemoteRequest]()
    private var observers = [NSObjectProtocol]()
    private static var _instance: ChatClient?
    private var rewriteMessageID = [UUID: UUID]()
    private class RemoteExecution {
        let chatID: String
        let statusMessageID = UUID()
        weak var session: PTYSession?
        let ownsTerminalOperation: Bool
        var canceled = false

        init(chatID: String, session: PTYSession, request: RemoteCommand) {
            self.chatID = chatID
            self.session = session
            switch request.content {
            case .executeCommand, .getManPage:
                ownsTerminalOperation = true
            default:
                ownsTerminalOperation = false
            }
        }
    }
    private var remoteExecutions = [UUID: RemoteExecution]()

    static var instance: ChatClient? {
        if _instance == nil {
            _instance = ChatClient()
        }
        return _instance
    }
    private let broker: ChatBroker
    private let sessionForReference: (String) -> PTYSession?
    let model: ChatListModel

    convenience init?() {
        guard let broker = ChatBroker.instance else { return nil }
        self.init(broker: broker)
    }

    init(broker: ChatBroker,
         sessionForReference: @escaping (String) -> PTYSession? = {
             iTermController.sharedInstance().anySession(forReference: $0)
         }) {
        self.model = broker.listModel
        self.broker = broker
        self.sessionForReference = sessionForReference
        broker.processors.append { [weak self] message, chatID, partial in
            guard let self else {
                return message
            }
            return processMessage(message, chatID: chatID, partial: partial)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ChatListModel.sessionBindingDidChange, object: model, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let chatID = notification.userInfo?[ChatListModel.chatIDUserInfoKey] as? String else { return }
                    // Linking a requested session is part of a live selection,
                    // rather than replacing the target of an existing approval.
                    let selecting = self.remoteRequests.values.contains {
                        $0.chatID == chatID && $0.pending && $0.targetSessionID == nil
                    }
                    if selecting { return }
                    let hasPending = self.remoteRequests.values.contains { $0.chatID == chatID && $0.pending }
                    let hasExecution = self.remoteExecutions.values.contains { $0.chatID == chatID }
                    if hasPending || hasExecution || TurnStatusModel.instance.inProgress(chatID: chatID) {
                        try? self.publishUserMessage(chatID: chatID, content: .userCommand(.stop))
                    }
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: ChatListModel.chatWasDeleted, object: nil, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let chatID = notification.userInfo?[ChatListModel.chatIDUserInfoKey] as? String,
                          self.model.chat(id: chatID) == nil else { return }
                    self.cancelRemoteCommands(chatID: chatID)
                    self.remoteRequests = self.remoteRequests.filter { $0.value.chatID != chatID }
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .iTermSessionWillTerminate, object: nil, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let session = notification.object as? PTYSession else { return }
                    let ids = Set(self.remoteRequests.values.filter {
                        $0.targetSessionID == session.stableID && $0.pending
                    }.map(\.chatID)).union(self.remoteExecutions.values.filter {
                        $0.session === session
                    }.map(\.chatID))
                    for chatID in ids {
                        try? self.publishUserMessage(chatID: chatID, content: .userCommand(.stop))
                    }
                }
            })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Transform Agent messages so they are useful to the client.
    private func processMessage(_ message: Message,
                                chatID: String,
                                partial: Bool) -> Message? {
        if message.author == .user {
            if case .userCommand(.stop) = message.content {
                cancelRemoteCommands(chatID: chatID)
            }
            if case .remoteCommandResponse(_, let id, _, _) = message.content {
                remoteRequests[id]?.pending = false
            }
            return message
        }
        switch message.content {
        case .userCommand:
            it_fatalError("Agent should not send userCommand")
        case .remoteCommandRequest(let payload, safe: let safe):
            it_assert(!partial)
            // AITerm's client only processes .classic payloads. .external
            // payloads come from orchestration mode and have their own
            // client; ignore them here.
            guard case let .classic(request) = payload else {
                return message
            }
            return processRemoteCommandRequest(chatID: chatID,
                                               message: message,
                                               request: request,
                                               safe: safe)
        case .plainText, .markdown, .explanationRequest, .remoteCommandResponse,
                .selectSessionRequest, .clientLocal, .renameChat, .setPermissions,
                .terminalCommand, .multipart, .vectorStoreCreated, .watcherEvent,
                .unsupported:
            return message
        case let .append(string: string, uuid: uuid):
            it_assert(partial)
            return processAppend(appendMessage: message, stringOrAttachment: .string(string), uuid: uuid, chatID: chatID)
        case let .appendAttachment(attachment: attachment, uuid: uuid):
            it_assert(partial)
            return processAppend(appendMessage: message, stringOrAttachment: .attachment(attachment), uuid: uuid, chatID: chatID)
        case .commit(let uuid):
            return processCommit(finalMessage: message, messageID: uuid, chatID: chatID)
        case .explanationResponse(let response, let update, let markdown):
            // This is either the entire message or the initial in a streaming rsponse.
            guard let newMarkdown = markdownForExplanationResponse(response: response,
                                                                   update: update,
                                                                   chatID: chatID,
                                                                   messageID: message.uniqueID) else {
                return nil
            }
            var temp = message
            temp.content = .explanationResponse(response, nil, markdown: markdown + newMarkdown)
            return temp
        }
    }

    // Use "" as default permissions
    func create(chatWithTitle title: String,
                terminalSessionGuid: String?,
                browserSessionGuid: String?,
                initialMessages: [Message],
                permissions: String) throws -> String {
        return try broker.create(chatWithTitle: title,
                                 terminalSessionGuid: terminalSessionGuid,
                                 browserSessionGuid: browserSessionGuid,
                                 permissions: permissions,
                                 initialMessages: initialMessages)
    }

    func delete(chatID: String) throws {
        try publishUserMessage(chatID: chatID, content: .userCommand(.stop))
        try broker.delete(chatID: chatID)
        remoteRequests = remoteRequests.filter { $0.value.chatID != chatID }
    }

    func deleteMessages(_ messageIDs: [UUID], fromChatID chatID: String) {
        broker.deleteMessages(messageIDs, fromChatID: chatID)
    }

    func subscribe(chatID: String?,
                   registrationProvider: AIRegistrationProvider?,
                   closure: @escaping (ChatBroker.Update) -> ()) -> ChatBroker.Subscription {
        broker.subscribe(chatID: chatID, registrationProvider: registrationProvider, closure: closure)
    }

    func publish(message: Message, toChatID chatID: String, partial: Bool) throws {
        try broker.publish(message: message, toChatID: chatID, partial: partial)
    }

    func publishMessageFromUser(chatID: String, content: Message.Content) throws {
        try broker.publishMessageFromUser(chatID: chatID, content: content)
    }

    func publishMessageFromAgent(chatID: String, content: Message.Content) throws {
        try broker.publishMessageFromAgent(chatID: chatID, content: content)
    }
    
    private func processRemoteCommandRequest(chatID: String,
                                             message submittedMessage: Message,
                                             request submittedRequest: RemoteCommand,
                                             safe submittedSafe: Bool?) -> Message? {
        var message = submittedMessage
        let pending: RemoteRequest
        if let existing = remoteRequests[message.uniqueID] {
            // Only a live session-selection request may be republished.
            guard existing.chatID == chatID, existing.pending,
                  existing.targetSessionID == nil else { return nil }
            pending = existing
        } else {
            guard !requestWasAnswered(chatID: chatID, requestID: message.uniqueID) else { return nil }
            pending = RemoteRequest(chatID: chatID, command: submittedRequest, safe: submittedSafe)
            remoteRequests[message.uniqueID] = pending
        }
        let request = pending.command
        let safe = pending.safe
        // A phone's picker response may carry a stale copy of the message. Use
        // the original command and safety verdict, never the resubmitted payload.
        message.content = .remoteCommandRequest(.classic(request), safe: safe)
        let maybeGuid = if request.content.permissionCategory.isBrowserSpecific {
            model.chat(id: chatID)?.browserSessionGuid
        } else {
            model.chat(id: chatID)?.terminalSessionGuid
        }
        guard let guid = maybeGuid,
              let session = sessionForReference(guid) else {
            return Message(chatID: chatID,
                           author: .agent,
                           content: .selectSessionRequest(message, terminal: !request.content.permissionCategory.isBrowserSpecific),
                           sentDate: Date(),
                           uniqueID: UUID())
        }
        pending.targetSessionID = session.stableID
        let permission = RemoteCommandExecutor.instance.permission(chatID: chatID,
                                                                   inSessionGuid: guid,
                                                                   category: request.content.permissionCategory)
        switch permission {
        case .never:
            // Persist the tool request before its (denial) response so the
            // rebuilt history has a matching tool_use for every tool_result.
            // We still return nil so the request is not delivered to the
            // live UI; ChatViewControllerModel hides this resolved request on
            // reload. Historically the request was squelched entirely, which
            // left an orphan tool_result that the next turn had to repair.
            do {
                try model.append(message: message, toChatID: chatID)
                try rejectRemoteCommandRequest(inChat: chatID, requestUUID: message.uniqueID,
                                               request: request, forRevision: false)
            } catch {
                failRemoteCommand(request, chatID: chatID, requestID: message.uniqueID, error: error)
            }
            return nil
        case .always, .ask:
            // Park on the user's Allow/Deny when the shared predicate says so (ask
            // always; always only when the safety check flagged it). Returning the
            // message surfaces it in the UI.
            if permission.parksOnApproval(safe: safe) {
                return message
            }
            // Auto-run (.always + safe). See .never above: persist the request (so
            // the next turn's history is complete) then run the tool. Returning nil
            // keeps it out of the live UI; the resolved request is hidden on reload.
            do {
                try model.append(message: message, toChatID: chatID)
                try performRemoteCommand(request, in: session, chatID: chatID,
                                         messageUniqueID: message.uniqueID)
            } catch {
                failRemoteCommand(request, chatID: chatID, requestID: message.uniqueID, error: error)
            }
            return nil
        }
    }

    func publishClientLocalMessage(chatID: String,
                                   action: ClientLocal.Action) throws {
        try broker.publishMessageFromAgent(chatID: chatID,
                                           content: .clientLocal(.init(action: action)))
    }

    func publishUserMessage(chatID: String,
                            content: Message.Content) throws {
        try broker.publish(message: .init(chatID: chatID,
                                          author: .user,
                                          content: content,
                                          sentDate: Date(),
                                          uniqueID: UUID()),
                           toChatID: chatID,
                           partial: false)
    }

    func publishNotice(chatID: String, notice: String) throws {
        try broker.publishNotice(chatID: chatID, notice: notice)
    }

    private func requestWasAnswered(chatID: String, requestID: UUID) -> Bool {
        model.messages(forChat: chatID, createIfNeeded: false)?.contains {
            if case .remoteCommandResponse(_, let id, _, _) = $0.content { return id == requestID }
            return false
        } ?? false
    }

    func isRemoteCommandRequestPending(chatID: String, requestID: UUID) -> Bool {
        guard let request = remoteRequests[requestID], request.chatID == chatID else { return false }
        return request.pending && !requestWasAnswered(chatID: chatID, requestID: requestID)
    }

    func resumeRemoteCommandAfterSessionSelection(chatID: String, requestID: UUID) {
        guard isRemoteCommandRequestPending(chatID: chatID, requestID: requestID),
              let pending = remoteRequests[requestID], pending.targetSessionID == nil else { return }
        let chat = model.chat(id: chatID)
        let guid = pending.command.content.permissionCategory.isBrowserSpecific
            ? chat?.browserSessionGuid : chat?.terminalSessionGuid
        do {
            guard let guid, sessionForReference(guid) != nil else {
                throw AIError(String(localized: "ChatClient.SelectedSessionUnavailable", defaultValue: "The selected session is no longer available. The request was not executed.", comment: "AI chat control or notice shown to the user"))
            }
            try publish(message: Message(chatID: chatID, author: .agent,
                                         content: .remoteCommandRequest(.classic(pending.command), safe: pending.safe),
                                         sentDate: Date(), uniqueID: requestID), toChatID: chatID, partial: false)
        } catch {
            failRemoteCommand(pending.command, chatID: chatID, requestID: requestID, error: error)
        }
    }

    // Both Mac and Companion use this gate. Consume approvals before calling any
    // terminal code, and resolve the target recorded when the request was shown.
    func decideRemoteCommandRequest(chatID: String, requestID: UUID,
                                    decision: RemoteCommandDecision) {
        guard isRemoteCommandRequestPending(chatID: chatID, requestID: requestID),
              let pending = remoteRequests[requestID] else {
            RLog("Ignoring stale AI command decision \(requestID)")
            return
        }
        let request = pending.command
        let category = request.content.permissionCategory
        let chat = model.chat(id: chatID)
        let guid = category.isBrowserSpecific ? chat?.browserSessionGuid : chat?.terminalSessionGuid
        let session = guid.flatMap(sessionForReference)
        do {
            // A denial with no selected session is still valid. No persistent
            // permission may be changed for a different target, however.
            if let target = pending.targetSessionID, session?.stableID != target {
                throw AIError(String(localized: "ChatClient.LinkedSessionChanged", defaultValue: "The linked session changed or closed. The old request was not executed. Send a new message for the current session.", comment: "AI chat control or notice shown to the user"))
            }
            switch decision {
            case .denyOnce, .denyAlways, .rejectAndRevise:
                pending.pending = false
                if decision != .denyOnce, let guid {
                    try model.setPermission(chat: chatID,
                                            permission: decision == .denyAlways ? .never : .ask,
                                            guid: guid, category: category)
                }
                try rejectRemoteCommandRequest(inChat: chatID, requestUUID: requestID,
                                               request: request, forRevision: decision == .rejectAndRevise)
            case .allowOnce, .allowAlways:
                guard let session else {
                    throw AIError(String(localized: "ChatClient.NoSession", defaultValue: "No session is linked. The request was not executed.", comment: "AI chat control or notice shown to the user"))
                }
                guard pending.targetSessionID != nil else {
                    throw AIError(String(localized: "ChatClient.SelectSession", defaultValue: "Select a session before approving this request.", comment: "AI chat control or notice shown to the user"))
                }
                if decision == .allowAlways, let guid {
                    try model.setPermission(chat: chatID, permission: .always,
                                            guid: guid, category: category)
                }
                try performRemoteCommand(request, in: session, chatID: chatID, messageUniqueID: requestID)
            }
            if decision == .allowAlways || decision == .denyAlways || decision == .rejectAndRevise {
                let updated = model.chat(id: chatID)
                try publishUserMessage(chatID: chatID, content: .setPermissions(
                    RemoteCommandExecutor.instance.allowedCategories(
                        chatID: chatID, terminalGuid: updated?.terminalSessionGuid,
                        browserGuid: updated?.browserSessionGuid)))
            }
        } catch {
            failRemoteCommand(request, chatID: chatID, requestID: requestID, error: error)
        }
    }

    private func failRemoteCommand(_ request: RemoteCommand, chatID: String,
                                   requestID: UUID, error: Error) {
        RLog("AI remote command failed: \(error)")
        remoteRequests[requestID]?.pending = false
        // Stop before recording a result, so an execution/publication failure
        // cannot leave a parked dispatcher or launch a retry without the user.
        do {
            if requestWasAnswered(chatID: chatID, requestID: requestID) {
                try publishUserMessage(chatID: chatID, content: .userCommand(.stop))
            } else {
                try rejectRemoteCommandRequest(inChat: chatID, requestUUID: requestID,
                                               request: request, forRevision: false)
            }
        } catch {
            try? publishUserMessage(chatID: chatID, content: .userCommand(.stop))
            RLog("Could not record AI command failure: \(error)")
        }
        try? publishNotice(chatID: chatID, notice: String(localized: "ChatClient.RequestFailed", defaultValue: "AI request failed: \(error.localizedDescription)", comment: "AI chat control or notice shown to the user"))
    }

    private func cancelRemoteCommands(chatID: String) {
        for request in remoteRequests.values where request.chatID == chatID {
            request.pending = false
        }
        let executions = remoteExecutions.filter { $0.value.chatID == chatID }
        if !executions.isEmpty {
            RLog("Canceling \(executions.count) AI remote command(s)")
        }
        for (id, execution) in executions {
            remoteExecutions.removeValue(forKey: id)
            execution.canceled = true
            if execution.ownsTerminalOperation {
                execution.session?.cancelRemoteCommand(interrupt: true)
            }
        }
    }

    func canCancelRemoteCommand(chatID: String, statusMessageID: UUID) -> Bool {
        return remoteExecutions.values.contains {
            $0.chatID == chatID && $0.statusMessageID == statusMessageID &&
                !$0.canceled && $0.ownsTerminalOperation && $0.session?.isExecutingRemoteCommand == true
        }
    }

    func canCollectRemoteCommandOutput(chatID: String, statusMessageID: UUID) -> Bool {
        remoteExecutions.values.contains {
            $0.chatID == chatID && $0.statusMessageID == statusMessageID &&
                !$0.canceled && $0.session?.canCollectRemoteCommandOutput == true
        }
    }

    func collectRemoteCommandOutput(chatID: String, statusMessageID: UUID) {
        guard let execution = remoteExecutions.values.first(where: {
            $0.chatID == chatID && $0.statusMessageID == statusMessageID && !$0.canceled
        }) else { return }
        execution.session?.collectRemoteCommandOutput()
    }

    func stopAllRemoteCommands() {
        // Closing the one chat window must also release commands belonging to
        // chats that are currently hidden behind the selected chat.
        let chatIDs = Set(remoteExecutions.values.map { $0.chatID })
            .union(remoteRequests.values.filter(\.pending).map(\.chatID))
            .union((0..<model.count).map { model.chat(at: $0).id }.filter {
                TurnStatusModel.instance.inProgress(chatID: $0)
            })
        for chatID in chatIDs {
            try? publishUserMessage(chatID: chatID, content: .userCommand(.stop))
            cancelRemoteCommands(chatID: chatID)
        }
    }

    func performRemoteCommand(_ request: RemoteCommand,
                              in session: PTYSession,
                              chatID: String,
                              messageUniqueID: UUID) throws {
        guard let pending = remoteRequests[messageUniqueID], pending.chatID == chatID,
              pending.pending, pending.targetSessionID == session.stableID,
              !requestWasAnswered(chatID: chatID, requestID: messageUniqueID) else {
            RLog("Ignoring inactive AI command approval \(messageUniqueID)")
            return
        }
        pending.pending = false
        var done = false
        let status: String
        if case .executeCommand(let command) = request.content {
            if session.runningRemoteCommand.bastionCompatibilityEnabled {
                status = RunningRemoteCommand.canAutomaticallyCollectUnwrappedCommand(command.command)
                    ? String(localized: "AIChat.Activity.BastionSingleLine", defaultValue: "Command sent; click Collect Output when finished, or wait for Shell Integration…", comment: "Progress status displayed below the AI chat transcript")
                    : String(localized: "AIChat.Activity.BastionMultiline", defaultValue: "Multiline command sent; click Collect Output when the entire script finishes…", comment: "Progress status displayed below the AI chat transcript")
            } else {
                status = String(localized: "AIChat.Activity.ExecutingTerminal", defaultValue: "Terminal executing; waiting for command completion…", comment: "Progress status displayed below the AI chat transcript")
            }
        } else if request.content.permissionCategory.isBrowserSpecific {
            status = String(localized: "AIChat.Activity.WaitingForBrowser", defaultValue: "Waiting for browser response…", comment: "Progress status displayed below the AI chat transcript")
        } else {
            status = String(localized: "AIChat.Activity.ReadingTerminal", defaultValue: "Reading terminal response…", comment: "Progress status displayed below the AI chat transcript")
        }
        broker.publish(activityStatus: status, toChatID: chatID)
        if request.shouldPublishNotice {
            try broker.publishNotice(chatID: chatID, notice: "\(request.markdownDescription)…")
        }
        let execution = RemoteExecution(chatID: chatID, session: session, request: request)
        remoteExecutions[messageUniqueID] = execution
        do {
            try session.execute(request, collectingOutput: { [weak self] in
                guard !execution.canceled else { return }
                self?.broker.publish(activityStatus: String(localized: "AIChat.Activity.CollectingOutput", defaultValue: "Collecting terminal output…", comment: "Progress status displayed below the AI chat transcript"), toChatID: chatID)
            }) { [weak self] response, userNotice in
                guard !done else { return }
                done = true
                self?.remoteExecutions.removeValue(forKey: messageUniqueID)
                // The stop message cancels the agent's pending tool. Sending a
                // tool result here could resume it before stop reaches it.
                guard !execution.canceled else { return }
                do {
                    try self?.respondSuccessfullyToRemoteCommandRequest(inChat: chatID,
                                                                        requestUUID: messageUniqueID,
                                                                        message: response,
                                                                        functionCallName: request.llmMessage.function_call?.name ?? "Unknown function call name",
                                                                        functionCallID: request.llmMessage.functionCallID,
                                                                        userNotice: userNotice)
                } catch {
                    self?.failRemoteCommand(request, chatID: chatID, requestID: messageUniqueID, error: error)
                }
            }
        } catch {
            remoteExecutions.removeValue(forKey: messageUniqueID)
            throw error
        }
        if !done {
            try publish(message: Message(chatID: chatID,
                                         author: .agent,
                                         content: .clientLocal(ClientLocal(action: .executingCommand(request))),
                                         sentDate: Date(),
                                         uniqueID: execution.statusMessageID),
                        toChatID: chatID,
                        partial: false)
        }
    }

    func rejectRemoteCommandRequest(inChat chatID: String,
                                    requestUUID: UUID,
                                    request: RemoteCommand,
                                    forRevision: Bool) throws {
        guard !requestWasAnswered(chatID: chatID, requestID: requestUUID) else { return }
        remoteRequests[requestUUID]?.pending = false
        // Stop BEFORE recording the denial. Delivering a successful tool result
        // resumes the parked LLM dispatcher and can generate another command.
        try publishUserMessage(chatID: chatID, content: .userCommand(.stop))
        // Session-selection requests embed the original call rather than storing
        // it as a separate row. Preserve its tool_use before recording a denial.
        if model.messages(forChat: chatID, createIfNeeded: false)?.contains(where: {
            $0.uniqueID == requestUUID
        }) != true {
            try model.append(message: Message(chatID: chatID, author: .agent,
                                               content: .remoteCommandRequest(.classic(request), safe: nil),
                                               sentDate: Date(), uniqueID: requestUUID), toChatID: chatID)
        }
        // Keep a paired tool result for the NEXT user-initiated turn, but do not
        // publish it through the broker or resume the rejected turn.
        let result = forRevision
            ? "The user rejected this command and will provide revised instructions. The command was not executed. Generate a new command from the user’s next message and wait for approval."
            : "The user denied this request. It was not executed. This turn was stopped; wait for a new user message."
        try model.append(message: Message(chatID: chatID,
                                         author: .user,
                                         content: .remoteCommandResponse(.success(result), requestUUID,
                                                                        request.content.functionName,
                                                                        request.llmMessage.functionCallID),
                                         sentDate: Date(), uniqueID: UUID()), toChatID: chatID)
        try publishNotice(chatID: chatID, notice: forRevision
                          ? String(localized: "ChatClient.RejectedNotice", defaultValue: "Command rejected. Enter your changes below; the revised command will require approval.", comment: "AI chat control or notice shown to the user")
                          : String(localized: "ChatClient.DeniedNotice", defaultValue: "Request denied. AI stopped and is waiting for your next message.", comment: "AI chat control or notice shown to the user"))
        broker.publish(activityStatus: String(localized: "AIChat.Activity.WaitingForInstructions", defaultValue: "Waiting for your instructions…", comment: "Progress status displayed below the AI chat transcript"), toChatID: chatID)
    }

    func respondSuccessfullyToRemoteCommandRequest(inChat chatID: String,
                                                   requestUUID: UUID,
                                                   message: String,
                                                   functionCallName: String,
                                                   functionCallID: LLM.Message.FunctionCallID?,
                                                   userNotice: String?) throws {
        if let userNotice {
            try broker.publishNotice(chatID: chatID, notice: userNotice)
        }
        try broker.publish(message: Message(chatID: chatID,
                                            author: .user,
                                            content: .remoteCommandResponse(
                                                .success(message),
                                                requestUUID,
                                                functionCallName,
                                                functionCallID),
                                            sentDate: Date(),
                                            uniqueID: UUID()),
                           toChatID: chatID,
                           partial: false)
    }

    private enum ExplainUserInfoKeys: String {
        case context
    }

    // Request an AI explanation, create a chat, and reveal the chat window.
    func explain(_ request: AIExplanationRequest,
                 title: String,
                 scope: iTermVariableScope) throws {
        guard let chatWindowController = ChatWindowController.instance(showErrors: false) else {
            return
        }
        chatWindowController.showChatWindow()
        guard let window = chatWindowController.window else {
            return
        }
        if AITermControllerRegistrationHelper.instance.registration == nil {
            AITermControllerRegistrationHelper.instance.requestRegistration(in: window) { [weak self] _ in
                if (AITermControllerRegistrationHelper.instance.registration != nil) {
                    try? self?.explain(request, title: title, scope: scope)
                } else {
                    ChatWindowController.instance(showErrors: false)?.window?.performClose(nil)
                }
            }
            return
        }
        let chatID = try broker.create(chatWithTitle: title,
                                       terminalSessionGuid: request.context.sessionID,
                                       browserSessionGuid: nil,
                                       permissions: "",
                                       initialMessages: [])
        let initialMessage = Message(chatID: chatID,
                                     author: .user,
                                     content: .explanationRequest(request: request),
                                     sentDate: Date(),
                                     uniqueID: UUID())
        try broker.publish(message: initialMessage, toChatID: chatID, partial: false)

        chatWindowController.select(chatID: chatID)
    }

    enum StringOrAttachment {
        case string(String)
        case attachment(LLM.Message.Attachment)
    }
    private func processAppend(appendMessage: Message,
                               stringOrAttachment: StringOrAttachment,
                               uuid upstreamUUID: UUID,
                               chatID: String) -> Message? {
        let uuid = rewriteMessageID[upstreamUUID] ?? upstreamUUID
        guard let messages = model.messages(forChat: chatID, createIfNeeded: false),
              let i = model.index(ofMessageID: uuid, inChat: chatID) else {
            return appendMessage
        }
        let original = messages[i]
        switch original.content {
        case .plainText, .markdown:
            if let messages = model.messages(forChat: chatID, createIfNeeded: false),
               i < messages.count - 1 {
                // Appending to a message that isn't the most recent. We'll create a new message
                // instead. Any future updates will get their message ID rewritten to this new ID.
                // Once the message is committed we can forget about this rewriting rule. This
                // also makes it easier to reconstruct a thread to put in a request.
                var temp = appendMessage
                temp.uniqueID = UUID()
                rewriteMessageID[upstreamUUID] = temp.uniqueID
                temp.content = switch stringOrAttachment {
                case .string(let string):
                    switch original.content {
                    case .plainText:
                            .plainText(string, context: nil)
                    case .markdown:
                            .markdown(string)
                    case .explanationRequest, .explanationResponse, .remoteCommandRequest,
                            .remoteCommandResponse, .selectSessionRequest, .clientLocal,
                            .renameChat, .append, .appendAttachment, .commit, .setPermissions,
                            .vectorStoreCreated, .terminalCommand, .multipart,
                            .userCommand, .watcherEvent, .unsupported:
                        it_fatalError("You can't append \(stringOrAttachment)")
                    }
                case .attachment:
                    it_fatalError("Server-sent attachments are not yet supported")
                }
                return temp;
            } else if uuid != upstreamUUID {
                // Append to last message with a rewritten UUID
                var temp = appendMessage
                switch stringOrAttachment {
                case .string(let string):
                    temp.content = .append(string: string, uuid: uuid)
                case .attachment(let attachment):
                    temp.content = .appendAttachment(attachment: attachment, uuid: uuid)
                }
                return temp
            } else {
                // Append to last message without rewriting the UUID
                return appendMessage
            }
        case .explanationRequest, .remoteCommandResponse, .clientLocal,
                .renameChat, .append, .commit, .remoteCommandRequest, .selectSessionRequest,
                .setPermissions, .terminalCommand, .appendAttachment, .multipart,
                .vectorStoreCreated, .userCommand, .watcherEvent, .unsupported:
            // These are impossible or just normal streaming messages.
            return appendMessage

        case .explanationResponse(var response, _, let accumulatedMarkdown):
            // The case has no second value because this is where second values *come* from.
            // The initial is always empty.

            // append() will modify response in place so it is always complete.
            var update = switch stringOrAttachment {
            case .string(let string):
                response.append(string, final: false)
            case .attachment(let attachment):
                switch attachment.type {
                case .code(let content):
                    // TODO: It would be better if explanation responses could hold multipart documents
                    response.append(content, final: false)
                case .statusUpdate:
                    response.append("", final: false)
                case .file(let file):
                    // TODO: It would be better if explanation responses could hold multipart documents
                    response.append(file.content.lossyString, final: false)
                case .fileID:
                    it_fatalError()
                }
            }
            update.messageID = uuid

            guard let newMarkdown = markdownForExplanationResponse(response: response,
                                                                   update: update,
                                                                   chatID: chatID,
                                                                   messageID: original.uniqueID) else {
                return nil
            }
            return Message(chatID: chatID,
                           author: original.author,
                           content: .explanationResponse(response,
                                                         update,
                                                         markdown: accumulatedMarkdown + newMarkdown),
                           sentDate: appendMessage.sentDate,
                           uniqueID: UUID())
        }
    }

    private func processCommit(finalMessage: Message, messageID upstreamUUID: UUID, chatID: String) -> Message? {
        let messageID = rewriteMessageID[upstreamUUID] ?? upstreamUUID
        rewriteMessageID.removeValue(forKey: upstreamUUID)
        guard let messages = model.messages(forChat: chatID, createIfNeeded: false),
              let i = model.index(ofMessageID: messageID, inChat: chatID) else {
            return finalMessage
        }
        let original = messages[i]
        switch original.content {
        case .plainText, .markdown, .explanationRequest, .remoteCommandResponse, .clientLocal,
                .renameChat, .append, .commit, .remoteCommandRequest, .selectSessionRequest,
                .setPermissions, .terminalCommand, .appendAttachment, .multipart,
                .vectorStoreCreated, .userCommand, .watcherEvent, .unsupported:
            // These are impossible or just normal streaming messages.
            return finalMessage

        case .explanationResponse(let response, _, let accumulatedMarkdown):
            // The case has no second value because the initial, which is still in the original message,
            // is always empty.
            let marginal = markdownForExplanationResponse(
                response: response,
                update: ExplanationResponse.Update(final: true, messageID: messageID),
                chatID: chatID,
                messageID: messageID)
            if let marginal {
                return Message(
                    chatID: chatID,
                    author: original.author,
                    content: .explanationResponse(response,
                                                  .init(final: true, messageID: messageID),
                                                  markdown: accumulatedMarkdown + marginal),
                    sentDate: finalMessage.sentDate,
                    uniqueID: UUID())
            } else {
                return nil
            }
        }
    }

    // Performs side-effects upon receiving an explanation and returns a transformed message
    // suitable for display. Returns the marginal markdown to append.
    private func markdownForExplanationResponse(response: ExplanationResponse,
                                                update: ExplanationResponse.Update?,
                                                chatID: String,
                                                messageID: UUID) -> String? {
        let value = update ?? ExplanationResponse.Update(response)
        guard let session = iTermController.sharedInstance().anySession(withGUID: response.request.context.sessionID) else {
            return nil
        }
        let aiAnnotations = value.annotations.compactMap {
            AITermAnnotation(annotation: $0, locatedString: response.request.originalString)
        }
        let urls = session.add(aiAnnotations: aiAnnotations,
                               baseOffset: response.request.context.baseOffset,
                               locatedString: response.request.originalString)
        var bullets = [String]()
        for (annotation, url) in zip(aiAnnotations, urls) {
            guard let url else {
                continue
            }
            bullets.append(String(localized: "ChatClient.AnnotatedBullet", defaultValue: "I [annotated](\(url.absoluteString)) “\(annotation.annotatedText)”: \(annotation.note)", comment: "Markdown bullet describing a terminal annotation the AI made; first placeholder is a link URL, second is the annotated text, third is the note"))
        }
        var result = ""
        result += bullets.map { "  * " + $0 }.joined(separator: "\n")
        if !bullets.isEmpty {
            result += "\n"
        }
        if value.final && !response.annotations.isEmpty {
            result += String(localized: "ChatClient.RevealAnnotationHint", defaultValue: "\nYou can click on a link in this message or on a yellow underline in the terminal to reveal an annotation.", comment: "Hint appended to a chat message explaining how to reveal terminal annotations")
        }
        if let mainResponse = value.mainResponse {
            if !result.isEmpty {
                result += "\n"
            }
            result += mainResponse
        }
        return result
    }
}
