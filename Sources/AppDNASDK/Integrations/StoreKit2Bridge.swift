import Foundation
import StoreKit

/// Native StoreKit 2 billing bridge. Default fallback when RevenueCat is not available.
final class StoreKit2Bridge: BillingBridgeProtocol {

    /// The shared reported set / delivery queue (SPEC-497 §13a.2). The purchase path writes each
    /// transaction id into the reported set BEFORE `finish()`, so the late observer never re-reports it,
    /// and marks the product in flight so the observer does not finish its update mid-purchase.
    private let deliveryQueue: PurchaseDeliveryQueue
    /// Server verification of every purchase and restored transaction (`/billing/verify`), in the
    /// background — see `PurchaseVerificationQueue`.
    private let verificationQueue: PurchaseVerificationQueue
    /// The product lookup — `Product.products(for:)` in production; injectable so a test can make it throw.
    private let loadProducts: ([String]) async throws -> [Product]

    init(
        deliveryQueue: PurchaseDeliveryQueue = .shared,
        verificationQueue: PurchaseVerificationQueue = .shared,
        loadProducts: (([String]) async throws -> [Product])? = nil
    ) {
        self.deliveryQueue = deliveryQueue
        self.verificationQueue = verificationQueue
        self.loadProducts = loadProducts ?? { try await Product.products(for: $0) }
    }

    /// Queue one verified transaction for `/billing/verify` and return at once: the send runs in a
    /// detached task, so neither the purchase nor the restore ever waits for — or fails with — the server.
    static func submitForVerification(
        _ transaction: Transaction,
        signedTransaction: String,
        queue: PurchaseVerificationQueue,
        appUserId: String? = AppDNA.identityManagerRef?.currentIdentity.userId
    ) {
        let entry = PendingVerification(
            transactionId: String(transaction.id),
            productId: transaction.productID,
            signedTransaction: signedTransaction,
            productType: transaction.productType == .autoRenewable ? "subs" : "inapp",
            appUserId: appUserId,
            queuedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        Task.detached { await queue.submit(entry) }
    }

    /// SPEC-497 §13a.2 (R40/R41) — the pure re-buy seam: StoreKit handed back a transaction that was
    /// ALREADY among the current entitlements before the purchase call (an owned non-consumable or
    /// subscription). No date check.
    static func isAlreadyOwned(preCallIds: Set<String>, transactionId: String) -> Bool {
        preCallIds.contains(transactionId)
    }

    /// SPEC-497 §13a.2 (R40/R41) — the live caller's `onPurchaseCompleted` delivery, after `finish()`.
    /// A re-buy of an owned item (`alreadyOwned`) delivers NOTHING. The purchase path calls this with
    /// `AppDNA.billingDelegate`; the `rebuy_already_owned` fixture calls it with its recording spy, so
    /// `delegate_calls: []` fails the moment a re-buy delivers. Returns whether it delivered.
    @MainActor
    @discardableResult
    static func deliverToLiveCaller(
        alreadyOwned: Bool,
        transaction: TransactionInfo,
        delegate: AppDNABillingDelegate?
    ) -> Bool {
        guard !alreadyOwned, let delegate else { return false }
        delegate.onPurchaseCompleted(productId: transaction.productId, transaction: transaction)
        return true
    }

    func purchase(
        productId: String,
        appAccountToken: UUID?
    ) async throws -> PurchaseResult {
        let products: [Product]
        do {
            products = try await loadProducts([productId])
        } catch {
            // A THROWN lookup (network, StoreKit unavailable) used to leave the purchase with no
            // `onPurchaseFailed` — only a lookup that returned nothing fired it.
            await fireBillingPurchaseFailed(productId: productId, error: error)
            throw error
        }
        guard let product = products.first else {
            let err = StoreKit2Error.productNotFound(productId)
            await fireBillingPurchaseFailed(productId: productId, error: err)
            throw err
        }

        // Bind the resulting transaction to the current app user (Apple
        // surfaces it on `Transaction.appAccountToken` and in App Store
        // Server-Server notifications, so the binding survives renewals).
        // `nil` token = host has not identified a user — proceed untagged,
        // preserving pre-identify first-launch behaviour, but log it so the
        // app developer can see it during integration.
        var options: Set<Product.PurchaseOption> = []
        if let token = appAccountToken {
            options.insert(.appAccountToken(token))
        } else {
            Log.warning("StoreKit2Bridge.purchase: no appAccountToken — host should call AppDNA.identify(userId:) BEFORE purchase to avoid cross-account entitlement leaks.")
        }

        // R40/R41 — the entitlement ids BEFORE the purchase call: a returned transaction among them is a
        // re-buy of something the user already owns.
        var preCallIds: Set<String> = []
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let owned) = entitlement { preCallIds.insert(String(owned.id)) }
        }

