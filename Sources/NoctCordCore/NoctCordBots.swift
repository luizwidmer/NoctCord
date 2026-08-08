import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordChannelPermissionTarget: Hashable, Sendable {
    case everyone
    case role(UUID)
}

public struct NoctCordChannelPermissionOverride: Codable, Equatable, Sendable {
    public let roleID: UUID?
    public let allow: [NoctCordPermission]
    public let deny: [NoctCordPermission]

    public init(
        roleID: UUID?,
        allow: Set<NoctCordPermission>,
        deny: Set<NoctCordPermission>
    ) {
        self.roleID = roleID
        self.allow = allow.sorted { $0.rawValue < $1.rawValue }
        self.deny = deny.sorted { $0.rawValue < $1.rawValue }
    }

    public var target: NoctCordChannelPermissionTarget {
        roleID.map(NoctCordChannelPermissionTarget.role) ?? .everyone
    }

    public var isStructurallyValid: Bool {
        let allowed = Set(allow)
        let denied = Set(deny)
        return allow.count <= NoctCordPermission.channelScoped.count
            && deny.count <= NoctCordPermission.channelScoped.count
            && allowed.count == allow.count
            && denied.count == deny.count
            && allowed.isDisjoint(with: denied)
            && allowed.isSubset(of: NoctCordPermission.channelScoped)
            && denied.isSubset(of: NoctCordPermission.channelScoped)
            && allow == allow.sorted { $0.rawValue < $1.rawValue }
            && deny == deny.sorted { $0.rawValue < $1.rawValue }
    }
}

public struct NoctCordBotCommand: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }

    public var isStructurallyValid: Bool {
        NoctCordValidation.isCommandName(name)
            && NoctCordValidation.isCommandDescription(summary)
    }
}

public struct NoctCordBotApplication: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let memberHandle: GroupScopedMemberHandleV2
    public let name: String
    public let commands: [NoctCordBotCommand]

    public init(
        id: UUID = UUID(),
        memberHandle: GroupScopedMemberHandleV2,
        name: String,
        commands: Set<NoctCordBotCommand>
    ) {
        self.id = id
        self.memberHandle = memberHandle
        self.name = name
        self.commands = commands.sorted { $0.name < $1.name }
    }

    public var isStructurallyValid: Bool {
        memberHandle.isStructurallyValid
            && NoctCordValidation.isName(name)
            && commands.count <= 32
            && Set(commands.map(\.name)).count == commands.count
            && commands.allSatisfy(\.isStructurallyValid)
            && commands == commands.sorted { $0.name < $1.name }
    }
}

public struct NoctCordBotCommandInvocation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let botID: UUID
    public let channelID: UUID
    public let commandName: String
    public let arguments: String

    public init(
        id: UUID = UUID(),
        botID: UUID,
        channelID: UUID,
        commandName: String,
        arguments: String = ""
    ) {
        self.id = id
        self.botID = botID
        self.channelID = channelID
        self.commandName = commandName
        self.arguments = arguments
    }

    public var isStructurallyValid: Bool {
        NoctCordValidation.isCommandName(commandName)
            && NoctCordValidation.isCommandArguments(arguments)
    }
}

public struct NoctCordBotInvocationContext: Equatable, Sendable {
    public let spaceID: UUID
    public let author: GroupScopedMemberHandleV2
    public let invocation: NoctCordBotCommandInvocation
}

public enum NoctCordBotRuntimeError: Error, Equatable {
    case invalidInvocation
    case botUnavailable
    case invalidResponse
}

public protocol NoctCordBotInvocationLedger: Sendable {
    /// Atomically claims an invocation. Returns false when it was already
    /// claimed or completed by this bot installation.
    func claim(_ invocationID: UUID) async throws -> Bool
    func preparedResponse(_ invocationID: UUID) async throws -> NoctCordBotResponseIntent?
    func storePreparedResponse(
        _ response: NoctCordBotResponseIntent,
        for invocationID: UUID
    ) async throws
    func complete(_ invocationID: UUID) async throws
    func release(_ invocationID: UUID) async
}

