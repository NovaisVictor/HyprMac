import AppKit
import Common

struct ConfigCommand: Command {
    let args: ConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        switch args.mode {
            case .getKey(let key):
                return getKey(io, args: args, key: key)
            case .majorKeys:
                let out = """
                    .
                    mode
                    \(config.modes.keys.lazy.map { "mode.\($0).binding" }.joined(separator: "\n"))
                    """
                return .succ(io.out(out))
            case .allKeys:
                let configMap = buildConfigMap()
                var allKeys: [String] = []
                configMap.dumpAllKeysRecursive(path: ".", result: &allKeys)
                return .succ(io.out(allKeys.joined(separator: "\n")))
            case .configPath:
                return .succ(io.out(configUrl.absoluteURL.path))
        }
    }
}

extension String {
    fileprivate func toKeyPath() -> Result<[String], String> {
        if self == "." { return .success([]) }
        if isEmpty { return .failure("Invalid empty key") }
        if self.contains("..") { return .failure("Invalid key '\(self)'") }
        if self.hasSuffix(".") { return .failure("Invalid key '\(self)'") }
        return .success(self.split(separator: ".", omittingEmptySubsequences: false).map(String.init))
    }
}

@MainActor private func getKey(_ io: CmdIo, args: ConfigCmdArgs, key: String) -> BinaryExitCode {
    guard let keyPath = key.toKeyPath().getOrNil(appendErrorTo: &io.stderr) else { return .fail }
    guard var configMap = buildConfigMap().find(keyPath: keyPath.slice).getOrNil(appendErrorTo: &io.stderr) else { return .fail }
    if args.keys {
        switch configMap {
            case .scalar(let scalar):
                return .fail(io.err("--keys flag cannot be applied to scalar object '\(scalar)'"))
            case .map(let map):
                configMap = .array(map.keys.map { .scalar(.string($0)) })
            case .array(let array):
                configMap = .array((0 ..< array.count).map { .scalar(.int($0)) })
        }
    }
    if args.json {
        return switch JSONEncoder.hyprMacDefault.encodeToString(configMap) {
            case let json?: .succ(io.out(json))
            case nil: .fail(io.err("Can't convert json Data to String"))
        }
    } else {
        switch configMap {
            case .scalar(let scalar):
                return .succ(io.out(scalar.describe))
            case .map:
                let msg = "Complicated objects can be printed only with --json flag. Alternatively, you can try to inspect keys of the object with --keys flag"
                return .fail(io.err(msg))
            case .array(let array):
                let plainArray: Result<[String], String> = array.mapAllOrFailure {
                    switch $0 {
                        case .scalar(let scalar): .success(scalar.describe)
                        default: .failure("Printing array of non-string objects is supported only with --json flag." +
                                "Alternatively, you can try to inspect keys of the object with --keys flag")
                    }
                }
                return switch plainArray {
                    case .success(let array): .succ(io.out(array.sorted().joined(separator: "\n")))
                    case .failure(let error): .fail(io.err(error))
                }
        }
    }
}

extension ConfigMapValue {
    func find(keyPath: StrArrSlice) -> Result<ConfigMapValue, String> {
        if let key = keyPath.first {
            switch self {
                case .scalar(let scalar):
                    return .failure("Can't dereference scalar value '\(scalar.describe)'")
                case .map(let map):
                    return switch map[key] {
                        case let child?: child.find(keyPath: keyPath.slice(1...).orDie())
                        case nil: .failure("No value at key token '\(key)'")
                    }
                case .array(let array):
                    if let key = Int(key) {
                        return switch array.getOrNil(atIndex: key) {
                            case let child?: child.find(keyPath: keyPath.slice(1...).orDie())
                            case nil: .failure("Index out of bounds. Index: \(key), Size: \(array.count)")
                        }
                    } else {
                        return .failure("Can't convert key token '\(key)' to Int")
                    }
            }
        } else {
            return .success(self)
        }
    }

    func dumpAllKeysRecursive(path: String, result: inout [String]) {
        result.append(path)
        switch self {
            case .scalar: break
            case .map(let map):
                for (key, value) in map {
                    let path = path == "." ? key : path + "." + key
                    value.dumpAllKeysRecursive(path: path, result: &result)
                }
            case .array(let array):
                for (index, value) in array.enumerated() {
                    let path = path == "." ? String(index) : path + "." + String(index)
                    value.dumpAllKeysRecursive(path: path, result: &result)
                }
        }
    }
}

