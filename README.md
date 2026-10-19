# Astra

Standalone Luau scripts for Astra Vortex.

| Script | File |
| --- | --- |
| Infinite Yield | `scripts/Admin.luau` |
| Unnamed ESP | `scripts/UnnamedEsp.luau` |
| vUNC | `scripts/EnvironmentTest.luau` |
| Dex | `scripts/Explorer.luau` |
| Air Arena script | `scripts/AirArena.luau` |
| Fluent UI library | `scripts/Fluent/Main.luau` |
| Fluent example | `scripts/Fluent/Example.luau` |

Load a script using its raw URL:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Admin.luau"))()
```

Infinite Yield includes `;explorer` / `;dex` and `;esp` commands to load Dex and Unnamed ESP from this repository.

Dex icons and UI compatibility code are embedded in the standalone scripts. No separate assets are required.

Upstream license notices are included in `licenses/`.

Fluent follows the upstream example API with separate `Fluent/Addons/SaveManager.luau` and `Fluent/Addons/InterfaceManager.luau` add-ons. See [Fluent usage and limitations](docs/Fluent.md). The library loads its Drawing fallback and bundled icon module when needed.

`scripts/Fluent/Example.luau` is an original commented showcase covering controls, dialogs, notifications, keybinds, colors, and configurations. Astra also includes the complete example in its local `Scripts/FluentExample.luau` file.
