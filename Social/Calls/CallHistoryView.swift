//
//  CallHistoryView.swift
//  Social
//
//  Historial de llamadas real, comparado con WhatsApp/Messenger/FaceTime --
//  ver CallHistoryViewModel.swift para el hallazgo completo. Icono real
//  por dirección/resultado (📞↗/📞↙ entrante-saliente, ❌ perdida),
//  duración real solo cuando la llamada de verdad terminó con alguien al
//  otro lado. Equivalente de CallHistoryScreen.kt.
//

import SwiftUI

struct CallHistoryView: View {
    @StateObject private var viewModel = CallHistoryViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.entries.isEmpty && !viewModel.isLoading {
                Text("Todavía no tienes ninguna llamada.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.entries) { entry in
                let call = entry.call
                let missed = call.status == "declined" || call.status == "missed"
                HStack(spacing: 10) {
                    Text(missed ? "❌" : (entry.isOutgoing ? "📞↗" : "📞↙"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text((entry.isGroup ? "👥 " : "") + entry.otherName)
                            .font(.subheadline.bold())
                            .foregroundStyle(missed ? .red : .primary)
                        Text(relativeTime(call.createdAt ?? "") + (call.kind == "video" ? " · Vídeo" : " · Voz"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if call.status == "ended", let createdAt = call.createdAt, let endedAt = call.endedAt,
                       let duration = callDuration(createdAt: createdAt, endedAt: endedAt) {
                        Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Llamadas")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    /// Duración real solo si la llamada de verdad terminó con alguien al
    /// otro lado -- una perdida/rechazada nunca tuvo duración real,
    /// mostrarla inventaría un dato que no existe.
    private func callDuration(createdAt: String, endedAt: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt),
              let end = formatter.date(from: endedAt) ?? ISO8601DateFormatter().date(from: endedAt) else {
            return nil
        }
        let secs = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

/// Duplicado a propósito, no compartido -- mismo criterio ya usado en
/// ChatView.swift/HomeView.swift/PostDetailView.swift.
private func relativeTime(_ isoTimestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let then = formatter.date(from: isoTimestamp) ?? ISO8601DateFormatter().date(from: isoTimestamp) else {
        return ""
    }
    let seconds = Date().timeIntervalSince(then)
    switch seconds {
    case ..<60: return "ahora"
    case ..<3600: return "hace \(Int(seconds / 60))min"
    case ..<86400: return "hace \(Int(seconds / 3600))h"
    case ..<604800: return "hace \(Int(seconds / 86400))d"
    default: return "hace \(Int(seconds / 604800))sem"
    }
}
