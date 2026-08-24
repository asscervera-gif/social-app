//
//  ClothingStoreView.swift
//  Social
//
//  Catálogo de ropa del avatar. Sin esta vista, ClothingStore.swift no tenía
//  ningún punto de entrada real en la app — un caso claro de "lógica sin
//  pantalla" que había que cerrar. Cuerpo/físico gratis, solo ropa de pago
//  (StoreKit 2), tal como exige la Fase 3.
//

import SwiftUI

struct ClothingStoreView: View {

    @StateObject private var store = ClothingStore()
    @State private var selectedCategory: String = "top"

    private let categories = [("top", "Torso"), ("bottom", "Piernas"), ("shoes", "Calzado")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Categoría", selection: $selectedCategory) {
                    ForEach(categories, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(store.catalog.filter { $0.category == selectedCategory }) { item in
                            ClothingCell(item: item, store: store)
                        }
                    }
                    .padding(.horizontal)
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle("Ropa")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restaurar compras") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.caption)
                }
            }
            .task { await store.loadProducts() }
        }
    }
}

private struct ClothingCell: View {
    let item: ClothingItem
    @ObservedObject var store: ClothingStore

    private var unlocked: Bool { store.isUnlocked(item) }
    private var priceLabel: String {
        store.products.first(where: { $0.id == item.id })?.displayPrice ?? "—"
    }

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14)
                .fill(.gray.opacity(0.12))
                .frame(height: 100)
                .overlay(
                    Image(systemName: "tshirt.fill")
                        .font(.title2)
                        .foregroundStyle(unlocked ? .primary : .secondary)
                )
                .overlay(alignment: .topTrailing) {
                    if !unlocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                            .padding(6)
                    }
                }

            Text(item.name)
                .font(.caption.bold())
                .multilineTextAlignment(.center)

            if item.isPaid && !unlocked {
                Button(priceLabel) {
                    Task { await store.purchase(item) }
                }
                .font(.caption2.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            } else {
                Text(item.isPaid ? "Comprado" : "Gratis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
