# HyprMac

<img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="30%" align="right">

HyprMac is an i3-like tiling window manager for macOS with Hyprland-like features:
a tree of containers, emulated workspaces, plain text config, CLI first, and no need to disable SIP.

Docs:
- [Guide](./docs/guide.adoc)
- [Commands](./docs/commands.adoc)
- [Goodies](./docs/goodies.adoc)

## Hyprland-like features

All of them are opt-in: without configuration, HyprMac behaves like a classic i3-like tiling window manager.

- **Layouts**
  - [Dwindle](./docs/guide.adoc#new-window-placement) new window placement
  - [Master](./docs/guide.adoc#master-layout) and [center master](./docs/guide.adoc#center-master) layouts
  - [Pseudotile](./docs/guide.adoc#pseudotiling)
  - [Smart gaps](./docs/guide.adoc#smart-gaps)
  - [Per-workspace rules](./docs/guide.adoc#workspace-rules): layout, orientation, gaps, normalization and placement
  - [`preselect`](./docs/guide.adoc#preselect), [`toggle-split`](./docs/commands.adoc#toggle-split) and [`swap-split`](./docs/commands.adoc#swap-split)
- **Windows**
  - [Scratchpad](./docs/commands.adoc#scratchpad-toggle)
  - [`floating-frame`](./docs/commands.adoc#floating-frame) to place floating windows
  - [Pinned windows](./docs/guide.adoc#pinned-windows)
- **Mouse and keyboard**
  - [Mouse bindings](./docs/guide.adoc#mouse-bindings) to grab windows, with [live preview](./docs/guide.adoc#mouse-grab-live-preview)
  - [Modifier-only bindings](./docs/guide.adoc#modifier-only-bindings) (tap `cmd` alone)
  - [Release and repeat bindings](./docs/guide.adoc#binding-triggers)
- **Visuals**
  - [Animations](./docs/guide.adoc#animations) with bezier curves
  - [Native borders](./docs/guide.adoc#borders) with glow
  - [Tab bar](./docs/guide.adoc#tab-bar) for accordion containers
- **Scripting**
  - [`on-window-title-changed`](./docs/guide.adoc#on-window-title-changed-callback) rules
  - [`tree`](./docs/commands.adoc#tree) command (text and JSON)
  - More [`subscribe`](./docs/commands.adoc#subscribe) events: `window-moved`, `window-closed`, `window-title-changed`, `monitors-changed`

## Installation

Install via [Homebrew](https://brew.sh/):

```
brew tap novaisvictor/tap
brew trust novaisvictor/tap
brew install --cask hyprmac
```

The cask installs `HyprMac.app`, the `hyprmac` CLI, the man pages and the bash, fish and zsh completions.

> [!NOTE]
> HyprMac releases are ad-hoc signed and not [notarized](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
>
> - If macOS refuses to open the app, remove the quarantine attribute:
>   `xattr -dr com.apple.quarantine /Applications/HyprMac.app`
> - macOS asks for the Accessibility permission again after every update, because the ad-hoc signature changes with each release.

HyprMac runs on macOS 13+ on Apple Silicon.

## Configuration

HyprMac looks for the config in:

1. `~/.hyprmac.toml`
2. `${XDG_CONFIG_HOME}/hyprmac/hyprmac.toml` (`XDG_CONFIG_HOME` defaults to `~/.config`)

Without a config, HyprMac uses the [default config](./docs/config-examples/default-config.toml).
Copy it as a starting point:

```
cp /Applications/HyprMac.app/Contents/Resources/default-config.toml ~/.hyprmac.toml
```

## Development

See [dev-docs/development.md](./dev-docs/development.md).

## License

HyprMac is licensed under MIT. See [LICENSE.txt](./LICENSE.txt) and the third-party notices in [legal/](./legal).

Based on [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko, MIT.
