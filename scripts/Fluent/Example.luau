-- Fluent for Astra: a complete, interactive example.
-- This script demonstrates UI state only; it does not change the game.
-- Run the full file from the internal editor or select it in the Scripts tab.

-- 1. Load the library and its optional configuration add-ons.
-- Keep these URLs on main so new versions can be picked up when you rerun.
local BaseUrl = "https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent/"
local Fluent = loadstring(game:HttpGet(BaseUrl .. "Main.luau"))()
local SaveManager = loadstring(game:HttpGet(BaseUrl .. "Addons/SaveManager.luau"))()
local InterfaceManager = loadstring(game:HttpGet(BaseUrl .. "Addons/InterfaceManager.luau"))()

-- 2. Create one window for this library instance.
-- Size uses pixels; TabWidth reserves space for the navigation on the left.
-- LeftControl minimizes the window until a saved menu bind overrides it.
-- Acrylic world blur and interactive window resizing are not implemented.
local Window = Fluent:CreateWindow({
    Title = "Fluent showcase",
    SubTitle = "Astra",
    TabWidth = 160,
    Size = UDim2.fromOffset(700, 520),
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.LeftControl,
})

-- Tabs can use one of the bundled icon names. Omit Icon for text-only tabs.
-- Their creation order also determines the index used by SelectTab below.
local Tabs = {
    Overview = Window:AddTab({ Title = "Overview", Icon = "home" }),
    Controls = Window:AddTab({ Title = "Controls", Icon = "settings" }),
    Appearance = Window:AddTab({ Title = "Colors", Icon = "eye" }),
    Settings = Window:AddTab({ Title = "Settings", Icon = "shield" }),
}

-- Options is the registry of controls with identifiers, shared with the add-ons.
-- Give every toggle, slider, dropdown, input, color picker, and keybind a unique ID.
-- Titles are display text and can change without breaking saved configurations.
local Options = Fluent.Options
local ResetDemo

-- 3. Build an overview that updates when the demo controls change.
Tabs.Overview:AddParagraph({
    Title = "Build a small interface",
    Content = "Try the controls, choose some colors, then save a profile in Settings.",
})

local Summary = Tabs.Overview:AddParagraph({
    Title = "Current selection",
    Content = "The control values will appear here.",
})
Summary:SetTitle("Current demo settings")

-- Paragraphs expose SetTitle and SetDesc, so status text needs no drawing loop.
-- Some controls invoke their callback during creation; check later options first.
local function RefreshSummary()
    local Enabled = Options.ExampleEnabled and Options.ExampleEnabled.Value or false
    local Intensity = Options.ExampleIntensity and Options.ExampleIntensity.Value or 0
    local Profile = Options.ExampleProfile and Options.ExampleProfile.Value or "Balanced"

    Summary:SetDesc(
        string.format(
            "Demo: %s\nIntensity: %s\nLayout: %s",
            Enabled and "enabled" or "disabled",
            tostring(Intensity),
            tostring(Profile)
        )
    )
end

Tabs.Overview:AddButton({
    Title = "Explore the controls",
    Description = "Open the interactive control gallery.",
    Callback = function()
        Window:SelectTab(2)
    end,
})

-- A button runs its Callback when clicked. It has no persistent option value.
Tabs.Overview:AddButton({
    Title = "Show a notification",
    Description = "Uses the message entered on the Controls tab.",
    Callback = function()
        local Message = Options.ExampleMessage.Value
        Fluent:Notify({
            Title = "Your message",
            Content = Message ~= "" and Message or "Hello from Fluent!",
            SubContent = "Notifications dismiss themselves.",
            Duration = 4,
        })
    end,
})

-- Identical notifications share one card and restart its timer. This button
-- also demonstrates the default lifetime and the global notification limit.
Tabs.Overview:AddButton({
    Title = "Show the same notification twice",
    Callback = function()
        for _ = 1, 2 do
            Fluent:Notify({ Title = "Shared notice", Content = "Only one card should appear." })
        end
    end,
})

-- Dialog callbacks run only after the corresponding button is selected.
-- Keep actions that require confirmation inside the Confirm callback.
Tabs.Overview:AddButton({
    Title = "Reset the demo controls",
    Description = "Shows a confirmation before restoring the example values.",
    Callback = function()
        Window:Dialog({
            Title = "Reset this example?",
            Content = "This changes the demo controls only. Saved profiles are kept.",
            Buttons = {
                {
                    Title = "Reset",
                    Callback = function()
                        ResetDemo()
                    end,
                },
                { Title = "Keep values" },
            },
        })
    end,
})