extension Shell<any Command> {
    var shellOfCommandsDescription: String { buildDescription { $0.args.description } }
}

@MainActor func buildConfigMap() -> ConfigMapValue {
    let mode = config.modes.mapValues { (mode: Mode) -> ConfigMapValue in
        var keyNotationToScript: [String: ConfigMapValue] = [:]
        for binding in mode.bindings.values {
            keyNotationToScript[binding.descriptionWithKeyNotation] =
                .scalar(.string(binding.commands.shellOfCommandsDescription))
        }
        for binding in mode.mouseBindings.values {
            keyNotationToScript[binding.descriptionWithKeyNotation] =
                .scalar(.string(binding.commands.shellOfCommandsDescription))
        }
        for binding in mode.modifierTapBindings.values {
            keyNotationToScript[binding.descriptionWithKeyNotation] =
                .scalar(.string(binding.commands.shellOfCommandsDescription))
        }
        return .map(["binding": .map(keyNotationToScript)])
    }
    return .map([
        "mode": .map(mode),
        "new-window-placement": .scalar(.string(config.newWindowPlacement.rawValue)),
        "master-ratio-percent": .scalar(.int(config.masterRatioPercent)),
        "master-new-window": .scalar(.string(config.masterNewWindow.rawValue)),
        "master-placement": config.masterPlacement.configMapValue { .string($0.rawValue) },
        "mouse-grab": .map([
            "live-preview": .scalar(.bool(config.mouseGrab.livePreview)),
            // Deprecated alias, kept for the scripts that read it
            "animation-duration-ms": .scalar(.int(config.animations.mouseGrab.durationMs)),
            "ignore-app-ids": .array(config.mouseGrab.ignoreAppIds.map { .scalar(.string($0)) }),
        ]),
        "workspace": .map(config.workspaceRules.mapValues(\.configMapValue)),
        "animations": buildAnimationsConfigMap(config.animations),
        "tab-bar": buildTabBarConfigMap(config.tabBar),
        "borders": buildBordersConfigMap(config.borders),
    ])
}

private func buildTabBarConfigMap(_ tabBar: TabBarConfig) -> ConfigMapValue {
    .map([
        "enabled": .scalar(.bool(tabBar.enabled)),
        "height": .scalar(.int(tabBar.height)),
        "font-size": .scalar(.int(tabBar.fontSize)),
        "show-icons": .scalar(.bool(tabBar.showIcons)),
        "gap": .scalar(.int(tabBar.gap)),
        "background-color": .scalar(.string(tabBar.backgroundColor.description)),
        "active-color": .scalar(.string(tabBar.activeColor.description)),
        "inactive-color": .scalar(.string(tabBar.inactiveColor.description)),
        "text-color": .scalar(.string(tabBar.textColor.description)),
    ])
}

private func buildBordersConfigMap(_ borders: BordersConfig) -> ConfigMapValue {
    func paint(_ paint: BorderPaint?) -> ConfigMapValue {
        guard let paint else { return .scalar(.string("")) }
        let colors = paint.colors.map { ConfigMapValue.scalar(.string($0.hexDescription)) }
        return paint.isGradient ? .array(colors) : colors[0]
    }
    func radius(_ radius: BorderRadius) -> ConfigMapValue {
        switch radius {
            case .auto: .scalar(.string("auto"))
            case .fixed(let value): .scalar(.double(value))
        }
    }
    return .map([
        "enabled": .scalar(.bool(borders.enabled)),
        "width": .scalar(.double(borders.width)),
        "radius": radius(borders.radius),
        "order": .scalar(.string(borders.order.rawValue)),
        "active-color": paint(borders.activeColor),
        "inactive-color": paint(borders.inactiveColor),
        "gradient-angle": .scalar(.int(borders.gradientAngle)),
        "transition-ms": .scalar(.int(borders.transitionMs)),
        "focus-sweep-ms": .scalar(.int(borders.focusSweepMs)),
        "angle-animation-period-ms": .scalar(.int(borders.angleAnimationPeriodMs)),
        "glow-radius": .scalar(.double(borders.glowRadius)),
        "glow-opacity": .scalar(.double(borders.glowOpacity)),
        "glow-color": .scalar(.string(borders.glowColor?.hexDescription ?? "")),
        "focus-pulse-ms": .scalar(.int(borders.focusPulseMs)),
    ])
}

