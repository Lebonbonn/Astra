local RGB, V2 = Color3.fromRGB, Vector2.new
local AssetBase = "https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent/"
local Environment = type(getgenv) == "function" and getgenv() or _G

if not UDim2 then
    Environment.UDim2 = {
        fromOffset = function(X, Y)
            return { X = { Scale = 0, Offset = X }, Y = { Scale = 0, Offset = Y } }
        end,
        new = function(XScale, XOffset, YScale, YOffset)
            return {
                X = { Scale = XScale, Offset = XOffset },
                Y = {
                    Scale = YScale,
                    Offset = YOffset,
                },
            }
        end,
    }
end

local Previous = Environment.AstraFluent

if Previous and Previous.AstraVersion and type(Previous.Destroy) == "function" then
    Previous:Destroy()
end

local Ui

if Drawing and type(Drawing.newcontext) == "function" then
    local Ok, Result = pcall(Drawing.newcontext)

    if Ok and Result and (Result.UiVersion or 0) >= 9 then
        Ui = Result
    end
end

if not Ui then
    Ui = assert(loadstring(game:HttpGet(AssetBase .. "Drawing.luau")))()(Drawing)
    assert((Ui.UiVersion or 0) >= 9, "Fluent requires Drawing UI version 9")
end

local Font = Drawing.Fonts and (Drawing.Fonts.SourceSans or Drawing.Fonts.Plex or Drawing.Fonts.UI)
    or 0

local Icons = {}
local IconOk, IconData = pcall(function()
    return assert(loadstring(game:HttpGet(AssetBase .. "Icons.luau")))()
end)

if IconOk and type(IconData) == "table" then
    Icons = IconData
end

local Fluent = {
    Version = "1.1.5",
    AstraVersion = 4,
    Options = {},
    Unloaded = false,
    Theme = "Dark",
    Themes = { "Dark", "Darker", "Light", "Aqua", "Amethyst", "Rose" },
    Connections = {},
    Keybinds = {},
    Notifications = {},
    MaxNotifications = 3,
    NotificationDuration = 4,
    Ui = Ui,
    SupportsAcrylic = Ui.SupportsBackdropBlur == true,
    UseAcrylic = false,
}
Environment.AstraFluent = Fluent

local Window, Popup
local ThemeBindings = {}
local Palette

local function Colors(Name)
    local Light = Name == "Light"
    local Accent = Name == "Amethyst" and RGB(175, 141, 255)
        or Name == "Rose" and RGB(244, 137, 169)
        or RGB(96, 205, 255)

    return {
        Background = Light and RGB(237, 240, 244)
            or Name == "Darker" and RGB(15, 17, 21)
            or RGB(24, 30, 38),
        Surface = Light and RGB(248, 249, 251) or RGB(35, 42, 51),
        Selected = Light and RGB(219, 225, 233) or RGB(45, 53, 63),
        Hover = Light and RGB(227, 232, 239) or RGB(43, 51, 61),
        Raised = Light and RGB(239, 242, 247) or RGB(31, 37, 46),
        Border = Light and RGB(202, 208, 219) or RGB(53, 62, 74),
        Text = Light and RGB(28, 34, 43) or RGB(239, 242, 247),
        Muted = Light and RGB(94, 104, 119) or RGB(165, 175, 189),
        Accent = Accent,
    }
end

Palette = Colors("Dark")

local function Safe(Callback, ...)
    if type(Callback) ~= "function" then
        return
    end

    local Ok, Error = pcall(Callback, ...)

    if not Ok then
        warn("Fluent: " .. tostring(Error))
    end
end

function Fluent:SafeCallback(Callback, ...)
    Safe(Callback, ...)
end

