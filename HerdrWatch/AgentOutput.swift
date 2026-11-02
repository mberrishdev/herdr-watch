import SwiftUI

struct OutputScope: Equatable {
    let host: Host
    let session: String
    let coreIdentity: String?
}
struct OutputTarget {
    let agent: Agent
    let scope: OutputScope
}
enum PromptDeliveryNotice: Equatable {
    case submitted
    case uncertain
    var text: String {
        switch self {
        case .submitted: return "Instruction submitted. Agent progress is reported separately."
        case .uncertain: return "Delivery is uncertain. Inspect the agent before sending again."
        }
    }
}
private enum AgentOutputSheet: String, Identifiable {
    case details
    var id: String { rawValue }
}
struct TerminalOutput {
    let text: String
    let truncated: Bool
    let partial: Bool
    let screenOnly: Bool
    let observed: Date

    static func decode(_ data: Data, core: Bool, agent: Agent) throws -> TerminalOutput {
        let text: String, partial: Bool, serverTruncated: Bool
        if core {
            struct Read: Decodable { let text: String; let complete: Bool }
            let read = try CoreAdapter.result(Read.self, from: data, id: "core-output")
            text = read.text; partial = !read.complete; serverTruncated = false
        } else {
            struct Envelope: Decodable {
                struct Result: Decodable {
                    struct Read: Decodable { let text: String; let pane_id: String; let workspace_id: String; let truncated: Bool }
                    let type: String; let read: Read
                }
                let id: String; let result: Result
            }
            let value = try JSONDecoder().decode(Envelope.self, from: data)
            guard value.id == "agent-output", value.result.type == "pane_read",
                  value.result.read.pane_id == agent.pane_id, value.result.read.workspace_id == agent.workspace_id else {
                throw WatchError.message("The terminal response did not match this agent's location.")
            }
            text = value.result.read.text; partial = false; serverTruncated = value.result.read.truncated
        }
        let cleaned = PlainTerminalText.clean(text)
        let bytes = Data(cleaned.utf8)
        let cap = 32 * 1024
        return TerminalOutput(text: String(decoding: bytes.suffix(cap).drop(while: { $0 & 0xC0 == 0x80 }), as: UTF8.self), truncated: serverTruncated || bytes.count > cap,
                              partial: partial, screenOnly: core, observed: Date())
    }
}

