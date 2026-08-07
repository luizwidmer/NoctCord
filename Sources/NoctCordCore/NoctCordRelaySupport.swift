import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordRelayTier: String, Codable, Equatable, Sendable {
    case incompatible
    case encryptedGroupFallback
    case realtimeMVP
    case durableCommunity
}

public enum NoctCordDeliveryProfile: String, Codable, Equatable, Sendable {
    case immediate
    case temporallyBucketed
}

public struct NoctCordRelayAssessment: Equatable, Sendable {
    public let tier: NoctCordRelayTier
    public let deliveryProfile: NoctCordDeliveryProfile
    public let usesCompactPackets: Bool
    public let supportsAttachments: Bool
    public let supportsFederation: Bool
    public let supportsEphemeralPresence: Bool
    public let missingModules: [String]
}

/// Noct Cord consumes relay capabilities without making the relay aware of
/// spaces, channels, roles, members, or message plaintext.
public enum NoctCordRelaySupport {
    public static let opaqueRouteModule = "nw.opaque-route"
    public static let realtimeRouteModule = "nw.realtime-route"
    public static let blobModule = "nw.blobs"
    public static let federationModule = "nw.federation"

    /// Proposed application-neutral extension for durable, cursor-based,
    /// capability-authorized encrypted logs. Relays must not advertise it
    /// before the implementation and interoperability suite are complete.
    public static let sharedLogModule = "nw.shared-log"

    /// Proposed best-effort lease service. Participation must remain optional
    /// because presence increases timing and relationship metadata exposure.
    public static let ephemeralPresenceModule = "nw.ephemeral-presence"

    public static func assess(_ info: RelayInfo) -> NoctCordRelayAssessment {
        guard let manifest = info.protocolCapabilities else {
            return NoctCordRelayAssessment(
                tier: .incompatible,
                deliveryProfile: deliveryProfile(
                    temporalBucketSeconds: info.temporalBucketSeconds,
                    temporalBucketScheduleSeconds: info.temporalBucketScheduleSeconds
                ),
                usesCompactPackets: false,
                supportsAttachments: false,
                supportsFederation: false,
                supportsEphemeralPresence: false,
                missingModules: ["relay capability manifest"]
            )
        }
        return assess(
            manifest,
            temporalBucketSeconds: info.temporalBucketSeconds,
            temporalBucketScheduleSeconds: info.temporalBucketScheduleSeconds
        )
    }

    public static func assess(
        _ manifest: RelayCapabilityManifestV2,
        temporalBucketSeconds: Int = 0,
        temporalBucketScheduleSeconds: [Int]? = nil
    ) -> NoctCordRelayAssessment {
        let profile = deliveryProfile(
            temporalBucketSeconds: temporalBucketSeconds,
            temporalBucketScheduleSeconds: temporalBucketScheduleSeconds
        )
        let hasCore = manifest.supports(module: "nw.core", version: 2)
        let hasOpaqueRoute = manifest.supports(module: opaqueRouteModule, version: 2)
        let hasRealtimeRoute = manifest.supports(module: realtimeRouteModule, version: 1)
        guard manifest.isStructurallyValid,
              hasCore,
              hasOpaqueRoute || hasRealtimeRoute,
              profile == .immediate else {
            var missing: [String] = []
            if !hasCore { missing.append("nw.core@2") }
            if !hasOpaqueRoute && !hasRealtimeRoute {
                missing.append("nw.realtime-route@1 or nw.opaque-route@2")
            }
            if profile != .immediate { missing.append("temporalBucketing=off") }
            return NoctCordRelayAssessment(
                tier: .incompatible,
                deliveryProfile: profile,
                usesCompactPackets: false,
                supportsAttachments: false,
                supportsFederation: false,
                supportsEphemeralPresence: false,
                missingModules: missing
            )
        }

        let hasSharedLog = manifest.supports(module: sharedLogModule, version: 1)
        let tier: NoctCordRelayTier
        if hasRealtimeRoute && hasSharedLog {
            tier = .durableCommunity
        } else if hasRealtimeRoute {
            tier = .realtimeMVP
        } else {
            tier = .encryptedGroupFallback
        }
        var missing: [String] = []
        if !hasRealtimeRoute { missing.append("nw.realtime-route@1") }
        if !hasSharedLog { missing.append("nw.shared-log@1") }
        return NoctCordRelayAssessment(
            tier: tier,
            deliveryProfile: profile,
            usesCompactPackets: hasRealtimeRoute,
            supportsAttachments: manifest.supports(module: blobModule, version: 1),
            supportsFederation: manifest.supports(module: federationModule, version: 1),
            supportsEphemeralPresence: manifest.supports(
                module: ephemeralPresenceModule,
                version: 1
            ),
            missingModules: missing
        )
    }

    private static func deliveryProfile(
        temporalBucketSeconds: Int,
        temporalBucketScheduleSeconds: [Int]?
    ) -> NoctCordDeliveryProfile {
        temporalBucketSeconds == 0
            && (temporalBucketScheduleSeconds?.isEmpty ?? true)
            ? .immediate
            : .temporallyBucketed
    }
}
