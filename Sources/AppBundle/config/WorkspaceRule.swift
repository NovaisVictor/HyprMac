import Common

/// `[workspace.<name>]` config table. nil values inherit the global config
struct WorkspaceRule: Withable, Equatable, Sendable {
    var defaultRootContainerLayout: Layout? = nil
    var defaultRootContainerOrientation: DefaultContainerOrientation? = nil
    var enableNormalizationFlattenContainers: Bool? = nil
    var enableNormalizationOppositeOrientationForNestedContainers: Bool? = nil
    var newWindowPlacement: NewWindowPlacement? = nil
    var masterNewWindow: MasterNewWindow? = nil
    var gaps: GapsOverride = GapsOverride()

    var setsRootContainer: Bool { defaultRootContainerLayout != nil || defaultRootContainerOrientation != nil }
}

extension Config {
    func defaultRootContainerLayout(for workspace: Workspace) -> Layout {
        workspaceRules[workspace.name]?.defaultRootContainerLayout ?? defaultRootContainerLayout
    }

    func defaultRootContainerOrientation(for workspace: Workspace) -> DefaultContainerOrientation {
        workspaceRules[workspace.name]?.defaultRootContainerOrientation ?? defaultRootContainerOrientation
    }

    func enableNormalizationFlattenContainers(for workspace: Workspace) -> Bool {
        workspaceRules[workspace.name]?.enableNormalizationFlattenContainers ?? enableNormalizationFlattenContainers
    }

    func enableNormalizationOppositeOrientationForNestedContainers(for workspace: Workspace) -> Bool {
        workspaceRules[workspace.name]?.enableNormalizationOppositeOrientationForNestedContainers
            ?? enableNormalizationOppositeOrientationForNestedContainers
    }

    func newWindowPlacement(for workspace: Workspace) -> NewWindowPlacement {
        workspaceRules[workspace.name]?.newWindowPlacement ?? newWindowPlacement
    }

    func masterNewWindow(for workspace: Workspace) -> MasterNewWindow {
        workspaceRules[workspace.name]?.masterNewWindow ?? masterNewWindow
    }

    func gaps(for workspace: Workspace) -> Gaps {
        workspaceRules[workspace.name]?.gaps.applied(to: gaps) ?? gaps
    }
}
