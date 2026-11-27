import Foundation
import NIOConcurrencyHelpers

/// Host-registered stored provider injected into `KWWKAI` at startup.
///
/// Participating providers appear in `providerDirectory`, `storedProviderOrder`,
/// `ProviderAttribution.displayNames`, `ModelsCatalog` (when `models` is
/// non-empty), and `registerStored` / `registerAllStored` without baking
/// host-specific or relay-backed providers into kwwk itself.
///
/// Hosts should register all custom providers at process startup before
/// evaluating cached directory/catalog snapshots. The `Model` returned by
/// `register` must carry `model.provider == descriptor.scope` so
/// `registerAllStored`'s scope deduplication and `APIRegistry` dispatch align.
public struct StoredProviderRegistration: Sendable {
    public typealias RegisterHandler = @Sendable (
        _ manager: OAuthManager,
        _ credentials: OAuthCredentials,
        _ modelOverride: String?,
        _ context1m: Bool,
        _ primeToken: Bool,
        _ notice: @escaping @Sendable (String) -> Void
    ) async throws -> ResolvedAuth?

    public let descriptor: ProviderDescriptor
    /// Display name exposed on `ProviderAttribution.displayNames[descriptor.scope]`
    /// (and `descriptor.catalogKey` when distinct).
    public let attributionDisplayName: String
    /// Optional bundled model list registered in `ModelsCatalog` under
    /// `descriptor.catalogKey` while this provider is registered.
    public let models: [Model]
    /// Registers the provider on `APIRegistry.shared` and returns its active
    /// `ResolvedAuth` (or `nil` to skip).
    public let register: RegisterHandler

    public init(
        descriptor: ProviderDescriptor,
        attributionDisplayName: String? = nil,
        models: [Model] = [],
        register: @escaping RegisterHandler
    ) {
        self.descriptor = descriptor
        self.attributionDisplayName = attributionDisplayName ?? descriptor.displayName
        self.models = models
        self.register = register
    }
}

/// Process-wide registry of host-provided stored providers.
///
/// Thread-safe and idempotent by `descriptor.storeId`: calling `register(_:)`
/// again with the same `storeId` updates the existing entry in place.
public enum StoredProviderRegistry {
    private static let entries = NIOLockedValueBox<[StoredProviderRegistration]>([])

    /// Register (or replace in place by `descriptor.storeId`) a host-provided
    /// stored provider. When `registration.models` is non-empty, those models
    /// are also registered into `ModelsCatalog` under
    /// `registration.descriptor.catalogKey`.
    public static func register(_ registration: StoredProviderRegistration) {
        entries.withLockedValue { list in
            var previousCatalogKey: String?
            if let idx = list.firstIndex(where: { $0.descriptor.storeId == registration.descriptor.storeId }) {
                let previous = list[idx]
                list[idx] = registration
                if !previous.models.isEmpty {
                    previousCatalogKey = previous.descriptor.catalogKey
                }
            } else {
                list.append(registration)
            }
            if let previousCatalogKey, previousCatalogKey != registration.descriptor.catalogKey {
                syncCatalog(forKey: previousCatalogKey, in: list)
            }
            if !registration.models.isEmpty || previousCatalogKey == registration.descriptor.catalogKey {
                syncCatalog(forKey: registration.descriptor.catalogKey, in: list)
            }
        }
    }

    /// Remove a previously registered host stored provider by `storeId`,
    /// restoring any earlier registration's models for the same `catalogKey`
    /// or unregistering the key from `ModelsCatalog` when none remain.
    public static func unregister(storeId: String) {
        entries.withLockedValue { list in
            guard let idx = list.firstIndex(where: { $0.descriptor.storeId == storeId }) else {
                return
            }
            let removed = list.remove(at: idx)
            guard !removed.models.isEmpty else { return }
            syncCatalog(forKey: removed.descriptor.catalogKey, in: list)
        }
    }

    private static func syncCatalog(forKey key: String, in list: [StoredProviderRegistration]) {
        if let owner = list.last(where: { !$0.models.isEmpty && $0.descriptor.catalogKey == key }) {
            ModelsCatalog.register(provider: key, models: owner.models)
        } else {
            ModelsCatalog.unregister(provider: key)
        }
    }

    static var registrations: [StoredProviderRegistration] {
        entries.withLockedValue { $0 }
    }

    static func registration(forStoreId storeId: String) -> StoredProviderRegistration? {
        entries.withLockedValue { list in
            list.first { $0.descriptor.storeId == storeId }
        }
    }

    static func attributionDisplayName(for provider: String) -> String? {
        entries.withLockedValue { list in
            if let match = list.first(where: { $0.descriptor.scope == provider }) {
                return match.attributionDisplayName
            }
            if let match = list.first(where: { $0.descriptor.catalogKey == provider }) {
                return match.attributionDisplayName
            }
            return nil
        }
    }

    static var attributionDisplayNames: [String: String] {
        entries.withLockedValue { list in
            guard !list.isEmpty else { return [:] }
            var map: [String: String] = [:]
            // Match attributionDisplayName(for:): scopes first (first-wins),
            // then catalogKeys without overwriting any scope entry.
            for entry in list where map[entry.descriptor.scope] == nil {
                map[entry.descriptor.scope] = entry.attributionDisplayName
            }
            for entry in list where map[entry.descriptor.catalogKey] == nil {
                map[entry.descriptor.catalogKey] = entry.attributionDisplayName
            }
            return map
        }
    }
}
