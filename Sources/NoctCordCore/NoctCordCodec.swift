import Foundation
@preconcurrency import NoctweaveCore

#if !NOCTCORD_VERIFIED_CORE
#error("NoctCord requires authenticated Core receipts and NOCTCORD_VERIFIED_CORE; legacy policy authoring is disabled.")
#endif

public enum NoctCordCodecError: Error, Equatable {
    case invalidEvent
    case unsupportedContent
    case bindingMismatch
}

public enum NoctCordCodec {
    public static let maximumEventBytes = NoctweaveArchitectureV2.maximumContentPayloadBytes

    public static var contentType: ContentTypeId {
        ContentTypeId(authority: "org.noctcord", name: "event", major: 1)
    }

    public static var secureContentType: ContentTypeId {
        ContentTypeId(authority: "org.noctcord", name: "event", major: 2)
    }

    /// Existing v1 credentials advertise only major 1. During an explicit
    /// in-place migration, the v2 payload uses that already-authorized family
    /// with an exact schema discriminator. Legacy decoders reject the extra
    /// parameter; verified v2 projection never accepts a bare v1 payload.
    public static func isSecureContent(_ content: EncodedContent) -> Bool {
        content.type == secureContentType
            || (content.type == contentType && content.parameters["schema"] == "2")
    }

    /// Group credentials must advertise every content family they may emit.
    /// Noct Cord retains Noctweave's baseline families and adds its single
    /// versioned application-event family before group creation or admission.
    public static var contentCapabilities: [ContentTypeCapabilityV2] {
        let cordEvents = ContentTypeCapabilityV2(
            authority: contentType.authority,
            name: contentType.name,
            majorVersions: [contentType.major, secureContentType.major]
        )
        return (ProtocolCapabilityManifest.defaultContentTypes.filter {
            $0.authority != cordEvents.authority || $0.name != cordEvents.name
        } + [cordEvents]).sorted {
            ($0.authority, $0.name) < ($1.authority, $1.name)
        }
    }

    public static func encode(_ event: NoctCordEvent) throws -> EncodedContent {
        guard event.isStructurallyValid else { throw NoctCordCodecError.invalidEvent }
        let bytes = try NoctweaveCoder.encode(event, sortedKeys: true)
        guard !bytes.isEmpty, bytes.count <= maximumEventBytes else {
            throw NoctCordCodecError.invalidEvent
        }
        let content = EncodedContent(
            type: contentType,
            parameters: ["space": event.spaceID.uuidString.lowercased()],
            payload: bytes,
            fallbackText: "Noct Cord event",
            disposition: .visible
        )
        guard content.isStructurallyValid else { throw NoctCordCodecError.invalidEvent }
        return content
    }

    public static func decode(_ content: EncodedContent) throws -> NoctCordEvent {
        guard content.type == contentType else { throw NoctCordCodecError.unsupportedContent }
        guard content.isStructurallyValid,
              !content.payload.isEmpty,
              content.payload.count <= maximumEventBytes,
              content.fallbackText == "Noct Cord event",
              content.disposition == .visible,
              NoctweaveCanonicalJSON.isCanonical(content.payload) else {
            throw NoctCordCodecError.invalidEvent
        }
        let event = try NoctweaveCoder.decode(NoctCordEvent.self, from: content.payload)
        guard event.isStructurallyValid,
              content.parameters == [
                  "space": event.spaceID.uuidString.lowercased()
              ],
              try NoctweaveCoder.encode(event, sortedKeys: true) == content.payload else {
            throw NoctCordCodecError.invalidEvent
        }
        return event
    }

    public static func wrap(
        _ event: NoctCordEvent,
        credential: GroupScopedCredentialHandleV2,
        clientTransactionID: UUID = UUID()
    ) throws -> GroupConversationEventV2 {
        let content = try encode(event)
        return GroupConversationEventV2(
            id: event.id,
            clientTransactionID: clientTransactionID,
            groupID: event.spaceID,
            authorMemberHandle: event.author,
            authorCredentialHandle: credential,
            createdAt: event.createdAt,
            kind: .application,
            content: content
        )
    }

