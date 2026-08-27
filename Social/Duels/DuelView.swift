//
//  DuelView.swift
//  Social
//
//  Duelo de preguntas: menos de 60 segundos, una pregunta a la vez.
//

import SwiftUI

struct DuelView: View {

    @ObservedObject var viewModel: DuelViewModel
    let opponentSections: [ProfileSection]

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.stage {
            case .loading:
                ProgressView("Preparando el duelo…")

            case .answering:
                if let question = viewModel.questions[safe: viewModel.currentIndex] {
                    QuestionCard(
                        question: question,
                        index: viewModel.currentIndex,
                        total: viewModel.questions.count,
                        onAnswer: viewModel.answer
                    )
                }

            case .scoring:
                ProgressView("Calculando compatibilidad…")

            case .finished:
                ResultCard(delta: viewModel.delta ?? 0, explanation: viewModel.explanation ?? "") {
                    Task { await viewModel.start(opponentSections: opponentSections) }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(28)
    }
}

private struct QuestionCard: View {
    let question: DuelQuestion
    let index: Int
    let total: Int
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Pregunta \(index + 1) de \(total)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Text(question.prompt)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                Button {
                    onAnswer(offset)
                } label: {
                    Text(option)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct ResultCard: View {
    let delta: Int
    let explanation: String
    let onRematch: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(delta >= 0 ? .green : .red)

            Text("\(delta >= 0 ? "+" : "")\(delta) de compatibilidad")
                .font(.title3.bold())

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Revancha real, comparado con juegos/apps de citas con
            // duelos de preguntas -- antes exigía volver a entrar por
            // ChatView ("⚡ Retar a duelo") desde cero cada vez.
            Button("🔁 Retar de nuevo", action: onRematch)
                .buttonStyle(.bordered)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
