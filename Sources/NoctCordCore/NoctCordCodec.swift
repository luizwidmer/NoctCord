import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordCodecError: Error, Equatable {
    case invalidEvent
    case unsupportedContent
    case bindingMismatch
}

public enum NoctCordCodec {
    public static var contentType: ContentTypeId {
        ContentTypeId(authority: "org.noctcord", name: "event", major: 1)
    }

    public static func encode(_ event: NoctCordEvent) throws -> EncodedContent {
        guard event.isStructurallyValid else { throw NoctCordCodecError.invalidEvent }
        let bytes = try NoctweaveCoder.encode(event, sortedKeys: true)
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
        let event = try NoctweaveCoder.decode(NoctCordEvent.self, from: content.payload)
        guard event.isStructurallyValid,
              content.parameters["space"] == event.spaceID.uuidString.lowercased() else {
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
