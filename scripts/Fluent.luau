local Drawing = Drawing
assert(Drawing and type(Drawing.new) == "function", "Fluent requires Drawing")

local Ui
if type(Drawing.newcontext) == "function" then
    local Ok, Result = pcall(Drawing.newcontext)
    if Ok and Result and type(Result.create) == "function" then Ui = Result end
end
if not Ui then
    local Source = game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/FluentDrawing.luau")
    Ui = loadstring(Source)()(Drawing)
end

local V2 = Vector2.new
local RGB = Color3.fromRGB
local Palette = {
    Background = RGB(19, 24, 32), Surface = RGB(29, 36, 47), Raised = RGB(37, 46, 59),
    Hover = RGB(47, 59, 75), Text = RGB(238, 242, 247), Muted = RGB(153, 166, 183),
    Accent = RGB(88, 166, 244), Selected = RGB(39, 72, 104)
}
local Fluent = {Version = "Astra 0.1", Options = {}, Unloaded = false, Theme = "Dark", Keybinds = {}}
local Window

local function Create(Kind, Parent, X, Y, W, H, Properties)
    Properties = Properties or {}
    if Properties.CornerRadius == nil then
        Properties.CornerRadius = Kind == "Frame" and 8 or Kind == "ScrollingFrame" and 0 or 6
    end
    Properties.Parent = Parent
    Properties.Position = V2(X, Y)
    Properties.Size = V2(W, H)
    return Ui.create(Kind, Properties)
end

local function Label(Parent, Text, X, Y, W, H, Size, Color)
    return Create("TextLabel", Parent, X, Y, W, H, {
        Text = tostring(Text or ""), TextSize = Size or 14, TextColor3 = Color or Palette.Text,
        BackgroundTransparency = 1, Active = false, Padding = 0,
        Font = Drawing.Fonts and (Drawing.Fonts.UI or Drawing.Fonts.Monospace) or 3
    })
end

local function Button(Parent, Text, X, Y, W, H, Callback)
    local Item = Create("TextButton", Parent, X, Y, W, H, {
        Text = tostring(Text), TextSize = 13, Padding = 7,
        BackgroundColor3 = Palette.Raised, HoverColor3 = Palette.Hover,
        TextColor3 = Palette.Text,
        Font = Drawing.Fonts and (Drawing.Fonts.UI or Drawing.Fonts.Monospace) or 3
    })
    Item.MouseButton1Click:Connect(function()
        local Ok, Error = pcall(Callback)
        if not Ok then warn("Fluent button: " .. tostring(Error)) end
    end)
    return Item
end

