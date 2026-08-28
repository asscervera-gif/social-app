//
//  StoryHighlightsRow.swift
//  Social
//
//  Destacados reales de historias en el perfil, comparado con Instagram --
//  fila de círculos justo debajo de la bio, igual en el propio perfil
//  (PerfilView.swift) que en el ajeno (ProfileViewerView.swift), reutilizada
//  tal cual en los dos porque la visibilidad ya la decide RLS
//  (0101_story_highlights.sql: `story_highlights_select`/`stories_select`
//  son las mismas para cualquiera que consulte, incluido el propio dueño).
//  No se muestra ninguna fila si la persona no tiene ningún destacado
//  todavía -- nunca un hueco vacío ni un texto de "sin destacados".
//  Equivalente de StoryHighlightsRow.kt (Android).
//

import SwiftUI

private struct HighlightSummary: Decodable, Identifiable {
    let id: UUID
    let title: String
    let cover_story_id: UUID?
}

private struct HighlightItemRow: Decodable {
    let story_id: UUID
}

private struct StoryMediaRow: Decodable {
    let id: UUID
    let media_url: String
}

struct StoryHighlightsRow: View {
    let profileID: UUID

    @State private var highlights: [HighlightSummary] = []
    @State private var covers: [UUID: String] = [:]
    @State private var openHighlight: HighlightSummary?
    // Borrar un destacado completo real, comparado con Instagram
    // (mantener pulsado el círculo -> "Eliminar destacado") -- hallazgo
    // real: un destacado creado quedaba para siempre sin salida real.
    // Solo tiene sentido sobre el propio perfil. Equivalente de
    // StoryHighlightsRow.kt (Android).
    @State private var myID: UUID?
    @State private var deletingHighlight: HighlightSummary?

    var body: some View {
        Group {
            if !highlights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(highlights) { highlight in
                            Button {
                                openHighlight = highlight
                            } label: {
                                VStack {
                                    ZStack {
                                        Circle().fill(.gray.opacity(0.15)).frame(width: 64, height: 64)
                                        if let coverID = highlight.cover_story_id,
                                           let urlString = covers[coverID],
                                           let url = URL(string: urlString) {
                                            AsyncImage(url: url) { image in
                                                image.resizable().scaledToFill()
                                            } placeholder: {
                                                Color.clear
                                            }
                                            .frame(width: 64, height: 64)
                                            .clipShape(Circle())
                                        } else {
                                            Text("⭐")
                                        }
                                    }
                                    Text(highlight.title)
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 64)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if profileID == myID {
                                    Button(role: .destructive) {
                                        deletingHighlight = highlight
                                    } label: {
                                        Label("Eliminar destacado", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { myID = try? await SupabaseManager.shared.client.auth.session.user.id }
        .alert("¿Borrar \"\(deletingHighlight?.title ?? "")\"?", isPresented: Binding(
            get: { deletingHighlight != nil },
            set: { isPresented in if !isPresented { deletingHighlight = nil } }
        )) {
            Button("Borrar", role: .destructive) {
                if let highlight = deletingHighlight {
                    highlights.removeAll { $0.id == highlight.id }
                    deletingHighlight = nil
                    Task {
                        try? await SupabaseManager.shared.client
                            .from("story_highlights")
                            .delete()
                            .eq("id", value: highlight.id)
                            .execute()
                    }
                }
            }
            Button("Cancelar", role: .cancel) { deletingHighlight = nil }
        } message: {
            Text("Esto borra el destacado completo. Las historias en sí no se ven afectadas.")
        }
        .task(id: profileID) {
            guard let rows: [HighlightSummary] = try? await SupabaseManager.shared.client
                .from("story_highlights")
                .select("id,title,cover_story_id")
                .eq("author_id", value: profileID)
                .execute()
                .value else {
                highlights = []
                return
            }
            highlights = rows
            let coverIDs = rows.compactMap { $0.cover_story_id }
            guard !coverIDs.isEmpty else {
                covers = [:]
                return
            }
            guard let mediaRows: [StoryMediaRow] = try? await SupabaseManager.shared.client
                .from("stories")
                .select("id,media_url")
                .in("id", values: coverIDs)
                .execute()
                .value else {
                covers = [:]
                return
            }
            covers = Dictionary(uniqueKeysWithValues: mediaRows.map { ($0.id, $0.media_url) })
        }
        .sheet(item: $openHighlight) { highlight in
            HighlightViewer(highlight: highlight)
        }
    }
}

/// Visor de un destacado real, comparado con Instagram -- ahora con las
/// mismas barras de progreso segmentadas y avance automático que el
/// visor de una historia activa (StoriesBar.swift.StoryViewer, mismo
/// patrón real reutilizado: 5s por foto, pasos de 50ms). Cierra el hueco
/// deliberado documentado hasta ahora en este mismo archivo. Los
/// adhesivos interactivos (encuesta/pregunta/responder) de una historia
/// activa siguen fuera de alcance a propósito -- un destacado ya no
/// tiene sentido real para responder/votar, esas piezas eran efímeras.
private struct HighlightViewer: View {
    let highlight: HighlightSummary

    @State private var mediaURLs: [String] = []
    @State private var index = 0
    @State private var progress: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    private func goNext() {
        if index < mediaURLs.count - 1 { index += 1 } else { dismiss() }
    }
    private func goPrevious() {
        if index > 0 { index -= 1 }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if index < mediaURLs.count, let url = URL(string: mediaURLs[index]) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { goPrevious() }
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { goNext() }
            }
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    ForEach(mediaURLs.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.35))
                                Capsule().fill(Color.white)
                                    .frame(width: geo.size.width * (i < index ? 1 : (i == index ? progress : 0)))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                Text(highlight.title)
                    .foregroundStyle(.white)
                    .font(.headline)
                    .padding()
            }
        }
        .task {
            guard let itemRows: [HighlightItemRow] = try? await SupabaseManager.shared.client
                .from("story_highlight_items")
                .select("story_id")
                .eq("highlight_id", value: highlight.id)
                .execute()
                .value else { return }
            let storyIDs = itemRows.map { $0.story_id }
            guard !storyIDs.isEmpty else { return }
            guard let mediaRows: [StoryMediaRow] = try? await SupabaseManager.shared.client
                .from("stories")
                .select("id,media_url")
                .in("id", values: storyIDs)
                .execute()
                .value else { return }
            mediaURLs = mediaRows.map { $0.media_url }
        }
        // Mismo criterio real que StoriesBar.swift.StoryViewer: 5s por
        // foto, cancelado sin avance doble por el cambio de `index`
        // cuando se avanza a mano. Clave compuesta "index-count" en vez
        // de solo `index`: sin esto, el avance automático nunca
        // arrancaría -- las fotos reales llegan de forma asíncrona
        // DESPUÉS de que `.task(id: index)` ya se disparó una vez con la
        // lista todavía vacía, y no se relanza solo porque cambie el
        // contenido de `mediaURLs` con el mismo `index` (0). Hallazgo
        // real, encontrado escribiendo esta misma ronda.
        .task(id: "\(index)-\(mediaURLs.count)") {
            guard !mediaURLs.isEmpty else { return }
            progress = 0
            let totalMs = 5000
            let stepMs = 50
            var elapsedMs = 0
            while elapsedMs < totalMs {
                try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                if Task.isCancelled { return }
                elapsedMs += stepMs
                withAnimation(.linear(duration: 0.05)) { progress = min(1, CGFloat(elapsedMs) / CGFloat(totalMs)) }
            }
            if !Task.isCancelled { goNext() }
        }
    }
}
