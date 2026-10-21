local InterfaceManager = {Folder = "FluentInterface", Settings = {Theme = "Dark", Acrylic = true, Transparency = false, MenuKeybind = "LeftControl"}}
function InterfaceManager:SetLibrary(Library) self.Library = Library end
function InterfaceManager:SetFolder(Folder)
    self.Folder = tostring(Folder):gsub("\\", "/"):gsub("/+$", "")
end
function InterfaceManager:SaveSettings()
    local Manager = self.Library.SaveManager
    local Old = Manager.Folder
    Manager.Folder = self.Folder
    local Ok, Error = Manager:BuildFolderTree()
    Manager.Folder = Old
    if not Ok then return false, Error end
    return pcall(function()
        local Encode = type(json) == "table" and json.encode or function(Value) return game:GetService("HttpService"):JSONEncode(Value) end
        writefile(self.Folder .. "/options.json", Encode(self.Settings))
    end)
end
function InterfaceManager:LoadSettings()
    local Ok, Settings = pcall(function()
        local Decode = type(json) == "table" and json.decode or function(Value) return game:GetService("HttpService"):JSONDecode(Value) end
        return Decode(readfile(self.Folder .. "/options.json"))
    end)
    if Ok and type(Settings) == "table" then
        if type(Settings.Theme) == "string" then self.Settings.Theme = Settings.Theme end
        if type(Settings.Transparency) == "boolean" then self.Settings.Transparency = Settings.Transparency end
        if type(Settings.Acrylic) == "boolean" then self.Settings.Acrylic = Settings.Acrylic end
        if type(Settings.MenuKeybind) == "string" then self.Settings.MenuKeybind = Settings.MenuKeybind end
    end
    return Ok
end
function InterfaceManager:BuildInterfaceSection(Tab)
    assert(self.Library, "Call SetLibrary first")
    self:LoadSettings()
    local Library, Settings = self.Library, self.Settings
    local Section = Tab:AddSection("Interface")
    Section:AddDropdown("InterfaceTheme", {Title = "Theme", Description = "Changes the interface theme.", Values = Library.Themes, Default = Settings.Theme, Callback = function(Value)
        Library:SetTheme(Value)
        Settings.Theme = Value
        self:SaveSettings()
    end})
    Section:AddToggle("TransparentToggle", {Title = "Transparency", Description = "Makes the window slightly transparent.", Default = Settings.Transparency, Callback = function(Value)
        Library:ToggleTransparency(Value)
        Settings.Transparency = Value
        self:SaveSettings()
    end})
    if Library.SupportsAcrylic then
        Section:AddToggle("AcrylicToggle", {Title = "Acrylic", Description = "Blurs the scene behind the window.", Default = Settings.Acrylic, Callback = function(Value)
            Library:ToggleAcrylic(Value)
            Settings.Acrylic = Value
            self:SaveSettings()
        end})
    end
    local Keybind = Section:AddKeybind("MenuKeybind", {Title = "Minimize bind", Default = Settings.MenuKeybind})
    Keybind:OnChanged(function(Value) Settings.MenuKeybind = Value self:SaveSettings() end)
    Library.MinimizeKeybind = Keybind
    return Section
end
return InterfaceManager
