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
            StoryViewer(group: group)
        }
    }
}

/// Visor a pantalla completa, avanza a la siguiente historia del mismo
/// autor al tocar, se cierra al llegar al final — mismo patrón simple que
/// Instagram/WhatsApp Status, sin arriesgar gestos/animaciones complejas
/// no verificadas.
private struct StoryViewer: View {
    let group: StoryGroup
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let story = group.stories[safe: index] {
                AsyncImage(url: URL(string: story.media_url)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                Text(group.authorName)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if index < group.stories.count - 1 {
                index += 1
            } else {
                dismiss()
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