    public static func unwrap(_ groupEvent: GroupConversationEventV2) throws -> NoctCordEvent {
        guard groupEvent.kind == .application else {
            throw NoctCordCodecError.unsupportedContent
        }
        // The legacy projection calls this entry point. Never flatten a v2
        // payload into a bare v1 event: doing so would discard its Core
        // receipt and owner-checkpoint authorization boundary.
        let event = try decode(groupEvent.content)
        guard event.id == groupEvent.id,
              event.spaceID == groupEvent.groupID,
              event.author == groupEvent.authorMemberHandle,
              event.createdAt == groupEvent.createdAt else {
            throw NoctCordCodecError.bindingMismatch
        }
        return event
    }

    public static func encodeSecure(
        _ secure: NoctCordSecureEventV2,
        usingLegacyCapability: Bool = false
    ) throws -> EncodedContent {
        guard secure.isStructurallyValid else { throw NoctCordCodecError.invalidEvent }
        let bytes = try NoctweaveCoder.encode(secure, sortedKeys: true)
        guard !bytes.isEmpty, bytes.count <= maximumEventBytes else {
            throw NoctCordCodecError.invalidEvent
        }
        let content = EncodedContent(
            type: usingLegacyCapability ? contentType : secureContentType,
            parameters: usingLegacyCapability
                ? ["space": secure.event.spaceID.uuidString.lowercased(), "schema": "2"]
                : ["space": secure.event.spaceID.uuidString.lowercased()],
            payload: bytes,
            fallbackText: "Noct Cord secure event",
            disposition: .visible
        )
        guard content.isStructurallyValid else { throw NoctCordCodecError.invalidEvent }
        return content
    }

    public static func decodeSecure(_ content: EncodedContent) throws -> NoctCordSecureEventV2 {
        guard isSecureContent(content) else {
            throw NoctCordCodecError.unsupportedContent
        }
        guard content.isStructurallyValid,
              !content.payload.isEmpty,
              content.payload.count <= maximumEventBytes,
              content.fallbackText == "Noct Cord secure event",
              content.disposition == .visible,
              NoctweaveCanonicalJSON.isCanonical(content.payload) else {
            throw NoctCordCodecError.invalidEvent
        }
        let secure = try NoctweaveCoder.decode(NoctCordSecureEventV2.self, from: content.payload)
        guard secure.isStructurallyValid,
              content.parameters == (content.type == contentType
                  ? ["space": secure.event.spaceID.uuidString.lowercased(), "schema": "2"]
                  : ["space": secure.event.spaceID.uuidString.lowercased()]),
              try NoctweaveCoder.encode(secure, sortedKeys: true) == content.payload else {
            throw NoctCordCodecError.invalidEvent
        }
        return secure
    }

    public static func wrapSecure(
        _ secure: NoctCordSecureEventV2,
        usingLegacyCapability: Bool = false,
        clientTransactionID: UUID = UUID()
    ) throws -> GroupConversationEventV2 {
        GroupConversationEventV2(
            id: secure.event.id,
            clientTransactionID: clientTransactionID,
            groupID: secure.event.spaceID,
            authorMemberHandle: secure.event.author,
            authorCredentialHandle: secure.credential,
            createdAt: secure.event.createdAt,
            kind: .application,
            content: try encodeSecure(
                secure, usingLegacyCapability: usingLegacyCapability
            )
        )
    }

    public static func unwrapSecure(
        _ groupEvent: GroupConversationEventV2
    ) throws -> NoctCordSecureEventV2 {
        guard groupEvent.kind == .application else {
            throw NoctCordCodecError.unsupportedContent
        }
        let secure = try decodeSecure(groupEvent.content)
        guard secure.event.id == groupEvent.id,
              secure.event.spaceID == groupEvent.groupID,
              secure.event.author == groupEvent.authorMemberHandle,
              secure.credential == groupEvent.authorCredentialHandle,
              secure.event.createdAt == groupEvent.createdAt else {
            throw NoctCordCodecError.bindingMismatch
        }
        return secure
    }
}
