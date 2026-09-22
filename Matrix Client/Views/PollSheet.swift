import SwiftUI
import MatrixRustSDK

/// Sheet that collects a question + 2–20 answers and creates an `m.poll.start`
/// event in the room. Reached from the composer's `/poll` slash command.
struct CreatePollSheet: View {
    @ObservedObject var room: RoomVM
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var answers: [String] = ["", ""]
    @State private var kind: PollKind = .disclosed
    @State private var maxSelections: Int = 1
    @State private var submitting = false
    @State private var errorText: String?

    private var trimmedAnswers: [String] {
        answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
              .filter { !$0.isEmpty }
    }

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trimmedAnswers.count >= 2
            && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Create a Poll").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Question").font(.caption.bold()).foregroundStyle(.secondary)
                TextField("What should we order for lunch?", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Answers").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(answers.indices, id: \.self) { i in
                    HStack {
                        TextField("Option \(i + 1)", text: $answers[i])
                            .textFieldStyle(.roundedBorder)
                        if answers.count > 2 {
                            Button {
                                answers.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if answers.count < 20 {
                    Button {
                        answers.append("")
                    } label: {
                        Label("Add option", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(.caption.bold()).foregroundStyle(.secondary)
                Picker("Visibility", selection: $kind) {
                    Text("Open — votes visible").tag(PollKind.disclosed)
                    Text("Closed — votes hidden until poll ends").tag(PollKind.undisclosed)
                }
                .pickerStyle(.radioGroup)

                Stepper(value: $maxSelections, in: 1...max(1, trimmedAnswers.count)) {
                    Text("Allow up to \(maxSelections) selection\(maxSelections == 1 ? "" : "s") per voter")
                }
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Create Poll") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func submit() {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = trimmedAnswers
        guard !trimmedQuestion.isEmpty, trimmed.count >= 2 else { return }
        submitting = true
        errorText = nil
        Task {
            let err = await room.createPoll(
                question: trimmedQuestion,
                answers: trimmed,
                maxSelections: UInt8(max(1, min(maxSelections, trimmed.count))),
                kind: kind
            )
            await MainActor.run {
                submitting = false
                if let err {
                    errorText = err
                } else {
                    dismiss()
                }
            }
        }
    }
}

/// In-bubble poll renderer. Pulls answers + vote tallies straight from the
/// SDK's `MsgLikeKind.poll` payload and lets the user cast or change a vote.
struct PollView: View {
    let pollStartEventId: String
    let question: String
    let kind: PollKind
    let maxSelections: UInt64
    let answers: [PollAnswer]
    /// answerId → list of voter user IDs (for disclosed polls; undisclosed
    /// reports counts but doesn't reveal who voted until poll ends).
    let votes: [String: [String]]
    let endTime: Timestamp?
    @ObservedObject var room: RoomVM
    @EnvironmentObject private var session: MatrixSession

    private var totalVotes: Int {
        votes.values.reduce(0) { $0 + $1.count }
    }

    private var myVotes: Set<String> {
        guard let me = session.currentUserId else { return [] }
        var out: Set<String> = []
        for (answerId, voters) in votes where voters.contains(me) {
            out.insert(answerId)
        }
        return out
    }

    private var isClosed: Bool {
        if let end = endTime {
            // Timestamp is milliseconds since epoch.
            return TimeInterval(end) / 1000.0 <= Date().timeIntervalSince1970
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                    Text(subtitleText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 6) {
                ForEach(answers, id: \.id) { ans in
                    answerRow(ans)
                }
            }

            if isClosed {
                Text("Poll closed")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var subtitleText: String {
        let visibility = (kind == .disclosed) ? "Open poll" : "Closed poll"
        let maxText: String = maxSelections > 1 ? " · up to \(maxSelections) votes" : ""
        let voteText = totalVotes == 0
            ? "no votes yet"
            : "\(totalVotes) vote\(totalVotes == 1 ? "" : "s")"
        return "\(visibility)\(maxText) · \(voteText)"
    }

    @ViewBuilder
    private func answerRow(_ ans: PollAnswer) -> some View {
        let count = votes[ans.id]?.count ?? 0
        let total = max(totalVotes, 1)
        let fraction = Double(count) / Double(total)
        let mine = myVotes.contains(ans.id)
        let showCounts = kind == .disclosed || isClosed
        Button {
            toggleVote(ans.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mine ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mine ? Color.accentColor : Color.secondary)
                Text(ans.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                if showCounts {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
                    if showCounts && totalVotes > 0 {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(mine ? 0.3 : 0.18))
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(mine ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: mine ? 1.2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClosed)
    }

    /// Single-select: choose this answer, or retract if you tapped your current
    /// choice. Multi-select: toggle this answer in the current ballot. Either
    /// way, send the resulting full ballot — the SDK replaces the user's prior
    /// response with whatever array we pass.
    private func toggleVote(_ answerId: String) {
        var current = myVotes
        if maxSelections <= 1 {
            current = current.contains(answerId) ? [] : [answerId]
        } else {
            if current.contains(answerId) {
                current.remove(answerId)
            } else if current.count < Int(maxSelections) {
                current.insert(answerId)
            }
        }
        let ids = Array(current)
        Task {
            await room.sendPollResponse(pollStartEventId: pollStartEventId, answerIds: ids)
        }
    }
}
