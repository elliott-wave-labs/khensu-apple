// SPDX-License-Identifier: AGPL-3.0-only

import Observation
import StoreKit

/// Tips paid with Apple in-app purchase. Apple keeps its App Store fee; what
/// remains is the creator's, and khensu.ñü takes no cut of it.
@MainActor @Observable
final class TipStore {
    static let productIDs = ["nu.khensu.ptah.tip.1", "nu.khensu.ptah.tip.5", "nu.khensu.ptah.tip.20"]

    private(set) var products: [Product] = []
    private(set) var loading = false
    var errorMessage: String?
    private var updates: Task<Void, Never>?

    init() {
        updates = Task {
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
            }
        }
    }

    func load() async {
        guard products.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns the price label once the purchase is verified and finished.
    func buy(_ product: Product) async -> String? {
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                return product.displayPrice
            case .success(.unverified):
                errorMessage = "The App Store couldn’t verify this purchase."
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return nil
    }
}
