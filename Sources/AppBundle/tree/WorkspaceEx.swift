import Common

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        let containers = children.filterIsInstance(of: TilingContainer.self)
        switch containers.count {
            case 0:
                let orientation: Orientation = switch config.defaultRootContainerOrientation(for: self) {
                    case .horizontal: .h
                    case .vertical: .v
                    case .auto: workspaceMonitorInfo.then { $0.width >= $0.height } ? .h : .v
                }
                return TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout(for: self), index: INDEX_BIND_LAST)
            case 1:
                return containers.singleOrNil().orDie()
            default:
                die("Workspace must contain zero or one tiling container as its child")
        }
    }

    /// The root container layout and orientation of the workspace rules apply only when the root container is created.
    /// Recreate the empty root containers, so that the reloaded rules are visible without waiting for the workspace to be
    /// garbage collected. The global defaults keep the upstream behavior, they don't affect the existing roots
    @MainActor static func recreateEmptyRootContainers(affectedByRulesOf previousConfig: Config) {
        for workspace in Workspace.all {
            let isAffected = previousConfig.workspaceRules[workspace.name]?.setsRootContainer == true ||
                config.workspaceRules[workspace.name]?.setsRootContainer == true
            guard isAffected,
                  let root = workspace.children.filterIsInstance(of: TilingContainer.self).singleOrNil(),
                  root.children.isEmpty
            else { continue }
            root.unbindFromParent()
        }
    }

    @MainActor
    var floatingWindows: [Window] {
        floatingWindowsContainer.children.filterIsInstance(of: Window.self)
    }

    @MainActor
    var floatingWindowsContainer: FloatingWindowsContainer {
        let containers = children.filterIsInstance(of: FloatingWindowsContainer.self)
        return switch containers.count {
            case 0: FloatingWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one FloatingWindowsContainer")
        }
    }

    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        let containers = children.filterIsInstance(of: MacosFullscreenWindowsContainer.self)
        return switch containers.count {
            case 0: MacosFullscreenWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one MacosFullscreenWindowsContainer")
        }
    }

    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        let containers = children.filterIsInstance(of: MacosHiddenAppsWindowsContainer.self)
        return switch containers.count {
            case 0: MacosHiddenAppsWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one MacosHiddenAppsWindowsContainer")
        }
    }

    @MainActor var isVisible: Bool { (parent as? WorkspacesContainer)?.visibleWorkspaceNameOrStale == self.name }

    @MainActor var workspaceMonitorInfo: MonitorInfo { // todo revisit this API (rename)
        return nodeMonitorInfo.orDie() // todo
    }

    @MainActor var forceAssignedMonitorInfo: MonitorInfo? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = globalSortedMonitorInfos
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitorInfo(sortedMonitors: sortedMonitors) }
            .first
    }
}
