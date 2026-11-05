extension MonitorInfo {
    /// Monitor-level: ignores the gaps of the workspace rules. Prefer ``Workspace/visibleRectPaddedByOuterGaps``
    /// whenever the workspace is known
    @MainActor
    var visibleRectPaddedByOuterGaps: Rect {
        visibleRect(paddedBy: ResolvedGaps(gaps: config.gaps, monitor: self).outer)
    }

    func visibleRect(paddedBy outer: ResolvedGaps.Outer) -> Rect {
        outer.pad(visibleRect)
    }

    var monitorId_oneBased: Int? {
        let sorted = globalSortedMonitorInfos
        let origin = self.rect.topLeftCorner
        return sorted.firstIndex { $0.rect.topLeftCorner == origin }.map { $0 + 1 }
    }
}

extension Workspace {
    @MainActor
    var resolvedGaps: ResolvedGaps { ResolvedGaps(gaps: config.gaps(for: self), monitor: workspaceMonitorInfo) }

    @MainActor
    var visibleRectPaddedByOuterGaps: Rect { workspaceMonitorInfo.visibleRect(paddedBy: resolvedGaps.outer) }
}