local function Option(Type, Id, Config)
    local Object = {
        Type = Type, Id = Id, Value = Config.Default, Multi = Config.Multi == true,
        Callback = Config.Callback, ChangedCallbacks = {}
    }
    function Object:OnChanged(Callback)
        self.ChangedCallbacks[#self.ChangedCallbacks + 1] = Callback
        return self
    end
    function Object:SetValue(Value)
        if self.Type == "Slider" then
            Value = tonumber(Value) or self.Value or 0
            Value = math.clamp(Value, self.Min, self.Max)
            local Precision = 10 ^ (self.Rounding or 0)
            Value = math.floor(Value * Precision + 0.5) / Precision
        elseif self.Type == "Toggle" then Value = Value == true
        elseif self.Type == "Input" then Value = tostring(Value or "") end
        if self.Value == Value then return end
        self.Value = Value
        if self.Control then
            if self.Type == "Slider" then self.Control.Value = Value
            elseif self.Type == "Input" then self.Control.Text = Value
            elseif self.Type == "Toggle" then
                self.Control.Text = Value and "ON" or "OFF"
                self.Control.BackgroundColor3 = Value and Palette.Selected or Palette.Raised
            elseif self.Type == "Dropdown" then self.Control.Text = tostring(Value)
            elseif self.Type == "Keybind" then self.Control.Text = tostring(Value) end
        end
        if self.Callback then
            local Ok, Error = pcall(self.Callback, Value)
            if not Ok then warn("Fluent option: " .. tostring(Error)) end
        end
        for _, Callback in self.ChangedCallbacks do
            local Ok, Error = pcall(Callback, Value)
            if not Ok then warn("Fluent option: " .. tostring(Error)) end
        end
    end
    if Id then Fluent.Options[Id] = Object end
    return Object
end

local TabMethods = {}
local function Row(Tab, Height, Title, Description)
    local Y = Tab.NextY
    Tab.NextY += Height + 7
    Tab.Page.CanvasSize = Tab.NextY + 8
    local Width = Tab.PageWidth - 22
    local Frame = Create("Frame", Tab.Page, 10, Y, Width, Height, {
        BackgroundColor3 = Palette.Surface, Active = false
    })
    Label(Frame, Title, 12, Description and 7 or math.floor((Height - 17) / 2), Width - 130, 18, 14)
    if Description then Label(Frame, Description, 12, 29, Width - 130, 15, 11, Palette.Muted) end
    return Frame, Width
end

function TabMethods:AddParagraph(Config)
    local Frame, Width = Row(self, Config.Content and 66 or 42, Config.Title or "")
    if Config.Content then Label(Frame, Config.Content, 12, 34, Width - 24, 26, 12, Palette.Muted) end
    return Frame
end

function TabMethods:AddButton(Config)
    local Frame, Width = Row(self, Config.Description and 54 or 44, Config.Title or "Button", Config.Description)
    return Button(Frame, Config.ButtonText or "Run", Width - 108, 8, 96, 29, Config.Callback or function() end)
end

function TabMethods:AddToggle(Id, Config)
    local Item = Option("Toggle", Id, Config)
    local Frame, Width = Row(self, Config.Description and 54 or 44, Config.Title or Id, Config.Description)
    Item.Control = Button(Frame, Item.Value and "ON" or "OFF", Width - 90, 8, 78, 29, function()
        Item:SetValue(not Item.Value)
    end)
    Item.Control.BackgroundColor3 = Item.Value and Palette.Selected or Palette.Raised
    return Item
end

function TabMethods:AddSlider(Id, Config)
    local Item = Option("Slider", Id, Config)
    Item.Min, Item.Max, Item.Rounding = Config.Min or 0, Config.Max or 100, Config.Rounding or 0
    Item.Value = math.clamp(tonumber(Item.Value) or Item.Min, Item.Min, Item.Max)
    local Frame, Width = Row(self, 63, Config.Title or Id, Config.Description)
    Item.Control = Create("Slider", Frame, 12, 34, Width - 24, 23, {
        Text = "", TextSize = 12, Min = Item.Min, Max = Item.Max,
        Value = Item.Value, BackgroundColor3 = Palette.Raised,
        HoverColor3 = Palette.Hover, TextColor3 = Palette.Accent
    })
    Item.Control:GetPropertyChangedSignal("Value"):Connect(function()
        Item:SetValue(Item.Control.Value)
    end)
    return Item
end

function TabMethods:AddInput(Id, Config)
    local Item = Option("Input", Id, Config)
    local Frame, Width = Row(self, Config.Description and 54 or 44, Config.Title or Id, Config.Description)
    Item.Control = Create("TextBox", Frame, Width - 157, 8, 145, 29, {
        Text = tostring(Item.Value or ""), TextSize = 13,
        PlaceholderText = Config.Placeholder or "", BackgroundColor3 = Palette.Raised,
        HoverColor3 = Palette.Hover, TextColor3 = Palette.Text
    })
    Item.Control.FocusLost:Connect(function() Item:SetValue(Item.Control.Text) end)
    return Item
end

function TabMethods:AddDropdown(Id, Config)
    local Item = Option("Dropdown", Id, Config)
    Item.Values = Config.Values or {}
    if type(Item.Value) == "number" then Item.Value = Item.Values[Item.Value] end
    Item.Value = Item.Value or Item.Values[1] or ""
    local Frame, Width = Row(self, Config.Description and 54 or 44, Config.Title or Id, Config.Description)
    Item.Control = Button(Frame, tostring(Item.Value), Width - 157, 8, 145, 29, function()
        if #Item.Values == 0 then return end
        local Index = 0
        for Number, Value in Item.Values do if Value == Item.Value then Index = Number break end end
        Item:SetValue(Item.Values[Index % #Item.Values + 1])
    end)
    return Item
end

function TabMethods:AddKeybind(Id, Config)
    local Item = Option("Keybind", Id, Config)
    Item.Mode = Config.Mode or "Toggle"
    Item.State = false
    Item.Control = nil
    local Frame, Width = Row(self, 44, Config.Title or Id)
    Item.Control = Button(Frame, tostring(Item.Value or "None"), Width - 130, 8, 118, 29, function()
        Item.Listening = true
        Item.Control.Text = "Press a key"
    end)
    function Item:GetState() return self.State end
    function Item:OnClick(Callback) self.ClickCallback = Callback return self end
    function Item:SetValue(Value, Mode)
        if Mode then self.Mode = Mode end
        self.Value = tostring(Value)
        if self.Control then self.Control.Text = self.Value end
    end
    Fluent.Keybinds[#Fluent.Keybinds + 1] = Item
    return Item
end

local WindowMethods = {}
function WindowMethods:AddTab(Config)
    local Index = #self.Tabs + 1
    local Width = self.Width - self.SidebarWidth - 28
    local Page = Create("ScrollingFrame", self.Root, self.SidebarWidth + 13, 62, Width, self.Height - 75, {
        BackgroundColor3 = Palette.Background, BackgroundTransparency = 1,
        ClipsDescendants = true, CanvasSize = 0, Visible = Index == 1
    })
    local Tab = setmetatable({Page = Page, PageWidth = Width, NextY = 10}, {__index = TabMethods})
    local TabButton = Button(self.Sidebar, Config.Title or "Tab", 8, 45 + (Index - 1) * 39,
        self.SidebarWidth - 16, 33, function() self:SelectTab(Index) end)
    Tab.Button = TabButton
    self.Tabs[Index] = Tab
    self:SelectTab(self.Selected or 1)
    return Tab
end

function WindowMethods:SelectTab(Index)
    self.Selected = Index
    for Number, Tab in self.Tabs do
        Tab.Page.Visible = Number == Index
        Tab.Button.BackgroundColor3 = Number == Index and Palette.Selected or Palette.Background
    end
end

function WindowMethods:Destroy()
    if self.Destroyed then return end
    self.Destroyed = true
    Fluent.Unloaded = true
    self.Root:Destroy()
end

function WindowMethods:Dialog(Config)
    Fluent:Notify({Title = Config.Title, Content = Config.Content})
end

function Fluent:CreateWindow(Config)
    if Window then Window:Destroy() end
    self.Unloaded = false
    local Size = Config.Size
    local Width = Size and Size.X and Size.X.Offset or 640
    local Height = Size and Size.Y and Size.Y.Offset or 440
    Width, Height = math.clamp(Width, 420, 820), math.clamp(Height, 320, 700)
    local View = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or V2(1280, 720)
    local Root = Create("Frame", nil, math.max(10, (View.X - Width) / 2),
        math.max(10, (View.Y - Height) / 2), Width, Height, {
            BackgroundColor3 = Palette.Background, Draggable = true, ZIndex = 1000
        })
    local Header = Create("Frame", Root, 0, 0, Width, 49, {
        BackgroundColor3 = Palette.Raised, Active = false
    })
    Label(Header, Config.Title or "Fluent", 16, 7, Width - 70, 24, 17)
    Label(Header, Config.SubTitle or "", 17, 29, Width - 70, 16, 11, Palette.Muted)
    local SidebarWidth = math.clamp(Config.TabWidth or 150, 115, 210)
    local Sidebar = Create("Frame", Root, 0, 49, SidebarWidth, Height - 49, {
        BackgroundColor3 = Palette.Surface, Active = false
    })
    local Result = setmetatable({Root = Root, Sidebar = Sidebar, Width = Width,
        Height = Height, SidebarWidth = SidebarWidth, Tabs = {}}, {__index = WindowMethods})
    Button(Header, "X", Width - 43, 9, 30, 28, function() Result:Destroy() end)
    Window = Result
    return Result
end

function Fluent:Notify(Config)
    print((Config.Title or "Fluent") .. ": " .. (Config.Content or ""))
end

local SaveManager = {Folder = "FluentSettings", Ignore = {}, Options = Fluent.Options}
function SaveManager:SetLibrary(Library) self.Options = Library.Options end
function SaveManager:SetFolder(Folder) self.Folder = tostring(Folder) end
function SaveManager:SetIgnoreIndexes(Indexes)
    for _, Id in Indexes do self.Ignore[Id] = true end
end
function SaveManager:IgnoreThemeSettings()
    self:SetIgnoreIndexes({"InterfaceTheme", "AcrylicToggle", "TransparentToggle", "MenuKeybind"})
end
local function ConfigPath(Self, Name)
    Name = tostring(Name or "default")
    if not Name:match("^[%w_%-]+$") then return nil end
    local Root = "FluentConfigs"
    if type(isfolder) == "function" and not isfolder(Root) then makefolder(Root) end
    local Folder = Root .. "/" .. Self.Folder:gsub("[^%w_%-]", "_")
    if type(isfolder) == "function" and not isfolder(Folder) then makefolder(Folder) end
    return Folder .. "/" .. Name .. ".json"
end
function SaveManager:Save(Name)
    if type(json) ~= "table" or type(json.encode) ~= "function" then return false, "json unavailable" end
    local Path = ConfigPath(self, Name)
    if not Path then return false, "invalid config name" end
    local Values = {}
    for Id, Item in self.Options do
        if not self.Ignore[Id] and (Item.Type == "Toggle" or Item.Type == "Slider" or Item.Type == "Input" or Item.Type == "Dropdown" or Item.Type == "Keybind") then
            Values[Id] = Item.Value
        end
    end
    local Ok, Error = pcall(writefile, Path, json.encode(Values))
    return Ok, Error
end
function SaveManager:Load(Name)
    if type(json) ~= "table" or type(json.decode) ~= "function" then return false, "json unavailable" end
    local Path = ConfigPath(self, Name)
    if not Path or not isfile(Path) then return false, "config missing" end
    local Ok, Values = pcall(function() return json.decode(readfile(Path)) end)
    if not Ok or type(Values) ~= "table" then return false, "invalid config" end
    for Id, Value in Values do
        local Item = self.Options[Id]
        if Item and not self.Ignore[Id] then Item:SetValue(Value) end
    end
    return true
end
function SaveManager:LoadAutoloadConfig() return self:Load("autoload") end
function SaveManager:BuildConfigSection(Tab)
    Tab:AddParagraph({Title = "Configs", Content = "Save settings under Workspace/FluentConfigs."})
    local Name = Tab:AddInput("ConfigName", {Title = "Config name", Default = "default"})
    Tab:AddButton({Title = "Save config", Callback = function()
        local Ok, Error = self:Save(Name.Value)
        Fluent:Notify({Title = "Config", Content = Ok and "Saved" or tostring(Error)})
    end})
    Tab:AddButton({Title = "Load config", Callback = function()
        local Ok, Error = self:Load(Name.Value)
        Fluent:Notify({Title = "Config", Content = Ok and "Loaded" or tostring(Error)})
    end})
    Tab:AddButton({Title = "Save autoload", Callback = function() self:Save("autoload") end})
end

local InterfaceManager = {Folder = "FluentSettings"}
function InterfaceManager:SetLibrary(Library) self.Library = Library end
function InterfaceManager:SetFolder(Folder) self.Folder = Folder end
function InterfaceManager:BuildInterfaceSection(Tab)
    Tab:AddParagraph({Title = "Interface", Content = "Fluent for Vortex, rendered through Drawing."})
    Tab:AddButton({Title = "Close window", Callback = function() if Window then Window:Destroy() end end})
end

Fluent.SaveManager = SaveManager
Fluent.InterfaceManager = InterfaceManager
Fluent.Ui = Ui
local Input = game:GetService("UserInputService")
if Input and Input.InputBegan then
    Input.InputBegan:Connect(function(Event)
        if Fluent.Unloaded then return end
        local Name = Event.KeyCode and Event.KeyCode.Name
        if not Name or Name == "Unknown" then return end
        for _, Item in Fluent.Keybinds do
            if Item.Listening then
                Item.Listening = false
                Item:SetValue(Name)
                if Item.ChangedCallback then pcall(Item.ChangedCallback, Name) end
            elseif Item.Value == Name then
                Item.State = Item.Mode ~= "Toggle" or not Item.State
                if Item.Callback then pcall(Item.Callback, Item.State) end
                if Item.ClickCallback then pcall(Item.ClickCallback, Item.State) end
            end
        end
    end)
    Input.InputEnded:Connect(function(Event)
        local Name = Event.KeyCode and Event.KeyCode.Name
        for _, Item in Fluent.Keybinds do
            if Item.Value == Name and Item.Mode == "Hold" then Item.State = false end
        end
    end)
end
return Fluent
