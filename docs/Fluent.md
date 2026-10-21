# Fluent for Vortex

The Drawing implementation follows the public API and layout of [dawid's Fluent](https://github.com/dawid-scripts/Fluent). The upstream MIT notice is in `AstraGithub/licenses/FluentLicense.txt`.

```text
scripts/Fluent/
  Main.luau
  Drawing.luau
  Icons.luau
  Example.luau
  Addons/
    SaveManager.luau
    InterfaceManager.luau
```

Runnable application scripts remain at `scripts/`; Fluent's support files are grouped here.

```lua
local Fluent = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent/Main.luau"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent/Addons/SaveManager.luau"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent/Addons/InterfaceManager.luau"))()

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
InterfaceManager:SetFolder("FluentInterface")
SaveManager:IgnoreThemeSettings()
InterfaceManager:BuildInterfaceSection(Settings)
SaveManager:BuildConfigSection(Settings)
Window:SelectTab(1)
```

`Fluent/Example.luau` is an original commented showcase with Overview, Controls, Colors, and Settings tabs. The complete example is also installed as `Scripts/FluentExample.luau` for the internal script hub; that file contains the full example body and imports only the library and add-ons. It demonstrates every implemented control type, sections, tab selection, updates to text and dropdown choices, callbacks, all three keybind modes, notifications, dialogs, themes, colors, profiles, autosave, and shared interface preferences. `Fluent.SaveManager` and `Fluent.InterfaceManager` remain available as lazy conveniences for existing scripts.

## Controls

Tabs and sections support `AddParagraph`, `AddButton`, `AddToggle`, `AddSlider`, `AddDropdown`, `AddInput`, `AddColorpicker`, and `AddKeybind`. Options are indexed by identifier in `Fluent.Options` and expose `Value`, `Type`, `OnChanged`, `SetValue`, `SetTitle`, `SetDesc`, and `Destroy`, where applicable. `OnChanged` immediately reports the current value, as upstream does.

- Toggles use a switch and accept clicks on the entire row.
- Sliders clamp and round values using `Min`, `Max`, and `Rounding`. Clicking and dragging the rail both work.
- Dropdowns open a scrolling list. `Multi`, numeric/string/table defaults, `AllowNull`, and `SetValues` are supported. Multi-select values are dictionaries of selected names.
- Inputs support `Numeric`, `Finished`, `MaxLength`, and `Placeholder`. With `Finished=true`, the callback runs on Enter; otherwise it runs as text changes.
- Color pickers expose `SetValueRGB(Color, Transparency)`. Their popup uses RGB sliders and an optional transparency slider.
- Keybinds support `Always`, `Hold`, `Toggle`, `MB1`, `MB2`, rebinding, `GetState`, `OnClick`, and `ChangedCallback`. Textbox input does not trigger shortcuts.

Windows have a draggable title bar, a minimize key/button, and a close confirmation dialog. `Window:Dialog` only invokes a callback after its button is clicked. `Fluent:Notify` displays a dismissible notification that expires after four seconds by default (`Fluent.NotificationDuration`). `Duration` overrides the lifetime, clamped to 0.5–30 seconds. At most three notifications are displayed by default (`Fluent.MaxNotifications`). Identical title/content messages reuse one notification and refresh its timer. The stack reflows when an entry expires or is dismissed. `Fluent:OnUnload(callback)` registers cleanup for a script's own loops and drawings. `Fluent:Destroy` flushes pending autosaves, invokes cleanup callbacks, disconnects input handlers, and removes its controls and notifications.

Themes: Dark, Darker, Light, Aqua, Amethyst, and Rose. Included icon names: home, crosshair, swords, users, person-standing, eye, settings, shield, flame, triangle, circle-user, minus, x, chevron-right, and chevron-down.

## Files and compatibility

Configs live under `Workspace/<ScriptFolder>/settings/<Name>.json`; interface settings use `Workspace/FluentInterface/options.json` when scripts use the shared folder shown above. Theme, transparency, and menu key therefore carry across Fluent scripts. Config names accept letters, digits, spaces, underscores, and hyphens. Configs contain typed data and are parsed as JSON.

`BuildConfigSection` enables autosave by default. Once all options are created, it loads the selected autoload profile or the private `autosave` profile, then saves edits after 0.8 seconds of inactivity. Closing the window flushes pending changes. Each script should use its own SaveManager folder and the shared `FluentInterface` folder for InterfaceManager. Set `SaveManager.AutoSave = false` before building the config section to disable this behavior. `SetAutoloadConfig`, `LoadAutoloadConfig`, `RefreshConfigList`, `SetIgnoreIndexes`, `IgnoreThemeSettings`, and `FlushAutoSave` are supported.

Fluent and its example load files from the repository’s `main` branch; their URLs contain no commit IDs. The library uses a native `Drawing.newcontext()` with `UiVersion >= 9` when available. Otherwise it fetches `Fluent/Drawing.luau`, which implements the controls over standard Drawing and input events. Icons come from `Fluent/Icons.luau`. Rounded backgrounds and clipping depend on the Drawing implementation; unsupported rounding is skipped. Filesystem and JSON support are needed for persistent configs.

The title bar, page heading, row backgrounds, tab selection marker, icons, switches, and rails follow Fluent's layout. Drag the bottom-right grip to resize, or call `Window:Resize(width, height)`. Controls and tab pages reflow with the window.

`Acrylic` and `ToggleAcrylic(enabled)` enable real backdrop blur when `Drawing.supportsblur()` is true. Native Vulkan captures the scene into reusable GPU images and creates a filtered pyramid before drawing the UI. Only the area behind the rounded window is composited, beneath the theme tint. Multiple panels share the same captured frame. No screenshots are transferred to the CPU, and no capture runs while blur objects are hidden.

`SupportsAcrylic` reports availability for the renderer active when the UI context is created. InterfaceManager shows the Acrylic toggle only when supported and saves the preference. Without blur, the panel stays opaque or 8% transparent. With blur, its tint is 80% opaque, or 65% with Transparency enabled. DirectX12, the separate Overlay backend, and Metal currently have no backdrop pass. Spring animations, maximizing, arbitrary Roblox asset icons, and the upstream HSV color canvas remain unavailable.

Native blur is off by default. Enable **Acrylic / backdrop blur** in the internal Settings menu
and restart if the current swapchain does not support capture, then reload Fluent. Turning the
global setting off stops captures immediately. The Vulkan pass filters a quarter-resolution image
down and back up to soften pixelation while using about 75% fewer working-image pixels than the
original implementation. It still costs GPU time; leave it disabled for the lowest overhead.

## Shared Drawing UI version 9

Controls add `MouseEnter`, `MouseLeave`, `TextXAlignment` (Left/Center/Right), `TextTransparency`, `BorderSizePixel`, `BorderColor3`, `BorderTransparency`, `CornerRadius`, `AccentColor3`, `KnobColor3`, and `ScrollBarThickness`. `ToggleStyle="Switch"` selects the switch appearance; `SliderStyle="Fluent"` selects the rail and thumb. A draggable control can set `DragTarget` to its root window. Scrolling frames show a draggable scrollbar when their canvas exceeds their height.

Frames can set `BackdropBlur = true` to place a rounded native blur beneath their background.
`Library.SupportsBackdropBlur` reports whether that UI context can use it. Use a translucent
`BackgroundTransparency` to reveal the blurred scene through the tint.

Properties keep existing defaults for older scripts. Destroyed controls are reclaimed before enforcing the 512-control limit. Square/Panel rounding uses the renderer's existing `Rounding` drawing property.

Idle frames reuse the previous hit-test result while pointer position, control layout, activity, and window focus are unchanged. Layout, visibility, parenting, z-order, and active-state changes invalidate that result. Unchanged native pointer positions avoid another Vector2 allocation. Fluent also uses a bounded 256-entry text-width cache to avoid repeating native measurements for unchanged labels and descriptions.

## Validation

`python Tools/TestFluent.py --luau <path-to-luau.exe>` runs a standalone fixture with mocked Drawing, input, and filesystem services. It checks controls, pointer clicks, callbacks, key modes, dialogs, config round trips, and the complete showcase example without executing gameplay code. `Tools/BuildFluentIcons.py` regenerates the bundled icons using Pillow. Normal script generation does not overwrite the hosted Fluent sources.
