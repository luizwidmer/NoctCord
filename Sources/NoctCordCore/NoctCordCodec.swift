import Foundation
@preconcurrency import NoctweaveCore

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

    /// Group credentials must advertise every content family they may emit.
    /// Noct Cord retains Noctweave's baseline families and adds its single
    /// versioned application-event family before group creation or admission.
    public static var contentCapabilities: [ContentTypeCapabilityV2] {
        Array(Set(
            ProtocolCapabilityManifest.defaultContentTypes
                + [ContentTypeCapabilityV2(contentType)]
        )).sorted { ($0.authority, $0.name) < ($1.authority, $1.name) }
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
        let event = try decode(groupEvent.content)
        guard event.id == groupEvent.id,
              event.spaceID == groupEvent.groupID,
              event.author == groupEvent.authorMemberHandle,
              event.createdAt == groupEvent.createdAt else {
            throw NoctCordCodecError.bindingMismatch
        }
        return event
    }
}
