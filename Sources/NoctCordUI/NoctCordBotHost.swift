import Foundation
import NoctCordCore

public enum NoctCordBotHostError: Error, Equatable, LocalizedError {
    case wrongBotIdentity
    case publicationIncomplete

    public var errorDescription: String? {
        switch self {
        case .wrongBotIdentity:
            "The bot host does not hold the group credential required by this installation."
        case .publicationIncomplete:
            "The relay did not acknowledge the complete bot response publication."
        }
    }
}

public struct NoctCordBotHostCycleResult: Equatable, Sendable {
    public let observedInvocations: Int
    public let publishedResponses: Int
}

/// Headless application host for a single bot installation in one encrypted
/// Noct Cord community. The relay only carries opaque group records.
public actor NoctCordBotHost {
    private let coordinator: NoctCordTransportCoordinator
    private let spaceID: UUID
    private let runtime: NoctCordBotRuntime

    public init(
        coordinator: NoctCordTransportCoordinator,
        spaceID: UUID,
        runtime: NoctCordBotRuntime
    ) {
        self.coordinator = coordinator
        self.spaceID = spaceID
        self.runtime = runtime
    }

    @discardableResult
    public func processOnce() async throws -> NoctCordBotHostCycleResult {
        _ = try await coordinator.synchronize(spaceID: spaceID)
        let snapshot = try await coordinator.storedSpaceSnapshot(spaceID: spaceID)
        let result = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: snapshot.owner,
            activeMembers: Set(snapshot.members.map(\.handle)),
            historicalMembers: Set(snapshot.events.map(\.author)),
            events: snapshot.events
        )
        let projection = result.projection
        let invocations = Self.dispatchableInvocations(from: result)
        var publishedResponses = 0

        for event in invocations {
            guard let invocationID = event.operation.botInvocation?.id,
                  let intent = try await runtime.prepareResponse(
                    for: event,
                    projection: projection
                  ) else {
                continue
            }
            guard snapshot.currentMember.rawValue == intent.requiredAuthorMemberHandle else {
                await runtime.release(invocationID)
                throw NoctCordBotHostError.wrongBotIdentity
            }

            do {
                let publication = try await coordinator.publishOperation(
                    spaceID: spaceID,
                    operation: intent.operation
                )
                guard publication.complete else {
                    throw NoctCordBotHostError.publicationIncomplete
                }
                try await runtime.markPublished(invocationID)
                publishedResponses += 1
            } catch {
                await runtime.release(invocationID)
                throw error
            }
        }

        return NoctCordBotHostCycleResult(
            observedInvocations: invocations.count,
            publishedResponses: publishedResponses
        )
    }

    /// Signed group delivery is not enough to authorize an application command.
    /// A rejected event must never reach bot code or stop the processing loop.
    static func dispatchableInvocations(
        from result: NoctCordProjectionResult
    ) -> [NoctCordEvent] {
        let projection = result.projection
        return result.acceptedEvents.filter { event in
            guard event.operation.kind == .botCommandInvoked,
                  let invocation = event.operation.botInvocation,
                  projection.botInvocations[invocation.id] == invocation,
                  let bot = projection.botApplications[invocation.botID] else {
                return false
            }
            return bot.commands.contains { $0.name == invocation.commandName }
        }
    }

    public func run(pollInterval: Duration = .seconds(1)) async throws {
        while !Task.isCancelled {
            _ = try await processOnce()
            try await Task.sleep(for: pollInterval)
        }
    }
}