local function Connect(Event, Callback, Persistent)
    local Connection = Event:Connect(Callback)

    if Persistent then
        Fluent.Connections[#Fluent.Connections + 1] = Connection
    end

    return Connection
end

local function Create(Kind, Parent, X, Y, W, H, Properties, Tags)
    local Values = {
        Parent = Parent,
        Position = V2(X, Y),
        Size = V2(W, H),
        ZIndex = 1,
        CornerRadius = 4,
        Text = "",
        TextSize = 14,
        Font = Font,
        BackgroundTransparency = 1,
        TextColor3 = Palette.Text,
        Padding = 0,
    }

    for Key, Value in Properties or {} do
        Values[Key] = Value
    end

    for Key, Value in Tags or {} do
        Values[Key] = Palette[Value]
    end

    local Item = Ui.create(Kind, Values)

    if Tags then
        if #ThemeBindings > 1024 then
            for Index = #ThemeBindings, 1, -1 do
                if ThemeBindings[Index][1].Destroyed then
                    table.remove(ThemeBindings, Index)
                end
            end
        end

        ThemeBindings[#ThemeBindings + 1] = { Item, Tags }
    end

    return Item
end

local function Label(Parent, Text, X, Y, W, H, Size, Color)
    return Create(
        "TextLabel",
        Parent,
        X,
        Y,
        W,
        H,
        { Text = tostring(Text or ""), TextSize = Size or 14, Active = false },
        { TextColor3 = Color or "Text" }
    )
end

local Measure = Drawing.new("Text")

Measure.Visible, Measure.Font = false, Font

local WidthCache, WidthKeys, WidthSlot = {}, {}, 1

local function TextWidth(Text, Size)
    local Key = tostring(Size) .. "\0" .. Text
    local Cached = WidthCache[Key]

    if Cached ~= nil then
        return Cached
    end

    Measure.Text, Measure.Size = Text, Size

    local Width = Measure.TextBounds.X

    if #Text <= 512 then
        if WidthKeys[WidthSlot] then
            WidthCache[WidthKeys[WidthSlot]] = nil
        end

        WidthKeys[WidthSlot] = Key
        WidthSlot = WidthSlot % 256 + 1
        WidthCache[Key] = Width
    end

    return Width
end

local function Wrap(Text, Width, Size)
    local Lines = {}

    for Line in (tostring(Text or "") .. "\n"):gmatch("(.-)\n") do
        local Current = ""

        for Word in Line:gmatch("%S+") do
            if Current ~= "" and TextWidth(Current .. " " .. Word, Size) > Width then
                Lines[#Lines + 1], Current = Current, Word
            else
                Current = Current == "" and Word or Current .. " " .. Word
            end
        end

        Lines[#Lines + 1] = Current
    end

    return table.concat(Lines, "\n"), #Lines
end

local function Icon(Parent, Name, X, Y, Size)
    if not Icons[Name] then
        return nil
    end

    return Create(
        "ImageLabel",
        Parent,
        X,
        Y,
        Size or 18,
        Size or 18,
        { Image = Icons[Name], Active = false, BackgroundTransparency = 0 }
    )
end

function Fluent:GetIcon(Name)
    return Icons[Name]
end

local function Click(Parent, Text, X, Y, W, H, Callback)
    local Item = Create(
        "TextButton",
        Parent,
        X,
        Y,
        W,
        H,
        { Text = Text, Padding = 10, BackgroundTransparency = 0, TextXAlignment = "Center" },
        { BackgroundColor3 = "Raised", HoverColor3 = "Hover", TextColor3 = "Text" }
    )
    Connect(Item.MouseButton1Click, function()
        Safe(Callback)
    end)

    return Item
end

local function ClosePopup()
    if Popup and not Popup.Destroyed then
        Popup:Destroy()
    end

    Popup = nil
end

local function Relative(Item)
    local X, Y = Item.Position.X, Item.Position.Y
    local Parent = Item.Parent

    while Parent and Parent ~= Window.Root do
        X, Y = X + Parent.Position.X, Y + Parent.Position.Y - (Parent.ScrollOffset or 0)
        Parent = Parent.Parent
    end

    return X, Y
end

local function NewPopup(Control, Width, Height)
    ClosePopup()

    local X, Y = Relative(Control)

    Y += Control.Size.Y + 4
    X = math.clamp(X, 4, math.max(4, Window.Width - Width - 4))

    if Y + Height > Window.Height - 4 then
        Y = math.max(46, Y - Height - Control.Size.Y - 8)
    end

    local Blocker = Create(
        "TextButton",
        Window.Root,
        0,
        42,
        Window.Width,
        Window.Height - 42,
        { ZIndex = 2000 }
    )
    Connect(Blocker.MouseButton1Click, ClosePopup)
    Popup = Blocker

    local Panel = Create("ScrollingFrame", Blocker, X, Y - 42, Width, Height, {
        BackgroundTransparency = 0,
        BorderSizePixel = 1,
        ClipsDescendants = true,
        CanvasSize = Height,
        Padding = 6,
    }, { BackgroundColor3 = "Raised", BorderColor3 = "Border", TextColor3 = "Muted" })

    return Panel
end

local function Emit(Item)
    Safe(Item.Callback, Item.Value)
    Safe(Item.Changed, Item.Value)

    for _, Observer in Item.Observers or {} do
        Safe(Observer, Item.Value)
    end
end

local TabMethods = {}

local function Reflow(Tab)
    if Tab.DeferReflow then
        return
    end

    local Y = 0

    for _, Row in Tab.Rows do
        if not Row.Frame.Destroyed then
            Row.Frame.Position = V2(0, Y)
            Row.Frame.Size = V2(Tab.Width - 7, Row.Height)
            Y += Row.Height + 5
        end
    end

    Tab.Page.CanvasSize = Y + 8
    Tab.Page.ScrollOffset = math.min(Tab.Page.ScrollOffset, math.max(0, Y - Tab.Page.Size.Y))
end

local function Element(Tab, Config, Reserved, Plain)
    local Item = { Tab = Tab, Config = Config, Reserved = Reserved or 0, Height = 42 }

    Item.Frame = Create(Plain and "Frame" or "TextButton", Tab.Page, 0, 0, Tab.Width - 7, 42, {
        BackgroundTransparency = Plain and 1 or 0,
        BorderSizePixel = Plain and 0 or 1,
        BorderTransparency = 0.65,
    }, { BackgroundColor3 = "Surface", HoverColor3 = "Hover", BorderColor3 = "Border" })
    Item.TitleLabel =
        Label(Item.Frame, Config.Title, 11, 12, Tab.Width - 32 - Item.Reserved, 18, 14)
    Item.DescLabel = Label(Item.Frame, "", 11, 32, Tab.Width - 32 - Item.Reserved, 14, 12, "Muted")
    Item.DescLabel.Multiline = true

    function Item:UpdateLayout()
        local Width = self.Tab.Width - 30 - self.Reserved
        local Description = tostring(self.Config.Description or "")
        local Text, Lines = Wrap(Description, math.max(30, Width), 12)

        self.TitleLabel.Text = tostring(self.Config.Title or "")
        self.TitleLabel.Size = V2(Width, 18)
        self.DescLabel.Visible = Description ~= ""
        self.DescLabel.Text = Text
        self.DescLabel.Size = V2(Width, Lines * 14 + 3)
        self.Height = Description ~= "" and 33 + Lines * 14 + 10 or 42
        self.TitleLabel.Position = V2(11, Description ~= "" and 10 or 12)
        self.DescLabel.Position = V2(11, 29)

        if self.PositionControl then
            self:PositionControl()
        end

        Reflow(self.Tab)
    end

    function Item:SetTitle(Title)
        self.Config.Title = Title
        self:UpdateLayout()

        return self
    end

    function Item:SetDesc(Description)
        self.Config.Description = Description
        self:UpdateLayout()

        return self
    end

    function Item:Destroy()
        self.Frame:Destroy()

        if self.Id then
            Fluent.Options[self.Id] = nil
        end

        Reflow(self.Tab)
    end

    Tab.Rows[#Tab.Rows + 1] = Item
    Item:UpdateLayout()

    return Item
end

local function Option(Tab, Type, Id, Config, Reserved)
    assert(type(Id) == "string", "Option identifier must be a string")

    if Fluent.Options[Id] then
        Fluent.Options[Id]:Destroy()
    end

    local Item = Element(Tab, Config, Reserved)

    Item.Type, Item.Id, Item.Value, Item.Callback = Type, Id, Config.Default, Config.Callback

    function Item:OnChanged(Callback)
        self.Changed = Callback
        Safe(Callback, self.Value)

        return self
    end

    function Item:Observe(Callback)
        self.Observers = self.Observers or {}
        self.Observers[#self.Observers + 1] = Callback

        return self
    end

    Fluent.Options[Id] = Item

    return Item
end

function TabMethods:AddParagraph(Config)
    local Item = Element(self, { Title = Config.Title, Description = Config.Content }, 0)

    function Item:SetDesc(Text)
        self.Config.Description = Text
        self:UpdateLayout()

        return self
    end

    return Item
end

function TabMethods:AddButton(Config)
    local Item = Element(self, Config, 30)

    Item.Arrow =
        Icon(Item.Frame, "chevron-right", self.Width - 37, math.floor((Item.Height - 18) / 2), 18)

    function Item:PositionControl()
        if self.Arrow then
            self.Arrow.Position = V2(self.Tab.Width - 37, math.floor((self.Height - 18) / 2))
        end
    end

    Connect(Item.Frame.MouseButton1Click, function()
        Safe(Config.Callback)
    end)

    return Item
end

function TabMethods:AddSection(Title)
    local Item = Element(self, { Title = Title }, 0, true)

    Item.Section = true
    Item.Height, Item.TitleLabel.TextSize = 30, 18
    Item.TitleLabel.Position = V2(0, 7)
    Reflow(self)

    return setmetatable({ Tab = self }, {
        __index = function(Section, Key)
            if type(TabMethods[Key]) == "function" then
                return function(_, ...)
                    return TabMethods[Key](Section.Tab, ...)
                end
            end
        end,
    })
end

function TabMethods:AddToggle(Id, Config)
    local Item = Option(self, "Toggle", Id, Config, 54)

    Item.Control = Create(
        "Checkbox",
        Item.Frame,
        self.Width - 57,
        10,
        40,
        22,
        { ToggleStyle = "Switch" },
        { AccentColor3 = "Accent", TextColor3 = "Muted", KnobColor3 = "Background" }
    )

    function Item:PositionControl()
        self.Control.Position = V2(self.Tab.Width - 57, (self.Height - 22) / 2)
    end

    function Item:SetValue(Value)
        if self.Setting then
            return
        end

        self.Setting = true
        self.Value = not not Value
        self.Control.Value = self.Value
        self.Setting = false
        Emit(self)
    end

    Connect(Item.Frame.MouseButton1Click, function()
        Item:SetValue(not Item.Value)
    end)

    Connect(Item.Control:GetPropertyChangedSignal("Value"), function()
        if not Item.Setting then
            Item:SetValue(Item.Control.Value)
        end
    end)

    Item:PositionControl()
    Item:SetValue(Config.Default or false)

    return Item
end

function TabMethods:AddSlider(Id, Config)
    assert(
        type(Config.Min) == "number" and type(Config.Max) == "number" and Config.Max > Config.Min,
        "Slider needs Min < Max"
    )

    local Item = Option(self, "Slider", Id, Config, 204)

    Item.Min, Item.Max, Item.Rounding = Config.Min, Config.Max, Config.Rounding or 0
    Item.Control = Create("Slider", Item.Frame, self.Width - 169, 9, 150, 24, {
        SliderStyle = "Fluent",
        Min = Item.Min,
        Max = Item.Max,
        Value = tonumber(Config.Default) or Item.Min,
    }, { AccentColor3 = "Accent", TextColor3 = "Muted" })
    Item.Display = Label(Item.Frame, "", self.Width - 222, 12, 47, 18, 12, "Muted")
    Item.Display.TextXAlignment = "Right"

    function Item:PositionControl()
        self.Control.Position = V2(self.Tab.Width - 169, (self.Height - 24) / 2)
        self.Display.Position = V2(self.Tab.Width - 222, (self.Height - 18) / 2)
    end

    function Item:SetValue(Value)
        if self.Setting then
            return
        end

        Value = tonumber(Value)

        if not Value or Value ~= Value then
            return
        end

        local Power = 10 ^ self.Rounding

        self.Value = math.floor(math.clamp(Value, self.Min, self.Max) * Power + 0.5) / Power
        self.Setting = true
        self.Control.Value, self.Display.Text = self.Value, tostring(self.Value)
        self.Setting = false
        Emit(self)
    end

    Connect(Item.Control:GetPropertyChangedSignal("Value"), function()
        if not Item.Setting then
            Item:SetValue(Item.Control.Value)
        end
    end)

    Item:PositionControl()
    Item:SetValue(Config.Default or Item.Min)

    return Item
end

function TabMethods:AddInput(Id, Config)
    local Item = Option(self, "Input", Id, Config, 175)

    Item.Numeric, Item.Finished = Config.Numeric == true, Config.Finished == true
    Item.Control = Create("TextBox", Item.Frame, self.Width - 179, 7, 160, 29, {
        Text = tostring(Config.Default or ""),
        PlaceholderText = Config.Placeholder or "",
        Padding = 8,
        BackgroundTransparency = 0,
        BorderSizePixel = 1,
        MaxLength = Config.MaxLength or 4096,
    }, {
        BackgroundColor3 = "Raised",
        BorderColor3 = "Border",
        TextColor3 = "Text",
        HoverColor3 = "Hover",
    })

    function Item:PositionControl()
        self.Control.Position = V2(self.Tab.Width - 179, (self.Height - 29) / 2)
    end

    function Item:SetValue(Value)
        if self.Setting then
            return
        end

        Value = tostring(Value or ""):sub(1, self.Config.MaxLength or 4096)

        if self.Numeric and Value ~= "" and not tonumber(Value) then
            Value = self.Value or ""
        end

        self.Setting = true
        self.Value, self.Control.Text = Value, Value
        self.Setting = false
        Emit(self)
    end

    if Item.Finished then
        Connect(Item.Control.FocusLost, function(Submitted)
            if Submitted then
                Item:SetValue(Item.Control.Text)
            end
        end)
    else
        Connect(Item.Control.TextChanged, function(Text)
            if not Item.Setting then
                Item:SetValue(Text)
            end
        end)
    end

    Item:PositionControl()
    Item.Value = tostring(Config.Default or "")

    return Item
end

function TabMethods:AddDropdown(Id, Config)
    local Item = Option(self, "Dropdown", Id, Config, 175)

    Item.Values, Item.Multi, Item.AllowNull =
        Config.Values or {}, Config.Multi == true, Config.AllowNull == true
    Item.Control = Click(Item.Frame, "", self.Width - 179, 7, 160, 29, function()
        Item:Open()
    end)

    Item.Control.TextXAlignment = "Left"
    Icon(Item.Control, "chevron-down", 137, 7, 14)

    function Item:PositionControl()
        self.Control.Position = V2(self.Tab.Width - 179, (self.Height - 29) / 2)
    end

    function Item:Display()
        local Text = self.Value

        if self.Multi then
            local Selected = {}

            for _, Value in self.Values do
                if self.Value[Value] then
                    Selected[#Selected + 1] = Value
                end
            end

            Text = #Selected > 0 and table.concat(Selected, ", ") or "--"
        end

        self.Control.Text = tostring(Text or "--")
    end

    function Item:SetValue(Value)
        if self.Multi then
            local Result = {}

            for Key, Entry in type(Value) == "table" and Value or {} do
                local Name = type(Key) == "number" and Entry or Key

                if Entry and table.find(self.Values, Name) then
                    Result[Name] = true
                end
            end

            self.Value = Result
        elseif Value == nil and self.AllowNull then
            self.Value = nil
        elseif table.find(self.Values, Value) then
            self.Value = Value
        elseif self.Value == nil and not self.AllowNull then
            self.Value = self.Values[1]
        end

        self:Display()
        Emit(self)
    end

    function Item:SetValues(Values)
        self.Values = Values or self.Values

        if self.Multi then
            self:SetValue(self.Value)
        elseif not table.find(self.Values, self.Value) then
            if self.AllowNull then
                self:SetValue(nil)
            else
                self:SetValue(self.Values[1])
            end
        end

        ClosePopup()
    end

    function Item:Open()
        local Panel =
            NewPopup(self.Control, 180, math.min(220, math.max(40, #self.Values * 31 + 12)))
        Panel.CanvasSize = #self.Values * 31 + 12

        for Index, Value in self.Values do
            local Selected = self.Multi and self.Value[Value] or self.Value == Value
            local Button = Click(
                Panel,
                tostring(Value),
                6,
                6 + (Index - 1) * 31,
                164,
                28,
                function()
                    if self.Multi then
                        local New = table.clone(self.Value)
                        New[Value] = not New[Value] or nil
                        self:SetValue(New)
                        self:Open()
                    else
                        self:SetValue(Value)
                        ClosePopup()
                    end
                end
            )
            Button.TextXAlignment = "Left"

            if Selected then
                Button.BackgroundColor3 = Palette.Selected
            end
        end

        return Panel
    end

    Item:PositionControl()
    Item.Value = Item.Multi and {} or nil

    local Default = type(Config.Default) == "number" and Item.Values[Config.Default]
        or Config.Default
    Item:SetValue(Default)

    return Item
end

function TabMethods:AddColorpicker(Id, Config)
    local Item = Option(self, "Colorpicker", Id, Config, 58)

    Item.Transparency = Config.Transparency or 0
    Item.Control = Click(Item.Frame, "", self.Width - 54, 11, 35, 20, function()
        Item:Open()
    end)

    function Item:PositionControl()
        self.Control.Position = V2(self.Tab.Width - 54, (self.Height - 20) / 2)
    end

    function Item:SetValueRGB(Color, Transparency)
        if
            not Color
            or type(Color.R) ~= "number"
            or type(Color.G) ~= "number"
            or type(Color.B) ~= "number"
        then
            return
        end

        self.Value = Color

        if Transparency ~= nil then
            self.Transparency = math.clamp(Transparency, 0, 1)
        end

        self.Control.BackgroundColor3, self.Control.HoverColor3 = Color, Color
        self.Control.BackgroundTransparency = self.Transparency
        Emit(self)
    end

    function Item:SetValue(Value, Transparency)
        self:SetValueRGB(Value, Transparency)
    end

    function Item:Open()
        local Panel = NewPopup(self.Control, 240, self.Config.Transparency ~= nil and 164 or 132)

        Label(Panel, "Color", 12, 7, 200, 22, 16)

        for Index, Name in { "R", "G", "B", "A" } do
            if Index == 4 and self.Config.Transparency == nil then
                break
            end

            Label(Panel, Name, 12, 34 + (Index - 1) * 30, 20, 22, 12)

            local Value = Index == 4 and self.Transparency or self.Value[Name]
            local Slider = Create(
                "Slider",
                Panel,
                39,
                33 + (Index - 1) * 30,
                185,
                24,
                { SliderStyle = "Fluent", Min = 0, Max = 1, Value = Value },
                { AccentColor3 = "Accent", TextColor3 = "Muted" }
            )
            Connect(Slider:GetPropertyChangedSignal("Value"), function()
                local R, G, B, A = self.Value.R, self.Value.G, self.Value.B, self.Transparency
                if Index == 1 then
                    R = Slider.Value
                elseif Index == 2 then
                    G = Slider.Value
                elseif Index == 3 then
                    B = Slider.Value
                else
                    A = Slider.Value
                end
                self:SetValueRGB(Color3.new(R, G, B), A)
            end)
        end

        return Panel
    end

    Item:PositionControl()
    Item:SetValueRGB(Config.Default or RGB(96, 205, 255), Config.Transparency)

    return Item
end

local function KeyName(Value)
    if type(Value) == "string" then
        return Value
    end

    local Ok, Name = pcall(function()
        return Value.Name
    end)

    return Ok and Name or tostring(Value):match("[^%.]+$")
end

function TabMethods:AddKeybind(Id, Config)
    local Item = Option(self, "Keybind", Id, Config, 115)

    Item.Mode, Item.State, Item.ChangedCallback =
        Config.Mode or "Toggle", false, Config.ChangedCallback
    Item.Control = Click(Item.Frame, "", self.Width - 119, 8, 100, 27, function()
        Item.Listening = true
        Item.Control.Text = "..."
    end)

    function Item:PositionControl()
        self.Control.Position = V2(self.Tab.Width - 119, (self.Height - 27) / 2)
    end

    function Item:SetValue(Value, Mode)
        self.Value = KeyName(Value or "None")
        self.Mode = Mode or self.Mode
        self.Control.Text = self.Value
        Safe(self.ChangedCallback, Value)
        Safe(self.Changed, self.Value)

        for _, Observer in self.Observers or {} do
            Safe(Observer, self.Value)
        end
    end

    function Item:GetState()
        return self.Mode == "Always" or self.State
    end

    function Item:OnClick(Callback)
        self.ClickCallback = Callback

        return self
    end

    function Item:DoClick()
        Safe(self.Callback, self:GetState())
        Safe(self.ClickCallback, self:GetState())
    end

    Item:SetValue(Config.Default or "None", Config.Mode)
    Item:PositionControl()
    Fluent.Keybinds[#Fluent.Keybinds + 1] = Item

    return Item
end

local WindowMethods = {}

function WindowMethods:Resize(Width, Height)
    if self.Resizing then
        return
    end

    Width, Height = tonumber(Width), tonumber(Height)

    if not Width or not Height or Width ~= Width or Height ~= Height then
        return
    end

    local View = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or V2(1280, 720)

    Width = math.clamp(math.floor(Width), math.min(460, View.X), math.max(460, View.X))
    Height = math.clamp(math.floor(Height), math.min(320, View.Y), math.max(320, View.Y))
    self.Resizing = true
    ClosePopup()
    self.Width, self.Height = Width, Height
    self.Root.Size, self.Header.Size = V2(Width, Height), V2(Width, 42)
    self.Sidebar.Size = V2(self.SidebarWidth, Height - 62)
    self.PageTitle.Size = V2(Width - self.SidebarWidth - 40, 35)
    self.Title.Size = V2(Width - 140, 18)

    if self.SubTitle then
        self.SubTitle.Size = V2(math.max(1, Width - self.SubTitle.Position.X - 95), 18)
    end

    self.TitleLine.Size = V2(Width - 2, 1)
    self.MinimizeButton.Position, self.CloseButton.Position = V2(Width - 78, 5), V2(Width - 41, 5)

    for _, Shadow in self.Shadows or {} do
        Shadow.Size = V2(Width - Shadow.Position.X * 2, Height - Shadow.Position.Y * 2)
    end

    if self.ResizeHandle then
        self.ResizeHandle.Position = V2(Width - 20, Height - 20)
    end

    for _, Tab in self.Tabs do
        Tab.Width = Width - self.SidebarWidth - 30
        Tab.Page.Size = V2(Tab.Width, Height - 112)
        Tab.DeferReflow = true

        for _, Row in Tab.Rows do
            if not Row.Frame.Destroyed then
                Row:UpdateLayout()

                if Row.Section then
                    Row.Height = 30
                    Row.TitleLabel.Position = V2(0, 7)
                end
            end
        end

        Tab.DeferReflow = false
        Reflow(Tab)
    end

    self.Resizing = false
end

function WindowMethods:AddTab(Config)
    local Index = #self.Tabs + 1
    local Width = self.Width - self.SidebarWidth - 30
    local Tab = setmetatable(
        { Title = Config.Title or "Tab", Width = Width, Rows = {}, Index = Index },
        { __index = TabMethods }
    )
    Tab.Page = Create(
        "ScrollingFrame",
        self.Root,
        self.SidebarWidth + 18,
        100,
        Width,
        self.Height - 112,
        { Visible = false, ClipsDescendants = true },
        { TextColor3 = "Muted" }
    )
    Tab.Button = Create(
        "TextButton",
        self.Sidebar,
        8,
        8 + (Index - 1) * 39,
        self.SidebarWidth - 16,
        34,
        { BackgroundTransparency = 1, HoverTransparency = 0, Padding = 0, CornerRadius = 5 },
        { HoverColor3 = "Hover", BackgroundColor3 = "Selected" }
    )

    local HasIcon = Icon(Tab.Button, Config.Icon, 10, 8, 18)

    Label(Tab.Button, Tab.Title, HasIcon and 37 or 12, 8, self.SidebarWidth - 54, 18, 14)
    Tab.Indicator = Create(
        "Frame",
        Tab.Button,
        1,
        8,
        3,
        18,
        { BackgroundTransparency = 0, Visible = false, CornerRadius = 2, Active = false },
        { BackgroundColor3 = "Accent" }
    )
    Connect(Tab.Button.MouseButton1Click, function()
        self:SelectTab(Index)
    end)

    self.Tabs[Index] = Tab
    self.Sidebar.CanvasSize = 16 + #self.Tabs * 39
    self:SelectTab(self.Selected or 1)

    return Tab
end

function WindowMethods:SelectTab(Index)
    if not self.Tabs[Index] then
        return
    end

    ClosePopup()
    self.Selected = Index
    self.PageTitle.Text = self.Tabs[Index].Title

    for Number, Tab in self.Tabs do
        Tab.Page.Visible, Tab.Indicator.Visible = Number == Index, Number == Index
        Tab.Button.BackgroundTransparency = Number == Index and 0 or 1
    end
end

function WindowMethods:Minimize()
    ClosePopup()
    self.Minimized = not self.Minimized
    self.Root.Visible = not self.Minimized
end

function WindowMethods:Dialog(Config)
    ClosePopup()

    local Shade = Create("TextButton", self.Root, 0, 0, self.Width, self.Height, {
        ZIndex = 3000,
        BackgroundColor3 = RGB(0, 0, 0),
        BackgroundTransparency = 0.45,
        CornerRadius = 8,
    })

    local Width = math.min(360, self.Width - 40)
    local Text, Lines = Wrap(Config.Content or "", Width - 40, 14)
    local Height = 112 + Lines * 17
    local Panel = Create(
        "Frame",
        Shade,
        (self.Width - Width) / 2,
        (self.Height - Height) / 2,
        Width,
        Height,
        { BackgroundTransparency = 0, CornerRadius = 8, BorderSizePixel = 1 },
        { BackgroundColor3 = "Raised", BorderColor3 = "Border" }
    )
    Label(Panel, Config.Title, 20, 16, Width - 40, 28, 20)

    local Content = Label(Panel, Text, 20, 51, Width - 40, Lines * 17 + 4, 14, "Muted")

    Content.Multiline = true

    local Buttons = Config.Buttons or { { Title = "Close" } }
    local ButtonWidth = (Width - 40 - (#Buttons - 1) * 8) / #Buttons

    for Index, Button in Buttons do
        Click(
            Panel,
            Button.Title or "OK",
            20 + (Index - 1) * (ButtonWidth + 8),
            Height - 47,
            ButtonWidth,
            30,
            function()
                Shade:Destroy()
                Safe(Button.Callback)
            end
        )
    end

    return {
        Destroy = function()
            Shade:Destroy()
        end,
    }
end

function WindowMethods:Destroy()
    Fluent:Destroy()
end

function Fluent:CreateWindow(Config)
    assert(not Window, "Fluent supports one window per library instance")
    self:SetTheme(Config.Theme or "Dark")

    local Width, Height = 680, 500

    if Config.Size then
        local Ok, X, Y = pcall(function()
            return Config.Size.X.Offset, Config.Size.Y.Offset
        end)

        if Ok and X and Y then
            Width, Height = X, Y
        end
    end

    Width, Height = math.clamp(Width, 460, 1200), math.clamp(Height, 320, 900)

    local View = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or V2(1280, 720)
    local Root = Create(
        "Frame",
        nil,
        math.max(8, (View.X - Width) / 2),
        math.max(8, (View.Y - Height) / 2),
        Width,
        Height,
        { ZIndex = 100, BackgroundTransparency = 0, CornerRadius = 8, BorderSizePixel = 1 },
        { BackgroundColor3 = "Background", BorderColor3 = "Border" }
    )

    local Header = Create("Frame", Root, 0, 0, Width, 42, { Draggable = true, DragTarget = Root })
    local Title = Label(Header, Config.Title or "Fluent", 16, 12, Width - 140, 18, 13)
    local SubTitle

    if Config.SubTitle and Config.SubTitle ~= "" then
        local X = 22 + TextWidth(Config.Title or "Fluent", 13)

        SubTitle =
            Label(Header, Config.SubTitle, X, 12, math.max(1, Width - X - 95), 18, 12, "Muted")
    end

    local TitleLine = Create(
        "Frame",
        Root,
        1,
        42,
        Width - 2,
        1,
        { BackgroundTransparency = 0, Active = false },
        { BackgroundColor3 = "Border" }
    )

    local SidebarWidth = math.clamp(Config.TabWidth or 160, 110, 230)
    local Sidebar = Create(
        "ScrollingFrame",
        Root,
        0,
        50,
        SidebarWidth,
        Height - 62,
        { ClipsDescendants = true, ScrollBarThickness = 0 }
    )

    local PageTitle = Label(Root, "", SidebarWidth + 18, 58, Width - SidebarWidth - 40, 35, 27)

    Window = setmetatable({
        Root = Root,
        Header = Header,
        Sidebar = Sidebar,
        PageTitle = PageTitle,
        Width = Width,
        Height = Height,
        SidebarWidth = SidebarWidth,
        Tabs = {},
        MinimizeKey = KeyName(Config.MinimizeKey or "LeftControl"),
    }, { __index = WindowMethods })
    self.Window = Window
    Window.Title, Window.SubTitle, Window.TitleLine = Title, SubTitle, TitleLine
    Window.Shadows = {}

    for Index = 1, 4 do
        local Inset = Index * 4

        Window.Shadows[Index] =
            Create("Frame", Root, -Inset, -Inset, Width + Inset * 2, Height + Inset * 2, {
                ZIndex = -10 - Index,
                Active = false,
                BackgroundColor3 = RGB(0, 0, 0),
                BackgroundTransparency = 0.95,
                CornerRadius = 8 + Inset,
            })
    end

    local Minimize = Click(Header, "", Width - 78, 5, 33, 32, function()
        Window:Minimize()
    end)

    if not Icons.minus then
        Minimize.Text = "-"
    end

    Minimize.BackgroundTransparency = 1
    Icon(Minimize, "minus", 8, 8, 16)

    local Close = Click(Header, "", Width - 41, 5, 33, 32, function()
        Window:Dialog({
            Title = "Unload Fluent?",
            Content = "This will close the interface.",
            Buttons = {
                {
                    Title = "Unload",
                    Callback = function()
                        Fluent:Destroy()
                    end,
                },
                { Title = "Cancel" },
            },
        })
    end)

    Close.BackgroundTransparency = 1

    if not Icons.x then
        Close.Text = "x"
    end

    Icon(Close, "x", 8, 8, 16)
    Window.MinimizeButton, Window.CloseButton = Minimize, Close

    if Config.Resizable ~= false then
        local Handle = Create("TextButton", Root, Width - 20, Height - 20, 20, 20, {
            ZIndex = 100,
            Draggable = true,
            Text = "◢",
            TextSize = 12,
            TextXAlignment = "Center",
            TextTransparency = 0.5,
        })
        Window.ResizeHandle = Handle
        Connect(Handle.Changed, function(Property)
            if Property == "Position" and not Window.Resizing then
                Window:Resize(Handle.Position.X + 20, Handle.Position.Y + 20)
            end
        end)
    end

    self:ToggleAcrylic(Config.Acrylic ~= false)

    return Window
end

function Fluent:SetTheme(Name)
    if not table.find(self.Themes, Name) then
        return
    end

    self.Theme, Palette = Name, Colors(Name)

    for _, Binding in ThemeBindings do
        if not Binding[1].Destroyed then
            for Key, Color in Binding[2] do
                Binding[1][Key] = Palette[Color]
            end
        end
    end

    for _, Item in self.Options do
        if Item.Type == "Colorpicker" and Item.Control and not Item.Control.Destroyed then
            Item.Control.BackgroundColor3, Item.Control.HoverColor3 = Item.Value, Item.Value
        end
    end
end

function Fluent:ToggleTransparency(Value)
    self.Transparency = not not Value
    self:ToggleAcrylic(self.UseAcrylic)
end

function Fluent:ToggleAcrylic(Value)
    self.UseAcrylic = Value == true and self.SupportsAcrylic

    if not Window then
        return
    end

    Window.Root.BackdropBlur = self.UseAcrylic
    Window.Root.BackgroundTransparency = self.UseAcrylic and (self.Transparency and 0.35 or 0.2)
        or (self.Transparency and 0.08 or 0)
end

function Fluent:OnUnload(Callback)
    self.UnloadCallbacks = self.UnloadCallbacks or {}
    self.UnloadCallbacks[#self.UnloadCallbacks + 1] = Callback
end

function Fluent:Notify(Config)
    if self.Unloaded then
        return
    end

    local Duration = tonumber(Config.Duration) or tonumber(self.NotificationDuration) or 4

    if Duration ~= Duration then
        Duration = 4
    end

    Duration = math.clamp(Duration, 0.5, 30)

    local Key = tostring(Config.Title or "Fluent")
        .. "\0"
        .. tostring(Config.Content or "")
        .. "\0"
        .. tostring(Config.SubContent or "")

    for _, Item in self.Notifications do
        if not Item.Destroyed and Item.NotificationKey == Key then
            Item.RefreshNotification(Duration)

            return Item.NotificationHandle
        end
    end

    local View = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or V2(1280, 720)
    local Text, Lines = Wrap(
        (Config.Content or "") .. (Config.SubContent and "\n" .. Config.SubContent or ""),
        265,
        13
    )

    local Height = 54 + Lines * 16
    local Limit = math.max(1, math.floor(tonumber(self.MaxNotifications) or 3))

    while #self.Notifications >= Limit do
        local Old = table.remove(self.Notifications, 1)

        if not Old.Destroyed then
            Old:Destroy()
        end
    end

    local Toast = Create(
        "Frame",
        nil,
        math.max(8, View.X - 324),
        math.max(8, View.Y - Height - 20 - #self.Notifications * (Height + 8)),
        304,
        Height,
        { ZIndex = 6000, BackgroundTransparency = 0, CornerRadius = 7, BorderSizePixel = 1 },
        { BackgroundColor3 = "Raised", BorderColor3 = "Border" }
    )
    Label(Toast, Config.Title or "Fluent", 14, 10, 256, 22, 16)

    local Content = Label(Toast, Text, 14, 37, 265, Lines * 16 + 3, 13, "Muted")

    Content.Multiline = true
    self.Notifications[#self.Notifications + 1] = Toast

    local function Arrange()
        local Offset = 20

        for Index = #self.Notifications, 1, -1 do
            local Item = self.Notifications[Index]

            if not Item.Destroyed then
                Item.Position =
                    V2(math.max(8, View.X - 324), math.max(8, View.Y - Offset - Item.Size.Y))
                Offset += Item.Size.Y + 8
            end
        end
    end

    Arrange()

    local function Remove()
        if Toast.Destroyed then
            return
        end

        if not Toast.Destroyed then
            Toast:Destroy()
        end

        local Index = table.find(self.Notifications, Toast)

        if Index then
            table.remove(self.Notifications, Index)
        end

        Arrange()
    end

    local Close = Click(Toast, "x", 273, 8, 22, 22, Remove)

    Close.BackgroundTransparency = 1

    local Generation = 0

    local function Refresh(Seconds)
        Generation += 1

        local Ticket = Generation

        local function Expire()
            if Ticket == Generation then
                Remove()
            end
        end

        if task and task.delay then
            task.delay(Seconds, Expire)
        else
            task.spawn(function()
                task.wait(Seconds)
                Expire()
            end)
        end
    end

    Toast.NotificationKey = Key
    Toast.NotificationHandle = { Destroy = Remove }
    Toast.RefreshNotification = Refresh
    Refresh(Duration)

    return Toast.NotificationHandle
end

function Fluent:Destroy()
    if self.Unloaded then
        return
    end

    local Manager = rawget(self, "SaveManager")

    if Manager and Manager.FlushAutoSave then
        Manager:FlushAutoSave()
    end

    self.Unloaded = true

    for _, Callback in self.UnloadCallbacks or {} do
        Safe(Callback)
    end

    ClosePopup()

    for _, Connection in self.Connections do
        pcall(function()
            Connection:Disconnect()
        end)
    end

    table.clear(self.Connections)
    Ui.destroyui()
    pcall(function()
        Measure:Remove()
    end)

    if Environment.AstraFluent == self then
        Environment.AstraFluent = nil
    end
end

local function EventName(Event)
    local Kind = KeyName(Event.UserInputType)

    if Kind == "MouseButton1" then
        return "MB1"
    elseif Kind == "MouseButton2" then
        return "MB2"
    end

    return KeyName(Event.KeyCode)
end

local Input = game:GetService("UserInputService")

if Input and Input.InputBegan then
    Connect(Input.InputBegan, function(Event, Processed)
        if Fluent.Unloaded then
            return
        end
        local Name = EventName(Event)
        if not Name or Name == "Unknown" then
            return
        end
        for _, Item in Fluent.Keybinds do
            if not Item.Frame.Destroyed and Item.Listening then
                Item.Listening = false
                Item:SetValue(Name == "Escape" and "None" or Name)
                return
            end
        end
        if Processed or Ui.getfocusedtextbox() then
            return
        end
        local MenuKey = Fluent.MinimizeKeybind and Fluent.MinimizeKeybind.Value
            or Window and Window.MinimizeKey
        if Window and Name == MenuKey then
            Window:Minimize()
        end
        for _, Item in Fluent.Keybinds do
            if not Item.Frame.Destroyed and Name == Item.Value then
                Item.State = Item.Mode == "Toggle" and not Item.State or Item.Mode ~= "Toggle"
                Safe(Item.Callback, Item:GetState())
                if Item.Mode == "Toggle" then
                    Safe(Item.ClickCallback, Item:GetState())
                end
            end
        end
    end, true)
    Connect(Input.InputEnded, function(Event)
        if Fluent.Unloaded then
            return
        end
        local Name = EventName(Event)
        for _, Item in Fluent.Keybinds do
            if not Item.Frame.Destroyed and Item.Mode == "Hold" and Item.Value == Name then
                Item.State = false
                Safe(Item.Callback, false)
            end
        end
    end, true)
end

setmetatable(Fluent, {
    __index = function(Self, Key)
        if Key ~= "SaveManager" and Key ~= "InterfaceManager" then
            return nil
        end
        local Manager = assert(loadstring(game:HttpGet(AssetBase .. "Addons/" .. Key .. ".luau")))()
        Manager:SetLibrary(Self)
        rawset(Self, Key, Manager)
        return Manager
    end,
})

return Fluent
