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
