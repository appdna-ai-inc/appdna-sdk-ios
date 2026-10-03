import SwiftUI

/// Interactive chat step renderer.
/// Renders a multi-turn chat UI with AI persona, webhooks, quick replies, and turn limits.
struct ChatStepView: View {
    let step: OnboardingStep
    let flowId: String
    let onNext: ([String: Any]) -> Void
    let onSkip: () -> Void
    /// Previously saved transcript for restoring chat on back navigation
    var savedTranscript: [String: Any]? = nil

    private var chatConfig: ChatConfig? { step.config.chat_config }
    private var style: ChatStyleConfig? { chatConfig?.style }
    private var persona: ChatPersona? { chatConfig?.persona }

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isTyping: Bool = false
    @State private var userTurnCount: Int = 0
    @State private var isCompleted: Bool = false
    @State private var currentRating: Int? = nil
    @State private var dynamicQuickReplies: [ChatQuickReply] = []
    @State private var webhookData: [String: AnyCodable] = [:]
    @State private var startTime: Date = Date()
    @State private var showSoftLimitWarning: Bool = false
    // Chat input focus. A bare TextField in this bottom input bar wasn't
    // reliably becoming first responder on tap, so the keyboard never opened.
    @FocusState private var inputFocused: Bool
    @State private var didRestore = false

    // Colors — defaults MUST match console preview defaults exactly
    private var aiBubbleBg: Color { Color(hex: style?.ai_bubble_bg ?? "#1E293B") }
    private var aiBubbleText: Color { Color(hex: style?.ai_bubble_text ?? "#E2E8F0") }
    private var userBubbleBg: Color { Color(hex: style?.user_bubble_bg ?? (AppDNA.brandAccentHex ?? "#6366F1")) }
    private var userBubbleText: Color { Color(hex: style?.user_bubble_text ?? "#FFFFFF") }
    private var inputBg: Color { Color(hex: style?.input_bg ?? "#1E293B") }
    private var inputTextColor: Color { Color(hex: style?.input_text ?? "#E2E8F0") }
    private var inputBorder: Color { Color(hex: style?.input_border ?? "#334155") }
    private var sendBtnColor: Color { Color(hex: style?.send_button_color ?? (AppDNA.brandAccentHex ?? "#6366F1")) }
    private var qrBg: Color { Color(hex: style?.quick_reply_bg ?? "#334155") }
    private var qrText: Color { Color(hex: style?.quick_reply_text ?? "#E2E8F0") }
    private var qrBorder: Color { Color(hex: style?.quick_reply_border ?? "#475569") }
    private var typingColor: Color { Color(hex: style?.typing_indicator_color ?? (AppDNA.brandAccentHex ?? "#6366F1")) }

