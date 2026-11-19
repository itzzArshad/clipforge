import SwiftUI

/// Copy the prompt into any AI chat (ChatGPT, Claude, Gemini...), paste its answer back. Nothing runs on the
/// phone. With a Claude API key in Settings, "Send" does the same round trip directly.
struct AISheet: View {
    let request: AIRequest
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var answer = ""
    @State private var error: String?
    @State private var copied = false
    @State private var sending = false
    @State private var showPrompt = false

    private var what: String {
        request.kind == .moments ? "pick and cut the best shorts, with hooks and titles"
                                 : "fix the caption spelling (Hinglish, numbers, names)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ask any AI to \(what). Nothing heavy runs on your phone.")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim)

                    step(1, "Copy the prompt")
                    HStack(spacing: 8) {
                        Chip(title: copied ? "Copied" : "Copy prompt", icon: copied ? "checkmark" : "doc.on.doc", selected: true) {
                            UIPasteboard.general.string = request.prompt
                            copied = true
                        }
                        Chip(title: showPrompt ? "Hide" : "Show", selected: false) { showPrompt.toggle() }
                        Spacer()
                        Text("\(request.prompt.count / 1000)k chars").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                    if showPrompt {
                        Text(request.prompt)
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                            .lineLimit(40)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .panel(10)
                    }

                    step(2, "Paste it into ChatGPT, Claude or Gemini and send")
                    Text("Any free chat works. Copy the AI's whole reply when it's done.")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint)

                    step(3, "Paste the answer here")
                    TextEditor(text: $answer)
                        .font(Theme.mono(12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .padding(8)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 8) {
                        Chip(title: "Paste", icon: "doc.on.clipboard", selected: false) {
                            answer = UIPasteboard.general.string ?? answer
                        }
                        Spacer()
                        Chip(title: "Use answer", icon: "checkmark", selected: !answer.isEmpty) { use(answer) }
                            .disabled(answer.isEmpty)
                    }

                    if let error {
                        Text(error).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.hot)
                    }

                    if model.hasAPIKey {
                        Divider().overlay(Theme.line)
                        HStack {
                            Text("Or send it with your Claude API key").font(.system(size: 13)).foregroundStyle(Theme.dim)
                            Spacer()
                            if sending {
                                ProgressView()
                            } else {
                                Chip(title: "Send", icon: "paperplane", selected: false) {
                                    sending = true
                                    Task {
                                        error = await model.sendAI(request)
                                        sending = false
                                        if error == nil { dismiss() }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(request.kind == .moments ? "Ask AI: pick shorts" : "Ask AI: fix captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
            Text(text).font(.system(size: 15, weight: .bold))
        }
    }

    private func use(_ text: String) {
        error = model.applyAI(text, for: request)
        if error == nil { dismiss() }
    }
}
