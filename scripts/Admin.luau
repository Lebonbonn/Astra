local Environment = _G
if type(getgenv) == "function" then local Ok, Value = pcall(getgenv) if Ok and type(Value) == "table" then Environment = Value end end
local getgenv = function() return Environment end
local task = task or {wait = wait, spawn = spawn, defer = spawn, delay = delay}
assert(type(task.wait) == "function" and type(task.spawn) == "function", "A scheduler with wait and spawn is required")
local MemoryFiles = Environment.VortexClientFiles or {}
Environment.VortexClientFiles = MemoryFiles
local NativeRead, NativeWrite, NativeIsFile = readfile, writefile, isfile
local function readfile(Path)
    if type(NativeRead) == "function" then return NativeRead(Path) end
    return assert(MemoryFiles[Path], "File not found")
end
local function writefile(Path, Text)
    if type(NativeWrite) == "function" then return NativeWrite(Path, Text) end
    MemoryFiles[Path] = Text
end
local function isfile(Path)
    if type(NativeIsFile) == "function" then return NativeIsFile(Path) end
    if MemoryFiles[Path] ~= nil then return true end
    if type(NativeRead) == "function" then return pcall(NativeRead, Path) end
    return false
end
local json = type(json) == "table" and json or {}
if type(json.encode) ~= "function" or type(json.decode) ~= "function" then
    json = {}
    json.null = {}
    local function Quote(Text)
        return '"' .. Text:gsub('[%z\1-\31\\"]', function(Character)
            local Escapes = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
            return Escapes[Character] or string.format('\\u%04x', string.byte(Character))
        end) .. '"'
    end
    function json.encode(Value)
        local Seen = {}
        local function Encode(Item, Depth)
            assert(Depth < 64, "JSON is too deeply nested")
            if Item == nil or Item == json.null then return "null" end
            if type(Item) == "string" then return Quote(Item) end
            if type(Item) == "boolean" then return tostring(Item) end
            if type(Item) == "number" then assert(Item == Item and math.abs(Item) < math.huge, "Invalid JSON number") return tostring(Item) end
            assert(type(Item) == "table" and not Seen[Item], "Invalid JSON value")
            Seen[Item] = true
            local Array, Count = true, 0
            for Key in Item do Count += 1 if type(Key) ~= "number" or Key % 1 ~= 0 or Key < 1 then Array = false end end
            Array = Array and Count > 0 and Count == #Item
            local Parts = {}
            if Array then for _, Entry in Item do Parts[#Parts + 1] = Encode(Entry, Depth + 1) end
            else for Key, Entry in Item do Parts[#Parts + 1] = Quote(tostring(Key)) .. ":" .. Encode(Entry, Depth + 1) end end
            Seen[Item] = nil
            return (Array and "[" or "{") .. table.concat(Parts, ",") .. (Array and "]" or "}")
        end
        return Encode(Value, 0)
    end
    function json.decode(Text)
        assert(type(Text) == "string" and #Text <= 1024 * 1024, "Invalid JSON input")
        local Cursor = 1
        local function Space() local _, Last = Text:find("^%s*", Cursor) Cursor = (Last or Cursor - 1) + 1 end
        local Parse
        local function String()
            Cursor += 1
            local Parts = {}
            while Cursor <= #Text do
                local Character = Text:sub(Cursor, Cursor)
                Cursor += 1
                if Character == '"' then return table.concat(Parts) end
                if Character == "\\" then
                    local Escape = Text:sub(Cursor, Cursor)
                    Cursor += 1
                    if Escape == "u" then
                        local Code = tonumber(Text:sub(Cursor, Cursor + 3), 16)
                        assert(Code, "Invalid JSON escape")
                        Cursor += 4
                        if Code >= 0xD800 and Code <= 0xDBFF then
                            assert(Text:sub(Cursor, Cursor + 1) == "\\u", "Invalid JSON surrogate")
                            local Low = tonumber(Text:sub(Cursor + 2, Cursor + 5), 16)
                            assert(Low and Low >= 0xDC00 and Low <= 0xDFFF, "Invalid JSON surrogate")
                            Code = 0x10000 + (Code - 0xD800) * 1024 + Low - 0xDC00
                            Cursor += 6
                        end
                        assert(Code < 0xD800 or Code > 0xDFFF, "Invalid JSON surrogate")
                        Character = utf8.char(Code)
                    else Character = ({['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'})[Escape] assert(Character, "Invalid JSON escape") end
                else assert(string.byte(Character) >= 32, "Invalid JSON string") end
                Parts[#Parts + 1] = Character
            end
            error("Unclosed JSON string")
        end
        Parse = function(Depth)
            assert(Depth < 64, "JSON is too deeply nested")
            Space()
            local Character = Text:sub(Cursor, Cursor)
            if Character == '"' then return String() end
            if Character == "{" or Character == "[" then
                Cursor += 1 Space()
                local Result, Array = {}, Character == "["
                local Close = Array and "]" or "}"
                if Text:sub(Cursor, Cursor) == Close then Cursor += 1 return Result end
                while true do
                    Space()
                    local Key = #Result + 1
                    if not Array then assert(Text:sub(Cursor, Cursor) == '"', "Expected JSON key") Key = String() Space() assert(Text:sub(Cursor, Cursor) == ":", "Expected colon") Cursor += 1 end
                    Result[Key] = Parse(Depth + 1)
                    Space()
                    local Delimiter = Text:sub(Cursor, Cursor)
                    Cursor += 1
                    if Delimiter == Close then return Result end
                    assert(Delimiter == ",", "Expected JSON delimiter")
                end
            end
            for Word, Value in {['true'] = true, ['false'] = false} do if Text:sub(Cursor, Cursor + #Word - 1) == Word then Cursor += #Word return Value end end
            if Text:sub(Cursor, Cursor + 3) == "null" then Cursor += 4 return json.null end
            local Number = Text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", Cursor)
            local Value = Number and tonumber(Number)
            assert(Value and Value == Value and math.abs(Value) < math.huge and not Number:match("^-?0%d") and not Number:match("%.$") and not Number:match("%.%D") and not Number:match("[eE][+-]?$"), "Invalid JSON value")
            Cursor += #Number
            return Value
        end
        local Value = Parse(0)
        Space()
        assert(Cursor > #Text, "Trailing JSON data")
        return Value
    end
end

local CreateUiLibrary = (function()
local function CreateLibrary(Drawing, Services)
    local Library = {UiVersion = 8}
    local HoveredItem
    local HoverChain = {}
    local Items, Connections = {}, {}
    local Focus, Pressed, Secondary, Drag, ScrollDrag, Context, Input, Running
    local Pointer = Vector2.new(0, 0)
    local Keys = {}
    local NextId = 0
    local Dirty = true
    local PaintDirty = true
    local LastBlink = -1
    local LayoutVersion = 0
    local LastHitX, LastHitY, LastHitVersion, LastHitActive
    local Boxes = setmetatable({}, {__mode = "k"})
    local Kinds = {Frame = true, ScrollingFrame = true, TextLabel = true, TextBox = true, TextButton = true, Button = true, Checkbox = true, Slider = true, ImageLabel = true}
    local Task
    local Elapsed = 0
    local Clock = os and os.clock
    local NativeNew = Drawing.new
    local function Name(Value) return type(Value) == "string" and Value or Value and Value.Name or "Unknown" end
    local function Signal()
        local Event = {Listeners = {}}
        function Event:Connect(Callback)
            assert(type(Callback) == "function", "Expected a function")
            local Connection = {Connected = true}
            self.Listeners[Connection] = Callback
            function Connection:Disconnect() self.Connected = false Event.Listeners[self] = nil end
            return Connection
        end
        function Event:Fire(...)
            local Arguments = table.pack(...)
            for Connection, Callback in self.Listeners do
                if Connection.Connected then Task.spawn(function() if not Connection.Connected then return end local Ok, Error = pcall(Callback, table.unpack(Arguments, 1, Arguments.n)) if not Ok then warn(Error) end end) end
            end
        end
        return Event
    end
    local function Before(Text, Cursor)
        Cursor = math.max(0, Cursor - 1)
        while Cursor > 0 and string.byte(Text, Cursor + 1) >= 128 and string.byte(Text, Cursor + 1) < 192 do Cursor -= 1 end
        return Cursor
    end
    local function After(Text, Cursor)
        Cursor = math.min(#Text, Cursor + 1)
        while Cursor < #Text and string.byte(Text, Cursor + 1) >= 128 and string.byte(Text, Cursor + 1) < 192 do Cursor += 1 end
        return Cursor
    end
    local function CharacterKind(Text, Cursor)
        local Character = Text:sub(Cursor + 1, After(Text, Cursor))
        if Character:match("%s") then return "Space" end
        if Character:match("[%w_]") or (Character:byte() or 0) >= 128 then return "Word" end
        return "Punctuation"
    end
    local function WordBefore(Text, Cursor)
        while Cursor > 0 and CharacterKind(Text, Before(Text, Cursor)) == "Space" do Cursor = Before(Text, Cursor) end
        if Cursor == 0 then return 0 end
        local Kind = CharacterKind(Text, Before(Text, Cursor))
        while Cursor > 0 and CharacterKind(Text, Before(Text, Cursor)) == Kind do Cursor = Before(Text, Cursor) end
        return Cursor
    end
    local function WordAfter(Text, Cursor)
        while Cursor < #Text and CharacterKind(Text, Cursor) == "Space" do Cursor = After(Text, Cursor) end
        if Cursor == #Text then return Cursor end
        local Kind = CharacterKind(Text, Cursor)
        while Cursor < #Text and CharacterKind(Text, Cursor) == Kind do Cursor = After(Text, Cursor) end
        return Cursor
    end
    local function LineStart(Text, Cursor)
        while Cursor > 0 and Text:sub(Cursor, Cursor) ~= "\n" do Cursor = Before(Text, Cursor) end
        return Cursor
    end
    local function LineEnd(Text, Cursor)
        return (Text:find("\n", Cursor + 1, true) or (#Text + 1)) - 1
    end
    local function Inside(Point, Bounds)
        return Bounds and Point.X >= Bounds.X and Point.Y >= Bounds.Y and Point.X <= Bounds.X + Bounds.Width and Point.Y <= Bounds.Y + Bounds.Height
    end
    local function Bounds(Item, Depth)
        local Cached = Boxes[Item]
        if Cached and Cached.Version == LayoutVersion then return Cached.Box end
        if Item.Destroyed or not Item.Visible or (Depth or 0) > 64 then return nil end
        local Position, Size = Item.Position, Item.Size
        local X, Y = Position.X, Position.Y
        if Item.Parent then
            local Parent = Bounds(Item.Parent, (Depth or 0) + 1)
            if not Parent then return nil end
            X += Parent.X
            Y += Parent.Y - (Item.Parent.ScrollOffset or 0)
        end
        local Box = {X = X, Y = Y, Width = Size.X, Height = Size.Y}
        Boxes[Item] = {Version = LayoutVersion, Box = Box}
        return Box
    end
    local function CanHit(Item)
        local Parent = Item.Parent
        while Parent do
            if Parent.ClipsDescendants and not Inside(Pointer, Bounds(Parent)) then return false end
            Parent = Parent.Parent
        end
        return true
    end
    local function GetLayer(Item)
        local Value, Parent = Item.ZIndex, Item.Parent
        while Parent do Value += Parent.ZIndex Parent = Parent.Parent end
        return math.clamp(Value, -9998, 9998)
    end
    local function Shape(Item, Key, Kind, Values)
        local Entry = Item.Shapes[Key]
        if not Entry then Entry = {Object = NativeNew(Kind), Values = {}} Item.Shapes[Key] = Entry end
        for Property, Value in Values do
            local Previous = Entry.Values[Property]
            local Equal = Previous == Value
            if Previous and (Property == "Position" or Property == "Size" and Kind ~= "Text") then Equal = Previous.X == Value.X and Previous.Y == Value.Y
            elseif Previous and Property == "Color" then Equal = Previous.R == Value.R and Previous.G == Value.G and Previous.B == Value.B end
            if not Equal then
                if Property == "Rounding" then pcall(function() Entry.Object[Property] = Value end)
                else Entry.Object[Property] = Value end
                Entry.Values[Property] = Value
            end
        end
        local Parent, Clip = Item.Parent, nil
        while Parent do
            if Parent.ClipsDescendants then
                local Box = Bounds(Parent)
                if Box then
                    if not Clip then Clip = {X=Box.X,Y=Box.Y,Width=Box.Width,Height=Box.Height} else
                        local Right, Bottom = math.min(Clip.X + Clip.Width, Box.X + Box.Width), math.min(Clip.Y + Clip.Height, Box.Y + Box.Height)
                        Clip.X, Clip.Y = math.max(Clip.X, Box.X), math.max(Clip.Y, Box.Y)
                        Clip.Width, Clip.Height = math.max(0, Right - Clip.X), math.max(0, Bottom - Clip.Y)
                    end
                end
            end
            Parent = Parent.Parent
        end
        if Kind == "Text" or Key == "Selection" then
            local Own = Bounds(Item)
            if Own and Clip then
                local Right, Bottom = math.min(Clip.X + Clip.Width, Own.X + Own.Width), math.min(Clip.Y + Clip.Height, Own.Y + Own.Height)
                Clip.X, Clip.Y = math.max(Clip.X, Own.X), math.max(Clip.Y, Own.Y)
                Clip.Width, Clip.Height = math.max(0, Right - Clip.X), math.max(0, Bottom - Clip.Y)
            else Clip = Own or Clip end
        end
        if Entry.Clipping ~= false then
            local Ok = pcall(function()
                Entry.Object.Clipping = Clip ~= nil
                if Clip then Entry.Object.ClipPosition = Vector2.new(Clip.X, Clip.Y) Entry.Object.ClipSize = Vector2.new(Clip.Width, Clip.Height) end
            end)
            Entry.Clipping = Ok
        end
        return Entry.Object
    end
    local function Selection(Item)
        return math.min(Item.Cursor, Item.Anchor), math.max(Item.Cursor, Item.Anchor)
    end
    local function Replace(Item, Text)
        Item.UndoItems[#Item.UndoItems + 1] = {Text = Item.Text, Cursor = Item.Cursor, Anchor = Item.Anchor}
        if #Item.UndoItems > 100 then table.remove(Item.UndoItems, 1) end
        table.clear(Item.RedoItems)
        local First, Last = Selection(Item)
        if not Item.Multiline then Text = Text:gsub("[\r\n]+", " ") end
        Text = Text:gsub("\r\n", "\n"):gsub("\r", "\n")
        local Limit = math.max(0, Item.MaxLength - (#Item.Text - (Last - First)))
        if #Text > Limit then
            local End = Limit
            while End > 0 and string.byte(Text, End + 1) and string.byte(Text, End + 1) >= 128 and string.byte(Text, End + 1) < 192 do End -= 1 end
            Text = Text:sub(1, End)
        end
        Item.Text = Item.Text:sub(1, First) .. Text .. Item.Text:sub(Last + 1)
        Item.Cursor = First + #Text
        Item.Anchor = Item.Cursor
    end
    local Methods = {}
    function Methods:CaptureFocus()
        assert(self.Kind == "TextBox" and self.TextEditable and not self.Destroyed, "Expected an editable TextBox")
        if Focus == self then return end
        if Focus then Focus:ReleaseFocus(false) end
        Focus = self
        PaintDirty = true
        self.Cursor = #self.Text
        self.Anchor = self.Cursor
        if self.ClearTextOnFocus then self.Text = "" self.Cursor = 0 self.Anchor = 0 end
        self.Focused:Fire()
    end
    function Methods:ReleaseFocus(Submitted)
        if Focus ~= self then return end
        Focus = nil
        PaintDirty = true
        if Context then Context:setcapture(false, false) end
        self.FocusLost:Fire(Submitted == true)
    end
    function Methods:IsFocused() return Focus == self end
    function Methods:GetChildren()
        local Children = {}
        for _, Item in Items do if Item.Parent == self and not Item.Destroyed then Children[#Children + 1] = Item end end
        return Children
    end
    function Methods:GetSelection() local First, Last = Selection(self) return self.Text:sub(First + 1, Last) end
    function Methods:SelectAll() self.Anchor = 0 self.Cursor = #self.Text end
    function Methods:InsertText(Text) assert(type(Text) == "string", "Expected text") Replace(self, Text) end
    function Methods:GetPropertyChangedSignal(Property)
        self.ChangedEvents[Property] = self.ChangedEvents[Property] or Signal()
        return self.ChangedEvents[Property]
    end
    function Methods:Destroy()
        if self.Destroyed then return end
        if Focus == self then self:ReleaseFocus(false) end
        for _, Child in self:GetChildren() do Child:Destroy() end
        self.Destroyed = true
        PaintDirty = true
        if Pressed == self then Pressed = nil end
        if Drag and Drag.Item == self then Drag = nil end
        for _, Entry in self.Shapes do pcall(function() Entry.Object:Remove() end) end
        for _, Name in {"Focused", "FocusLost", "TextChanged", "Changed", "InputBegan", "MouseEnter", "MouseLeave", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up"} do
            for Connection in self[Name].Listeners do Connection:Disconnect() end
        end
        for _, Event in self.ChangedEvents do for Connection in Event.Listeners do Connection:Disconnect() end end
        table.clear(self.Shapes)
        Dirty = true
    end
    Methods.Remove = Methods.Destroy
    local function Key(KeyName, Repeated)
        local Item = Focus
        if not Item or not Item.TextEditable then return end
        local Control = Keys.Control
        if Control == nil then Control = Keys.LeftControl or Keys.RightControl end
        local Shift = Keys.Shift
        if Shift == nil then Shift = Keys.LeftShift or Keys.RightShift end
        local Alt = Keys.Alt
        if Alt == nil then Alt = Keys.LeftAlt or Keys.RightAlt end
        local Command = Keys.Command
        local Primary = Command or Control
        local Word = Alt or Control
        Item.InputBegan:Fire(KeyName, Primary == true, Shift == true)
        if Primary and (KeyName == "Z" or KeyName == "Y") then
            local Redo = KeyName == "Y" or Shift
            local Source = Redo and Item.RedoItems or Item.UndoItems
            local Destination = Redo and Item.UndoItems or Item.RedoItems
            local State = table.remove(Source)
            if State then Destination[#Destination + 1] = {Text = Item.Text, Cursor = Item.Cursor, Anchor = Item.Anchor} Item.Text = State.Text Item.Cursor = State.Cursor Item.Anchor = State.Anchor end
        elseif Primary and KeyName == "A" then Item:SelectAll()
        elseif Primary and (KeyName == "C" or KeyName == "X" or KeyName == "Insert") or Shift and KeyName == "Delete" then
            local Text = Item:GetSelection()
            if #Text > 0 and type(setclipboard) == "function" then setclipboard(Text) end
            if (KeyName == "X" or KeyName == "Delete") and #Text > 0 then Replace(Item, "") end
        elseif KeyName == "Backspace" or KeyName == "Delete" then
            if Item.Cursor == Item.Anchor then
                if KeyName == "Backspace" then
                    Item.Anchor = Command and LineStart(Item.Text, Item.Cursor) or Word and WordBefore(Item.Text, Item.Cursor) or Before(Item.Text, Item.Cursor)
                else
                    Item.Anchor = Command and LineEnd(Item.Text, Item.Cursor) or Word and WordAfter(Item.Text, Item.Cursor) or After(Item.Text, Item.Cursor)
                end
            end
            Replace(Item, "")
        elseif KeyName == "Left" or KeyName == "Right" then
            local Left = KeyName == "Left"
            if Command then Item.Cursor = Left and LineStart(Item.Text, Item.Cursor) or LineEnd(Item.Text, Item.Cursor)
            elseif Word then Item.Cursor = Left and WordBefore(Item.Text, Item.Cursor) or WordAfter(Item.Text, Item.Cursor)
            elseif not Shift and Item.Cursor ~= Item.Anchor then Item.Cursor = Left and math.min(Item.Cursor, Item.Anchor) or math.max(Item.Cursor, Item.Anchor)
            else Item.Cursor = Left and Before(Item.Text, Item.Cursor) or After(Item.Text, Item.Cursor) end
            if not Shift then Item.Anchor = Item.Cursor end
        elseif KeyName == "Home" or KeyName == "End" or Command and (KeyName == "Up" or KeyName == "Down") then
            Item.Cursor = (KeyName == "Home" or KeyName == "Up") and 0 or #Item.Text
            if not Shift then Item.Anchor = Item.Cursor end
        elseif KeyName == "Escape" then Item:ReleaseFocus(false)
        elseif KeyName == "Return" or KeyName == "Enter" then
            if Item.Multiline and not Primary then Replace(Item, "\n") else Item:ReleaseFocus(true) end
        end
    end
    local function Caret(Item)
        local Box = Bounds(Item)
        if not Box then return Item.Cursor end
        local X = Pointer.X - Box.X - Item.Padding + (Item.TextOffset or 0)
        local Start, Finish = 0, #Item.Text
        if Item.Multiline then
            local Row = math.max(0, math.floor((Pointer.Y - Box.Y - 3) / Item.TextSize))
            for _ = 1, Row do local Next = Item.Text:find("\n", Start + 1, true) if not Next then Start = #Item.Text break end Start = Next end
            Finish = (Item.Text:find("\n", Start + 1, true) or (#Item.Text + 1)) - 1
        end
        local Stops = {Start}
        local Offset = Start
        while Offset < Finish do Offset = After(Item.Text, Offset) Stops[#Stops + 1] = Offset end
        local Low, High = 1, #Stops
        while Low < High do
            local Middle = math.floor((Low + High) / 2)
            local Measure = Shape(Item, "HitMeasure", "Text", {Visible = false, Text = Item.Text:sub(Start + 1, Stops[Middle]), Font = Item.Font, Size = Item.TextSize})
            if Measure.TextBounds.X < X then Low = Middle + 1 else High = Middle end
        end
        return Stops[Low]
    end
    local function PointerDown(Button)
        local Hit
        for Index = #Items, 1, -1 do
            local Item = Items[Index]
            if Item.Active and Inside(Pointer, Bounds(Item)) and CanHit(Item) then Hit = Item break end
        end
        if Focus and Focus ~= Hit then Focus:ReleaseFocus(false) end
        if Button == 2 then
            Secondary = Hit
            if Hit then Hit.MouseButton2Down:Fire(Pointer) end
            return
        end
        Pressed = Hit
        if not Hit then return end
        Hit.MouseButton1Down:Fire()
        if Hit.Kind == "ScrollingFrame" and Hit.CanvasSize > Hit.Size.Y and Pointer.X >= Bounds(Hit).X + Hit.Size.X - 10 then
            ScrollDrag = Hit
        elseif Hit.Kind == "Slider" then
            local Box = Bounds(Hit)
            local Inset = Hit.SliderStyle == "Fluent" and 7 or 0
            Hit.Value = Hit.Min + math.clamp((Pointer.X - Box.X - Inset) / math.max(Box.Width - 2 * Inset, 1), 0, 1) * (Hit.Max - Hit.Min)
        elseif Hit.Kind == "TextBox" then
            Hit:CaptureFocus()
            Hit.Cursor = Caret(Hit)
            if not Keys.LeftShift and not Keys.RightShift then Hit.Anchor = Hit.Cursor end
            Hit.LastPointerX = Pointer.X
        elseif Hit.Draggable then
            local Target = Hit.DragTarget or Hit
            if Library.isui(Target) then Drag = {Item = Target, Offset = Pointer - Target.Position} end
        end
    end
    local function PointerUp(Button)
        if Button == 2 then
            local Item = Secondary
            Secondary = nil
            if Item and not Item.Destroyed then
                Item.MouseButton2Up:Fire(Pointer)
                if Inside(Pointer, Bounds(Item)) and CanHit(Item) then Item.MouseButton2Click:Fire(Pointer) end
            end
            return
        end
        local Item = Pressed
        Pressed, Drag, ScrollDrag = nil, nil, nil
        if Item and not Item.Destroyed then
            Item.MouseButton1Up:Fire()
            if Inside(Pointer, Bounds(Item)) and CanHit(Item) then
                if Item.Kind == "Checkbox" then Item.Value = not Item.Value end
                Item.MouseButton1Click:Fire()
            end
        end
    end
    local Virtual = {[8] = "Backspace", [9] = "Tab", [13] = "Return", [16] = "LeftShift", [17] = "LeftControl", [27] = "Escape", [32] = "Space", [35] = "End", [36] = "Home", [37] = "Left", [38] = "Up", [39] = "Right", [40] = "Down", [164] = "LeftAlt", [165] = "RightAlt", [45] = "Insert", [46] = "Delete", [160] = "LeftShift", [161] = "RightShift", [162] = "LeftControl", [163] = "RightControl"}
    for Code = 65, 90 do Virtual[Code] = string.char(Code) end
    local function Paint(Item)
        local Box = Bounds(Item)
        if not Box then for _, Entry in Item.Shapes do if Entry.Values.Visible ~= false then Entry.Object.Visible = false Entry.Values.Visible = false end end return end
        Item.AbsolutePosition = Vector2.new(Box.X, Box.Y)
        Item.AbsoluteSize = Item.Size
        local Layer = GetLayer(Item)
        local Base = {Visible = true, Position = Item.AbsolutePosition, Size = Item.Size, Filled = true, Color = Item.BackgroundColor3, Transparency = 1 - Item.BackgroundTransparency, ZIndex = Layer, Rounding = Item.CornerRadius}
        if HoverChain[Item] and not Item.Multiline then
            Base.Color = Item.HoverColor3 or Base.Color
            if Item.HoverTransparency ~= nil then Base.Transparency = 1 - Item.HoverTransparency end
        end
        local Switch = Item.Kind == "Checkbox" and Item.ToggleStyle == "Switch"
        local Slider = Item.Kind == "Slider" and Item.SliderStyle == "Fluent"
        if Item.Kind ~= "TextLabel" and Item.Kind ~= "ImageLabel" and not Switch and not Slider then Shape(Item, "Background", "Square", Base) end
        if Item.BorderSizePixel > 0 then
            Shape(Item, "Border", "Square", {Visible = true, Position = Item.AbsolutePosition, Size = Item.Size, Filled = false,
                Color = Item.BorderColor3, Transparency = 1 - Item.BorderTransparency, Thickness = Item.BorderSizePixel, Rounding = Item.CornerRadius, ZIndex = Layer + 1})
        elseif Item.Shapes.Border then
            Item.Shapes.Border.Object.Visible = false
            Item.Shapes.Border.Values.Visible = false
        end
        if Switch then
            local Width, Height = math.min(36, Box.Width), math.min(18, Box.Height)
            local X, Y = Box.X + (Box.Width - Width) / 2, Box.Y + (Box.Height - Height) / 2
            Shape(Item, "SwitchTrack", "Square", {Visible = true, Position = Vector2.new(X, Y), Size = Vector2.new(Width, Height), Filled = Item.Value,
                Color = Item.Value and Item.AccentColor3 or Item.TextColor3, Transparency = Item.Value and 1 or 0.5, Thickness = 1, Rounding = Height / 2, ZIndex = Layer})
            Shape(Item, "SwitchKnob", "Circle", {Visible = true, Position = Vector2.new(X + (Item.Value and Width - 9 or 9), Y + Height / 2),
                Radius = 5.5, NumSides = 24, Filled = true, Color = Item.Value and Item.KnobColor3 or Item.TextColor3, Transparency = Item.Value and 1 or 0.6, ZIndex = Layer + 1})
        elseif Slider then
            local Fraction = math.clamp((Item.Value - Item.Min) / math.max(0.00001, Item.Max - Item.Min), 0, 1)
            local Width = math.max(1, Box.Width - 14)
            local X, Y = Box.X + 7, Box.Y + Box.Height / 2
            Shape(Item, "SliderTrack", "Square", {Visible = true, Position = Vector2.new(X, Y - 2), Size = Vector2.new(Width, 4), Filled = true,
                Color = Item.TextColor3, Transparency = 0.35, Rounding = 2, ZIndex = Layer})
            Shape(Item, "SliderFill", "Square", {Visible = true, Position = Vector2.new(X, Y - 2), Size = Vector2.new(Width * Fraction, 4), Filled = true,
                Color = Item.AccentColor3, Transparency = 1, Rounding = 2, ZIndex = Layer + 1})
            Shape(Item, "SliderKnob", "Circle", {Visible = true, Position = Vector2.new(X + Width * Fraction, Y), Radius = 6, NumSides = 24,
                Filled = true, Color = Item.AccentColor3, Transparency = 1, ZIndex = Layer + 2})
        elseif Item.Kind == "ScrollingFrame" then
            local Visible = Item.CanvasSize > Box.Height and Item.ScrollBarThickness > 0
            local Height = math.max(18, Box.Height * Box.Height / math.max(Item.CanvasSize, 1))
            local Offset = Item.ScrollOffset / math.max(1, Item.CanvasSize - Box.Height) * (Box.Height - Height)
            Shape(Item, "ScrollBar", "Square", {Visible = Visible, Position = Vector2.new(Box.X + Box.Width - Item.ScrollBarThickness, Box.Y + Offset),
                Size = Vector2.new(Item.ScrollBarThickness, Height), Filled = true, Color = Item.TextColor3, Transparency = 0.35, Rounding = 2, ZIndex = Layer + 10})
        end
        if Item.Kind == "ImageLabel" then
            Shape(Item, "Image", "Image", {Visible = true, Position = Item.AbsolutePosition, Size = Item.Size, Data = Item.Image, Transparency = 1 - Item.BackgroundTransparency, ZIndex = Layer})
        elseif Item.Kind ~= "Frame" and Item.Kind ~= "ScrollingFrame" then
            local Text = Item.Text
            local Offset = 0
            if Item.Kind == "TextBox" and not Item.Multiline then
                local Measure = Shape(Item, "CaretMeasure", "Text", {Visible = false, Text = Text:sub(1, Item.Cursor), Font = Item.Font, Size = Item.TextSize})
                Offset = Focus == Item and (Item.TextOffset or 0) or 0
                if Measure.TextBounds.X - Offset > Box.Width - 2 * Item.Padding then Offset = math.max(0, Measure.TextBounds.X - Box.Width + 2 * Item.Padding)
                elseif Measure.TextBounds.X < Offset then Offset = Measure.TextBounds.X end
                Item.TextOffset = Offset
            end
            if Item.Kind == "Checkbox" and not Switch then Text = (Item.Value and "[x] " or "[ ] ") .. Text end
            if Item.Kind == "Slider" and not Slider then Text ..= " " .. string.format("%.2f", Item.Value) end
            local Empty = Text == "" and Focus ~= Item
            if Empty then Text = Item.PlaceholderText end
            local TextX = Box.X + Item.Padding - Offset
            if Item.TextXAlignment ~= "Left" then
                local Width = Shape(Item, "AlignMeasure", "Text", {Visible = false, Text = Text, Font = Item.Font, Size = Item.TextSize}).TextBounds.X
                TextX = Item.TextXAlignment == "Center" and Box.X + (Box.Width - Width) / 2 or Box.X + Box.Width - Width - Item.Padding
            end
            local Label = Shape(Item, "Text", "Text", {Visible = true, Text = Text, Position = Vector2.new(TextX, Box.Y + (Item.Multiline and 3 or math.max(0, (Box.Height - Item.TextSize) / 2))), Size = Item.TextSize,
                Color = Empty and Item.PlaceholderColor3 or Item.TextColor3, Transparency = 1 - Item.TextTransparency, Font = Item.Font, ZIndex = Layer + 2, Outline = false})
            for Key, Entry in Item.Shapes do
                if Key == "Caret" or Key:sub(1, 9) == "Selection" then Entry.Object.Visible = false Entry.Values.Visible = false end
            end
            if Focus == Item and Item.Multiline then
                local First, Last = Selection(Item)
                local Start, Row, Used = 0, 0, 0
                local Clip = Item.Parent and Bounds(Item.Parent) or Box
                for Line in (Item.Text .. "\n"):gmatch("(.-)\n") do
                    local Finish = Start + #Line
                    local Y = Box.Y + 3 + Row * Item.TextSize
                    if Y + Item.TextSize >= Clip.Y and Y <= Clip.Y + Clip.Height then
                        local function Measure(Value)
                            return Shape(Item, "LineMeasure", "Text", {Visible = false, Text = Value, Font = Item.Font, Size = Item.TextSize}).TextBounds.X
                        end
                        if First < Finish + 1 and Last > Start then
                            local Left, Right = math.max(First, Start), math.min(Last, Finish)
                            local X = Box.X + Item.Padding + Measure(Item.Text:sub(Start + 1, Left))
                            Used += 1
                            Shape(Item, "Selection" .. Used, "Square", {Visible = true, Filled = true, Position = Vector2.new(X, Y), Size = Vector2.new(math.max(2, Measure(Item.Text:sub(Left + 1, Right))), Item.TextSize), Color = Color3.fromRGB(70, 100, 135), Transparency = 0.45, ZIndex = Layer})
                        end
                        if Item.Cursor >= Start and Item.Cursor <= Finish and math.floor((Clock and Clock() or Elapsed) * 2) % 2 == 0 then
                            local X = Box.X + Item.Padding + Measure(Item.Text:sub(Start + 1, Item.Cursor))
                            Shape(Item, "Caret", "Line", {Visible = true, From = Vector2.new(X, Y), To = Vector2.new(X, Y + Item.TextSize), Thickness = 1, Color = Item.TextColor3, Transparency = 1, ZIndex = Layer + 2})
                        end
                    end
                    if Y > Clip.Y + Clip.Height then break end
                    Start, Row = Finish + 1, Row + 1
                end
            elseif Focus == Item and Item.Cursor ~= Item.Anchor then
                local First, Last = Selection(Item)
                local Measure = Shape(Item, "Measure", "Text", {Visible = false, Text = Item.Text:sub(1, First), Font = Item.Font, Size = Item.TextSize})
                local SelectionOffset = Measure.TextBounds.X - Offset
                local Selected = Shape(Item, "MeasureSelection", "Text", {Visible = false, Text = Item.Text:sub(First + 1, Last), Font = Item.Font, Size = Item.TextSize})
                Shape(Item, "Selection", "Square", {Visible = true, Filled = true, Position = Vector2.new(Box.X + Item.Padding + SelectionOffset, Box.Y + 2), Size = Vector2.new(math.max(1, Selected.TextBounds.X), math.max(1, Box.Height - 4)), Color = Color3.fromRGB(70, 100, 135), Transparency = 0.45, ZIndex = Layer})
            end
            if Focus == Item and not Item.Multiline and math.floor((Clock and Clock() or Elapsed) * 2) % 2 == 0 then
                local Width = Shape(Item, "CaretMeasure", "Text", {Visible = false, Text = Item.Text:sub(1, Item.Cursor), Font = Item.Font, Size = Item.TextSize}).TextBounds.X
                local X, Y = Box.X + Item.Padding + Width - Offset, Box.Y + math.max(0, (Box.Height - Item.TextSize) / 2)
                Shape(Item, "Caret", "Line", {Visible = true, From = Vector2.new(X, Y), To = Vector2.new(X, Y + Item.TextSize), Thickness = 1, Color = Item.TextColor3, Transparency = 1, ZIndex = Layer + 2})
            end
        end
    end
    function Library.step()
        Elapsed += 1 / 60
        if Dirty then table.sort(Items, function(A, B) local Left, Right = GetLayer(A), GetLayer(B) return Left == Right and A.Id < B.Id or Left < Right end) Dirty = false end
        local IsActive = Services and Services.IsActive or iswindowactive
        local Active = type(IsActive) ~= "function" or IsActive()
        if type(input) == "table" and type(input.isinterfaceactive) == "function" and input.isinterfaceactive() then Active = false end
        if not Active and Focus then Focus:ReleaseFocus(false) end
        if Focus and not Bounds(Focus) then Focus:ReleaseFocus(false) end
        if not Active then table.clear(Keys) Pressed, Drag, ScrollDrag = nil, nil, nil end
        if Context then
            local Position = Context:getpointer()
            if Position and (Position.X ~= Pointer.X or Position.Y ~= Pointer.Y) then Pointer = Vector2.new(Position.X, Position.Y) end
            for _, Event in Context:getevents() do
                if Event.Type == "KeyDown" or Event.Type == "KeyUp" then
                    for _, Modifier in {"Command", "Control", "Shift", "Alt"} do
                        if Event[Modifier] ~= nil then Keys[Modifier] = Event[Modifier] end
                    end
                end
                if Event.Type == "KeyDown" then local KeyName = Virtual[Event.Code] or "Unknown" Keys[KeyName] = true Key(KeyName, Event.Repeat)
                elseif Event.Type == "KeyUp" then Keys[Virtual[Event.Code] or "Unknown"] = nil
                elseif Event.Type == "Text" or Event.Type == "Paste" then
                    local Text = Event.Text
                    if Event.Type == "Paste" and type(Context.getpaste) == "function" then Text = Context:getpaste(Event.Code) end
                    if Focus and Text ~= "" then Replace(Focus, Text) end
                elseif Event.Type == "MouseDown" then
                    if Event.X and Event.Y then Pointer = Vector2.new(Event.X, Event.Y) end
                    PointerDown(Event.Code)
                elseif Event.Type == "MouseUp" then
                    if Event.X and Event.Y then Pointer = Vector2.new(Event.X, Event.Y) end
                    PointerUp(Event.Code)
                elseif Event.Type == "Wheel" then for Index = #Items, 1, -1 do local Item = Items[Index] if Item.Kind == "ScrollingFrame" and Inside(Pointer, Bounds(Item)) then Item.ScrollOffset = math.clamp(Item.ScrollOffset - Event.Delta * 30, 0, math.max(0, Item.CanvasSize - Item.Size.Y)) break end end end
            end
        elseif Input then
            local Ok, Position = pcall(function() return Input:GetMouseLocation() end)
            if Ok then Pointer = Position end
        end
        if Drag then Drag.Item.Position = Pointer - Drag.Offset end
        if ScrollDrag then
            local Box = Bounds(ScrollDrag)
            if Box then
                local Height = math.max(18, Box.Height * Box.Height / ScrollDrag.CanvasSize)
                ScrollDrag.ScrollOffset = math.clamp((Pointer.Y - Box.Y - Height / 2) / math.max(1, Box.Height - Height), 0, 1) * math.max(0, ScrollDrag.CanvasSize - Box.Height)
            end
        end
        if Pressed and Pressed.Kind == "TextBox" and (Pressed.LastPointerX ~= Pointer.X or Pressed.LastPointerY ~= Pointer.Y) then Pressed.Cursor = Caret(Pressed) Pressed.LastPointerX, Pressed.LastPointerY = Pointer.X, Pointer.Y end
        if Pressed and Pressed.Kind == "Slider" then
            local Box = Bounds(Pressed)
            if Box then
                local Inset = Pressed.SliderStyle == "Fluent" and 7 or 0
                Pressed.Value = Pressed.Min + math.clamp((Pointer.X - Box.X - Inset) / math.max(Box.Width - 2 * Inset, 1), 0, 1) * (Pressed.Max - Pressed.Min)
            end
        end
        local Blink = Focus and math.floor((Clock and Clock() or Elapsed) * 2) or -1
        if Blink ~= LastBlink then LastBlink = Blink PaintDirty = true end
        local Hovered = HoveredItem
        if Pointer.X ~= LastHitX or Pointer.Y ~= LastHitY or LayoutVersion ~= LastHitVersion or Active ~= LastHitActive then
            Hovered = nil
            if Active then
                for Index = #Items, 1, -1 do
                    local Item = Items[Index]
                    if not Item.Destroyed and Item.Active and Inside(Pointer, Bounds(Item)) and CanHit(Item) then Hovered = Item break end
                end
            end
            LastHitX, LastHitY, LastHitVersion, LastHitActive = Pointer.X, Pointer.Y, LayoutVersion, Active
        end
        if Hovered ~= HoveredItem then
            HoveredItem = Hovered
            local Previous = HoverChain
            HoverChain = {}
            local Item = Hovered
            while Item do HoverChain[Item] = true Item = Item.Parent end
            for Old in Previous do if not HoverChain[Old] and not Old.Destroyed then Old.MouseLeave:Fire() end end
            for New in HoverChain do if not Previous[New] and not New.Destroyed then New.MouseEnter:Fire() end end
            PaintDirty = true
        end
        local Repaint = PaintDirty
        PaintDirty = false
        if Repaint then for _, Item in Items do if not Item.Destroyed then Paint(Item) end end end
        if Context then
            local Root = Hovered
            while Root and Root.Parent do Root = Root.Parent end
            local Box = Root and Bounds(Root)
            if Box then Context:setregion(Box.X, Box.Y, Box.Width, Box.Height) end
            Context:setcapture(Active and Focus ~= nil, Active and (Box ~= nil or Pressed ~= nil))
        end
        for Index = #Items, 1, -1 do if Items[Index].Destroyed then table.remove(Items, Index) end end
        if #Items == 0 then
            Running = false
            if Context then Context:destroy() Context = nil end
            for _, Connection in Connections do Connection:Disconnect() end
            table.clear(Connections)
        end
    end
    local function Start()
        if Running then return end
        Task = task or {spawn = spawn, wait = wait}
        Running = true
        Input = Services and Services.Input or game:GetService("UserInputService")
        if type(input) == "table" and type(input.createcontext) == "function" then Context = input.createcontext() end
        Connections[#Connections + 1] = Input.InputBegan:Connect(function(Event)
            local KeyName, Kind = Name(Event.KeyCode), Name(Event.UserInputType)
            if not Context then
                Keys[KeyName] = true
                if Kind == "MouseButton1" or Kind == "MouseButton2" then PointerDown(Kind == "MouseButton2" and 2 or 1) else
                    Key(KeyName)
                    local Control = Keys.LeftControl or Keys.RightControl
                    if Focus and not Control then
                        local Character = #KeyName == 1 and KeyName:lower() or KeyName == "Space" and " " or nil
                        if Character then Replace(Focus, (Keys.LeftShift or Keys.RightShift) and Character:upper() or Character) end
                    elseif Focus and Control and KeyName == "V" and type(getclipboard) == "function" then Replace(Focus, getclipboard()) end
                end
            end
        end)
        Connections[#Connections + 1] = Input.InputEnded:Connect(function(Event)
            Keys[Name(Event.KeyCode)] = nil
            if not Context then
                local Kind = Name(Event.UserInputType)
                if Kind == "MouseButton1" or Kind == "MouseButton2" then PointerUp(Kind == "MouseButton2" and 2 or 1) end
            end
        end)
        if not Services or Services.Automatic ~= false then
            Task.spawn(function()
                while Running do
                    Task.wait((type(iswindowactive) ~= "function" or iswindowactive()) and 0 or 0.1)
                    local Ok, Error = pcall(Library.step)
                    if not Ok then warn(Error) Running = false Library.destroyui() end
                end
            end)
        end
    end
    function Library.create(Kind, Properties)
        assert(Kinds[Kind], "Unsupported UI control: " .. tostring(Kind))
        if #Items >= 512 then
            for Index = #Items, 1, -1 do if Items[Index].Destroyed then table.remove(Items, Index) end end
        end
        assert(#Items < 512, "UI control limit reached")
        NextId += 1
        local Data = {Kind = Kind, Id = NextId, Position = Vector2.new(0, 0), Size = Vector2.new(200, 30), Visible = true, Active = true, ZIndex = 1000,
            BackgroundColor3 = Color3.fromRGB(28, 28, 30), BackgroundTransparency = 0, TextColor3 = Color3.fromRGB(235, 235, 238), PlaceholderColor3 = Color3.fromRGB(130, 130, 138),
            Text = "", PlaceholderText = "", TextSize = 16, Font = Drawing.Fonts.Monospace or 3, Padding = 6, MaxLength = 65536, TextEditable = true, ClearTextOnFocus = false,
            Cursor = 0, Anchor = 0, Value = false, Min = 0, Max = 100, Multiline = false, Draggable = false, ClipsDescendants = false, ScrollOffset = 0, CanvasSize = 0, CornerRadius = 0,
            TextXAlignment = "Left", TextTransparency = 0, BorderSizePixel = 0, BorderColor3 = Color3.fromRGB(70, 70, 75), BorderTransparency = 0,
            AccentColor3 = Color3.fromRGB(96, 205, 255), KnobColor3 = Color3.fromRGB(20, 25, 32), ScrollBarThickness = 3,
            Shapes = {}, ChangedEvents = {}, UndoItems = {}, RedoItems = {}, Destroyed = false}
        if Kind == "Slider" then Data.Value = 0 end
        for _, Event in {"Focused", "FocusLost", "TextChanged", "Changed", "InputBegan", "MouseEnter", "MouseLeave", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up"} do Data[Event] = Signal() end
        local Object
        Object = setmetatable({}, {__index = function(_, Key) return Methods[Key] or Data[Key] end, __newindex = function(_, Key, Value)
            assert(not Data.Destroyed or Key == "Destroyed", "UI control was destroyed")
            if Key == "Parent" then
                local Parent, Depth = Value, 0
                while Parent do assert(Parent ~= Object and Library.isui(Parent) and Depth < 64, "Invalid UI parent") Parent = Parent.Parent Depth += 1 end
            elseif Key == "Text" then assert(type(Value) == "string" and #Value <= 65536, "Invalid text")
            elseif Key == "Position" or Key == "Size" then assert(Value and type(Value.X) == "number" and type(Value.Y) == "number" and Value.X == Value.X and Value.Y == Value.Y and math.abs(Value.X) <= 65536 and math.abs(Value.Y) <= 65536, "Invalid UI bounds")
            elseif Key == "MaxLength" then assert(type(Value) == "number" and Value >= 0 and Value <= 65536, "Invalid text limit") end
            if Key == "ZIndex" or Key == "TextSize" or Key == "Padding" or Key == "Font" or Key == "Cursor" or Key == "Anchor" or Key == "CanvasSize" or Key == "ScrollOffset" or Key == "Min" or Key == "Max" or Key == "CornerRadius" or Key == "BorderSizePixel" or Key == "ScrollBarThickness" then
                assert(type(Value) == "number" and Value == Value and math.abs(Value) <= 65536, "Invalid UI number")
            elseif Key == "BackgroundTransparency" or Key == "HoverTransparency" or Key == "BorderTransparency" or Key == "TextTransparency" then assert(type(Value) == "number" and Value >= 0 and Value <= 1, "Invalid transparency")
            elseif Key == "TextColor3" or Key == "BackgroundColor3" or Key == "PlaceholderColor3" or Key == "HoverColor3" or Key == "BorderColor3" or Key == "AccentColor3" or Key == "KnobColor3" then assert(Value and type(Value.R) == "number" and type(Value.G) == "number" and type(Value.B) == "number", "Invalid UI color") end
            if Key == "TextSize" then assert(Value >= 1 and Value <= 10000, "Invalid text size") end
            if Key == "Value" and Data.Kind == "Slider" then assert(type(Value) == "number" and Value == Value and math.abs(Value) <= 65536, "Invalid slider value") end
            if Data[Key] == Value then return end
            if (Key == "Position" or Key == "Size") and Data[Key] and Data[Key].X == Value.X and Data[Key].Y == Value.Y then return end
            if Key == "Position" or Key == "Size" or Key == "Visible" or Key == "Parent" or Key == "ScrollOffset" or Key == "Destroyed" or Key == "Active" or Key == "ZIndex" or Key == "ClipsDescendants" then LayoutVersion += 1 end
            if Key ~= "AbsolutePosition" and Key ~= "AbsoluteSize" and Key ~= "TextOffset" and Key ~= "LastPointerX" then PaintDirty = true end
            Data[Key] = Value
            if Key == "Text" then Data.Cursor = math.min(Data.Cursor, #Value) Data.Anchor = math.min(Data.Anchor, #Value) Data.TextChanged:Fire(Value) end
            if Key == "ZIndex" or Key == "Parent" then Dirty = true end
            if Data.ChangedEvents[Key] then Data.ChangedEvents[Key]:Fire() end
            Data.Changed:Fire(Key)
        end})
        if Properties then for Key, Value in Properties do Object[Key] = Value end end
        Items[#Items + 1] = Object
        LayoutVersion += 1
        Dirty = true
        PaintDirty = true
        Start()
        return Object
    end
    function Library.isui(Object) for _, Item in Items do if Item == Object then return not Item.Destroyed end end return false end
    function Library.getfocusedtextbox() return Focus end
    function Library.getpointer() return Pointer end
    function Library.newcontext() return CreateLibrary(Drawing, Services) end
    function Library.destroyui() for _, Item in Items do Item:Destroy() end Library.step() end
    return Library
end
return CreateLibrary

end)()
local Runtime = (function()
local Runtime = {NeedsProjection = true, Tick = 0, Foreground = true, Order = {}, OrderDirty = false, Alive = true, Objects = {}, Connections = {}, Jobs = {}, Bindings = {}, Elapsed = 0, Errors = {}, Queue = {}}
local NativePlayers = game:GetService("Players")
local NativeInput = game:GetService("UserInputService")
local NativeColor = Color3
local NativeCamera = function() return workspace.CurrentCamera end
local Clock = os and os.clock
local NativeDraw = Drawing
local UiLibrary
function Runtime.Control(Kind, Properties)
    for _, Create in {NativeDraw.create, NativeDraw.new} do
        if type(Create) == "function" then
            local Ok, Control = pcall(Create, Kind, Properties)
            if Ok and Control then
                local Compatible = pcall(function()
                    for Name, Value in Properties or {} do Control[Name] = Value end
                    if Kind == "TextBox" then assert(Control.FocusLost and Control.InputBegan and type(Control.CaptureFocus) == "function" and type(Control.ReleaseFocus) == "function" and type(Control.IsFocused) == "function")
                    elseif Kind == "Button" or Kind == "TextButton" then assert(Control.MouseButton1Click) end
                end)
                if Compatible then Runtime.Objects[#Runtime.Objects + 1] = Control return Control end
                pcall(function() Control:Destroy() end)
            end
        end
    end
    UiLibrary = UiLibrary or CreateUiLibrary(NativeDraw)
    local Control = UiLibrary.create(Kind, Properties)
    Runtime.Objects[#Runtime.Objects + 1] = Control
    return Control
end
local InputState = {Buttons = {}, Keys = {}, Position = Vector2.new(0, 0)}
local KeyEnums = {}
for _, Key in Enum.KeyCode:GetEnumItems() do KeyEnums[Key.Name] = Key end
Runtime.Keys = KeyEnums
local function Read(Object, Name)
    local Success, Value = pcall(function() return Object[Name] end)
    if Success then return Value end
    return nil
end

function Runtime.Time()
    return Clock and Clock() or Runtime.Elapsed
end

function Runtime.Report(Name, Message)
    local Text = tostring(Message)
    if Runtime.Errors[Name] ~= Text then
        Runtime.Errors[Name] = Text
        warn(Name .. ": " .. Text)
    end
end

function Runtime.Try(Name, Callback, ...)
    local Values = table.pack(pcall(Callback, ...))
    if not Values[1] then Runtime.Report(Name, Values[2]) end
    return table.unpack(Values, 1, Values.n)
end

function Runtime.Defer(Callback, ...)
    if #Runtime.Queue >= 256 then return false end
    Runtime.Queue[#Runtime.Queue + 1] = {Callback = Callback, Arguments = table.pack(...)}
    return true
end

function Runtime.Signal()
    local Signal = {Listeners = {}}
    function Signal:Connect(Callback)
        assert(type(Callback) == "function", "Callback expected")
        local Connection = {Connected = true, Callback = Callback}
        function Connection:Disconnect() self.Connected = false end
        self.Listeners[#self.Listeners + 1] = Connection
        return Connection
    end
    function Signal:Once(Callback)
        local Connection
        Connection = self:Connect(function(...)
            Connection:Disconnect()
            Callback(...)
        end)
        return Connection
    end
    function Signal:Fire(...)
        local Arguments = table.pack(...)
        for Index = #self.Listeners, 1, -1 do
            local Connection = self.Listeners[Index]
            if not Connection.Connected then table.remove(self.Listeners, Index)
            else Runtime.Defer(function() if Connection.Connected then Connection.Callback(table.unpack(Arguments, 1, Arguments.n)) end end) end
        end
    end
    function Signal:Wait()
        local Received, Arguments = false, nil
        local Connection = self:Once(function(...) Arguments = table.pack(...) Received = true end)
        while Runtime.Alive and not Received do task.wait() end
        Connection:Disconnect()
        if Arguments then return table.unpack(Arguments, 1, Arguments.n) end
    end
    return Signal
end

function Runtime.Connect(Signal, Callback)
    assert(Signal and type(Signal.Connect) == "function", "Signal unavailable")
    local Connection = Signal:Connect(Callback)
    Runtime.Connections[#Runtime.Connections + 1] = Connection
    return Connection
end

function Runtime.Drawing(Type, Properties)
    assert(Runtime.Alive, "Script stopped")
    local Object = NativeDraw.new(Type)
    Runtime.Objects[#Runtime.Objects + 1] = Object
    if Properties then
        for Key, Value in Properties do Object[Key] = Value end
    end
    return Object
end

function Runtime.Stop()
    if not Runtime.Alive then return end
    Runtime.Alive = false
    if Runtime.InputContext then pcall(function() Runtime.InputContext:destroy() end) end
    for _, Connection in Runtime.Connections do pcall(function() Connection:Disconnect() end) end
    for _, Object in Runtime.Objects do pcall(function() Object:Remove() end) end
    for _, Job in Runtime.Jobs do if Job.Cancel then pcall(Job.Cancel) end end
    table.clear(Runtime.Queue)
    table.clear(Runtime.Bindings)
    table.clear(Runtime.Objects)
end

function Runtime.Step(Name, Priority, Callback)
    local Binding = {Name = Name, Priority = Priority, Callback = Callback}
    Runtime.Bindings[Name] = Binding
    Runtime.Order[#Runtime.Order + 1] = Binding
    Runtime.OrderDirty = true
end

local function KeyName(Item)
    if type(Item) == "string" then return Item:match("([^%.]+)$") end
    local Name = Read(Item, "Name")
    return Name or tostring(Item):match("([^%.]+)$")
end
Runtime.KeyName = KeyName

Runtime.Input = {
    InputBegan = Runtime.Signal(), InputEnded = Runtime.Signal(), InputChanged = Runtime.Signal(),
    TextInput = Runtime.Signal(),
    PasteInput = Runtime.Signal(),
    KeyboardEnabled = true, MouseEnabled = true,
}
function Runtime.Input:IsKeyDown(Key)
    if Runtime.InterfaceActive then return false end
    if not Runtime.Foreground then return false end
    local Success, Value = pcall(function() return NativeInput:IsKeyDown(Key) end)
    return Success and Value == true or InputState.Keys[KeyName(Key)] == true
end
function Runtime.Input:IsMouseButtonPressed(Button)
    if Runtime.InterfaceActive then return false end
    return InputState.Buttons[Button] == true
end
function Runtime.Input:GetMouseLocation()
    if Runtime.PointerTick == Runtime.Tick then return InputState.Position end
    Runtime.PointerTick = Runtime.Tick
    if Runtime.InputContext then
        local Value = Runtime.InputContext:getpointer()
        if Value then InputState.Position = Vector2.new(Value.X, Value.Y) return InputState.Position end
    end
    local Success, Value = pcall(function() return NativeInput:GetMouseLocation() end)
    if Success and Value then InputState.Position = Vector2.new(Value.X, Value.Y) end
    return InputState.Position
end
function Runtime.Input:GetFocusedTextBox() return nil end

local function Deliver(Input, Processed, Began)
    local Kind = KeyName(Read(Input, "UserInputType"))
    local Key = KeyName(Read(Input, "KeyCode"))
    if Key then InputState.Keys[Key] = Began end
    if Kind == "MouseButton1" then InputState.Buttons[1] = Began end
    if Kind == "MouseButton2" then InputState.Buttons[2] = Began end
    if Kind == "MouseButton3" then InputState.Buttons[3] = Began end
    Runtime.Defer(function()
        if Runtime.InterfaceActive or type(iswindowactive) == "function" and not iswindowactive() then return end
        local Signal = Began and Runtime.Input.InputBegan or Runtime.Input.InputEnded
        Signal:Fire(Input, Processed)
    end)
end
Runtime.Connect(NativeInput.InputBegan, function(Input, Processed) Deliver(Input, Processed, true) end)
Runtime.Connect(NativeInput.InputEnded, function(Input, Processed) Deliver(Input, Processed, false) end)
if NativeInput.InputChanged and type(NativeInput.InputChanged.Connect) == "function" then
    Runtime.Connect(NativeInput.InputChanged, function(Input, Processed)
        Runtime.Defer(function() Runtime.Input.InputChanged:Fire(Input, Processed) end)
    end)
end

local InputLibrary
pcall(function() InputLibrary = input end)
if type(InputLibrary) == "table" and type(InputLibrary.createcontext) == "function" then Runtime.InputContext = InputLibrary.createcontext() end
function Runtime.Capture(Keyboard, Region)
    if not Runtime.InputContext then return false end
    if Runtime.InterfaceActive then Keyboard = false Region = nil end
    if Region then Runtime.InputContext:setregion(Region.X, Region.Y, Region.Width, Region.Height) end
    Runtime.InputContext:setcapture(Keyboard == true, Region ~= nil)
    return true
end
local VirtualKeys = {[8] = "Backspace", [9] = "Tab", [13] = "Return", [16] = "LeftShift", [17] = "LeftControl", [18] = "LeftAlt", [27] = "Escape", [32] = "Space",
    [33] = "PageUp", [34] = "PageDown", [35] = "End", [36] = "Home", [37] = "Left", [38] = "Up", [39] = "Right", [40] = "Down", [46] = "Delete",
    [160] = "LeftShift", [161] = "RightShift", [162] = "LeftControl", [163] = "RightControl", [186] = "Semicolon", [187] = "Equals", [188] = "Comma", [189] = "Minus",
    [190] = "Period", [191] = "Slash", [192] = "Backquote", [219] = "LeftBracket", [220] = "BackSlash", [221] = "RightBracket", [222] = "Quote"}
for Code = 65, 90 do VirtualKeys[Code] = string.char(Code) end
for Index, Name in {"Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"} do VirtualKeys[47 + Index] = Name end
for Index = 1, 24 do VirtualKeys[111 + Index] = "F" .. Index end
local function CapturedEvents()
    if not Runtime.InputContext then return end
    Runtime.InterfaceActive = type(InputLibrary.isinterfaceactive) == "function" and InputLibrary.isinterfaceactive()
    if Runtime.InterfaceActive then
        table.clear(InputState.Keys)
        table.clear(InputState.Buttons)
        Runtime.InputContext:getevents()
        return
    end
    if type(iswindowactive) == "function" and not iswindowactive() then
        table.clear(InputState.Keys)
        table.clear(InputState.Buttons)
        Runtime.InputContext:getevents()
        return
    end
    for _, Event in Runtime.InputContext:getevents() do
        if Event.Type == "Text" then Runtime.Input.TextInput:Fire(Event.Text)
        elseif Event.Type == "Paste" then Runtime.Input.PasteInput:Fire(Event.Text)
        elseif Event.Type == "KeyDown" or Event.Type == "KeyUp" then
            local Name = VirtualKeys[Event.Code] or "Unknown"
            local Down = Event.Type == "KeyDown"
            InputState.Keys[Name] = Down
            local Signal = Down and Runtime.Input.InputBegan or Runtime.Input.InputEnded
            Signal:Fire({KeyCode = KeyEnums[Name] or {Name = Name}, UserInputType = {Name = "Keyboard"}, Captured = true, Repeated = Event.Repeat}, false)
        elseif Event.Type == "MouseDown" or Event.Type == "MouseUp" then
            local Down = Event.Type == "MouseDown"
            InputState.Buttons[Event.Code] = Down
            local Signal = Down and Runtime.Input.InputBegan or Runtime.Input.InputEnded
            Signal:Fire({KeyCode = Enum.KeyCode.Unknown, UserInputType = {Name = "MouseButton" .. Event.Code}, Captured = true}, false)
        elseif Event.Type == "Wheel" then Runtime.Input.InputChanged:Fire({UserInputType = {Name = "MouseWheel"}, Position = {Z = Event.Delta}, Captured = true}, false)
        elseif Event.Type == "MouseMove" then Runtime.Input.InputChanged:Fire({UserInputType = {Name = "MouseMovement"}, Position = InputState.Position, Captured = true}, false) end
    end
end

local function Dot(A, B) return A.X * B.X + A.Y * B.Y + A.Z * B.Z end
local function Unit(Value)
    local Length = math.sqrt(Dot(Value, Value))
    if Length < 0.000001 then return nil end
    return rawget(Vector3, "new")(Value.X / Length, Value.Y / Length, Value.Z / Length)
end
Runtime.Dot = Dot
Runtime.Unit = Unit

function Runtime.Projection()
    local Camera = NativeCamera()
    assert(Camera and Camera.ViewportPointToRay, "Camera projection unavailable")
    local Size = Camera.ViewportSize
    assert(Size and Size.X > 0 and Size.Y > 0, "Viewport unavailable")
    local Frame = Camera.CFrame
    local Forward, Right, Up = Frame.LookVector, Frame.RightVector, Frame.UpVector
    local Edge = Camera:ViewportPointToRay(Size.X, Size.Y / 2)
    local TangentX = Dot(Edge.Direction, Right) / Dot(Edge.Direction, Forward)
    local Calibration = Runtime.Calibration
    if not Calibration or Calibration.Width ~= Size.X or Calibration.Height ~= Size.Y then
        local Top = Camera:ViewportPointToRay(Size.X / 2, 0)
        Calibration = {Width = Size.X, Height = Size.Y, Aspect = Dot(Top.Direction, Up) / Dot(Top.Direction, Forward) / TangentX}
        Runtime.Calibration = Calibration
    end
    local TangentY = TangentX * Calibration.Aspect
    assert(TangentX > 0 and TangentY > 0, "Invalid camera projection")
    return {Origin = Frame.Position, Forward = Forward, Right = Right, Up = Up, Width = Size.X, Height = Size.Y,
        ScaleX = Size.X / (2 * TangentX), ScaleY = Size.Y / (2 * TangentY)}
end

Runtime.View = nil
function Runtime.Project(Position)
    local View = Runtime.View or Runtime.Projection()
    local Difference = Position - View.Origin
    local Depth = Dot(Difference, View.Forward)
    local Divisor = math.abs(Depth) < 0.000001 and 0.000001 or Depth
    local X = View.Width / 2 + Dot(Difference, View.Right) * View.ScaleX / Divisor
    local Y = View.Height / 2 - Dot(Difference, View.Up) * View.ScaleY / Divisor
    local Visible = Depth > 0 and X >= 0 and X <= View.Width and Y >= 0 and Y <= View.Height
    if X ~= X or Y ~= Y or Depth ~= Depth then return rawget(Vector3, "new")(0, 0, -1), false end
    X = math.clamp(X, -View.Width * 4, View.Width * 5)
    Y = math.clamp(Y, -View.Height * 4, View.Height * 5)
    return rawget(Vector3, "new")(X, Y, Depth), Visible
end

function Runtime.ScreenEdge(Position)
    local View = Runtime.View or Runtime.Projection()
    local HalfX, HalfY = View.Width / 2, View.Height / 2
    local X, Y = Position.X - HalfX, Position.Y - HalfY
    if X ~= X or Y ~= Y or math.abs(X) == math.huge or math.abs(Y) == math.huge then
        return Vector2.new(HalfX, HalfY)
    end
    local Scale = math.max(1, math.abs(X) / math.max(1, HalfX), math.abs(Y) / math.max(1, HalfY))
    return Vector2.new(HalfX + X / Scale, HalfY + Y / Scale)
end

local CameraSignals = {}
Runtime.Camera = setmetatable({}, {
    __index = function(_, Name)
        if Name == "WorldToViewportPoint" or Name == "WorldToScreenPoint" then return function(_, Position) return Runtime.Project(Position) end end
        if Name == "Parent" then return workspace end
        if Name == "GetPropertyChangedSignal" then return function(_, Property)
            CameraSignals[Property] = CameraSignals[Property] or Runtime.Signal()
            return CameraSignals[Property]
        end end
        return NativeCamera()[Name]
    end,
    __newindex = function() error("Vortex does not expose writable camera controls") end,
})

local RootCache = setmetatable({}, {__mode = "k"})
local CharacterCache = setmetatable({}, {__mode = "k"})
local PlayerCache = setmetatable({}, {__mode = "k"})
local function AdaptRoot(Root)
    if not Root then return nil end
    if RootCache[Root] then return RootCache[Root] end
    local Proxy = setmetatable({_char = rawget(Root, "_char"), _id = rawget(Root, "_id")}, {
        __index = function(_, Name)
            if Name == "GetRenderCFrame" then return function() return Root.CFrame end end
            return Root[Name]
        end,
        __newindex = function(_, Name, Value) Root[Name] = Value end,
    })
    RootCache[Root] = Proxy
    return Proxy
end
function Runtime.Character(Character)
    if not Character then return nil end
    if CharacterCache[Character] then return CharacterCache[Character] end
    local function Child(Name)
        if Name == "Humanoid" then return Character.Humanoid end
        if Name == "HumanoidRootPart" then return AdaptRoot(Character.HumanoidRootPart) end
        if Name == "Head" then return Character:FindFirstChild("Head") or Character:FindFirstChild("Head Hitbox") end
        return Character:FindFirstChild(Name)
    end
    local Proxy = setmetatable({_id = rawget(Character, "_id")}, {
        __index = function(_, Name)
            if Name == "FindFirstChild" then return function(_, Value) return Child(Value) end end
            if Name == "FindFirstChildOfClass" or Name == "FindFirstChildWhichIsA" then return function(_, Class)
                if Class == "Humanoid" then return Character.Humanoid end
                for _, Item in Character:GetChildren() do if Item:IsA(Class) then return Item end end
            end end
            if Name == "Head" or Name == "HumanoidRootPart" or Name == "Humanoid" then return Child(Name) end
            local Value = Character[Name]
            if type(Value) == "function" then return function(_, ...) return Value(Character, ...) end end
            return Value
        end,
        __newindex = function(_, Name, Value) Character[Name] = Value end,
    })
    CharacterCache[Character] = Proxy
    return Proxy
end
function Runtime.Player(Player)
    if not Player then return nil end
    if PlayerCache[Player] then return PlayerCache[Player] end
    local Proxy = setmetatable({_id = rawget(Player, "_id")}, {
        __index = function(_, Name)
            if Name == "Character" then return Runtime.Character(Player.Character) end
            local Value = Player[Name]
            if type(Value) == "function" then return function(_, ...) return Value(Player, ...) end end
            return Value
        end,
        __newindex = function(_, Name, Value) Player[Name] = Value end,
    })
    PlayerCache[Player] = Proxy
    return Proxy
end
Runtime.Players = setmetatable({}, {__index = function(_, Name)
    if Name == "LocalPlayer" then return Runtime.Player(NativePlayers.LocalPlayer) end
    if Name == "GetPlayers" or Name == "GetChildren" then return function()
        local Result = {}
        for _, Player in NativePlayers:GetPlayers() do Result[#Result + 1] = Runtime.Player(Player) end
        return Result
    end end
    if Name == "FindFirstChild" then return function(_, Search)
        for _, Player in NativePlayers:GetPlayers() do if Player.Name == Search then return Runtime.Player(Player) end end
    end end
    return NativePlayers[Name]
end})

function Runtime.Team(Player)
    local Team = Read(Player, "Team")
    if Team ~= nil then return Team end
    local Character = Read(Player, "Character")
    if Character and Read(Character, "GetAttribute") then
        local Success, Value = pcall(function() return Character:GetAttribute("Team") end)
        if Success then return Value end
    end
end
function Runtime.SameTeam(Player, Other)
    local First, Second = Runtime.Team(Player), Runtime.Team(Other)
    return First ~= nil and Second ~= nil and First == Second
end

Runtime.Color = {}
function Runtime.Color.ToHSV(Value)
    local Maximum = math.max(Value.R, Value.G, Value.B)
    local Minimum = math.min(Value.R, Value.G, Value.B)
    local Difference = Maximum - Minimum
    local Hue = 0
    if Difference > 0 then
        if Maximum == Value.R then Hue = ((Value.G - Value.B) / Difference) % 6
        elseif Maximum == Value.G then Hue = (Value.B - Value.R) / Difference + 2
        else Hue = (Value.R - Value.G) / Difference + 4 end
    end
    return Hue / 6, Maximum == 0 and 0 or Difference / Maximum, Maximum
end
function Runtime.Color.new(R, G, B)
    local Value = NativeColor.new(R or 0, G or 0, B or 0)
    if type(Value) == "table" then rawset(Value, "ToHSV", Runtime.Color.ToHSV) rawset(Value, "toHSV", Runtime.Color.ToHSV) end
    return Value
end
function Runtime.Color.fromRGB(R, G, B) return Runtime.Color.new(R / 255, G / 255, B / 255) end
function Runtime.Color.fromHex(Hex)
    Hex = Hex:gsub("#", "")
    assert(Hex:match("^%x%x%x%x%x%x$"), "Invalid color")
    return Runtime.Color.fromRGB(tonumber(Hex:sub(1, 2), 16), tonumber(Hex:sub(3, 4), 16), tonumber(Hex:sub(5, 6), 16))
end
function Runtime.Color.fromHSV(H, S, V)
    H = (H % 1) * 6
    S, V = math.clamp(S, 0, 1), math.clamp(V, 0, 1)
    local C = V * S
    local X = C * (1 - math.abs(H % 2 - 1))
    local M = V - C
    local Colors = {{C, X, 0}, {X, C, 0}, {0, C, X}, {0, X, C}, {X, 0, C}, {C, 0, X}}
    local Value = Colors[math.floor(H) + 1]
    return Runtime.Color.new(Value[1] + M, Value[2] + M, Value[3] + M)
end

Runtime.Values = {}
function Runtime.Value(Initial)
    local Value = Initial or 0
    local Changed = Runtime.Signal()
    return setmetatable({}, {
        __index = function(_, Name)
            if Name == "Value" then return Value end
            if Name == "Changed" then return Changed end
            if Name == "GetPropertyChangedSignal" then return function() return Changed end end
            if Name == "Destroy" then return function() table.clear(Changed.Listeners) end end
        end,
        __newindex = function(_, Name, New)
            assert(Name == "Value", "Unknown UI value property")
            Value = New
            Changed:Fire(New)
        end,
    })
end
Runtime.Tween = {}
function Runtime.Tween:Create(Object, Info, Properties)
    local Tween = {Completed = Runtime.Signal(), Cancelled = false, Started = false}
    function Tween:Cancel() self.Cancelled = true end
    function Tween:Play()
        if self.Started then return end
        self.Started = true
        local Start = Runtime.Time()
        local Initial = {}
        for Name in Properties do Initial[Name] = Object[Name] end
        local Name = "Tween" .. tostring(self)
        Runtime.Step(Name, 400, function()
            if self.Cancelled then Runtime.Bindings[Name] = nil return end
            local Progress = math.clamp((Runtime.Time() - Start) / math.max(Info.Time or 0.5, 0.001), 0, 1)
            local Ease = 1 - (1 - Progress) ^ 4
            for Property, Target in Properties do Object[Property] = Initial[Property] + (Target - Initial[Property]) * Ease end
            if Progress == 1 then Runtime.Bindings[Name] = nil self.Completed:Fire() end
        end)
    end
    return Tween
end

Runtime.RunService = {}
function Runtime.RunService:BindToRenderStep(Name, Priority, Callback) Runtime.Step(Name, Priority, Callback) end
function Runtime.RunService:UnbindFromRenderStep(Name) Runtime.Bindings[Name] = nil end
Runtime.RunService.Heartbeat = Runtime.Signal()
Runtime.RunService.RenderStepped = Runtime.Signal()

function Runtime.Start()
    if Runtime.Started then return end
    Runtime.Started = true
    task.spawn(function()
        local Width, Height = 0, 0
        while Runtime.Alive do
            local Foreground = type(iswindowactive) ~= "function" or iswindowactive()
            Runtime.Foreground = Foreground
            local Delta = task.wait(Foreground and 0 or 0.1)
            Runtime.Tick += 1
            if not Runtime.Alive then break end
            Runtime.Elapsed += type(Delta) == "number" and math.clamp(Delta, 0.001, 1) or 1 / 60
            local WorkStarted = Runtime.Time()
            CapturedEvents()
            local Frame = type(NativeDraw.beginframe) == "function" and NativeDraw.beginframe() or nil
            local Pending = Runtime.Queue
            Runtime.Queue = {}
            for _, Item in Pending do Runtime.Try("Input", Item.Callback, table.unpack(Item.Arguments, 1, Item.Arguments.n)) end
            local Project = Runtime.NeedsProjection
            if type(Project) == "function" then Project = Project() end
            local Success, View
            if Project then Success, View = pcall(Runtime.Projection)
            else
                local Camera = NativeCamera()
                local Size = Camera and Camera.ViewportSize
                Success = Size ~= nil and Size.X > 0 and Size.Y > 0
                View = {Width = Size and Size.X or 0, Height = Size and Size.Y or 0}
            end
            if Success then
                Runtime.View = View
                if Width ~= View.Width or Height ~= View.Height then
                    Width, Height = View.Width, View.Height
                    if CameraSignals.ViewportSize then CameraSignals.ViewportSize:Fire() end
                end
            else Runtime.View = nil end
            if Runtime.OrderDirty then
                table.sort(Runtime.Order, function(A, B) return A.Priority == B.Priority and A.Name < B.Name or A.Priority < B.Priority end)
                Runtime.OrderDirty = false
            end
            for Index = #Runtime.Order, 1, -1 do
                local Binding = Runtime.Order[Index]
                if Runtime.Bindings[Binding.Name] ~= Binding then table.remove(Runtime.Order, Index) end
            end
            if Runtime.View then
                for _, Binding in Runtime.Order do Runtime.Try("Frame", Binding.Callback, Delta or 1 / 60) end
            end
            if Frame then NativeDraw.endframe(Frame) end
            Runtime.LastWork = Runtime.Time() - WorkStarted
            Runtime.PeakWork = math.max(Runtime.PeakWork or 0, Runtime.LastWork)
            Runtime.RunService.Heartbeat:Fire(Delta or 1 / 60)
            Runtime.RunService.RenderStepped:Fire(Delta or 1 / 60)
        end
    end)
end

Runtime.Read = Read
Runtime.NativePlayers = NativePlayers
return Runtime

end)()

local Admin = {Commands = {}, Names = {}, Aliases = {}, Binds = {}, Waypoints = {}, Loops = {}, Undo = {}, Log = {}, History = {}, Plugins = {}, Position = Vector2.new(0, 0),
    Prefix = ";", Open = true, Focused = false, Docked = true, Text = "", Cursor = 0, Mode = "Commands", Scroll = 0, Selected = 1, Rows = {}, FlySpeed = 300, TweenSpeed = 40, StayOpen = false, Slide = 20, Hovered = false, LastHover = 0, Theme = "Classic"}
local Previous = getgenv().VortexAdmin
if Previous and type(Previous.Stop) == "function" then Previous.Stop(true) end
local SettingsPath = "VortexAdmin.json"
local Color = Runtime.Color
local Input = Runtime.Input
local Player = Runtime.NativePlayers.LocalPlayer
assert(Player, "Join a game before starting the admin script")
local White = Color.fromRGB(255, 255, 255)
local Gray = Color.fromRGB(145, 145, 145)
local Accent = Color.fromRGB(95, 130, 165)
local Background = Color.fromRGB(46, 46, 47)
local Views = {"Commands", "Settings", "Waypoints", "Aliases", "Binds", "Logs", "Players"}

local function PreviousCharacter(Text, Cursor)
    local Index = math.max(0, Cursor - 1)
    while Index > 0 do
        local Byte = string.byte(Text, Index + 1)
        if Byte < 128 or Byte >= 192 then break end
        Index -= 1
    end
    return Index
end

local function NextCharacter(Text, Cursor)
    local Index = math.min(#Text, Cursor + 1)
    while Index < #Text do
        local Byte = string.byte(Text, Index + 1)
        if Byte < 128 or Byte >= 192 then break end
        Index += 1
    end
    return Index
end

function Admin:Notify(Message)
    Message = tostring(Message)
    self.Status = Message
    self.StatusTime = Runtime.Time()
    self.Log[#self.Log + 1] = Message
    if #self.Log > 200 then table.remove(self.Log, 1) end
    print(Message)
end

function Admin:Save()
    local Data = {Version = 1, Prefix = self.Prefix, StayOpen = self.StayOpen, Aliases = self.Aliases, Binds = self.Binds, Waypoints = self.Waypoints,
        Position = {X = self.Position.X, Y = self.Position.Y}, DockOffset = self.DockOffset, FlySpeed = self.FlySpeed, TweenSpeed = self.TweenSpeed, Theme = self.Theme}
    writefile(SettingsPath, json.encode(Data))
end

function Admin:Load()
    if not isfile(SettingsPath) then return end
    local Data = json.decode(readfile(SettingsPath))
    assert(type(Data) == "table" and Data.Version == 1, "Unsupported settings")
    if type(Data.Prefix) == "string" and #Data.Prefix == 1 then self.Prefix = Data.Prefix end
    if type(Data.StayOpen) == "boolean" then self.StayOpen = Data.StayOpen end
    if type(Data.DockOffset) == "number" and Data.DockOffset == Data.DockOffset then self.DockOffset = math.clamp(Data.DockOffset, -10000, -250) end
    if Data.Theme == "Classic" or Data.Theme == "Dark" or Data.Theme == "Transparent" then self.Theme = Data.Theme end
    for _, Name in {"Aliases", "Binds", "Waypoints"} do
        if type(Data[Name]) == "table" then self[Name] = Data[Name] end
    end
    for _, Name in {"FlySpeed", "TweenSpeed"} do
        local Value = Data[Name]
        if type(Value) == "number" and Value == Value then self[Name] = math.clamp(Value, 1, 500) end
    end
    if type(Data.Position) == "table" and type(Data.Position.X) == "number" and type(Data.Position.Y) == "number" then
        self.Position = Vector2.new(math.clamp(Data.Position.X, 0, 10000), math.clamp(Data.Position.Y, 0, 10000))
        self.Positioned = true
    end
end

local Drawings = {}
local Properties = {}
local Used = {}
local function Equal(First, Second)
    if First == Second then return true end
    if type(First) ~= "table" or type(Second) ~= "table" then return false end
    if rawget(First, "X") ~= nil and rawget(Second, "X") ~= nil then return First.X == Second.X and First.Y == Second.Y end
    if rawget(First, "R") ~= nil and rawget(Second, "R") ~= nil then return First.R == Second.R and First.G == Second.G and First.B == Second.B end
    return false
end
local function Shape(Name, Kind, Values)
    if not Drawings[Name] then Drawings[Name] = Runtime.Drawing(Kind) end
    Properties[Name] = Properties[Name] or {}
    local Previous = Properties[Name]
    local Object = Drawings[Name]
    Used[Name] = true
    for Key, Value in Values do
        if not Equal(Previous[Key], Value) then Object[Key] = Value Previous[Key] = Value end
    end
    if Previous.Visible ~= true then Object.Visible = true Previous.Visible = true end
    return Object
end
local function Finish()
    for Name, Object in Drawings do
        if not Used[Name] and Properties[Name] and Properties[Name].Visible then
            Object.Visible = false
            Properties[Name].Visible = false
        end
    end
end
local function Label(Name, Text, X, Y, Tint, Size)
    return Shape(Name, "Text", {Text = tostring(Text), Position = Vector2.new(X, Y), Size = Size or 18, Font = Drawing.Fonts.SourceSans or Drawing.Fonts.System,
        Color = Tint or White, Outline = false, ZIndex = 9001})
end
local function Rectangle(Name, X, Y, Width, Height, Tint, Opacity)
    return Shape(Name, "Square", {Position = Vector2.new(X, Y), Size = Vector2.new(math.max(1, Width), math.max(1, Height)), Filled = true,
        Color = Tint, Transparency = Opacity or 1, ZIndex = 9000})
end
local function Within(Position, X, Y, Width, Height)
    return Position.X >= X and Position.X <= X + Width and Position.Y >= Y and Position.Y <= Y + Height
end

function Admin:List()
    local Key = self.Mode .. "|" .. self.Text .. "|" .. self.Cursor .. "|" .. #self.Names .. "|" .. tostring(self.StayOpen)
    local Now = Runtime.Time()
    if self.ListKey == Key and Now - (self.ListTime or 0) < 0.25 then return self.Rows end
    self.ListKey = Key
    self.ListTime = Now
    local Rows = {}
    if self.Mode == "Commands" then
        local Before = self.Text:sub(1, self.Cursor)
        local Prefix, Search = Before:match("^(.*%s)([^%s]*)$")
        Search = (Search or Before):lower()
        if Prefix then
            local Head, Last = Search:match("^(.*[,])([^,]*)$")
            Head, Search = Head or "", Last or Search
            for _, Other in Runtime.NativePlayers:GetPlayers() do
                local Name = Other.Name
                local Display = Other.DisplayName or Name
                if Name:lower():sub(1, #Search) == Search or Display:lower():sub(1, #Search) == Search then
                    Rows[#Rows + 1] = {Text = Name, Detail = Display, Command = Prefix .. Head .. Name, Player = true}
                end
            end
            for _, Name in {"me", "all", "others", "random", "nearest", "farthest", "team", "nonteam"} do
                if Name:sub(1, #Search) == Search then
                    Rows[#Rows + 1] = {Text = Name, Detail = "Player selector", Command = Prefix .. Head .. Name, Player = true}
                end
            end
        else
            for _, Name in self.Names do
                local Command = self.Commands[Name]
                local Match = Name:find(Search, 1, true) ~= nil
                local Completion = Name
                for _, Alias in Command.Aliases do
                    if Alias:sub(1, #Search) == Search then
                        Match = true
                        Completion = Alias
                        if Alias == Search then break end
                    end
                end
                if Match then
                    Rows[#Rows + 1] = {Text = Completion, Detail = Command.Usage .. "  " .. Command.Description, Command = Completion}
                end
            end
        end
        table.sort(Rows, function(A, B) return A.Text < B.Text end)
    elseif self.Mode == "Settings" then
        Rows = {
            {Text = "Prefix: " .. self.Prefix, Detail = "Use prefix <character>", Command = "prefix "},
            {Text = "Keep Menu Open", Check = self.StayOpen, Callback = function() self.StayOpen = not self.StayOpen self:Save() end},
            {Text = "Edit Theme", Icon = "edittheme", Callback = function() self.Mode = "Theme" self.Scroll = 0 end},
            {Text = "Edit Keybinds", Icon = "editkeybinds", Callback = function() self.Mode = "Binds" self.Scroll = 0 end},
            {Text = "Edit Aliases", Icon = "editaliases", Callback = function() self.Mode = "Aliases" self.Scroll = 0 end},
            {Text = "Edit/Goto Waypoints", Icon = "editwaypoints", Callback = function() self.Mode = "Waypoints" self.Scroll = 0 end},
            {Text = "Manage Plugins", Icon = "bindsandplugins", Callback = function() self.Mode = "Plugins" self.Scroll = 0 end},
            {Text = "Fly speed: " .. self.FlySpeed, Command = "flyspeed "},
            {Text = "Tween speed: " .. self.TweenSpeed, Command = "tweenspeed "},
            {Text = "Save settings", Callback = function() self:Save() self:Notify("Settings saved") end},
            {Text = "Load settings", Callback = function() self:Load() self:Notify("Settings loaded") end},
            {Text = "Restore changes", Callback = function() self:Restore() end},
            {Text = "Unload", Callback = function() self.Stop() end},
        }
        for _, Name in {"Waypoints", "Aliases", "Binds", "Logs", "Players"} do
            Rows[#Rows + 1] = {Text = Name, Callback = function() self.Mode = Name self.Scroll = 0 end}
        end
    elseif self.Mode == "Theme" then
        for _, Name in {"Classic", "Dark", "Transparent"} do
            Rows[#Rows + 1] = {Text = Name, Callback = function() self.Theme = Name self:Save() end}
        end
    elseif self.Mode == "Plugins" then
        Rows[#Rows + 1] = {Text = "Add Plugin", Command = "addplugin "}
        for Name in self.Plugins do Rows[#Rows + 1] = {Text = Name, Detail = "Loaded plugin"} end
    elseif self.Mode == "Waypoints" then
        for Name, Point in self.Waypoints do Rows[#Rows + 1] = {Text = Name, Detail = string.format("%.1f, %.1f, %.1f", Point.X, Point.Y, Point.Z), Command = 'waypoint "' .. Name .. '"'} end
        table.sort(Rows, function(A, B) return A.Text < B.Text end)
    elseif self.Mode == "Aliases" then
        for Name, Command in self.Aliases do Rows[#Rows + 1] = {Text = Name, Detail = Command, Command = Name} end
    elseif self.Mode == "Binds" then
        for Name, Command in self.Binds do Rows[#Rows + 1] = {Text = Name, Detail = Command, Command = Command} end
    elseif self.Mode == "Logs" then
        for Index = #self.Log, 1, -1 do Rows[#Rows + 1] = {Text = self.Log[Index]} end
    elseif self.Mode == "Players" then
        for _, Other in Runtime.NativePlayers:GetPlayers() do
            Rows[#Rows + 1] = {Text = Other.DisplayName or Other.Name, Detail = Other.Name .. " / " .. tostring(Other.UserId), Command = "goto " .. Other.Name}
        end
    end
    self.Rows = Rows
    return Rows
end

local Assets = {}
local function Icon(Name, Asset, X, Y, Size)
    if not Assets[Asset] and type(Drawing.getasset) == "function" then
        local Success, Data = pcall(Drawing.getasset, Asset)
        if Success then Assets[Asset] = Data else Assets[Asset] = false end
    end
    if not Assets[Asset] then return end
    local Object = Drawings[Name]
    if not Object then
        Object = Runtime.Drawing("Image", {Data = Assets[Asset], ZIndex = 9002})
        Drawings[Name] = Object
    end
    Shape(Name, "Image", {Position = Vector2.new(X, Y), Size = Vector2.new(Size, Size)})
end

local function Quart(Value)
    return Value < 0.5 and 8 * Value ^ 4 or 1 - (-2 * Value + 2) ^ 4 / 2
end

function Admin:Draw()
    table.clear(Used)
    local View = Runtime.View
    if not View then Finish() return end
    if Runtime.InterfaceActive then self.Focused = false self.DragOffset = nil end
    local Width, Height = 250, 220
    local Mouse = Input:GetMouseLocation()
    local Now = Runtime.Time()
    local Hover = not Runtime.InterfaceActive and Within(Mouse, self.Position.X, self.Position.Y, Width, Height)
    if Hover then self.LastHover = Now end
    local Target = self.StayOpen or Hover or self.Focused or self.DragOffset or Now - self.LastHover < 1
    Target = self.Open and (Target and 220 or 20) or 20
    if self.SlideTarget ~= Target then
        self.SlideFrom = self.Slide
        self.SlideTarget = Target
        self.SlideStart = Now
        self.SlideDuration = Target > self.Slide and 0.2 or 0.5
    end
    local Alpha = math.clamp((Now - self.SlideStart) / self.SlideDuration, 0, 1)
    self.Slide = self.SlideFrom + (Target - self.SlideFrom) * Quart(Alpha)
    if self.DragOffset then
        if Input:IsMouseButtonPressed(1) then
            self.DockOffset = math.clamp(Mouse.X - self.DragOffset, 0, math.max(0, View.Width - Width)) - View.Width
        else
            self.DragOffset = nil
            Runtime.Try("Settings", function() self:Save() end)
        end
    end
    if self.Docked or not self.Positioned then
        self.Position = Vector2.new(math.clamp(View.Width + (self.DockOffset or -Width), 0, math.max(0, View.Width - Width)), math.max(0, View.Height - self.Slide))
        self.Positioned = true
    end
    self.Position = Vector2.new(math.clamp(self.Position.X, 0, math.max(0, View.Width - Width)), math.clamp(self.Position.Y, 0, math.max(0, View.Height - 20)))
    local X, Y = self.Position.X, self.Position.Y
    local Shade1 = self.Theme == "Dark" and Color.fromRGB(20, 20, 21) or Color.fromRGB(36, 36, 37)
    local Shade2 = self.Theme == "Dark" and Color.fromRGB(28, 28, 29) or Color.fromRGB(46, 46, 47)
    local Opacity = self.Theme == "Transparent" and 0.9 or 1
    local VisibleHeight = math.min(Height, View.Height - Y)
    Runtime.Capture(self.Focused and not self.Textbox, not Runtime.InterfaceActive and {X = X, Y = Y, Width = Width, Height = VisibleHeight} or nil)
    Rectangle("Panel", X, Y, Width, Height, Shade2, Opacity)
    Rectangle("Top", X, Y, Width, 20, Shade1, Opacity)
    local Title = Label("Title", "Infinite Yield FE v6.4.2", X + 125, Y - 1, White, 18)
    Title.Center = true
    Icon("Reference", "reference", X + 212, Y + 2, 16)
    Icon("Settings", "settings", X + 230, Y, 20)
    Rectangle("ListBackground", X, Y + 45, Width, 175, Shade1, Opacity)
    local Text = self.Text
    if self.Focused and math.floor(Now * 2) % 2 == 0 then Text = Text:sub(1, self.Cursor) .. "|" .. Text:sub(self.Cursor + 1) end
    if #Text > 32 then Text = Text:sub(#Text - 31) end
    if self.Textbox then
        local Box = self.Textbox
        Box.Position = Vector2.new(X + 5, Y + 20)
        Box.Size = Vector2.new(240, 25)
        Box.Visible = self.Focused or Y + 20 < View.Height
        if self.Text ~= self.LastTextboxText then Box.Text = self.Text Box.Cursor = self.Cursor Box.Anchor = self.Cursor end
        self.Text = Box.Text
        self.Cursor = Box.Cursor
        self.LastTextboxText = self.Text
        if self.TextboxFocus ~= self.Focused then
            self.TextboxFocus = self.Focused
            if self.Focused and not Box:IsFocused() then Box:CaptureFocus()
            elseif not self.Focused and Box:IsFocused() then Box:ReleaseFocus(false) end
        end
    else
        local Command = Label("CommandText", #Text > 0 and Text or "Command Bar (" .. self.Prefix .. ")", X + 5, Y + 22, #Text > 0 and White or Gray, 18)
        Command.Clipping = true Command.ClipPosition = Vector2.new(X + 5, Y + 20) Command.ClipSize = Vector2.new(240, 25)
    end
    local Rows = self:List()
    self.RowHeight = self.Mode == "Settings" and 30 or 20
    local Page = math.floor(175 / self.RowHeight)
    self.PageSize = Page
    self.Scroll = math.clamp(self.Scroll, 0, math.max(0, #Rows - Page))
    self.Selected = math.clamp(self.Selected, 1, math.max(1, #Rows))
    for Index = 1, Page + 1 do
        local Row = Rows[self.Scroll + Index]
        if Row then
            local RowY = Y + 45 + (Index - 1) * self.RowHeight
            if RowY < Y + Height then
                local Hovered = Within(Mouse, X + 5, RowY, Width - 18, self.RowHeight)
                if self.Mode == "Settings" or Hovered or self.Focused and self.Selected == self.Scroll + Index then
                    local Fill = Rectangle("Row" .. Index, X + 5, RowY, Width - 18, self.RowHeight - (self.Mode == "Settings" and 5 or 0), Shade2, Opacity)
                    Fill.Clipping = true Fill.ClipPosition = Vector2.new(X, Y + 45) Fill.ClipSize = Vector2.new(Width, 175)
                end
                local Left = Row.Icon and 28 or 5
                if Row.Icon then Icon("Icon" .. Index, Row.Icon, X + 10, RowY + 5, 16) end
                local Object = Label("RowText" .. Index, Row.Text, X + Left, RowY + (self.Mode == "Settings" and 4 or -1), White, self.Mode == "Settings" and 14 or 18)
                Object.Clipping = true Object.ClipPosition = Vector2.new(X + Left, Y + 45) Object.ClipSize = Vector2.new(Width - Left - 16, 175)
                if Row.Check ~= nil then Rectangle("Check" .. Index, X + 212, RowY + 2, 20, 20, Row.Check and Color.fromRGB(150, 150, 151) or Color.fromRGB(78, 78, 79)) end
                if Hovered then self.Tooltip = Row.Detail end
            end
        end
    end
    if #Rows > Page then
        local Thumb = math.max(12, 175 * Page / #Rows)
        Rectangle("ScrollThumb", X + Width - 8, Y + 45 + self.Scroll / (#Rows - Page) * (175 - Thumb), 8, Thumb, Color.fromRGB(78, 78, 79))
    end
    Finish()
end

local CharacterKeys = {Space = " ", Semicolon = ";", Quote = "'", Comma = ",", Period = ".", Slash = "/", BackSlash = "\\", Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", Backquote = "`"}
local ShiftKeys = { [";"] = ":", ["'"] = '"', [","] = "<", ["."] = ">", ["/"] = "?", ["\\"] = "|", ["-"] = "_", ["="] = "+", ["["] = "{", ["]"] = "}", ["`"] = "~",
    ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%", ["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")"}
local Digits = {Zero = "0", One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9"}
local function HandleInput(Event, Processed)
    local Kind = Runtime.KeyName(Event.UserInputType)
    local Name = Runtime.KeyName(Event.KeyCode)
    if Processed and not Admin.Focused then return end
    if Kind == "MouseButton1" then
        if not Within(Input:GetMouseLocation(), Admin.Position.X, Admin.Position.Y, 250, 220) then Admin.Focused = false return end
        local Mouse = Input:GetMouseLocation()
        local X, Y = Admin.Position.X, Admin.Position.Y
        if Within(Mouse, X + 230, Y, 20, 20) then Admin.Mode = Admin.Mode == "Commands" and "Settings" or "Commands" Admin.Scroll = 0 Admin.Open = true return end
        if Within(Mouse, X + 212, Y, 16, 20) then Admin.Mode = "Commands" Admin.Text = "" Admin.Cursor = 0 Admin.Scroll = 0 return end
        if Within(Mouse, X, Y, 210, 20) then
            Admin.Open = true
            Admin.Focused = false
            Admin.LastHover = Runtime.Time()
            Admin.DragOffset = Mouse.X - X
            return
        end
        if Within(Mouse, X + 5, Y + 20, 240, 25) then Admin.Focused = true return end
        Admin.Focused = false
        if Within(Mouse, X + 5, Y + 45, 232, 175) then
            local Index = math.floor((Mouse.Y - Y - 45) / (Admin.RowHeight or 20)) + 1 + Admin.Scroll
            local Row = Admin.Rows[Index]
            if Row and Row.Callback then Runtime.Try("Action", Row.Callback)
            elseif Row and Row.Command then Admin.Text = Row.Command Admin.Cursor = #Admin.Text Admin.Mode = "Commands" Admin.Focused = true end
        end
        return
    end
    if Kind ~= "Keyboard" then return end
    local Shift = Input:IsKeyDown(Enum.KeyCode.LeftShift) or Input:IsKeyDown(Enum.KeyCode.RightShift)
    local Character = #Name == 1 and Name:lower() or CharacterKeys[Name] or Digits[Name]
    if Shift and Character then Character = ShiftKeys[Character] or Character:upper() end
    if Event.Captured then Character = nil end
    if not Admin.Focused then
        if Character == Admin.Prefix then Admin.Open = true Admin.Focused = true Admin.Text = "" Admin.Cursor = 0 Admin.Mode = "Commands" return end
        if Admin.Binds[Name] then Runtime.Defer(function() Admin:Run(Admin.Binds[Name]) end) end
        return
    end
    if Admin.Textbox and Name ~= "Tab" and Name ~= "Up" and Name ~= "Down" then return end
    if Name == "Escape" then Admin.Focused = false return end
    local Control = Input:IsKeyDown(Enum.KeyCode.LeftControl) or Input:IsKeyDown(Enum.KeyCode.RightControl)
    if Name == "A" and Control then Admin.SelectAll = true return end
    if Control and (Name == "C" or Name == "X") then
        if Admin.SelectAll and type(setclipboard) == "function" then setclipboard(Admin.Text) end
        if Name == "X" and Admin.SelectAll then Admin.Text = "" Admin.Cursor = 0 Admin.SelectAll = false end
        return
    end
    if Control then Character = nil end
    if Name == "Return" or Name == "Enter" then
        local Command = Admin.Text
        Admin.Text = ""
        Admin.Cursor = 0
        Admin.Focused = false
        Runtime.Defer(function() Admin:Run(Command) end)
    elseif Name == "Backspace" then
        if Admin.SelectAll then Admin.Text = "" Admin.Cursor = 0 Admin.SelectAll = false
        elseif Admin.Cursor > 0 then
            local Before = PreviousCharacter(Admin.Text, Admin.Cursor)
            Admin.Text = Admin.Text:sub(1, Before) .. Admin.Text:sub(Admin.Cursor + 1)
            Admin.Cursor = Before
        end
    elseif Name == "Delete" then
        if Admin.SelectAll then Admin.Text = "" Admin.Cursor = 0 Admin.SelectAll = false
        elseif Admin.Cursor < #Admin.Text then local After = NextCharacter(Admin.Text, Admin.Cursor) Admin.Text = Admin.Text:sub(1, Admin.Cursor) .. Admin.Text:sub(After + 1) end
    elseif Name == "Left" then Admin.Cursor = PreviousCharacter(Admin.Text, Admin.Cursor) Admin.SelectAll = false
    elseif Name == "Right" then Admin.Cursor = NextCharacter(Admin.Text, Admin.Cursor) Admin.SelectAll = false
    elseif Name == "Home" then Admin.Cursor = 0 Admin.SelectAll = false
    elseif Name == "End" then Admin.Cursor = #Admin.Text Admin.SelectAll = false
    elseif Name == "Tab" then
        local Row = Admin.Rows[Admin.Selected]
        if Row and Row.Command then Admin.Text = Row.Command .. " " Admin.Cursor = #Admin.Text end
    elseif Name == "Up" or Name == "Down" then
        if Input:IsKeyDown(Enum.KeyCode.LeftControl) then
            Admin.HistoryIndex = math.clamp((Admin.HistoryIndex or #Admin.History + 1) + (Name == "Up" and -1 or 1), 1, math.max(1, #Admin.History))
            Admin.Text = Admin.History[Admin.HistoryIndex] or ""
            Admin.Cursor = #Admin.Text
        else Admin.Selected = math.clamp(Admin.Selected + (Name == "Up" and -1 or 1), 1, math.max(1, #Admin.Rows))
            Admin.Scroll = math.clamp(Admin.Selected - (Admin.PageSize or 8), 0, math.max(0, #Admin.Rows - (Admin.PageSize or 8))) end
    elseif Character and #Admin.Text < 1024 then
        if Admin.SelectAll then Admin.Text = "" Admin.Cursor = 0 Admin.SelectAll = false end
        Admin.Text = Admin.Text:sub(1, Admin.Cursor) .. Character .. Admin.Text:sub(Admin.Cursor + 1)
        Admin.Cursor += #Character Admin.Selected = 1 Admin.Scroll = 0
    end
end
Runtime.Connect(Input.InputBegan, HandleInput)
pcall(function()
    local Box = Runtime.Control("TextBox", {Position = Vector2.new(0, 0), Size = Vector2.new(240, 25), BackgroundTransparency = 1, TextColor3 = White,
        Font = Drawing.Fonts.SourceSans or Drawing.Fonts.System or 1, TextSize = 18, Padding = 0, MaxLength = 1024, ZIndex = 9003, PlaceholderText = "Command Bar (" .. Admin.Prefix .. ")"})
    assert(Box.InputBegan and Box.FocusLost and type(Box.CaptureFocus) == "function", "TextBox interface unavailable")
    Runtime.Connect(Box.Focused, function() Admin.Focused = true Admin.TextboxFocus = true Admin.Open = true end)
    Runtime.Connect(Box.FocusLost, function(Submitted)
        Admin.Focused = false
        Admin.TextboxFocus = false
        if Submitted then
            local Command = Box.Text
            Box.Text = ""
            Admin.Text = "" Admin.LastTextboxText = "" Admin.Cursor = 0
            Runtime.Defer(function() Admin:Run(Command) end)
        end
    end)
    Runtime.Connect(Box.InputBegan, function(Name)
        if Name == "Escape" or Name == "Return" or Name == "Enter" then
            Admin.Focused = false
            Admin.TextboxFocus = false
            if Box:IsFocused() then Box:ReleaseFocus(Name ~= "Escape") end
        elseif Name == "Tab" or Name == "Up" or Name == "Down" then HandleInput({KeyCode = {Name = Name}, UserInputType = {Name = "Keyboard"}, Captured = true}, false) end
    end)
    Admin.Textbox = Box
end)
Runtime.Connect(Input.TextInput, function(Text)
    if Admin.Focused and not Admin.Textbox and #Admin.Text + #Text <= 1024 then
        if Admin.SelectAll then Admin.Text = "" Admin.Cursor = 0 Admin.SelectAll = false end
        Admin.Text = Admin.Text:sub(1, Admin.Cursor) .. Text .. Admin.Text:sub(Admin.Cursor + 1)
        Admin.Cursor += #Text Admin.Selected = 1 Admin.Scroll = 0
    end
end)
Runtime.Connect(Input.PasteInput, function(Text)
    if not Admin.Focused or Admin.Textbox then return end
    Text = Text:gsub("[\r\n]+", " ")
    if Admin.SelectAll then Admin.Text = "" Admin.Cursor = 0 Admin.SelectAll = false end
    Text = Text:sub(1, math.max(0, 1024 - #Admin.Text))
    Admin.Text = Admin.Text:sub(1, Admin.Cursor) .. Text .. Admin.Text:sub(Admin.Cursor + 1)
    Admin.Cursor += #Text
end)
Runtime.Connect(Input.InputEnded, function(Event)
    if Runtime.KeyName(Event.UserInputType) == "MouseButton1" then
        if Admin.DragOffset then Runtime.Try("Settings", function() Admin:Save() end) end
        Admin.DragOffset = nil
    end
end)
Runtime.Connect(Input.InputChanged, function(Event)
    if Admin.Open and Runtime.KeyName(Event.UserInputType) == "MouseWheel" and Within(Input:GetMouseLocation(), Admin.Position.X, Admin.Position.Y + 45, 250, 175) then
        local Position = Event.Position
        Admin.Scroll = math.clamp(Admin.Scroll - (Position and Position.Z or 0) * 3, 0, math.max(0, #Admin.Rows - (Admin.PageSize or 8)))
    end
end)

local function Tokens(Text)
    local Result, Buffer, Quote, Escaped = {}, {}, nil, false
    for Index = 1, #Text do
        local Character = Text:sub(Index, Index)
        if Escaped then Buffer[#Buffer + 1] = Character Escaped = false
        elseif Character == "\\" and Quote then Escaped = true
        elseif Quote then if Character == Quote then Quote = nil else Buffer[#Buffer + 1] = Character end
        elseif Character == '"' or Character == "'" then Quote = Character
        elseif Character:match("%s") then if #Buffer > 0 then Result[#Result + 1] = table.concat(Buffer) Buffer = {} end
        else Buffer[#Buffer + 1] = Character end
    end
    assert(not Quote, "Unclosed quote")
    if #Buffer > 0 then Result[#Result + 1] = table.concat(Buffer) end
    return Result
end
local function Number(Value, Minimum, Maximum)
    local Result = tonumber(Value)
    assert(Result and Result == Result and Result >= Minimum and Result <= Maximum, "Expected a number from " .. Minimum .. " to " .. Maximum)
    return Result
end
local function Character()
    local Value = Player.Character
    assert(Value and Value.HumanoidRootPart, "Character unavailable")
    return Value, Value.HumanoidRootPart, Value.Humanoid
end
local function Position(Other)
    local Model = Other and Other.Character
    return Model and Model.HumanoidRootPart and Model.HumanoidRootPart.Position
end
local function Distance(A, B) return (A - B).Magnitude end
local function Same(A, B)
    if type(A) == "number" and type(B) == "number" then return math.abs(A - B) < 0.001 end
    if type(A) == "table" and type(B) == "table" and A.X and B.X then return Distance(A, B) < 0.1 end
    return A == B
end

function Admin:Add(Names, Description, Callback, Usage)
    local List = type(Names) == "string" and string.split(Names, " ") or Names
    assert(List[1] and type(Callback) == "function", "Invalid command")
    local Entry = {Name = List[1], Description = Description, Callback = Callback, Usage = Usage or List[1], Aliases = List}
    local Seen = {}
    for _, Name in List do
        assert(type(Name) == "string" and not self.Commands[Name] and not Seen[Name], "Invalid or duplicate command: " .. tostring(Name))
        Seen[Name] = true
    end
    for _, Name in List do self.Commands[Name] = Entry end
    self.Names[#self.Names + 1] = List[1]
    table.sort(self.Names)
    return Entry
end

function Admin:Players(Selector)
    Selector = (Selector or "me"):lower()
    local All = Runtime.NativePlayers:GetPlayers()
    local Result, Seen = {}, {}
    local function Add(Other) if Other and not Seen[Other.UserId] then Seen[Other.UserId] = true Result[#Result + 1] = Other end end
    for Query in Selector:gmatch("[^,]+") do
        if Query == "me" then Add(Player)
        elseif Query == "all" then for _, Other in All do Add(Other) end
        elseif Query == "others" then for _, Other in All do if Other.UserId ~= Player.UserId then Add(Other) end end
        elseif Query == "random" then if #All > 0 then Add(All[math.random(1, #All)]) end
        elseif Query == "nearest" or Query == "farthest" then
            local Origin = assert(Position(Player), "Character unavailable")
            local Ordered = {}
            for _, Other in All do if Other.UserId ~= Player.UserId and Position(Other) then Ordered[#Ordered + 1] = Other end end
            table.sort(Ordered, function(A, B)
                local First, Second = Distance(Position(A), Origin), Distance(Position(B), Origin)
                return Query == "nearest" and First < Second or Query == "farthest" and First > Second
            end)
            Add(Ordered[1])
        elseif Query == "team" or Query == "nonteam" then
            assert(Runtime.Team(Player) ~= nil, "This game does not expose teams")
            for _, Other in All do if Runtime.SameTeam(Other, Player) == (Query == "team") then Add(Other) end end
        else
            for _, Other in All do
                if tostring(Other.UserId) == Query or Other.Name:lower():sub(1, #Query) == Query or (Other.DisplayName or ""):lower():sub(1, #Query) == Query then Add(Other) end
            end
        end
    end
    assert(#Result > 0, "No matching players")
    return Result
end

function Admin:Set(Object, Property, Value, Verify)
    local Before = Runtime.Read(Object, Property)
    assert(Before ~= nil, Property .. " is unavailable in Vortex")
    self.Undo[Object] = self.Undo[Object] or {}
    if self.Undo[Object][Property] == nil then self.Undo[Object][Property] = {Value = Before} end
    Object[Property] = Value
    if Verify ~= false then
        task.wait(0.05)
        assert(Same(Runtime.Read(Object, Property), Value), Property .. " was not changed by the client")
    end
end

function Admin:Restore()
    table.clear(self.Loops)
    self:SetFlying(false)
    self.InfiniteJump = false
    self.Aimlock = false
    self.Noclip = false
    self.Float = false
    for Object, Properties in self.Undo do
        for Name, Value in Properties do pcall(function() Object[Name] = Value.Value end) end
    end
    table.clear(self.Undo)
    self:Notify("Changes restored")
end

function Admin:Loop(Name, Interval, Callback)
    self.Loops[Name] = {At = 0, Interval = Interval, Callback = Callback}
end

function Admin:Teleport(Point)
    local Model, Root = Character()
    self.PositionHistory = self.PositionHistory or {}
    self.PositionHistory[#self.PositionHistory + 1] = Root.Position
    if #self.PositionHistory > 20 then table.remove(self.PositionHistory, 1) end
    local Target = Root.CFrame + (Point - Root.Position)
    Model:PivotTo(Target)
    task.wait(0.1)
    local _, Current = Character()
    assert(Distance(Current.Position, Point) < 3, "Position change was rejected by the game")
end

function Admin:TweenTo(Point)
    local _, Root = Character()
    local Start = Root.Position
    local Duration = math.max(Distance(Start, Point) / self.TweenSpeed, 0.05)
    assert(Duration <= 120, "Target is too far away")
    local Began = Runtime.Time()
    self:Loop("Tween", 0, function()
        local Model, Current = Character()
        local Alpha = math.clamp((Runtime.Time() - Began) / Duration, 0, 1)
        local Location = Start + (Point - Start) * Alpha
        Model:PivotTo(Current.CFrame + (Location - Current.Position))
        if Alpha >= 1 then self.Loops.Tween = nil end
    end)
end

function Admin:Run(Source, Depth)
    local Success, Failure = pcall(function()
        assert(type(Source) == "string" and #Source <= 4096, "Invalid command")
        Depth = Depth or 0
        assert(Depth < 8, "Alias recursion limit")
        Source = Source:match("^%s*(.-)%s*$")
        if Source:sub(1, #self.Prefix) == self.Prefix then Source = Source:sub(#self.Prefix + 1) end
        if #Source == 0 then return end
        local Count, Repeated = Source:match("^(%d+)%^(.+)$")
        if Count then
            Count = Number(Count, 1, 100)
            for _ = 1, Count do self:Run(Repeated, Depth + 1) task.wait(0.05) end
            return
        end
        local Arguments = Tokens(Source)
        local Name = table.remove(Arguments, 1):lower()
        if self.Aliases[Name] then return self:Run(self.Aliases[Name] .. " " .. table.concat(Arguments, " "), Depth + 1) end
        local Entry = self.Commands[Name]
        if not Entry then error(self.Unsupported and self.Unsupported[Name] or "Unknown command: " .. Name) end
        if Depth == 0 then
            self.History[#self.History + 1] = Source
            if #self.History > 100 then table.remove(self.History, 1) end
            self.LastCommand = Name ~= "lastcommand" and Source or self.LastCommand
        end
        local Value = Entry.Callback(Arguments, Source)
        if Value ~= nil then self:Notify(Value) end
    end)
    if not Success then self:Notify(tostring(Failure)) end
    return Success, Failure
end

local function Add(Names, Description, Callback, Usage) return Admin:Add(Names, Description, Callback, Usage) end
local function Vector(Arguments, Start)
    Start = Start or 1
    return Vector3.new(Number(Arguments[Start], -100000, 100000), Number(Arguments[Start + 1], -100000, 100000), Number(Arguments[Start + 2], -100000, 100000))
end
local function Rest(Arguments, Start) return table.concat(Arguments, " ", Start or 1) end
local function FindPart(Query, Class)
    assert(Query and #Query > 0, "Enter an instance name")
    for _, Object in workspace:GetDescendants() do
        if (Class and Object.ClassName:lower() == Query:lower()) or (not Class and Object.Name:lower() == Query:lower()) then
            if Object.Position then return Object end
            if Object.GetPivot then return Object end
        end
    end
    error("Instance not found")
end
local function ObjectPosition(Object) return Object.Position or Object:GetPivot().Position end
local function CharacterParts(Model)
    local Result = {}
    for _, Object in Model:GetDescendants() do if Object:IsA("BasePart") or Object.ClassName == "Part" then Result[#Result + 1] = Object end end
    return Result
end
local function SelfProperty(Names, Property, Minimum, Maximum, Default)
    Add(Names, "Set your " .. Property, function(Arguments)
        local _, _, Humanoid = Character()
        assert(Humanoid, "Humanoid unavailable")
        local Value = Number(Arguments[1] or Default, Minimum, Maximum)
        Admin:Set(Humanoid, Property, Value)
        return Property .. " = " .. Value
    end, Names:match("^%S+") .. " <number>")
end

Add("cmds commands help", "List and search commands", function(Arguments)
    Admin.Mode = "Commands" Admin.Open = true Admin.Focused = true Admin.Text = Rest(Arguments) Admin.Scroll = 0
end)
Add("settings", "Open settings", function() Admin.Mode = "Settings" Admin.Open = true end)
Add("hideiy hide", "Hide the command panel", function() Admin.Open = false Admin.Focused = false end)
Add("showiy show", "Show the command panel", function() Admin.Open = true end)
Add("prefix", "Change the command prefix", function(Arguments) assert(Arguments[1] and #Arguments[1] == 1, "Enter one character") Admin.Prefix = Arguments[1] Admin:Save() end, "prefix <character>")
Add("saveconfig", "Save settings", function() Admin:Save() return "Settings saved" end)
Add("loadconfig", "Load settings", function() Admin:Load() return "Settings loaded" end)
Add("restore", "Undo property changes and stop loops", function() Admin:Restore() end)
Add("exit unload destroyiy", "Unload this script and restore changed properties", function() Admin.Stop() end)
Add("breakloops", "Stop running command loops", function() table.clear(Admin.Loops) Admin.Flying = false Admin.Float = false return "Loops stopped" end)
Add("lastcommand lastcmd", "Repeat the previous command", function() assert(Admin.LastCommand, "No command history") Admin:Run(Admin.LastCommand, 1) end)
Add("notify", "Display text", function(Arguments) return Rest(Arguments) end, "notify <text>")
Add("clearlogs", "Clear command output", function() table.clear(Admin.Log) Admin.Status = "" end)
Add("logs", "Show command output", function() Admin.Mode = "Logs" Admin.Open = true end)
Add("savelogs", "Save command output to Workspace", function() writefile("VortexAdminLog.txt", table.concat(Admin.Log, "\n")) return "Saved VortexAdminLog.txt" end)
Add("history", "Show command history", function() return table.concat(Admin.History, "\n") end)
Add("players", "Show connected players", function() Admin.Mode = "Players" Admin.Open = true end)
Add("serverinfo", "Show available client session data", function() return "Game " .. tostring(game.PlaceId or game.GameId or "unknown") .. " | " .. #Runtime.NativePlayers:GetPlayers() .. " players | " .. tostring(identifyexecutor()) end)
Add("addalias", "Create a command alias", function(Arguments)
    local Name = assert(Arguments[1], "Enter an alias"):lower()
    assert(Name:match("^[%w_%-]+$") and not Admin.Commands[Name], "Invalid or reserved alias")
    local Target = Rest(Arguments, 2) assert(#Target > 0, "Enter a command")
    Admin.Aliases[Name] = Target Admin:Save()
end, "addalias <name> <command>")
Add("removealias", "Remove an alias", function(Arguments) Admin.Aliases[assert(Arguments[1], "Enter an alias"):lower()] = nil Admin:Save() end)
Add("clraliases clearaliases", "Remove all aliases", function() table.clear(Admin.Aliases) Admin:Save() end)
Add("aliases", "Open aliases", function() Admin.Mode = "Aliases" Admin.Open = true end)
Add("bind keybind", "Bind a key to a command", function(Arguments)
    local Key = assert(Arguments[1], "Enter an Enum.KeyCode name")
    assert(Runtime.Keys[Key], "Unknown key")
    local Command = Rest(Arguments, 2) assert(#Command > 0, "Enter a command")
    Admin.Binds[Key] = Command Admin:Save()
end, "bind <KeyCode> <command>")
Add("unbind", "Remove a key binding", function(Arguments) Admin.Binds[assert(Arguments[1], "Enter a key")] = nil Admin:Save() end)
Add("clearbinds", "Remove key bindings", function() table.clear(Admin.Binds) Admin:Save() end)
Add("binds", "Open key bindings", function() Admin.Mode = "Binds" Admin.Open = true end)
Add("loop", "Repeat a command at a bounded interval", function(Arguments)
    local Name = assert(Arguments[1], "Enter a loop name")
    local Interval = Number(Arguments[2], 0.05, 3600)
    local Command = Rest(Arguments, 3) assert(#Command > 0, "Enter a command")
    Admin:Loop(Name, Interval, function() if not Admin:Run(Command, 1) then Admin.Loops[Name] = nil end end)
end, "loop <name> <seconds> <command>")
Add("unloop", "Stop a named loop", function(Arguments) Admin.Loops[assert(Arguments[1], "Enter a loop name")] = nil end)

SelfProperty("speed walkspeed ws", "WalkSpeed", 0, 500, 16)
SelfProperty("jumppower jumpower jpower jp", "JumpPower", 0, 500, 50)
SelfProperty("jumpheight jheight", "JumpHeight", 0, 200, 7.2)
SelfProperty("hipheight hheight", "HipHeight", -10, 100, 0)
SelfProperty("health", "Health", 0, 1000000, 100)
SelfProperty("maxhealth", "MaxHealth", 1, 1000000, 100)
for _, Entry in {{"loopspeed", "WalkSpeed", 16}, {"loopjumppower", "JumpPower", 50}} do
    local Name, Property, Default = Entry[1], Entry[2], Entry[3]
    Add(Name, "Keep " .. Property .. " set", function(Arguments)
        local Value = Number(Arguments[1] or Default, 0, 500)
        Admin:Loop(Name, 0.1, function() local _, _, H = Character() Admin:Set(H, Property, Value, false) end)
    end)
    Add("un" .. Name, "Stop " .. Name, function() Admin.Loops[Name] = nil end)
end
Add("sit", "Sit down", function() local _, _, H = Character() Admin:Set(H, "Sit", true) end)
Add("unsit", "Stand up", function() local _, _, H = Character() Admin:Set(H, "Sit", false) end)
Add("norotate", "Disable automatic character rotation", function() local _, _, H = Character() Admin:Set(H, "AutoRotate", false) end)
Add("unnorotate", "Enable automatic character rotation", function() local _, _, H = Character() Admin:Set(H, "AutoRotate", true) end)
Add("reset re respawn", "Reset your character using its health", function() local _, _, H = Character() Admin:Set(H, "Health", 0) end)
Add("heal", "Restore current health to maximum", function() local _, _, H = Character() Admin:Set(H, "Health", H.MaxHealth) end)
Add("freeze", "Freeze local character movement", function() local _, _, H = Character() Admin:Set(H, "WalkSpeed", 0) Admin:Set(H, "JumpPower", 0) end)
Add("thaw unfreeze", "Restore movement before freeze", function()
    local _, _, H = Character()
    local Values = Admin.Undo[H] or {}
    H.WalkSpeed = Values.WalkSpeed and Values.WalkSpeed.Value or 16
    H.JumpPower = Values.JumpPower and Values.JumpPower.Value or 50
end)
Add("goto to tp", "Move beside a player", function(Arguments)
    local Target = Admin:Players(Arguments[1])[1]
    Admin:Teleport(assert(Position(Target), "Target character unavailable") + Vector3.new(3, 0, 0))
end, "goto <player>")
Add("tweengoto tweento", "Move gradually beside a player", function(Arguments) Admin:TweenTo(assert(Position(Admin:Players(Arguments[1])[1]), "Target character unavailable") + Vector3.new(3, 0, 0)) end)
Add("tpposition teleportpos tppos", "Move to coordinates", function(Arguments) Admin:Teleport(Vector(Arguments)) end, "tpposition <x> <y> <z>")
Add("tweentpposition", "Move gradually to coordinates", function(Arguments) Admin:TweenTo(Vector(Arguments)) end)
Add("getposition pos", "Display current coordinates", function() local _, R = Character() return string.format("%.3f, %.3f, %.3f", R.Position.X, R.Position.Y, R.Position.Z) end)
Add("copyposition", "Copy current coordinates", function() local _, R = Character() setclipboard(string.format("%.3f, %.3f, %.3f", R.Position.X, R.Position.Y, R.Position.Z)) end)
Add("flashback back", "Return to the previous teleport location", function()
    assert(Admin.PositionHistory and #Admin.PositionHistory > 0, "No position history")
    local Point = table.remove(Admin.PositionHistory)
    Admin:Teleport(Point)
    table.remove(Admin.PositionHistory)
end)
Add("offset", "Move relative to your current position", function(Arguments) local _, R = Character() Admin:Teleport(R.Position + Vector(Arguments)) end)
Add("loopgoto", "Follow a player's position", function(Arguments)
    local Target = Admin:Players(Arguments[1])[1]
    Admin:Loop("LoopGoto", 0.1, function() local M, R = Character() local P = assert(Position(Target), "Target character unavailable") M:PivotTo(R.CFrame + (P + Vector3.new(3, 0, 0) - R.Position)) end)
end)
Add("unloopgoto", "Stop following a player", function() Admin.Loops.LoopGoto = nil end)
Add("setwaypoint", "Save your current location", function(Arguments)
    local Name = assert(Arguments[1], "Enter a waypoint name")
    local _, R = Character() Admin.Waypoints[Name] = {X = R.Position.X, Y = R.Position.Y, Z = R.Position.Z} Admin:Save()
end, "setwaypoint <name>")
Add("waypointpos", "Save coordinates as a waypoint", function(Arguments)
    local Name = assert(Arguments[1], "Enter a waypoint name")
    local Point = Vector(Arguments, 2) Admin.Waypoints[Name] = {X = Point.X, Y = Point.Y, Z = Point.Z} Admin:Save()
end)
Add("waypoint wp", "Move to a saved waypoint", function(Arguments)
    local Point = assert(Admin.Waypoints[Arguments[1]], "Waypoint not found") Admin:Teleport(Vector3.new(Point.X, Point.Y, Point.Z))
end)
Add("tweenwaypoint", "Move gradually to a waypoint", function(Arguments)
    local Point = assert(Admin.Waypoints[Arguments[1]], "Waypoint not found") Admin:TweenTo(Vector3.new(Point.X, Point.Y, Point.Z))
end)
Add("waypoints", "Open saved waypoints", function() Admin.Mode = "Waypoints" Admin.Open = true end)
Add("deletewaypoint", "Delete a saved waypoint", function(Arguments) Admin.Waypoints[assert(Arguments[1], "Enter a waypoint name")] = nil Admin:Save() end)
Add("clearwaypoints cleargamewaypoints", "Delete saved waypoints", function() table.clear(Admin.Waypoints) Admin:Save() end)
Add("spawnpoint", "Return here after a character replacement", function() local _, R = Character() Admin.SpawnPoint = R.Position return "Spawnpoint set" end)
Add("nospawnpoint", "Remove the local spawnpoint", function() Admin.SpawnPoint = nil end)
Add("tweenspeed", "Set gradual movement speed", function(Arguments) Admin.TweenSpeed = Number(Arguments[1], 1, 500) Admin:Save() end)
for _, Pair in {{"gotopart", false, false}, {"gotopartclass", true, false}, {"gotomodel", false, false}, {"tweengotopart", false, true}, {"tweengotopartclass", true, true}, {"tweengotomodel", false, true}} do
    local Name, Class, Tween = Pair[1], Pair[2], Pair[3]
    Add(Name, "Move to a matching instance", function(Arguments)
        local Point = ObjectPosition(FindPart(Rest(Arguments), Class)) + Vector3.new(0, 3, 0)
        if Tween then Admin:TweenTo(Point) else Admin:Teleport(Point) end
    end)
end
Add("fly cframefly", "Fly using BodyVelocity", function(Arguments) Character() if Arguments[1] then Admin.FlySpeed = Number(Arguments[1], 1, 500) end Admin:SetFlying(true) end)
Add("unfly uncframefly", "Stop flight", function() Admin:SetFlying(false) end)
Add("infjump infinitejump", "Jump again while in the air", function() Character() Admin.InfiniteJump = true end)
Add("uninfjump noinfinitejump", "Disable infinite jumping", function() Admin.InfiniteJump = false end)
Add("aimlock aimbot", "Aim the camera at the nearest living player", function() Character() Admin.Aimlock = true end)
Add("unaimlock unaimbot", "Release the camera aim lock", function() Admin.Aimlock = false end)
Add("togglefly", "Toggle transform flight", function() Character() Admin:SetFlying(not Admin.Flying) end)
Add("noclip", "Phase through nearby walls while preserving floor collision (experimental)", function() Character() Admin.Noclip = true end)
Add("clip unnoclip", "Disable wall phasing", function() Admin.Noclip = false end)
Add("togglenoclip", "Toggle wall phasing", function() Character() Admin.Noclip = not Admin.Noclip end)
Add("fov fieldofview", "Set camera field of view", function(Arguments) Admin:Set(workspace.CurrentCamera, "FieldOfView", Number(Arguments[1] or 70, 1, 120)) end)
Add("view spectate", "View a player's character", function(Arguments)
    local Other = Admin:Players(Arguments[1])[1]
    local Model = assert(Other.Character, "Character unavailable")
    Admin:Set(workspace.CurrentCamera, "CameraSubject", Model.Humanoid or Model.HumanoidRootPart, false)
end)
Add("unview unspectate fixcamera", "Return the camera to your character", function()
    local Model, Root, Humanoid = Character()
    workspace.CurrentCamera.CameraSubject = Humanoid or Root
end)
Add("follow", "Follow a player", function(Arguments)
    local Other = Admin:Players(Arguments[1])[1]
    Admin:Loop("Follow", 0.15, function()
        local _, _, Humanoid = Character()
        assert(Humanoid and type(Humanoid.MoveTo) == "function", "MoveTo is unavailable in this Vortex build")
        Humanoid:MoveTo(assert(Position(Other), "Target character unavailable"))
    end)
end)
Add("unfollow", "Stop following", function() Admin.Loops.Follow = nil end)
Add("unlookat", "Stop facing a player", function() Admin.Loops.Stare = nil end)
local function Lighting()
    local Value = game:GetService("Lighting")
    return assert(Value, "Lighting is unavailable in this Vortex build")
end
Add("fullbright", "Brighten local lighting", function() local L = Lighting() Admin:Set(L, "Brightness", 2) Admin:Set(L, "Ambient", Color3.new(1, 1, 1), false) end)
Add("nofog", "Remove local distance fog", function() local L = Lighting() Admin:Set(L, "FogEnd", 1000000) end)
Add("time", "Set local lighting time", function(Arguments) Admin:Set(Lighting(), "ClockTime", Number(Arguments[1] or 12, 0, 24)) end)
Add("brightness", "Set local brightness", function(Arguments) Admin:Set(Lighting(), "Brightness", Number(Arguments[1] or 1, 0, 100)) end)
Add("gravity grav", "Set local gravity", function(Arguments) Admin:Set(workspace, "Gravity", Number(Arguments[1] or 196.2, 0, 1000)) end)
Add("flyspeed cframeflyspeed", "Set flight speed", function(Arguments) Admin.FlySpeed = Number(Arguments[1], 1, 500) Admin:Save() end)
Add("qefly", "Toggle Q and E vertical controls", function() Admin.QeFly = not Admin.QeFly return "Q/E controls: " .. tostring(Admin.QeFly) end)
Add("float", "Keep your current height", function() local _, R = Character() Admin.FloatHeight = R.Position.Y Admin.Float = true end)
Add("unfloat", "Stop keeping height", function() Admin.Float = false end)
Add("togglefloat", "Toggle keeping your current height", function() local _, R = Character() Admin.FloatHeight = R.Position.Y Admin.Float = not Admin.Float end)
Add("spin", "Rotate the character continuously", function(Arguments) Admin.SpinSpeed = Number(Arguments[1] or 90, -1440, 1440) end)
Add("unspin", "Stop rotating", function() Admin.SpinSpeed = nil end)
Add("stareat lookat", "Face a player", function(Arguments)
    local Target = Admin:Players(Arguments[1])[1]
    Admin:Loop("Stare", 0, function() local M, R = Character() local Point = assert(Position(Target), "Target unavailable") M:PivotTo(CFrame.lookAt(R.Position, Vector3.new(Point.X, R.Position.Y, Point.Z))) end)
end)
Add("unstareat", "Stop facing a player", function() Admin.Loops.Stare = nil end)

for _, Pair in {{"copyname", "Name", true}, {"userid", "UserId", false}, {"copyid", "UserId", true}} do
    local Name, Property, Copy = Pair[1], Pair[2], Pair[3]
    Add(Name, "Read a player's " .. Property, function(Arguments)
        local Values = {} for _, Other in Admin:Players(Arguments[1]) do Values[#Values + 1] = tostring(Other[Property]) end
        local Text = table.concat(Values, ", ") if Copy then setclipboard(Text) else return Text end
    end)
end
Add("getcamera", "Display available camera data", function() local C = workspace.CurrentCamera return tostring(C.CFrame.Position) .. " | " .. tostring(C.ViewportSize) end)
Add("copyfreecamposition", "Copy the current camera position", function() local P = workspace.CurrentCamera.CFrame.Position setclipboard(string.format("%.3f, %.3f, %.3f", P.X, P.Y, P.Z)) end)
Add("notifyfreecamposition", "Display the current camera position", function() return tostring(workspace.CurrentCamera.CFrame.Position) end)
Add("gotocamera", "Move to the current camera", function() Admin:Teleport(workspace.CurrentCamera.CFrame.Position) end)
Add("tweengotocamera", "Move gradually to the camera", function() Admin:TweenTo(workspace.CurrentCamera.CFrame.Position) end)
Add("invisible", "Hide your character hitboxes locally", function() for _, Part in CharacterParts(Player.Character) do Admin:Set(Part, "Transparency", 1, false) end end)
Add("visible", "Restore character hitbox visibility", function()
    for _, Part in CharacterParts(Player.Character) do local Values = Admin.Undo[Part] if Values and Values.Transparency then Part.Transparency = Values.Transparency.Value end end
end)
Add("delete", "Delete matching local world objects", function(Arguments)
    local Name = assert(Arguments[1], "Enter an exact instance name") local Count = 0
    for _, Object in workspace:GetDescendants() do if Object.Name:lower() == Name:lower() then Object:Destroy() Count += 1 end end
    return "Deleted " .. Count .. " instances locally"
end)
Add("deleteclass", "Delete a local world class", function(Arguments)
    local Name = assert(Arguments[1], "Enter an exact class") local Count = 0
    for _, Object in workspace:GetDescendants() do if Object.ClassName:lower() == Name:lower() then Object:Destroy() Count += 1 end end
    return "Deleted " .. Count .. " instances locally"
end)
Add("chardelete", "Delete matching local character parts", function(Arguments)
    local Name = assert(Arguments[1], "Enter a part name") for _, Object in Player.Character:GetDescendants() do if Object.Name:lower() == Name:lower() then Object:Destroy() end end
end)
Add("chardeleteclass", "Delete a local character class", function(Arguments)
    local Name = assert(Arguments[1], "Enter a class") for _, Object in Player.Character:GetDescendants() do if Object.ClassName:lower() == Name:lower() then Object:Destroy() end end
end)
Add("invisibleparts", "Reveal transparent world parts locally", function()
    for _, Object in workspace:GetDescendants() do if type(Object.Transparency) == "number" and Object.Transparency >= 1 then Admin:Set(Object, "Transparency", 0.5, false) end end
end)
Add("uninvisibleparts", "Restore revealed world parts", function()
    for Object, Values in Admin.Undo do if Values.Transparency then pcall(function() Object.Transparency = Values.Transparency.Value end) end end
end)
Add("deleteinvisparts", "Delete transparent world parts locally", function()
    for _, Object in workspace:GetDescendants() do if type(Object.Transparency) == "number" and Object.Transparency >= 1 then Object:Destroy() end end
end)
Add("inspect", "Show matching instance properties", function(Arguments)
    local Object = FindPart(Rest(Arguments), false)
    return Object.ClassName .. " " .. Object.Name .. " | " .. tostring(ObjectPosition(Object))
end)
Add("bringpart", "Move a local part beside you", function(Arguments) local _, R = Character() local Part = FindPart(Rest(Arguments), false) Admin:Set(Part, "Position", R.Position + Vector3.new(3, 0, 0)) end)
Add("bringpartclass", "Move a matching local part beside you", function(Arguments) local _, R = Character() local Part = FindPart(Rest(Arguments), true) Admin:Set(Part, "Position", R.Position + Vector3.new(3, 0, 0)) end)
Add("anchoredparts", "List anchored world parts", function()
    local Names = {} for _, Object in workspace:GetDescendants() do if Object.Anchored == true then Names[#Names + 1] = Object.Name end end return table.concat(Names, ", ")
end)
Add("freezeunanchored", "Anchor unanchored world parts locally", function() for _, Object in workspace:GetDescendants() do if Object.Anchored == false then Admin:Set(Object, "Anchored", true, false) end end end)
Add("thawunanchored", "Restore anchored parts", function() for Object, Values in Admin.Undo do if Values.Anchored then pcall(function() Object.Anchored = Values.Anchored.Value end) end end end)
Add("deletevelocity", "Clear your current velocity", function() local _, R = Character() R.Velocity = Vector3.new(0, 0, 0) end)
Add("tpunanchored", "Move unanchored local parts beside you", function() local _, R = Character() for _, Object in workspace:GetDescendants() do if Object.Anchored == false and Object.Position then Admin:Set(Object, "Position", R.Position + Vector3.new(0, 3, 0), false) end end end)

Add("saveinstance savemap", "Save the client scene to Workspace", function(Arguments) local Path, Report = saveinstance(Arguments[1] or "Game.vrtx") return tostring(Path) .. " | " .. tostring(Report.Instances) .. " instances" end)
Add("loadscript execfile", "Run a Luau file from Workspace", function(Arguments) local Chunk = assert(loadfile(assert(Arguments[1], "Enter a Workspace script path"))) Chunk() end)
Add("explorer dex", "Load Dex explorer", function()
    local Url = "https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/Explorer.luau"
    local Chunk, Message = loadstring(game:HttpGet(Url))
    assert(Chunk, Message)
    Chunk()
end)
Add("scripts", "List accessible scripts", function() local Names = {} for _, Object in getscripts() do Names[#Names + 1] = Object.Name end return table.concat(Names, ", ") end)
Add("decompilescript", "Save accessible script source to Workspace", function(Arguments)
    local Name = assert(Arguments[1], "Enter a script name")
    for _, Script in getscripts() do if Script.Name == Name then
        local Source = decompile(Script)
        local FileName = Arguments[2] or Script.Name:gsub('[<>:"/\\|%?%*%c]', "_") .. ".luau"
        writefile(FileName, Source)
        return "Saved " .. FileName
    end end
    error("Script not found")
end)
Add("copyjobid", "Copy an exposed session identifier", function() local Id = game.JobId assert(type(Id) == "string" and #Id > 0, "Vortex does not expose a session identifier") setclipboard(Id) end)
Add("notifyjobid", "Read an exposed session identifier", function() local Id = game.JobId assert(type(Id) == "string" and #Id > 0, "Vortex does not expose a session identifier") return Id end)
Add("esp", "Load Unnamed ESP", function()
    local Chunk, Message = loadstring(game:HttpGet("https://raw.githubusercontent.com/Lebonbonn/Astra/main/scripts/UnnamedEsp.luau"))
    assert(Chunk, Message)
    Chunk()
end)
Add("noesp", "Disable the loaded ESP script", function() assert(getgenv().UnnamedEsp, "Run UnnamedEsp.luau first").Options.Enabled(false) end)
Add("espteam", "Toggle team display in the loaded ESP", function() assert(getgenv().UnnamedEsp, "Run UnnamedEsp.luau first").Options.ShowTeam() end)
Add("partesp locate", "Track an instance with the loaded ESP", function(Arguments) local Esp = assert(getgenv().UnnamedEsp, "Run UnnamedEsp.luau first") local Part = FindPart(Rest(Arguments), false) Esp.AddInstance(Part, Part.Name) end)
Add("unpartesp nolocate", "Stop tracking an instance", function(Arguments) local Esp = assert(getgenv().UnnamedEsp, "Run UnnamedEsp.luau first") Esp.RemoveInstance(FindPart(Rest(Arguments), false)) end)
Add("showwaypoints", "Draw saved waypoint markers", function() Admin.ShowWaypoints = true end)
Add("hidewaypoints", "Hide saved waypoint markers", function() Admin.ShowWaypoints = false end)
Add("autoclick", "Click while the Vortex window is active", function(Arguments)
    local Interval = Number(Arguments[1] or 0.1, 0.05, 10)
    Admin:Loop("AutoClick", Interval, function() if not Admin.Focused and iswindowactive() then mouse1click() end end)
end)
Add("unautoclick", "Stop automatic clicking", function() Admin.Loops.AutoClick = nil end)
Add("autokeypress", "Press a virtual key while Vortex is active", function(Arguments)
    local Code = Number(Arguments[1], 1, 254)
    local Interval = Number(Arguments[2] or 0.1, 0.05, 10)
    Admin:Loop("AutoKey", Interval, function() if not Admin.Focused and iswindowactive() then keyclick(Code) end end)
end)
Add("unautokeypress", "Stop automatic key presses", function() Admin.Loops.AutoKey = nil end)
Add("discord", "Copy the upstream Infinite Yield project link", function() setclipboard("https://github.com/EdgeIY/infiniteyield") end)

function Admin:RemovePlugin(Name)
    for Index = #self.Names, 1, -1 do
        local Entry = self.Commands[self.Names[Index]]
        if Entry.Plugin == Name then for _, Alias in Entry.Aliases do self.Commands[Alias] = nil end table.remove(self.Names, Index) end
    end
    self.Plugins[Name] = nil
end
Add("addplugin", "Load a compatible plugin from Workspace", function(Arguments)
    local File = assert(Arguments[1], "Enter a plugin file")
    assert(File:match("^[%w_%-]+%.luau$") or File:match("^[%w_%-]+%.iy$"), "Use a .luau or .iy file in Workspace")
    assert(not Admin.Plugins[File], "Plugin already loaded")
    local Chunk = assert(loadfile(File))
    local Parent = getfenv(Chunk)
    setfenv(Chunk, setmetatable({
        notify = function(Title, Message) Admin:Notify(tostring(Title) .. ": " .. tostring(Message or "")) end,
        execCmd = function(Command) Admin:Run(Command) end,
        getRoot = function(Model) return Model.HumanoidRootPart end,
        getPlayer = function(Selector) local Names = {} for _, Other in Admin:Players(Selector) do Names[#Names + 1] = Other.Name end return Names end,
    }, {__index = Parent}))
    local Plugin = Chunk()
    assert(type(Plugin) == "table" and type(Plugin.Commands) == "table", "Invalid plugin")
    local Added = {}
    local Success, Failure = pcall(function()
        for Name, Command in Plugin.Commands do
            assert(type(Name) == "string" and type(Command.Function) == "function", "Invalid plugin command")
            local Names = {Name}
            for _, Alias in Command.Aliases or {} do Names[#Names + 1] = Alias end
            local Entry = Admin:Add(Names, Command.Description or "Plugin command", function(Args) return Command.Function(Args, Player) end, Command.ListName or Name)
            Entry.Plugin = File Added[#Added + 1] = Entry
        end
    end)
    if not Success then Admin:RemovePlugin(File) error(Failure) end
    Admin.Plugins[File] = Plugin
    return "Loaded " .. File
end)
Add("removeplugin", "Unload a plugin", function(Arguments) Admin:RemovePlugin(assert(Arguments[1], "Enter a plugin file")) end)
Add("reloadplugin", "Reload a Workspace plugin", function(Arguments) local Name = assert(Arguments[1], "Enter a plugin file") Admin:RemovePlugin(Name) Admin:Run("addplugin " .. Name, 1) end)
Add("removecmd", "Remove a plugin command", function(Arguments)
    local Entry = assert(Admin.Commands[Arguments[1]], "Command not found") assert(Entry.Plugin, "Only plugin commands can be removed")
    for _, Name in Entry.Aliases do Admin.Commands[Name] = nil end
    for Index, Name in Admin.Names do if Name == Entry.Name then table.remove(Admin.Names, Index) break end end
end)
Add("plugins", "List loaded plugins", function() local Names = {} for Name in Admin.Plugins do Names[#Names + 1] = Name end return #Names > 0 and table.concat(Names, ", ") or "No plugins loaded" end)

local WaypointDrawings = {}
local LastCharacter = nil
local LastCharacterCheck = 0
Runtime.NeedsProjection = function() return Admin.ShowWaypoints == true end

function Admin:SetFlying(Enabled)
    if self.Flight then
        local Flight = self.Flight
        self.Flight = nil
        pcall(function() Flight.Body:Destroy() end)
    end
    self.Flying = false
    if not Enabled then return end
    local Model = Player.Character
    local Root = Model and Model.HumanoidRootPart
    assert(Root, "Character unavailable")
    local Body = Instance.new("BodyVelocity")
    local Success, Failure = pcall(function()
        Body.MaxForce = rawget(Vector3, "new")(1e5, 1e5, 1e5)
        Body.Velocity = rawget(Vector3, "new")(0, 0, 0)
        Body.Parent = Root
    end)
    if not Success then pcall(function() Body:Destroy() end) error(Failure) end
    self.Flight = {Body = Body, Character = Model._id}
    self.Flying = true
    self.Float = false
end

Runtime.Jobs[#Runtime.Jobs + 1] = {Cancel = function() Admin:SetFlying(false) end}
Runtime.Connect(Input.InputBegan, function(Event, Processed)
    if Admin.InfiniteJump and Runtime.KeyName(Event.KeyCode) == "Space" and not Processed and not Admin.Focused and not Runtime.InterfaceActive then
        Runtime.Try("Jump", function()
            local Model = Player.Character
            local Root, Humanoid = Model and Model.HumanoidRootPart, Model and Model.Humanoid
            if not Root then return end
            if Admin.JumpBody then pcall(function() Admin.JumpBody:Destroy() end) end
            local Body = Instance.new("BodyVelocity")
            Body.MaxForce = rawget(Vector3, "new")(0, 1e5, 0)
            Body.Velocity = rawget(Vector3, "new")(0, Humanoid and Humanoid.JumpPower or 50, 0)
            Body.Parent = Root
            Admin.JumpBody = Body
            task.delay(0.12, function() pcall(function() Body:Destroy() end) if Admin.JumpBody == Body then Admin.JumpBody = nil end end)
        end)
    end
end)

Runtime.Step("Aimlock", 250, function()
    if not Admin.Aimlock then return end
    local LocalRoot = Player.Character and Player.Character.HumanoidRootPart
    if not LocalRoot then return end
    local Target, Distance
    for _, Other in Runtime.NativePlayers:GetPlayers() do
        local Model = Other.Character
        local Root = Model and (Model.Head or Model.HumanoidRootPart)
        local Humanoid = Model and Model.Humanoid
        if Other.UserId ~= Player.UserId and Root and (not Humanoid or Humanoid.Health > 0) then
            local Current = (Root.Position - LocalRoot.Position).Magnitude
            if not Distance or Current < Distance then Target, Distance = Root, Current end
        end
    end
    if Target then
        local Camera = workspace.CurrentCamera
        Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, Target.Position)
    end
end)

Runtime.Step("AdminMovement", 100, function(Delta)
    if Admin.Flying or Admin.Float or Admin.SpinSpeed then
        local Model = Player.Character
        local Root = Model and Model.HumanoidRootPart
        if not Root then Admin:SetFlying(false) Admin.Float = false Admin.SpinSpeed = nil return end
        if Admin.Flying then
            if not Admin.Flight or Admin.Flight.Character ~= Model._id then Admin:SetFlying(true) end
            local Frame = workspace.CurrentCamera.CFrame
            local Movement = rawget(Vector3, "new")(0, 0, 0)
            if not Admin.Focused and not Runtime.InterfaceActive then
                if Input:IsKeyDown(Enum.KeyCode.W) then Movement += Frame.LookVector end
                if Input:IsKeyDown(Enum.KeyCode.S) then Movement -= Frame.LookVector end
                if Input:IsKeyDown(Enum.KeyCode.D) then Movement += Frame.RightVector end
                if Input:IsKeyDown(Enum.KeyCode.A) then Movement -= Frame.RightVector end
                if Input:IsKeyDown(Enum.KeyCode.Space) or Admin.QeFly and Input:IsKeyDown(Enum.KeyCode.E) then Movement += rawget(Vector3, "new")(0, 1, 0) end
                if Input:IsKeyDown(Enum.KeyCode.LeftControl) or Admin.QeFly and Input:IsKeyDown(Enum.KeyCode.Q) then Movement -= rawget(Vector3, "new")(0, 1, 0) end
            end
            local Direction = Runtime.Unit(Movement)
            Admin.Flight.Body.Velocity = Direction and Direction * Admin.FlySpeed or rawget(Vector3, "new")(0, 0, 0)
        end
        if Admin.Float or Admin.SpinSpeed then
            local Frame = Root.CFrame
            if Admin.Float then Frame += rawget(Vector3, "new")(0, Admin.FloatHeight - Root.Position.Y, 0) end
            if Admin.SpinSpeed then Frame *= CFrame.Angles(0, math.rad(Admin.SpinSpeed) * math.clamp(Delta, 0, 0.1)) end
            Model:PivotTo(Frame)
        end
    end
    if Runtime.Time() - LastCharacterCheck >= 0.25 then
        LastCharacterCheck = Runtime.Time()
        local Model = Player.Character
        local Identifier = Model and Model._id
        if Identifier and Identifier ~= LastCharacter then
            LastCharacter = Identifier
            if Admin.SpawnPoint then Runtime.Defer(function() Admin:Teleport(Admin.SpawnPoint) end) end
        end
    end
end)

Runtime.Step("AdminLoops", 200, function()
    local Ready = {}
    for Name, Loop in Admin.Loops do
        if Runtime.Time() >= Loop.At then
            Loop.At = Runtime.Time() + Loop.Interval
            Ready[#Ready + 1] = {Name = Name, Loop = Loop}
        end
    end
    for _, Item in Ready do
        local Success, Failure = pcall(Item.Loop.Callback)
        if not Success then Admin.Loops[Item.Name] = nil Admin:Notify(Item.Name .. ": " .. tostring(Failure)) end
    end
end)

local LastPhase = 0
Runtime.Step("WallPhase", 110, function()
    if not Admin.Noclip or Admin.Focused or Runtime.InterfaceActive or not Runtime.Foreground then return end
    local Now = Runtime.Time()
    if Now - LastPhase < 0.08 then return end
    LastPhase = Now
    local Model = Player.Character
    local Root = Model and Model.HumanoidRootPart
    if not Root then return end
    local Frame = workspace.CurrentCamera.CFrame
    local Direction = rawget(Vector3, "new")(0, 0, 0)
    if Input:IsKeyDown(Enum.KeyCode.W) then Direction += Frame.LookVector end
    if Input:IsKeyDown(Enum.KeyCode.S) then Direction -= Frame.LookVector end
    if Input:IsKeyDown(Enum.KeyCode.D) then Direction += Frame.RightVector end
    if Input:IsKeyDown(Enum.KeyCode.A) then Direction -= Frame.RightVector end
    Direction = Runtime.Unit(rawget(Vector3, "new")(Direction.X, 0, Direction.Z))
    if not Direction then return end
    local Filter = {FilterDescendantsInstances = {Model}, FilterType = Enum.RaycastFilterType.Exclude}
    local Origin = Root.Position
    local Hit = workspace:Raycast(Origin, Direction * 3, Filter)
    if not Hit then return end
    local Normal = Runtime.Read(Hit, "Normal")
    if not Normal then Admin.Noclip = false Admin:Notify("Noclip requires raycast surface normals") return end
    if math.abs(Normal.Y) > 0.5 then return end
    local Exit = workspace:Raycast(Origin + Direction * 12, Direction * -12, Filter)
    if not Exit or Exit.Instance ~= Hit.Instance or not Exit.Normal or Exit.Normal.X * Direction.X + Exit.Normal.Z * Direction.Z <= 0 then return end
    local Target = Exit.Position + Direction * (math.max(Root.Size.X, Root.Size.Z) / 2 + 0.5)
    Target = rawget(Vector3, "new")(Target.X, Origin.Y, Target.Z)
    local Floor = workspace:Raycast(Target, rawget(Vector3, "new")(0, -math.max(6, Root.Size.Y + 3), 0), Filter)
    if not Floor or not Floor.Normal or Floor.Normal.Y < 0.5 then return end
    Model:PivotTo(Root.CFrame + (Target - Origin))
end)

Runtime.Step("AdminWaypoints", 250, function()
    for _, Object in WaypointDrawings do Object.Visible = false end
    if not Admin.ShowWaypoints or not Runtime.View then return end
    for Name, Point in Admin.Waypoints do
        if type(Point) == "table" and type(Point.X) == "number" and type(Point.Y) == "number" and type(Point.Z) == "number" then
            local Screen, Visible = Runtime.Project(rawget(Vector3, "new")(Point.X, Point.Y, Point.Z))
            if Visible then
                if not WaypointDrawings[Name] then WaypointDrawings[Name] = Runtime.Drawing("Text", {Size = 14, Font = Drawing.Fonts.Monospace, Center = true, Outline = true, Color = Color3.new(1, 1, 1)}) end
                local Object = WaypointDrawings[Name]
                Object.Text = Name
                Object.Position = Vector2.new(Screen.X, Screen.Y)
                Object.Visible = true
            end
        end
    end
end)
Runtime.Step("AdminInterface", 300, function() Admin:Draw() end)

function Admin.Stop(KeepChanges)
    if not Runtime.Alive then return end
    Admin:SetFlying(false)
    if Admin.JumpBody then pcall(function() Admin.JumpBody:Destroy() end) Admin.JumpBody = nil end
    if not KeepChanges then Admin:Restore() end
    Runtime.Stop()
    if getgenv().VortexAdmin == Admin then getgenv().VortexAdmin = nil end
end

Admin.Runtime = Runtime
Runtime.Try("Settings", function() Admin:Load() end)
getgenv().VortexAdmin = Admin
Admin:Notify("Infinite Yield for Vortex loaded. " .. Admin.Prefix .. " opens the command bar")
Runtime.Start()
return Admin