-- 4. Sections organize rows without creating another tab or scroll container.
local Values = Tabs.Controls:AddSection("Values and selections")

local Enabled = Values:AddToggle("ExampleEnabled", {
    Title = "Enable demo",
    Description = "A switch with a boolean Value.",
    Default = false,
})

-- OnChanged immediately reports the current value, then reports later changes.
-- Use either Callback in the config or OnChanged afterward; both are supported.
Enabled:OnChanged(function(Value)
    print("Example enabled:", Value)
    RefreshSummary()
end)

local Intensity = Values:AddSlider("ExampleIntensity", {
    Title = "Intensity",
    Description = "A numeric value, clamped between Min and Max.",
    Min = 0,
    Max = 10,
    Default = 2.5,
    Rounding = 1,
    Callback = function(Value)
        print("Example intensity:", Value)
        RefreshSummary()
    end,
})

-- Rounding is the number of decimal places, not the slider's step size.
-- SetValue updates the control and invokes its change callbacks.
Intensity:SetValue(3.5)

local Profile = Values:AddDropdown("ExampleProfile", {
    Title = "Layout profile",
    Description = "Choose one value from the popup list.",
    Values = { "Balanced", "Compact", "Detailed" },
    Default = "Balanced",
    Multi = false,
})

-- A single dropdown accepts a default value or a one-based index into Values.
Profile:OnChanged(function(Value)
    print("Example profile:", Value)
    RefreshSummary()
end)

local Details = Values:AddDropdown("ExampleDetails", {
    Title = "Visible details",
    Description = "A dropdown can also keep several selections.",
    Values = { "Status", "Shortcuts", "Hints", "Descriptions" },
    Default = { "Status", "Shortcuts" },
    Multi = true,
})