/// Discard terminal control sequences before presenting inert, selectable text.
enum PlainTerminalText {
    static func clean(_ value: String) -> String {
        enum State { case text, escape, csi, osc, oscEscape, string, stringEscape }
        var state = State.text
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let code = scalar.value
            switch state {
            case .text:
                switch code {
                case 0x1B: state = .escape
                case 0x9B: state = .csi
                case 0x9D: state = .osc
                case 0x90, 0x98, 0x9E, 0x9F: state = .string
                case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: break
                default: result.append(scalar)
                }
            case .escape:
                switch code {
                case 0x5B: state = .csi
                case 0x5D: state = .osc
                case 0x50, 0x58, 0x5E, 0x5F: state = .string
                case 0x20...0x2F, 0x1B: break
                default: state = .text
                }
            case .csi: if (0x40...0x7E).contains(code) { state = .text }
            case .osc:
                if code == 7 || code == 0x9C { state = .text }
                else if code == 0x1B { state = .oscEscape }
            case .string:
                if code == 0x9C { state = .text }
                else if code == 0x1B { state = .stringEscape }
            case .oscEscape: state = code == 0x5C ? .text : code == 0x1B ? .oscEscape : .osc
            case .stringEscape: state = code == 0x5C ? .text : code == 0x1B ? .stringEscape : .string
            }
        }
        return String(result).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

struct AgentStatusBadge: View {
    let status: String
    private var color: Color {
        switch status { case "working": return .blue; case "blocked", "error": return .orange; case "done": return .green; default: return .secondary }
    }
    var body: some View {
        Text(statusLabel(status)).font(.subheadline.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

private struct OutputBlock: Identifiable {
    enum Kind {
        case heading(String)
        case paragraph(String)
        case quote(String)
        case bullets([String])
        case code(String?, String)
    }
    let id: Int
    let kind: Kind
}

/// A conservative typography pass for terminal text: it only recognizes explicit
/// Markdown headings, fenced code, common list markers, and the Codex prompt glyph.
/// Everything else stays verbatim instead of being guessed to be a final answer.
private enum ReadableOutputParser {
    static func blocks(_ text: String) -> [OutputBlock] {
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
        }
        var result: [OutputBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCode = false
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(OutputBlock(id: result.count, kind: .paragraph(paragraph.joined(separator: "\n"))))
            paragraph.removeAll(keepingCapacity: true)
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            result.append(OutputBlock(id: result.count, kind: .bullets(bullets)))
            bullets.removeAll(keepingCapacity: true)
        }
        func flushCode() {
            guard !code.isEmpty else { return }
            result.append(OutputBlock(id: result.count, kind: .code(codeLanguage, code.joined(separator: "\n"))))
            code.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph(); flushBullets()
                if inCode { flushCode(); inCode = false }
                else {
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    inCode = true
                }
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); flushBullets(); continue }

            if let heading = markdownHeading(line) {
                flushParagraph(); flushBullets()
                result.append(OutputBlock(id: result.count, kind: .heading(heading)))
            } else if let item = listItem(line) {
                flushParagraph(); bullets.append(item)
            } else if line.hasPrefix("› ") {
                flushParagraph(); flushBullets()
                result.append(OutputBlock(id: result.count, kind: .quote(String(line.dropFirst(2)))))
            } else if line.hasPrefix("> ") {
                flushParagraph(); flushBullets()
                result.append(OutputBlock(id: result.count, kind: .quote(String(line.dropFirst(2)))) )
            } else {
                flushBullets(); paragraph.append(raw)
            }
        }
        flushParagraph(); flushBullets(); flushCode()
        return result
    }
    private static func markdownHeading(_ line: String) -> String? {
        guard let range = line.range(of: "^#{1,3}\\s+", options: .regularExpression) else { return nil }
        return String(line[range.upperBound...])
    }
    private static func listItem(_ line: String) -> String? {
        for marker in ["• ", "◦ ", "- ", "* "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        if let range = line.range(of: "^[0-9]{1,3}[.)]\\s+", options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return nil
    }
}

private struct ReadableOutputView: View {
    let text: String
    let fontSize: Double
    private var blocks: [OutputBlock] { ReadableOutputParser.blocks(text) }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if blocks.isEmpty {
                Text("The terminal screen is empty.").font(.body).foregroundStyle(.secondary)
            }
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let value):
                    Text(inlineMarkdown(value)).font(.system(size: fontSize + 2, weight: .semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let value):
                    Text(inlineMarkdown(value)).font(.system(size: fontSize)).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
                        Text(inlineMarkdown(value)).font(.system(size: fontSize)).foregroundStyle(.secondary).lineSpacing(4)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                case .bullets(let values):
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 2)
                                Text(inlineMarkdown(value)).font(.system(size: fontSize)).lineSpacing(4).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.leading, 2)
                case .code(let language, let value):
                    VStack(alignment: .leading, spacing: 0) {
                        if let language, !language.isEmpty {
                            Text(language.lowercased()).font(.caption2.weight(.semibold)).tracking(0.2)
                                .foregroundStyle(.secondary).padding(.horizontal, 13).padding(.top, 11)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(verbatim: value).font(.system(size: fontSize * 0.9, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                                .padding(13)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Render inline emphasis and code while keeping terminal-provided links inert.
private func inlineMarkdown(_ source: String) -> AttributedString {
    var value = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    for run in value.runs where run.link != nil { value[run.range].link = nil }
    return value
}

struct AgentOutputView: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.scenePhase) private var phase
    @ScaledMetric(relativeTo: .body) private var baseTextSize = 17.0
    @AppStorage("terminalWrapLines") private var wrapLines = true
    @AppStorage("terminalTextScale") private var textScale = 1.0
    @AppStorage("readableAgentOutput") private var readableMode = true
    @State private var target: OutputTarget
    @State private var output: TerminalOutput?
    @State private var loading = false
    @State private var error: String?
    @State private var activeSheet: AgentOutputSheet?
    init(target: OutputTarget) { _target = State(initialValue: target) }
    private var currentStatus: String { store.snapshot?.agents.first(where: { $0.id == target.agent.id })?.agent_status ?? "unknown" }
    private var readableText: String {
        guard let output, !output.text.isEmpty else { return "The terminal screen is empty." }
        guard wrapLines else { return output.text }
        // Trim screen padding and collapse long blank runs without altering text.
        let lines = output.text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression) }
        var compact: [String] = []
        for line in lines where !line.isEmpty || compact.last?.isEmpty != true { compact.append(line) }
        while compact.last?.isEmpty == true { compact.removeLast() }
        return compact.joined(separator: "\n")
    }
    private var displayScale: Double { textScale.isFinite ? min(1.5, max(0.875, textScale)) : 1 }
    private var formattedOutput: AttributedString {
        var result = AttributedString()
        let lines = readableText.components(separatedBy: "\n")
        let headingIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        for (index, rawLine) in lines.enumerated() {
            var line = AttributedString(rawLine.isEmpty ? " " : rawLine)
            line.font = .system(size: baseTextSize * displayScale, weight: .regular, design: .monospaced)
            if index == headingIndex {
                line.font = .system(size: baseTextSize * displayScale, weight: .semibold, design: .monospaced)
                line.foregroundColor = .accentColor
            } else if rawLine.hasPrefix("› ") || rawLine.hasPrefix("> ") {
                line.foregroundColor = .primary
                if let mark = line.range(of: String(rawLine.prefix(2))) {
                    line[mark].foregroundColor = .accentColor
                    line[mark].font = .system(size: baseTextSize * displayScale, weight: .bold, design: .monospaced)
                }
            } else if rawLine.hasPrefix("• ") || rawLine.hasPrefix("- ") {
                if let mark = line.range(of: String(rawLine.prefix(2))) {
                    line[mark].foregroundColor = .accentColor
                    line[mark].font = .system(size: baseTextSize * displayScale, weight: .bold, design: .monospaced)
                }
            }
            result += line
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            sourceRow.padding(.horizontal, 18).padding(.vertical, 9)
            if output != nil {
                ScrollView(readableMode || wrapLines ? .vertical : [.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let output, output.truncated || output.partial {
                            Label(output.truncated ? "Showing the newest part of this output" : "The host reports an incomplete screen", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if readableMode {
                            ReadableOutputView(text: output?.text ?? "", fontSize: baseTextSize * displayScale)
                                .padding(.vertical, 8)
                        } else {
                            Text(formattedOutput).lineSpacing(5).textSelection(.enabled)
                                .fixedSize(horizontal: !wrapLines, vertical: true)
                                .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.bottom, 18)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(loading ? "Reading session…" : "No output yet", systemImage: "text.alignleft", description: Text(error ?? "Herdr's latest terminal output will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AgentPromptComposer(target: target).environmentObject(store)
        }
        .navigationTitle(target.agent.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Menu {
                Button("Larger text", systemImage: "textformat.size.larger") { textScale = min(1.5, displayScale + 0.125) }.disabled(displayScale >= 1.5)
                Button("Smaller text", systemImage: "textformat.size.smaller") { textScale = max(0.875, displayScale - 0.125) }.disabled(displayScale <= 0.875)
                Button("Default text size") { textScale = 1 }
                Divider()
                Toggle("Readable layout", isOn: $readableMode)
                Toggle("Wrap terminal lines", isOn: $wrapLines).disabled(readableMode)
            } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Reading options")
            Button {
                Task { if !store.connected { await store.connect() }; await load() }
            } label: { Image(systemName: store.connected ? "arrow.clockwise" : "wifi.exclamationmark") }
                .accessibilityLabel(store.connected ? "Refresh terminal" : "Reconnect")
                .disabled(loading || store.busy)
            Button { activeSheet = .details } label: { Image(systemName: "info.circle") }.accessibilityLabel("Session details")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .details: sessionDetails
            }
        }
        .task(id: phase) {
            guard phase == .active else { output = nil; return }
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await load()
            }
        }
        .onDisappear { output = nil }
        .overlay { if phase != .active { Color.gray.ignoresSafeArea().overlay { Label("HerdrWatch", systemImage: "lock.fill") } } }
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal.fill").font(.subheadline).foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(target.agent.agent?.capitalized ?? "Agent") · \(target.scope.session)")
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(target.scope.host.address) · \(target.scope.host.username)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            AgentStatusBadge(status: currentStatus)
        }
    }
    private var sourceRow: some View {
        HStack(spacing: 7) {
            Circle().fill(error != nil || !store.connected ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(output?.screenOnly == false ? "Recent terminal output" : "Current terminal screen")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let output {
                Text("\(error != nil || !store.connected ? "Stale" : "Updated") · \(output.observed.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            } else {
                Text(loading ? "Refreshing…" : "Waiting")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
    private var sessionDetails: some View {
        NavigationStack {
            ZStack {
                Rectangle().fill(.background).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    detailRow("Host", value: "\(target.scope.host.username)@\(target.scope.host.address):\(target.scope.host.port)", symbol: "network")
                    detailRow("Herdr session", value: target.scope.session, symbol: "rectangle.on.rectangle")
                    detailRow("Terminal", value: target.agent.terminal_id, symbol: "terminal")
                    if let cwd = target.agent.cwd { detailRow("Working directory", value: cwd, symbol: "folder") }
                    detailRow("Screen source", value: output?.screenOnly == false ? "Recent output · up to 100 lines" : "Current screen · refreshes every 5 seconds", symbol: "arrow.clockwise")
                    Spacer(minLength: 0)
                }.padding(20)
            }
            .navigationTitle("Session details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { activeSheet = nil } } }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    private func detailRow(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.subheadline).textSelection(.enabled)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).glassPanel(cornerRadius: 17)
    }
    @MainActor private func load() async {
        guard !loading else { return }
        guard store.connected else { error = "Disconnected. Reconnect to read the terminal."; return }
        loading = true
        defer { loading = false }
        do {
            if let value = try await store.readOutput(for: target) { output = value; error = nil }
            else if output == nil { error = "Waiting for the current dashboard refresh…" }
        } catch is CancellationError { error = "Screen read interrupted. Refresh after reconnecting." }
        catch { self.error = (error as? WatchError)?.localizedDescription ?? "Could not decode the terminal screen." }
    }
}

struct AgentPromptComposer: View {
    @EnvironmentObject private var store: WatchStore
    @ScaledMetric(relativeTo: .body) private var baseTextSize = 17.0
    let target: OutputTarget
    @State private var draft = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var promptDelivery: PromptDeliveryNotice?

    private var currentStatus: String {
        store.snapshot?.agents.first(where: { $0.id == target.agent.id })?.agent_status ?? "unknown"
    }
    private var hasValidDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 8192
    }
    private var canSend: Bool {
        hasValidDraft && store.permitsPrompt(status: currentStatus) && !sending && !store.busy
    }
    private var guidance: String? {
        if store.permitsPrompt(status: currentStatus) { return nil }
        if currentStatus == "blocked" { return "This agent is blocked. Continue on the host." }
        if currentStatus == "working" { return "This agent is working. Wait until it is idle to send a follow-up." }
        return "Waiting for Herdr to confirm this agent is ready."
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                if let promptDelivery {
                    Label(promptDelivery.text, systemImage: promptDelivery == .uncertain ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(promptDelivery == .uncertain ? .orange : .green)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .font(.system(size: baseTextSize))
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
                    .accessibilityLabel("Instruction for \(target.agent.title)")
                if let guidance {
                    Text(guidance).font(.caption2).foregroundStyle(currentStatus == "blocked" ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draft.utf8.count > 7000 {
                    Text("\(draft.utf8.count) / 8192 bytes").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Button(action: send) {
                Group {
                    if sending { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.up").font(.headline.weight(.semibold)).foregroundStyle(.white) }
                }.frame(width: 42, height: 42)
                    .background(canSend ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send instruction")
            .disabled(!canSend)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
    }

    @MainActor private func send() {
        guard canSend else { return }
        sending = true
        errorMessage = nil
        Task {
            defer { sending = false }
            do {
                _ = try await store.sendPrompt(for: target, text: draft)
                draft = ""
                promptDelivery = .submitted
            } catch PromptSendError.deliveryUncertain {
                promptDelivery = .uncertain
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "The instruction was not sent."
            }
        }
    }
}

#if DEBUG
struct OutputPreviewRoot: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        NavigationStack {
            if let agent = store.snapshot?.agents.first {
                AgentOutputView(target: OutputTarget(agent: agent, scope: store.outputScope))
            } else { ProgressView("Loading sample agent…") }
        }.task { await store.connect() }
    }
}
#endif
