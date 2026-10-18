local Fluent = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Fluent.luau"))()
local SaveManager = Fluent.SaveManager
local InterfaceManager = Fluent.InterfaceManager
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local Remote = ReplicatedStorage:FindFirstChild("RE_gunmessage")

local Previous = getgenv().AstraGunGame
if Previous and type(Previous.Unload) == "function" then pcall(Previous.Unload, Previous) end

local State = {Running = true, Esp = {}, FireHook = false, OriginalFire = nil}
getgenv().AstraGunGame = State

local function Character(Player)
    return Player and Player.Character
end

local function Part(Player, Name)
    local Model = Character(Player)
    return Model and Model:FindFirstChild(Name)
end

local function Alive(Player)
    local Model = Character(Player)
    local Humanoid = Model and Model:FindFirstChild("Humanoid")
    return Humanoid and Humanoid.Health > 0
end

local function FindTarget(Name)
    Name = tostring(Name or ""):lower()
    if Name == "" then return nil end
    for _, Player in Players:GetPlayers() do
        if Player ~= LocalPlayer and Player.Name:lower():find(Name, 1, true) then
            return Player
        end
    end
    return nil
end

local function Project(Position)
    local Camera = workspace.CurrentCamera
    if not Camera then return nil end
    local Frame = Camera.CFrame
    local Size = Camera.ViewportSize
    local Relative = Position - Frame.Position
    local Depth = Relative:Dot(Frame.LookVector)
    if Depth <= 0.1 then return nil end
    local Field = Camera.FieldOfView or 70
    local Scale = Size.Y / (2 * math.tan(math.rad(Field) / 2))
    return Vector2.new(Size.X / 2 + Relative:Dot(Frame.RightVector) * Scale / Depth,
        Size.Y / 2 - Relative:Dot(Frame.UpVector) * Scale / Depth), Depth
end

local function Nearest(MaxPixels)
    local Camera = workspace.CurrentCamera
    if not Camera then return nil end
    local View = Camera.ViewportSize
    local Middle = Vector2.new(View.X / 2, View.Y / 2)
    local Best, Distance = nil, MaxPixels or 180
    for _, Player in Players:GetPlayers() do
        if Player ~= LocalPlayer and Alive(Player) then
            local Head = Part(Player, "Head") or Part(Player, "HumanoidRootPart")
            if Head then
                local Screen = Project(Head.Position)
                if Screen then
                    local Offset = (Screen - Middle).Magnitude
                    if Offset < Distance then Best, Distance = Player, Offset end
                end
            end
        end
    end
    return Best
end

local function Shot(Player)
    if not Remote or not Alive(Player) then return false end
    local Head = Part(Player, "Head") or Part(Player, "HumanoidRootPart")
    local Camera = workspace.CurrentCamera
    if not Head or not Camera then return false end
    local Origin = Camera.CFrame.Position
    Remote:FireServer({
        id = "fire", rayorigin = Origin, raydestination = Head.Position,
        hitplr = Player.UserId, hitobjectname = Head.Name
    })
    return true
end

local function GunEnvironment()
    local Scripts = game:GetService("StarterPlayerScripts")
    local Client = Scripts and Scripts:FindFirstChild("GunClient")
    if Client and type(getsenv) == "function" then
        local Ok, Environment = pcall(getsenv, Client)
        if Ok and type(Environment) == "table" then return Environment end
    end
    return type(getrenv) == "function" and getrenv() or nil
end

local Window = Fluent:CreateWindow({
    Title = "Astra  |  Gun Game", SubTitle = "Vortex proof of concept",
    TabWidth = 148, Theme = "Dark", Acrylic = true
})
local Tabs = {
    Aim = Window:AddTab({Title = "Aiming", Icon = "crosshair"}),
    Combat = Window:AddTab({Title = "Combat", Icon = "swords"}),
    Players = Window:AddTab({Title = "Players", Icon = "users"}),
    Movement = Window:AddTab({Title = "Movement", Icon = "person-standing"}),
    Visuals = Window:AddTab({Title = "Visuals", Icon = "eye"}),
    Settings = Window:AddTab({Title = "Settings", Icon = "settings"})
}
local Options = Fluent.Options

