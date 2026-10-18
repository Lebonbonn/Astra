local CreateUiLibrary = (function()
local function CreateLibrary(Drawing, Services)
    local Library = {UiVersion = 5}
    local HoveredItem
    local HoverChain = {}
    local Items, Connections = {}, {}
    local Focus, Pressed, Secondary, Drag, Context, Input, Running
    local Pointer = Vector2.new(0, 0)
    local Keys = {}
    local NextId = 0
    local Dirty = true
    local PaintDirty = true
    local LastBlink = -1
    local LayoutVersion = 0
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
            if not Equal then Entry.Object[Property] = Value Entry.Values[Property] = Value end
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
        for _, Name in {"Focused", "FocusLost", "TextChanged", "Changed", "InputBegan", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up"} do
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
        local Control = Keys.LeftControl or Keys.RightControl or Keys.Control
        local Shift = Keys.LeftShift or Keys.RightShift or Keys.Shift
        Item.InputBegan:Fire(KeyName, Control == true, Shift == true)
        if Control and (KeyName == "Z" or KeyName == "Y") then
            local Source = KeyName == "Z" and Item.UndoItems or Item.RedoItems
            local Destination = KeyName == "Z" and Item.RedoItems or Item.UndoItems
            local State = table.remove(Source)
            if State then Destination[#Destination + 1] = {Text = Item.Text, Cursor = Item.Cursor, Anchor = Item.Anchor} Item.Text = State.Text Item.Cursor = State.Cursor Item.Anchor = State.Anchor end
        elseif Control and KeyName == "A" then Item:SelectAll()
        elseif Control and (KeyName == "C" or KeyName == "X" or KeyName == "Insert") or Shift and KeyName == "Delete" then
            local Text = Item:GetSelection()
            if #Text > 0 and type(setclipboard) == "function" then setclipboard(Text) end
            if (KeyName == "X" or KeyName == "Delete") and #Text > 0 then Replace(Item, "") end
        elseif KeyName == "Backspace" or KeyName == "Delete" then
            if Item.Cursor == Item.Anchor then
                if KeyName == "Backspace" then Item.Anchor = Before(Item.Text, Item.Cursor) else Item.Anchor = After(Item.Text, Item.Cursor) end
            end
            Replace(Item, "")
        elseif KeyName == "Left" or KeyName == "Right" then
            Item.Cursor = KeyName == "Left" and Before(Item.Text, Item.Cursor) or After(Item.Text, Item.Cursor)
            if not Shift then Item.Anchor = Item.Cursor end
        elseif KeyName == "Home" or KeyName == "End" then
            Item.Cursor = KeyName == "Home" and 0 or #Item.Text
            if not Shift then Item.Anchor = Item.Cursor end
        elseif KeyName == "Escape" then Item:ReleaseFocus(false)
        elseif KeyName == "Return" or KeyName == "Enter" then
            if Item.Multiline and not Control then Replace(Item, "\n") else Item:ReleaseFocus(true) end
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
        if Hit.Kind == "TextBox" then
            Hit:CaptureFocus()
            Hit.Cursor = Caret(Hit)
            if not Keys.LeftShift and not Keys.RightShift then Hit.Anchor = Hit.Cursor end
            Hit.LastPointerX = Pointer.X
        elseif Hit.Draggable then Drag = {Item = Hit, Offset = Pointer - Hit.Position}
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
        Pressed, Drag = nil, nil
        if Item and not Item.Destroyed then
            Item.MouseButton1Up:Fire()
            if Inside(Pointer, Bounds(Item)) and CanHit(Item) then
                if Item.Kind == "Checkbox" then Item.Value = not Item.Value end
                Item.MouseButton1Click:Fire()
            end
        end
    end
    local Virtual = {[8] = "Backspace", [9] = "Tab", [13] = "Return", [16] = "LeftShift", [17] = "LeftControl", [27] = "Escape", [32] = "Space", [35] = "End", [36] = "Home", [37] = "Left", [39] = "Right", [45] = "Insert", [46] = "Delete", [160] = "LeftShift", [161] = "RightShift", [162] = "LeftControl", [163] = "RightControl"}
    for Code = 65, 90 do Virtual[Code] = string.char(Code) end
    local function Paint(Item)
        local Box = Bounds(Item)
        if not Box then for _, Entry in Item.Shapes do if Entry.Values.Visible ~= false then Entry.Object.Visible = false Entry.Values.Visible = false end end return end
        Item.AbsolutePosition = Vector2.new(Box.X, Box.Y)
        Item.AbsoluteSize = Item.Size
        local Layer = GetLayer(Item)
        local Base = {Visible = true, Position = Item.AbsolutePosition, Size = Item.Size, Filled = true, Color = Item.BackgroundColor3, Transparency = 1 - Item.BackgroundTransparency, ZIndex = Layer}
        if HoverChain[Item] and not Item.Multiline then
            Base.Color = Item.HoverColor3 or Base.Color
            if Item.HoverTransparency ~= nil then Base.Transparency = 1 - Item.HoverTransparency end
        end
        if Item.Kind ~= "TextLabel" and Item.Kind ~= "ImageLabel" then Shape(Item, "Background", "Square", Base) end
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
            if Item.Kind == "Checkbox" then Text = (Item.Value and "[x] " or "[ ] ") .. Text end
            if Item.Kind == "Slider" then Text ..= " " .. string.format("%.2f", Item.Value) end
            local Empty = Text == "" and Focus ~= Item
            if Empty then Text = Item.PlaceholderText end
            local Label = Shape(Item, "Text", "Text", {Visible = true, Text = Text, Position = Vector2.new(Box.X + Item.Padding - Offset, Box.Y + (Item.Multiline and 3 or math.max(0, (Box.Height - Item.TextSize) / 2))), Size = Item.TextSize,
                Color = Empty and Item.PlaceholderColor3 or Item.TextColor3, Font = Item.Font, ZIndex = Layer + 1, Outline = false})
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
        if not Active then table.clear(Keys) Pressed, Drag = nil, nil end
        if Context then
            local Position = Context:getpointer()
            if Position then Pointer = Vector2.new(Position.X, Position.Y) end
            for _, Event in Context:getevents() do
                if Event.Type == "KeyDown" then local KeyName = Virtual[Event.Code] or "Unknown" Keys[KeyName] = true Key(KeyName, Event.Repeat)
                elseif Event.Type == "KeyUp" then Keys[Virtual[Event.Code] or "Unknown"] = nil
                elseif Event.Type == "Text" or Event.Type == "Paste" then if Focus then Replace(Focus, Event.Text) end
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
        if Pressed and Pressed.Kind == "TextBox" and (Pressed.LastPointerX ~= Pointer.X or Pressed.LastPointerY ~= Pointer.Y) then Pressed.Cursor = Caret(Pressed) Pressed.LastPointerX, Pressed.LastPointerY = Pointer.X, Pointer.Y end
        if Pressed and Pressed.Kind == "Slider" then
            local Box = Bounds(Pressed)
            if Box then Pressed.Value = Pressed.Min + math.clamp((Pointer.X - Box.X) / math.max(Box.Width, 1), 0, 1) * (Pressed.Max - Pressed.Min) end
        end
        local Blink = Focus and math.floor((Clock and Clock() or Elapsed) * 2) or -1
        if Blink ~= LastBlink then LastBlink = Blink PaintDirty = true end
        local Hovered
        for Index = #Items, 1, -1 do
            local Item = Items[Index]
            if Active and not Item.Destroyed and Item.Active and Inside(Pointer, Bounds(Item)) and CanHit(Item) then Hovered = Item break end
        end
        if Hovered ~= HoveredItem then
            HoveredItem = Hovered
            table.clear(HoverChain)
            local Item = Hovered
            while Item do HoverChain[Item] = true Item = Item.Parent end
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
        assert(#Items < 512, "UI control limit reached")
        NextId += 1
        local Data = {Kind = Kind, Id = NextId, Position = Vector2.new(0, 0), Size = Vector2.new(200, 30), Visible = true, Active = true, ZIndex = 1000,
            BackgroundColor3 = Color3.fromRGB(28, 28, 30), BackgroundTransparency = 0, TextColor3 = Color3.fromRGB(235, 235, 238), PlaceholderColor3 = Color3.fromRGB(130, 130, 138),
            Text = "", PlaceholderText = "", TextSize = 16, Font = Drawing.Fonts.Monospace or 3, Padding = 6, MaxLength = 65536, TextEditable = true, ClearTextOnFocus = false,
            Cursor = 0, Anchor = 0, Value = false, Min = 0, Max = 100, Multiline = false, Draggable = false, ClipsDescendants = false, ScrollOffset = 0, CanvasSize = 0,
            Shapes = {}, ChangedEvents = {}, UndoItems = {}, RedoItems = {}, Destroyed = false}
        if Kind == "Slider" then Data.Value = 0 end
        for _, Event in {"Focused", "FocusLost", "TextChanged", "Changed", "InputBegan", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up"} do Data[Event] = Signal() end
        local Object
        Object = setmetatable({}, {__index = function(_, Key) return Methods[Key] or Data[Key] end, __newindex = function(_, Key, Value)
            assert(not Data.Destroyed or Key == "Destroyed", "UI control was destroyed")
            if Key == "Parent" then
                local Parent, Depth = Value, 0
                while Parent do assert(Parent ~= Object and Library.isui(Parent) and Depth < 64, "Invalid UI parent") Parent = Parent.Parent Depth += 1 end
            elseif Key == "Text" then assert(type(Value) == "string" and #Value <= 65536, "Invalid text")
            elseif Key == "Position" or Key == "Size" then assert(Value and type(Value.X) == "number" and type(Value.Y) == "number" and Value.X == Value.X and Value.Y == Value.Y and math.abs(Value.X) <= 65536 and math.abs(Value.Y) <= 65536, "Invalid UI bounds")
            elseif Key == "MaxLength" then assert(type(Value) == "number" and Value >= 0 and Value <= 65536, "Invalid text limit") end
            if Key == "ZIndex" or Key == "TextSize" or Key == "Padding" or Key == "Font" or Key == "Cursor" or Key == "Anchor" or Key == "CanvasSize" or Key == "ScrollOffset" or Key == "Min" or Key == "Max" then
                assert(type(Value) == "number" and Value == Value and math.abs(Value) <= 65536, "Invalid UI number")
            elseif Key == "BackgroundTransparency" or Key == "HoverTransparency" then assert(type(Value) == "number" and Value >= 0 and Value <= 1, "Invalid transparency")
            elseif Key == "TextColor3" or Key == "BackgroundColor3" or Key == "PlaceholderColor3" or Key == "HoverColor3" then assert(Value and type(Value.R) == "number" and type(Value.G) == "number" and type(Value.B) == "number", "Invalid UI color") end
            if Key == "TextSize" then assert(Value >= 1 and Value <= 10000, "Invalid text size") end
            if Key == "Value" and Data.Kind == "Slider" then assert(type(Value) == "number" and Value == Value and math.abs(Value) <= 65536, "Invalid slider value") end
            if Data[Key] == Value then return end
            if (Key == "Position" or Key == "Size") and Data[Key] and Data[Key].X == Value.X and Data[Key].Y == Value.Y then return end
            if Key == "Position" or Key == "Size" or Key == "Visible" or Key == "Parent" or Key == "ScrollOffset" or Key == "Destroyed" then LayoutVersion += 1 end
            if Key ~= "AbsolutePosition" and Key ~= "AbsoluteSize" and Key ~= "TextOffset" and Key ~= "LastPointerX" then PaintDirty = true end
            Data[Key] = Value
            if Key == "Text" then Data.Cursor = math.min(Data.Cursor, #Value) Data.Anchor = math.min(Data.Anchor, #Value) Data.TextChanged:Fire(Value) end
            if Key == "ZIndex" or Key == "Parent" then Dirty = true end
            if Data.ChangedEvents[Key] then Data.ChangedEvents[Key]:Fire() end
            Data.Changed:Fire(Key)
        end})
        if Properties then for Key, Value in Properties do Object[Key] = Value end end
        Items[#Items + 1] = Object
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
local Icons = {
["Attachment"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\070\073\068\065\084\120\156\117\147\207\075\084\081\020\199\063\231\190\247\070\107\176\210\008\170\069\063\192\212\212\022\082\180\106\081\068\171\036\194\034\218\021\132\248\007\184\041\162\070\003\177\054\109\130\090\246\139\032\146\108\104\225\198\117\080\096\063\022\058\110\106\101\008\005\217\015\135\178\153\123\239\137\251\102\070\028\211\243\184\028\238\187\239\251\061\223\115\190\247\193\186\161\082\073\213\188\078\200\218\216\021\032\017\109\157\208\077\025\203\048\158\087\133\211\060\071\043\239\215\038\080\149\218\033\057\053\109\007\105\137\044\119\050\091\057\111\191\243\090\055\115\162\112\148\223\085\114\111\234\192\207\052\010\224\238\188\158\236\122\169\055\025\022\031\121\006\002\184\252\131\207\226\184\094\056\038\197\000\076\023\016\175\170\236\218\243\186\083\133\209\104\035\007\186\095\168\181\009\143\236\034\135\188\229\081\225\140\076\030\156\210\228\207\028\215\005\062\116\150\201\075\029\193\024\166\171\129\123\038\161\223\149\176\038\033\118\101\070\103\191\144\099\030\215\222\067\214\120\114\073\051\131\118\145\169\082\204\241\180\133\156\170\009\210\247\039\156\069\184\228\029\078\032\082\135\143\018\174\116\110\103\036\109\071\184\144\108\097\208\021\249\038\202\232\199\055\020\165\054\180\246\188\054\025\097\034\206\112\196\151\112\064\020\116\165\179\138\017\111\025\241\150\167\081\194\109\181\060\041\244\201\195\128\141\025\074\157\208\140\101\155\139\217\171\014\069\049\085\127\036\236\130\018\019\115\085\020\223\249\150\222\177\097\041\081\081\237\151\093\040\197\044\033\044\034\233\083\177\177\066\017\118\070\045\078\050\092\155\238\225\214\238\251\218\088\083\103\024\074\107\200\047\195\015\081\230\165\066\089\209\145\014\055\205\086\034\034\181\168\017\178\217\108\213\061\085\009\004\233\012\090\044\059\212\176\039\200\021\033\009\077\104\032\018\196\052\018\123\199\156\043\115\113\230\020\003\133\115\233\093\208\176\036\016\117\140\235\086\099\120\016\053\208\235\203\129\152\175\002\077\018\177\193\059\150\128\188\056\110\204\244\201\236\234\139\027\183\062\214\077\081\204\221\040\075\175\043\242\211\011\151\141\099\146\152\022\045\209\108\012\011\211\239\121\023\108\172\013\174\142\032\206\146\168\103\151\255\203\002\208\063\123\074\198\171\103\159\234\074\229\254\007\047\071\199\184\182\237\123\166\135\151\063\012\149\086\230\218\175\189\070\252\003\046\123\010\089\020\098\180\255\000\000\000\000\073\069\078\068\174\066\096\130",
["BodyVelocity"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\049\073\068\065\084\120\156\117\146\205\075\148\081\020\198\127\231\190\051\147\070\089\147\100\100\038\210\007\077\126\068\031\208\170\144\008\203\002\201\032\133\054\253\007\021\005\173\043\104\213\034\016\172\160\101\031\016\150\057\126\208\066\105\081\155\090\148\006\126\225\066\009\019\033\132\022\154\056\233\188\239\019\239\232\224\168\211\129\203\057\247\220\231\185\231\060\231\094\200\049\003\154\218\228\237\107\251\189\045\220\075\178\112\031\198\181\109\218\082\255\094\155\194\092\118\133\121\199\074\016\122\001\159\203\136\021\020\196\091\015\039\117\195\204\244\166\217\252\068\167\234\102\098\188\157\094\162\052\204\133\132\208\135\180\008\043\065\198\075\054\005\169\234\046\158\007\070\075\085\135\246\007\198\184\019\055\005\143\226\069\252\204\020\204\114\050\029\228\218\242\129\013\093\178\190\088\148\090\057\014\057\113\093\001\087\071\026\237\113\201\012\202\037\175\189\064\203\082\118\245\082\152\072\234\117\202\231\194\072\063\023\255\078\082\157\022\170\076\170\119\196\167\034\023\027\090\100\077\245\187\114\191\206\219\252\206\164\094\004\001\045\085\199\072\248\001\099\158\199\061\065\235\176\199\143\101\009\057\077\179\222\036\135\089\112\176\091\123\162\062\175\204\168\008\196\181\209\070\251\132\228\097\230\175\081\205\042\211\192\116\162\075\155\023\196\083\223\232\242\082\116\167\226\020\198\102\217\235\121\060\112\105\110\015\094\177\137\220\065\186\156\187\050\175\240\173\129\005\015\122\060\241\208\098\220\041\152\227\156\139\144\020\012\204\022\051\189\254\021\044\143\132\012\160\178\067\071\049\158\152\081\106\142\091\067\013\214\177\001\155\087\191\086\039\092\211\163\120\101\167\014\108\192\100\228\254\175\003\224\072\187\074\210\112\028\071\061\198\014\115\244\005\139\124\025\029\100\156\251\022\172\027\162\050\195\107\146\188\225\046\234\036\046\059\227\100\216\128\069\241\044\068\248\160\052\147\130\126\051\122\211\226\229\088\035\127\080\206\063\152\120\134\099\055\167\013\154\045\202\118\243\064\139\016\004\224\098\096\017\202\131\069\202\021\016\137\026\239\192\230\194\226\027\036\212\180\171\204\143\112\022\168\007\078\153\216\138\241\085\240\193\137\190\226\109\124\255\120\198\210\217\206\243\206\032\107\137\118\085\203\081\052\191\196\192\084\179\045\228\195\252\003\112\062\250\102\024\067\029\037\000\000\000\000\073\069\078\068\174\066\096\130",
["BoolValue"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\210\073\068\065\084\120\156\109\083\077\104\083\065\016\158\217\159\151\054\210\106\197\030\074\052\047\033\080\068\068\209\082\111\138\069\233\069\042\030\180\032\222\196\131\158\138\226\073\170\165\032\136\224\065\020\010\162\072\021\234\191\120\240\230\041\005\127\064\016\065\081\180\197\188\228\021\027\042\053\086\011\249\233\219\157\145\077\077\208\226\028\118\216\217\153\143\111\230\219\065\000\064\000\224\032\008\090\180\214\157\068\068\224\130\136\200\204\156\076\038\191\186\059\051\215\067\176\194\208\029\097\024\238\034\162\097\068\140\035\162\075\006\034\066\033\132\003\249\132\136\195\190\239\207\254\015\004\167\167\167\055\120\158\247\008\000\158\001\192\061\041\165\033\034\015\017\171\000\176\214\090\123\006\000\190\251\190\127\204\017\089\009\032\180\214\091\001\224\023\017\221\097\230\179\204\076\201\100\242\189\181\118\007\017\029\146\082\094\000\128\237\097\024\174\254\195\014\255\001\192\229\094\201\243\188\002\000\020\173\181\055\103\102\102\134\028\109\099\204\043\099\204\130\139\027\099\200\181\230\106\254\001\224\229\198\100\177\088\140\082\169\212\073\034\154\239\234\234\186\204\204\099\153\076\230\113\058\157\254\204\204\039\226\241\184\017\066\184\092\219\024\170\243\074\041\005\081\020\065\079\079\015\228\243\249\035\204\188\126\110\110\238\062\034\110\014\130\096\141\148\242\008\017\237\171\213\106\157\065\016\204\002\192\003\223\247\239\034\162\083\011\085\020\069\074\008\081\203\229\114\105\165\212\041\102\062\159\072\036\158\132\097\216\139\136\183\181\214\003\082\202\134\050\206\239\047\020\010\059\167\166\166\134\038\038\038\034\069\068\095\016\049\033\165\236\005\128\193\241\241\241\192\081\035\162\003\109\109\109\003\139\139\139\142\178\163\075\082\074\151\255\011\017\015\199\098\177\183\163\163\163\215\234\125\020\010\133\227\204\124\028\000\022\152\249\181\214\250\106\020\069\147\090\107\159\136\220\156\072\107\045\150\150\150\126\034\226\065\107\237\081\041\101\074\041\181\183\041\073\062\159\223\036\165\220\104\140\201\073\041\053\051\191\032\162\151\082\202\167\074\169\075\068\244\195\090\059\136\136\235\060\207\187\094\173\086\191\106\173\251\149\043\030\025\025\017\169\084\234\035\000\124\108\128\033\226\079\173\117\198\090\059\105\140\057\109\173\253\098\173\237\212\090\223\082\074\105\000\088\068\196\074\147\001\051\139\108\054\091\215\056\145\072\200\150\150\150\135\029\029\029\003\165\082\233\093\044\022\235\175\084\042\123\060\207\187\097\140\209\173\173\173\170\082\169\092\241\125\127\168\249\041\156\044\125\125\125\038\155\205\082\119\119\119\141\136\046\150\074\165\249\246\246\246\045\213\106\245\185\016\098\076\008\209\026\143\199\085\185\092\254\084\171\213\174\052\151\105\165\053\150\038\008\130\221\066\136\097\034\218\041\132\240\152\249\059\034\078\002\192\057\223\247\063\212\243\254\007\240\055\072\177\088\092\085\046\151\183\001\064\007\034\126\075\167\211\111\016\209\052\222\127\003\097\101\137\167\030\013\225\136\000\000\000\000\073\069\078\068\174\066\096\130",
["Camera"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\110\073\068\065\084\120\156\141\082\061\104\083\081\020\062\231\220\247\072\083\176\054\234\018\033\127\198\082\008\088\020\023\093\004\117\144\014\254\076\078\130\184\185\137\168\136\032\062\002\058\009\046\010\130\131\139\147\116\209\065\065\151\014\074\193\169\226\096\167\250\222\011\137\084\169\081\180\033\109\239\203\249\228\198\188\082\083\007\015\220\123\057\247\252\127\223\033\026\008\000\118\039\008\002\113\047\013\137\251\079\109\091\236\065\016\200\112\064\028\199\185\070\163\177\195\157\133\133\133\109\195\118\000\253\024\078\063\194\048\028\207\102\179\153\078\167\067\158\231\093\001\112\130\153\127\013\124\070\137\232\145\231\121\051\190\239\251\189\094\239\103\062\159\239\108\036\008\195\240\130\136\092\036\162\085\034\218\174\170\095\001\220\113\122\038\147\177\214\218\010\051\223\004\176\046\034\235\170\010\107\109\048\049\049\049\203\097\024\030\048\198\060\001\080\039\162\143\190\239\143\044\047\047\127\154\154\154\250\190\185\229\040\138\242\068\084\033\162\031\000\078\051\243\180\136\156\241\068\164\160\170\173\114\185\060\179\057\160\209\104\236\035\162\035\170\186\010\224\069\185\092\094\138\227\248\046\017\053\085\245\033\051\159\036\162\029\014\085\117\163\204\205\205\101\083\048\227\056\062\015\224\041\128\099\068\116\150\153\159\133\097\056\013\224\160\170\030\246\125\127\156\136\122\206\215\115\151\136\080\062\159\071\189\094\215\040\138\106\000\110\048\243\245\082\169\244\124\208\254\045\017\185\038\034\167\000\124\075\146\100\140\153\061\164\084\168\042\025\099\082\070\142\003\248\224\130\055\168\098\190\015\032\067\068\059\139\197\098\219\024\227\049\051\028\155\242\015\126\045\017\101\083\213\093\214\090\031\128\255\199\252\215\018\241\150\004\170\250\146\153\075\113\028\095\114\014\243\243\243\227\190\239\223\022\145\047\221\110\247\189\171\204\204\105\018\136\083\152\057\089\092\092\180\174\229\106\181\218\096\230\171\170\122\046\142\227\217\092\046\247\010\064\209\090\123\121\114\114\114\205\249\136\200\154\219\005\087\192\075\146\164\107\140\217\093\171\213\118\049\243\146\075\091\042\149\094\183\219\237\119\043\043\043\135\156\189\082\169\188\101\102\117\133\221\027\069\209\094\017\201\048\243\042\183\090\173\081\107\237\003\102\222\079\068\159\029\051\003\240\044\051\119\211\085\006\096\092\048\017\037\000\246\136\200\227\066\161\112\175\063\011\128\145\102\179\121\084\085\199\140\049\206\137\122\189\094\127\188\129\093\141\049\125\064\085\213\088\107\091\213\106\245\205\006\146\195\064\254\143\164\108\252\006\043\060\085\250\069\011\032\183\000\000\000\000\073\069\078\068\174\066\096\130",
["Collapse"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\209\073\068\065\084\120\156\189\082\177\107\090\097\016\255\238\061\229\165\017\162\014\009\014\245\075\134\022\133\012\249\019\202\027\131\115\076\166\116\043\116\201\020\186\100\120\207\210\213\161\049\025\004\007\135\118\208\007\014\226\032\004\209\033\131\067\214\066\049\131\015\082\035\130\210\128\242\108\019\253\046\220\235\251\072\076\098\040\029\122\112\188\187\223\221\239\238\187\187\007\000\140\161\064\096\000\248\198\168\047\068\023\086\099\083\113\253\123\242\058\118\110\125\099\200\076\134\076\138\201\128\252\157\207\189\021\223\212\137\248\127\077\046\217\124\065\096\136\192\012\084\092\149\054\125\231\115\016\222\101\207\252\091\069\084\031\135\016\072\201\054\012\067\161\060\003\081\185\203\000\240\146\024\037\205\116\033\156\072\164\247\210\093\156\205\235\032\109\137\123\234\226\050\086\046\151\023\093\007\000\176\221\110\135\108\219\222\028\143\199\023\137\068\226\084\008\001\141\070\067\213\117\125\146\078\167\095\196\227\241\183\193\096\112\202\057\255\194\057\031\019\143\226\138\124\110\040\020\098\253\126\127\221\182\237\131\082\169\180\077\024\145\017\209\023\137\068\118\059\157\206\254\096\048\216\136\070\163\110\190\101\089\010\197\021\000\016\084\045\028\014\095\169\170\250\085\211\180\155\094\175\247\209\178\172\036\034\106\133\066\225\253\112\056\252\160\105\218\197\104\052\058\002\000\135\070\076\038\147\194\091\005\115\231\052\077\019\082\169\148\168\086\171\027\221\110\247\147\227\056\107\066\136\031\170\170\190\010\004\002\039\156\243\067\093\215\191\019\217\052\077\154\251\238\255\144\069\138\197\162\123\190\122\189\030\207\229\114\133\076\038\243\051\159\207\031\183\090\173\101\015\247\205\108\254\161\024\127\182\239\022\169\213\106\235\149\074\101\175\217\108\190\036\063\155\205\250\031\158\247\073\065\239\230\222\201\150\036\246\108\103\054\167\136\124\213\095\019\159\040\244\239\228\255\038\183\037\183\020\029\197\221\160\050\000\000\000\000\073\069\078\068\174\066\096\130",
["Color3Value"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\162\073\068\065\084\120\156\181\083\077\139\019\065\016\173\087\189\172\113\017\069\204\030\115\017\018\188\122\090\088\246\226\065\253\013\030\252\017\130\103\103\002\254\013\143\094\189\237\217\139\122\145\021\081\240\035\018\210\051\038\144\096\024\118\205\165\051\203\244\147\078\038\217\108\152\241\034\022\052\069\117\189\042\222\171\234\022\169\049\146\008\167\046\254\191\070\018\147\201\228\090\150\101\055\086\119\073\146\220\028\141\070\123\219\088\173\040\054\000\232\156\123\058\155\205\158\068\081\164\105\154\094\037\249\034\207\243\007\165\020\173\109\000\160\040\027\221\243\222\159\119\187\093\239\156\187\165\170\119\001\252\010\205\227\056\190\192\203\006\237\144\180\214\062\006\240\072\068\014\188\247\086\085\191\146\220\007\112\032\034\039\170\250\188\213\106\189\094\225\117\155\128\049\102\040\034\167\034\114\174\170\111\072\126\043\041\159\122\239\223\003\008\185\106\139\162\104\039\248\126\191\127\127\048\024\156\076\167\211\235\229\000\187\214\218\151\085\053\186\185\219\056\142\023\250\141\049\135\000\070\205\102\243\119\041\239\014\201\254\106\200\151\040\115\073\047\008\226\120\060\190\237\156\123\038\034\071\000\118\072\190\037\185\171\170\071\034\050\019\145\087\243\249\060\234\116\058\243\075\091\000\150\036\178\044\059\035\249\073\068\118\001\124\084\213\015\198\152\159\036\061\128\099\017\249\210\110\183\139\237\189\107\169\127\225\123\189\222\149\036\073\062\167\105\250\048\196\195\225\240\208\090\251\035\220\087\206\064\046\244\051\248\070\163\209\020\145\119\069\081\124\015\122\139\162\216\083\213\227\060\207\185\249\128\086\171\095\051\168\098\181\006\213\216\002\247\047\063\172\182\118\157\088\082\252\235\055\254\003\060\187\004\107\100\181\082\170\000\000\000\000\073\069\078\068\174\066\096\130",
["Copy"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\202\073\068\065\084\120\156\077\147\203\107\093\085\020\135\191\181\246\062\231\222\180\185\209\218\042\088\146\084\107\197\129\177\013\034\098\021\004\043\078\164\058\171\127\064\103\226\200\185\067\065\068\028\138\003\193\153\147\116\032\034\070\011\130\130\147\118\032\045\245\021\031\160\182\036\166\141\208\196\155\251\058\119\239\181\100\159\139\143\061\217\135\181\089\107\253\094\071\222\189\216\124\020\043\061\155\205\005\119\084\069\004\204\016\117\183\126\165\250\230\249\103\194\091\034\210\148\007\119\088\091\091\011\047\157\059\103\151\062\189\220\139\135\122\242\212\153\149\064\039\130\057\082\238\157\126\214\207\175\153\119\042\155\071\244\149\183\063\158\230\151\223\031\126\240\208\145\057\217\105\016\236\187\063\016\201\155\235\235\011\114\225\114\051\060\187\026\234\081\131\186\136\228\012\027\091\137\159\183\197\193\009\161\146\038\077\039\238\108\230\044\170\194\176\153\166\119\190\189\209\125\239\133\163\023\238\137\065\037\013\038\116\190\248\222\112\132\113\227\237\253\226\099\065\234\080\184\152\085\049\118\246\198\114\252\210\079\206\252\156\112\123\032\175\159\170\243\068\194\129\079\098\206\072\183\082\158\056\001\085\084\182\119\141\031\054\157\131\181\144\205\153\154\104\133\219\066\071\108\056\049\110\237\185\031\191\055\030\234\143\243\107\215\007\167\151\099\084\103\154\224\234\111\006\234\244\071\016\021\038\201\249\106\195\216\233\059\203\135\085\159\124\016\173\163\208\036\243\091\183\167\126\160\214\197\253\166\062\031\147\169\087\017\078\030\083\098\016\110\238\057\063\110\025\085\016\030\127\064\025\079\105\005\110\050\156\121\088\016\169\036\168\051\106\068\047\094\145\197\024\131\215\083\067\174\093\119\068\156\254\184\181\146\108\112\229\119\099\212\064\039\192\222\008\142\244\224\217\149\128\010\168\210\026\030\147\229\186\091\007\089\061\038\045\130\237\061\103\099\211\009\010\039\151\148\102\010\033\128\208\054\177\063\134\249\046\237\002\007\098\021\092\154\004\095\255\234\080\016\140\156\194\213\028\190\185\049\067\080\220\040\103\191\129\074\225\249\085\229\159\080\197\148\197\171\032\242\232\253\179\226\159\253\153\006\101\227\169\037\101\156\139\168\133\187\083\050\018\067\113\011\070\137\150\074\076\134\169\016\150\014\151\150\153\003\191\220\020\082\254\079\131\002\181\055\039\060\183\050\091\242\239\041\003\004\029\186\217\156\153\182\194\164\236\164\228\162\138\060\178\172\173\250\165\167\012\078\054\251\046\154\020\248\110\238\017\168\154\172\161\020\234\010\041\224\029\247\032\248\226\093\255\095\215\246\182\104\010\125\021\074\242\053\238\014\244\203\245\171\249\116\153\023\021\255\107\228\161\019\089\200\142\151\228\153\107\249\123\164\133\087\162\157\090\033\173\073\037\118\097\040\111\124\056\186\111\171\031\142\138\163\211\204\164\215\149\059\079\220\045\175\222\209\227\105\113\047\192\138\033\133\250\065\017\052\027\057\008\131\082\220\029\240\217\223\161\244\097\225\170\099\171\238\000\000\000\000\073\069\078\068\174\066\096\130",
["Cut"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\068\073\068\065\084\120\156\109\147\077\108\027\085\016\199\103\222\174\063\082\027\219\033\181\227\052\169\147\122\069\066\090\164\085\129\067\017\018\114\014\092\000\053\018\224\165\021\106\032\082\110\069\136\094\026\144\016\155\021\042\149\042\004\135\052\002\197\023\148\075\164\109\085\113\011\007\076\020\068\112\139\250\065\211\070\069\245\182\224\218\129\124\212\009\145\133\139\189\251\222\084\047\165\017\135\188\203\104\164\055\255\153\055\255\223\067\000\000\211\052\153\140\154\166\181\068\163\209\195\141\070\227\152\016\034\223\108\054\191\030\026\026\170\155\166\137\150\101\009\216\233\016\017\018\017\147\113\106\106\234\229\249\249\249\235\165\082\233\193\204\204\204\242\196\196\196\128\188\051\059\059\171\238\088\012\000\091\157\013\195\064\068\036\206\249\141\149\149\021\030\139\197\130\233\116\186\061\145\072\188\155\203\229\158\204\100\050\092\054\217\169\057\155\156\156\108\049\012\195\200\229\114\047\014\015\015\175\109\110\110\126\233\056\078\181\179\179\147\218\218\218\012\215\117\007\164\056\000\224\227\066\249\100\250\047\103\225\112\248\112\042\149\250\052\157\078\095\152\158\158\254\188\086\171\045\020\139\197\171\174\235\066\111\111\111\176\163\163\227\237\241\241\241\061\136\200\103\077\083\037\032\028\179\044\002\211\068\024\027\067\053\024\012\190\020\014\135\083\186\174\251\202\229\242\241\098\177\248\090\181\090\253\197\113\156\063\116\093\223\151\136\199\101\062\071\217\236\089\000\016\008\072\082\104\192\178\060\057\001\230\243\249\087\214\215\215\223\236\238\238\126\067\211\180\072\040\020\130\165\165\165\117\199\113\252\186\174\135\252\193\032\022\046\094\044\220\188\117\107\248\228\223\223\222\185\178\113\224\016\227\252\057\015\241\182\079\009\020\164\003\017\185\196\193\193\193\119\034\145\200\137\158\158\158\046\077\211\084\033\004\032\162\215\162\048\229\218\194\013\254\091\169\116\186\255\231\159\130\204\117\223\034\132\004\017\213\000\113\078\010\060\129\136\053\219\182\253\149\074\229\169\100\050\105\196\162\209\145\190\254\254\061\169\174\046\168\255\144\135\186\223\079\229\123\229\085\126\169\176\043\164\042\204\005\090\100\068\237\130\096\175\186\188\188\044\164\029\000\224\033\226\162\109\219\167\238\149\203\063\254\243\111\253\104\169\082\121\181\091\081\119\183\198\227\176\235\215\107\237\245\102\195\163\150\200\103\202\170\239\140\136\061\248\008\128\062\084\147\201\164\043\109\146\034\166\105\170\217\108\086\230\249\209\209\209\203\189\207\232\121\182\185\241\113\237\082\097\063\173\173\112\053\016\112\185\235\013\080\172\177\198\144\189\192\016\021\089\185\005\209\099\143\109\219\086\226\139\139\040\183\124\245\253\247\076\207\115\079\096\179\169\048\159\015\064\081\016\136\124\248\008\064\006\008\075\219\112\108\067\002\192\044\000\113\249\131\227\207\178\166\248\070\097\120\128\124\234\073\225\185\125\036\096\004\144\230\000\208\005\128\058\017\125\181\245\007\182\209\004\192\177\108\246\017\097\228\245\113\038\186\026\036\126\175\052\238\159\023\192\207\003\194\006\000\196\137\243\211\228\231\035\119\087\171\223\179\255\143\143\082\227\220\185\045\108\155\194\127\061\064\170\019\000\108\223\075\173\167\152\080\062\001\160\040\016\254\133\168\222\125\254\139\201\251\233\214\086\182\211\047\035\019\000\015\189\190\112\251\202\133\253\223\041\002\158\038\070\071\008\129\035\192\159\064\120\246\096\038\083\161\120\092\005\203\242\030\002\088\217\143\044\124\104\108\084\000\000\000\000\073\069\078\068\174\066\096\130",
["Decal"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\037\073\068\065\084\120\156\157\148\061\104\085\065\016\133\191\153\221\119\095\210\004\140\152\072\032\160\133\018\147\052\246\022\105\180\075\136\032\175\178\208\094\043\237\018\016\004\069\176\208\198\202\074\016\004\145\024\049\065\027\021\027\009\130\136\168\137\040\008\001\017\084\068\034\017\223\123\247\238\140\220\155\063\021\255\240\044\044\203\238\158\153\221\051\103\023\112\193\093\248\079\200\218\096\096\202\119\138\208\043\001\255\027\169\150\088\126\146\243\148\134\164\042\192\224\180\031\022\225\184\059\031\068\040\126\193\241\181\078\064\220\233\083\097\198\090\076\202\240\013\239\117\152\017\227\148\229\204\137\178\075\003\069\025\037\174\178\011\200\084\048\023\234\022\121\093\228\196\012\174\056\028\141\041\167\075\035\205\092\088\008\025\231\181\198\062\203\201\085\016\043\005\082\162\024\175\076\056\019\018\035\094\176\151\140\049\114\022\049\186\085\012\071\072\017\250\016\118\019\216\036\145\030\137\108\145\064\143\116\208\141\243\114\097\076\166\147\112\069\097\160\179\205\246\242\062\090\039\041\245\021\049\205\041\112\154\110\184\039\062\091\206\017\075\060\032\085\235\035\067\211\126\082\132\009\017\196\149\188\020\195\019\162\063\213\196\181\142\056\220\153\031\151\011\020\156\179\068\174\074\063\048\169\202\168\173\036\088\175\158\174\115\003\046\078\076\077\146\011\023\113\215\174\196\172\231\220\051\099\201\161\097\137\231\026\081\113\202\246\093\000\071\202\073\023\058\200\185\191\048\202\109\068\108\174\033\095\045\112\204\157\067\243\227\114\205\225\082\201\072\090\233\086\033\074\194\061\096\201\168\069\197\016\110\014\206\210\155\110\121\007\205\170\150\031\091\025\239\135\174\123\127\050\030\090\155\079\234\116\086\103\168\225\209\067\121\115\098\200\121\099\025\119\085\057\072\098\127\040\040\087\160\133\118\148\230\081\242\000\025\198\035\075\188\144\136\122\065\136\237\022\075\245\058\053\175\177\071\218\156\182\026\059\066\160\216\144\105\003\009\162\214\120\027\156\062\131\109\094\240\174\218\054\060\229\013\083\038\128\229\223\088\185\210\169\124\118\165\149\049\054\139\114\249\089\023\103\215\243\012\094\245\173\100\116\087\198\250\003\092\145\122\193\151\199\007\100\113\099\246\132\255\232\135\127\193\234\023\240\013\008\176\244\154\106\127\240\209\000\000\000\000\073\069\078\068\174\066\096\130",
["Delete"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\106\073\068\065\084\120\156\133\083\061\076\083\081\020\254\206\121\239\009\131\196\068\035\196\246\221\123\091\066\196\040\154\016\006\029\052\056\024\119\076\234\000\209\073\227\096\220\116\114\104\136\110\174\014\078\078\078\160\137\209\196\069\147\154\168\131\137\134\216\098\129\135\088\002\012\196\010\005\090\108\011\237\187\230\190\246\097\069\141\103\185\185\231\126\231\059\223\249\185\064\139\105\128\241\031\051\152\223\112\026\176\055\093\068\139\093\232\052\247\228\063\072\052\064\127\073\064\168\042\244\151\037\077\149\005\189\046\186\232\107\130\045\019\240\183\224\124\047\058\214\092\236\031\075\052\048\076\062\044\000\029\237\054\006\065\244\160\216\141\062\002\234\227\013\169\097\032\019\224\235\024\122\247\085\232\126\155\205\035\137\175\129\079\067\015\194\046\009\156\047\073\202\212\098\164\011\130\222\173\198\113\098\183\146\045\129\051\085\073\239\171\138\222\084\036\142\238\148\171\147\013\105\171\194\062\189\033\105\226\071\140\244\138\164\137\101\023\067\198\159\083\104\047\197\112\185\034\105\177\042\233\101\037\130\195\045\205\164\176\062\219\056\011\010\253\005\201\079\203\113\210\121\069\094\094\097\120\077\209\189\162\162\226\166\160\071\058\142\174\080\217\031\029\078\133\036\018\241\188\162\199\223\020\213\242\138\190\175\042\042\110\072\122\104\026\023\096\007\224\180\054\120\199\140\138\144\121\073\224\226\178\164\210\070\140\244\178\162\245\005\137\145\038\198\217\157\157\195\236\004\212\022\093\236\153\147\124\197\039\190\187\005\148\075\062\158\213\053\216\002\141\046\184\214\016\001\219\134\167\149\132\204\197\140\045\027\193\001\199\166\155\014\232\058\025\137\132\091\142\227\063\065\021\151\124\208\104\013\180\174\181\125\099\126\105\235\249\089\160\222\028\109\061\096\249\232\162\039\035\104\124\090\176\239\009\046\204\008\190\246\097\000\078\083\182\149\083\024\158\119\185\144\147\188\050\167\248\118\014\104\015\154\111\038\152\150\232\206\008\126\245\069\178\206\186\188\144\141\242\085\083\082\000\024\108\156\134\040\167\172\011\057\201\179\179\146\183\167\035\156\124\001\180\005\217\063\185\056\158\145\060\059\233\242\116\058\098\157\011\151\039\092\093\157\076\242\088\179\102\047\106\159\242\004\103\061\151\107\147\081\186\147\058\136\189\240\122\208\054\033\112\044\125\008\071\154\146\127\005\055\178\147\033\009\199\236\041\244\207\008\122\059\229\242\204\084\023\098\173\019\009\182\171\245\055\038\077\096\042\101\107\173\105\044\145\048\202\130\183\116\039\186\063\071\113\210\108\233\079\155\084\244\190\217\034\240\106\000\000\000\000\073\069\078\068\174\066\096\130",
["Expand"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\183\073\068\065\084\120\156\157\082\077\075\002\081\020\189\247\205\160\067\016\024\081\155\116\083\109\084\090\184\107\017\212\190\182\010\181\009\250\019\045\010\156\054\181\111\209\007\045\106\237\064\235\022\045\250\001\142\095\168\032\162\228\160\017\040\130\225\032\243\072\111\204\056\067\163\141\065\029\120\220\247\184\247\156\119\230\204\195\131\139\194\194\072\088\008\009\126\232\174\119\131\111\229\040\096\164\004\100\086\152\134\002\000\113\000\127\035\047\125\210\252\026\013\217\199\196\080\146\136\153\181\172\000\070\150\000\203\109\160\072\028\200\061\019\085\000\019\009\028\058\103\049\153\076\178\023\216\097\203\209\029\058\195\113\131\136\016\064\054\023\033\226\132\128\005\034\220\150\095\132\229\114\219\171\071\232\172\111\177\217\016\221\068\123\203\090\173\214\033\231\124\062\157\078\063\032\098\143\136\004\180\221\077\131\057\027\089\150\081\081\020\243\140\134\097\236\245\251\253\115\159\207\183\079\068\126\147\108\138\120\185\193\105\251\102\045\149\074\097\000\056\230\156\111\074\146\116\029\014\135\111\017\113\224\229\004\061\050\176\134\122\189\222\098\179\217\188\229\156\111\137\162\120\025\010\133\110\002\129\064\151\136\024\034\142\126\203\005\138\197\162\207\022\011\100\050\153\103\085\085\245\122\189\126\063\024\012\086\157\075\126\132\232\192\188\001\000\044\155\213\106\117\023\000\130\140\049\021\000\158\036\073\234\056\099\224\005\026\255\062\043\216\090\173\118\148\207\231\223\115\185\220\163\166\105\027\238\153\153\228\084\042\101\037\093\169\084\078\011\133\066\051\155\205\222\053\026\141\053\187\047\184\173\059\064\015\101\081\211\180\043\093\215\231\012\195\056\137\197\098\175\054\113\228\249\042\039\212\016\045\033\093\215\131\157\078\103\101\250\085\254\025\255\038\207\250\094\047\124\001\014\226\004\108\161\107\248\035\000\000\000\000\073\069\078\068\174\066\096\130",
["Folder"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\148\073\068\065\084\120\156\165\083\193\106\083\065\020\061\247\206\228\053\018\108\080\065\049\110\237\170\043\245\003\146\047\112\231\055\116\021\112\043\008\003\021\063\066\063\193\126\128\136\011\179\009\130\016\112\211\077\154\174\220\187\176\077\155\204\123\051\071\238\068\036\218\026\023\057\243\014\111\120\239\204\204\057\247\050\000\000\018\130\191\096\223\024\130\146\188\242\111\029\242\123\193\116\184\131\061\175\248\006\192\205\005\189\055\151\034\194\077\139\067\160\170\077\022\039\047\159\054\238\206\231\122\182\059\169\151\221\047\245\197\253\175\113\022\142\206\078\095\220\091\185\009\122\197\221\047\103\158\132\198\153\014\125\183\253\040\253\088\192\169\034\103\066\059\213\030\206\113\204\119\207\014\001\180\166\211\225\154\155\219\073\068\154\016\040\194\079\125\031\031\244\063\086\157\170\031\047\150\009\016\007\001\197\204\037\158\129\060\205\034\229\052\181\072\164\136\202\018\076\135\173\135\175\222\123\012\006\192\009\129\034\146\130\082\155\068\168\074\215\181\252\227\063\236\167\012\217\109\035\126\159\063\103\192\007\157\076\122\215\087\089\128\148\201\024\235\188\206\058\165\026\139\038\003\216\193\160\175\218\110\223\250\103\155\068\202\163\235\004\161\016\216\155\230\094\177\037\116\235\013\246\247\143\243\118\014\070\035\075\107\137\172\207\228\127\104\154\149\086\136\145\109\048\184\107\055\193\091\147\081\138\182\153\101\020\045\253\219\155\061\081\145\163\004\149\113\142\214\026\177\099\184\137\166\041\090\197\248\224\201\065\227\045\071\117\201\215\205\141\056\006\181\003\231\050\082\190\190\181\078\137\148\052\047\227\188\138\110\180\074\180\013\072\249\009\067\144\225\072\018\185\009\152\000\000\000\000\073\069\078\068\174\066\096\130",
["Group"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\031\073\068\065\084\120\156\077\147\075\104\093\085\020\134\255\181\246\058\231\158\115\238\171\177\106\174\065\171\069\154\218\090\002\162\224\139\210\014\029\068\172\083\233\080\017\156\169\051\045\205\200\130\138\056\020\171\224\200\137\014\125\191\048\040\020\132\082\235\019\105\027\154\094\026\099\140\038\134\123\115\207\189\251\236\189\150\156\084\176\123\178\006\011\190\245\173\199\166\039\094\094\122\222\136\078\178\163\207\118\053\167\094\105\118\186\229\168\244\194\014\134\235\158\083\088\146\065\057\075\171\254\229\043\071\160\118\202\224\206\009\136\142\049\187\078\172\170\071\036\079\103\211\006\006\078\210\004\248\031\096\166\008\209\018\005\004\030\154\038\201\204\104\123\184\155\093\227\176\128\236\099\131\222\195\142\191\029\143\182\094\093\095\095\031\076\060\075\150\056\173\254\003\020\069\130\086\187\227\243\052\117\053\053\122\127\212\057\057\105\076\231\233\153\119\214\122\121\218\253\080\163\157\184\188\188\116\184\040\218\243\222\079\006\033\154\099\162\029\011\114\044\108\250\205\214\186\063\245\249\235\135\054\022\022\022\120\048\251\194\034\193\062\018\009\133\037\205\164\170\216\143\203\224\014\060\251\248\158\185\219\167\020\227\192\016\002\136\129\095\087\012\095\125\183\178\054\210\044\039\000\171\051\143\186\093\034\129\097\145\199\074\028\163\057\043\067\018\125\220\110\165\208\222\020\151\153\171\162\080\085\009\170\042\250\145\110\143\227\198\023\103\087\155\243\047\045\077\055\110\187\151\067\101\020\131\058\145\020\086\171\070\018\037\038\046\003\120\241\231\097\242\254\226\166\027\251\232\018\071\168\130\033\068\125\236\216\131\055\061\204\100\254\234\079\063\030\223\127\199\220\223\170\042\114\253\170\012\166\121\010\043\137\226\222\094\038\015\028\044\112\067\203\161\082\032\075\168\155\167\210\125\251\147\053\188\247\233\090\251\208\062\132\237\109\229\107\000\130\065\000\038\110\152\162\110\211\237\238\008\246\246\114\220\216\101\140\038\117\014\218\076\017\083\161\106\171\244\222\049\136\008\182\003\136\010\114\034\232\020\060\056\253\193\031\163\201\184\012\251\247\020\237\141\129\082\052\198\196\027\068\140\124\134\164\010\166\237\130\089\173\190\015\016\231\206\212\084\197\128\086\035\215\019\103\206\255\115\100\249\207\234\197\034\117\107\173\156\172\147\035\180\011\210\078\206\177\213\224\032\076\090\142\001\178\029\083\176\175\204\168\222\183\066\222\125\238\224\234\047\167\015\156\157\153\146\077\037\100\032\071\049\068\081\128\171\168\226\067\109\108\153\037\204\236\016\193\012\105\078\183\067\024\068\128\036\212\196\167\222\180\100\115\243\130\156\191\056\088\255\109\121\088\018\081\048\160\046\097\044\112\091\195\096\247\205\022\227\073\005\118\140\040\043\023\174\204\155\225\078\085\154\127\250\141\205\031\122\183\096\072\141\091\191\236\095\186\116\110\229\047\147\016\038\038\074\084\165\128\141\153\246\221\213\157\220\220\157\154\235\247\251\015\041\056\161\227\175\245\191\054\179\163\033\084\229\116\111\102\057\203\242\081\172\127\078\226\070\226\160\245\160\174\117\091\107\192\020\136\191\095\093\185\187\028\151\061\032\157\136\106\056\067\196\115\204\252\061\105\124\139\018\012\213\135\108\236\141\118\166\067\102\117\004\034\148\064\089\194\094\085\239\119\196\079\042\209\197\127\001\216\191\161\154\120\075\141\006\000\000\000\000\073\069\078\068\174\066\096\130",
["Humanoid"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\021\073\068\065\084\120\156\125\082\049\107\020\097\016\125\239\219\189\187\112\158\073\017\209\164\208\082\208\034\093\192\046\254\002\187\008\250\011\172\108\020\068\044\098\154\019\148\144\198\194\034\182\022\073\103\169\072\136\034\006\162\040\081\003\177\081\176\080\136\107\144\220\233\238\221\125\243\228\219\245\142\189\024\157\101\217\111\102\222\188\111\230\237\016\255\176\119\115\167\027\227\024\171\231\078\171\209\158\092\120\220\062\008\199\178\035\129\036\212\186\058\061\209\173\224\158\192\019\160\224\128\143\078\221\075\163\183\222\236\244\049\253\154\120\136\238\102\078\168\078\013\039\041\156\171\087\028\067\160\221\245\083\164\187\003\096\167\143\233\151\184\253\045\009\032\141\145\128\244\087\199\236\103\215\012\096\218\083\030\027\234\248\047\130\149\045\132\027\037\243\223\032\182\225\016\090\112\004\090\134\106\018\114\255\213\032\152\102\102\098\092\108\049\249\132\179\066\124\044\114\148\055\255\245\072\098\079\177\221\016\215\214\122\216\071\192\062\237\143\027\211\215\036\092\016\152\001\218\131\080\128\025\180\226\097\007\213\000\060\024\107\110\220\046\110\155\035\251\170\126\185\050\117\168\086\027\089\143\136\083\102\072\026\035\209\081\169\160\014\115\236\101\062\033\057\042\105\059\205\210\051\147\011\155\109\105\057\026\104\048\097\117\011\095\111\122\005\234\081\218\053\107\117\204\183\051\235\117\122\050\065\171\222\236\121\025\155\147\163\108\069\056\146\084\115\204\115\012\079\016\082\066\149\097\148\065\233\065\123\224\080\101\065\154\055\031\059\186\033\221\201\145\128\249\092\046\033\017\070\037\022\215\083\194\150\096\120\038\208\042\145\067\199\236\109\023\126\051\142\136\008\244\018\094\152\183\165\227\139\235\105\161\221\121\159\119\048\088\205\230\203\176\109\248\126\125\250\126\181\234\160\140\015\009\042\174\184\041\101\189\108\188\185\113\121\232\255\149\053\008\091\182\060\027\230\255\147\034\122\049\017\084\142\195\217\027\160\101\068\154\131\043\111\228\144\136\179\043\176\208\013\201\026\028\099\162\120\195\217\057\084\241\030\226\252\176\140\003\017\203\107\234\128\187\201\110\250\036\114\124\029\252\100\055\221\034\227\015\152\047\048\101\236\111\079\001\243\118\228\087\063\113\000\000\000\000\073\069\078\068\174\066\096\130",
["InsertObject"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\215\073\068\065\084\120\156\109\083\207\139\028\069\020\254\222\171\234\158\031\059\059\110\054\110\050\107\060\140\001\131\204\096\016\093\140\135\176\051\030\060\042\040\116\131\055\047\254\001\130\071\161\103\131\183\220\131\120\207\101\026\004\047\094\188\108\200\077\012\098\096\134\156\054\187\040\110\214\017\119\101\102\182\167\187\171\234\073\247\236\198\013\248\160\170\030\197\123\095\189\247\234\251\000\128\002\064\005\001\212\176\088\195\064\137\128\130\032\080\016\033\008\168\060\255\199\136\008\186\112\058\128\020\027\198\040\003\251\187\061\053\233\161\186\057\216\114\205\250\071\106\241\238\103\249\129\032\045\160\206\147\163\040\226\018\004\023\045\234\105\236\060\048\215\239\007\183\061\225\187\226\092\006\230\058\001\063\221\244\221\023\241\168\099\048\216\041\107\042\000\198\227\049\241\025\018\033\138\184\215\110\151\021\225\052\191\162\026\254\123\171\055\055\183\087\110\188\188\037\214\189\189\055\074\052\006\093\194\032\090\182\118\102\220\239\247\025\178\172\172\118\181\089\058\148\203\028\034\169\186\084\155\146\038\039\066\039\009\106\038\136\203\254\128\193\128\138\215\139\088\061\153\076\004\113\200\175\054\127\243\031\237\085\020\128\084\012\177\056\104\089\024\136\021\038\017\149\253\061\165\120\052\080\087\103\215\188\203\183\198\057\186\176\157\081\103\089\202\027\247\063\237\137\115\119\156\117\134\136\018\201\204\043\122\189\246\214\234\155\045\201\143\023\060\027\061\059\038\226\159\133\196\177\082\013\016\126\157\251\238\203\223\195\056\041\123\182\179\197\166\127\173\185\093\105\173\066\138\065\091\128\024\226\140\099\174\106\052\186\173\075\032\124\064\138\224\172\224\244\201\164\190\242\052\045\115\117\009\144\217\020\002\163\215\107\057\092\049\016\209\098\225\075\102\132\052\147\183\086\045\046\051\174\234\044\063\073\086\000\153\158\252\153\184\231\000\222\075\053\109\103\153\154\061\062\148\050\221\056\165\027\021\169\093\095\039\059\093\200\124\255\164\096\141\034\038\031\012\038\066\229\242\173\215\233\008\063\066\139\008\117\227\240\097\154\152\143\237\113\046\090\248\031\235\220\109\106\225\014\136\140\088\120\230\056\249\197\206\237\087\228\195\146\066\131\027\245\163\141\141\209\162\200\213\187\187\187\106\028\198\207\000\124\127\254\183\237\111\062\017\104\182\032\024\040\242\168\162\014\247\062\255\238\135\139\156\251\122\056\084\097\024\242\242\027\163\136\223\249\240\080\229\227\167\254\227\234\218\002\127\153\181\146\015\138\065\133\018\028\170\027\081\175\177\209\237\103\243\249\062\031\180\247\077\124\047\046\057\195\097\016\058\236\236\184\071\091\223\230\094\242\090\134\048\182\254\010\147\164\214\155\141\142\252\244\112\074\196\228\085\154\087\108\048\130\057\216\111\103\120\255\129\121\046\168\023\180\080\080\148\072\058\195\160\101\078\177\109\166\105\014\205\085\191\094\251\227\201\222\141\135\103\058\040\035\207\181\176\228\254\127\250\044\104\064\099\042\103\050\124\017\028\116\081\141\231\246\047\174\061\097\230\035\142\019\248\000\000\000\000\073\069\078\068\174\066\096\130",
["Instance"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\206\073\068\065\084\120\156\133\147\177\138\020\065\016\134\187\122\059\246\082\017\217\227\076\054\021\021\245\178\021\046\017\065\049\056\209\064\195\227\048\186\232\192\104\003\223\064\124\002\035\025\048\021\004\113\081\080\239\033\156\173\250\119\070\054\089\054\056\246\224\134\229\182\164\231\186\251\102\006\209\074\166\186\235\175\175\187\170\167\140\137\166\074\170\074\097\065\089\166\189\024\058\247\149\146\038\233\140\113\009\064\148\118\085\253\146\206\242\060\223\176\214\086\091\091\116\170\170\150\136\214\041\051\152\109\046\060\061\008\149\153\159\058\231\062\244\122\189\247\179\217\236\182\079\246\177\174\222\118\129\094\200\204\251\068\244\210\057\119\072\068\239\170\170\122\083\020\197\189\000\073\165\181\072\163\209\168\134\001\056\016\145\047\000\174\197\184\079\102\230\163\162\040\238\007\125\173\077\061\211\224\136\200\225\116\058\253\004\224\138\095\143\199\099\023\079\044\203\114\027\192\079\000\143\034\036\052\084\235\206\050\243\043\000\031\153\249\114\243\148\224\215\016\000\183\060\164\044\203\135\045\077\081\020\119\068\228\219\124\062\191\212\077\142\230\111\227\191\204\124\087\068\190\046\022\139\141\244\010\235\245\122\233\243\150\203\229\213\248\168\093\192\112\056\212\058\193\218\077\099\204\201\106\181\058\075\037\152\115\242\051\017\241\053\222\108\094\187\233\079\038\147\039\000\126\136\200\141\214\077\053\056\204\252\088\068\142\152\121\059\236\167\038\002\120\001\224\059\051\095\111\053\049\090\132\228\121\254\032\064\134\049\006\096\207\215\093\150\229\032\104\107\168\007\080\034\132\128\255\133\001\236\024\099\094\171\234\091\085\221\036\162\029\107\237\094\191\223\255\021\053\017\112\049\011\245\056\144\111\140\255\027\063\231\121\126\236\156\059\080\213\069\085\085\207\007\131\193\239\044\203\082\242\063\237\111\207\216\170\247\255\118\049\206\035\085\187\219\024\237\174\253\001\004\249\097\052\220\073\126\020\000\000\000\000\073\069\078\068\174\066\096\130",
["IntValue"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\162\073\068\065\084\120\156\181\083\077\139\019\065\016\173\087\189\172\113\017\069\204\030\115\017\018\188\122\090\088\246\226\065\253\013\030\252\017\130\103\103\002\254\013\143\094\189\237\217\139\122\145\021\081\240\035\018\210\051\038\144\096\024\118\205\165\051\203\244\147\078\038\217\108\152\241\034\022\052\069\117\189\042\222\171\234\022\169\049\146\008\167\046\254\191\070\018\147\201\228\090\150\101\055\086\119\073\146\220\028\141\070\123\219\088\173\040\054\000\232\156\123\058\155\205\158\068\081\164\105\154\094\037\249\034\207\243\007\165\020\173\109\000\160\040\027\221\243\222\159\119\187\093\239\156\187\165\170\119\001\252\010\205\227\056\190\192\203\006\237\144\180\214\062\006\240\072\068\014\188\247\086\085\191\146\220\007\112\032\034\039\170\250\188\213\106\189\094\225\117\155\128\049\102\040\034\167\034\114\174\170\111\072\126\043\041\159\122\239\223\003\008\185\106\139\162\104\039\248\126\191\127\127\048\024\156\076\167\211\235\229\000\187\214\218\151\085\053\186\185\219\056\142\023\250\141\049\135\000\070\205\102\243\119\041\239\014\201\254\106\200\151\040\115\073\047\008\226\120\060\190\237\156\123\038\034\071\000\118\072\190\037\185\171\170\071\034\050\019\145\087\243\249\060\234\116\058\243\075\091\000\150\036\178\044\059\035\249\073\068\118\001\124\084\213\015\198\152\159\036\061\128\099\017\249\210\110\183\139\237\189\107\169\127\225\123\189\222\149\036\073\062\167\105\250\048\196\195\225\240\208\090\251\035\220\087\206\064\046\244\051\248\070\163\209\020\145\119\069\081\124\015\122\139\162\216\083\213\227\060\207\185\249\128\086\171\095\051\168\098\181\006\213\216\002\247\047\063\172\182\118\157\088\082\252\235\055\254\003\060\187\004\107\100\181\082\170\000\000\000\000\073\069\078\068\174\066\096\130",
["JumpToParent"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\186\073\068\065\084\120\156\157\083\065\136\028\069\020\173\095\085\221\061\179\217\073\178\102\221\149\224\097\065\136\152\092\002\049\098\064\066\110\129\192\122\080\179\008\230\098\020\036\071\015\018\247\020\132\008\230\022\076\068\060\120\054\108\035\036\007\193\147\087\111\030\132\140\135\053\154\176\163\097\102\157\117\233\217\158\233\095\255\255\042\249\237\030\020\114\016\063\020\221\245\187\250\213\123\245\094\065\074\006\192\024\179\081\110\088\243\132\042\203\242\095\243\209\104\004\075\075\075\169\044\075\105\027\041\025\253\255\127\023\108\092\059\158\127\095\157\119\089\150\173\136\056\151\016\121\038\051\064\068\167\011\066\008\237\032\034\195\204\169\174\107\039\034\097\123\123\251\151\126\191\031\252\201\157\062\252\056\183\122\012\069\190\138\210\036\001\147\000\192\121\239\145\153\013\000\024\107\091\117\202\148\188\247\061\099\204\086\175\215\123\203\024\051\244\213\083\167\028\117\023\030\102\227\173\075\182\040\082\195\144\067\035\100\173\013\204\108\083\074\049\198\216\210\205\243\060\033\162\215\111\157\078\103\172\061\127\234\196\085\124\113\109\109\250\254\215\073\022\242\189\055\111\188\122\120\253\194\027\175\061\115\056\203\110\135\016\186\136\024\016\209\238\203\136\136\216\033\162\081\074\233\003\061\083\127\238\254\211\217\229\047\126\061\235\240\183\207\116\205\213\123\147\207\031\149\239\029\033\196\151\152\121\158\069\066\140\209\042\011\017\017\102\238\138\200\032\198\216\105\025\116\187\043\039\139\194\127\124\116\113\254\005\038\158\254\190\187\115\243\224\043\159\092\170\190\185\242\242\212\251\206\180\174\021\160\117\042\198\168\018\028\051\243\230\230\230\227\022\192\204\122\253\241\238\248\211\064\180\146\059\187\083\204\029\186\254\224\238\219\207\090\105\174\099\211\116\067\008\042\001\246\221\136\068\212\074\088\094\094\254\112\056\028\142\252\183\031\045\078\140\049\119\046\220\030\238\030\112\178\086\190\179\248\195\249\115\103\159\039\176\167\069\228\128\090\038\034\186\171\050\144\024\227\092\140\113\203\057\087\180\214\092\188\184\225\102\011\247\011\247\240\187\035\240\220\153\249\063\007\063\081\024\012\040\230\249\161\166\105\172\136\196\201\100\098\001\064\237\160\166\105\052\007\052\030\143\031\168\173\160\040\171\171\175\159\032\154\126\025\102\149\096\052\142\003\219\166\105\038\026\028\117\000\017\149\186\037\034\079\068\243\204\060\000\128\119\235\186\030\121\005\232\084\127\060\194\162\088\079\121\047\147\201\174\006\008\000\032\219\015\079\210\167\050\176\127\087\001\000\123\117\093\171\116\104\001\030\139\028\229\170\090\071\196\028\017\137\136\028\017\165\016\002\048\051\133\016\014\198\024\127\174\170\234\178\210\254\231\085\080\000\221\101\219\057\119\075\225\189\247\026\059\080\235\156\115\234\125\212\118\140\113\207\024\163\007\215\050\218\007\210\119\243\196\107\252\095\235\047\100\142\201\231\206\175\235\038\000\000\000\000\073\069\078\068\174\066\096\130",
["Lighting"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\215\073\068\065\084\120\156\117\147\189\107\020\081\020\197\127\247\190\121\174\054\081\080\086\116\183\077\171\157\168\016\013\049\133\133\109\016\068\252\027\210\136\229\138\157\177\177\019\044\101\155\096\185\150\034\024\023\011\255\012\033\130\031\016\020\067\246\099\222\187\242\102\102\055\051\019\188\112\135\199\189\231\158\057\103\222\029\104\133\025\218\174\213\122\210\174\073\027\032\130\153\109\158\013\204\031\068\226\045\032\003\190\120\058\175\069\222\255\094\096\078\016\088\213\056\180\235\189\014\167\134\014\183\158\019\048\236\177\097\055\020\233\102\132\251\034\159\191\213\073\212\204\026\146\061\254\153\035\091\159\145\007\129\041\112\053\226\158\024\242\061\199\189\104\091\208\166\244\155\151\129\187\016\162\032\106\224\061\157\135\014\118\060\225\165\193\181\067\187\221\047\177\165\122\077\243\011\182\025\116\065\078\199\005\113\097\113\030\033\094\153\162\231\083\201\019\046\054\020\136\200\146\096\138\238\011\252\209\138\084\064\002\133\197\158\067\094\129\100\019\248\122\194\130\020\146\076\086\100\252\019\108\055\241\022\198\150\242\164\147\225\046\025\236\038\076\194\086\051\090\251\128\169\130\100\216\243\064\254\201\163\024\049\079\233\081\011\132\189\035\226\078\233\253\248\246\117\057\094\092\203\150\138\140\015\034\140\032\083\143\207\082\130\211\136\189\059\039\227\131\018\083\089\020\137\039\022\169\060\109\116\231\204\031\129\156\169\058\071\030\255\006\062\252\056\126\089\075\065\138\167\012\170\005\009\171\010\014\248\155\178\060\135\213\212\075\024\254\023\102\091\105\136\153\173\109\155\109\154\217\134\153\221\073\171\109\019\091\219\174\099\022\145\246\188\022\111\099\122\078\208\033\076\068\144\094\049\132\237\207\112\195\058\102\017\013\011\213\134\233\138\124\252\021\112\035\144\062\088\063\144\143\082\045\245\234\254\155\242\049\073\247\059\024\012\138\255\035\157\205\238\093\040\179\232\105\209\195\026\223\224\031\205\150\236\008\078\099\215\193\000\000\000\000\073\069\078\068\174\066\096\130",
["LocalScript"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\098\073\068\065\084\120\156\109\147\077\136\078\097\020\199\127\231\062\119\204\107\134\145\175\241\077\054\131\145\148\097\165\176\086\068\122\169\137\133\013\069\089\074\041\195\134\053\059\043\165\148\102\074\089\250\216\080\227\043\034\068\098\193\196\194\199\248\158\049\239\123\239\115\254\186\247\125\199\087\078\061\221\211\061\207\249\159\243\063\231\255\192\031\102\205\243\063\063\025\255\026\244\247\043\072\042\195\041\133\099\166\101\023\117\208\096\157\137\092\086\222\255\109\194\101\100\006\109\137\184\179\189\206\009\204\098\145\155\054\147\151\039\226\112\152\068\071\028\033\026\068\009\043\074\026\056\070\107\168\128\165\144\143\112\149\042\217\250\062\165\215\204\242\178\146\059\075\147\009\116\248\055\006\013\086\197\200\010\115\086\090\096\101\146\209\237\198\070\031\099\056\126\227\163\027\087\138\162\215\010\224\146\002\016\140\138\034\040\161\075\112\036\009\100\101\007\017\121\138\007\152\038\099\042\240\169\018\240\130\255\246\001\108\096\028\128\080\242\044\078\007\208\013\212\139\153\153\008\018\049\058\147\128\008\140\126\031\197\173\136\244\169\200\160\001\224\184\181\130\215\184\141\177\107\044\099\172\037\144\062\123\205\215\061\075\008\157\211\233\124\252\153\185\045\070\220\050\135\015\189\210\228\002\204\142\053\001\018\008\094\047\007\182\070\206\165\246\086\168\229\188\058\183\137\125\189\011\057\002\244\148\101\026\219\076\155\254\101\073\135\255\094\023\228\192\176\057\159\127\212\025\218\048\147\057\192\206\226\191\195\093\119\030\057\012\002\237\192\014\096\086\217\129\067\012\019\192\199\120\016\034\189\139\140\236\225\077\190\206\168\178\012\168\001\167\130\217\153\095\178\144\142\055\129\189\236\064\177\164\224\130\158\152\112\253\165\113\111\241\090\206\191\255\065\165\041\192\005\146\230\073\234\146\052\023\152\061\046\204\180\148\106\096\117\104\035\081\141\054\002\139\075\209\012\243\037\081\185\141\162\131\067\192\238\063\230\176\000\120\001\100\105\119\191\102\035\186\098\141\231\150\147\043\195\060\039\084\002\175\142\062\229\201\233\030\246\003\075\154\235\221\010\156\005\134\128\187\192\027\155\127\067\019\167\188\101\070\154\225\076\108\112\244\058\166\148\236\241\102\222\149\106\104\240\062\000\156\004\182\153\217\133\127\134\255\127\043\020\039\041\149\180\087\210\045\073\247\037\013\074\218\033\041\041\226\141\023\219\167\198\058\143\002\003\191\094\049\084\241\234\000\201\153\042\157\163\035\080\113\178\100\050\045\237\144\155\217\251\226\202\079\186\152\027\075\226\253\187\086\000\000\000\000\073\069\078\068\174\066\096\130",
["MeshPart"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\243\073\068\065\084\120\156\109\083\075\104\092\101\020\062\231\127\220\059\161\038\227\205\099\200\128\230\070\073\138\173\081\092\136\072\113\229\099\225\198\133\107\081\008\082\168\027\197\133\011\045\013\218\082\168\184\105\113\033\110\170\214\069\113\227\139\022\132\010\046\132\046\186\114\035\136\073\238\157\166\018\026\115\103\050\147\225\210\123\255\199\087\254\116\018\139\244\108\206\089\156\199\119\190\115\062\166\251\012\128\096\102\031\226\060\207\219\000\102\249\158\237\164\105\186\062\202\225\224\153\025\123\158\254\043\014\137\216\216\216\120\218\123\127\028\192\147\204\156\000\136\153\249\054\128\127\152\249\098\154\166\215\070\037\161\022\034\004\163\201\232\116\058\111\001\184\006\096\153\153\191\000\112\155\153\035\041\229\103\068\244\108\028\199\087\242\060\063\003\064\001\216\027\042\086\086\086\194\100\159\101\217\178\082\234\171\169\169\169\025\034\186\236\189\191\201\204\199\226\056\126\204\024\051\035\132\184\016\199\113\148\036\201\071\157\078\039\052\060\128\065\089\150\029\097\230\111\152\249\166\148\242\152\049\230\180\016\162\053\057\057\185\034\132\160\237\237\237\171\068\116\030\192\215\068\116\131\153\031\101\230\079\230\230\230\190\087\163\253\223\012\251\010\033\062\168\235\250\211\070\163\177\094\150\229\225\162\040\186\001\030\017\173\055\155\205\027\069\081\188\038\165\116\068\116\014\192\219\000\126\226\205\205\205\067\117\093\255\056\054\054\246\082\089\150\003\034\250\003\192\113\102\126\153\136\102\133\016\149\181\086\088\107\191\109\052\026\167\152\249\085\033\196\140\181\118\195\057\247\138\178\214\038\222\251\086\085\085\104\054\155\019\253\126\255\057\102\158\098\230\019\073\146\028\173\170\138\134\195\161\081\074\253\006\224\153\192\081\081\020\001\245\195\090\235\182\024\012\006\146\153\135\198\152\247\250\253\254\119\204\156\059\231\012\000\031\152\030\221\220\005\232\225\042\221\110\247\119\107\109\064\248\167\247\062\010\231\040\136\104\168\181\126\162\170\170\011\090\235\059\066\136\053\102\062\189\179\179\243\120\160\136\153\123\214\218\191\181\214\239\027\099\014\001\120\145\136\198\000\220\018\075\075\075\067\102\190\062\049\049\113\066\074\249\051\128\207\165\148\135\189\247\187\163\031\009\048\238\040\165\030\002\240\177\148\242\135\086\171\117\022\064\158\166\233\095\001\001\175\174\174\094\234\245\122\203\090\235\071\198\199\199\159\239\118\187\047\016\081\050\061\061\125\050\028\097\107\107\235\023\231\092\055\138\162\215\149\082\212\235\245\042\034\250\050\172\038\194\148\197\197\197\085\034\250\208\057\087\026\099\072\008\113\132\136\174\020\069\049\216\221\221\013\092\092\214\090\207\069\081\020\200\035\231\220\249\052\077\175\238\125\226\189\055\128\152\159\159\191\068\068\239\148\101\249\047\128\055\136\104\222\123\127\189\044\203\092\107\189\237\189\127\215\123\111\234\186\062\091\020\197\201\131\079\220\023\209\190\095\091\091\123\074\041\181\047\166\201\125\049\121\239\111\057\231\046\046\044\044\252\122\191\130\015\212\248\127\057\103\089\054\075\068\237\208\053\142\227\094\187\221\206\030\036\231\187\052\023\174\189\167\232\129\203\000\000\000\000\073\069\078\068\174\066\096\130",
["Model"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\026\073\068\065\084\120\156\165\147\191\107\020\065\020\199\063\111\102\111\239\014\098\032\024\193\031\133\144\084\030\090\232\089\165\073\032\004\017\236\108\163\141\069\004\123\017\082\092\242\007\088\089\025\177\211\042\149\157\134\128\162\141\144\132\088\152\202\034\138\066\148\003\229\018\049\123\183\187\243\100\230\054\222\026\211\057\048\203\190\055\239\125\223\247\125\223\012\252\231\146\163\156\170\024\094\048\070\068\076\130\098\049\228\236\179\198\071\089\196\149\099\163\195\137\034\056\158\115\013\225\049\041\017\022\013\133\042\164\076\048\011\172\028\196\169\170\252\005\192\114\193\072\105\080\103\148\110\193\209\225\024\194\240\139\241\114\220\194\002\135\000\006\141\245\200\080\092\081\029\114\050\036\124\075\107\113\001\061\026\160\232\008\009\000\253\255\254\254\071\065\083\182\095\109\077\250\020\191\099\098\049\088\044\017\006\241\054\198\251\213\167\109\245\091\104\181\016\241\066\136\072\064\247\104\094\098\093\097\026\199\003\160\250\167\009\033\193\113\091\174\242\038\216\234\069\215\001\064\163\165\241\177\075\140\116\187\184\159\192\189\248\238\217\009\251\050\057\055\188\222\097\251\252\008\223\026\017\111\111\125\033\170\043\246\135\097\248\235\119\089\154\075\005\213\064\231\242\050\247\021\110\040\036\222\145\057\162\174\097\117\254\025\119\102\179\215\015\177\249\020\038\043\068\148\026\170\143\120\050\051\031\249\046\154\235\090\113\202\180\169\049\074\015\068\160\030\131\230\092\057\062\182\121\145\237\100\138\168\126\210\163\006\238\149\033\232\237\077\050\183\017\149\167\208\013\163\083\127\159\032\207\017\085\246\133\090\015\149\125\156\243\093\247\017\052\179\024\073\056\181\087\026\227\193\200\074\131\211\178\047\192\030\028\244\213\222\226\132\025\000\040\053\177\136\058\196\171\044\022\036\167\150\101\054\066\180\138\177\066\158\219\016\235\211\068\170\201\078\162\198\215\217\104\006\242\107\154\209\065\105\227\104\187\148\093\148\077\117\233\039\068\222\227\210\093\212\181\065\219\228\073\007\117\239\154\075\205\076\002\081\068\047\060\213\145\090\204\184\051\197\107\203\195\067\250\188\113\093\118\244\230\234\025\242\222\233\192\041\156\057\195\112\252\065\150\102\058\191\001\133\119\244\052\201\245\074\100\000\000\000\000\073\069\078\068\174\066\096\130",
["ModuleScript"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\090\073\068\065\084\120\156\101\147\207\139\143\081\020\198\063\231\222\247\059\051\223\153\154\076\100\034\073\018\011\011\063\106\236\020\043\036\178\154\018\177\080\152\141\048\100\097\241\053\101\099\041\165\088\146\020\127\129\076\106\198\066\137\166\108\038\043\041\069\205\015\076\190\154\121\223\247\222\071\247\125\191\227\199\056\171\219\057\061\207\125\206\057\207\049\058\241\104\068\155\129\001\021\132\229\156\203\176\229\119\136\152\079\169\110\062\014\223\177\025\144\129\041\171\192\103\181\038\194\099\007\219\149\225\204\106\096\132\234\033\088\114\158\024\097\062\148\028\001\102\090\096\099\080\019\068\099\095\183\103\079\017\248\234\140\183\130\050\097\149\138\034\209\237\104\118\049\248\115\145\137\227\247\108\058\253\062\134\037\126\150\009\054\052\060\042\003\147\161\155\017\095\096\121\137\249\046\204\074\218\068\110\123\199\073\103\188\171\056\091\152\141\037\097\029\002\015\062\015\021\229\033\183\196\107\065\200\092\005\022\194\227\024\040\075\020\029\255\134\100\021\129\012\185\122\092\179\192\075\137\168\090\122\202\071\193\254\222\030\250\022\219\052\254\198\183\110\080\019\152\161\204\065\046\166\122\224\098\027\088\042\177\190\084\236\003\043\184\240\189\205\174\050\240\161\066\118\228\255\110\129\136\203\067\165\228\224\034\124\244\064\111\131\128\163\161\130\023\125\107\057\051\116\138\236\243\056\179\146\156\089\061\192\063\004\064\213\130\152\053\099\050\166\045\024\230\061\189\159\222\115\107\244\046\091\136\220\095\127\150\115\102\054\033\201\155\089\229\023\087\015\131\152\090\000\222\100\129\043\177\224\122\051\112\185\127\011\195\163\207\152\142\145\211\056\182\001\071\037\173\175\231\151\140\212\033\144\145\229\161\218\248\254\220\241\188\187\135\241\069\227\230\206\189\244\019\025\119\142\083\212\222\024\001\158\002\171\204\076\236\075\102\173\099\091\230\177\050\208\235\061\091\155\013\088\040\152\094\183\137\028\199\036\176\026\216\216\105\121\055\112\085\210\019\051\166\178\116\003\018\067\121\201\119\025\069\136\196\118\078\211\140\005\006\248\097\102\151\036\165\223\071\059\042\210\140\175\001\187\192\014\100\249\079\230\155\077\078\020\101\101\125\188\067\161\032\203\115\190\001\061\146\206\003\135\059\103\145\020\228\192\067\224\193\010\091\253\031\146\250\037\189\149\212\150\244\069\210\130\164\087\146\082\075\169\094\207\160\213\210\074\147\086\097\102\009\112\012\024\076\023\221\081\048\103\102\115\105\011\201\015\191\000\099\101\014\029\186\159\084\099\000\000\000\000\073\069\078\068\174\066\096\130",
["Motor6D"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\135\073\068\065\084\120\156\205\147\061\075\028\081\020\134\159\115\063\198\085\052\224\007\108\037\168\144\096\054\065\139\096\017\072\155\082\020\242\003\236\244\103\232\254\001\003\233\147\054\176\138\089\210\166\074\101\161\022\054\018\012\065\196\034\144\128\130\097\116\157\059\115\143\076\118\133\053\069\154\105\124\225\126\190\112\224\060\239\189\080\081\210\093\084\088\191\219\247\180\129\034\162\093\091\133\141\062\191\223\171\042\041\167\070\075\135\221\032\083\154\119\207\049\098\130\227\242\120\073\078\104\105\242\188\198\012\074\098\012\177\244\016\178\129\159\252\056\088\147\224\102\119\116\092\012\239\242\130\103\008\087\034\160\134\154\135\125\096\117\214\050\174\240\086\097\066\011\114\021\034\202\072\167\078\155\150\054\157\073\088\208\156\199\094\089\078\134\249\195\013\062\090\036\189\038\099\093\077\125\140\223\023\231\172\248\033\108\122\005\003\134\235\194\050\031\149\205\167\134\247\078\002\094\133\243\039\129\179\173\215\082\252\219\227\215\038\017\248\213\127\215\248\172\039\064\199\024\156\195\160\040\102\023\018\208\078\163\205\027\132\087\064\118\175\146\226\177\124\060\090\100\175\228\129\032\038\041\187\173\040\071\044\107\017\095\066\182\133\232\209\050\219\240\119\252\039\059\205\136\196\152\033\078\061\129\156\177\099\207\228\194\023\189\007\241\219\033\023\047\022\177\225\148\081\015\054\165\007\017\166\163\048\232\132\194\197\140\061\107\248\030\132\118\072\123\049\022\212\172\101\159\166\172\166\115\090\183\150\015\185\048\097\149\060\148\049\070\030\009\124\042\193\075\213\135\084\149\225\003\248\076\183\006\094\188\045\167\227\223\189\000\000\000\000\073\069\078\068\174\066\096\130",
["NumberValue"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\162\073\068\065\084\120\156\181\083\077\139\019\065\016\173\087\189\172\113\017\069\204\030\115\017\018\188\122\090\088\246\226\065\253\013\030\252\017\130\103\103\002\254\013\143\094\189\237\217\139\122\145\021\081\240\035\018\210\051\038\144\096\024\118\205\165\051\203\244\147\078\038\217\108\152\241\034\022\052\069\117\189\042\222\171\234\022\169\049\146\008\167\046\254\191\070\018\147\201\228\090\150\101\055\086\119\073\146\220\028\141\070\123\219\088\173\040\054\000\232\156\123\058\155\205\158\068\081\164\105\154\094\037\249\034\207\243\007\165\020\173\109\000\160\040\027\221\243\222\159\119\187\093\239\156\187\165\170\119\001\252\010\205\227\056\190\192\203\006\237\144\180\214\062\006\240\072\068\014\188\247\086\085\191\146\220\007\112\032\034\039\170\250\188\213\106\189\094\225\117\155\128\049\102\040\034\167\034\114\174\170\111\072\126\043\041\159\122\239\223\003\008\185\106\139\162\104\039\248\126\191\127\127\048\024\156\076\167\211\235\229\000\187\214\218\151\085\053\186\185\219\056\142\023\250\141\049\135\000\070\205\102\243\119\041\239\014\201\254\106\200\151\040\115\073\047\008\226\120\060\190\237\156\123\038\034\071\000\118\072\190\037\185\171\170\071\034\050\019\145\087\243\249\060\234\116\058\243\075\091\000\150\036\178\044\059\035\249\073\068\118\001\124\084\213\015\198\152\159\036\061\128\099\017\249\210\110\183\139\237\189\107\169\127\225\123\189\222\149\036\073\062\167\105\250\048\196\195\225\240\208\090\251\035\220\087\206\064\046\244\051\248\070\163\209\020\145\119\069\081\124\015\122\139\162\216\083\213\227\060\207\185\249\128\086\171\095\051\168\098\181\006\213\216\002\247\047\063\172\182\118\157\088\082\252\235\055\254\003\060\187\004\107\100\181\082\170\000\000\000\000\073\069\078\068\174\066\096\130",
["ObjectValue"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\162\073\068\065\084\120\156\181\083\077\139\019\065\016\173\087\189\172\113\017\069\204\030\115\017\018\188\122\090\088\246\226\065\253\013\030\252\017\130\103\103\002\254\013\143\094\189\237\217\139\122\145\021\081\240\035\018\210\051\038\144\096\024\118\205\165\051\203\244\147\078\038\217\108\152\241\034\022\052\069\117\189\042\222\171\234\022\169\049\146\008\167\046\254\191\070\018\147\201\228\090\150\101\055\086\119\073\146\220\028\141\070\123\219\088\173\040\054\000\232\156\123\058\155\205\158\068\081\164\105\154\094\037\249\034\207\243\007\165\020\173\109\000\160\040\027\221\243\222\159\119\187\093\239\156\187\165\170\119\001\252\010\205\227\056\190\192\203\006\237\144\180\214\062\006\240\072\068\014\188\247\086\085\191\146\220\007\112\032\034\039\170\250\188\213\106\189\094\225\117\155\128\049\102\040\034\167\034\114\174\170\111\072\126\043\041\159\122\239\223\003\008\185\106\139\162\104\039\248\126\191\127\127\048\024\156\076\167\211\235\229\000\187\214\218\151\085\053\186\185\219\056\142\023\250\141\049\135\000\070\205\102\243\119\041\239\014\201\254\106\200\151\040\115\073\047\008\226\120\060\190\237\156\123\038\034\071\000\118\072\190\037\185\171\170\071\034\050\019\145\087\243\249\060\234\116\058\243\075\091\000\150\036\178\044\059\035\249\073\068\118\001\124\084\213\015\198\152\159\036\061\128\099\017\249\210\110\183\139\237\189\107\169\127\225\123\189\222\149\036\073\062\167\105\250\048\196\195\225\240\208\090\251\035\220\087\206\064\046\244\051\248\070\163\209\020\145\119\069\081\124\015\122\139\162\216\083\213\227\060\207\185\249\128\086\171\095\051\168\098\181\006\213\216\002\247\047\063\172\182\118\157\088\082\252\235\055\254\003\060\187\004\107\100\181\082\170\000\000\000\000\073\069\078\068\174\066\096\130",
["Part"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\120\073\068\065\084\120\156\109\083\077\104\019\081\016\158\111\222\110\067\004\081\208\022\036\107\216\021\137\138\061\122\082\060\090\196\123\003\122\240\092\234\161\224\069\068\004\017\245\080\176\021\069\016\188\120\016\011\205\065\168\094\068\004\237\197\042\010\138\189\180\010\239\109\105\188\180\033\096\018\216\180\217\055\242\210\108\136\197\057\236\190\249\249\230\205\155\249\134\232\095\129\136\176\136\192\041\238\092\173\086\247\100\078\017\241\050\127\022\131\001\231\142\001\016\247\215\090\159\103\230\041\034\026\033\162\231\141\070\227\233\232\232\104\051\075\012\192\246\019\136\008\050\096\028\199\103\069\228\058\017\157\006\176\032\034\085\034\186\196\204\141\052\077\239\019\209\092\020\069\073\015\043\200\192\090\235\019\204\124\149\136\198\136\232\007\128\233\098\177\184\216\171\038\084\074\077\089\107\047\018\209\119\034\154\014\195\240\093\086\053\105\173\247\199\113\252\173\217\108\138\049\230\238\192\179\212\242\242\242\080\166\107\173\047\104\173\083\099\076\051\142\227\083\206\230\245\124\135\136\232\096\173\086\251\072\068\227\090\235\099\214\218\105\000\159\137\040\093\089\089\041\228\114\185\073\000\101\017\249\010\224\168\136\028\039\162\047\221\004\157\078\135\125\223\079\210\052\189\198\204\074\041\117\147\153\223\196\113\252\194\090\251\027\192\004\017\181\068\228\033\017\189\022\145\151\074\041\118\088\238\207\015\096\207\243\036\138\162\247\075\075\075\099\074\169\203\068\116\014\192\013\017\153\241\060\239\076\024\134\143\234\245\122\093\068\124\107\187\067\160\110\002\223\247\165\103\232\242\096\120\120\024\065\016\188\178\214\206\017\209\098\020\069\179\065\016\212\092\079\242\249\188\151\077\172\159\000\059\146\038\073\178\229\244\066\161\160\230\231\231\021\000\031\128\234\145\071\085\042\021\215\216\182\136\164\025\005\060\247\217\222\222\222\242\060\111\223\208\208\208\017\000\159\136\200\005\113\028\199\221\160\074\165\130\114\185\156\246\038\081\000\048\002\160\123\025\187\089\038\073\018\139\200\002\051\063\054\198\060\216\220\220\012\028\211\000\116\092\144\003\175\174\174\230\214\214\214\174\048\243\091\017\249\153\207\231\063\100\111\134\123\147\043\209\024\051\238\154\006\224\128\181\246\054\017\157\084\074\149\210\052\157\101\230\091\000\066\017\121\210\110\183\103\074\165\210\159\046\118\215\050\209\198\198\198\222\086\171\053\001\096\082\068\130\094\139\092\176\171\240\078\177\088\252\181\155\254\125\113\141\203\206\235\235\235\135\141\049\247\140\049\207\220\126\012\176\179\191\173\255\021\231\028\076\052\072\235\193\117\206\236\127\001\248\134\111\145\110\153\064\024\000\000\000\000\073\069\078\068\174\066\096\130",
["Paste"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\184\073\068\065\084\120\156\093\083\077\111\020\071\016\125\085\221\051\179\179\031\182\119\193\024\219\004\127\096\243\033\229\004\007\174\236\041\242\049\178\204\017\229\152\255\128\132\195\207\224\022\229\224\075\148\067\046\017\156\188\201\015\072\114\136\162\072\241\194\010\196\130\145\099\007\175\189\227\249\232\042\212\227\093\219\162\071\163\174\150\250\189\122\245\170\154\048\090\155\170\252\029\160\157\078\199\180\219\237\098\107\235\231\025\230\228\057\049\191\107\212\235\095\175\173\173\101\248\017\140\013\136\191\079\068\090\238\056\253\203\195\198\198\102\216\108\206\233\189\123\253\160\086\091\093\103\166\117\034\164\039\039\217\015\189\222\247\047\122\189\111\108\111\113\177\248\245\105\187\024\039\038\085\101\034\146\095\126\235\079\135\019\252\040\063\062\136\143\250\127\005\034\242\045\049\071\076\048\034\178\203\054\122\086\189\122\167\017\197\205\055\197\085\183\245\213\236\236\177\170\146\245\096\096\147\169\042\015\191\152\159\126\156\039\081\117\207\102\002\069\204\134\203\044\034\174\030\004\209\147\214\204\124\164\108\223\239\116\223\238\003\248\169\131\142\177\219\219\219\083\237\118\231\208\041\166\006\131\052\190\084\011\163\234\245\101\005\179\120\105\105\154\234\135\131\035\076\180\046\087\039\155\021\030\012\178\154\026\219\240\196\015\240\000\254\206\044\240\084\224\036\045\156\228\211\147\161\206\052\032\151\099\199\211\053\165\185\086\196\146\038\252\247\063\093\249\056\200\020\076\057\068\210\177\007\246\240\048\137\125\080\228\206\218\192\176\033\161\223\255\252\131\135\073\134\122\045\198\245\133\005\084\171\021\028\190\222\229\254\219\015\116\101\118\134\149\070\181\121\002\107\181\236\000\051\067\156\128\200\224\214\173\219\040\068\097\152\017\134\033\086\039\012\086\174\053\145\035\192\191\239\135\222\149\049\030\118\028\136\008\136\009\042\014\221\238\014\210\204\033\012\003\164\233\009\002\027\224\206\237\155\152\106\214\033\253\225\069\060\108\081\016\141\021\168\042\136\045\150\150\150\207\020\156\014\013\035\140\042\200\114\063\052\004\156\021\240\153\002\038\175\160\192\171\151\175\144\022\005\002\107\253\196\097\056\076\208\168\197\248\242\238\253\242\236\046\042\192\104\149\030\120\059\216\096\233\198\050\156\243\157\228\114\078\061\121\020\088\136\040\252\119\110\225\005\019\207\020\168\067\119\103\007\089\033\176\134\075\146\149\149\021\052\091\151\112\156\106\057\244\108\184\196\148\004\068\069\233\001\089\086\017\085\034\214\155\171\055\092\238\212\148\015\133\008\113\165\050\114\153\024\004\209\092\206\219\168\054\046\217\012\219\242\093\236\254\159\081\028\182\160\150\124\050\245\198\238\039\014\251\195\004\142\188\034\024\152\011\037\052\042\149\255\124\016\134\220\037\224\227\193\177\098\111\144\228\080\132\002\008\001\234\085\016\067\136\016\049\241\158\049\246\229\008\175\159\000\051\080\054\001\248\238\040\196\000\000\000\000\073\069\078\068\174\066\096\130",
["Pause"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\241\073\068\065\084\120\156\197\147\187\079\027\065\016\198\127\251\056\157\237\088\121\040\049\018\014\081\168\065\020\136\063\032\082\186\180\070\070\244\145\040\082\208\166\188\163\161\037\249\031\146\002\142\146\134\010\137\046\069\082\033\075\072\072\148\150\112\225\151\100\099\223\099\162\061\027\108\072\186\020\249\164\093\237\206\236\142\102\190\249\070\049\133\008\042\012\081\171\171\040\119\175\215\017\165\200\152\195\217\217\059\219\106\045\200\214\086\148\242\008\202\109\065\128\005\060\192\186\115\016\160\093\224\157\157\137\205\249\142\142\048\206\118\247\071\185\071\123\123\100\007\007\060\239\116\248\146\166\188\206\050\176\150\155\082\137\079\195\033\047\069\248\154\036\088\173\041\104\205\047\165\248\012\100\097\136\088\151\178\082\112\126\078\113\125\157\247\219\219\188\209\026\162\136\155\139\011\124\099\120\177\182\198\135\205\077\076\167\003\199\199\020\014\015\049\251\251\136\171\092\071\209\164\134\235\107\018\107\233\086\171\036\139\139\036\090\211\189\188\036\029\012\024\023\010\116\150\151\025\084\042\164\034\244\174\174\016\199\017\211\186\112\025\020\139\168\044\195\140\070\088\119\023\193\148\074\121\118\058\077\177\163\017\222\120\140\129\124\221\067\063\096\082\205\150\043\195\033\142\031\250\030\067\243\143\208\255\053\064\024\006\042\039\113\030\146\115\059\131\231\205\236\243\190\040\066\053\026\141\073\023\156\099\056\204\165\155\090\075\234\008\020\201\091\040\034\100\090\147\250\126\222\102\215\129\092\198\237\246\134\083\075\166\235\245\073\196\106\021\147\166\148\251\125\076\175\151\203\181\188\180\132\049\006\027\199\148\091\045\138\131\065\094\242\147\149\149\089\038\074\004\237\134\038\008\120\005\124\243\060\222\186\164\146\132\166\008\046\252\130\008\223\125\031\079\004\063\142\249\209\108\242\017\054\104\183\127\102\247\157\157\078\227\179\147\147\092\243\082\171\145\221\222\210\117\068\247\122\060\061\061\133\074\005\093\171\049\222\221\165\175\212\100\152\254\192\188\096\092\208\187\243\223\132\036\034\234\055\013\124\196\076\006\108\126\161\000\000\000\000\073\069\078\068\174\066\096\130",
["Placeholder"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\206\073\068\065\084\120\156\133\147\177\138\020\065\016\134\187\122\059\246\082\017\217\227\076\054\021\021\245\178\021\046\017\065\049\056\209\064\195\227\048\186\232\192\104\003\223\064\124\002\035\025\048\021\004\113\081\080\239\033\156\173\250\119\070\054\089\054\056\246\224\134\229\182\164\231\186\251\102\006\209\074\166\186\235\175\175\187\170\167\140\137\166\074\170\074\097\065\089\166\189\024\058\247\149\146\038\233\140\113\009\064\148\118\085\253\146\206\242\060\223\176\214\086\091\091\116\170\170\150\136\214\041\051\152\109\046\060\061\008\149\153\159\058\231\062\244\122\189\247\179\217\236\182\079\246\177\174\222\118\129\094\200\204\251\068\244\210\057\119\072\068\239\170\170\122\083\020\197\189\000\073\165\181\072\163\209\168\134\001\056\016\145\047\000\174\197\184\079\102\230\163\162\040\238\007\125\173\077\061\211\224\136\200\225\116\058\253\004\224\138\095\143\199\099\023\079\044\203\114\027\192\079\000\143\034\036\052\084\235\206\050\243\043\000\031\153\249\114\243\148\224\215\016\000\183\060\164\044\203\135\045\077\081\020\119\068\228\219\124\062\191\212\077\142\230\111\227\191\204\124\087\068\190\046\022\139\141\244\010\235\245\122\233\243\150\203\229\213\248\168\093\192\112\056\212\058\193\218\077\099\204\201\106\181\058\075\037\152\115\242\051\017\241\053\222\108\094\187\233\079\038\147\039\000\126\136\200\141\214\077\053\056\204\252\088\068\142\152\121\059\236\167\038\002\120\001\224\059\051\095\111\053\049\090\132\228\121\254\032\064\134\049\006\096\207\215\093\150\229\032\104\107\168\007\080\034\132\128\255\133\001\236\024\099\094\171\234\091\085\221\036\162\029\107\237\094\191\223\255\021\053\017\112\049\011\245\056\144\111\140\255\027\063\231\121\126\236\156\059\080\213\069\085\085\207\007\131\193\239\044\203\082\242\063\237\111\207\216\170\247\255\118\049\206\035\085\187\219\024\237\174\253\001\004\249\097\052\220\073\126\020\000\000\000\000\073\069\078\068\174\066\096\130",
["Play"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\222\073\068\065\084\120\156\133\146\177\107\020\081\016\198\127\243\118\239\246\176\176\178\240\044\084\132\008\241\144\052\233\002\118\098\167\085\210\218\137\157\136\218\137\187\219\165\180\181\178\020\060\109\172\004\255\128\171\044\047\068\065\052\065\189\131\004\069\130\194\221\237\190\145\055\247\114\152\184\226\007\143\125\188\217\239\155\153\111\006\064\008\200\113\060\161\133\034\118\063\010\001\149\092\213\229\185\030\141\101\121\118\094\114\121\156\229\217\133\040\148\198\227\076\044\064\085\056\078\140\112\107\172\157\080\244\250\084\166\175\040\120\010\156\161\164\162\135\080\144\160\056\010\017\074\241\141\002\043\217\202\020\101\143\014\061\148\155\008\047\041\232\243\129\115\246\210\071\216\066\254\209\026\233\206\175\029\033\033\099\074\200\048\033\101\149\154\085\038\044\049\100\151\132\007\156\230\019\125\042\010\052\036\165\180\111\056\072\055\239\158\029\051\126\077\194\178\214\090\163\150\075\073\105\153\164\178\133\242\005\184\015\108\211\163\102\136\082\090\020\055\098\228\084\180\021\120\243\166\072\017\090\204\168\240\204\112\092\194\113\021\225\005\194\027\134\092\054\114\048\122\241\123\019\014\133\060\021\074\005\044\225\184\130\240\140\135\244\204\232\156\180\113\052\127\073\205\155\154\225\173\236\083\180\233\088\100\132\088\025\141\080\234\072\079\226\203\015\224\027\194\109\030\241\150\231\036\108\048\107\018\168\022\045\004\091\106\246\016\198\056\238\226\205\190\253\184\096\102\098\026\179\133\018\061\194\012\161\099\068\207\008\248\074\194\029\060\239\088\230\059\027\212\139\093\008\012\203\003\222\250\075\237\222\070\217\069\025\224\184\193\132\107\120\006\148\236\211\143\107\030\038\016\201\243\010\148\054\142\147\212\124\198\243\158\054\247\056\224\035\155\028\032\054\046\023\251\157\123\114\012\041\083\179\105\064\205\166\045\237\069\038\172\227\233\227\088\039\161\108\038\030\066\184\069\139\046\025\005\063\041\254\216\137\184\105\255\195\111\179\097\179\191\007\088\102\200\000\000\000\000\073\069\078\068\174\066\096\130",
["Player"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\182\073\068\065\084\120\156\149\083\193\138\019\065\020\172\215\211\073\064\088\023\020\022\134\033\157\152\220\188\008\126\130\055\047\030\253\000\065\100\015\162\130\030\101\174\030\252\010\015\094\020\241\023\246\188\122\246\056\061\025\179\201\036\238\162\003\074\039\067\166\164\117\018\067\018\049\022\012\244\188\174\087\175\222\235\110\193\095\064\082\000\200\242\087\068\136\125\017\199\177\218\039\134\181\010\091\152\078\167\007\206\185\067\146\108\183\219\095\068\100\246\079\001\210\059\021\166\105\122\151\228\067\017\089\144\244\149\127\040\165\158\027\099\078\151\156\045\001\214\027\214\218\107\000\222\003\120\185\088\044\078\124\080\107\253\128\228\077\099\204\029\017\153\175\139\168\029\174\066\000\223\072\190\233\247\251\131\094\175\151\002\120\013\224\112\056\028\030\108\146\213\102\064\107\237\219\014\186\221\238\202\102\089\150\170\110\101\011\122\051\048\155\205\134\090\235\075\131\193\224\056\073\146\019\165\148\079\190\175\148\026\071\081\084\252\234\091\100\167\128\196\113\044\222\118\146\036\079\148\082\143\068\228\086\237\242\188\209\104\060\022\145\210\187\003\080\121\017\018\191\165\214\135\050\153\076\194\162\040\174\106\173\143\000\092\033\233\201\057\201\139\032\008\114\099\204\197\159\193\067\100\153\156\101\217\141\170\170\158\145\052\034\082\145\156\251\138\053\183\073\178\085\175\063\180\090\173\023\097\024\078\086\014\070\163\209\145\115\238\173\136\156\086\085\245\170\217\108\126\142\162\232\187\183\090\039\005\121\158\095\118\206\245\001\060\005\080\116\058\157\123\171\251\144\101\217\237\052\077\063\238\154\242\038\172\181\215\173\181\159\124\209\213\049\150\101\121\006\224\157\063\042\063\036\223\214\142\207\199\003\017\249\234\239\200\120\060\158\239\083\112\127\212\207\247\191\185\063\001\068\032\249\068\208\032\034\026\000\000\000\000\073\069\078\068\174\066\096\130",
["Players"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\228\073\068\065\084\120\156\141\083\077\136\020\071\020\254\094\085\117\079\207\244\076\235\234\006\089\205\018\227\015\130\168\185\024\130\007\081\018\193\031\012\098\064\131\172\123\240\038\130\120\082\017\133\081\052\162\039\047\201\205\091\084\208\067\132\004\131\075\002\234\006\053\034\024\162\162\073\070\084\076\246\160\174\184\227\204\246\244\116\087\189\039\061\227\046\234\041\239\084\085\239\123\095\213\087\239\123\192\155\016\001\117\087\004\017\081\034\242\102\255\126\190\011\146\028\008\192\076\158\016\100\244\251\053\145\042\088\034\162\250\219\197\019\249\167\231\086\148\227\113\152\143\183\093\025\155\096\163\014\243\193\042\189\090\112\099\023\009\118\000\100\028\228\212\243\030\028\217\223\172\216\133\031\060\163\067\043\175\184\250\233\117\091\149\225\125\206\073\072\130\011\017\243\110\012\254\018\119\136\228\252\134\169\175\226\228\078\193\232\015\089\128\212\186\088\249\244\105\180\249\226\189\060\159\223\028\164\193\165\040\244\150\054\019\007\199\176\138\249\243\104\112\232\055\149\003\234\177\037\128\052\017\193\024\130\038\060\086\109\121\217\083\219\208\031\213\054\205\187\049\167\194\070\240\064\004\208\185\022\097\109\137\059\151\171\092\194\031\255\052\027\032\057\214\074\237\095\237\212\221\247\172\236\045\047\047\127\149\250\102\152\061\119\121\227\116\239\248\159\161\156\104\142\167\215\083\203\143\021\225\219\030\063\189\149\215\210\196\039\061\063\185\106\166\020\205\252\208\185\100\160\047\124\048\052\151\134\169\100\022\034\021\032\227\056\134\172\148\159\147\250\072\175\244\087\216\062\153\050\240\107\109\178\011\141\051\171\183\176\208\055\012\137\050\232\209\237\073\246\245\079\084\072\138\190\002\131\033\153\072\036\074\178\041\124\034\002\125\166\180\105\215\079\173\062\025\205\074\014\083\227\204\151\051\156\164\067\149\192\251\164\145\100\028\248\090\185\150\221\025\174\168\252\091\182\188\007\134\116\012\058\091\187\218\184\219\043\234\071\069\020\040\002\044\115\012\166\047\140\035\093\006\099\122\046\166\228\027\101\153\071\075\204\079\032\124\083\051\029\208\022\186\105\220\163\025\108\042\032\087\043\006\102\113\154\049\010\090\151\218\105\214\099\178\241\102\203\020\205\213\122\043\251\072\043\037\165\068\190\163\181\145\042\181\232\118\166\057\204\004\028\178\050\229\229\193\225\255\174\053\183\075\226\142\058\017\069\096\100\150\094\080\181\010\053\048\109\141\231\045\105\209\236\203\176\116\176\191\080\124\024\255\174\066\179\072\098\155\219\140\160\008\100\057\027\015\104\137\204\250\225\239\235\231\054\005\203\202\013\198\218\139\217\059\126\207\163\111\100\125\239\088\219\027\038\173\231\195\114\110\051\002\017\231\003\226\105\044\171\207\062\127\171\051\005\210\197\119\140\148\247\179\042\093\079\052\058\037\084\161\178\054\084\050\134\066\079\083\209\120\084\242\252\212\170\014\166\202\093\236\100\027\115\115\229\140\135\008\050\109\212\166\028\251\023\220\088\214\007\130\069\087\132\000\162\132\253\151\111\099\223\127\253\255\136\206\168\191\035\251\053\146\188\109\065\143\023\145\196\000\000\000\000\073\069\078\068\174\066\096\130",
["PointLight"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\237\073\068\065\084\120\156\157\147\191\107\020\081\016\199\063\243\246\199\145\092\033\119\101\032\129\128\034\088\136\081\004\021\047\107\058\005\049\149\069\058\065\016\005\109\146\066\016\033\248\023\104\163\229\253\001\138\193\202\070\020\067\114\118\054\218\136\008\022\065\099\099\033\194\153\219\221\247\070\222\189\187\203\037\119\177\112\096\217\221\249\206\204\155\249\206\247\009\251\076\085\165\255\045\098\052\248\220\192\055\108\034\162\241\056\103\072\202\098\213\147\105\207\219\017\193\142\043\098\246\059\158\042\145\127\023\216\123\150\106\203\050\217\202\105\092\011\069\071\227\227\189\237\227\091\117\170\199\171\057\114\057\034\057\001\130\163\088\084\165\025\038\244\077\162\123\058\080\069\066\114\022\121\176\224\208\041\129\233\146\252\163\035\255\004\238\088\135\211\071\060\246\150\044\218\141\239\021\240\064\120\214\203\238\063\178\228\096\045\038\093\104\019\095\000\062\192\196\146\199\022\100\189\236\199\119\071\080\109\204\230\112\059\133\090\014\045\007\111\028\204\025\228\142\200\235\159\093\062\244\124\211\192\178\106\099\186\132\235\006\102\044\124\078\176\143\099\176\029\033\218\178\200\047\069\127\068\196\117\131\173\068\164\223\006\220\192\054\080\219\033\078\019\202\045\197\088\197\109\067\221\142\221\111\174\141\166\034\051\006\121\036\148\147\138\172\056\228\085\069\054\238\143\172\157\046\137\087\035\145\103\086\245\098\165\224\247\092\066\252\165\064\111\128\158\013\068\153\151\059\184\023\085\116\074\100\243\189\234\106\143\187\007\110\192\038\100\213\002\125\168\232\084\138\089\244\132\170\158\057\220\198\180\171\242\238\251\031\109\204\198\176\038\104\051\098\243\009\168\243\162\051\065\124\126\117\246\040\184\122\010\055\067\050\038\039\093\073\136\174\248\019\039\100\227\043\200\178\067\206\065\086\243\201\187\135\019\198\024\229\034\123\158\235\252\221\128\103\093\209\249\184\113\138\028\216\234\016\152\107\118\171\208\249\075\125\025\255\051\241\127\108\248\230\030\016\224\037\027\024\063\200\254\002\171\182\226\077\251\078\229\010\000\000\000\000\073\069\078\068\174\066\096\130",
["Reference"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\083\073\068\065\084\120\156\053\083\207\079\098\087\020\254\238\227\033\234\032\026\229\151\194\040\180\085\034\026\193\016\042\052\130\153\016\023\206\036\196\054\053\214\133\255\064\211\232\162\127\000\153\101\055\046\219\196\037\043\041\027\236\174\027\148\132\103\074\032\017\002\069\094\156\206\068\005\127\004\081\073\128\136\226\187\205\125\195\044\078\206\205\201\057\223\119\114\190\239\018\000\160\148\018\150\009\033\148\082\170\007\096\057\058\058\026\175\215\235\058\086\086\171\213\119\054\155\173\172\215\235\063\002\184\234\246\017\150\201\151\071\023\100\070\020\197\031\146\201\164\163\084\042\077\220\223\223\235\036\073\226\134\134\134\238\172\086\235\185\223\239\255\215\225\112\236\003\072\019\066\058\242\044\237\178\003\112\199\098\177\159\083\169\212\091\147\201\164\155\155\155\131\086\171\005\199\113\184\189\189\069\169\084\130\040\138\245\217\217\217\131\245\245\245\223\123\123\123\015\024\008\233\002\204\198\098\177\095\115\185\220\143\129\064\224\149\217\108\166\233\116\154\230\243\121\180\219\109\232\245\122\172\172\172\144\118\187\077\034\145\200\211\212\212\212\223\155\155\155\191\041\149\202\127\120\000\090\081\020\191\023\004\225\109\048\024\124\229\114\185\232\238\238\046\018\137\004\247\252\252\140\078\167\003\150\027\141\006\221\218\218\146\054\054\054\122\194\225\240\082\042\149\250\180\184\184\120\197\154\190\074\038\147\078\163\209\168\155\158\158\166\079\079\079\184\184\184\032\108\253\080\040\132\157\157\029\140\142\142\066\016\004\082\173\086\057\187\221\046\077\076\076\104\142\143\143\231\106\181\218\055\124\046\151\123\093\040\020\198\087\087\087\161\086\171\105\167\211\225\182\183\183\153\034\024\025\025\065\177\088\196\240\240\048\250\251\251\229\080\042\149\036\016\008\032\028\014\143\039\018\009\043\223\104\052\180\236\218\099\099\099\224\121\158\180\090\045\024\012\006\244\244\244\224\228\228\004\135\135\135\208\104\052\008\006\131\208\233\152\170\128\217\108\070\171\213\050\092\094\094\142\242\140\145\073\197\024\153\037\084\042\021\097\151\127\124\124\004\059\034\123\047\047\047\099\097\097\065\006\237\250\070\246\014\011\142\153\068\163\209\212\110\110\110\228\230\190\190\062\182\009\020\010\005\006\007\007\097\177\088\048\063\063\015\149\074\133\151\151\023\025\224\250\250\154\129\213\116\058\093\149\155\153\153\041\219\108\182\243\116\058\141\102\179\201\064\040\107\100\032\094\175\023\062\159\079\102\102\114\050\195\117\058\029\026\143\199\153\180\101\159\207\119\198\013\012\012\124\242\251\253\197\179\179\179\135\124\062\207\177\013\021\010\133\172\198\254\254\062\162\209\040\234\245\186\188\017\171\023\010\005\034\138\098\211\237\118\159\152\076\166\015\204\007\087\014\135\035\230\116\058\109\145\072\228\157\036\073\074\183\219\045\049\128\211\211\083\121\152\177\179\200\100\050\092\052\026\149\038\039\039\051\030\143\039\010\224\191\207\151\163\148\169\241\102\111\111\239\151\108\054\235\215\235\245\067\030\143\071\190\001\051\209\195\195\003\178\217\044\042\149\074\211\110\183\167\215\214\214\254\048\026\141\127\017\066\030\191\124\038\025\004\192\183\130\032\252\036\008\071\206\074\165\252\154\082\042\127\038\016\082\051\024\012\229\239\188\222\226\210\210\210\159\060\207\039\216\112\040\068\063\107\023\162\148\123\079\136\148\201\100\148\046\151\203\114\087\175\127\029\143\031\090\174\202\101\003\000\078\055\102\172\046\184\061\231\214\113\211\007\000\031\217\240\065\136\242\111\222\227\229\127\017\078\165\099\210\073\035\240\000\000\000\000\073\069\078\068\174\066\096\130",
["Rename"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\022\073\068\065\084\120\156\133\210\095\072\083\081\028\007\240\115\206\238\189\231\238\143\185\153\203\018\167\018\034\057\103\061\204\052\162\216\075\182\057\074\010\082\212\160\094\162\135\040\140\048\008\122\152\123\208\138\158\012\130\162\032\082\035\242\015\006\149\136\061\088\228\124\168\038\100\122\103\057\165\101\182\217\180\053\157\251\115\238\118\079\092\027\209\255\126\047\231\225\240\057\223\223\249\157\003\192\127\138\058\000\162\221\181\010\136\032\016\250\172\155\006\142\041\243\006\207\232\012\161\097\139\086\222\135\255\194\014\010\080\139\219\172\128\229\099\226\084\215\206\106\074\051\047\068\034\090\014\074\203\012\082\120\159\075\209\232\089\230\095\201\096\178\150\129\229\061\100\234\110\101\053\002\027\059\085\218\178\245\005\187\237\128\172\248\192\219\225\043\155\163\225\208\071\248\087\092\107\100\160\201\067\102\251\149\086\117\214\158\014\085\086\253\006\164\202\079\112\234\076\134\097\049\009\190\029\229\189\035\247\004\244\027\166\000\077\087\218\088\104\018\200\244\029\100\085\231\084\119\102\149\157\210\083\150\144\144\119\008\175\250\094\160\088\208\171\096\057\012\025\014\047\192\095\147\167\043\139\216\098\187\055\049\219\139\173\154\220\234\078\157\241\180\158\194\037\146\252\056\200\133\003\128\126\241\043\136\154\227\113\048\232\127\010\082\043\071\229\003\228\046\164\181\182\075\141\012\172\243\144\217\094\100\213\228\238\239\208\026\155\054\064\244\133\036\062\220\230\024\181\082\146\020\091\197\208\168\027\135\231\252\174\121\095\168\177\234\138\240\094\198\212\098\001\204\147\066\011\007\235\004\226\190\065\109\234\077\053\093\186\052\142\207\223\230\032\207\082\137\045\021\087\199\005\188\026\008\140\166\162\129\006\025\015\180\219\176\220\057\186\229\040\224\229\023\237\107\198\182\241\158\154\005\049\060\076\197\229\254\196\138\231\000\141\206\030\074\197\252\109\241\224\163\035\212\115\185\098\228\249\249\082\131\140\038\028\070\110\237\222\215\143\155\089\121\237\056\001\108\163\055\247\126\138\004\134\104\050\210\159\136\124\195\082\204\223\026\255\244\224\008\021\046\087\184\038\046\154\243\215\102\213\157\198\223\062\018\004\029\039\249\218\098\115\213\085\109\097\141\030\050\239\068\067\238\052\011\017\165\020\111\035\145\177\055\120\105\202\227\034\201\120\253\182\115\175\063\200\201\101\078\129\208\180\103\154\237\212\166\204\219\113\109\171\221\153\181\056\051\037\142\063\236\100\227\230\002\041\099\163\041\153\152\121\129\087\222\251\070\084\012\058\044\227\129\246\034\108\106\018\018\223\127\170\195\001\025\042\129\028\086\157\163\085\082\026\203\088\024\102\139\052\218\148\239\177\055\057\175\009\098\160\000\046\053\131\026\043\090\039\231\228\100\083\147\064\126\124\118\167\211\041\049\099\243\044\089\231\126\069\183\023\244\040\117\134\029\146\010\027\032\031\187\143\151\150\022\093\144\215\055\216\047\189\156\235\150\177\243\103\156\046\004\015\238\210\213\179\000\092\043\205\207\078\149\111\041\132\152\135\018\085\136\061\028\077\182\089\154\159\205\117\059\000\087\231\004\127\194\107\051\128\199\247\105\178\023\150\249\146\200\231\197\100\149\030\192\194\124\032\173\047\049\123\170\206\185\195\114\114\093\139\032\002\008\210\051\251\189\190\002\149\164\102\069\000\105\183\049\000\000\000\000\073\069\078\068\174\066\096\130",
["ReplicatedFirst"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\231\073\068\065\084\120\156\093\083\077\104\084\087\020\254\206\185\239\199\009\153\049\193\070\037\198\182\073\169\130\009\084\177\096\119\210\054\034\197\141\155\084\164\080\232\194\077\045\184\016\170\032\056\206\038\138\021\220\136\160\139\066\161\155\040\084\138\008\133\066\083\092\116\021\218\074\139\246\039\033\052\211\252\084\097\116\116\198\055\239\189\123\207\041\247\013\083\082\031\220\119\224\112\238\247\125\247\059\231\016\160\004\144\078\094\107\108\236\127\204\007\025\092\038\082\197\011\159\019\128\152\088\157\044\253\145\254\253\253\253\218\068\230\243\065\181\010\170\213\160\149\166\078\000\122\021\208\187\042\112\080\053\032\116\129\020\068\076\025\169\012\129\104\203\206\141\175\030\184\015\172\086\171\202\065\183\064\041\184\208\044\089\194\047\038\172\124\112\243\036\037\235\217\021\032\002\244\200\116\115\071\078\250\133\201\178\176\171\028\224\162\130\072\033\046\081\144\238\122\138\244\069\249\212\083\066\081\166\128\228\098\218\254\217\053\015\080\171\145\076\125\150\140\074\016\188\069\208\193\123\097\227\224\225\233\230\166\130\065\149\080\085\246\241\200\165\231\219\157\102\111\019\161\098\088\223\157\186\216\218\138\026\073\161\192\218\244\040\135\125\151\136\204\110\050\102\134\068\094\241\012\213\115\160\169\113\020\038\091\155\191\131\048\250\156\136\119\041\104\038\023\183\231\191\039\244\141\216\043\046\107\223\054\065\004\195\056\253\213\153\129\159\060\179\087\119\243\125\242\134\082\127\082\153\081\151\094\015\162\126\102\096\250\141\125\149\111\011\133\234\127\000\182\031\215\225\201\179\205\143\214\089\087\228\123\038\023\113\191\246\079\158\123\122\012\080\211\203\147\143\243\243\075\019\165\018\182\069\156\102\207\018\019\017\209\189\209\209\209\053\015\078\222\096\000\245\250\195\215\085\059\175\013\012\032\121\242\004\037\107\237\131\177\177\177\191\104\113\113\113\015\051\127\169\138\071\074\120\198\192\203\034\242\160\221\110\127\056\062\062\158\123\128\122\189\062\226\156\187\165\068\126\120\026\164\180\021\144\070\171\213\058\026\016\209\054\085\013\152\249\124\167\211\121\024\199\241\123\068\116\120\120\120\184\068\221\011\176\214\190\196\204\155\008\056\149\166\233\124\020\069\123\001\156\136\162\104\208\015\146\031\154\049\017\185\019\069\145\141\227\056\078\146\228\135\245\115\016\199\113\150\231\249\032\128\027\113\028\119\130\032\216\096\173\253\189\092\046\059\175\192\119\162\165\170\191\121\048\231\220\008\051\255\111\023\172\181\190\166\003\224\071\085\109\138\200\144\247\039\077\083\010\084\213\155\214\016\145\243\097\024\254\147\101\217\033\102\062\228\156\095\159\222\036\018\139\072\110\140\185\012\224\079\085\125\147\136\062\081\085\004\034\242\043\051\255\108\140\249\084\068\018\102\174\056\231\190\158\157\157\125\222\235\130\181\118\009\192\119\034\242\177\136\180\153\185\172\170\223\120\194\130\097\121\121\185\111\109\109\109\203\202\202\202\144\063\170\218\221\145\106\149\253\038\118\091\174\241\194\194\066\081\179\186\186\186\121\110\110\046\244\249\127\001\098\254\127\027\132\098\246\136\000\000\000\000\073\069\078\068\174\066\096\130",
["ReplicatedStorage"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\113\073\068\065\084\120\156\141\147\205\075\084\081\024\198\127\231\156\123\175\051\058\017\003\010\097\009\211\162\033\178\015\072\194\141\139\062\041\104\211\070\119\229\031\080\127\067\051\179\043\132\118\174\130\118\045\082\012\092\100\139\104\087\208\007\082\139\012\202\070\007\071\209\018\169\172\196\153\185\231\188\113\174\051\037\230\162\011\247\156\115\223\247\240\190\207\115\159\231\085\000\034\162\248\143\071\041\037\059\099\186\149\240\111\177\088\220\181\080\043\191\107\014\160\092\046\231\181\214\119\180\214\089\017\177\255\116\209\186\238\156\043\228\114\185\231\133\066\065\151\074\037\215\202\005\126\137\162\232\104\020\069\151\157\115\190\027\097\104\208\077\044\034\016\134\033\095\215\086\030\202\024\047\056\130\041\022\177\020\017\085\194\037\215\170\213\106\191\181\246\137\009\076\198\198\118\093\116\091\089\076\170\134\019\015\049\112\232\197\229\003\123\135\007\148\250\177\005\250\047\027\229\151\217\217\217\158\040\138\158\025\173\122\098\027\093\235\172\092\159\209\182\114\012\104\024\163\149\174\207\253\012\226\181\077\004\131\065\146\061\228\173\058\175\150\018\010\065\016\172\130\124\139\045\251\163\205\087\031\058\054\038\110\146\226\010\053\060\087\157\016\141\212\022\031\031\073\003\027\220\031\028\123\048\028\120\206\185\092\174\086\153\159\255\028\182\165\143\075\061\058\132\168\078\098\115\015\229\102\209\024\172\171\037\176\133\020\154\026\053\250\128\238\065\198\209\206\057\227\037\210\070\125\204\100\218\099\151\206\119\096\101\049\118\209\184\186\228\110\033\238\046\154\215\004\188\196\050\170\046\050\066\131\041\096\121\104\104\194\234\233\233\233\196\011\056\230\246\100\218\131\154\233\222\135\102\037\144\248\164\140\097\080\156\195\049\066\204\109\002\250\147\152\225\004\138\037\015\073\247\245\245\037\154\214\026\141\201\106\165\124\035\214\109\147\024\190\067\163\075\013\097\233\102\130\117\006\088\231\052\157\060\077\098\208\229\197\243\005\130\150\038\249\124\190\012\140\038\218\079\113\022\037\007\019\100\189\088\122\113\020\081\204\128\020\208\008\089\132\229\063\086\166\057\015\242\110\044\018\017\141\098\030\069\118\203\198\088\165\154\166\041\225\232\165\029\104\199\121\004\077\039\182\252\046\066\195\095\150\199\124\066\232\145\071\092\192\240\005\077\072\140\066\216\068\115\024\200\098\088\104\021\216\097\043\255\067\088\032\197\018\001\037\132\006\014\149\096\021\028\154\052\142\247\164\088\077\010\108\159\050\111\149\228\240\134\095\156\226\106\098\161\120\091\131\173\150\138\144\186\058\067\236\063\127\003\081\219\001\196\214\178\056\157\000\000\000\000\073\069\078\068\174\066\096\130",
["Save"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\135\073\068\065\084\120\156\045\083\093\076\028\085\024\061\223\189\119\102\119\096\119\128\178\176\005\102\041\008\212\045\132\016\064\170\177\040\052\105\045\161\169\062\232\098\140\137\038\053\245\039\013\018\013\026\211\024\023\094\140\090\163\079\062\168\177\190\106\199\054\198\088\211\198\054\053\062\136\090\163\077\075\109\164\137\109\099\011\044\184\203\239\206\254\205\220\107\102\241\038\095\238\247\112\190\147\243\125\057\135\008\128\194\255\079\129\048\005\066\023\068\044\111\126\100\074\227\144\089\212\067\012\020\236\221\104\120\233\205\217\189\023\190\141\044\045\063\119\252\196\038\148\002\017\041\246\086\050\201\148\082\172\076\096\131\013\013\131\069\111\067\011\234\090\103\036\022\140\106\109\164\221\141\172\171\079\219\047\223\218\254\249\059\127\127\048\112\162\224\067\253\097\255\103\127\118\117\145\109\219\190\016\074\032\129\225\097\200\212\175\040\085\006\205\245\222\072\183\026\174\127\064\182\007\099\136\023\162\058\129\208\188\048\066\062\216\199\151\009\058\175\037\148\013\032\153\076\146\125\222\102\231\108\043\208\191\175\095\232\034\036\194\021\022\085\085\198\192\245\048\060\022\080\071\126\059\162\157\221\115\150\035\009\066\002\101\213\226\007\076\177\205\149\005\178\167\063\113\099\239\213\191\190\161\002\007\002\086\174\088\044\201\190\149\205\117\020\068\073\119\138\069\098\130\189\125\105\254\199\087\238\153\183\156\172\087\058\150\178\083\215\018\039\019\092\012\099\074\078\191\064\242\232\139\071\031\239\222\217\053\113\209\060\095\247\203\202\012\026\141\040\210\217\085\181\198\055\152\033\116\245\111\177\216\035\165\134\071\205\199\032\011\060\099\239\180\095\059\153\056\153\022\211\211\036\007\007\007\107\070\014\030\120\249\225\221\123\235\134\104\127\225\216\031\147\236\210\202\140\224\196\201\208\130\184\147\093\036\207\037\119\162\125\210\027\013\031\228\023\156\239\159\222\028\218\060\071\068\095\248\123\136\254\254\129\039\044\107\071\143\102\006\084\124\091\187\120\119\224\184\214\109\246\209\213\165\191\240\251\194\044\214\243\057\076\238\122\067\028\142\031\014\084\069\182\161\165\163\067\011\087\152\099\150\101\053\177\241\241\100\197\232\232\200\083\177\166\230\042\006\238\221\077\045\243\182\096\059\222\191\239\067\116\135\123\017\240\066\120\190\246\085\244\108\012\225\242\149\057\044\103\050\124\135\213\042\027\027\155\070\250\250\122\030\018\142\115\123\176\166\230\080\167\105\154\144\074\082\200\008\033\235\021\016\175\142\227\227\061\159\097\173\176\134\054\253\094\228\115\037\056\165\044\002\090\000\130\115\213\212\212\108\232\186\177\159\190\249\250\171\047\107\235\173\177\106\179\202\003\192\185\224\144\082\162\228\150\016\230\097\048\048\172\185\171\144\202\131\116\129\092\046\015\215\117\177\186\154\081\055\111\221\204\136\150\150\214\134\234\218\040\042\042\012\041\061\143\151\029\194\168\236\111\087\150\224\073\137\058\138\128\020\065\122\018\121\153\067\001\005\021\015\118\120\154\046\106\068\102\037\035\027\172\086\044\046\102\176\188\156\070\048\024\216\178\025\249\197\202\141\082\170\076\216\220\216\128\153\252\069\092\197\044\158\141\062\067\057\039\167\068\058\157\070\161\088\192\149\217\057\056\078\086\109\143\214\194\117\061\112\206\192\024\209\022\129\084\080\004\131\105\248\041\243\051\078\209\041\117\127\116\183\114\214\029\018\169\212\018\247\021\063\178\239\065\047\159\207\179\112\168\082\041\063\150\091\134\167\114\075\036\125\009\140\056\038\138\227\120\082\141\161\083\219\165\078\151\078\147\248\231\206\188\254\221\153\051\008\155\097\238\100\179\240\060\069\074\201\242\033\253\128\203\045\249\229\163\248\241\011\082\000\006\025\184\225\205\209\245\027\215\189\255\000\036\185\121\185\040\057\136\034\000\000\000\000\073\069\078\068\174\066\096\130",
["Script"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\068\073\068\065\084\120\156\117\083\061\107\084\081\016\061\051\247\190\151\247\022\140\032\001\027\023\054\046\001\033\032\136\105\020\004\065\177\080\048\063\193\031\097\101\149\197\214\095\016\044\236\147\198\198\198\194\160\133\085\098\163\141\034\146\100\101\033\133\044\033\201\251\184\187\115\071\230\109\034\073\220\220\230\221\055\119\206\153\153\051\051\164\170\068\068\186\177\177\145\205\207\207\063\096\230\089\102\030\139\008\225\130\067\068\009\128\223\237\118\251\147\095\095\095\103\000\210\237\118\239\051\243\091\000\094\068\204\233\034\048\178\044\067\081\020\047\136\232\035\089\006\246\208\239\247\223\100\089\246\172\040\010\228\121\142\024\227\063\018\085\109\238\102\019\145\040\034\131\209\104\116\119\097\097\161\239\205\069\001\167\170\055\236\074\068\063\170\170\090\051\103\011\200\204\058\009\076\117\140\113\041\077\211\229\024\227\094\093\215\123\230\224\087\122\032\244\208\100\226\125\195\247\211\057\247\026\064\106\132\105\154\042\051\115\089\150\005\017\253\033\162\101\000\113\113\113\209\136\225\079\149\199\085\085\089\168\039\034\242\029\192\200\140\033\004\156\008\029\099\188\100\165\156\148\125\158\064\189\247\024\143\199\191\000\188\035\034\017\017\054\160\161\141\139\136\110\002\120\100\182\169\004\073\146\160\170\170\111\033\132\087\204\220\068\137\049\170\115\206\136\106\102\182\250\141\096\106\006\092\150\165\001\158\166\105\122\207\034\170\042\059\231\026\017\001\084\170\122\153\153\155\110\252\071\160\170\176\018\066\008\125\085\253\096\193\143\129\170\170\009\017\061\246\222\207\158\006\159\033\096\230\104\037\000\248\082\020\197\243\086\171\101\093\176\161\137\222\123\127\120\120\120\149\153\031\158\022\176\233\051\084\105\115\107\203\207\205\205\125\158\153\153\089\010\033\084\000\006\170\058\062\151\193\053\034\114\073\146\112\093\215\091\157\078\231\014\017\141\060\152\244\118\084\191\179\179\147\198\024\005\064\194\204\215\143\219\213\076\160\125\069\196\180\024\219\096\017\209\065\175\215\019\172\096\162\244\246\246\182\045\209\251\060\207\217\106\052\192\180\029\176\183\086\171\133\225\112\184\210\233\116\094\174\110\174\038\141\006\204\124\203\057\247\245\232\232\168\182\223\169\091\052\025\115\095\215\245\190\170\174\153\097\112\048\152\008\178\187\187\123\037\132\224\243\060\063\043\241\185\083\150\101\051\015\221\110\119\255\196\246\023\186\097\040\174\207\145\136\173\000\000\000\000\073\069\078\068\174\066\096\130",
["SelectChildren"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\238\073\068\065\084\120\156\125\083\077\104\084\087\020\254\206\189\239\229\037\153\025\201\012\076\209\044\082\049\016\138\161\005\065\016\017\164\218\141\160\118\163\003\046\058\136\021\020\069\176\093\088\116\161\121\207\046\234\194\210\046\106\194\084\012\130\029\146\188\108\082\074\023\226\034\082\220\248\139\032\099\098\021\173\148\170\241\047\154\152\076\102\238\187\231\200\029\077\137\069\250\193\229\114\239\057\231\158\143\243\125\151\032\066\061\097\072\081\020\177\136\080\095\095\095\183\136\168\241\241\241\091\185\092\206\132\097\040\097\024\018\016\034\138\136\001\224\228\201\056\087\147\023\029\218\218\039\132\183\024\025\025\201\076\079\079\083\177\088\156\114\231\158\158\030\213\221\221\221\136\087\042\021\058\026\069\201\214\088\116\182\130\096\009\080\143\034\074\092\140\070\071\071\189\201\201\201\207\141\049\123\000\120\068\212\095\169\084\006\162\040\106\036\204\099\103\044\185\116\029\095\105\216\079\033\114\039\128\061\254\093\177\249\038\013\014\014\174\037\162\195\034\242\187\214\122\142\153\191\032\162\083\068\116\009\064\147\039\053\097\246\212\056\175\217\033\065\254\203\084\058\104\173\206\001\207\103\120\040\177\234\107\079\041\181\138\153\239\040\165\122\011\133\066\061\142\227\077\034\242\141\136\220\002\208\105\224\255\037\064\053\175\238\110\228\230\166\086\229\229\102\131\022\106\158\170\202\103\019\179\106\177\002\240\015\017\125\008\096\121\185\092\254\072\068\218\152\185\095\041\085\002\040\015\162\017\129\119\236\017\047\189\056\205\109\168\091\004\115\172\021\131\030\164\128\089\085\173\086\207\002\184\001\160\215\243\188\083\034\114\213\024\211\027\004\193\101\017\121\000\248\215\183\109\219\114\237\030\058\014\077\188\106\250\227\225\075\101\039\094\216\219\080\250\219\021\022\119\027\083\142\227\056\199\204\107\156\124\073\146\092\042\022\139\015\007\006\006\186\136\232\087\000\187\199\198\198\046\132\056\175\246\045\059\191\012\022\142\237\051\243\009\110\252\188\146\140\231\180\039\162\231\000\126\155\151\207\169\227\251\126\098\173\181\204\044\206\035\155\075\087\244\137\237\244\039\000\183\222\064\132\156\108\226\138\218\219\219\117\087\087\151\100\050\025\103\042\243\038\046\076\228\055\204\115\230\131\206\212\254\095\100\143\006\175\181\192\109\175\073\253\240\061\209\061\207\005\093\007\000\141\068\017\209\110\055\198\016\136\052\129\172\235\164\203\181\253\153\022\062\208\150\086\169\087\085\217\048\085\229\069\123\127\146\131\142\238\059\024\030\030\110\236\206\019\004\074\105\212\079\015\014\197\231\022\235\251\007\219\090\057\213\170\077\045\219\098\069\131\055\219\180\233\104\048\088\136\066\161\208\096\002\224\009\160\119\131\108\007\091\232\025\202\164\083\236\173\178\156\232\068\060\098\178\143\053\188\153\127\255\194\066\188\029\172\044\188\219\085\150\213\089\205\063\250\026\043\045\203\223\038\193\145\218\083\061\244\222\007\230\081\042\149\252\108\054\075\249\124\158\215\175\091\151\236\237\175\125\204\172\058\161\228\241\211\251\254\149\225\136\234\255\087\255\095\094\239\105\038\244\026\058\189\107\148\217\232\209\231\000\000\000\000\073\069\078\068\174\066\096\130",
["ServerScriptService"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\092\073\068\065\084\120\156\117\147\075\108\077\081\020\134\191\181\207\185\247\182\168\138\038\036\222\137\080\033\193\072\110\031\131\098\034\006\136\164\072\196\192\035\204\069\066\136\092\070\106\100\032\066\012\068\072\013\218\161\071\036\012\024\084\007\077\012\060\058\065\136\071\005\033\241\104\238\235\156\253\203\057\061\045\245\216\147\125\246\058\235\255\215\191\254\189\182\241\191\213\215\157\167\208\188\004\115\223\217\116\241\117\022\053\064\191\167\217\164\239\082\041\160\235\030\068\173\069\188\014\035\191\026\108\020\175\107\048\229\052\027\207\086\255\036\177\137\221\080\026\046\149\028\197\119\189\076\047\236\160\018\129\004\097\000\229\250\049\054\204\237\129\097\131\126\159\230\167\064\101\224\068\114\243\212\078\020\206\067\188\132\104\057\046\060\133\104\034\023\004\212\227\199\124\251\090\100\091\127\121\002\051\161\224\214\206\233\208\112\129\092\176\153\200\023\112\124\194\235\012\216\098\114\110\031\177\140\216\127\001\206\227\024\160\240\252\046\107\239\071\191\008\110\239\061\066\099\254\020\229\084\178\200\007\009\000\034\255\202\156\045\180\048\180\180\237\208\037\049\044\242\231\090\191\205\057\056\220\125\162\238\080\201\001\235\001\143\124\148\082\214\162\049\147\204\022\072\254\163\175\085\222\249\106\101\196\143\150\223\250\106\245\125\028\215\183\012\079\027\089\133\153\066\078\156\132\182\125\099\125\037\101\012\143\153\225\125\025\069\123\183\207\095\051\176\180\113\222\130\122\181\022\017\230\200\037\196\206\185\135\229\183\207\111\038\037\072\214\141\061\187\040\132\087\112\150\074\164\016\066\185\054\210\222\180\112\221\064\199\241\067\192\058\160\158\181\028\103\215\120\213\204\122\194\148\096\104\126\047\109\035\179\137\226\253\024\211\172\022\005\034\254\176\162\101\081\011\176\217\195\020\160\002\094\014\215\004\036\131\213\055\110\162\077\012\198\245\003\115\113\154\153\139\098\171\135\181\202\096\251\209\090\113\198\178\235\049\244\004\240\012\072\156\239\002\182\154\089\231\228\209\045\165\102\078\154\046\073\179\036\189\145\052\036\233\174\164\059\146\094\100\231\252\120\146\077\034\081\201\117\171\047\072\118\073\179\037\061\149\180\091\082\135\164\181\025\120\088\082\240\223\119\036\041\085\147\001\126\072\122\036\105\080\210\131\236\124\249\175\226\127\016\152\164\156\164\075\146\170\146\202\146\106\146\098\073\159\037\181\143\023\250\055\195\216\207\228\202\087\002\013\153\121\137\209\137\236\081\224\137\153\249\036\239\039\184\088\081\144\227\129\151\208\000\000\000\000\073\069\078\068\174\066\096\130",
["ServerStorage"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\065\073\068\065\084\120\156\133\147\207\075\085\081\016\199\063\115\206\125\094\205\178\020\138\072\050\082\023\025\036\084\072\033\017\065\226\046\090\148\139\104\017\021\101\180\105\023\109\194\085\173\130\012\193\101\155\002\033\161\077\096\101\032\253\001\181\168\069\020\004\005\065\006\046\204\031\207\247\227\222\115\038\206\189\239\249\044\144\190\048\247\012\195\204\247\124\239\204\028\097\051\204\092\108\067\090\246\098\253\034\195\143\127\214\162\002\232\198\052\089\247\052\248\035\134\183\007\133\210\143\243\088\185\137\167\027\225\055\232\019\190\180\142\115\107\162\146\229\073\131\068\242\098\021\068\242\224\236\149\061\120\243\146\109\113\063\165\036\207\138\044\148\043\119\088\094\121\192\072\008\076\251\058\137\172\051\062\187\180\155\054\123\028\100\011\106\191\129\027\194\200\093\066\106\193\088\210\244\051\109\219\143\050\248\176\148\093\027\226\130\230\010\102\046\159\192\218\073\060\125\025\169\240\021\111\030\129\059\077\115\116\142\138\083\208\101\196\076\144\038\239\232\040\206\050\056\093\202\021\188\186\218\129\050\195\214\248\024\197\138\007\049\196\017\148\157\067\252\119\096\127\022\011\040\024\008\092\169\155\194\086\175\049\252\116\205\160\244\131\030\161\088\013\197\121\059\043\137\071\212\098\109\207\122\113\064\213\121\156\042\113\116\001\019\159\013\191\096\080\041\035\082\169\183\051\116\180\054\022\079\234\188\136\096\076\205\172\049\129\205\068\017\198\153\222\144\101\088\093\250\128\202\107\090\155\012\070\194\173\166\110\210\020\025\117\046\245\105\090\206\205\149\188\166\137\095\045\046\248\106\121\174\049\198\055\215\187\112\254\030\232\169\048\180\092\137\088\124\117\186\051\110\159\235\110\217\217\145\042\153\252\040\178\113\103\115\251\210\212\225\027\207\069\164\210\024\099\032\155\029\237\069\147\184\144\070\146\072\226\062\157\028\091\236\107\221\119\031\056\004\084\106\228\011\064\088\144\121\224\246\134\045\108\192\214\151\083\117\032\113\105\085\055\032\113\201\120\085\171\003\170\250\081\085\123\002\099\190\078\217\119\044\035\154\228\140\029\229\133\075\146\196\020\010\133\048\239\066\182\058\161\127\038\026\002\014\000\077\255\190\139\198\179\080\205\070\167\170\093\170\250\094\085\215\084\117\073\085\087\106\126\192\140\170\238\248\075\250\038\100\093\192\174\154\130\128\112\134\186\121\017\249\245\191\250\255\226\015\078\233\021\091\099\062\238\020\000\000\000\000\073\069\078\068\174\066\096\130",
["Service"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\252\073\068\065\084\120\156\157\083\191\171\211\080\020\062\231\222\132\082\242\218\090\005\125\041\129\012\125\226\110\039\119\055\071\221\020\065\208\217\127\064\233\032\244\015\112\210\213\065\113\241\137\032\046\014\197\229\241\112\019\028\043\201\173\098\067\165\133\164\244\198\164\201\145\019\155\146\214\130\240\190\033\135\239\220\147\239\158\095\023\096\013\034\066\056\003\176\074\130\032\056\212\090\159\183\044\043\075\146\228\031\065\252\011\109\219\182\183\241\017\017\059\105\060\030\223\204\178\236\017\000\196\204\119\051\066\044\104\070\068\231\000\224\181\235\186\003\000\200\011\111\016\004\007\113\028\015\137\232\185\105\154\199\068\084\103\005\033\132\088\151\071\108\133\016\113\154\166\087\136\232\089\150\101\247\186\221\238\103\131\015\180\214\013\086\175\213\106\031\109\219\254\245\159\178\167\074\169\159\082\202\139\076\140\242\006\033\004\165\105\106\149\037\121\158\103\003\192\045\034\058\016\066\188\115\093\247\043\135\113\034\074\041\201\023\022\089\065\101\010\069\225\136\052\153\076\046\033\226\011\203\178\158\054\155\205\001\017\189\245\060\239\042\034\230\195\225\112\211\208\045\001\006\034\022\092\107\125\163\094\175\095\095\046\151\233\098\177\136\091\173\214\017\000\220\221\055\114\001\123\128\136\178\140\173\248\138\114\119\097\084\009\017\229\108\147\036\249\000\000\039\141\070\227\026\103\026\134\225\015\041\229\203\138\024\237\021\072\211\180\220\139\239\190\239\223\137\162\232\054\055\209\048\140\055\142\227\156\174\155\072\074\169\205\104\141\181\098\209\121\211\052\053\219\126\191\047\092\215\253\006\000\079\118\050\102\245\220\247\253\172\044\019\249\051\155\205\090\097\024\126\066\196\065\020\069\199\157\078\167\062\159\207\161\221\110\111\254\100\046\132\248\157\231\249\101\041\229\043\195\048\030\056\142\115\178\089\229\209\104\116\095\074\249\144\099\075\225\173\110\011\193\124\133\136\023\000\224\253\116\058\125\220\235\245\086\091\251\174\148\058\034\162\067\041\101\182\090\109\159\049\076\211\196\060\207\023\142\227\124\169\054\178\156\192\153\158\243\031\101\003\008\160\215\089\165\236\000\000\000\000\073\069\078\068\174\066\096\130",
["Sound"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\092\073\068\065\084\120\156\149\083\059\104\084\081\016\061\051\239\238\110\178\217\104\126\054\129\128\104\036\086\186\033\187\027\021\141\157\173\088\196\066\011\011\005\127\069\136\070\178\155\004\055\105\242\033\149\088\008\018\052\130\149\041\146\070\176\019\171\252\016\193\066\196\038\040\136\172\196\221\077\204\127\223\157\145\247\140\139\228\099\240\192\189\197\048\051\247\220\051\103\128\093\160\010\210\052\120\107\060\189\067\108\027\118\042\220\002\218\179\120\161\167\249\072\062\025\191\252\165\253\068\169\002\228\049\202\117\196\163\243\169\196\085\063\015\126\030\113\145\238\139\086\231\117\026\134\250\032\185\174\120\084\068\199\005\120\092\094\106\027\008\080\034\168\101\094\103\224\094\190\059\113\155\000\073\167\065\219\168\204\039\019\231\028\194\072\056\196\117\203\027\054\167\170\045\176\164\196\136\085\013\206\062\203\118\054\159\006\203\019\235\226\082\205\240\236\091\227\021\173\038\099\135\150\065\103\012\083\173\005\238\006\028\170\094\217\016\033\034\086\023\026\112\140\117\225\222\207\036\227\153\170\193\233\087\217\084\252\101\032\128\027\004\092\227\185\182\227\021\107\068\015\035\033\103\148\153\250\003\068\213\027\174\090\038\176\138\170\178\068\246\013\076\126\100\198\211\032\211\077\239\187\070\048\046\066\071\023\083\209\003\092\017\009\085\042\081\067\193\085\117\173\172\185\170\138\223\002\249\048\012\047\066\034\246\013\128\154\124\239\217\253\171\022\159\136\021\162\230\032\163\196\155\137\010\008\242\175\185\121\061\188\251\039\214\057\092\102\004\066\000\027\098\114\121\065\129\175\225\032\059\065\227\148\048\249\202\022\155\145\128\188\009\048\209\041\040\114\117\189\083\057\113\011\245\096\085\071\245\051\087\244\077\101\161\220\182\184\106\239\184\174\029\022\193\146\113\200\017\133\199\138\217\240\082\062\217\088\047\074\215\001\026\241\199\169\116\030\138\185\242\129\233\140\081\085\034\162\247\000\188\131\092\042\049\083\016\125\020\014\112\205\074\193\218\117\075\234\176\137\144\226\065\229\192\204\068\174\039\214\040\022\023\028\131\043\062\067\085\037\244\018\225\067\043\141\097\012\023\199\096\191\119\054\182\132\156\224\168\011\169\101\107\078\086\014\077\190\243\146\243\221\077\135\069\121\066\129\231\213\253\179\067\158\184\158\196\069\051\249\150\221\180\114\166\035\030\205\118\197\110\125\027\062\086\246\199\202\249\174\166\196\143\100\172\163\232\094\095\255\191\026\252\199\050\237\141\221\214\217\139\249\047\111\226\023\224\144\028\124\219\202\077\173\000\000\000\000\073\069\078\068\174\066\096\130",
["SoundService"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\078\073\068\065\084\120\156\125\147\079\072\084\081\020\198\127\231\190\055\211\076\140\098\065\027\041\042\008\034\163\040\090\184\016\036\036\010\035\038\147\140\008\009\130\022\065\219\214\102\036\145\139\022\017\180\173\069\171\161\200\168\089\183\237\015\164\022\142\155\036\132\130\136\010\241\223\152\111\222\253\226\142\163\021\086\103\115\239\061\247\156\239\158\243\125\231\194\111\038\201\250\074\138\214\028\207\021\055\046\028\087\229\248\139\217\031\167\016\104\230\119\221\214\134\236\078\110\154\208\068\145\043\193\023\174\247\140\168\221\224\088\101\148\027\012\146\174\007\000\246\061\210\214\212\184\019\111\162\039\157\101\052\246\116\165\142\163\181\148\049\045\049\031\111\228\041\158\199\019\189\054\132\100\043\101\061\087\220\086\082\097\239\019\117\164\017\101\151\163\199\087\241\018\213\150\022\150\082\207\094\231\184\191\244\131\239\062\203\069\034\250\219\070\212\134\153\220\246\123\202\237\153\101\152\028\021\065\217\101\216\175\132\196\140\000\238\062\103\200\076\158\098\016\152\045\108\230\210\228\113\027\149\024\199\113\058\188\237\154\155\104\053\232\141\114\108\051\104\086\013\143\088\037\210\091\149\172\004\206\040\011\186\175\074\206\025\175\076\028\172\003\016\184\131\170\079\168\065\157\152\053\182\205\136\153\011\171\105\046\097\042\241\124\188\102\230\195\190\038\190\006\213\098\023\225\029\228\163\028\177\095\008\066\080\103\060\208\155\122\166\031\180\083\061\036\237\120\243\141\015\083\011\220\237\147\182\141\127\231\125\249\019\183\002\176\181\149\148\037\195\128\203\114\066\009\173\046\203\022\037\120\065\045\130\238\241\034\221\222\115\217\057\022\129\048\023\130\122\139\111\129\126\087\057\099\203\149\049\006\230\190\112\216\025\069\037\188\118\121\092\042\022\058\091\153\007\186\156\035\239\161\197\195\215\070\114\019\208\001\236\094\233\247\154\249\233\011\054\243\238\164\189\240\017\069\095\229\033\080\088\244\245\224\106\227\213\097\007\007\128\115\172\000\005\190\146\006\097\178\048\020\148\020\085\078\216\231\194\015\206\075\012\198\009\073\163\236\048\048\079\205\108\222\204\158\001\211\141\074\088\111\146\173\142\231\204\140\054\073\122\041\169\038\233\137\164\078\073\215\037\045\074\090\150\116\228\175\024\065\235\000\036\169\089\210\152\254\109\093\235\254\194\175\066\100\065\038\073\023\128\179\192\114\227\239\004\153\243\192\056\048\244\175\252\053\144\255\006\000\063\001\025\118\054\233\068\198\164\158\000\000\000\000\073\069\078\068\174\066\096\130",
["SpawnLocation"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\155\073\068\065\084\120\156\117\083\077\104\019\065\020\158\111\039\147\053\049\045\033\082\068\041\165\006\210\139\246\160\004\245\032\104\065\010\034\066\081\138\130\135\094\122\242\092\017\132\154\131\213\131\007\079\245\208\179\069\049\135\094\004\127\080\104\045\040\042\233\069\090\193\106\179\059\203\150\054\213\150\102\107\067\146\221\204\147\009\137\164\165\125\135\157\125\187\243\190\247\125\188\239\049\214\018\068\100\016\017\026\239\245\051\151\203\009\034\226\205\124\119\024\173\009\000\005\128\136\040\164\207\205\205\205\068\071\071\199\195\229\229\229\184\254\173\065\246\005\203\100\050\134\148\242\162\046\106\178\177\109\123\076\074\233\018\081\120\175\238\245\166\172\065\087\119\148\082\078\050\198\034\068\052\069\068\215\001\092\106\048\122\198\024\123\074\068\235\000\250\013\195\248\220\213\213\053\171\235\012\013\048\055\055\023\210\029\057\231\239\056\231\087\133\016\147\177\088\236\010\128\223\068\084\140\199\227\067\140\177\151\000\102\001\012\040\165\254\052\101\024\250\145\078\167\125\173\223\247\253\163\225\112\088\005\065\224\108\111\111\015\071\034\145\243\000\046\120\158\055\170\239\153\166\217\006\096\188\187\187\251\251\204\204\012\215\236\216\252\252\124\066\074\121\220\182\237\083\182\109\255\040\020\010\149\165\165\165\107\187\181\058\142\051\186\177\177\065\249\124\254\121\203\212\096\068\163\209\054\034\186\015\224\125\056\028\238\041\149\074\063\133\016\175\180\164\108\054\203\039\038\038\068\099\188\083\197\098\113\043\020\010\013\088\150\245\104\109\109\237\136\102\000\141\228\186\238\033\165\212\008\231\252\182\239\251\191\170\213\234\233\084\042\181\213\144\104\000\008\108\219\062\201\024\251\000\064\112\206\221\090\173\246\166\082\169\220\173\027\167\179\179\115\221\243\188\140\239\251\223\162\209\104\143\105\154\055\234\232\064\013\128\175\217\002\024\074\036\018\049\165\212\011\207\243\206\016\209\131\084\042\085\174\051\208\084\007\007\007\149\235\186\055\133\016\079\124\223\015\148\082\227\068\244\086\143\021\128\006\028\102\140\253\013\130\224\114\050\153\156\221\225\196\133\133\005\221\129\076\211\252\090\046\151\075\177\088\044\209\222\222\126\143\115\254\017\192\235\072\036\162\139\203\074\041\018\066\084\181\233\166\167\167\067\117\035\081\195\068\043\043\043\007\171\213\234\099\000\189\074\169\047\156\243\128\136\206\002\056\071\068\057\198\216\136\082\234\142\082\234\083\050\153\028\211\000\125\125\125\193\255\049\045\046\046\154\182\109\031\179\044\235\064\243\155\148\050\045\165\044\228\243\249\126\157\175\174\174\030\118\028\231\068\235\178\237\025\026\093\143\206\113\156\094\203\178\110\053\119\099\223\130\134\043\048\152\221\185\105\187\087\091\159\090\127\107\217\063\183\049\136\238\072\030\100\236\000\000\000\000\073\069\078\068\174\066\096\130",
["SpecialMesh"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\029\073\068\065\084\120\156\141\146\079\072\084\081\024\197\127\223\157\215\168\163\038\070\089\046\050\176\022\058\099\069\077\180\208\141\065\129\053\045\090\152\080\082\174\091\069\016\212\034\144\160\077\020\237\146\118\018\036\004\086\051\083\033\104\173\130\022\209\166\160\150\106\016\225\038\251\103\255\152\124\239\196\155\121\047\167\204\232\192\133\239\092\238\057\247\059\247\187\070\053\036\059\060\142\155\121\143\035\011\237\051\004\227\225\254\128\249\252\011\237\015\212\212\081\212\193\152\119\021\181\047\093\208\217\152\111\189\175\108\071\094\217\248\146\106\173\101\239\042\245\045\224\050\048\132\184\074\130\105\249\236\053\163\003\184\134\209\128\024\196\145\052\143\220\203\003\054\093\054\049\083\104\224\189\109\036\104\252\192\084\224\232\198\216\099\062\158\057\218\004\077\014\182\007\176\218\096\157\124\070\018\053\044\084\196\127\137\145\206\235\076\186\160\139\229\186\168\161\076\065\099\097\157\185\165\158\116\065\247\170\223\233\183\008\219\038\085\095\250\078\191\131\163\136\013\050\198\076\116\027\108\009\028\215\045\160\007\216\012\140\173\170\225\230\243\253\246\170\058\130\251\218\068\034\033\090\008\104\054\071\202\068\043\198\026\160\193\085\234\102\140\058\140\214\249\005\188\021\039\209\153\215\233\206\162\174\068\245\177\076\081\055\162\056\125\153\130\030\186\114\247\170\175\164\088\138\097\125\019\170\121\019\208\229\251\092\002\002\196\132\028\057\023\208\182\040\070\061\163\118\238\011\201\215\003\060\174\245\024\012\163\154\089\016\027\184\217\018\201\192\231\148\137\094\019\243\130\181\038\126\132\039\082\073\222\173\175\227\233\133\157\140\166\060\142\003\253\192\161\176\019\073\013\191\058\201\228\181\049\115\071\039\210\047\148\012\249\174\009\237\104\187\173\156\164\077\146\038\037\205\072\242\085\193\199\136\159\151\148\088\254\024\195\010\227\150\241\108\078\245\165\069\157\244\165\207\146\022\037\149\034\147\071\146\194\143\070\060\092\171\022\150\199\164\037\046\105\042\018\198\232\141\246\151\052\127\034\206\039\105\141\164\089\073\079\036\141\072\250\036\233\092\040\254\095\131\022\073\071\036\053\071\124\183\164\220\138\194\202\033\076\026\118\149\069\085\148\225\101\055\254\004\076\200\068\217\184\189\009\022\000\000\000\000\073\069\078\068\174\066\096\130",
["SpotLight"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\017\073\068\065\084\120\156\133\147\063\104\020\081\016\198\127\243\246\237\154\232\005\140\136\164\009\022\177\150\043\068\033\230\114\054\073\019\082\073\176\176\176\176\080\176\183\177\136\065\176\023\068\083\088\216\219\248\023\133\084\185\131\132\216\137\088\073\016\076\017\080\081\131\049\154\219\125\239\147\189\035\127\008\023\051\213\238\240\190\153\223\124\204\192\001\033\097\210\180\147\112\123\243\007\105\217\251\232\143\134\135\114\141\206\182\084\187\190\149\243\255\019\155\161\242\187\165\145\243\194\046\027\076\121\146\227\005\177\213\082\061\077\089\159\117\221\145\059\098\105\252\088\174\209\199\096\247\028\124\143\216\171\130\128\199\101\016\047\064\069\126\007\117\218\204\102\098\071\136\151\234\061\005\155\183\132\078\180\096\178\098\205\085\169\238\011\066\158\195\165\077\236\118\102\243\133\223\065\157\081\105\214\006\115\003\045\146\001\163\052\077\085\135\123\090\177\249\085\233\244\017\179\249\223\185\106\095\064\079\250\172\249\190\173\165\077\080\175\180\112\039\051\098\154\163\222\128\250\122\208\090\001\019\096\227\057\076\029\182\230\138\084\063\149\019\095\000\087\051\154\139\002\179\013\213\006\061\246\208\224\012\176\044\194\107\112\013\112\209\218\038\199\107\192\080\196\150\064\231\128\070\070\243\102\217\183\036\183\092\181\009\143\123\217\177\208\008\068\034\122\099\112\095\036\063\033\058\135\085\035\177\234\176\165\132\198\035\051\226\150\233\038\013\087\011\146\057\135\245\135\210\078\044\073\113\086\016\223\130\221\017\090\003\010\193\122\070\227\195\110\113\025\014\022\222\009\158\059\146\164\195\128\229\196\224\073\206\010\221\232\144\082\017\062\116\091\046\087\206\017\008\119\011\138\143\041\222\199\242\023\092\032\132\004\198\064\035\194\126\028\226\239\074\217\125\107\185\182\011\072\184\094\091\088\246\216\149\130\240\057\195\151\036\138\229\240\237\102\110\044\133\111\102\011\191\186\109\108\073\016\203\034\102\141\197\136\077\004\226\092\138\115\041\073\074\187\152\142\066\246\117\191\149\223\158\167\083\132\248\073\245\158\065\226\197\136\077\002\253\017\061\232\177\230\179\221\183\177\111\236\061\217\157\188\156\164\174\231\251\015\169\161\002\173\094\111\067\160\000\000\000\000\073\069\078\068\174\066\096\130",
["StarterCharacterScripts"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\076\073\068\065\084\120\156\117\147\193\075\085\065\020\198\191\115\238\204\125\190\087\230\083\169\032\201\106\041\090\139\202\077\139\022\209\095\016\212\127\144\139\182\017\180\008\124\082\224\178\016\074\136\054\109\093\180\104\017\209\166\086\045\091\004\026\015\035\048\010\133\052\077\237\061\223\187\051\243\197\220\251\158\018\234\129\115\153\225\204\124\247\119\102\190\017\000\032\039\236\250\183\254\074\255\177\016\226\028\082\017\172\096\071\198\166\218\228\164\002\053\162\086\147\188\086\155\162\008\152\143\227\082\046\062\060\157\105\246\068\069\135\125\128\003\041\073\034\026\124\248\097\141\220\145\115\083\043\056\036\072\136\113\116\035\214\218\027\072\004\073\212\141\255\033\144\024\029\207\182\091\159\054\150\238\063\237\043\245\166\091\155\219\065\052\149\163\027\203\235\114\249\121\182\075\208\172\079\094\087\197\027\136\020\136\160\068\105\021\149\192\176\041\034\075\129\076\084\196\171\209\212\103\238\067\090\218\190\043\195\143\155\177\061\211\017\082\144\154\043\010\036\126\008\194\036\073\085\141\084\035\017\003\033\169\129\207\124\025\060\246\008\064\051\223\104\186\018\007\132\243\062\004\095\244\213\061\053\017\033\020\074\050\039\214\195\054\199\142\172\053\234\051\247\061\107\181\231\125\230\230\067\179\085\039\253\034\254\044\052\114\033\000\198\057\064\247\201\016\002\069\150\181\103\112\100\236\165\148\135\042\054\009\001\078\068\140\117\040\221\027\036\231\018\017\249\213\109\032\160\163\072\004\164\214\074\214\110\213\211\147\183\102\209\123\254\025\128\043\000\118\034\177\141\107\011\242\023\228\207\007\006\030\154\150\019\155\099\116\036\080\046\001\173\070\134\158\179\039\016\194\037\040\191\198\011\043\138\024\000\180\007\192\044\112\170\109\122\172\251\210\110\241\149\170\158\009\012\089\164\055\142\022\240\159\115\050\213\101\000\211\000\086\001\120\000\035\000\038\226\092\068\092\126\146\124\063\105\214\134\126\087\006\251\006\114\043\111\052\170\166\250\247\099\003\163\115\023\000\188\006\176\000\096\171\067\112\017\064\036\024\021\145\181\220\142\251\045\090\092\017\201\113\146\117\146\055\073\094\035\121\149\228\091\146\171\036\123\255\243\116\220\180\151\115\073\145\156\230\193\049\075\050\247\066\126\011\197\235\234\130\228\143\193\147\172\002\056\014\224\029\128\232\253\088\136\217\002\048\035\034\097\087\160\064\238\060\215\189\136\061\223\238\026\230\016\179\241\031\100\035\059\060\082\140\226\192\000\000\000\000\073\069\078\068\174\066\096\130",
["StarterPlayer"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\042\073\068\065\084\120\156\125\146\189\107\020\081\020\197\127\247\206\155\217\100\073\098\018\237\036\017\065\003\162\133\133\098\043\034\164\086\240\095\016\177\019\027\027\217\093\020\045\181\177\201\127\160\066\026\193\148\166\181\208\086\069\016\130\129\068\069\243\225\038\155\236\204\123\087\222\204\238\250\145\196\083\012\051\115\239\057\239\188\123\174\000\152\093\079\215\062\077\212\039\198\066\136\223\072\093\088\101\071\206\180\186\102\013\133\166\208\108\090\089\107\182\076\132\234\061\182\218\199\123\083\185\230\143\085\116\218\007\010\204\036\073\068\131\015\203\169\147\155\114\188\181\202\001\048\067\092\097\197\169\052\077\175\146\008\073\212\149\088\129\196\233\249\188\189\251\118\125\233\206\147\067\181\209\236\231\102\059\136\102\050\178\190\178\038\231\230\242\129\131\206\135\198\101\085\094\034\018\169\145\045\081\090\069\037\088\216\020\145\165\096\150\168\136\087\167\153\207\139\197\172\214\190\045\211\143\058\241\122\174\039\164\152\105\169\040\072\124\024\134\115\201\184\058\029\143\142\204\007\036\115\132\220\015\099\099\247\129\078\236\119\206\065\111\116\123\080\020\222\240\177\026\213\053\182\198\043\006\036\239\185\133\190\131\125\033\037\072\156\075\233\118\119\151\253\182\223\054\179\021\066\125\112\164\043\010\080\253\175\140\239\118\059\015\101\228\244\139\080\155\026\206\124\167\205\145\217\047\085\173\101\125\007\001\145\050\091\139\067\172\134\025\178\161\076\187\091\091\243\217\204\131\231\192\028\112\018\248\006\118\011\100\033\014\220\225\209\108\056\073\075\027\253\024\035\124\072\024\029\194\182\215\222\000\179\192\005\008\057\232\036\112\013\088\128\038\110\040\045\222\117\119\109\094\085\143\005\139\013\131\056\067\182\181\091\083\175\027\192\215\210\037\154\246\228\223\155\085\078\165\108\125\213\112\223\143\254\168\031\062\052\249\119\030\027\168\204\180\054\205\044\018\175\000\039\128\021\096\094\068\162\048\018\215\241\207\221\254\023\102\118\017\184\001\140\002\025\016\183\112\007\120\010\060\115\145\028\069\170\001\244\209\028\228\012\225\046\232\165\125\180\207\002\139\213\110\148\014\126\115\074\069\017\051\043\083\122\029\119\170\119\106\012\060\158\020\157\124\174\168\123\061\151\255\026\205\074\177\213\146\003\246\180\194\047\007\042\234\059\102\114\028\123\000\000\000\000\073\069\078\068\174\066\096\130",
["StarterPlayerScripts"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\074\073\068\065\084\120\156\125\147\063\079\084\081\016\197\127\115\239\123\111\093\022\001\053\177\088\013\184\133\049\196\198\194\206\136\031\192\088\098\098\111\129\165\141\022\154\236\018\197\150\066\027\109\236\077\136\157\009\133\026\077\076\140\159\128\006\140\005\032\024\032\033\011\044\239\207\029\051\111\031\068\013\056\201\205\155\220\055\247\220\115\206\204\021\000\109\183\221\214\173\213\147\167\198\134\195\198\214\128\156\217\238\201\010\091\217\185\171\175\118\237\031\157\142\210\233\136\213\090\046\034\090\230\128\168\222\175\167\139\067\051\081\228\175\231\121\200\065\005\197\033\244\196\103\015\146\214\179\175\252\019\170\136\088\085\009\240\189\125\033\205\245\083\050\210\024\165\151\130\019\008\010\141\026\233\230\206\092\082\103\170\219\075\253\096\157\208\221\195\013\198\189\109\025\157\221\059\100\176\183\240\168\229\188\127\151\212\226\139\105\154\007\192\217\021\206\009\033\144\138\232\018\138\237\219\181\145\034\063\226\036\186\043\163\143\151\085\085\162\010\200\001\030\053\121\226\048\126\010\222\073\221\071\254\242\159\220\017\055\158\237\103\099\192\050\116\196\014\030\027\069\008\033\047\073\153\127\149\232\146\138\019\187\221\210\232\127\000\073\045\118\233\126\246\043\219\207\215\016\245\168\051\180\072\139\205\109\235\132\017\138\142\058\168\104\136\147\216\165\189\253\121\169\055\059\012\092\241\208\003\106\010\133\104\099\060\083\125\209\004\126\030\000\024\114\129\136\249\175\078\028\089\154\237\074\028\079\199\231\239\221\009\048\229\192\156\055\201\125\163\225\051\048\021\157\168\069\154\229\212\169\199\062\049\035\173\141\222\145\117\247\034\226\150\233\156\112\020\235\033\200\138\115\120\002\009\206\153\137\175\129\181\104\101\099\117\253\236\072\115\142\110\122\035\047\138\052\096\029\020\175\034\059\136\024\239\029\240\111\157\227\139\105\192\017\003\079\129\045\017\201\074\039\085\219\142\133\221\006\167\007\250\070\187\001\033\093\044\104\190\172\001\243\080\030\090\170\218\209\002\198\129\155\034\242\190\028\203\227\186\160\170\195\170\250\077\085\031\170\234\068\181\158\171\106\161\170\215\014\138\196\064\250\223\131\245\049\170\242\219\122\116\024\232\208\225\028\244\031\198\095\068\242\106\080\046\001\031\128\221\202\121\147\104\178\102\069\100\187\028\101\065\104\219\147\173\098\122\122\218\138\014\134\110\070\068\158\028\037\111\242\205\164\023\036\252\006\173\114\047\138\056\182\007\005\000\000\000\000\073\069\078\068\174\066\096\130",
["StringValue"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\162\073\068\065\084\120\156\181\083\077\139\019\065\016\173\087\189\172\113\017\069\204\030\115\017\018\188\122\090\088\246\226\065\253\013\030\252\017\130\103\103\002\254\013\143\094\189\237\217\139\122\145\021\081\240\035\018\210\051\038\144\096\024\118\205\165\051\203\244\147\078\038\217\108\152\241\034\022\052\069\117\189\042\222\171\234\022\169\049\146\008\167\046\254\191\070\018\147\201\228\090\150\101\055\086\119\073\146\220\028\141\070\123\219\088\173\040\054\000\232\156\123\058\155\205\158\068\081\164\105\154\094\037\249\034\207\243\007\165\020\173\109\000\160\040\027\221\243\222\159\119\187\093\239\156\187\165\170\119\001\252\010\205\227\056\190\192\203\006\237\144\180\214\062\006\240\072\068\014\188\247\086\085\191\146\220\007\112\032\034\039\170\250\188\213\106\189\094\225\117\155\128\049\102\040\034\167\034\114\174\170\111\072\126\043\041\159\122\239\223\003\008\185\106\139\162\104\039\248\126\191\127\127\048\024\156\076\167\211\235\229\000\187\214\218\151\085\053\186\185\219\056\142\023\250\141\049\135\000\070\205\102\243\119\041\239\014\201\254\106\200\151\040\115\073\047\008\226\120\060\190\237\156\123\038\034\071\000\118\072\190\037\185\171\170\071\034\050\019\145\087\243\249\060\234\116\058\243\075\091\000\150\036\178\044\059\035\249\073\068\118\001\124\084\213\015\198\152\159\036\061\128\099\017\249\210\110\183\139\237\189\107\169\127\225\123\189\222\149\036\073\062\167\105\250\048\196\195\225\240\208\090\251\035\220\087\206\064\046\244\051\248\070\163\209\020\145\119\069\081\124\015\122\139\162\216\083\213\227\060\207\185\249\128\086\171\095\051\168\098\181\006\213\216\002\247\047\063\172\182\118\157\088\082\252\235\055\254\003\060\187\004\107\100\181\082\170\000\000\000\000\073\069\078\068\174\066\096\130",
["SurfaceLight"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\245\073\068\065\084\120\156\125\146\049\107\020\097\016\134\159\119\118\247\046\119\049\018\017\036\032\006\177\077\109\016\193\004\020\036\133\157\130\149\063\064\241\007\216\197\160\141\255\192\210\082\208\074\075\211\004\082\004\036\149\160\109\138\096\037\068\067\226\121\247\237\126\035\223\222\109\220\035\193\129\101\249\102\222\153\121\103\230\021\045\115\071\176\154\149\248\093\225\023\192\171\113\036\019\080\030\081\109\206\107\251\032\225\036\060\069\212\078\078\206\161\175\188\016\254\208\224\091\068\029\195\137\048\050\236\074\069\220\235\048\243\072\250\116\220\046\130\251\186\165\127\240\091\247\131\175\236\014\252\206\181\054\179\166\193\200\087\062\006\095\125\153\240\077\142\214\029\219\016\209\125\249\124\160\187\005\218\021\122\011\222\079\121\009\084\097\150\081\014\029\091\002\127\054\036\220\158\211\206\023\119\076\013\021\247\027\189\017\197\043\131\155\137\012\168\238\208\152\032\058\158\057\250\094\160\167\210\214\126\202\205\079\230\224\176\130\133\055\142\191\135\178\132\168\169\017\128\130\156\128\011\194\175\198\159\255\131\044\074\028\245\148\112\100\070\013\156\182\146\136\136\246\147\034\059\163\064\050\139\105\093\142\078\103\215\044\078\251\243\051\112\168\238\030\167\118\048\182\108\162\139\255\022\112\057\054\170\015\135\171\064\245\142\066\045\038\047\198\163\233\116\129\061\006\186\060\233\226\132\197\012\117\043\212\072\017\039\184\097\251\032\159\063\139\193\085\134\026\209\029\056\241\158\208\147\008\121\058\080\028\015\229\025\102\014\031\028\127\221\102\096\117\117\071\207\217\025\102\104\201\208\227\028\155\007\205\010\157\027\127\204\001\233\253\064\104\013\122\131\147\125\053\066\250\225\203\231\231\232\109\118\200\175\167\131\181\187\180\215\027\168\142\035\113\121\070\219\095\147\156\079\070\184\136\133\146\242\115\132\217\010\015\154\176\131\088\139\072\088\116\170\142\097\123\129\209\225\056\182\049\125\086\247\181\238\128\227\075\078\017\251\252\153\040\180\207\111\162\250\164\021\012\051\088\056\144\222\029\053\057\127\001\108\035\222\018\050\011\026\164\000\000\000\000\073\069\078\068\174\066\096\130",
["Team"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\155\073\068\065\084\120\156\141\083\207\107\083\065\016\158\153\125\155\068\159\214\010\073\047\053\105\066\164\030\069\011\181\010\074\207\122\240\168\254\001\130\120\241\234\143\067\245\168\120\241\032\042\232\165\066\193\196\147\222\004\081\060\168\135\162\040\162\053\193\214\038\045\074\168\162\198\247\210\052\217\249\100\107\011\057\168\056\176\187\195\238\204\236\055\051\223\048\245\072\181\090\221\110\140\217\101\173\173\100\179\217\087\244\031\034\000\216\043\000\018\214\218\203\125\125\125\037\085\157\090\092\092\076\175\221\175\190\255\073\128\009\145\117\163\165\165\165\036\051\015\135\097\072\170\186\035\138\162\045\189\206\000\100\125\245\006\009\252\198\204\032\162\230\252\252\252\165\102\179\121\136\136\094\014\015\015\127\088\179\089\013\194\204\250\039\020\236\183\122\189\190\199\057\119\150\153\059\206\057\019\004\065\071\085\055\059\231\110\021\139\197\187\149\074\037\105\173\061\039\034\251\001\076\013\013\013\221\252\237\126\158\185\084\042\153\209\209\209\041\034\218\155\076\038\179\171\133\017\161\229\229\229\079\068\052\079\068\007\157\115\125\034\082\025\024\024\072\052\026\141\055\097\024\238\075\167\211\063\137\202\034\099\099\099\009\000\134\136\110\183\219\109\109\183\219\221\149\149\021\000\184\007\160\017\004\193\230\066\161\240\153\136\222\069\081\020\049\243\076\038\147\105\254\078\187\076\146\205\102\187\030\058\051\039\125\074\198\152\128\153\125\106\041\102\110\019\209\198\217\217\217\157\000\110\196\113\124\221\007\174\086\171\187\001\088\162\146\138\119\022\145\107\204\220\016\017\086\213\135\221\110\183\037\034\112\206\093\237\116\058\103\140\049\143\068\228\002\128\035\000\174\036\018\137\199\245\122\253\148\071\033\000\130\092\046\247\196\057\183\096\140\241\149\126\225\127\006\240\165\080\040\060\003\080\100\230\039\214\218\076\016\004\219\140\049\091\137\232\129\170\030\192\220\092\202\247\148\215\250\157\072\165\082\162\170\222\096\147\170\038\106\181\090\040\034\223\000\124\084\085\116\187\093\168\087\128\025\102\094\161\188\097\207\003\245\080\022\022\022\158\182\090\173\147\204\252\026\192\115\107\237\219\084\042\229\162\040\242\198\003\206\057\095\216\239\204\220\207\204\022\192\123\145\124\235\175\052\245\050\061\061\109\243\249\252\134\056\142\047\170\234\081\034\186\099\140\057\238\156\059\225\156\043\077\078\078\054\123\105\201\019\019\019\171\179\177\126\142\140\140\032\157\078\255\240\076\102\230\208\163\013\195\208\167\217\046\022\139\223\199\199\199\229\159\008\214\248\161\181\090\237\044\128\195\068\116\063\008\130\099\206\185\211\185\092\238\126\185\092\254\071\128\158\065\122\093\171\245\219\056\222\144\201\100\126\182\090\045\207\202\175\131\131\131\177\071\253\011\063\137\103\088\150\079\106\062\000\000\000\000\073\069\078\068\174\066\096\130",
["Teams"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\098\073\068\065\084\120\156\125\146\187\107\084\065\020\198\127\103\238\220\155\205\134\024\018\055\186\006\017\052\026\035\104\161\133\166\079\225\003\133\052\146\206\206\206\224\159\176\187\069\064\027\045\005\091\017\049\104\097\033\164\086\177\176\176\145\160\228\129\065\137\016\140\154\135\027\115\095\115\100\110\054\018\227\227\192\048\103\152\243\248\190\239\028\153\152\184\028\140\156\028\060\045\162\251\114\037\011\000\068\002\077\221\098\116\108\252\165\106\205\240\155\213\085\068\116\235\037\241\076\237\020\162\147\145\181\189\105\234\084\004\009\002\033\205\243\175\034\114\062\234\111\188\226\063\102\093\230\122\141\053\149\036\205\115\080\081\005\151\225\162\054\219\019\199\217\245\245\119\181\059\098\092\059\014\135\113\030\224\092\251\192\248\220\047\004\233\108\099\216\105\062\009\210\066\143\248\091\085\053\008\002\049\034\222\199\057\197\150\067\146\102\252\188\105\226\075\061\253\055\087\180\086\051\022\113\130\007\190\195\068\068\114\151\187\092\011\191\168\065\154\251\184\190\238\168\212\009\172\248\056\243\047\110\170\234\160\016\203\159\032\012\131\144\082\100\065\108\065\103\075\003\254\158\238\162\200\026\066\255\173\036\235\009\089\018\191\214\164\217\132\224\051\046\220\044\080\175\171\205\050\048\091\056\090\068\194\208\154\036\078\223\179\017\207\099\164\044\232\189\176\239\202\011\058\014\084\072\191\047\019\086\022\161\129\151\203\102\064\004\174\072\086\037\008\173\073\147\248\033\093\039\110\068\061\195\221\027\075\179\243\165\234\208\110\224\017\176\159\176\180\012\140\249\183\162\098\172\096\162\048\240\077\131\168\189\045\200\178\116\045\108\219\123\059\218\051\122\013\091\121\090\170\014\157\003\134\129\195\094\011\160\010\092\040\024\080\199\150\100\237\109\154\116\062\065\056\036\121\038\056\055\067\245\172\255\031\001\202\224\142\131\062\131\192\243\014\091\100\167\085\181\032\110\229\200\173\143\058\061\054\074\212\087\094\089\219\144\174\170\205\036\058\186\170\170\119\129\081\048\139\034\050\161\170\062\121\000\088\000\238\139\136\083\085\063\096\063\230\098\084\219\071\056\008\156\001\166\240\250\192\085\096\023\080\002\098\160\009\060\022\145\201\205\004\063\112\173\025\095\076\245\199\065\085\093\240\155\168\170\023\085\245\065\203\223\105\083\170\090\041\246\064\010\253\235\136\052\084\181\228\187\172\002\159\128\047\192\018\240\006\072\090\034\122\068\062\239\131\031\224\031\043\220\226\218\219\010\252\006\116\180\078\190\045\204\011\152\250\006\063\001\220\213\037\065\123\105\022\034\000\000\000\000\073\069\078\068\174\066\096\130",
["TeleportTo"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\107\073\068\065\084\120\156\109\147\111\104\091\085\024\198\159\247\156\115\111\211\036\055\077\155\038\105\089\102\247\199\086\169\165\022\203\168\116\216\084\167\211\077\191\217\204\127\236\195\112\032\008\194\016\038\012\209\088\024\138\160\095\133\042\236\131\027\184\025\054\217\134\091\059\104\164\234\232\116\077\176\105\215\110\058\076\093\211\184\181\180\077\187\230\207\077\238\189\071\110\088\253\162\207\135\243\124\120\207\057\060\047\060\063\096\083\017\112\219\118\189\141\166\142\087\217\165\064\015\222\005\224\032\034\132\163\016\000\008\255\035\010\135\171\067\212\118\130\247\052\160\242\229\223\008\237\244\056\071\131\158\135\234\254\152\206\156\074\141\110\124\070\203\148\029\248\086\242\216\001\072\000\214\127\127\001\065\074\073\012\012\174\103\092\193\253\031\109\077\095\190\241\149\252\224\228\107\102\215\033\103\028\173\120\220\190\037\037\104\051\233\166\196\011\135\030\246\015\103\111\011\234\035\129\030\148\243\171\249\096\190\224\038\143\195\039\095\010\191\110\120\027\180\167\189\117\023\078\077\196\239\070\137\186\047\074\153\048\232\000\056\098\213\036\082\024\222\210\240\147\245\078\151\171\070\179\087\049\242\037\093\212\185\124\001\093\047\032\147\075\139\182\150\014\243\205\129\080\135\207\115\230\139\100\040\217\069\013\248\156\114\180\246\097\084\178\193\065\128\158\123\047\104\189\188\239\013\218\022\104\071\081\223\000\231\002\053\204\045\085\085\193\228\221\081\146\082\202\045\245\173\146\153\042\251\097\252\114\229\231\095\198\207\077\142\020\142\225\030\210\144\032\081\052\245\201\070\079\168\115\181\178\080\089\218\200\112\151\170\193\176\012\081\054\075\144\100\193\132\078\233\092\146\026\092\205\214\158\190\125\220\023\240\189\226\168\185\018\202\038\074\199\118\244\151\198\133\097\065\223\040\044\179\249\124\138\223\089\185\041\004\083\065\156\160\185\188\112\215\122\160\010\021\018\006\050\235\051\108\089\204\091\143\180\117\154\141\094\255\238\139\218\119\039\102\039\178\159\008\098\224\185\210\034\210\171\055\177\176\154\134\067\081\192\004\176\106\010\212\148\021\040\138\002\085\113\128\036\160\086\220\228\211\154\044\166\112\072\105\121\201\066\157\032\034\019\068\146\113\197\100\188\134\020\213\065\092\053\025\113\019\038\211\097\177\034\202\114\013\001\215\118\171\085\235\149\115\127\222\017\063\198\175\221\202\252\086\124\095\227\024\017\166\089\086\001\073\189\045\047\138\251\141\057\046\020\142\218\090\039\012\042\200\107\139\103\136\171\006\118\054\118\091\126\122\148\146\019\211\044\249\235\212\216\245\159\214\142\026\055\112\189\218\003\067\215\151\046\141\157\095\119\168\110\195\046\084\169\172\051\127\125\147\243\217\254\062\197\093\235\145\219\124\143\089\154\177\149\095\025\025\203\167\018\191\127\051\059\109\030\199\044\253\021\141\074\049\051\003\073\109\135\177\125\109\013\254\149\002\076\085\160\156\095\135\191\247\009\237\235\183\014\030\222\002\103\185\050\063\159\081\174\198\019\217\137\120\230\227\165\091\056\137\021\090\143\068\036\111\095\004\161\031\022\022\046\044\056\171\101\038\155\021\006\236\210\124\207\071\131\183\079\036\142\200\163\167\247\154\187\223\241\076\057\187\177\023\136\112\027\167\200\131\042\219\030\005\152\056\059\119\182\021\081\057\053\176\212\238\108\247\207\020\078\207\221\215\010\197\138\227\251\225\243\149\244\236\189\115\083\169\194\241\074\138\166\033\099\246\134\060\022\131\185\201\193\160\125\012\013\013\053\219\030\141\134\171\084\062\117\004\205\093\007\089\188\101\015\062\197\014\004\236\087\015\112\102\118\074\027\186\127\025\004\232\031\137\046\101\199\011\203\111\168\000\000\000\000\073\069\078\068\174\066\096\130",
["Terrain"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\087\073\068\065\084\120\156\141\147\077\072\085\065\020\199\127\243\113\239\123\207\242\229\166\018\090\181\136\202\069\171\118\006\098\217\034\108\021\060\136\176\015\063\018\090\212\166\160\141\240\122\184\139\022\066\084\020\182\040\136\192\010\004\083\017\250\032\145\086\181\179\040\003\161\232\019\161\210\133\190\251\222\220\057\113\175\041\106\046\058\139\153\051\103\206\127\230\204\249\255\007\254\199\004\181\038\178\188\086\255\038\022\021\148\018\079\210\253\165\113\184\099\047\161\169\195\086\038\104\190\083\078\115\021\162\087\129\147\068\085\242\233\092\044\106\006\010\058\245\199\186\186\177\230\041\168\017\034\123\139\145\179\153\165\002\236\042\240\221\182\013\108\205\238\162\058\063\205\225\210\175\116\111\176\099\039\066\047\070\229\137\125\076\104\143\019\205\143\163\232\079\046\081\136\040\148\018\134\078\108\035\008\111\130\106\004\121\131\231\002\185\112\146\168\124\003\107\219\136\061\104\157\060\199\083\113\239\089\136\014\112\228\222\247\052\194\171\238\000\027\092\161\038\104\005\169\035\099\026\081\060\034\138\158\225\213\177\180\083\094\190\226\253\059\156\215\100\195\221\228\178\167\147\170\085\090\230\104\231\057\172\233\035\246\014\084\000\018\163\148\193\040\080\010\042\241\008\085\125\158\128\089\112\157\004\182\023\023\127\066\199\045\138\199\039\235\049\102\140\108\184\135\106\012\222\207\161\117\030\145\004\028\035\242\019\157\217\199\193\107\083\203\013\031\110\191\079\046\060\074\089\090\052\134\044\090\215\080\113\014\241\023\081\110\063\177\156\193\251\031\100\172\193\235\171\041\120\160\096\144\130\089\236\125\220\067\020\079\099\189\181\216\140\199\197\009\157\125\028\186\125\249\239\029\175\025\105\159\100\161\178\131\090\121\152\070\010\015\018\122\023\045\183\253\035\209\231\015\120\021\088\034\099\049\126\134\104\161\159\231\077\150\205\091\052\051\013\158\230\210\004\048\145\082\044\069\205\037\096\224\173\162\208\032\012\125\011\201\096\208\090\022\117\000\142\012\115\052\191\112\255\200\056\213\098\041\209\227\074\155\103\180\043\201\213\150\160\042\120\201\163\107\154\120\210\061\133\139\109\218\188\245\204\121\133\009\170\040\183\017\047\245\184\184\108\153\157\253\066\109\126\012\241\061\056\053\135\040\003\226\215\061\032\161\085\156\071\084\014\097\028\091\126\153\176\140\036\106\028\060\181\137\170\093\252\027\249\117\225\043\042\009\133\214\235\191\083\005\175\126\238\106\127\189\245\154\127\173\254\000\113\137\240\101\042\220\174\006\000\000\000\000\073\069\078\068\174\066\096\130",
["Texture"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\130\073\068\065\084\120\156\077\147\203\138\093\069\020\134\191\085\151\125\046\137\118\018\162\032\024\112\160\068\067\146\129\157\128\111\032\100\034\161\017\004\167\130\056\243\005\156\058\022\028\057\023\196\064\164\099\196\007\112\026\115\027\228\162\036\131\120\193\129\210\208\125\250\156\062\123\239\170\250\165\202\110\076\013\215\090\197\250\111\203\056\124\103\191\209\107\221\140\201\088\080\116\088\041\056\158\123\121\066\166\135\090\119\198\238\227\045\251\171\214\013\100\231\182\249\212\034\159\040\019\016\206\196\032\227\111\212\254\202\140\128\241\050\194\090\201\088\072\124\246\232\061\187\097\231\183\117\169\024\063\249\009\179\050\128\159\065\094\113\207\117\124\080\214\172\124\161\079\112\158\192\077\023\153\043\131\159\067\222\231\110\223\243\110\072\142\083\078\116\185\103\172\112\148\241\130\133\057\254\120\112\213\150\141\222\182\254\244\112\160\196\196\068\206\107\156\196\177\153\227\133\096\144\027\042\071\084\065\120\204\010\221\241\223\255\215\032\004\028\153\014\135\175\011\204\131\018\088\068\065\149\051\012\202\236\097\100\245\076\113\044\246\095\226\244\197\235\154\013\070\206\003\039\156\227\031\018\061\198\160\145\057\080\214\061\004\015\019\196\109\193\199\089\100\159\160\120\206\102\113\029\207\049\031\170\005\252\086\006\182\052\103\105\007\200\034\103\012\062\159\056\172\182\171\216\171\135\087\237\225\161\234\156\251\078\027\242\188\233\034\051\235\160\044\097\190\195\047\183\223\183\085\237\095\248\081\007\057\145\153\114\200\211\096\243\150\226\017\103\007\030\072\085\241\202\085\144\253\025\218\178\054\238\137\213\210\166\015\181\032\194\248\140\147\155\223\171\012\011\114\246\204\076\236\020\049\090\198\204\216\091\172\056\249\206\053\133\131\072\025\087\108\180\213\107\008\217\024\028\188\157\002\063\100\040\118\130\104\137\167\036\062\148\103\173\017\188\227\021\023\249\122\033\230\050\070\115\028\167\096\125\065\071\054\110\248\142\203\071\033\025\247\040\195\156\159\159\092\177\190\034\124\235\166\222\176\194\037\063\101\090\167\171\046\105\201\175\207\219\152\242\208\184\138\190\133\100\189\177\095\037\170\233\111\080\059\058\150\121\032\056\213\115\192\097\072\134\085\027\087\002\103\014\079\038\025\004\051\252\046\116\175\094\211\108\090\193\046\233\000\095\111\162\136\228\035\161\036\178\075\172\195\110\207\157\023\003\095\154\231\035\025\190\012\020\131\215\187\009\223\078\234\150\145\066\108\193\137\237\030\107\222\007\118\036\190\168\023\217\172\224\043\197\011\167\217\044\142\169\139\148\146\240\184\246\225\191\190\154\105\131\009\201\181\088\239\060\216\178\251\181\245\047\185\109\056\244\019\144\035\033\000\000\000\000\073\069\078\068\174\066\096\130",
["Ungroup"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\078\073\068\065\084\120\156\069\147\079\104\092\085\020\198\191\115\238\125\239\205\228\077\038\177\109\140\165\077\009\077\180\139\004\036\093\148\008\085\004\139\010\034\254\129\128\022\173\160\210\236\004\027\087\138\076\179\105\049\069\097\112\213\146\130\082\020\073\022\130\011\169\056\093\088\033\020\034\042\173\182\141\141\029\146\209\054\233\159\100\050\153\206\204\123\239\222\123\228\037\001\015\028\206\234\240\251\206\253\190\075\175\159\042\159\131\224\069\098\123\226\235\015\250\039\176\085\004\192\137\048\017\185\183\079\205\015\070\224\031\068\080\037\015\175\126\245\254\222\185\066\065\184\175\239\092\150\094\155\184\185\166\189\076\222\153\230\204\092\117\251\145\142\108\071\203\038\085\175\102\002\201\001\046\214\089\181\083\047\188\145\245\237\135\196\016\007\030\219\087\239\157\028\031\039\083\044\158\217\173\005\246\091\103\147\231\218\219\059\015\060\211\147\043\137\056\039\174\157\083\009\078\224\192\078\197\173\174\237\107\171\043\089\147\068\151\153\112\041\093\030\153\018\181\019\199\238\211\209\211\167\189\133\187\035\207\030\028\204\127\051\114\080\229\126\159\107\064\105\133\199\251\003\136\000\154\128\122\012\124\089\074\110\094\093\092\121\229\252\071\143\092\126\179\248\207\144\141\205\147\004\191\196\103\070\071\019\242\031\170\056\007\115\189\188\102\190\191\180\020\149\102\151\204\173\229\134\105\243\097\058\067\180\050\010\002\165\146\243\011\221\011\071\062\157\219\149\068\241\036\049\127\226\208\060\171\001\033\207\161\205\008\184\090\135\090\111\024\213\136\153\102\255\022\044\213\001\095\131\091\009\008\214\117\143\061\197\239\138\234\009\238\222\186\055\224\196\005\036\200\105\128\100\245\065\044\190\098\060\049\016\194\211\221\050\191\204\020\004\217\141\019\226\068\056\117\100\168\079\231\153\221\113\065\032\139\109\093\122\190\178\254\099\163\086\255\088\139\008\029\058\009\103\172\149\048\171\049\244\088\007\012\003\097\006\024\236\001\152\083\056\064\004\102\112\104\005\068\226\199\213\198\182\159\039\126\234\250\037\245\089\028\193\017\017\020\224\066\031\086\107\136\098\065\224\003\025\111\179\125\013\100\124\088\197\016\086\176\105\076\134\135\225\243\232\201\223\122\067\083\121\193\058\155\113\002\213\074\156\134\021\114\002\088\011\152\173\078\085\024\011\118\002\194\134\010\080\080\131\232\186\238\156\110\087\230\209\127\111\223\243\038\075\015\175\196\022\156\010\217\191\151\189\084\149\164\169\164\255\227\073\128\056\017\109\161\226\167\113\188\141\005\178\203\243\252\142\230\131\214\175\023\175\068\207\207\092\083\135\098\203\095\128\096\082\153\076\112\155\076\164\175\153\206\148\000\229\035\202\231\107\096\056\115\212\036\173\019\236\243\232\133\066\056\059\216\113\227\070\046\131\165\020\190\005\150\212\141\052\196\155\019\080\172\018\118\073\240\093\045\095\163\130\020\248\234\103\239\004\211\099\123\154\111\021\043\195\173\086\084\012\195\176\127\255\190\029\219\118\239\072\077\114\072\153\027\169\078\063\131\056\249\179\092\163\235\229\213\133\196\208\231\186\231\108\079\056\062\182\103\125\164\240\071\046\137\204\203\158\023\028\104\053\155\114\173\092\191\184\188\150\187\178\177\044\142\156\115\042\240\185\017\039\081\184\088\089\061\076\058\219\171\093\227\061\157\207\231\163\169\169\041\053\141\129\038\045\150\103\172\049\119\000\185\125\231\126\237\088\101\181\243\047\182\053\191\017\229\197\111\103\102\139\072\076\173\045\171\037\240\036\126\073\020\093\248\015\123\014\175\152\021\230\193\141\000\000\000\000\073\069\078\068\174\066\096\130",
["Vector3Value"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\001\162\073\068\065\084\120\156\181\083\077\139\019\065\016\173\087\189\172\113\017\069\204\030\115\017\018\188\122\090\088\246\226\065\253\013\030\252\017\130\103\103\002\254\013\143\094\189\237\217\139\122\145\021\081\240\035\018\210\051\038\144\096\024\118\205\165\051\203\244\147\078\038\217\108\152\241\034\022\052\069\117\189\042\222\171\234\022\169\049\146\008\167\046\254\191\070\018\147\201\228\090\150\101\055\086\119\073\146\220\028\141\070\123\219\088\173\040\054\000\232\156\123\058\155\205\158\068\081\164\105\154\094\037\249\034\207\243\007\165\020\173\109\000\160\040\027\221\243\222\159\119\187\093\239\156\187\165\170\119\001\252\010\205\227\056\190\192\203\006\237\144\180\214\062\006\240\072\068\014\188\247\086\085\191\146\220\007\112\032\034\039\170\250\188\213\106\189\094\225\117\155\128\049\102\040\034\167\034\114\174\170\111\072\126\043\041\159\122\239\223\003\008\185\106\139\162\104\039\248\126\191\127\127\048\024\156\076\167\211\235\229\000\187\214\218\151\085\053\186\185\219\056\142\023\250\141\049\135\000\070\205\102\243\119\041\239\014\201\254\106\200\151\040\115\073\047\008\226\120\060\190\237\156\123\038\034\071\000\118\072\190\037\185\171\170\071\034\050\019\145\087\243\249\060\234\116\058\243\075\091\000\150\036\178\044\059\035\249\073\068\118\001\124\084\213\015\198\152\159\036\061\128\099\017\249\210\110\183\139\237\189\107\169\127\225\123\189\222\149\036\073\062\167\105\250\048\196\195\225\240\208\090\251\035\220\087\206\064\046\244\051\248\070\163\209\020\145\119\069\081\124\015\122\139\162\216\083\213\227\060\207\185\249\128\086\171\095\051\168\098\181\006\213\216\002\247\047\063\172\182\118\157\088\082\252\235\055\254\003\060\187\004\107\100\181\082\170\000\000\000\000\073\069\078\068\174\066\096\130",
["ViewScript"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\146\073\068\065\084\120\156\077\147\107\076\091\117\024\198\159\255\229\112\078\079\075\059\182\193\090\012\215\165\088\096\008\163\155\132\108\078\019\170\075\230\156\049\174\113\038\126\192\111\051\044\033\075\092\098\136\001\225\131\137\209\012\099\140\113\198\236\018\003\036\054\018\231\062\193\196\078\092\192\120\097\051\046\149\109\008\056\151\012\005\090\010\189\157\158\115\254\127\083\152\198\231\235\147\247\201\239\125\223\060\036\028\014\179\098\163\088\063\127\125\146\032\158\020\059\118\008\130\135\090\093\165\050\024\172\100\193\096\208\244\249\124\057\000\180\191\191\223\194\255\068\078\119\157\110\050\044\227\172\109\091\186\148\194\148\032\132\062\052\037\136\077\025\117\081\066\023\231\022\230\078\142\143\143\199\195\225\112\081\036\018\201\255\023\016\010\029\125\178\189\237\177\177\087\078\028\087\025\231\144\194\006\200\022\004\037\020\177\187\139\152\152\136\034\155\203\124\085\221\220\220\217\211\213\149\232\237\237\229\255\146\240\120\060\097\056\052\109\163\186\166\154\023\105\170\101\155\022\005\037\144\082\130\171\069\248\123\045\037\116\221\129\039\014\029\056\054\061\253\253\165\182\182\182\206\129\129\129\002\009\139\068\034\054\023\084\080\042\193\082\201\021\054\053\241\043\201\230\114\084\085\139\096\024\006\092\197\030\040\170\142\076\058\035\102\126\190\145\207\027\230\115\205\123\154\047\180\183\183\191\058\056\056\152\232\235\235\163\188\128\097\075\129\034\077\195\222\166\000\172\124\030\140\177\173\021\024\197\082\034\139\142\103\066\084\074\073\044\203\018\223\126\115\109\127\044\022\115\019\066\226\177\088\076\217\012\096\148\066\152\038\230\022\255\068\054\155\131\194\057\132\016\112\057\053\180\238\009\160\201\095\001\069\119\210\165\007\127\209\239\162\215\146\115\247\239\219\133\185\146\146\144\164\092\225\176\133\000\229\010\106\043\031\065\117\185\015\129\064\013\060\078\023\206\142\220\067\100\097\059\064\037\096\229\054\015\108\089\022\051\242\092\124\252\163\080\124\047\215\049\106\153\214\038\065\193\188\053\059\143\188\157\131\166\109\199\204\111\038\094\012\053\032\122\121\018\137\013\027\080\153\116\106\014\028\127\233\133\244\254\242\090\114\249\195\139\195\182\213\050\182\249\242\194\197\109\001\212\215\215\194\048\057\222\063\055\137\134\250\050\156\056\178\027\103\158\247\066\087\057\242\025\155\185\061\170\237\041\217\021\176\124\135\222\206\172\167\166\023\162\211\123\041\087\052\024\166\009\085\119\193\235\173\194\185\225\187\136\205\199\113\096\095\053\080\228\068\149\191\018\111\190\115\021\239\126\116\157\164\146\105\049\124\101\094\043\123\234\112\199\027\095\156\186\120\099\228\147\016\079\172\111\192\237\114\096\121\105\021\067\087\238\224\216\209\032\182\021\171\232\125\239\042\146\235\025\148\238\244\224\233\080\043\140\188\109\127\112\233\166\082\083\225\090\170\105\243\159\186\013\164\099\011\095\254\064\179\057\192\161\114\044\175\164\240\203\237\085\028\233\168\199\174\082\055\238\252\177\014\127\093\021\098\191\199\209\113\208\143\199\091\042\048\051\187\130\214\128\059\113\178\142\071\187\009\049\250\046\068\053\094\086\236\064\124\045\013\191\191\028\175\117\150\200\238\158\207\165\203\165\225\173\051\207\162\241\081\047\130\205\149\120\189\127\020\186\174\202\158\238\195\208\148\180\050\053\051\227\001\176\214\232\092\054\057\231\128\144\004\140\051\113\048\088\110\155\230\062\185\205\173\162\113\183\027\070\102\029\237\045\094\228\205\032\220\046\221\110\168\085\248\167\231\071\229\103\163\099\118\161\046\145\072\004\188\174\182\130\039\146\027\116\104\104\132\048\066\104\169\183\148\036\031\216\248\105\114\025\133\074\017\202\080\230\043\069\138\080\054\245\245\061\220\188\053\203\119\058\117\038\229\086\027\255\001\187\130\131\114\132\157\206\003\000\000\000\000\073\069\078\068\174\066\096\130",
["WedgePart"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\099\073\068\065\084\120\156\125\083\207\107\019\081\016\158\239\237\110\160\018\069\008\130\030\018\054\009\094\123\018\245\162\071\017\015\162\135\226\069\090\065\240\226\015\208\127\160\061\120\244\032\173\020\079\034\042\162\017\069\164\040\138\216\030\252\129\146\163\208\214\102\247\189\217\004\033\080\069\208\131\213\205\142\076\217\134\180\106\007\134\199\188\247\205\199\204\251\102\136\136\104\124\124\220\136\136\161\220\068\164\144\036\201\208\218\027\109\098\016\017\000\016\013\022\023\023\107\133\066\225\056\128\067\068\052\148\101\217\229\090\173\246\066\068\060\000\189\127\018\016\017\181\219\237\225\052\077\207\003\216\003\160\067\068\119\068\100\007\128\075\034\114\033\012\195\153\255\146\180\090\173\221\214\218\207\204\060\019\069\209\240\224\091\028\199\039\156\115\214\090\123\068\227\070\163\225\109\204\247\061\207\171\003\216\070\068\219\141\049\171\000\017\009\230\230\230\164\086\171\221\079\146\068\219\156\142\162\232\092\189\094\255\171\018\223\024\019\136\200\043\099\204\075\017\105\180\090\173\083\000\222\040\048\007\223\107\183\219\191\125\223\159\116\206\017\128\117\036\126\154\166\100\140\217\082\046\151\039\153\249\087\016\004\183\156\115\163\074\050\059\059\235\231\224\135\157\078\199\075\211\244\218\070\018\223\243\060\149\065\084\182\074\165\114\061\073\018\149\244\166\115\110\044\012\195\183\003\149\052\152\089\068\100\138\153\013\128\039\170\160\159\247\044\089\150\073\046\233\180\115\078\019\110\091\107\079\002\120\039\034\107\149\060\176\214\006\068\116\133\153\191\002\120\221\031\018\207\243\048\049\049\161\031\230\135\097\056\037\034\087\115\146\253\000\082\197\052\155\205\160\090\173\222\005\240\028\192\233\213\068\102\062\234\156\123\054\040\141\246\174\167\181\246\034\051\071\074\146\087\138\165\165\165\178\115\238\003\051\143\173\130\163\040\058\192\204\011\113\028\143\048\115\125\121\121\089\037\237\027\051\159\113\206\125\138\227\120\095\030\207\048\243\141\254\020\055\155\205\160\084\042\157\053\198\140\232\014\016\209\079\000\172\005\244\122\189\143\000\222\003\024\037\162\195\122\071\068\187\138\197\226\177\082\169\244\189\063\202\106\221\110\183\184\178\178\178\019\192\112\150\101\058\145\234\117\034\082\210\111\068\180\087\068\190\136\200\193\106\181\186\160\203\007\032\091\083\065\131\031\058\217\185\063\210\251\249\249\249\173\133\066\033\244\060\079\255\224\169\049\230\113\165\082\089\208\013\213\228\117\051\173\253\040\145\250\102\043\172\184\193\248\015\016\126\118\042\070\082\149\174\000\000\000\000\073\069\078\068\174\066\096\130",
["Weld"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\043\073\068\065\084\120\156\157\083\061\136\019\081\016\158\121\047\155\221\136\063\193\228\012\001\073\082\196\004\043\193\082\176\185\234\188\226\090\075\075\075\017\171\171\178\157\022\114\162\160\224\021\022\150\087\136\030\103\041\105\036\032\004\004\217\034\070\147\236\238\237\038\074\032\009\138\154\219\077\222\200\156\201\145\139\185\003\029\088\230\045\111\190\217\111\190\249\022\224\152\040\149\074\098\122\182\044\235\164\235\186\103\167\239\068\132\156\035\071\129\137\072\032\162\106\181\090\113\000\088\071\196\101\034\138\216\182\093\039\162\123\136\248\158\155\136\227\192\158\231\037\016\113\091\008\113\003\017\095\016\209\099\068\204\032\226\142\239\251\151\017\241\015\141\057\048\242\069\173\086\075\198\098\177\087\000\176\100\024\198\181\084\042\213\224\251\122\189\174\235\186\094\038\162\221\092\046\119\093\044\002\243\172\186\174\191\036\162\020\034\174\050\184\092\046\071\120\132\066\161\176\007\000\155\000\112\145\025\070\230\025\084\171\085\141\136\158\010\033\178\097\024\046\231\243\249\207\068\036\017\113\196\077\184\102\060\030\159\145\082\142\012\195\008\035\011\190\126\069\041\181\066\068\107\249\124\254\147\239\251\039\016\241\231\068\151\081\163\209\072\073\041\111\001\192\235\100\050\249\237\096\004\211\052\247\245\080\074\093\002\128\047\154\166\125\112\028\231\126\016\004\155\174\235\198\088\084\030\077\211\052\030\237\059\000\220\061\180\005\211\052\105\114\244\001\192\024\141\070\079\164\148\119\136\232\107\038\147\249\213\110\183\151\136\104\007\000\078\043\165\214\178\217\108\027\000\016\231\087\215\233\116\206\005\065\240\046\145\072\228\186\221\238\115\000\184\169\148\186\032\165\124\134\136\167\134\195\225\106\177\088\108\078\235\197\140\171\136\197\010\195\112\029\000\050\253\126\127\087\074\121\085\008\241\070\074\249\022\017\247\162\209\232\010\131\183\182\182\088\084\197\088\156\060\251\244\109\219\222\136\199\227\183\007\131\193\134\148\242\001\017\177\152\231\149\082\031\013\195\216\078\167\211\063\166\098\031\218\125\165\082\137\057\142\243\176\215\235\017\055\097\038\071\057\116\161\239\155\205\102\209\113\156\158\227\056\143\184\136\155\114\230\159\105\038\255\229\218\131\176\044\043\234\121\094\129\157\054\163\201\255\197\191\130\127\003\252\157\069\026\053\252\128\023\000\000\000\000\073\069\078\068\174\066\096\130",
["WeldConstraint"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\002\117\073\068\065\084\120\156\125\083\061\104\020\081\016\158\153\247\110\247\114\057\077\208\042\133\102\115\027\098\017\011\059\035\216\004\005\177\017\083\089\139\063\181\168\136\164\185\139\096\171\164\176\010\246\146\086\027\171\164\181\016\137\016\139\075\194\187\061\046\254\017\004\189\159\220\238\251\025\121\199\093\072\206\224\131\101\103\118\230\155\249\102\190\183\000\000\176\189\189\125\126\111\111\239\036\028\115\152\025\215\214\214\036\051\015\063\194\199\192\027\074\169\183\073\146\092\030\000\014\129\201\199\225\063\071\002\000\018\081\222\057\151\027\238\140\136\206\219\073\146\148\136\232\156\115\206\090\107\081\008\225\180\214\027\211\211\211\063\101\063\217\039\242\097\176\047\220\104\052\046\024\099\098\102\126\228\156\235\002\064\155\136\044\051\159\033\162\013\102\190\035\055\055\055\169\088\044\030\208\094\095\095\023\243\243\243\102\103\103\231\138\148\114\153\136\186\030\032\132\184\155\101\089\042\165\220\007\128\057\000\184\009\000\212\099\048\212\217\238\238\238\022\180\214\207\156\115\175\162\040\090\169\213\106\047\000\224\169\016\098\159\185\071\180\224\156\123\131\136\134\102\103\103\123\115\122\202\136\200\149\074\005\179\044\171\048\243\047\173\245\107\068\212\081\020\061\048\198\092\079\211\116\097\116\116\116\033\077\211\107\165\082\105\249\096\137\000\096\133\016\227\074\169\075\099\099\099\095\154\205\230\184\049\102\113\102\102\038\085\074\141\003\064\043\142\227\223\199\073\076\003\071\107\077\068\116\175\221\110\159\152\156\156\188\207\204\223\235\245\122\153\136\110\249\038\171\171\171\162\092\046\123\089\241\176\212\200\204\185\036\073\222\049\179\167\180\200\204\031\114\185\092\157\136\030\107\173\211\048\012\175\078\076\076\212\250\178\242\048\003\121\080\009\209\087\213\133\066\225\097\183\219\005\034\242\136\219\030\220\143\031\001\015\190\081\223\112\253\026\065\024\134\030\220\115\156\115\207\149\082\043\074\169\057\223\109\104\132\222\024\114\107\107\139\130\032\200\091\107\083\033\068\181\211\233\156\182\214\102\214\090\191\180\143\000\240\057\008\130\175\125\006\188\180\180\116\148\133\082\042\079\068\055\136\232\147\214\250\148\049\038\031\134\161\051\198\116\133\016\013\068\244\239\162\181\054\240\128\048\012\185\213\106\009\041\101\043\138\162\111\189\209\157\115\162\094\175\191\100\230\139\136\216\241\055\204\255\072\000\224\065\062\199\014\174\186\183\157\115\039\153\249\253\212\212\212\147\222\028\213\106\053\028\025\025\057\203\204\236\119\208\108\054\049\008\002\239\254\179\184\129\228\136\248\039\142\227\031\127\001\011\228\116\254\078\240\052\190\000\000\000\000\073\069\078\068\174\066\096\130",
["Workspace"]="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\016\000\000\000\016\008\006\000\000\000\031\243\255\097\000\000\003\025\073\068\065\084\120\156\117\147\077\104\148\071\024\199\255\207\204\187\187\089\247\051\219\141\073\147\128\138\137\031\169\086\005\021\173\085\060\008\209\139\049\181\077\043\105\041\005\065\015\230\224\161\045\120\217\013\034\248\113\208\120\019\063\064\034\061\184\081\080\080\033\007\065\016\244\148\168\133\180\086\147\016\154\196\166\238\250\038\217\239\055\051\243\148\119\053\106\005\231\048\204\192\252\255\207\127\102\158\031\240\254\096\166\247\183\093\189\233\112\087\047\135\005\125\252\140\245\118\149\096\001\034\179\179\231\097\056\088\110\222\167\012\181\062\031\017\053\006\051\216\117\204\206\120\061\250\174\063\048\217\251\027\145\141\111\088\034\069\218\149\209\027\091\002\136\191\058\051\211\044\029\113\129\045\179\045\026\241\098\075\083\021\216\000\099\105\096\252\229\028\114\197\242\003\099\202\251\083\063\199\135\042\073\136\088\036\220\202\000\218\143\167\027\133\195\041\010\169\109\143\167\134\116\174\240\076\255\240\165\209\063\109\135\078\126\013\189\162\049\099\114\218\108\102\229\235\107\059\253\098\177\043\118\181\034\153\004\187\213\165\016\221\228\245\173\025\252\107\088\061\027\113\100\192\083\037\165\016\242\225\243\089\217\126\234\079\217\211\063\042\158\090\183\021\226\249\149\034\031\058\234\022\077\118\131\005\017\113\251\169\023\171\136\100\251\148\103\192\216\158\113\025\136\104\140\252\091\066\255\239\054\014\158\027\069\127\250\009\034\223\246\033\208\118\077\166\151\220\052\004\180\237\238\025\093\071\032\174\060\162\165\066\235\181\191\088\237\108\186\198\141\059\254\033\147\141\226\201\213\157\248\238\116\014\074\009\132\086\056\096\095\001\150\020\084\172\027\132\009\239\014\089\249\186\013\000\006\043\247\103\199\187\080\251\179\172\067\175\000\035\049\251\104\037\144\141\192\048\193\088\010\181\211\159\065\093\057\128\137\190\086\040\040\230\208\012\083\217\106\120\247\141\004\077\044\008\044\152\021\193\153\170\129\244\151\160\133\131\101\225\024\174\031\110\193\205\129\052\014\095\106\129\167\080\109\234\099\030\011\150\086\239\012\188\133\009\202\007\097\101\063\129\094\056\140\134\206\027\032\229\193\075\155\209\228\111\193\226\154\085\200\021\024\044\075\048\147\075\152\172\040\147\044\143\185\082\225\078\038\056\241\064\020\131\147\193\241\047\192\048\092\152\155\067\137\138\104\170\093\128\141\245\117\040\026\198\223\153\050\216\176\089\090\019\150\062\105\077\021\193\247\043\009\018\009\022\221\135\104\108\239\009\251\124\116\108\087\034\031\255\067\173\094\158\150\029\085\123\104\189\119\053\106\189\209\074\072\197\014\047\175\143\207\045\253\116\145\111\102\058\123\233\214\145\234\017\183\123\137\153\137\146\160\206\088\038\088\206\251\046\115\136\246\108\095\155\065\199\231\245\038\026\016\044\073\192\206\105\234\185\101\211\208\100\152\044\083\190\195\249\233\239\083\184\056\205\201\228\060\024\175\091\121\199\185\225\072\196\174\062\233\104\241\099\036\078\190\134\152\068\088\046\192\068\070\035\099\151\028\109\248\138\223\240\047\189\071\034\153\055\024\240\235\004\068\060\111\226\218\117\158\125\181\053\151\151\173\165\146\105\004\131\060\022\198\253\062\238\079\253\026\187\247\150\200\138\230\195\193\076\243\108\204\147\246\063\118\093\225\007\056\255\007\017\019\118\192\019\160\125\172\000\000\000\000\073\069\078\068\174\066\096\130",
}
local Environment = getgenv and getgenv() or _G
local Existing = Environment.VortexExplorer
if Existing and Existing.Alive then Existing:Show() return Existing end

assert(Drawing and type(Drawing.new) == "function", "Dex requires the Drawing library")
local Ui
if type(Drawing.newcontext) == "function" and (Drawing.UiVersion or 5) >= 5 then
    local Ok, Value = pcall(Drawing.newcontext)
    if Ok then Ui = Value end
elseif type(Drawing.create) == "function" and Drawing.UiVersion == nil then
    local Probe
    local Compatible = pcall(function()
        Probe = Drawing.create("TextBox", {Visible = false})
        Probe.HoverColor3 = Color3.fromRGB(68, 68, 68)
        Probe.HoverTransparency = 0
        assert(Probe.MouseButton2Click and Probe.FocusLost and Probe.TextChanged and type(Probe.CaptureFocus) == "function")
        assert(type(Drawing.getfocusedtextbox) == "function")
    end)
    if Probe then pcall(function() Probe:Destroy() end) end
    if Compatible then Ui = Drawing end
end
Ui = Ui or CreateUiLibrary(Drawing)
local Vector = Vector2.new
local Rgb = Color3.fromRGB
local Theme = {Main = Rgb(45, 45, 45), Title = Rgb(52, 52, 52), Outline = Rgb(33, 33, 33),
    Input = Rgb(38, 38, 38), Text = Rgb(220, 220, 220), Muted = Rgb(150, 150, 150), Selected = Rgb(11, 90, 175)}
local Fonts = Drawing.Fonts or {}
local Font = Fonts.SourceSans or Fonts.UI or Fonts.System or 1
local Controller = {Alive = true, Visible = true, Connections = {}, Windows = {}, Rows = {}, PropertyRows = {}, Flat = {},
    Nodes = setmetatable({}, {__mode = "v"}), Properties = {}, SearchVersion = 0, Query = "", LastTreeOffset = -1, LastPropertyOffset = -1}
local Input = game:GetService("UserInputService")
local Elapsed = 0
local NativeClock = os and os.clock or time or tick
local function Clock() return NativeClock and NativeClock() or Elapsed end

local function Read(Object, Name)
    local Ok, Value = pcall(function() return Object[Name] end)
    if Ok then return Value end
end

local function Text(Value)
    if Value == nil then return "nil" end
    local Ok, Result = pcall(tostring, Value)
    return Ok and Result or "<unavailable>"
end

local function Connect(Event, Callback)
    local Connection = Event:Connect(Callback)
    Controller.Connections[#Controller.Connections + 1] = Connection
    return Connection
end

local function Create(Kind, Parent, X, Y, Width, Height, Caption)
    local Highlighted = Kind == "TextButton" or Kind == "TextBox" or Kind == "Checkbox"
    return Ui.create(Kind, {Parent = Parent, Position = Vector(X, Y), Size = Vector(Width, Height),
        Text = Caption or "", Font = Font, TextSize = 14, Padding = 5, ZIndex = 2,
        Active = Kind == "TextButton" or Kind == "TextBox" or Kind == "ScrollingFrame",
        BackgroundColor3 = Theme.Main, BackgroundTransparency = Kind == "TextLabel" and 1 or 0,
        TextColor3 = Theme.Text, PlaceholderColor3 = Theme.Muted, ClearTextOnFocus = false,
        HoverColor3 = Highlighted and Rgb(68, 68, 68) or nil, HoverTransparency = Highlighted and 0 or nil})
end

local function Icon(Parent, Name, X, Y)
    local Data = Icons[Name] or Icons.Instance
    if not Data then return end
    local Ok, Item = pcall(Create, "ImageLabel", Parent, X, Y, 16, 16)
    if Ok then Item.Image, Item.BackgroundTransparency, Item.Active = Data, 0, false return Item end
end
Controller.Icon = Icon

local View = Read(workspace, "CurrentCamera")
local ViewSize = View and Read(View, "ViewportSize")
local ScreenWidth, ScreenHeight = ViewSize and ViewSize.X or 1280, ViewSize and ViewSize.Y or 720
local Height = math.clamp(ScreenHeight - 120, 300, 620)
local Width = math.clamp(math.floor((ScreenWidth - 60) / 2), 240, 310)

local function Window(Title, X, Y, W, H)
    local Root = Create("Frame", nil, X, Y, W, H)
    Root.Active, Root.Draggable, Root.ZIndex = true, true, (#Controller.Windows + 1) * 20
    Root.BackgroundColor3, Root.BackgroundTransparency = Theme.Main, 0.18
    local Body = Create("Frame", Root, 1, 1, W - 2, H - 2)
    Body.ZIndex, Body.BackgroundTransparency = 0, 1
    local Header = Create("Frame", Root, 1, 1, W - 2, 20)
    Header.ZIndex, Header.BackgroundColor3 = 0, Theme.Title
    Create("TextLabel", Header, 1, 0, W - 48, 20, Title)
    local Close = Create("TextButton", Root, W - 23, 1, 21, 19, "×")
    Close.ZIndex, Close.BackgroundTransparency = 5, 1
    Connect(Close.MouseButton1Click, function() Root.Visible = false end)
    Controller.Windows[#Controller.Windows + 1] = Root
    return Root
end

local WindowY = math.max(0, math.floor((ScreenHeight - Height) / 2))
local Explorer = Window("Explorer", math.max(10, ScreenWidth - Width * 2 - 28), WindowY, Width, Height)
local Properties = Window("Properties", math.max(Width + 20, ScreenWidth - Width - 18), WindowY, Width, Height)
local TreeSearch = Create("TextBox", Explorer, 3, 23, Width - 30, 21)
TreeSearch.BackgroundColor3, TreeSearch.PlaceholderText = Theme.Input, "Search workspace"
local Reload = Create("TextButton", Explorer, Width - 26, 23, 23, 21, "R")
Reload.BackgroundColor3 = Theme.Input
local Tree = Create("ScrollingFrame", Explorer, 2, 47, Width - 4, Height - 92)
Tree.ClipsDescendants, Tree.BackgroundTransparency, Tree.ZIndex = true, 1, 1
local Status = Create("TextLabel", Explorer, 3, Height - 23, Width - 6, 20, "Loading instances...")
Status.TextColor3 = Theme.Muted
local PropertySearch = Create("TextBox", Properties, 3, 23, Width - 6, 21)
PropertySearch.BackgroundColor3, PropertySearch.PlaceholderText = Theme.Input, "Search properties"
local PropertyList = Create("ScrollingFrame", Properties, 2, 47, Width - 4, Height - 51)
PropertyList.ClipsDescendants, PropertyList.BackgroundTransparency, PropertyList.ZIndex = true, 1, 1
Controller.Explorer, Controller.PropertyWindow = Explorer, Properties
local Bars = {}
local function Pointer()
    if type(Ui.getpointer) == "function" then return Ui.getpointer() end
    local Ok, Value = pcall(function() return Input:GetMouseLocation() end)
    if Ok then return Value end
end
local function Scrollbar(Parent, Scroll, X, Y)
    local Track = Create("TextButton", Parent, X, Y, 8, Scroll.Size.Y)
    Track.ZIndex, Track.BackgroundColor3 = 4, Theme.Input
    local Thumb = Create("TextButton", Track, 1, 0, 6, 30)
    Thumb.ZIndex, Thumb.BackgroundColor3 = 1, Rgb(111, 111, 111)
    local Bar = {Track = Track, Thumb = Thumb, Scroll = Scroll}
    Bars[#Bars + 1] = Bar
    Connect(Thumb.MouseButton1Down, function()
        local Point = Pointer()
        if Point then Controller.ScrollbarDrag = {Bar = Bar, Offset = Point.Y - Thumb.AbsolutePosition.Y} end
    end)
    Connect(Thumb.MouseButton1Up, function() Controller.ScrollbarDrag = nil end)
    Connect(Track.MouseButton1Click, function()
        local Point = Pointer()
        if Point then Scroll.ScrollOffset = math.clamp((Point.Y - Track.AbsolutePosition.Y) / Track.Size.Y, 0, 1) * math.max(0, Scroll.CanvasSize - Scroll.Size.Y) end
    end)
end
Scrollbar(Explorer, Tree, Width - 11, 47)
Scrollbar(Properties, PropertyList, Width - 11, 47)
local function PaintBars()
    local Drag = Controller.ScrollbarDrag
    if Drag then
        local Point, Bar = Pointer(), Drag.Bar
        if Point and not Bar.Track.Destroyed then
            local Range = math.max(1, Bar.Track.Size.Y - Bar.Thumb.Size.Y)
            Bar.Scroll.ScrollOffset = math.clamp((Point.Y - Bar.Track.AbsolutePosition.Y - Drag.Offset) / Range, 0, 1)
                * math.max(0, Bar.Scroll.CanvasSize - Bar.Scroll.Size.Y)
        end
    end
    for _, Bar in Bars do
        local Maximum = math.max(0, Bar.Scroll.CanvasSize - Bar.Scroll.Size.Y)
        Bar.Track.Visible = Maximum > 0
        if Maximum == 0 then continue end
        local Size = math.max(22, Bar.Track.Size.Y * Bar.Scroll.Size.Y / math.max(1, Bar.Scroll.CanvasSize))
        Bar.Thumb.Size = Vector(6, Size)
        Bar.Thumb.Position = Vector(1, Bar.Scroll.ScrollOffset / Maximum * (Bar.Track.Size.Y - Size))
    end
end

local Dock = Create("TextButton", nil, ScreenWidth / 2 - 27, 2, 54, 25, "Dex++")
Dock.BackgroundColor3, Dock.ZIndex = Theme.Title, 9990
Controller.Dock = Dock

function Controller:Status(Message)
    if self.Alive then Status.Text = Text(Message):sub(1, 512) end
end

function Controller:Show()
    self.Visible, Explorer.Visible, Properties.Visible = true, true, true
end

function Controller:Stop()
    if not self.Alive then return end
    self.Alive = false
    for _, Connection in self.Connections do pcall(function() Connection:Disconnect() end) end
    for _, Root in self.Windows do pcall(function() Root:Destroy() end) end
    Dock:Destroy()
    if Environment.VortexExplorer == self then Environment.VortexExplorer = nil end
end
Controller.Destroy = Controller.Stop
Connect(Dock.MouseButton1Click, function()
    if Explorer.Visible or Properties.Visible then
        Explorer.Visible, Properties.Visible, Controller.Visible = false, false, false
        for _, Root in Controller.Windows do Root.Visible = false end
    else Controller:Show() end
end)

local function Node(Object, Parent)
    local Key = Read(Object, "_id") or Object
    local Item = Controller.Nodes[Key]
    if not Item then
        Item = {Object = Object, Parent = Parent, Key = Key, Name = Text(Read(Object, "Name") or (Object == game and "game" or "Instance")),
            Class = Text(Read(Object, "ClassName") or (Object == game and "DataModel" or "Instance")), Expanded = false}
        Controller.Nodes[Key] = Item
    end
    Item.Parent = Parent
    return Item
end

local Root = Node(game)
Root.Expanded = true
local ServiceOrder = {Workspace = 1, ReplicatedStorage = 2, StarterPlayerScripts = 3, ServerScriptService = 4, Lighting = 5, Players = 6}
local function Children(Item, Refresh)
    if Item.Children and not Refresh then return Item.Children end
    local Ok, Objects = pcall(function() return Item.Object:GetChildren() end)
    if not Ok or type(Objects) ~= "table" then Objects = {} end
    if Item.Object == game and #Objects == 0 then
        Objects = {workspace}
        for _, Name in {"Players", "Lighting", "ReplicatedStorage", "StarterPlayerScripts", "ServerScriptService", "Teams", "SoundService"} do
            local Success, Service = pcall(function() return game:GetService(Name) end)
            if Success and Service and Service ~= workspace then Objects[#Objects + 1] = Service end
        end
    end
    local Result, Seen = {}, {}
    for _, Object in Objects do
        local Child = Node(Object, Item)
        if Child.Key ~= Item.Key and not Seen[Child.Key] then
            Seen[Child.Key] = true
            Child.Name = Text(Read(Object, "Name") or Child.Name)
            Result[#Result + 1] = Child
        end
    end
    table.sort(Result, function(A, B)
        if Item == Root then
            local Left, Right = ServiceOrder[A.Class] or ServiceOrder[A.Name] or 100, ServiceOrder[B.Class] or ServiceOrder[B.Name] or 100
            if Left ~= Right then return Left < Right end
        end
        if A.Class ~= B.Class then return A.Class < B.Class end
        return A.Name:lower() < B.Name:lower()
    end)
    Item.Children = Result
    return Result
end

local function Rebuild()
    if Controller.Query ~= "" then return end
    local Flat, Stack, Seen = {}, {}, {}
    local Services = Children(Root)
    for Index = #Services, 1, -1 do Stack[#Stack + 1] = {Node = Services[Index], Depth = 0} end
    while #Stack > 0 and #Flat < 12000 do
        local Entry = table.remove(Stack)
        local Item = Entry.Node
        if Seen[Item.Key] or Entry.Depth > 64 then continue end
        Seen[Item.Key] = true
        Flat[#Flat + 1] = Entry
        if Item.Expanded then
            local List = Children(Item)
            for Index = #List, 1, -1 do Stack[#Stack + 1] = {Node = List[Index], Depth = Entry.Depth + 1} end
        end
    end
    Controller.Flat = Flat
    Tree.CanvasSize = math.min(65000, #Flat * 20)
    Tree.ScrollOffset = math.clamp(Tree.ScrollOffset, 0, math.max(0, Tree.CanvasSize - Tree.Size.Y))
    Controller.LastTreeOffset = -1
end

local function Search(Query, Version)
    local Stack, Ordered, Keep, Seen = {{Node = Root, Depth = 0}}, {}, {}, {}
    while #Stack > 0 and #Ordered < 8000 do
        if not Controller.Alive or Version ~= Controller.SearchVersion then return end
        local Entry = table.remove(Stack)
        local Item = Entry.Node
        if Seen[Item.Key] or Entry.Depth > 64 then continue end
        Seen[Item.Key] = true
        Ordered[#Ordered + 1] = Entry
        if Item.Name:lower():find(Query, 1, true) or Item.Class:lower():find(Query, 1, true) then
            local Parent = Item
            for _ = 1, 65 do if not Parent then break end Keep[Parent] = true Parent = Parent.Parent end
        end
        local List = Children(Item)
        for Index = #List, 1, -1 do Stack[#Stack + 1] = {Node = List[Index], Depth = Entry.Depth + 1} end
        if #Ordered % 80 == 0 then task.wait() end
    end
    if not Controller.Alive or Version ~= Controller.SearchVersion then return end
    local Flat = {}
    for _, Entry in Ordered do if Keep[Entry.Node] then Flat[#Flat + 1] = Entry end end
    Controller.Flat = Flat
    Tree.CanvasSize, Tree.ScrollOffset = math.min(65000, #Flat * 20), 0
    Controller.LastTreeOffset = -1
    Controller:Status(#Stack > 0 and "Search limited to 8000 instances" or (#Flat .. " matching rows"))
end

local function Path(Item)
    local Parts = {}
    for _ = 1, 65 do
        if not Item or Item == Root then break end
        table.insert(Parts, 1, "[" .. string.format("%q", Item.Name) .. "]")
        Item = Item.Parent
    end
    return "game" .. table.concat(Parts)
end

local function ValueKind(Value)
    if type(Value) == "number" or type(Value) == "boolean" or type(Value) == "string" then return type(Value) end
    if Value ~= nil and type(Read(Value, "R")) == "number" and type(Read(Value, "G")) == "number" then return "Color3" end
    if Value ~= nil and type(Read(Value, "X")) == "number" and type(Read(Value, "Y")) == "number" then
        return type(Read(Value, "Z")) == "number" and "Vector3" or "Vector2"
    end
    return "readonly"
end

local function Format(Value, Kind)
    if Kind == "Vector3" then return string.format("%.4g, %.4g, %.4g", Value.X, Value.Y, Value.Z) end
    if Kind == "Vector2" then return string.format("%.4g, %.4g", Value.X, Value.Y) end
    if Kind == "Color3" then return string.format("%.4g, %.4g, %.4g", Value.R, Value.G, Value.B) end
    return Text(Value):sub(1, 4096)
end

local function Parse(Value, Kind)
    if Kind == "string" then return Value end
    if Kind == "boolean" then
        Value = Value:lower():match("^%s*(.-)%s*$")
        assert(Value == "true" or Value == "false", "Enter true or false")
        return Value == "true"
    end
    if Kind == "number" then
        local Number = tonumber(Value)
        assert(Number and Number == Number and math.abs(Number) < math.huge, "Enter a finite number")
        return Number
    end
    local Parts = {}
    for Part in Value:gmatch("[^,%s]+") do Parts[#Parts + 1] = Parse(Part, "number") end
    assert(#Parts == (Kind == "Vector2" and 2 or 3), "Enter comma-separated components")
    if Kind == "Color3" then return Color3.new(Parts[1], Parts[2], Parts[3]) end
    if Kind == "Vector2" then return Vector2.new(Parts[1], Parts[2]) end
    return Vector3.new(Parts[1], Parts[2], Parts[3])
end

local Groups = {
    {"Data", "ClassName", "Name", "Parent", "Archivable", "Value"},
    {"Transform", "Position", "Size", "CFrame", "Orientation", "Rotation", "PivotOffset"},
    {"Appearance", "Color", "Transparency", "Reflectance", "Material", "Shape", "CastShadow", "TextureID", "MeshId"},
    {"Behavior", "Anchored", "CanCollide", "CanTouch", "CanQuery", "Locked", "Massless", "Velocity", "AssemblyLinearVelocity", "AssemblyAngularVelocity"},
    {"Humanoid", "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight", "Sit", "PlatformStand", "AutoRotate"},
    {"Script", "Enabled", "Disabled", "RunContext"},
    {"Lighting", "Gravity", "Brightness", "Ambient", "OutdoorAmbient", "ClockTime", "TimeOfDay", "FogStart", "FogEnd", "FogColor"},
    {"Camera", "FieldOfView", "CameraType", "ViewportSize"},
}

local function RefreshProperties()
    local Selected = Controller.Selected
    if not Selected then return end
    local Result, Query = {}, PropertySearch.Text:lower()
    for _, Group in Groups do
        local Values = {}
        for Index = 2, #Group do
            local Name = Group[Index]
            local Value = Read(Selected.Object, Name)
            if Value == nil and Name ~= "Parent" then continue end
            local Kind = ValueKind(Value)
            if Name == "ClassName" or Name == "Parent" or Name == "ViewportSize" or Name == "CFrame" then Kind = "readonly" end
            if Query == "" or Name:lower():find(Query, 1, true) then
                Values[#Values + 1] = {Name = Name, Kind = Kind, Value = Format(Value, Kind)}
            end
        end
        if #Values > 0 then
            Result[#Result + 1] = {Name = Group[1], Header = true}
            for _, Value in Values do Result[#Result + 1] = Value end
        end
    end
    local Ok, Attributes = pcall(function() return Selected.Object:GetAttributes() end)
    if Ok and type(Attributes) == "table" then
        local Count = 0
        for Name, Value in Attributes do
            if type(Name) ~= "string" or Query ~= "" and not Name:lower():find(Query, 1, true) then continue end
            if Count == 0 then Result[#Result + 1] = {Name = "Attributes", Header = true} end
            local Kind = ValueKind(Value)
            Result[#Result + 1] = {Name = Name, Kind = Kind, Value = Format(Value, Kind), Attribute = true}
            Count += 1
            if Count == 50 then break end
        end
    end
    Controller.Properties = Result
    PropertyList.CanvasSize = #Result * 22
    Controller.LastPropertyOffset = -1
end

local function Select(Item)
    for _, Slot in Controller.PropertyRows do if Slot.Value:IsFocused() then Slot.Value:ReleaseFocus(false) end end
    Controller.Selected = Item
    Controller.Selection = {[Item.Key] = Item}
    if Controller.CloseMenu then Controller.CloseMenu() end
    Controller.LastTreeOffset = -1
    PropertyList.ScrollOffset = 0
    RefreshProperties()
    Controller:Status(Path(Item))
end

local PageSize = math.min(32, math.ceil(Tree.Size.Y / 20) + 1)
local OpenContext
for Index = 1, PageSize do
    local Slot = {}
    Slot.Row = Create("TextButton", Tree, 0, 0, Width - 12, 20)
    Slot.Row.Visible = false
    Slot.Arrow = Create("TextButton", Slot.Row, 0, 0, 17, 20)
    Slot.Arrow.ZIndex, Slot.Arrow.BackgroundTransparency = 3, 1
    Slot.ArrowIcon = Icon(Slot.Arrow, "Expand", 1, 2)
    Slot.Icon = Icon(Slot.Row, "Instance", 19, 2) or Create("Frame", Slot.Row, 19, 5, 10, 10)
    Slot.Label = Create("TextLabel", Slot.Row, 40, 0, Width - 60, 20)
    Slot.Label.Padding = 0
    Slot.Row.MouseButton1Click:Connect(function()
        if not Slot.Entry then return end
        local Item, Now = Slot.Entry.Node, Clock()
        Select(Item)
        if Slot.LastKey == Item.Key and Now - (Slot.LastClick or 0) < 0.35 then
            if Item.Class:find("Script", 1, true) and Controller.Actions then Controller.Actions.Source()
            else Item.Expanded = not Item.Expanded Rebuild() end
        end
        Slot.LastKey, Slot.LastClick = Item.Key, Now
    end)
    Slot.Row.MouseButton2Click:Connect(function(Position)
        if Slot.Entry and OpenContext then
            if not Controller.Selection or not Controller.Selection[Slot.Entry.Node.Key] then Select(Slot.Entry.Node) end
            OpenContext(Position or Pointer())
        end
    end)
    Slot.Arrow.MouseButton1Click:Connect(function()
        if not Slot.Entry then return end
        Slot.Entry.Node.Expanded = not Slot.Entry.Node.Expanded
        Rebuild()
    end)
    Controller.Rows[Index] = Slot
end

for Index = 1, math.min(32, math.ceil(PropertyList.Size.Y / 22) + 1) do
    local Slot = {}
    Slot.Label = Create("TextLabel", PropertyList, 0, 0, Width * 0.48, 22)
    Slot.Value = Create("TextBox", PropertyList, Width * 0.48, 0, Width * 0.52 - 10, 21)
    Slot.Value.BackgroundColor3, Slot.Value.MaxLength = Theme.Input, 4096
    Slot.ReadOnly = Create("TextLabel", PropertyList, Width * 0.48, 0, Width * 0.52 - 10, 22)
    Slot.ReadOnly.TextColor3 = Theme.Muted
    Slot.Toggle = Create("Checkbox", PropertyList, Width * 0.48, 0, 20, 20)
    Slot.Toggle.Active = true
    Slot.Label.Visible, Slot.Value.Visible, Slot.ReadOnly.Visible, Slot.Toggle.Visible = false, false, false, false
    Slot.Toggle.MouseButton1Click:Connect(function()
        local Entry, Object = Slot.Descriptor, Slot.Object
        if not Entry or Entry.Kind ~= "boolean" or not Object then return end
        local Ok, Error = pcall(function()
            if Entry.Attribute then Object:SetAttribute(Entry.Name, Slot.Toggle.Value)
            else Object[Entry.Name] = Slot.Toggle.Value end
        end)
        Controller:Status(Ok and (Entry.Name .. " updated") or Error)
        RefreshProperties()
    end)
    Slot.Value.Focused:Connect(function()
        Slot.Editing = Slot.Descriptor and {Object = Controller.Selected.Object, Descriptor = Slot.Descriptor}
    end)
    Slot.Value.FocusLost:Connect(function(Submitted)
        local Edit = Slot.Editing
        Slot.Editing = nil
        if not Submitted or not Edit then return end
        local Ok, Error = pcall(function()
            local Value = Parse(Slot.Value.Text, Edit.Descriptor.Kind)
            if Edit.Descriptor.Attribute then Edit.Object:SetAttribute(Edit.Descriptor.Name, Value)
            else Edit.Object[Edit.Descriptor.Name] = Value end
        end)
        Controller:Status(Ok and (Edit.Descriptor.Name .. " updated") or Error)
        if Ok and Edit.Descriptor.Name == "Name" and Controller.Selected and Controller.Selected.Object == Edit.Object then
            Controller.Selected.Name = Text(Read(Edit.Object, "Name"))
            Controller.LastTreeOffset = -1
        end
        RefreshProperties()
    end)
    Controller.PropertyRows[Index] = Slot
end

local function PaintTree()
    if Tree.ScrollOffset == Controller.LastTreeOffset then return end
    Controller.LastTreeOffset = Tree.ScrollOffset
    local Maximum = math.max(0, Tree.CanvasSize - Tree.Size.Y)
    local Offset = Maximum > 0 and Tree.ScrollOffset * math.max(0, #Controller.Flat * 20 - Tree.Size.Y) / Maximum or 0
    local First = math.floor(Offset / 20)
    for Index, Slot in Controller.Rows do
        local Entry = Controller.Flat[First + Index]
        Slot.Entry, Slot.Row.Visible = Entry, Entry ~= nil
        if not Entry then continue end
        local Item, Indent = Entry.Node, math.min(Entry.Depth * 14, Width - 75)
        Slot.Row.Position = Vector(0, Tree.ScrollOffset + (First + Index - 1) * 20 - Offset)
        Slot.Row.BackgroundTransparency = Controller.Selection and Controller.Selection[Item.Key] and 0 or 1
        Slot.Row.BackgroundColor3 = Theme.Selected
        Slot.Row.HoverColor3 = Controller.Selection and Controller.Selection[Item.Key] and Rgb(28, 108, 187) or Rgb(65, 65, 65)
        Slot.Row.HoverTransparency = 0.15
        Slot.Arrow.Position, Slot.Arrow.Text = Vector(Indent, 0), ""
        Slot.Arrow.Visible = not Item.Children or #Item.Children > 0
        if Slot.ArrowIcon then Slot.ArrowIcon.Image = Icons[(Item.Expanded or Controller.Query ~= "") and "Collapse" or "Expand"] end
        Slot.Icon.Position = Vector(Indent + 19, 2)
        if Slot.Icon.Kind == "ImageLabel" then Slot.Icon.Image = Icons[Item.Class] or Icons.Instance end
        Slot.Label.Position, Slot.Label.Size = Vector(Indent + 40, 0), Vector(math.max(20, Width - Indent - 54), 20)
        Slot.Label.Text = Item.Name
    end
end

local function PaintProperties()
    if PropertyList.ScrollOffset == Controller.LastPropertyOffset then return end
    Controller.LastPropertyOffset = PropertyList.ScrollOffset
    local First = math.floor(PropertyList.ScrollOffset / 22)
    for Index, Slot in Controller.PropertyRows do
        local Entry = Controller.Properties[First + Index]
        Slot.Descriptor, Slot.Label.Visible = Entry, Entry ~= nil
        Slot.Value.Visible, Slot.ReadOnly.Visible, Slot.Toggle.Visible = false, false, false
        if not Entry then continue end
        local Y = (First + Index - 1) * 22
        Slot.Label.Position, Slot.Label.Text = Vector(0, Y), Entry.Name
        Slot.Label.Size = Vector(Entry.Header and Width - 10 or Width * 0.48, 22)
        if not Entry.Header then
            Slot.Object = Controller.Selected and Controller.Selected.Object
            if Entry.Kind == "boolean" then
                Slot.Toggle.Position, Slot.Toggle.Visible, Slot.Toggle.Value = Vector(Width * 0.48 + 4, Y + 1), true, Entry.Value == "true"
                continue
            end
            local Field = Entry.Kind == "readonly" and Slot.ReadOnly or Slot.Value
            Field.Position, Field.Visible = Vector(Width * 0.48, Y), true
            if Field ~= Slot.Value or not Slot.Value:IsFocused() then Field.Text = Entry.Value end
        end
    end
end

local function Refresh()
    Controller.SearchVersion += 1
    local function Clear(Item, Seen)
        if Seen[Item.Key] then return end
        Seen[Item.Key] = true
        for _, Child in Item.Children or {} do Clear(Child, Seen) end
        Item.Children = nil
    end
    Clear(Root, {})
    if Controller.Query == "" then Rebuild()
    else task.spawn(Search, Controller.Query, Controller.SearchVersion) end
    RefreshProperties()
    Controller:Status("Explorer refreshed")
end
Connect(Reload.MouseButton1Click, Refresh)
Connect(TreeSearch.TextChanged, function(Value)
    Controller.Query = Value:lower():match("^%s*(.-)%s*$")
    Controller.SearchVersion += 1
    Controller.SearchAt = Clock() + 0.25
end)
Connect(PropertySearch.TextChanged, RefreshProperties)

local Actions = {}
local function Action(Caption, X, WidthValue, Callback)
    Actions[Caption] = Callback
    local Button = Create("TextButton", Explorer, X, Height - 45, WidthValue, 20, Caption)
    Button.BackgroundColor3 = Theme.Title
    Connect(Button.MouseButton1Click, function()
        task.spawn(function()
            local Ok, Error = pcall(Callback)
            if not Ok then Controller:Status(Error) end
        end)
    end)
    return Button
end

Action("Copy path", 3, 70, function()
    assert(Controller.Selected, "Select an instance")
    assert(type(setclipboard) == "function", "Clipboard unavailable")
    setclipboard(Path(Controller.Selected))
    Controller:Status("Path copied")
end)

local SourceWindow, SourceBox, SourceScroll
Action("Source", 76, 56, function()
    local Selected = assert(Controller.Selected, "Select a script")
    assert(Selected.Class:find("Script", 1, true), "Select a LocalScript, ModuleScript or Script")
    local Source = Read(Selected.Object, "Source")
    if type(Source) ~= "string" or Source == "" then
        assert(type(decompile) == "function", "Decompiler unavailable")
        Controller:Status("Decompiling " .. Selected.Name .. "...")
        Source = decompile(Selected.Object)
    end
    assert(type(Source) == "string", "No source returned")
    if not SourceWindow then
        local W, H = math.min(700, ScreenWidth - 30), math.min(480, ScreenHeight - 80)
        SourceWindow = Window("Script Viewer", 20, math.max(0, math.floor((ScreenHeight - H) / 2)), W, H)
        SourceScroll = Create("ScrollingFrame", SourceWindow, 4, 25, W - 8, H - 54)
        SourceScroll.ClipsDescendants, SourceScroll.BackgroundColor3, SourceScroll.ZIndex = true, Rgb(36, 36, 36), 1
        SourceBox = Create("TextBox", SourceScroll, 0, 0, W - 18, H - 54)
        SourceBox.Multiline, SourceBox.Font, SourceBox.TextSize = true, Fonts.Monospace or 3, 14
        SourceBox.BackgroundColor3 = Rgb(36, 36, 36)
        Scrollbar(SourceWindow, SourceScroll, W - 12, 25)
        local Copy = Create("TextButton", SourceWindow, 4, H - 25, 100, 21, "Copy source")
        Connect(Copy.MouseButton1Click, function()
            if type(setclipboard) == "function" then setclipboard(SourceBox.Text) end
        end)
        local Save = Create("TextButton", SourceWindow, 108, H - 25, 100, 21, "Save source")
        Connect(Save.MouseButton1Click, function()
            local Ok, Error = pcall(function()
                assert(type(writefile) == "function", "writefile unavailable")
                local Name = (Controller.SourceName or "Script"):gsub("[^%w_%-]", "_"):sub(1, 80) .. ".luau"
                writefile(Name, SourceBox.Text)
                Controller:Status("Saved " .. Name)
            end)
            if not Ok then Controller:Status(Error) end
        end)
    end
    SourceWindow.Visible = true
    Controller.SourceName = Selected.Name
    SourceBox.Text = Source:sub(1, 65536)
    local _, Lines = SourceBox.Text:gsub("\n", "")
    SourceBox.Size = Vector(SourceBox.Size.X, math.min(65000, math.max(SourceScroll.Size.Y, (Lines + 2) * 16)))
    SourceScroll.CanvasSize, SourceScroll.ScrollOffset = SourceBox.Size.Y, 0
    SourceBox.Cursor, SourceBox.Anchor = 0, 0
    Controller:Status("Opened " .. Selected.Name)
end)

Action("Save", 135, 43, function()
    assert(type(saveinstance) == "function", "saveinstance unavailable")
    local Selected = Controller.Selected
    local Name = Selected and Selected.Name:gsub("[^%w_%-]", "_"):sub(1, 80) or "Game"
    local Options = {FilePath = Name .. ".vrtx", SaveScripts = true}
    if Selected and Selected ~= Root then Options.Root = Selected.Object end
    Controller:Status("Saving " .. Name .. ".vrtx...")
    local SavedPath = saveinstance(Options)
    Controller:Status("Saved " .. tostring(SavedPath))
end)

Action("Delete", 181, 52, function()
    local Selected = assert(Controller.Selected, "Select an instance")
    assert(Selected ~= Root and Selected.Object ~= workspace, "Cannot delete this root")
    if Controller.DeleteKey ~= Selected.Key or Clock() > (Controller.DeleteUntil or 0) then
        Controller.DeleteKey, Controller.DeleteUntil = Selected.Key, Clock() + 3
        Controller:Status("Press Delete again to remove " .. Selected.Name)
        return
    end
    Selected.Object:Destroy()
    Controller.Selected = nil
    Controller.Properties = {}
    Controller.LastPropertyOffset = -1
    Refresh()
end)

for _, Object in {game, workspace} do
    for _, Name in {"DescendantAdded", "DescendantRemoving"} do
        local Signal = Read(Object, Name)
        if Signal then
            pcall(function() Connect(Signal, function()
                if not Controller.RefreshAt then Controller.RefreshAt = Clock() + 0.5 end
            end) end)
        end
    end
end

Rebuild()
PaintTree()
PaintProperties()
local Menu, PromptWindow, PromptBox, PromptCallback
local Clipboard = {}
local function Run(Callback)
    if not Callback then return end
    local Ok, Error = pcall(Callback)
    if not Ok then Controller:Status(Error) end
end

local function CloseMenu()
    if Menu then Menu:Destroy() Menu = nil end
end
Controller.CloseMenu = CloseMenu
Controller.Ui = Ui
Controller.Root = Root
Controller.Refresh = Refresh
Controller.Select = Select
Controller.Rebuild = Rebuild

local function Selected()
    local Result = {}
    for _, Item in Controller.Selection or {} do
        local Ancestor, Nested = Item.Parent, false
        for _ = 1, 65 do
            if not Ancestor then break end
            if Controller.Selection[Ancestor.Key] then Nested = true break end
            Ancestor = Ancestor.Parent
        end
        if not Nested and Item ~= Root then Result[#Result + 1] = Item end
    end
    return Result
end

local function Prompt(Title, Value, Callback)
    CloseMenu()
    if not PromptWindow then
        PromptWindow = Window("", math.max(10, ScreenWidth / 2 - 160), math.max(30, ScreenHeight / 2 - 55), 320, 110)
        local Label = Create("TextLabel", PromptWindow, 6, 22, 308, 22)
        PromptWindow.PromptLabel = Label
        PromptBox = Create("TextBox", PromptWindow, 6, 47, 308, 23)
        PromptBox.BackgroundColor3 = Theme.Input
        local Accept = Create("TextButton", PromptWindow, 164, 79, 72, 23, "OK")
        local Cancel = Create("TextButton", PromptWindow, 241, 79, 72, 23, "Cancel")
        local function Finish(Submitted)
            if not PromptWindow.Visible then return end
            PromptWindow.Visible = false
            if PromptBox:IsFocused() then PromptBox:ReleaseFocus(false) end
            local CallbackValue = PromptCallback
            PromptCallback = nil
            if Submitted then Run(function() CallbackValue(PromptBox.Text) end) end
        end
        Connect(Accept.MouseButton1Click, function() Finish(true) end)
        Connect(Cancel.MouseButton1Click, function() Finish(false) end)
        Connect(PromptBox.FocusLost, function(Submitted) if Submitted then Finish(true) end end)
        Connect(PromptBox.InputBegan, function(Key) if Key == "Escape" then Finish(false) end end)
    end
    PromptWindow.Visible, PromptWindow.PromptLabel.Text = true, Title
    PromptBox.Text, PromptCallback = Value or "", Callback
    PromptBox:CaptureFocus()
    PromptBox:SelectAll()
end

local function RequireSelection()
    return assert(Controller.Selected, "Select an instance")
end

local function Copy(Cut)
    local Items, NewClipboard = Selected(), {}
    assert(#Items > 0, "Select an instance")
    for _, Item in Items do NewClipboard[#NewClipboard + 1] = Item.Object:Clone() end
    for _, Object in Clipboard do pcall(function() Object:Destroy() end) end
    Clipboard = NewClipboard
    if Cut then for _, Item in Items do Item.Object:Destroy() end Refresh() end
    Controller:Status((Cut and "Cut " or "Copied ") .. #Items .. " instance(s)")
end

local function Delete(ChildrenOnly)
    local Items = Selected()
    assert(#Items > 0, "Select an instance")
    for _, Item in Items do
        assert(Item.Object ~= workspace, "Cannot delete Workspace")
        if ChildrenOnly then
            for _, Child in Item.Object:GetChildren() do Child:Destroy() end
        else Item.Object:Destroy() end
    end
    Controller.Selected, Controller.Selection, Controller.Properties = nil, {}, {}
    Refresh()
end

local function Expand(Expanded)
    local Stack, Count, Seen = {RequireSelection()}, 0, {}
    while #Stack > 0 and Count < 8000 do
        local Item = table.remove(Stack)
        if Seen[Item.Key] then continue end
        Seen[Item.Key], Item.Expanded = true, Expanded
        Count += 1
        for _, Child in Children(Item) do Stack[#Stack + 1] = Child end
        if Count % 80 == 0 then task.wait() end
    end
    Rebuild()
    Controller:Status(Count == 8000 and "Expansion limited to 8000 instances" or "Tree updated")
end

local Commands = {
    {"Cut", "Ctrl+X", "Cut", function() Copy(true) end},
    {"Copy", "Ctrl+C", "Copy", function() Copy(false) end},
    {"Paste Into", "Ctrl+Shift+V", "Paste", function()
        assert(#Clipboard > 0, "Copy an instance first")
        local Target = RequireSelection()
        for _, Object in Clipboard do local Clone = Object:Clone() Clone.Parent = Target.Object end
        Target.Expanded = true
        Refresh()
    end},
    {"Duplicate", "Ctrl+D", "Copy", function()
        for _, Item in Selected() do local Clone = Item.Object:Clone() Clone.Parent = Item.Object.Parent end
        Refresh()
    end},
    {"Delete", "Del", "Delete", function() Delete(false) end},
    {"Delete Children", "Shift+Del", "Delete", function() Delete(true) end},
    {"Rename", "F2", "Rename", function()
        local Item = RequireSelection()
        assert(Item ~= Root, "Cannot rename game")
        Prompt("Rename " .. Item.Name, Item.Name, function(Value)
            assert(#Value > 0, "Name cannot be empty")
            Item.Object.Name, Item.Name = Value, Value
            Refresh()
        end)
    end},
    {"Group", "Ctrl+G", "Group", function()
        local Items = Selected()
        assert(#Items > 0, "Select an instance")
        local Model = Instance.new("Model")
        Model.Name, Model.Parent = "Model", Items[1].Object.Parent
        for _, Item in Items do Item.Object.Parent = Model end
        Refresh()
        Select(Node(Model, Items[1].Parent))
    end},
    {"Ungroup", "Ctrl+U", "Ungroup", function()
        for _, Item in Selected() do
            assert(Item.Class == "Model" or Item.Class == "Folder", "Select a Model or Folder")
            local Parent = Item.Object.Parent
            for _, Child in Item.Object:GetChildren() do Child.Parent = Parent end
            Item.Object:Destroy()
        end
        Refresh()
    end},
    {"Select Children", "", "SelectChildren", function()
        local Parent = RequireSelection()
        Controller.Selection = {}
        for _, Item in Children(Parent) do Controller.Selection[Item.Key] = Item end
        Parent.Expanded, Controller.LastTreeOffset = true, -1
        Rebuild()
    end},
    {"Jump to Parent", "", "JumpToParent", function()
        local Parent = RequireSelection().Parent
        assert(Parent, "Already at the root")
        Select(Parent)
        Parent.Expanded = true
        Rebuild()
    end},
    {"Expand All", "", "Expand", function() Expand(true) end},
    {"Collapse All", "", "Collapse", function() Expand(false) end},
    {"Copy Path", "", "Reference", Actions["Copy path"]},
    {"Insert Object", "", "InsertObject", function()
        local Parent = RequireSelection()
        Prompt("Insert object (class name)", "Folder", function(Class)
            local Object = Instance.new(Class)
            Object.Parent = Parent.Object
            Parent.Expanded = true
            Refresh()
            Select(Node(Object, Parent))
        end)
    end},
    {"Save to File", "", "Save", Actions.Save},
    {"View Script", "", "ViewScript", Actions.Source},
    {"Save Bytecode", "", "Save", function()
        local Item = RequireSelection()
        assert(type(getscriptbytecode) == "function" and type(writefile) == "function", "Bytecode export unavailable")
        local Name = Item.Name:gsub("[^%w_%-]", "_"):sub(1, 80) .. ".bin"
        writefile(Name, getscriptbytecode(Item.Object))
        Controller:Status("Saved " .. Name)
    end},
    {"Teleport To", "", "TeleportTo", function()
        local Object = RequireSelection().Object
        local Character = game:GetService("Players").LocalPlayer.Character
        local RootPart = Character and Character:FindFirstChild("HumanoidRootPart")
        assert(RootPart, "Character is unavailable")
        RootPart.CFrame = Read(Object, "CFrame") or Object:GetPivot()
    end},
    {"View Object", "", "Play", function()
        local Object = RequireSelection().Object
        workspace.CurrentCamera.CameraSubject = Object
    end},
    {"Select Character", "", "SelectChildren", function()
        local Player = RequireSelection().Object
        local Character = assert(Read(Player, "Character"), "Select a player with a character")
        Select(Node(Character, Node(workspace, Root)))
    end},
}
Controller.Commands = Commands
Controller.Actions = Actions
local function Invoke(Name)
    CloseMenu()
    for _, Command in Commands do if Command[1] == Name then Run(Command[4]) return end end
end
Controller.Invoke = Invoke

OpenContext = function(Position)
    CloseMenu()
    Position = Position or Pointer() or Vector(0, 0)
    local CurrentSize = View and Read(View, "ViewportSize")
    local AvailableWidth = math.max(CurrentSize and CurrentSize.X or ScreenWidth, Explorer.Position.X + Explorer.Size.X, Properties.Position.X + Properties.Size.X, Position.X + 1)
    local AvailableHeight = math.max(CurrentSize and CurrentSize.Y or ScreenHeight, Explorer.Position.Y + Explorer.Size.Y, Properties.Position.Y + Properties.Size.Y, Position.Y + 1)
    local Item = RequireSelection()
    local Entries = {}
    for _, Command in Commands do
        local Name, Available = Command[1], true
        if Name == "View Script" or Name == "Save Bytecode" then Available = Item.Class:find("Script", 1, true) ~= nil end
        if Name == "Select Character" then Available = Item.Class == "Player" end
        if Name == "Teleport To" or Name == "View Object" then Available = Read(Item.Object, "CFrame") ~= nil or Item.Class == "Model" end
        if Available then Entries[#Entries + 1] = Command end
    end
    local MenuHeight = #Entries * 22 + 4
    local X = Position.X + 250 <= AvailableWidth and Position.X or Position.X - 250
    local Y = Position.Y + MenuHeight <= AvailableHeight and Position.Y or math.max(0, AvailableHeight - MenuHeight)
    Menu = Create("Frame", nil, math.max(0, X), math.max(0, Y), 250, MenuHeight)
    Menu.ZIndex, Menu.Active, Menu.BackgroundColor3 = 9000, true, Rgb(32, 32, 32)
    for Index, Entry in Entries do
        local Button = Create("TextButton", Menu, 2, 2 + (Index - 1) * 22, 246, 22, Entry[1])
        Button.Padding, Button.BackgroundTransparency = 25, 1
        local Shortcut = Create("TextLabel", Button, 157, 0, 87, 22, Entry[2])
        Shortcut.TextColor3 = Theme.Muted
        if Controller.Icon then Controller.Icon(Button, Entry[3], 3, 3) end
        Connect(Button.MouseButton1Click, function() Invoke(Entry[1]) end)
    end
end
Controller.OpenContext = OpenContext

Connect(Input.InputBegan, function(Event)
    if not Controller.Alive then return end
    local Name = Read(Event.KeyCode, "Name")
    if Name == "Escape" then CloseMenu() return end
    if Ui.getfocusedtextbox and Ui.getfocusedtextbox() then return end
    if not Controller.Visible or not Explorer.Visible or not Controller.Selected then return end
    local Ok, Control, Shift = pcall(function()
        return Input:IsKeyDown(Enum.KeyCode.LeftControl) or Input:IsKeyDown(Enum.KeyCode.RightControl),
            Input:IsKeyDown(Enum.KeyCode.LeftShift) or Input:IsKeyDown(Enum.KeyCode.RightShift)
    end)
    if not Ok then return end
    local Shortcut = Control and ({X="Cut", C="Copy", D="Duplicate", G="Group", U="Ungroup", V=Shift and "Paste Into"})[Name]
        or Name == "F2" and "Rename" or Name == "Delete" and (Shift and "Delete Children" or "Delete")
    if Shortcut then Invoke(Shortcut) end
end)

local Stop = Controller.Stop
function Controller:Stop()
    CloseMenu()
    for _, Object in Clipboard do pcall(function() Object:Destroy() end) end
    table.clear(Clipboard)
    Stop(self)
end
Controller.Destroy = Controller.Stop

Environment.VortexExplorer = Controller
task.spawn(function()
    local Ok, Error = pcall(function()
        Controller:Status("Select an instance to inspect its properties")
        local Updated = Clock()
        while Controller.Alive do
            if Controller.SearchAt and Clock() >= Controller.SearchAt then
                Controller.SearchAt = nil
                if Controller.Query == "" then Rebuild()
                else task.spawn(Search, Controller.Query, Controller.SearchVersion) end
            end
            if Controller.Visible then
                if Controller.RefreshAt and Clock() >= Controller.RefreshAt and Controller.Query == "" then
                    Controller.RefreshAt = nil
                    Refresh()
                end
                PaintBars()
                PaintTree()
                local Editing = false
                for _, Slot in Controller.PropertyRows do if Slot.Value:IsFocused() then Editing = true break end end
                if Properties.Visible and not Editing and Clock() - Updated > 1 then RefreshProperties() Updated = Clock() end
                PaintProperties()
            end
            local Delta = task.wait(1 / 60)
            Elapsed += type(Delta) == "number" and math.max(Delta, 1 / 60) or 1 / 60
        end
    end)
    if not Ok and Controller.Alive then Controller:Status(Error) end
end)
return Controller
