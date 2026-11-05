public let stableAeroSpaceAppId: String = "com.victornovais.HyprMac"
#if DEBUG
    public let aeroSpaceAppId: String = "com.victornovais.HyprMac.debug"
    public let aeroSpaceAppName: String = "HyprMac-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "HyprMac"
#endif