-- Multi-select Value is a dictionary: selected names map to true.
-- Read entries with Value.Name; iterate the dictionary to collect selections.
Details:OnChanged(function(Value)
    local Names = {}
    for Name, Selected in Value do
        if Selected then
            Names[#Names + 1] = Name
        end
    end
    table.sort(Names)
    print("Example details:", table.concat(Names, ", "))
end)

-- Programmatic multi-select updates use a dictionary or an array of names.
Details:SetValue({ Status = true, Shortcuts = true, Hints = false })

local Optional = Values:AddDropdown("ExampleOptional", {
    Title = "Optional label",
    Description = "AllowNull permits an empty selection.",
    Values = { "Primary", "Secondary", "Extra" },
    AllowNull = true,
})

Values:AddButton({
    Title = "Clear the optional label",
    Callback = function()
        Optional:SetValue(nil)
    end,
})

-- SetValues replaces a dropdown's choices without recreating the whole window.
Values:AddButton({
    Title = "Add a dropdown choice",
    Description = "Updates the optional list while the window is open.",
    Callback = function()
        Optional:SetValues({ "Primary", "Secondary", "Extra", "New label" })
        Optional:SetValue("New label")
    end,
})

local Text = Tabs.Controls:AddSection("Text input")

Text:AddInput("ExampleMessage", {
    Title = "Notification message",
    Default = "Everything is connected.",
    Placeholder = "Write a short message",
    MaxLength = 120,
    Finished = false,
    Callback = function(Value)
        print("Example message:", Value)
    end,
})

-- Finished=false reports edits as they happen. Finished=true reports on Enter.
-- Numeric inputs still return text; convert with tonumber when using the value.
Text:AddInput("ExampleNumber", {
    Title = "Numeric input",
    Description = "Type a number and press Enter to submit it.",
    Default = "25",
    Numeric = true,
    Finished = true,
    MaxLength = 8,
    Callback = function(Value)
        print("Submitted number:", tonumber(Value))
    end,
})

-- 5. Keybinds support Toggle, Hold, and Always modes.
-- Click a keybind to rebind it. Escape clears it; MB1 and MB2 mean mouse buttons.
-- Avoid using the same key as the menu toggle for an unrelated action.
local Keys = Tabs.Controls:AddSection("Shortcuts")
local Shortcut = Keys:AddKeybind("ExampleShortcut", {
    Title = "Demo shortcut",
    Default = "K",
    Mode = "Toggle",
    ChangedCallback = function(Key)
        print("Demo shortcut bound to:", Key)
    end,
})

-- OnClick is for Toggle mode. GetState reads the current active state.
-- OnChanged observes the binding itself, rather than each key press.
Shortcut:OnClick(function()
    print("Demo shortcut active:", Shortcut:GetState())
end)

Shortcut:OnChanged(function(Key)
    print("Current shortcut:", Key)
end)

Keys:AddKeybind("ExampleHold", {
    Title = "Hold demonstration",
    Default = "H",
    Mode = "Hold",
    Callback = function(Down)
        print("Hold demonstration:", Down)
    end,
})

-- Always mode stays active regardless of whether its key is pressed.
-- It is useful when a script wants one consistent GetState() check.
local Always = Keys:AddKeybind("ExampleAlways", {
    Title = "Always active demonstration",
    Default = "None",
    Mode = "Always",
})
Keys:AddButton({
    Title = "Check shortcut states",
    Callback = function()
        Fluent:Notify({
            Title = "Shortcut states",
            Content = string.format(
                "Toggle: %s   Always: %s",
                tostring(Shortcut:GetState()),
                tostring(Always:GetState())
            ),
        })
    end,
})

-- Callbacks are sufficient for this example: no repeating polling task is needed.
-- In a script with an existing update loop, read Options.ExampleHold:GetState().

-- 6. Color controls report Color3 values; transparency is a separate property.
local ColorSummary = Tabs.Appearance:AddParagraph({
    Title = "Color sample",
    Content = "The values below are demo data, separate from the interface theme.",
})

local Accent = Tabs.Appearance:AddColorpicker("ExampleAccent", {
    Title = "Sample accent",
    Description = "Open the popup to adjust red, green, and blue.",
    Default = Color3.fromRGB(96, 205, 255),
})

Accent:OnChanged(function(Color)
    ColorSummary:SetDesc(
        string.format(
            "Red: %d   Green: %d   Blue: %d",
            math.floor(Color.R * 255 + 0.5),
            math.floor(Color.G * 255 + 0.5),
            math.floor(Color.B * 255 + 0.5)
        )
    )
end)

local Glass = Tabs.Appearance:AddColorpicker("ExampleGlass", {
    Title = "Sample translucent color",
    Default = Color3.fromRGB(180, 150, 245),
    Transparency = 0.25,
})

-- Supplying Transparency adds an alpha slider: 0 is opaque and 1 is invisible.
Glass:OnChanged(function(Color)
    print("Sample color:", Color, "Transparency:", Glass.Transparency)
end)

Tabs.Appearance:AddButton({
    Title = "Try another sample color",
    Callback = function()
        Accent:SetValueRGB(Color3.fromRGB(130, 225, 170))
        Glass:SetValueRGB(Color3.fromRGB(150, 180, 255), 0.4)
    end,
})

-- Reset only the demo options. Interface preferences and saved files stay intact.
ResetDemo = function()
    Enabled:SetValue(false)
    Intensity:SetValue(2.5)
    Profile:SetValue("Balanced")
    Details:SetValue({ Status = true, Shortcuts = true })
    Optional:SetValue(nil)
    Options.ExampleMessage:SetValue("Everything is connected.")
    Options.ExampleNumber:SetValue("25")
    Accent:SetValueRGB(Color3.fromRGB(96, 205, 255))
    Glass:SetValueRGB(Color3.fromRGB(180, 150, 245), 0.25)
end

-- 7. Give both add-ons the same library instance before building their controls.
-- InterfaceManager handles theme, transparency, and the window's menu key.
-- SaveManager handles named profiles, their option values, and autoload selection.
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
InterfaceManager:SetFolder("FluentInterface")
SaveManager:SetFolder("FluentExample/Profiles")

-- Keep interface preferences separate from ordinary option profiles.
-- These transient inputs are also excluded; the config manager excludes its own UI.
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "ExampleMessage", "ExampleNumber" })
InterfaceManager:BuildInterfaceSection(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)

-- Files are stored under Workspace/FluentExample, not beside the library script.
-- Build every option before loading, so each saved ID has a matching control.
-- Edits now autosave after a short pause. A selected autoload profile is the
-- autosave target; otherwise the add-on uses its private "autosave" profile.
-- The interface theme and menu bind use the shared FluentInterface folder.
local Autoloaded = SaveManager.AutoSaveLoaded

RefreshSummary()
Window:SelectTab(1)

Fluent:Notify({
    Title = "Fluent showcase",
    Content = Autoloaded and "Your saved profile is ready." or "Ready to explore.",
    SubContent = "Use Controls, Colors, and Settings to try each feature.",
    Duration = 5,
})

-- Click the window's close button to confirm unloading, or call Fluent:Destroy().
-- Unloading removes its controls and input connections. Rerunning starts fresh.
-- OnUnload is useful for stopping a script's own loops or removing drawings.
Fluent:OnUnload(function()
    print("Fluent showcase closed")
end)