private func buildAnimationsConfigMap(_ animations: AnimationsConfig) -> ConfigMapValue {
    func common(_ animation: AnimationConfig) -> [String: ConfigMapValue] {
        [
            "enabled": .scalar(.bool(animation.enabled)),
            "duration-ms": .scalar(.int(animation.durationMs)),
            "curve": .scalar(.string(animation.curve.name)),
        ]
    }
    return .map([
        "max-windows": .scalar(.int(animations.maxWindows)),
        "bezier": .map(animations.beziers.mapValues { bezier in
            .array([bezier.x1, bezier.y1, bezier.x2, bezier.y2].map { .scalar(.double($0)) })
        }),
        "windows-move": .map(common(animations.windowsMove).merging(["animate-size": .scalar(.bool(animations.windowsMove.animateSize))]) { _, new in new }),
        "mouse-grab": .map(common(animations.mouseGrab)),
        "scratchpad": .map(common(animations.scratchpad).merging(["direction": .scalar(.string(animations.scratchpad.direction.rawValue))]) { _, new in new }),
    ])
}

extension WorkspaceRule {
    /// Only the keys that are set in the config, the same as they are written in the config
    fileprivate var configMapValue: ConfigMapValue {
        var map: [String: ConfigMapValue] = [:]
        map["default-root-container-layout"] = defaultRootContainerLayout.map { .scalar(.string($0.rawValue)) }
        map["default-root-container-orientation"] = defaultRootContainerOrientation.map { .scalar(.string($0.rawValue)) }
        map["enable-normalization-flatten-containers"] = enableNormalizationFlattenContainers.map { .scalar(.bool($0)) }
        map["enable-normalization-opposite-orientation-for-nested-containers"] =
            enableNormalizationOppositeOrientationForNestedContainers.map { .scalar(.bool($0)) }
        map["new-window-placement"] = newWindowPlacement.map { .scalar(.string($0.rawValue)) }
        map["master-new-window"] = masterNewWindow.map { .scalar(.string($0.rawValue)) }
        let inner = nonEmptyMap(["vertical": gaps.inner.vertical, "horizontal": gaps.inner.horizontal])
        let outer = nonEmptyMap(["left": gaps.outer.left, "bottom": gaps.outer.bottom, "top": gaps.outer.top, "right": gaps.outer.right])
        map["gaps"] = nonEmptyMap(["inner": inner, "outer": outer])
        return .map(map)
    }
}

private func nonEmptyMap(_ values: [String: DynamicConfigValue<Int>?]) -> ConfigMapValue? {
    nonEmptyMap(values.mapValues { $0?.configMapValue })
}

private func nonEmptyMap(_ values: [String: ConfigMapValue?]) -> ConfigMapValue? {
    let map = values.compactMapValues { $0 }
    return map.isEmpty ? nil : .map(map)
}

extension DynamicConfigValue {
    /// Mirrors the config syntax: `[{ monitor.main = 1 }, 2]`
    fileprivate func configMapValue(_ scalar: (Value) -> ConfigScalarValue) -> ConfigMapValue {
        switch self {
            case .constant(let value): .scalar(scalar(value))
            case .perMonitor(let values, let defaultValue):
                .array(values.map { .map(["monitor": .map([$0.description.configDescription: .scalar(scalar($0.value))])]) } + [.scalar(scalar(defaultValue))])
        }
    }
}

extension DynamicConfigValue<Int> {
    fileprivate var configMapValue: ConfigMapValue { configMapValue { .int($0) } }
}

extension MonitorDescription {
    fileprivate var configDescription: String {
        switch self {
            case .sequenceNumber(let number): String(number)
            case .main: "main"
            case .secondary: "secondary"
            case .pattern(let regex): regex.origin
        }
    }
}

enum ConfigScalarValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    var describe: String {
        return switch self {
            case .string(let string): string
            case .int(let int): String(int)
            case .double(let double): String(double)
            case .bool(let bool): String(bool)
        }
    }

    func encode(to encoder: Encoder) throws {
        let value: Encodable = switch self {
            case .string(let string): string
            case .int(let int): int
            case .double(let double): double
            case .bool(let bool): bool
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

enum ConfigMapValue: Encodable {
    case scalar(ConfigScalarValue)
    case map([String: ConfigMapValue])
    case array([ConfigMapValue])

    func encode(to encoder: Encoder) throws {
        let value: Encodable = switch self {
            case .scalar(let scalar): scalar
            case .map(let map): map
            case .array(let array): array
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
