import Common
import Foundation
import Network

private struct Subscriber {
    let connection: NWConnection
    let events: Set<ServerEventType>
}

@MainActor private var subscribers: [UniqueToken: Subscriber] = [:]

@MainActor
func handleSubscribeAndWaitTillError(_ connection: NWConnection, _ args: SubscribeCmdArgs) async {
    let id = UniqueToken()
    subscribers[id] = Subscriber(connection: connection, events: args.events)
    syncWindowTitleObservation(resetState: false)
    defer {
        subscribers.removeValue(forKey: id)
        syncWindowTitleObservation(resetState: false)
    }
    if args.sendInitial {
        let f = globalFocus
        for eventType in args.events {
            let event: ServerEvent
            switch eventType {
                case .focusChanged:
                    event = .focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name)
                case .workspaceChanged:
                    event = .workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name)
                case .modeChanged:
                    event = .modeChanged(mode: activeMode)
                case .focusedMonitorChanged:
                    event = .focusedMonitorChanged(
                        workspace: f.workspace.name,
                        monitorId_oneBased: f.workspace.workspaceMonitorInfo.monitorId_oneBased ?? 0,
                    )
                case .monitorsChanged:
                    event = .monitorsChanged(monitors: currentServerEventMonitors())
                case .windowDetected, .bindingTriggered, .windowClosed, .windowMoved, .windowTitleChanged: continue
            }
            if await connection.writeAtomic(event, jsonEncoder).error != nil {
                return
            }
        }
    }

    // Keep connection alive - wait for client to disconnect
    await connection.readTillError()
}

@MainActor
func hasSubscribers(for eventType: ServerEventType) -> Bool {
    subscribers.values.contains { $0.events.contains(eventType) }
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
}()

@MainActor private var lastBroadcast: Task<(), Never>? = nil

@MainActor
func broadcastEvent(_ event: ServerEvent) {
    // Writes suspend, so independent broadcast tasks could interleave and deliver events to a subscriber in a different
    // order than they were emitted (e.g. window-moved X->Y after Y->Z). Chaining every broadcast after the previous one
    // keeps the emission order for every subscriber
    let previous = lastBroadcast
    lastBroadcast = Task.startUnstructured { @MainActor in
        await previous?.value
        for (id, subscriber) in subscribers {
            guard subscriber.events.contains(event.eventType) else { continue }
            if await subscriber.connection.writeAtomic(event, jsonEncoder).error != nil {
                _ = subscribers.removeValue(forKey: id)
            }
        }
    }
}