Tabs.Aim:AddParagraph({Title = "Aim assistant", Content = "Camera aim uses visible players inside the FOV."})
Tabs.Aim:AddToggle("Aimbot", {Title = "Camera aimbot", Default = false})
Tabs.Aim:AddSlider("AimFov", {Title = "Aim FOV", Min = 30, Max = 500, Default = 180, Rounding = 0})
Tabs.Aim:AddToggle("SilentAim", {Title = "Silent aim", Description = "Redirect this game's gun.fire callback", Default = false})
Tabs.Aim:AddButton({Title = "Shoot nearest target", Callback = function()
    if not Shot(Nearest(Options.AimFov.Value)) then Fluent:Notify({Title = "Combat", Content = "No target in FOV"}) end
end})

Tabs.Combat:AddParagraph({Title = "Gun controls", Content = "These use GunClient and RE_gunmessage."})
Tabs.Combat:AddToggle("InfiniteAmmo", {Title = "Infinite ammo", Default = false})
Tabs.Combat:AddToggle("NoRecoil", {Title = "No recoil", Default = false})
Tabs.Combat:AddSlider("FireRate", {Title = "Fire interval", Min = 0.03, Max = 0.5, Default = 0.1, Rounding = 2})
Tabs.Combat:AddToggle("RapidFire", {Title = "Apply fire interval", Default = false})
Tabs.Combat:AddButton({Title = "Kill all once", Description = "Sends one normal shot per player", Callback = function()
    task.spawn(function()
        local Count = 0
        for _, Player in Players:GetPlayers() do
            if not State.Running then break end
            if Player ~= LocalPlayer and Shot(Player) then Count += 1 task.wait(0.16) end
        end
        Fluent:Notify({Title = "Combat", Content = "Sent " .. Count .. " shots"})
    end)
end})

Tabs.Players:AddParagraph({Title = "Player actions", Content = "Enter part of a player's name."})
local PlayerName = Tabs.Players:AddInput("TargetName", {Title = "Target", Default = "", Placeholder = "Player name"})
Tabs.Players:AddButton({Title = "Teleport to player", Callback = function()
    local Target = FindTarget(PlayerName.Value)
    local MyRoot = Part(LocalPlayer, "HumanoidRootPart")
    local TheirRoot = Part(Target, "HumanoidRootPart")
    if MyRoot and TheirRoot then MyRoot.CFrame = CFrame.new(TheirRoot.Position + Vector3.new(0, 3, 0))
    else Fluent:Notify({Title = "Teleport", Content = "Player or root part unavailable"}) end
end})
Tabs.Players:AddButton({Title = "Shoot selected player", Callback = function()
    if not Shot(FindTarget(PlayerName.Value)) then Fluent:Notify({Title = "Combat", Content = "Player unavailable"}) end
end})
Tabs.Players:AddButton({Title = "Teleport to nearest", Callback = function()
    local Target = Nearest(500)
    local MyRoot = Part(LocalPlayer, "HumanoidRootPart")
    local TheirRoot = Part(Target, "HumanoidRootPart")
    if MyRoot and TheirRoot then MyRoot.CFrame = CFrame.new(TheirRoot.Position + Vector3.new(0, 3, 0)) end
end})

Tabs.Movement:AddParagraph({Title = "Character", Content = "Values are reapplied while enabled."})
Tabs.Movement:AddToggle("SpeedEnabled", {Title = "Override walk speed", Default = false})
Tabs.Movement:AddSlider("WalkSpeed", {Title = "Walk speed", Min = 8, Max = 120, Default = 30})
Tabs.Movement:AddToggle("JumpEnabled", {Title = "Override jump power", Default = false})
Tabs.Movement:AddSlider("JumpPower", {Title = "Jump power", Min = 20, Max = 160, Default = 65})

