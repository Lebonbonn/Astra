# Fluent for Vortex

The Drawing implementation follows the public API and layout of [dawid's Fluent](https://github.com/dawid-scripts/Fluent). The upstream MIT notice is in `AstraGithub/licenses/FluentLicense.txt`.

```lua
local Fluent = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent.luau"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/FluentSaveManager.luau"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/FluentInterfaceManager.luau"))()

local Window = Fluent:CreateWindow({
    Title = "My script",
    SubTitle = "",
    TabWidth = 160,
    Size = UDim2.fromOffset(680, 500),
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.LeftControl
})
local Main = Window:AddTab({Title = "General", Icon = "home"})
local Settings = Window:AddTab({Title = "Settings", Icon = "settings"})
Main:AddToggle("Example", {Title = "Enabled", Default = false}):OnChanged(function(Value)
    print(Value)
end)
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:SetFolder("MyScript")
InterfaceManager:SetFolder("MyScript")
SaveManager:IgnoreThemeSettings()
InterfaceManager:BuildInterfaceSection(Settings)
SaveManager:BuildConfigSection(Settings)
Window:SelectTab(1)
```

`FluentExample.luau` is the upstream example with only its three library URLs changed. `Fluent.SaveManager` and `Fluent.InterfaceManager` remain available as lazy conveniences for existing scripts.

## Controls

Tabs and sections support `AddParagraph`, `AddButton`, `AddToggle`, `AddSlider`, `AddDropdown`, `AddInput`, `AddColorpicker`, and `AddKeybind`. Options are indexed by identifier in `Fluent.Options` and expose `Value`, `Type`, `OnChanged`, `SetValue`, `SetTitle`, `SetDesc`, and `Destroy`, where applicable. `OnChanged` immediately reports the current value, as upstream does.

- Toggles use a switch and accept clicks on the entire row.
- Sliders clamp and round values using `Min`, `Max`, and `Rounding`. Clicking and dragging the rail both work.
- Dropdowns open a scrolling list. `Multi`, numeric/string/table defaults, `AllowNull`, and `SetValues` are supported. Multi-select values are dictionaries of selected names.
- Inputs support `Numeric`, `Finished`, `MaxLength`, and `Placeholder`. With `Finished=true`, the callback runs on Enter; otherwise it runs as text changes.
- Color pickers expose `SetValueRGB(Color, Transparency)`. Their popup uses RGB sliders and an optional transparency slider.
- Keybinds support `Always`, `Hold`, `Toggle`, `MB1`, `MB2`, rebinding, `GetState`, `OnClick`, and `ChangedCallback`. Textbox input does not trigger shortcuts.

Windows have a draggable title bar, a minimize key/button, and a close confirmation dialog. `Window:Dialog` only invokes a callback after its button is clicked. `Fluent:Notify` displays a dismissible notification; `Duration` schedules expiry. At most four notifications are displayed by default (`Fluent.MaxNotifications`); the stack reflows when one is dismissed. `Fluent:Destroy` disconnects input handlers and removes its controls, notifications, and drawing objects.

Themes: Dark, Darker, Light, Aqua, Amethyst, and Rose. Included icon names: home, crosshair, swords, users, person-standing, eye, settings, shield, flame, triangle, circle-user, minus, x, chevron-right, and chevron-down.

## Files and compatibility

Configs live under `Workspace/<Folder>/settings/<Name>.json`; interface settings use `Workspace/<Folder>/options.json`. Config names accept letters, digits, spaces, underscores, and hyphens. Configs contain typed data and are parsed as JSON. `SetAutoloadConfig`, `LoadAutoloadConfig`, `RefreshConfigList`, `SetIgnoreIndexes`, and `IgnoreThemeSettings` are supported.

Fluent pins its dependency assets to a matching repository revision. The example also pins its three library URLs so cached moving URLs cannot mix versions. The library uses a native `Drawing.newcontext()` with `UiVersion >= 7` when available. Otherwise it fetches `FluentDrawing.luau`, which implements the controls over standard Drawing and input events. Icons come from `FluentIcons.luau`. Rounded backgrounds and clipping depend on the Drawing implementation; unsupported rounding is skipped. Filesystem and JSON support are needed for persistent configs.

The title bar, page heading, restrained row backgrounds, tab selection marker, icons, switches, and rails follow Fluent's layout. World acrylic blur, spring animations, interactive resizing/maximizing, arbitrary Roblox asset icons, and the upstream HSV color canvas are not implemented. `Acrylic` is accepted for compatibility; `SupportsAcrylic` and `UseAcrylic` are false.

## Shared Drawing UI version 7

Controls add `MouseEnter`, `MouseLeave`, `TextXAlignment` (Left/Center/Right), `TextTransparency`, `BorderSizePixel`, `BorderColor3`, `BorderTransparency`, `CornerRadius`, `AccentColor3`, `KnobColor3`, and `ScrollBarThickness`. `ToggleStyle="Switch"` selects the switch appearance; `SliderStyle="Fluent"` selects the rail and thumb. A draggable control can set `DragTarget` to its root window. Scrolling frames show a draggable scrollbar when their canvas exceeds their height.

Properties keep existing defaults for older scripts. Destroyed controls are reclaimed before enforcing the 512-control limit. Square/Panel rounding uses the renderer's existing `Rounding` drawing property.

## Validation

`python Tools/TestFluent.py --luau <path-to-luau.exe>` runs a standalone fixture with mocked Drawing, input, and filesystem services. It checks controls, pointer clicks, callbacks, key modes, dialogs, config round trips, and the adapted upstream example without executing gameplay code. `Tools/BuildFluentIcons.py` regenerates the bundled icons using Pillow. Normal script generation does not overwrite the hosted Fluent sources.