        await deliveryQueue.beginPurchase(productId: product.id)
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: options)
        } catch {
            await deliveryQueue.endPurchase(productId: product.id)
            await fireBillingPurchaseFailed(productId: productId, error: error)
            throw error
        }

        switch result {
        case .success(let verification):
            let transaction: Transaction
            do {
                transaction = try checkVerified(verification)
            } catch {
                await deliveryQueue.endPurchase(productId: product.id)
                await fireBillingPurchaseFailed(productId: productId, error: error)
                throw error
            }
            let transactionId = String(transaction.id)
            let alreadyOwned = Self.isAlreadyOwned(preCallIds: preCallIds, transactionId: transactionId)
            // Reported BEFORE finish(): the observer then finishes the matching update without emitting.
            await deliveryQueue.markReported(transactionId)
            await transaction.finish()
            await deliveryQueue.endPurchase(productId: product.id)

            // SPEC-400 — fire onPurchaseCompleted to the host's registered AppDNABillingDelegate (the live
            // caller's fire-and-forget delivery). Single source of truth for billing-delegate purchase
            // callbacks; PaywallManager does NOT fire here. A re-buy of an owned item delivers nothing
            // (SPEC-497 R40/R41, as Android) — decided inside `deliverToLiveCaller`, the seam the
            // `rebuy_already_owned` fixture drives.
            let environment = StoreKitEnvironment.name(of: transaction)
            let txInfo = TransactionInfo(
                transactionId: transactionId,
                productId: product.id,
                purchaseDate: transaction.purchaseDate,
                environment: environment
            )
            // §17-4 — server verification, in the background. A re-buy of an owned item is sent too: the
            // server's upsert is idempotent and it may never have seen the original.
            Self.submitForVerification(transaction, signedTransaction: verification.jwsRepresentation, queue: verificationQueue)
            await MainActor.run {
                Self.deliverToLiveCaller(alreadyOwned: alreadyOwned, transaction: txInfo, delegate: AppDNA.billingDelegate)
            }

            // SPEC-497 §13a.2 (R42–R46) — the price the store CHARGED (`transaction.price`, the intro price
            // for a paid intro, 0 for a free trial; the list price only when StoreKit has none) and
            // whether this is a free trial.
            let isTrial = TrialDetection.isFreeTrial(transaction: transaction, product: product)
            return PurchaseResult(
                productId: product.id,
                transactionId: transactionId,
                originalTransactionId: String(transaction.originalID),
                price: chargedPrice(transactionPrice: transaction.price, productPrice: product.price),
                currency: transaction.currency?.identifier ?? product.priceFormatStyle.currencyCode ?? "USD",
                provider: "storekit2",
                // `Product.subscription` is `Product.SubscriptionInfo?` — non-nil ONLY for an
                // auto-renewable subscription. A consumable / non-consumable / lifetime unlock leaves it
                // nil and therefore emits `purchase_completed` alone. This is the iOS half of the
                // discriminator Android reads off `Entitlement.expiresAt != null`.
                isSubscription: product.subscription != nil,
                isConsumable: transaction.productType == .consumable,
                isTrial: isTrial,
                alreadyOwned: alreadyOwned,
                environment: environment
            )

        case .userCancelled:
            await deliveryQueue.endPurchase(productId: product.id)
            let err = StoreKit2Error.userCancelled
            await fireBillingPurchaseFailed(productId: productId, error: err)
            throw err

        case .pending:
            await deliveryQueue.endPurchase(productId: product.id)
            let err = StoreKit2Error.purchasePending
            await fireBillingPurchaseFailed(productId: productId, error: err)
            throw err

        @unknown default:
            await deliveryQueue.endPurchase(productId: product.id)
            let err = StoreKit2Error.unknown
            await fireBillingPurchaseFailed(productId: productId, error: err)
            throw err
        }
    }

    func restore(appAccountToken: UUID?) async throws -> [String] {
        var restoredIds: [String] = []

        // Resolve the first-identifier anchor ONCE per restore call so the
        // decision matrix below sees a stable value across all transactions
        // even if the host identifies a different user mid-iteration.
        let firstIdentifier = AppAccountTokenResolver.firstIdentifiedToken()

        var granted: [(Transaction, String)] = []
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            // Per-user binding filter (see `EntitlementOwnerFilter`):
            // - tagged + matches current user → grant
            // - tagged + different user → DENY (cross-account leak guard)
            // - untagged + current user is the device's first-identifier
            //   → grant (migration-tolerant; legacy / pre-identify
            //   onboarding-paywall purchase)
            // - untagged + current user is NOT the first-identifier
            //   → DENY (the v1.0.62 leak close — was incorrectly granted)
            switch EntitlementOwnerFilter.decide(
                transactionToken: transaction.appAccountToken,
                expectedToken: appAccountToken,
                firstIdentifiedToken: firstIdentifier
            ) {
            case .grant, .grantAnonymousPolicy:
                restoredIds.append(transaction.productID)
                granted.append((transaction, result.jwsRepresentation))
            case .grantUntaggedMigration:
                Log.info("StoreKit2Bridge.restore: granting untagged historical transaction \(transaction.id) to the device's first-identifier (migration-tolerant policy — server should claim ownership).")
                restoredIds.append(transaction.productID)
                granted.append((transaction, result.jwsRepresentation))
            case .denyOtherUser:
                Log.warning("StoreKit2Bridge.restore: skipped transaction \(transaction.id) — appAccountToken does not match the current user.")
            case .denyUntaggedOtherUser:
                Log.warning("StoreKit2Bridge.restore: skipped untagged transaction \(transaction.id) — the current user is not the device's first-identifier, so the untagged history is not inherited (cross-account leak guard).")
            }
        }

        // §17-4 — every granted transaction goes to `/billing/verify` in the background (the untagged ones
        // are how the server claims them for this user). Never awaited: a restore does not wait for it.
        for (transaction, jws) in granted {
            Self.submitForVerification(transaction, signedTransaction: jws, queue: verificationQueue)
        }

        // SPEC-400 — fire onRestoreCompleted alongside the return.
        let ids = restoredIds
        await MainActor.run {
            AppDNA.billingDelegate?.onRestoreCompleted(restoredProducts: ids)
        }

        return restoredIds
    }

    /// SPEC-400 — single helper for the purchase-failure delegate fan-out.
    private func fireBillingPurchaseFailed(productId: String, error: Error) async {
        await MainActor.run {
            AppDNA.billingDelegate?.onPurchaseFailed(productId: productId, error: error)
        }
    }

    func getEntitlements(appAccountToken: UUID?) async -> [String] {
        // The same read-only pass `ExternalProviderBridge` uses (see `EntitlementOwnerFilter` for the
        // decision matrix).
        await StoreKitEntitlementReader.productIds(appAccountToken: appAccountToken, label: "StoreKit2Bridge")
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKit2Error.verificationFailed
        case .verified(let value):
            return value
        }
    }
}

// MARK: - Errors

enum StoreKit2Error: LocalizedError {
    case productNotFound(String)
    case userCancelled
    case purchasePending
    case verificationFailed
    case unknown

    var errorDescription: String? {
        switch self {
        case .productNotFound(let id): return "Product not found: \(id)"
        case .userCancelled: return "Purchase was cancelled"
        case .purchasePending: return "Purchase is pending approval"
        case .verificationFailed: return "Transaction verification failed"
        case .unknown: return "Unknown purchase error"
        }
    }
}