    private var maxTurns: Int { chatConfig?.resolvedMaxTurns ?? 5 }
    private var minTurns: Int { chatConfig?.resolvedMinTurns ?? 1 }
    private var canSendMessage: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTyping && !isCompleted
    }
    private var canComplete: Bool { userTurnCount >= minTurns }
    private var turnsRemaining: Int { max(0, maxTurns - userTurnCount) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }

                        if isTyping {
                            typingIndicator
                                .id("typing")
                        }

                        // Rating prompt (if triggered)
                        if let rating = currentRating, rating == 0 {
                            ratingPrompt
                                .id("rating")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _ in
                    withAnimation {
                        proxy.scrollTo(messages.last?.id ?? "typing", anchor: .bottom)
                    }
                }
            }

            // Quick replies
            if !dynamicQuickReplies.isEmpty && !isCompleted && !isTyping {
                quickRepliesBar
            }

            // Soft limit warning
            if showSoftLimitWarning {
                Text("You have 1 message remaining")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            // Completion CTA or Input bar
            if isCompleted {
                completionCTA
            } else if turnsRemaining > 0 {
                inputBar
            } else {
                // Turn limit reached: show the completion CTA. Auto-complete
                // only on a HARD limit; a soft limit lets the user tap Continue. (The
                // old `|| !isHardLimit` on the inputBar branch kept the input showing
                // forever for soft limits → max never honored + CTA never shown.)
                completionCTA
                    .onAppear { if (chatConfig?.isHardLimit ?? true) { completeChat(reason: "max_turns") } }
            }
        }
        .background(Color(hex: style?.background_color ?? "#0F172A"))
        .onAppear {
            startTime = Date()
            if !didRestore, let saved = savedTranscript, let transcript = saved["transcript"] as? [[String: Any]] {
                // Restore chat from saved transcript
                didRestore = true
                for msg in transcript {
                    let role = msg["role"] as? String ?? "ai"
                    let content = msg["content"] as? String ?? ""
                    let msgId = msg["id"] as? String ?? UUID().uuidString
                    let ts: Date = {
                        if let s = msg["timestamp"] as? String { return ISO8601.date(from: s) ?? Date() }
                        return Date()
                    }()
                    messages.append(ChatMessage(id: msgId, role: role == "user" ? .user : .ai, content: content, media: nil, timestamp: ts))
                }
                userTurnCount = saved["user_turn_count"] as? Int ?? messages.filter { $0.role == .user }.count
                isCompleted = true
                Log.debug("[Chat] Restored \(messages.count) messages from saved transcript")
            } else if messages.isEmpty {
                playAutoMessages()
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        VStack(spacing: 4) {
            if let title = step.config.title {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            if let personaName = persona?.name, let role = persona?.role {
                HStack(spacing: 8) {
                    if let avatarUrl = persona?.avatar_url, let url = URL(string: avatarUrl) {
                        BundledAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Circle().fill(Color.gray.opacity(0.3)) }
                            .frame(width: 28, height: 28).clipShape(Circle())
                    }
                    Text("\(personaName) - \(role)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .ai:
            HStack(alignment: .top, spacing: 8) {
                // Avatar
                if let avatarUrl = persona?.avatar_url, let url = URL(string: avatarUrl) {
                    BundledAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Circle().fill(Color.gray.opacity(0.3)) }
                        .frame(width: 32, height: 32).clipShape(Circle())
                } else {
                    Circle().fill(aiBubbleBg).frame(width: 32, height: 32)
                        .overlay(Text(String((persona?.name ?? "A").prefix(1))).font(.caption.bold()).foregroundColor(aiBubbleText))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.content)
                        .font(.subheadline)
                        .foregroundColor(aiBubbleText)
                        .padding(12)
                        .background(aiBubbleBg)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    // Media
                    if let media = msg.media, media.type == "image", let url = media.url.flatMap(URL.init) {
                        BundledAsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                            .frame(maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Spacer(minLength: 40)
            }
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.content)
                    .font(.subheadline)
                    .foregroundColor(userBubbleText)
                    .padding(12)
                    .background(userBubbleBg)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        case .system:
            Text(msg.content)
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(aiBubbleBg).frame(width: 32, height: 32)
                .overlay(Text(String((persona?.name ?? "A").prefix(1))).font(.caption.bold()).foregroundColor(aiBubbleText))
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(typingColor)
                        .frame(width: 8, height: 8)
                        .opacity(0.6)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: isTyping)
                }
            }
            .padding(12)
            .background(aiBubbleBg)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
    }

    // MARK: - Quick Replies

    private var quickRepliesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dynamicQuickReplies) { qr in
                    Button {
                        AppDNA.track(event: "chat_quick_reply_tapped", properties: [
                            "flow_id": flowId, "step_id": step.id, "quick_reply_id": qr.id, "turn": userTurnCount,
                        ])
                        sendMessage(qr.text)
                    } label: {
                        Text(qr.text)
                            .font(.caption)
                            .foregroundColor(qrText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(qrBg)
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(qrBorder, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Custom text field with styled placeholder
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text(chatConfig?.input_placeholder ?? "Type your message...")
                        .font(.system(size: CGFloat(style?.input_font_size ?? 14)))
                        .foregroundColor(inputTextColor.opacity(0.5))
                        .padding(.horizontal, 12)
                }
                TextField("", text: $inputText)
                    .font(.system(size: CGFloat(style?.input_font_size ?? 14)))
                    .foregroundColor(inputTextColor)
                    .padding(.horizontal, 12)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { if canSendMessage { sendMessage(inputText) } }
            }
            .padding(.vertical, 10)
            .background(inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(inputBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { inputFocused = true }

            Button {
                sendMessage(inputText)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSendMessage ? sendBtnColor : sendBtnColor.opacity(0.3))
            }
            .disabled(!canSendMessage)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: style?.background_color ?? "#0F172A"))
    }

    // MARK: - Rating Prompt

    private var ratingPrompt: some View {
        VStack(spacing: 8) {
            Text("How helpful is this conversation?")
                .font(.caption)
                .foregroundColor(.gray)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        currentRating = star
                        // Send rating event via webhook
                        sendRatingEvent(star)
                    } label: {
                        Image(systemName: (currentRating ?? 0) >= star ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(Color(hex: style?.rating_star_color ?? "#FBBF24"))
                    }
                }
            }
        }
        .padding(12)
        .background(aiBubbleBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Completion CTA

    private var completionCTA: some View {
        // Resolve styling from completion_button (new, matches normal CTA block)
        // falling back to the chat theme's user bubble colors. Any unset field
        // keeps the previous default so existing flows look identical.
        let btn = chatConfig?.completion_button
        let variant = btn?.variant ?? "primary"
        let hasCustomBg = !(btn?.bg_color?.isEmpty ?? true)
        let resolvedBg: Color = {
            if let hex = btn?.bg_color, !hex.isEmpty { return Color(hex: hex) }
            return userBubbleBg
        }()
        // Text color fallback chain:
        //   1. Explicit `text_color` — use it.
        //   2. Else if user overrode `bg_color` (but left text_color empty):
        //      pick black or white for contrast against the new bg. Without this,
        //      setting bg_color to white leaves text_color at the chat theme's
        //      userBubbleText default (often white) → white-on-white invisible text.
        //   3. Else (neither set): fall back to userBubbleText — original behavior
        //      that pairs the CTA with the chat theme.
        let resolvedText: Color = {
            if let hex = btn?.text_color, !hex.isEmpty { return Color(hex: hex) }
            if hasCustomBg, let bgHex = btn?.bg_color {
                return Color.isLightHex(bgHex) ? Color.black : Color.white
            }
            return userBubbleText
        }()
        let radius: CGFloat = CGFloat(btn?.button_corner_radius ?? 14)
        let height: CGFloat? = btn?.button_height.map { CGFloat($0) }
        let fontSize: CGFloat = CGFloat(btn?.style?.font_size ?? 17)
        let fontWeight: Font.Weight = {
            switch Int(btn?.style?.font_weight ?? 600) {
            case 400: return .regular
            case 500: return .medium
            case 700: return .bold
            default: return .semibold
            }
        }()

        return VStack(spacing: 12) {
            Button {
                let transcript = buildTranscript(reason: isCompleted ? "max_turns" : "user_completed")
                onNext(transcript)
            } label: {
                Text(chatConfig?.completion_cta_text ?? step.config.cta_text ?? "Continue")
                    .font(.system(size: fontSize, weight: fontWeight))
                    .foregroundColor(variant == "outline" || variant == "text" ? resolvedBg : resolvedText)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .padding(.vertical, height == nil ? 14 : 0)
                    .background(
                        Group {
                            switch variant {
                            case "text":
                                Color.clear
                            case "outline":
                                RoundedRectangle(cornerRadius: radius)
                                    .stroke(resolvedBg, lineWidth: 2)
                            case "secondary":
                                RoundedRectangle(cornerRadius: radius)
                                    .fill(resolvedBg.opacity(0.15))
                            default: // primary
                                RoundedRectangle(cornerRadius: radius)
                                    .fill(resolvedBg)
                            }
                        }
                    )
            }
            .padding(.horizontal, 20)

            if step.config.skip_enabled == true {
                Button("Skip") { onSkip() }
                    .font(.caption).foregroundColor(.gray)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Actions

    private func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Add user message
        let userMsg = ChatMessage(id: "msg_u\(userTurnCount)", role: .user, content: trimmed, media: nil, timestamp: Date())
        messages.append(userMsg)
        inputText = ""
        userTurnCount += 1
        dynamicQuickReplies = []

        // Track message sent
        AppDNA.track(event: "chat_message_sent", properties: [
            "flow_id": flowId, "step_id": step.id, "turn": userTurnCount, "message_length": trimmed.count,
        ])

        // Check soft limit warning
        if !(chatConfig?.isHardLimit ?? true) && turnsRemaining == 1 {
            showSoftLimitWarning = true
        }

        // Check turn actions
        checkTurnActions(turn: userTurnCount)

        // Fire webhook
        isTyping = true
        HapticEngine.trigger(.light)

        Task {
            await fireWebhook(userMessage: trimmed)
        }
    }

    private func fireWebhook(userMessage: String) async {
        guard let webhook = chatConfig?.webhook, webhook.enabled == true else {
            isTyping = false
            return
        }

        let messagePayloads = messages.map { msg in
            ChatMessagePayload(
                role: msg.role == .user ? "user" : "ai",
                content: msg.content,
                id: msg.id,
                timestamp: ISO8601DateFormatter().string(from: msg.timestamp)
            )
        }

        let request = ChatWebhookRequest(
            event: "chat_message",
            flow_id: flowId,
            step_id: step.id,
            app_id: AppDNA.currentAppId ?? "",
            user_id: AppDNA.currentUserId ?? "",
            conversation: ChatConversationContext(
                turn: userTurnCount - 1,
                messages: messagePayloads,
                user_message: userMessage,
                max_turns: maxTurns,
                remaining_turns: turnsRemaining
            ),
            responses: nil,
            rating: currentRating,
            context: webhookData.isEmpty ? nil : webhookData
        )

        do {
            let jsonData = try JSONEncoder().encode(request)
            guard let url = URL(string: webhook.webhook_url ?? "") else {
                isTyping = false
                return
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = jsonData
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.timeoutInterval = Double(webhook.timeout_ms ?? 15000) / 1000.0

            // Add custom headers
            if let headers = webhook.headers {
                for (key, value) in headers {
                    urlRequest.setValue(value, forHTTPHeaderField: key)
                }
            }

            let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)

            // Surface 4xx/5xx as chat_webhook_error instead of silently
                            // decoding the error body as an empty ChatWebhookResponse.
            if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500).description ?? ""
                await MainActor.run {
                    isTyping = false
                    let errorMsg = chatConfig?.webhook?.error_text ?? "Sorry, something went wrong. Please try again."
                    messages.append(ChatMessage(id: "err_\(userTurnCount)", role: .system, content: errorMsg, media: nil, timestamp: Date()))
                    AppDNA.track(event: "chat_webhook_error", properties: [
                        "flow_id": flowId, "step_id": step.id, "turn": userTurnCount,
                        "http_status": http.statusCode, "response_body": bodyPreview,
                    ])
                }
                return
            }

            let response = try JSONDecoder().decode(ChatWebhookResponse.self, from: data)

            await MainActor.run {
                handleWebhookResponse(response)
            }
        } catch {
            await MainActor.run {
                isTyping = false
                let errorMsg = chatConfig?.webhook?.error_text ?? "Sorry, something went wrong. Please try again."
                messages.append(ChatMessage(id: "err_\(userTurnCount)", role: .system, content: errorMsg, media: nil, timestamp: Date()))
                AppDNA.track(event: "chat_webhook_error", properties: [
                    "flow_id": flowId, "step_id": step.id, "turn": userTurnCount, "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleWebhookResponse(_ response: ChatWebhookResponse) {
        isTyping = false

        AppDNA.track(event: "chat_message_received", properties: [
            "flow_id": flowId, "step_id": step.id, "turn": userTurnCount,
            "message_count": response.messages?.count ?? 0,
        ])

        // Add AI messages
        if let msgs = response.messages {
            for (i, msg) in msgs.enumerated() {
                let aiMsg = ChatMessage(
                    id: "msg_a\(userTurnCount)_\(i)",
                    role: .ai,
                    content: msg.content ?? "",
                    media: msg.media,
                    timestamp: Date()
                )
                messages.append(aiMsg)
            }
        }

        // Update quick replies if provided
        if let qrs = response.quick_replies {
            dynamicQuickReplies = qrs
        }

        // Merge webhook data
        if let data = response.data {
            for (key, value) in data {
                webhookData[key] = value
            }
        }

        // Check for forced completion
        if response.force_complete == true || response.action == "reply_and_complete" {
            if let completionMsg = response.completion_message ?? chatConfig?.completion_message?.content {
                messages.append(ChatMessage(id: "completion", role: .ai, content: completionMsg, media: nil, timestamp: Date()))
            }
            completeChat(reason: "ai_completed")
        }

        // Check if max turns reached.
        // Guard on `!isCompleted` (matches Android ChatStepComposable). Without it, a webhook
        // that returns force_complete on the FINAL allowed turn ran completeChat("ai_completed") above and
        // then fell through here to emit a SECOND chat_completed ("max_turns") + a second completion
        // bubble. `completeChat` sets isCompleted = true, so this now skips when already completed.
        if turnsRemaining <= 0 && !isCompleted {
            if let completionMsg = chatConfig?.completion_message?.content {
                messages.append(ChatMessage(id: "completion", role: .ai, content: completionMsg, media: nil, timestamp: Date()))
            }
            completeChat(reason: "max_turns")
        }
    }

    private func completeChat(reason: String) {
        isCompleted = true
        showSoftLimitWarning = false
        dynamicQuickReplies = []

        // Track event
        AppDNA.track(event: "chat_completed", properties: [
            "flow_id": flowId,
            "step_id": step.id,
            "user_turn_count": userTurnCount,
            "total_messages": messages.count,
            "duration_ms": Int(Date().timeIntervalSince(startTime) * 1000),
            "completion_reason": reason,
        ])
    }

    private func buildTranscript(reason: String) -> [String: Any] {
        let payloads = messages.filter { $0.role != .system }.map { msg -> [String: Any] in
            ["role": msg.role == .user ? "user" : "ai", "content": msg.content, "id": msg.id, "timestamp": ISO8601DateFormatter().string(from: msg.timestamp)]
        }
        var result: [String: Any] = [
            "transcript": payloads,
            "user_turn_count": userTurnCount,
            "total_message_count": messages.count,
            "completion_reason": reason,
            "duration_ms": Int(Date().timeIntervalSince(startTime) * 1000),
        ]
        if let r = currentRating { result["rating"] = r }
        if !webhookData.isEmpty {
            result["webhook_data"] = webhookData.mapValues { $0.value }
        }
        return result
    }

    // MARK: - Auto Messages

    private func playAutoMessages() {
        guard let autoMsgs = chatConfig?.auto_messages?.filter({ $0.turn == 0 }) else {
            loadQuickReplies(forTurn: 0)
            return
        }

        for (i, autoMsg) in autoMsgs.enumerated() {
            let delay = Double(autoMsg.delay_ms ?? (500 + i * 1200)) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                isTyping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.8) {
                isTyping = false
                messages.append(ChatMessage(id: autoMsg.id, role: .ai, content: autoMsg.content, media: autoMsg.media, timestamp: Date()))
                if i == autoMsgs.count - 1 {
                    loadQuickReplies(forTurn: 0)
                }
            }
        }
    }

    private func loadQuickReplies(forTurn turn: Int) {
        dynamicQuickReplies = chatConfig?.quick_replies?.filter { $0.show_at_turn == turn } ?? []
    }

    private func checkTurnActions(turn: Int) {
        guard let actions = chatConfig?.turn_actions?.filter({ $0.turn == turn }) else { return }
        for action in actions {
            switch action.type {
            case "rating_prompt":
                currentRating = 0 // 0 = prompt shown but no selection
            case "auto_message":
                if let content = action.config?.value as? [String: Any], let text = content["content"] as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        messages.append(ChatMessage(id: "action_\(turn)", role: .ai, content: text, media: nil, timestamp: Date()))
                    }
                }
            default:
                break
            }
        }
    }

    private func sendRatingEvent(_ rating: Int) {
        AppDNA.track(event: "chat_rating_submitted", properties: [
            "flow_id": flowId,
            "step_id": step.id,
            "rating": rating,
            "turn": userTurnCount,
        ])
    }
}