Tabs.Visuals:AddParagraph({Title = "Players", Content = "Drawing names and distance on screen."})
Tabs.Visuals:AddToggle("EspEnabled", {Title = "Player ESP", Default = false})
Tabs.Visuals:AddToggle("EspDistance", {Title = "Show distance", Default = true})
Tabs.Visuals:AddSlider("EspMaxDistance", {Title = "Max distance", Min = 100, Max = 3000, Default = 1200})

SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:SetFolder("AstraGunGame")
InterfaceManager:SetFolder("AstraGunGame")
InterfaceManager:BuildInterfaceSection(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
Window:SelectTab(1)

local Environment = GunEnvironment()
local Gun = Environment and Environment.gun
if Gun and type(Gun.fire) == "function" and type(hookfunction) == "function" then
    local Ok, Original = pcall(function()
        return hookfunction(Gun.fire, function(Self, ...)
            if State.Running and Options.SilentAim.Value and Self.char == Character(LocalPlayer) then
                local Target = Nearest(Options.AimFov.Value)
                if Target and Shot(Target) then return end
            end
            return State.OriginalFire(Self, ...)
        end)
    end)
    if Ok and type(Original) == "function" then State.OriginalFire = Original State.FireHook = true end
end

local function ClearEsp()
    for Player, Label in State.Esp do
        pcall(function() Label:Remove() end)
        State.Esp[Player] = nil
    end
end

function State:Unload()
    self.Running = false
    ClearEsp()
    if Window then Window:Destroy() end
end

task.spawn(function()
    while State.Running do
        local Ok, Error = pcall(function()
            local MyCharacter = Character(LocalPlayer)
            local Humanoid = MyCharacter and MyCharacter:FindFirstChild("Humanoid")
            if Humanoid then
                if Options.SpeedEnabled.Value then Humanoid.WalkSpeed = Options.WalkSpeed.Value end
                if Options.JumpEnabled.Value then Humanoid.JumpPower = Options.JumpPower.Value end
            end
            if Environment then
                local Equipped = Environment.equipped_gun
                if Equipped then
                    if Options.InfiniteAmmo.Value then Equipped.ammo_mag = Equipped.info and Equipped.info.magcapacity or 30 end
                    if Options.RapidFire.Value and Equipped.info then Equipped.info.firerate = Options.FireRate.Value end
                end
                if Options.NoRecoil.Value then Environment.RECOIL = Vector3.zero end
            end
            if Options.Aimbot.Value then
                local Target = Nearest(Options.AimFov.Value)
                local Head = Part(Target, "Head") or Part(Target, "HumanoidRootPart")
                local Camera = workspace.CurrentCamera
                if Head and Camera then Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, Head.Position) end
            end
            if Options.EspEnabled.Value then
                local Camera = workspace.CurrentCamera
                for _, Player in Players:GetPlayers() do
                    if Player ~= LocalPlayer and Alive(Player) then
                        local Head = Part(Player, "Head") or Part(Player, "HumanoidRootPart")
                        local Screen, Depth
                        if Head then Screen, Depth = Project(Head.Position) end
                        local Label = State.Esp[Player]
                        if not Label then
                            Label = Drawing.new("Text")
                            Label.Size = 14
                            Label.Center = true
                            Label.Color = Color3.fromRGB(105, 196, 255)
                            Label.Outline = true
                            State.Esp[Player] = Label
                        end
                        Label.Visible = Screen ~= nil and Depth < Options.EspMaxDistance.Value
                        if Label.Visible then
                            Label.Position = Screen
                            Label.Text = Player.Name .. (Options.EspDistance.Value and ("  [" .. math.floor(Depth) .. "]") or "")
                        end
                    end
                end
            else ClearEsp() end
        end)
        if not Ok then warn("Astra Gun Game: " .. tostring(Error)) end
        task.wait(0.12)
    end
end)

Fluent:Notify({Title = "Astra Gun Game", Content = "Loaded. Gun hook: " .. tostring(State.FireHook)})
return State
