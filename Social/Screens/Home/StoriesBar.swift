//
//  StoriesBar.swift
//  Social
//
//  Barra de historias en la parte superior de Home — no existía ningún
//  cliente para Historias en ninguna plataforma (ver StoriesViewModel.swift
//  para el hallazgo completo). Equivalente de StoriesBar.kt.
//

import SwiftUI
import PhotosUI

struct StoriesBar: View {
    @StateObject private var viewModel = StoriesViewModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var viewingGroup: StoryGroup?
    @State private var myID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    VStack {
                        ZStack {
                            Circle().fill(.gray.opacity(0.15)).frame(width: 60, height: 60)
                            if viewModel.isUploading {
                                ProgressView()
                            } else {
                                Image(systemName: "plus")
                            }
                        }
                        Text("Tu historia").font(.caption2)
                    }
                }
                .onChange(of: selectedPhoto) { newValue in
                    Task {
                        if let data = try? await newValue?.loadTransferable(type: Data.self) {
                            await viewModel.createStory(imageData: data)
                        }
                    }
                }

                ForEach(viewModel.groups) { group in
                    Button {
                        viewingGroup = group
                    } label: {
                        VStack {
                            AsyncImage(url: URL(string: group.stories.first?.media_url ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(.gray.opacity(0.15))
                            }
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                            Text(group.authorName).font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        .task { await viewModel.load() }
        .fullScreenCover(item: $viewingGroup) { group in
            StoryViewer(group: group, viewModel: viewModel, myID: myID)
        }
        .task { myID = try? await SupabaseManager.shared.client.auth.session.user.id }
    }
}

/// Visor a pantalla completa, avanza a la siguiente historia del mismo
/// autor al tocar, se cierra al llegar al final — mismo patrón simple que
/// Instagram/WhatsApp Status -- antes solo tocar para pasar a mano, sin
/// barra de progreso ni avance automático, comparado con esas apps y con
/// SOCIAL_APP.html (`.stbar`/`.stbarf`). Ahora cada historia tiene su
/// propio segmento de progreso que se rellena en 5s y avanza sola; tocar
/// la mitad derecha adelanta, la izquierda retrocede -- mismo lenguaje de
/// gestos ya estandarizado.
private struct StoryViewer: View {
    let group: StoryGroup
    @ObservedObject var viewModel: StoriesViewModel
    let myID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    // "Quién vio tu historia" (0053_story_views.sql), comparado con
    // Instagram/Snapchat/WhatsApp Status -- antes ni siquiera se
    // registraba quién veía una historia, la tabla no existía.
    @State private var viewers: [StoriesViewModel.StoryViewer] = []
    @State private var showViewers = false
    @State private var progress: CGFloat = 0

    private func goNext() {
        if index < group.stories.count - 1 {
            index += 1
        } else {
            dismiss()
        }
    }

    private func goPrevious() {
        if index > 0 { index -= 1 }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let story = group.stories[safe: index] {
                AsyncImage(url: URL(string: story.media_url)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
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

                HStack(spacing: 4) {
                    ForEach(group.stories.indices, id: \.self) { i in
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

                Text(group.authorName)
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                    .padding(.horizontal, 16)

                if story.author_id == myID {
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                showViewers = true
                            } label: {
                                Text("👁 \(viewers.count) \(viewers.count == 1 ? "vista" : "vistas")")
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                    }
                    .padding()
                }
            }
        }
        .task(id: index) {
            showViewers = false
            guard let story = group.stories[safe: index] else { return }
            if story.author_id == myID {
                viewers = await viewModel.loadViewers(storyID: story.id)
            } else {
                await viewModel.recordView(story)
            }
        }
        // 5s por historia, mismo orden de magnitud que Instagram/WhatsApp
        // Status (SOCIAL_APP.html usaba 4s para su maqueta estática). Si
        // el usuario avanza a mano antes de que termine, `.task(id:)`
        // cancela esta tarea al cambiar `index` -- no se dispara un
        // avance doble.
        .task(id: index) {
            progress = 0
            withAnimation(.linear(duration: 5)) { progress = 1 }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { goNext() }
        }
        .sheet(isPresented: $showViewers) {
            NavigationStack {
                List(viewers) { viewer in
                    Text(viewer.displayName)
                }
                .overlay {
                    if viewers.isEmpty {
                        Text("Todavía nadie ha visto esta historia.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Vistas")
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
