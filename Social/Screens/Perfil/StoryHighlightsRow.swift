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
                        }
                    }
                }
            }
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

/// Visor minimalista de un destacado real -- alcance deliberado, distinto
/// del visor de una historia activa (StoriesBar.swift.StoryViewer): solo
/// pasa las fotos reales una a una al tocar, sin las barras de progreso ni
/// los adhesivos interactivos (encuesta/pregunta/responder) de una
/// historia activa. Añadir esa paridad completa es un hueco real aparte,
/// documentado en LOOP_STATE.md.
private struct HighlightViewer: View {
    let highlight: HighlightSummary

    @State private var mediaURLs: [String] = []
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss

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
                .contentShape(Rectangle())
                .onTapGesture {
                    if index < mediaURLs.count - 1 { index += 1 } else { dismiss() }
                }
            }
            Text(highlight.title)
                .foregroundStyle(.white)
                .font(.headline)
                .padding()
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
    }
}
