//
//  ClothingStore.swift
//  Social
//
//  Catálogo de ropa para el avatar. El cuerpo/físico es gratis e ilimitado
//  (se edita en el propio motor de avatar); solo la ropa tiene productos de
//  pago, gestionados con StoreKit 2. Los identificadores de producto deben
//  coincidir con los configurados en App Store Connect.
//

import Foundation
import StoreKit

struct ClothingItem: Identifiable, Hashable {
    let id: String              // coincide con el productID de StoreKit si isPaid == true
    let name: String
    let category: String        // "top", "bottom", "shoes", "accessory"
    let isPaid: Bool
}

@MainActor
final class ClothingStore: ObservableObject {

    /// Catálogo completo. Los productos gratuitos no requieren StoreKit.
    let catalog: [ClothingItem] = [
        ClothingItem(id: "tshirt_basic", name: "Camiseta básica", category: "top", isPaid: false),
        ClothingItem(id: "jeans_basic", name: "Vaqueros básicos", category: "bottom", isPaid: false),
        ClothingItem(id: "sneakers_basic", name: "Zapatillas básicas", category: "shoes", isPaid: false),
        ClothingItem(id: "com.social.clothing.jacket_neon", name: "Chaqueta neón", category: "top", isPaid: true),
        ClothingItem(id: "com.social.clothing.dress_gala", name: "Vestido de gala", category: "top", isPaid: true),
        ClothingItem(id: "com.social.clothing.boots_leather", name: "Botas de cuero", category: "shoes", isPaid: true)
    ]

    @Published private(set) var purchasedIDs: Set<String> = []
    @Published private(set) var products: [Product] = []
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = listenForTransactionUpdates()
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Carga los Product de StoreKit para los artículos de pago del catálogo.
    func loadProducts() async {
        let paidIDs = catalog.filter { $0.isPaid }.map { $0.id }
        do {
            products = try await Product.products(for: paidIDs)
        } catch {
            errorMessage = "No se pudo cargar la tienda de ropa: \(error.localizedDescription)"
        }
    }

    func isUnlocked(_ item: ClothingItem) -> Bool {
        !item.isPaid || purchasedIDs.contains(item.id)
    }

    func purchase(_ item: ClothingItem) async {
        guard item.isPaid, let product = products.first(where: { $0.id == item.id }) else { return }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    purchasedIDs.insert(transaction.productID)
                    await transaction.finish()
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "No se pudo completar la compra: \(error.localizedDescription)"
        }
    }

    /// Restaura compras previas (obligatorio para revisión de App Store).
    func restorePurchases() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                purchasedIDs.insert(transaction.productID)
            }
        }
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await self?.purchasedIDs.insert(transaction.productID)
                await transaction.finish()
            }
        }
    }
}
