public let stableHyprMacAppId: String = "com.victornovais.HyprMac"
#if DEBUG
    public let hyprMacAppId: String = "com.victornovais.HyprMac.debug"
    public let hyprMacAppName: String = "HyprMac-Debug"
#else
    public let hyprMacAppId: String = stableHyprMacAppId
    public let hyprMacAppName: String = "HyprMac"
#endif
