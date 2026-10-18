# Astra

Standalone Luau scripts for Astra Vortex.

| Script | File |
| --- | --- |
| Infinite Yield | `scripts/Admin.luau` |
| Unnamed ESP | `scripts/UnnamedEsp.luau` |
| vUNC | `scripts/EnvironmentTest.luau` |
| Dex | `scripts/Explorer.luau` |

Load a script using its raw URL:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Admin.luau"))()
```

Infinite Yield includes `;explorer` / `;dex` and `;esp` commands to load Dex and Unnamed ESP from this repository.

Dex icons and UI compatibility code are embedded in the standalone scripts. No separate assets are required.

Upstream license notices are included in `licenses/`.
