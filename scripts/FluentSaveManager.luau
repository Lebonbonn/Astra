local SaveManager = {Folder = "FluentSettings", Ignore = {}}
local function Json()
    if type(json) == "table" and type(json.encode) == "function" then return json.encode, json.decode end
    local Service = game:GetService("HttpService")
    return function(Value) return Service:JSONEncode(Value) end, function(Value) return Service:JSONDecode(Value) end
end
local function ValidName(Name)
    return type(Name) == "string" and #Name > 0 and #Name <= 96 and Name:match("^[%w _%-]+$") ~= nil
end
function SaveManager:SetLibrary(Library) self.Library, self.Options = Library, Library.Options end
function SaveManager:SetIgnoreIndexes(Indexes) for _, Index in Indexes do self.Ignore[Index] = true end end
function SaveManager:IgnoreThemeSettings() self:SetIgnoreIndexes({"InterfaceTheme", "AcrylicToggle", "TransparentToggle", "MenuKeybind"}) end
function SaveManager:BuildFolderTree()
    local Ok, Error = pcall(function()
        assert(type(makefolder) == "function" and type(isfolder) == "function", "filesystem unavailable")
        local Path = ""
        for Part in (self.Folder .. "/settings"):gmatch("[^/]+") do
            assert(Part ~= "." and Part ~= ".." and Part:match("^[%w _%-]+$"), "invalid folder")
            Path = Path == "" and Part or Path .. "/" .. Part
            if not isfolder(Path) then makefolder(Path) end
        end
    end)
    return Ok, Error
end
function SaveManager:SetFolder(Folder)
    self.Folder = tostring(Folder):gsub("\\", "/"):gsub("/+$", "")
    return self:BuildFolderTree()
end
function SaveManager:Save(Name)
    if not ValidName(Name) then return false, "invalid config name" end
    local Ok, Error = self:BuildFolderTree()
    if not Ok then return false, Error end
    return pcall(function()
        local Encode = Json()
        local Objects = {}
        for Id, Item in self.Options do
            if not self.Ignore[Id] and not Item.Frame.Destroyed then
                local Entry = {idx = Id, type = Item.Type}
                if Item.Type == "Colorpicker" then
                    Entry.value = {R = Item.Value.R, G = Item.Value.G, B = Item.Value.B}
                    Entry.transparency = Item.Transparency
                elseif Item.Type == "Keybind" then Entry.key, Entry.mode = Item.Value, Item.Mode
                elseif Item.Type == "Input" then Entry.text = Item.Value
                else Entry.value = Item.Value end
                Objects[#Objects + 1] = Entry
            end
        end
        writefile(self.Folder .. "/settings/" .. Name .. ".json", Encode({version = 1, objects = Objects}))
    end)
end
function SaveManager:Load(Name)
    if not ValidName(Name) then return false, "invalid config name" end
    local Ok, Error = pcall(function()
        local _, Decode = Json()
        local Value = Decode(readfile(self.Folder .. "/settings/" .. Name .. ".json"))
        assert(type(Value) == "table" and type(Value.objects) == "table", "invalid config")
        for _, Entry in Value.objects do
            local Item = type(Entry) == "table" and self.Options[Entry.idx]
            if Item and not self.Ignore[Entry.idx] and Item.Type == Entry.type and not Item.Frame.Destroyed then
                if Item.Type == "Colorpicker" then
                    local Color = Entry.value
                    assert(type(Color) == "table" and type(Color.R) == "number" and type(Color.G) == "number" and type(Color.B) == "number", "invalid color")
                    Item:SetValueRGB(Color3.new(Color.R, Color.G, Color.B), Entry.transparency)
                elseif Item.Type == "Keybind" then Item:SetValue(Entry.key, Entry.mode)
                elseif Item.Type == "Input" then Item:SetValue(Entry.text)
                else Item:SetValue(Entry.value) end
            end
        end
    end)
    return Ok, Error
end
function SaveManager:RefreshConfigList()
    local Result = {}
    local Ok = self:BuildFolderTree()
    if not Ok then return Result end
    local Success, Files = pcall(listfiles, self.Folder .. "/settings")
    if not Success then return Result end
    for _, File in Files do
        local Name = File:gsub("\\", "/"):match("([^/]+)%.json$")
        if Name and ValidName(Name) then Result[#Result + 1] = Name end
    end
    table.sort(Result)
    return Result
end
function SaveManager:SetAutoloadConfig(Name)
    if not ValidName(Name) then return false, "invalid config name" end
    local Ok, Error = self:BuildFolderTree()
    if not Ok then return false, Error end
    return pcall(writefile, self.Folder .. "/settings/autoload.txt", Name)
end
function SaveManager:LoadAutoloadConfig()
    local Ok, Name = pcall(readfile, self.Folder .. "/settings/autoload.txt")
    if not Ok then return false, "no autoload config" end
    return self:Load(Name)
end
function SaveManager:BuildConfigSection(Tab)
    assert(self.Library, "Call SetLibrary first")
    local Section = Tab:AddSection("Configuration")
    local Name = Section:AddInput("SaveManager_ConfigName", {Title = "Config name", Default = "default"})
    local List = Section:AddDropdown("SaveManager_ConfigList", {Title = "Config list", Values = self:RefreshConfigList(), AllowNull = true})
    local function Report(Ok, Error)
        self.Library:Notify({Title = "Configuration", Content = Ok and "Done" or tostring(Error), Duration = 4})
    end
    Section:AddButton({Title = "Create config", Callback = function()
        Report(self:Save(Name.Value))
        List:SetValues(self:RefreshConfigList())
    end})
    Section:AddButton({Title = "Load config", Callback = function() Report(self:Load(List.Value)) end})
    Section:AddButton({Title = "Overwrite config", Callback = function() Report(self:Save(List.Value)) end})
    Section:AddButton({Title = "Refresh list", Callback = function() List:SetValues(self:RefreshConfigList()) end})
    Section:AddButton({Title = "Set as autoload", Callback = function() Report(self:SetAutoloadConfig(List.Value)) end})
    self:SetIgnoreIndexes({"SaveManager_ConfigName", "SaveManager_ConfigList"})
    return Section
end
return SaveManager