/// Development ledger. Production bot hosts should supply an encrypted,
/// durable implementation so process restarts cannot repeat side effects.
public actor NoctCordInMemoryBotInvocationLedger: NoctCordBotInvocationLedger {
    private var claimed: Set<UUID> = []
    private var completed: Set<UUID> = []
    private var preparedResponses: [UUID: NoctCordBotResponseIntent] = [:]

    public init() {}

    public func claim(_ invocationID: UUID) -> Bool {
        guard !claimed.contains(invocationID), !completed.contains(invocationID) else {
            return false
        }
        claimed.insert(invocationID)
        return true
    }

    public func complete(_ invocationID: UUID) {
        claimed.remove(invocationID)
        preparedResponses.removeValue(forKey: invocationID)
        completed.insert(invocationID)
    }

    public func preparedResponse(_ invocationID: UUID) -> NoctCordBotResponseIntent? {
        preparedResponses[invocationID]
    }

    public func storePreparedResponse(
        _ response: NoctCordBotResponseIntent,
        for invocationID: UUID
    ) {
        preparedResponses[invocationID] = response
    }

    public func release(_ invocationID: UUID) {
        claimed.remove(invocationID)
    }
}

public struct NoctCordBotResponseIntent: Codable, Equatable, Sendable {
    public let requiredAuthorMemberHandle: String
    public let operation: NoctCordOperation
}

/// Runs bot code in a separately operated client process. It never executes
/// at the relay and never receives relay-side plaintext authority.
public actor NoctCordBotRuntime {
    public typealias Handler = @Sendable (NoctCordBotInvocationContext) async throws -> String

    private let botID: UUID
    private let memberHandleRawValue: String
    private let ledger: any NoctCordBotInvocationLedger
    private let handler: Handler

    public init(
        botID: UUID,
        memberHandleRawValue: String,
        ledger: any NoctCordBotInvocationLedger,
        handler: @escaping Handler
    ) {
        self.botID = botID
        self.memberHandleRawValue = memberHandleRawValue
        self.ledger = ledger
        self.handler = handler
    }

    /// Claims and handles an invocation, but does not mark it complete. The
    /// caller must publish the returned operation with the required member
    /// credential and then call `markPublished(_:)`. On publication failure,
    /// call `release(_:)` so the invocation can be retried.
    public func prepareResponse(
        for event: NoctCordEvent,
        projection: NoctCordSpaceProjection
    ) async throws -> NoctCordBotResponseIntent? {
        guard event.operation.kind == .botCommandInvoked,
              let invocation = event.operation.botInvocation,
              invocation.botID == botID else {
            return nil
        }
        guard let bot = projection.botApplications[botID],
              bot.memberHandle.rawValue == memberHandleRawValue,
              bot.commands.contains(where: { $0.name == invocation.commandName }),
              projection.botInvocations[invocation.id] == invocation else {
            throw NoctCordBotRuntimeError.botUnavailable
        }
        guard try await ledger.claim(invocation.id) else { return nil }

        do {
            if let prepared = try await ledger.preparedResponse(invocation.id) {
                return prepared
            }
            let response = try await handler(
                NoctCordBotInvocationContext(
                    spaceID: event.spaceID,
                    author: event.author,
                    invocation: invocation
                )
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard NoctCordValidation.isMessage(response) else {
                throw NoctCordBotRuntimeError.invalidResponse
            }
            let intent = NoctCordBotResponseIntent(
                requiredAuthorMemberHandle: memberHandleRawValue,
                operation: .postMessage(
                    id: UUID(),
                    channelID: invocation.channelID,
                    text: response,
                    replyTo: invocation.id
                )
            )
            try await ledger.storePreparedResponse(intent, for: invocation.id)
            return intent
        } catch {
            await ledger.release(invocation.id)
            throw error
        }
    }

    public func markPublished(_ invocationID: UUID) async throws {
        try await ledger.complete(invocationID)
    }

    public func release(_ invocationID: UUID) async {
        await ledger.release(invocationID)
    }
}
