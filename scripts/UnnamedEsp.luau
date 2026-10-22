local Environment = _G

if type(getgenv) == "function" then
    local Ok, Value = pcall(getgenv)

    if Ok and type(Value) == "table" then
        Environment = Value
    end
end

local getgenv = function()
    return Environment
end

local task = task or { wait = wait, spawn = spawn, defer = spawn, delay = delay }

assert(
    type(task.wait) == "function" and type(task.spawn) == "function",
    "A scheduler with wait and spawn is required"
)

local MemoryFiles = Environment.VortexClientFiles or {}

Environment.VortexClientFiles = MemoryFiles

local NativeRead, NativeWrite, NativeIsFile = readfile, writefile, isfile

local function readfile(Path)
    if type(NativeRead) == "function" then
        return NativeRead(Path)
    end

    return assert(MemoryFiles[Path], "File not found")
end

local function writefile(Path, Text)
    if type(NativeWrite) == "function" then
        return NativeWrite(Path, Text)
    end

    MemoryFiles[Path] = Text
end

local function isfile(Path)
    if type(NativeIsFile) == "function" then
        return NativeIsFile(Path)
    end

    if MemoryFiles[Path] ~= nil then
        return true
    end

    if type(NativeRead) == "function" then
        return pcall(NativeRead, Path)
    end

    return false
end

local json = type(json) == "table" and json or {}

if type(json.encode) ~= "function" or type(json.decode) ~= "function" then
    json = {}
    json.null = {}

    local function Quote(Text)
        return '"'
            .. Text:gsub('[%z\1-\31\\"]', function(Character)
                local Escapes = {
                    ['"'] = '\\"',
                    ["\\"] = "\\\\",
                    ["\n"] = "\\n",
                    ["\r"] = "\\r",
                    ["\t"] = "\\t",
                }
                return Escapes[Character] or string.format("\\u%04x", string.byte(Character))
            end)
            .. '"'
    end

    function json.encode(Value)
        local Seen = {}

        local function Encode(Item, Depth)
            assert(Depth < 64, "JSON is too deeply nested")

            if Item == nil or Item == json.null then
                return "null"
            end

            if type(Item) == "string" then
                return Quote(Item)
            end

            if type(Item) == "boolean" then
                return tostring(Item)
            end

            if type(Item) == "number" then
                assert(Item == Item and math.abs(Item) < math.huge, "Invalid JSON number")

                return tostring(Item)
            end

            assert(type(Item) == "table" and not Seen[Item], "Invalid JSON value")
            Seen[Item] = true

            local Array, Count = true, 0

            for Key in Item do
                Count += 1

                if type(Key) ~= "number" or Key % 1 ~= 0 or Key < 1 then
                    Array = false
                end
            end

            Array = Array and Count > 0 and Count == #Item

            local Parts = {}

            if Array then
                for _, Entry in Item do
                    Parts[#Parts + 1] = Encode(Entry, Depth + 1)
                end
            else
                for Key, Entry in Item do
                    Parts[#Parts + 1] = Quote(tostring(Key)) .. ":" .. Encode(Entry, Depth + 1)
                end
            end

            Seen[Item] = nil

            return (Array and "[" or "{") .. table.concat(Parts, ",") .. (Array and "]" or "}")
        end

        return Encode(Value, 0)
    end

    function json.decode(Text)
        assert(type(Text) == "string" and #Text <= 1024 * 1024, "Invalid JSON input")

        local Cursor = 1

        local function Space()
            local _, Last = Text:find("^%s*", Cursor)

            Cursor = (Last or Cursor - 1) + 1
        end

        local Parse

        local function String()
            Cursor += 1

            local Parts = {}

            while Cursor <= #Text do
                local Character = Text:sub(Cursor, Cursor)

                Cursor += 1

                if Character == '"' then
                    return table.concat(Parts)
                end

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

                            assert(
                                Low and Low >= 0xDC00 and Low <= 0xDFFF,
                                "Invalid JSON surrogate"
                            )
                            Code = 0x10000 + (Code - 0xD800) * 1024 + Low - 0xDC00
                            Cursor += 6
                        end

                        assert(Code < 0xD800 or Code > 0xDFFF, "Invalid JSON surrogate")
                        Character = utf8.char(Code)
                    else
                        Character = ({
                            ['"'] = '"',
                            ["\\"] = "\\",
                            ["/"] = "/",
                            b = "\b",
                            f = "\f",
                            n = "\n",
                            r = "\r",
                            t = "\t",
                        })[Escape]
                        assert(Character, "Invalid JSON escape")
                    end
                else
                    assert(string.byte(Character) >= 32, "Invalid JSON string")
                end

                Parts[#Parts + 1] = Character
            end

            error("Unclosed JSON string")
        end

        Parse = function(Depth)
            assert(Depth < 64, "JSON is too deeply nested")
            Space()

            local Character = Text:sub(Cursor, Cursor)

            if Character == '"' then
                return String()
            end

            if Character == "{" or Character == "[" then
                Cursor += 1
                Space()

                local Result, Array = {}, Character == "["
                local Close = Array and "]" or "}"

                if Text:sub(Cursor, Cursor) == Close then
                    Cursor += 1

                    return Result
                end

                while true do
                    Space()

                    local Key = #Result + 1

                    if not Array then
                        assert(Text:sub(Cursor, Cursor) == '"', "Expected JSON key")
                        Key = String()
                        Space()
                        assert(Text:sub(Cursor, Cursor) == ":", "Expected colon")
                        Cursor += 1
                    end

                    Result[Key] = Parse(Depth + 1)
                    Space()

                    local Delimiter = Text:sub(Cursor, Cursor)

                    Cursor += 1

                    if Delimiter == Close then
                        return Result
                    end

                    assert(Delimiter == ",", "Expected JSON delimiter")
                end
            end

            for Word, Value in { ["true"] = true, ["false"] = false } do
                if Text:sub(Cursor, Cursor + #Word - 1) == Word then
                    Cursor += #Word

                    return Value
                end
            end

            if Text:sub(Cursor, Cursor + 3) == "null" then
                Cursor += 4

                return json.null
            end

            local Number = Text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", Cursor)
            local Value = Number and tonumber(Number)

            assert(
                Value
                    and Value == Value
                    and math.abs(Value) < math.huge
                    and not Number:match("^-?0%d")
                    and not Number:match("%.$")
                    and not Number:match("%.%D")
                    and not Number:match("[eE][+-]?$"),
                "Invalid JSON value"
            )
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
        local Library = { UiVersion = 8 }
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
        local Boxes = setmetatable({}, { __mode = "k" })
        local Kinds = {
            Frame = true,
            ScrollingFrame = true,
            TextLabel = true,
            TextBox = true,
            TextButton = true,
            Button = true,
            Checkbox = true,
            Slider = true,
            ImageLabel = true,
        }
        local Task
        local Elapsed = 0
        local Clock = os and os.clock
        local NativeNew = Drawing.new
        local function Name(Value)
            return type(Value) == "string" and Value or Value and Value.Name or "Unknown"
        end
        local function Signal()
            local Event = { Listeners = {} }
            function Event:Connect(Callback)
                assert(type(Callback) == "function", "Expected a function")
                local Connection = { Connected = true }
                self.Listeners[Connection] = Callback
                function Connection:Disconnect()
                    self.Connected = false
                    Event.Listeners[self] = nil
                end
                return Connection
            end
            function Event:Fire(...)
                local Arguments = table.pack(...)
                for Connection, Callback in self.Listeners do
                    if Connection.Connected then
                        Task.spawn(function()
                            if not Connection.Connected then
                                return
                            end
                            local Ok, Error =
                                pcall(Callback, table.unpack(Arguments, 1, Arguments.n))
                            if not Ok then
                                warn(Error)
                            end
                        end)
                    end
                end
            end
            return Event
        end
        local function Before(Text, Cursor)
            Cursor = math.max(0, Cursor - 1)
            while
                Cursor > 0
                and string.byte(Text, Cursor + 1) >= 128
                and string.byte(Text, Cursor + 1) < 192
            do
                Cursor -= 1
            end
            return Cursor
        end
        local function After(Text, Cursor)
            Cursor = math.min(#Text, Cursor + 1)
            while
                Cursor < #Text
                and string.byte(Text, Cursor + 1) >= 128
                and string.byte(Text, Cursor + 1) < 192
            do
                Cursor += 1
            end
            return Cursor
        end
        local function CharacterKind(Text, Cursor)
            local Character = Text:sub(Cursor + 1, After(Text, Cursor))
            if Character:match("%s") then
                return "Space"
            end
            if Character:match("[%w_]") or (Character:byte() or 0) >= 128 then
                return "Word"
            end
            return "Punctuation"
        end
        local function WordBefore(Text, Cursor)
            while Cursor > 0 and CharacterKind(Text, Before(Text, Cursor)) == "Space" do
                Cursor = Before(Text, Cursor)
            end
            if Cursor == 0 then
                return 0
            end
            local Kind = CharacterKind(Text, Before(Text, Cursor))
            while Cursor > 0 and CharacterKind(Text, Before(Text, Cursor)) == Kind do
                Cursor = Before(Text, Cursor)
            end
            return Cursor
        end
        local function WordAfter(Text, Cursor)
            while Cursor < #Text and CharacterKind(Text, Cursor) == "Space" do
                Cursor = After(Text, Cursor)
            end
            if Cursor == #Text then
                return Cursor
            end
            local Kind = CharacterKind(Text, Cursor)
            while Cursor < #Text and CharacterKind(Text, Cursor) == Kind do
                Cursor = After(Text, Cursor)
            end
            return Cursor
        end
        local function LineStart(Text, Cursor)
            while Cursor > 0 and Text:sub(Cursor, Cursor) ~= "\n" do
                Cursor = Before(Text, Cursor)
            end
            return Cursor
        end
        local function LineEnd(Text, Cursor)
            return (Text:find("\n", Cursor + 1, true) or (#Text + 1)) - 1
        end
        local function Inside(Point, Bounds)
            return Bounds
                and Point.X >= Bounds.X
                and Point.Y >= Bounds.Y
                and Point.X <= Bounds.X + Bounds.Width
                and Point.Y <= Bounds.Y + Bounds.Height
        end
        local function Bounds(Item, Depth)
            local Cached = Boxes[Item]
            if Cached and Cached.Version == LayoutVersion then
                return Cached.Box
            end
            if Item.Destroyed or not Item.Visible or (Depth or 0) > 64 then
                return nil
            end
            local Position, Size = Item.Position, Item.Size
            local X, Y = Position.X, Position.Y
            if Item.Parent then
                local Parent = Bounds(Item.Parent, (Depth or 0) + 1)
                if not Parent then
                    return nil
                end
                X += Parent.X
                Y += Parent.Y - (Item.Parent.ScrollOffset or 0)
            end
            local Box = { X = X, Y = Y, Width = Size.X, Height = Size.Y }
            Boxes[Item] = { Version = LayoutVersion, Box = Box }
            return Box
        end
        local function CanHit(Item)
            local Parent = Item.Parent
            while Parent do
                if Parent.ClipsDescendants and not Inside(Pointer, Bounds(Parent)) then
                    return false
                end
                Parent = Parent.Parent
            end
            return true
        end
        local function GetLayer(Item)
            local Value, Parent = Item.ZIndex, Item.Parent
            while Parent do
                Value += Parent.ZIndex
                Parent = Parent.Parent
            end
            return math.clamp(Value, -9998, 9998)
        end
        local function Shape(Item, Key, Kind, Values)
            local Entry = Item.Shapes[Key]
            if not Entry then
                Entry = { Object = NativeNew(Kind), Values = {} }
                Item.Shapes[Key] = Entry
            end
            for Property, Value in Values do
                local Previous = Entry.Values[Property]
                local Equal = Previous == Value
                if
                    Previous and (Property == "Position" or Property == "Size" and Kind ~= "Text")
                then
                    Equal = Previous.X == Value.X and Previous.Y == Value.Y
                elseif Previous and Property == "Color" then
                    Equal = Previous.R == Value.R
                        and Previous.G == Value.G
                        and Previous.B == Value.B
                end
                if not Equal then
                    if Property == "Rounding" then
                        pcall(function()
                            Entry.Object[Property] = Value
                        end)
                    else
                        Entry.Object[Property] = Value
                    end
                    Entry.Values[Property] = Value
                end
            end
            local Parent, Clip = Item.Parent, nil
            while Parent do
                if Parent.ClipsDescendants then
                    local Box = Bounds(Parent)
                    if Box then
                        if not Clip then
                            Clip = { X = Box.X, Y = Box.Y, Width = Box.Width, Height = Box.Height }
                        else
                            local Right, Bottom =
                                math.min(Clip.X + Clip.Width, Box.X + Box.Width),
                                math.min(Clip.Y + Clip.Height, Box.Y + Box.Height)
                            Clip.X, Clip.Y = math.max(Clip.X, Box.X), math.max(Clip.Y, Box.Y)
                            Clip.Width, Clip.Height =
                                math.max(0, Right - Clip.X), math.max(0, Bottom - Clip.Y)
                        end
                    end
                end
                Parent = Parent.Parent
            end
            if Kind == "Text" or Key == "Selection" then
                local Own = Bounds(Item)
                if Own and Clip then
                    local Right, Bottom =
                        math.min(Clip.X + Clip.Width, Own.X + Own.Width),
                        math.min(Clip.Y + Clip.Height, Own.Y + Own.Height)
                    Clip.X, Clip.Y = math.max(Clip.X, Own.X), math.max(Clip.Y, Own.Y)
                    Clip.Width, Clip.Height =
                        math.max(0, Right - Clip.X), math.max(0, Bottom - Clip.Y)
                else
                    Clip = Own or Clip
                end
            end
            if Entry.Clipping ~= false then
                local Ok = pcall(function()
                    Entry.Object.Clipping = Clip ~= nil
                    if Clip then
                        Entry.Object.ClipPosition = Vector2.new(Clip.X, Clip.Y)
                        Entry.Object.ClipSize = Vector2.new(Clip.Width, Clip.Height)
                    end
                end)
                Entry.Clipping = Ok
            end
            return Entry.Object
        end
        local function Selection(Item)
            return math.min(Item.Cursor, Item.Anchor), math.max(Item.Cursor, Item.Anchor)
        end
        local function Replace(Item, Text)
            Item.UndoItems[#Item.UndoItems + 1] =
                { Text = Item.Text, Cursor = Item.Cursor, Anchor = Item.Anchor }
            if #Item.UndoItems > 100 then
                table.remove(Item.UndoItems, 1)
            end
            table.clear(Item.RedoItems)
            local First, Last = Selection(Item)
            if not Item.Multiline then
                Text = Text:gsub("[\r\n]+", " ")
            end
            Text = Text:gsub("\r\n", "\n"):gsub("\r", "\n")
            local Limit = math.max(0, Item.MaxLength - (#Item.Text - (Last - First)))
            if #Text > Limit then
                local End = Limit
                while
                    End > 0
                    and string.byte(Text, End + 1)
                    and string.byte(Text, End + 1) >= 128
                    and string.byte(Text, End + 1) < 192
                do
                    End -= 1
                end
                Text = Text:sub(1, End)
            end
            Item.Text = Item.Text:sub(1, First) .. Text .. Item.Text:sub(Last + 1)
            Item.Cursor = First + #Text
            Item.Anchor = Item.Cursor
        end
        local Methods = {}
        function Methods:CaptureFocus()
            assert(
                self.Kind == "TextBox" and self.TextEditable and not self.Destroyed,
                "Expected an editable TextBox"
            )
            if Focus == self then
                return
            end
            if Focus then
                Focus:ReleaseFocus(false)
            end
            Focus = self
            PaintDirty = true
            self.Cursor = #self.Text
            self.Anchor = self.Cursor
            if self.ClearTextOnFocus then
                self.Text = ""
                self.Cursor = 0
                self.Anchor = 0
            end
            self.Focused:Fire()
        end
        function Methods:ReleaseFocus(Submitted)
            if Focus ~= self then
                return
            end
            Focus = nil
            PaintDirty = true
            if Context then
                Context:setcapture(false, false)
            end
            self.FocusLost:Fire(Submitted == true)
        end
        function Methods:IsFocused()
            return Focus == self
        end
        function Methods:GetChildren()
            local Children = {}
            for _, Item in Items do
                if Item.Parent == self and not Item.Destroyed then
                    Children[#Children + 1] = Item
                end
            end
            return Children
        end
        function Methods:GetSelection()
            local First, Last = Selection(self)
            return self.Text:sub(First + 1, Last)
        end
        function Methods:SelectAll()
            self.Anchor = 0
            self.Cursor = #self.Text
        end
        function Methods:InsertText(Text)
            assert(type(Text) == "string", "Expected text")
            Replace(self, Text)
        end
        function Methods:GetPropertyChangedSignal(Property)
            self.ChangedEvents[Property] = self.ChangedEvents[Property] or Signal()
            return self.ChangedEvents[Property]
        end
        function Methods:Destroy()
            if self.Destroyed then
                return
            end
            if Focus == self then
                self:ReleaseFocus(false)
            end
            for _, Child in self:GetChildren() do
                Child:Destroy()
            end
            self.Destroyed = true
            PaintDirty = true
            if Pressed == self then
                Pressed = nil
            end
            if Drag and Drag.Item == self then
                Drag = nil
            end
            for _, Entry in self.Shapes do
                pcall(function()
                    Entry.Object:Remove()
                end)
            end
            for _, Name in
                {
                    "Focused",
                    "FocusLost",
                    "TextChanged",
                    "Changed",
                    "InputBegan",
                    "MouseEnter",
                    "MouseLeave",
                    "MouseButton1Click",
                    "MouseButton1Down",
                    "MouseButton1Up",
                    "MouseButton2Click",
                    "MouseButton2Down",
                    "MouseButton2Up",
                }
            do
                for Connection in self[Name].Listeners do
                    Connection:Disconnect()
                end
            end
            for _, Event in self.ChangedEvents do
                for Connection in Event.Listeners do
                    Connection:Disconnect()
                end
            end
            table.clear(self.Shapes)
            Dirty = true
        end
        Methods.Remove = Methods.Destroy
        local function Key(KeyName, Repeated)
            local Item = Focus
            if not Item or not Item.TextEditable then
                return
            end
            local Control = Keys.Control
            if Control == nil then
                Control = Keys.LeftControl or Keys.RightControl
            end
            local Shift = Keys.Shift
            if Shift == nil then
                Shift = Keys.LeftShift or Keys.RightShift
            end
            local Alt = Keys.Alt
            if Alt == nil then
                Alt = Keys.LeftAlt or Keys.RightAlt
            end
            local Command = Keys.Command
            local Primary = Command or Control
            local Word = Alt or Control
            Item.InputBegan:Fire(KeyName, Primary == true, Shift == true)
            if Primary and (KeyName == "Z" or KeyName == "Y") then
                local Redo = KeyName == "Y" or Shift
                local Source = Redo and Item.RedoItems or Item.UndoItems
                local Destination = Redo and Item.UndoItems or Item.RedoItems
                local State = table.remove(Source)
                if State then
                    Destination[#Destination + 1] =
                        { Text = Item.Text, Cursor = Item.Cursor, Anchor = Item.Anchor }
                    Item.Text = State.Text
                    Item.Cursor = State.Cursor
                    Item.Anchor = State.Anchor
                end
            elseif Primary and KeyName == "A" then
                Item:SelectAll()
            elseif
                Primary and (KeyName == "C" or KeyName == "X" or KeyName == "Insert")
                or Shift and KeyName == "Delete"
            then
                local Text = Item:GetSelection()
                if #Text > 0 and type(setclipboard) == "function" then
                    setclipboard(Text)
                end
                if (KeyName == "X" or KeyName == "Delete") and #Text > 0 then
                    Replace(Item, "")
                end
            elseif KeyName == "Backspace" or KeyName == "Delete" then
                if Item.Cursor == Item.Anchor then
                    if KeyName == "Backspace" then
                        Item.Anchor = Command and LineStart(Item.Text, Item.Cursor)
                            or Word and WordBefore(Item.Text, Item.Cursor)
                            or Before(Item.Text, Item.Cursor)
                    else
                        Item.Anchor = Command and LineEnd(Item.Text, Item.Cursor)
                            or Word and WordAfter(Item.Text, Item.Cursor)
                            or After(Item.Text, Item.Cursor)
                    end
                end
                Replace(Item, "")
            elseif KeyName == "Left" or KeyName == "Right" then
                local Left = KeyName == "Left"
                if Command then
                    Item.Cursor = Left and LineStart(Item.Text, Item.Cursor)
                        or LineEnd(Item.Text, Item.Cursor)
                elseif Word then
                    Item.Cursor = Left and WordBefore(Item.Text, Item.Cursor)
                        or WordAfter(Item.Text, Item.Cursor)
                elseif not Shift and Item.Cursor ~= Item.Anchor then
                    Item.Cursor = Left and math.min(Item.Cursor, Item.Anchor)
                        or math.max(Item.Cursor, Item.Anchor)
                else
                    Item.Cursor = Left and Before(Item.Text, Item.Cursor)
                        or After(Item.Text, Item.Cursor)
                end
                if not Shift then
                    Item.Anchor = Item.Cursor
                end
            elseif
                KeyName == "Home"
                or KeyName == "End"
                or Command and (KeyName == "Up" or KeyName == "Down")
            then
                Item.Cursor = (KeyName == "Home" or KeyName == "Up") and 0 or #Item.Text
                if not Shift then
                    Item.Anchor = Item.Cursor
                end
            elseif KeyName == "Escape" then
                Item:ReleaseFocus(false)
            elseif KeyName == "Return" or KeyName == "Enter" then
                if Item.Multiline and not Primary then
                    Replace(Item, "\n")
                else
                    Item:ReleaseFocus(true)
                end
            end
        end
        local function Caret(Item)
            local Box = Bounds(Item)
            if not Box then
                return Item.Cursor
            end
            local X = Pointer.X - Box.X - Item.Padding + (Item.TextOffset or 0)
            local Start, Finish = 0, #Item.Text
            if Item.Multiline then
                local Row = math.max(0, math.floor((Pointer.Y - Box.Y - 3) / Item.TextSize))
                for _ = 1, Row do
                    local Next = Item.Text:find("\n", Start + 1, true)
                    if not Next then
                        Start = #Item.Text
                        break
                    end
                    Start = Next
                end
                Finish = (Item.Text:find("\n", Start + 1, true) or (#Item.Text + 1)) - 1
            end
            local Stops = { Start }
            local Offset = Start
            while Offset < Finish do
                Offset = After(Item.Text, Offset)
                Stops[#Stops + 1] = Offset
            end
            local Low, High = 1, #Stops
            while Low < High do
                local Middle = math.floor((Low + High) / 2)
                local Measure = Shape(Item, "HitMeasure", "Text", {
                    Visible = false,
                    Text = Item.Text:sub(Start + 1, Stops[Middle]),
                    Font = Item.Font,
                    Size = Item.TextSize,
                })
                if Measure.TextBounds.X < X then
                    Low = Middle + 1
                else
                    High = Middle
                end
            end
            return Stops[Low]
        end
        local function PointerDown(Button)
            local Hit
            for Index = #Items, 1, -1 do
                local Item = Items[Index]
                if Item.Active and Inside(Pointer, Bounds(Item)) and CanHit(Item) then
                    Hit = Item
                    break
                end
            end
            if Focus and Focus ~= Hit then
                Focus:ReleaseFocus(false)
            end
            if Button == 2 then
                Secondary = Hit
                if Hit then
                    Hit.MouseButton2Down:Fire(Pointer)
                end
                return
            end
            Pressed = Hit
            if not Hit then
                return
            end
            Hit.MouseButton1Down:Fire()
            if
                Hit.Kind == "ScrollingFrame"
                and Hit.CanvasSize > Hit.Size.Y
                and Pointer.X >= Bounds(Hit).X + Hit.Size.X - 10
            then
                ScrollDrag = Hit
            elseif Hit.Kind == "Slider" then
                local Box = Bounds(Hit)
                local Inset = Hit.SliderStyle == "Fluent" and 7 or 0
                Hit.Value = Hit.Min
                    + math.clamp(
                            (Pointer.X - Box.X - Inset) / math.max(Box.Width - 2 * Inset, 1),
                            0,
                            1
                        )
                        * (Hit.Max - Hit.Min)
            elseif Hit.Kind == "TextBox" then
                Hit:CaptureFocus()
                Hit.Cursor = Caret(Hit)
                if not Keys.LeftShift and not Keys.RightShift then
                    Hit.Anchor = Hit.Cursor
                end
                Hit.LastPointerX = Pointer.X
            elseif Hit.Draggable then
                local Target = Hit.DragTarget or Hit
                if Library.isui(Target) then
                    Drag = { Item = Target, Offset = Pointer - Target.Position }
                end
            end
        end
        local function PointerUp(Button)
            if Button == 2 then
                local Item = Secondary
                Secondary = nil
                if Item and not Item.Destroyed then
                    Item.MouseButton2Up:Fire(Pointer)
                    if Inside(Pointer, Bounds(Item)) and CanHit(Item) then
                        Item.MouseButton2Click:Fire(Pointer)
                    end
                end
                return
            end
            local Item = Pressed
            Pressed, Drag, ScrollDrag = nil, nil, nil
            if Item and not Item.Destroyed then
                Item.MouseButton1Up:Fire()
                if Inside(Pointer, Bounds(Item)) and CanHit(Item) then
                    if Item.Kind == "Checkbox" then
                        Item.Value = not Item.Value
                    end
                    Item.MouseButton1Click:Fire()
                end
            end
        end
        local Virtual = {
            [8] = "Backspace",
            [9] = "Tab",
            [13] = "Return",
            [16] = "LeftShift",
            [17] = "LeftControl",
            [27] = "Escape",
            [32] = "Space",
            [35] = "End",
            [36] = "Home",
            [37] = "Left",
            [38] = "Up",
            [39] = "Right",
            [40] = "Down",
            [164] = "LeftAlt",
            [165] = "RightAlt",
            [45] = "Insert",
            [46] = "Delete",
            [160] = "LeftShift",
            [161] = "RightShift",
            [162] = "LeftControl",
            [163] = "RightControl",
        }
        for Code = 65, 90 do
            Virtual[Code] = string.char(Code)
        end
        local function Paint(Item)
            local Box = Bounds(Item)
            if not Box then
                for _, Entry in Item.Shapes do
                    if Entry.Values.Visible ~= false then
                        Entry.Object.Visible = false
                        Entry.Values.Visible = false
                    end
                end
                return
            end
            Item.AbsolutePosition = Vector2.new(Box.X, Box.Y)
            Item.AbsoluteSize = Item.Size
            local Layer = GetLayer(Item)
            local Base = {
                Visible = true,
                Position = Item.AbsolutePosition,
                Size = Item.Size,
                Filled = true,
                Color = Item.BackgroundColor3,
                Transparency = 1 - Item.BackgroundTransparency,
                ZIndex = Layer,
                Rounding = Item.CornerRadius,
            }
            if HoverChain[Item] and not Item.Multiline then
                Base.Color = Item.HoverColor3 or Base.Color
                if Item.HoverTransparency ~= nil then
                    Base.Transparency = 1 - Item.HoverTransparency
                end
            end
            local Switch = Item.Kind == "Checkbox" and Item.ToggleStyle == "Switch"
            local Slider = Item.Kind == "Slider" and Item.SliderStyle == "Fluent"
            if
                Item.Kind ~= "TextLabel"
                and Item.Kind ~= "ImageLabel"
                and not Switch
                and not Slider
            then
                Shape(Item, "Background", "Square", Base)
            end
            if Item.BorderSizePixel > 0 then
                Shape(Item, "Border", "Square", {
                    Visible = true,
                    Position = Item.AbsolutePosition,
                    Size = Item.Size,
                    Filled = false,
                    Color = Item.BorderColor3,
                    Transparency = 1 - Item.BorderTransparency,
                    Thickness = Item.BorderSizePixel,
                    Rounding = Item.CornerRadius,
                    ZIndex = Layer + 1,
                })
            elseif Item.Shapes.Border then
                Item.Shapes.Border.Object.Visible = false
                Item.Shapes.Border.Values.Visible = false
            end
            if Switch then
                local Width, Height = math.min(36, Box.Width), math.min(18, Box.Height)
                local X, Y = Box.X + (Box.Width - Width) / 2, Box.Y + (Box.Height - Height) / 2
                Shape(Item, "SwitchTrack", "Square", {
                    Visible = true,
                    Position = Vector2.new(X, Y),
                    Size = Vector2.new(Width, Height),
                    Filled = Item.Value,
                    Color = Item.Value and Item.AccentColor3 or Item.TextColor3,
                    Transparency = Item.Value and 1 or 0.5,
                    Thickness = 1,
                    Rounding = Height / 2,
                    ZIndex = Layer,
                })
                Shape(Item, "SwitchKnob", "Circle", {
                    Visible = true,
                    Position = Vector2.new(X + (Item.Value and Width - 9 or 9), Y + Height / 2),
                    Radius = 5.5,
                    NumSides = 24,
                    Filled = true,
                    Color = Item.Value and Item.KnobColor3 or Item.TextColor3,
                    Transparency = Item.Value and 1 or 0.6,
                    ZIndex = Layer + 1,
                })
            elseif Slider then
                local Fraction = math.clamp(
                    (Item.Value - Item.Min) / math.max(0.00001, Item.Max - Item.Min),
                    0,
                    1
                )
                local Width = math.max(1, Box.Width - 14)
                local X, Y = Box.X + 7, Box.Y + Box.Height / 2
                Shape(Item, "SliderTrack", "Square", {
                    Visible = true,
                    Position = Vector2.new(X, Y - 2),
                    Size = Vector2.new(Width, 4),
                    Filled = true,
                    Color = Item.TextColor3,
                    Transparency = 0.35,
                    Rounding = 2,
                    ZIndex = Layer,
                })
                Shape(Item, "SliderFill", "Square", {
                    Visible = true,
                    Position = Vector2.new(X, Y - 2),
                    Size = Vector2.new(Width * Fraction, 4),
                    Filled = true,
                    Color = Item.AccentColor3,
                    Transparency = 1,
                    Rounding = 2,
                    ZIndex = Layer + 1,
                })
                Shape(Item, "SliderKnob", "Circle", {
                    Visible = true,
                    Position = Vector2.new(X + Width * Fraction, Y),
                    Radius = 6,
                    NumSides = 24,
                    Filled = true,
                    Color = Item.AccentColor3,
                    Transparency = 1,
                    ZIndex = Layer + 2,
                })
            elseif Item.Kind == "ScrollingFrame" then
                local Visible = Item.CanvasSize > Box.Height and Item.ScrollBarThickness > 0
                local Height = math.max(18, Box.Height * Box.Height / math.max(Item.CanvasSize, 1))
                local Offset = Item.ScrollOffset
                    / math.max(1, Item.CanvasSize - Box.Height)
                    * (Box.Height - Height)
                Shape(Item, "ScrollBar", "Square", {
                    Visible = Visible,
                    Position = Vector2.new(
                        Box.X + Box.Width - Item.ScrollBarThickness,
                        Box.Y + Offset
                    ),
                    Size = Vector2.new(Item.ScrollBarThickness, Height),
                    Filled = true,
                    Color = Item.TextColor3,
                    Transparency = 0.35,
                    Rounding = 2,
                    ZIndex = Layer + 10,
                })
            end
            if Item.Kind == "ImageLabel" then
                Shape(Item, "Image", "Image", {
                    Visible = true,
                    Position = Item.AbsolutePosition,
                    Size = Item.Size,
                    Data = Item.Image,
                    Transparency = 1 - Item.BackgroundTransparency,
                    ZIndex = Layer,
                })
            elseif Item.Kind ~= "Frame" and Item.Kind ~= "ScrollingFrame" then
                local Text = Item.Text
                local Offset = 0
                if Item.Kind == "TextBox" and not Item.Multiline then
                    local Measure = Shape(Item, "CaretMeasure", "Text", {
                        Visible = false,
                        Text = Text:sub(1, Item.Cursor),
                        Font = Item.Font,
                        Size = Item.TextSize,
                    })
                    Offset = Focus == Item and (Item.TextOffset or 0) or 0
                    if Measure.TextBounds.X - Offset > Box.Width - 2 * Item.Padding then
                        Offset = math.max(0, Measure.TextBounds.X - Box.Width + 2 * Item.Padding)
                    elseif Measure.TextBounds.X < Offset then
                        Offset = Measure.TextBounds.X
                    end
                    Item.TextOffset = Offset
                end
                if Item.Kind == "Checkbox" and not Switch then
                    Text = (Item.Value and "[x] " or "[ ] ") .. Text
                end
                if Item.Kind == "Slider" and not Slider then
                    Text ..= " " .. string.format("%.2f", Item.Value)
                end
                local Empty = Text == "" and Focus ~= Item
                if Empty then
                    Text = Item.PlaceholderText
                end
                local TextX = Box.X + Item.Padding - Offset
                if Item.TextXAlignment ~= "Left" then
                    local Width = Shape(
                        Item,
                        "AlignMeasure",
                        "Text",
                        { Visible = false, Text = Text, Font = Item.Font, Size = Item.TextSize }
                    ).TextBounds.X
                    TextX = Item.TextXAlignment == "Center" and Box.X + (Box.Width - Width) / 2
                        or Box.X + Box.Width - Width - Item.Padding
                end
                local Label = Shape(Item, "Text", "Text", {
                    Visible = true,
                    Text = Text,
                    Position = Vector2.new(
                        TextX,
                        Box.Y
                            + (
                                Item.Multiline and 3
                                or math.max(0, (Box.Height - Item.TextSize) / 2)
                            )
                    ),
                    Size = Item.TextSize,
                    Color = Empty and Item.PlaceholderColor3 or Item.TextColor3,
                    Transparency = 1 - Item.TextTransparency,
                    Font = Item.Font,
                    ZIndex = Layer + 2,
                    Outline = false,
                })
                for Key, Entry in Item.Shapes do
                    if Key == "Caret" or Key:sub(1, 9) == "Selection" then
                        Entry.Object.Visible = false
                        Entry.Values.Visible = false
                    end
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
                                return Shape(Item, "LineMeasure", "Text", {
                                    Visible = false,
                                    Text = Value,
                                    Font = Item.Font,
                                    Size = Item.TextSize,
                                }).TextBounds.X
                            end
                            if First < Finish + 1 and Last > Start then
                                local Left, Right = math.max(First, Start), math.min(Last, Finish)
                                local X = Box.X
                                    + Item.Padding
                                    + Measure(Item.Text:sub(Start + 1, Left))
                                Used += 1
                                Shape(Item, "Selection" .. Used, "Square", {
                                    Visible = true,
                                    Filled = true,
                                    Position = Vector2.new(X, Y),
                                    Size = Vector2.new(
                                        math.max(2, Measure(Item.Text:sub(Left + 1, Right))),
                                        Item.TextSize
                                    ),
                                    Color = Color3.fromRGB(70, 100, 135),
                                    Transparency = 0.45,
                                    ZIndex = Layer,
                                })
                            end
                            if
                                Item.Cursor >= Start
                                and Item.Cursor <= Finish
                                and math.floor((Clock and Clock() or Elapsed) * 2) % 2 == 0
                            then
                                local X = Box.X
                                    + Item.Padding
                                    + Measure(Item.Text:sub(Start + 1, Item.Cursor))
                                Shape(Item, "Caret", "Line", {
                                    Visible = true,
                                    From = Vector2.new(X, Y),
                                    To = Vector2.new(X, Y + Item.TextSize),
                                    Thickness = 1,
                                    Color = Item.TextColor3,
                                    Transparency = 1,
                                    ZIndex = Layer + 2,
                                })
                            end
                        end
                        if Y > Clip.Y + Clip.Height then
                            break
                        end
                        Start, Row = Finish + 1, Row + 1
                    end
                elseif Focus == Item and Item.Cursor ~= Item.Anchor then
                    local First, Last = Selection(Item)
                    local Measure = Shape(Item, "Measure", "Text", {
                        Visible = false,
                        Text = Item.Text:sub(1, First),
                        Font = Item.Font,
                        Size = Item.TextSize,
                    })
                    local SelectionOffset = Measure.TextBounds.X - Offset
                    local Selected = Shape(Item, "MeasureSelection", "Text", {
                        Visible = false,
                        Text = Item.Text:sub(First + 1, Last),
                        Font = Item.Font,
                        Size = Item.TextSize,
                    })
                    Shape(Item, "Selection", "Square", {
                        Visible = true,
                        Filled = true,
                        Position = Vector2.new(Box.X + Item.Padding + SelectionOffset, Box.Y + 2),
                        Size = Vector2.new(
                            math.max(1, Selected.TextBounds.X),
                            math.max(1, Box.Height - 4)
                        ),
                        Color = Color3.fromRGB(70, 100, 135),
                        Transparency = 0.45,
                        ZIndex = Layer,
                    })
                end
                if
                    Focus == Item
                    and not Item.Multiline
                    and math.floor((Clock and Clock() or Elapsed) * 2) % 2 == 0
                then
                    local Width = Shape(Item, "CaretMeasure", "Text", {
                        Visible = false,
                        Text = Item.Text:sub(1, Item.Cursor),
                        Font = Item.Font,
                        Size = Item.TextSize,
                    }).TextBounds.X
                    local X, Y =
                        Box.X + Item.Padding + Width - Offset,
                        Box.Y + math.max(0, (Box.Height - Item.TextSize) / 2)
                    Shape(Item, "Caret", "Line", {
                        Visible = true,
                        From = Vector2.new(X, Y),
                        To = Vector2.new(X, Y + Item.TextSize),
                        Thickness = 1,
                        Color = Item.TextColor3,
                        Transparency = 1,
                        ZIndex = Layer + 2,
                    })
                end
            end
        end
        function Library.step()
            Elapsed += 1 / 60
            if Dirty then
                table.sort(Items, function(A, B)
                    local Left, Right = GetLayer(A), GetLayer(B)
                    return Left == Right and A.Id < B.Id or Left < Right
                end)
                Dirty = false
            end
            local IsActive = Services and Services.IsActive or iswindowactive
            local Active = type(IsActive) ~= "function" or IsActive()
            if
                type(input) == "table"
                and type(input.isinterfaceactive) == "function"
                and input.isinterfaceactive()
            then
                Active = false
            end
            if not Active and Focus then
                Focus:ReleaseFocus(false)
            end
            if Focus and not Bounds(Focus) then
                Focus:ReleaseFocus(false)
            end
            if not Active then
                table.clear(Keys)
                Pressed, Drag, ScrollDrag = nil, nil, nil
            end
            if Context then
                local Position = Context:getpointer()
                if Position and (Position.X ~= Pointer.X or Position.Y ~= Pointer.Y) then
                    Pointer = Vector2.new(Position.X, Position.Y)
                end
                for _, Event in Context:getevents() do
                    if Event.Type == "KeyDown" or Event.Type == "KeyUp" then
                        for _, Modifier in { "Command", "Control", "Shift", "Alt" } do
                            if Event[Modifier] ~= nil then
                                Keys[Modifier] = Event[Modifier]
                            end
                        end
                    end
                    if Event.Type == "KeyDown" then
                        local KeyName = Virtual[Event.Code] or "Unknown"
                        Keys[KeyName] = true
                        Key(KeyName, Event.Repeat)
                    elseif Event.Type == "KeyUp" then
                        Keys[Virtual[Event.Code] or "Unknown"] = nil
                    elseif Event.Type == "Text" or Event.Type == "Paste" then
                        local Text = Event.Text
                        if Event.Type == "Paste" and type(Context.getpaste) == "function" then
                            Text = Context:getpaste(Event.Code)
                        end
                        if Focus and Text ~= "" then
                            Replace(Focus, Text)
                        end
                    elseif Event.Type == "MouseDown" then
                        if Event.X and Event.Y then
                            Pointer = Vector2.new(Event.X, Event.Y)
                        end
                        PointerDown(Event.Code)
                    elseif Event.Type == "MouseUp" then
                        if Event.X and Event.Y then
                            Pointer = Vector2.new(Event.X, Event.Y)
                        end
                        PointerUp(Event.Code)
                    elseif Event.Type == "Wheel" then
                        for Index = #Items, 1, -1 do
                            local Item = Items[Index]
                            if Item.Kind == "ScrollingFrame" and Inside(Pointer, Bounds(Item)) then
                                Item.ScrollOffset = math.clamp(
                                    Item.ScrollOffset - Event.Delta * 30,
                                    0,
                                    math.max(0, Item.CanvasSize - Item.Size.Y)
                                )
                                break
                            end
                        end
                    end
                end
            elseif Input then
                local Ok, Position = pcall(function()
                    return Input:GetMouseLocation()
                end)
                if Ok then
                    Pointer = Position
                end
            end
            if Drag then
                Drag.Item.Position = Pointer - Drag.Offset
            end
            if ScrollDrag then
                local Box = Bounds(ScrollDrag)
                if Box then
                    local Height = math.max(18, Box.Height * Box.Height / ScrollDrag.CanvasSize)
                    ScrollDrag.ScrollOffset = math.clamp(
                        (Pointer.Y - Box.Y - Height / 2) / math.max(1, Box.Height - Height),
                        0,
                        1
                    ) * math.max(0, ScrollDrag.CanvasSize - Box.Height)
                end
            end
            if
                Pressed
                and Pressed.Kind == "TextBox"
                and (Pressed.LastPointerX ~= Pointer.X or Pressed.LastPointerY ~= Pointer.Y)
            then
                Pressed.Cursor = Caret(Pressed)
                Pressed.LastPointerX, Pressed.LastPointerY = Pointer.X, Pointer.Y
            end
            if Pressed and Pressed.Kind == "Slider" then
                local Box = Bounds(Pressed)
                if Box then
                    local Inset = Pressed.SliderStyle == "Fluent" and 7 or 0
                    Pressed.Value = Pressed.Min
                        + math.clamp(
                                (Pointer.X - Box.X - Inset) / math.max(Box.Width - 2 * Inset, 1),
                                0,
                                1
                            )
                            * (Pressed.Max - Pressed.Min)
                end
            end
            local Blink = Focus and math.floor((Clock and Clock() or Elapsed) * 2) or -1
            if Blink ~= LastBlink then
                LastBlink = Blink
                PaintDirty = true
            end
            local Hovered = HoveredItem
            if
                Pointer.X ~= LastHitX
                or Pointer.Y ~= LastHitY
                or LayoutVersion ~= LastHitVersion
                or Active ~= LastHitActive
            then
                Hovered = nil
                if Active then
                    for Index = #Items, 1, -1 do
                        local Item = Items[Index]
                        if
                            not Item.Destroyed
                            and Item.Active
                            and Inside(Pointer, Bounds(Item))
                            and CanHit(Item)
                        then
                            Hovered = Item
                            break
                        end
                    end
                end
                LastHitX, LastHitY, LastHitVersion, LastHitActive =
                    Pointer.X, Pointer.Y, LayoutVersion, Active
            end
            if Hovered ~= HoveredItem then
                HoveredItem = Hovered
                local Previous = HoverChain
                HoverChain = {}
                local Item = Hovered
                while Item do
                    HoverChain[Item] = true
                    Item = Item.Parent
                end
                for Old in Previous do
                    if not HoverChain[Old] and not Old.Destroyed then
                        Old.MouseLeave:Fire()
                    end
                end
                for New in HoverChain do
                    if not Previous[New] and not New.Destroyed then
                        New.MouseEnter:Fire()
                    end
                end
                PaintDirty = true
            end
            local Repaint = PaintDirty
            PaintDirty = false
            if Repaint then
                for _, Item in Items do
                    if not Item.Destroyed then
                        Paint(Item)
                    end
                end
            end
            if Context then
                local Root = Hovered
                while Root and Root.Parent do
                    Root = Root.Parent
                end
                local Box = Root and Bounds(Root)
                if Box then
                    Context:setregion(Box.X, Box.Y, Box.Width, Box.Height)
                end
                Context:setcapture(
                    Active and Focus ~= nil,
                    Active and (Box ~= nil or Pressed ~= nil)
                )
            end
            for Index = #Items, 1, -1 do
                if Items[Index].Destroyed then
                    table.remove(Items, Index)
                end
            end
            if #Items == 0 then
                Running = false
                if Context then
                    Context:destroy()
                    Context = nil
                end
                for _, Connection in Connections do
                    Connection:Disconnect()
                end
                table.clear(Connections)
            end
        end
        local function Start()
            if Running then
                return
            end
            Task = task or { spawn = spawn, wait = wait }
            Running = true
            Input = Services and Services.Input or game:GetService("UserInputService")
            if type(input) == "table" and type(input.createcontext) == "function" then
                Context = input.createcontext()
            end
            Connections[#Connections + 1] = Input.InputBegan:Connect(function(Event)
                local KeyName, Kind = Name(Event.KeyCode), Name(Event.UserInputType)
                if not Context then
                    Keys[KeyName] = true
                    if Kind == "MouseButton1" or Kind == "MouseButton2" then
                        PointerDown(Kind == "MouseButton2" and 2 or 1)
                    else
                        Key(KeyName)
                        local Control = Keys.LeftControl or Keys.RightControl
                        if Focus and not Control then
                            local Character = #KeyName == 1 and KeyName:lower()
                                or KeyName == "Space" and " "
                                or nil
                            if Character then
                                Replace(
                                    Focus,
                                    (Keys.LeftShift or Keys.RightShift) and Character:upper()
                                        or Character
                                )
                            end
                        elseif
                            Focus
                            and Control
                            and KeyName == "V"
                            and type(getclipboard) == "function"
                        then
                            Replace(Focus, getclipboard())
                        end
                    end
                end
            end)
            Connections[#Connections + 1] = Input.InputEnded:Connect(function(Event)
                Keys[Name(Event.KeyCode)] = nil
                if not Context then
                    local Kind = Name(Event.UserInputType)
                    if Kind == "MouseButton1" or Kind == "MouseButton2" then
                        PointerUp(Kind == "MouseButton2" and 2 or 1)
                    end
                end
            end)
            if not Services or Services.Automatic ~= false then
                Task.spawn(function()
                    while Running do
                        Task.wait(
                            (type(iswindowactive) ~= "function" or iswindowactive()) and 0 or 0.1
                        )
                        local Ok, Error = pcall(Library.step)
                        if not Ok then
                            warn(Error)
                            Running = false
                            Library.destroyui()
                        end
                    end
                end)
            end
        end
        function Library.create(Kind, Properties)
            assert(Kinds[Kind], "Unsupported UI control: " .. tostring(Kind))
            if #Items >= 512 then
                for Index = #Items, 1, -1 do
                    if Items[Index].Destroyed then
                        table.remove(Items, Index)
                    end
                end
            end
            assert(#Items < 512, "UI control limit reached")
            NextId += 1
            local Data = {
                Kind = Kind,
                Id = NextId,
                Position = Vector2.new(0, 0),
                Size = Vector2.new(200, 30),
                Visible = true,
                Active = true,
                ZIndex = 1000,
                BackgroundColor3 = Color3.fromRGB(28, 28, 30),
                BackgroundTransparency = 0,
                TextColor3 = Color3.fromRGB(235, 235, 238),
                PlaceholderColor3 = Color3.fromRGB(130, 130, 138),
                Text = "",
                PlaceholderText = "",
                TextSize = 16,
                Font = Drawing.Fonts.Monospace or 3,
                Padding = 6,
                MaxLength = 65536,
                TextEditable = true,
                ClearTextOnFocus = false,
                Cursor = 0,
                Anchor = 0,
                Value = false,
                Min = 0,
                Max = 100,
                Multiline = false,
                Draggable = false,
                ClipsDescendants = false,
                ScrollOffset = 0,
                CanvasSize = 0,
                CornerRadius = 0,
                TextXAlignment = "Left",
                TextTransparency = 0,
                BorderSizePixel = 0,
                BorderColor3 = Color3.fromRGB(70, 70, 75),
                BorderTransparency = 0,
                AccentColor3 = Color3.fromRGB(96, 205, 255),
                KnobColor3 = Color3.fromRGB(20, 25, 32),
                ScrollBarThickness = 3,
                Shapes = {},
                ChangedEvents = {},
                UndoItems = {},
                RedoItems = {},
                Destroyed = false,
            }
            if Kind == "Slider" then
                Data.Value = 0
            end
            for _, Event in
                {
                    "Focused",
                    "FocusLost",
                    "TextChanged",
                    "Changed",
                    "InputBegan",
                    "MouseEnter",
                    "MouseLeave",
                    "MouseButton1Click",
                    "MouseButton1Down",
                    "MouseButton1Up",
                    "MouseButton2Click",
                    "MouseButton2Down",
                    "MouseButton2Up",
                }
            do
                Data[Event] = Signal()
            end
            local Object
            Object = setmetatable({}, {
                __index = function(_, Key)
                    return Methods[Key] or Data[Key]
                end,
                __newindex = function(_, Key, Value)
                    assert(not Data.Destroyed or Key == "Destroyed", "UI control was destroyed")
                    if Key == "Parent" then
                        local Parent, Depth = Value, 0
                        while Parent do
                            assert(
                                Parent ~= Object and Library.isui(Parent) and Depth < 64,
                                "Invalid UI parent"
                            )
                            Parent = Parent.Parent
                            Depth += 1
                        end
                    elseif Key == "Text" then
                        assert(type(Value) == "string" and #Value <= 65536, "Invalid text")
                    elseif Key == "Position" or Key == "Size" then
                        assert(
                            Value
                                and type(Value.X) == "number"
                                and type(Value.Y) == "number"
                                and Value.X == Value.X
                                and Value.Y == Value.Y
                                and math.abs(Value.X) <= 65536
                                and math.abs(Value.Y) <= 65536,
                            "Invalid UI bounds"
                        )
                    elseif Key == "MaxLength" then
                        assert(
                            type(Value) == "number" and Value >= 0 and Value <= 65536,
                            "Invalid text limit"
                        )
                    end
                    if
                        Key == "ZIndex"
                        or Key == "TextSize"
                        or Key == "Padding"
                        or Key == "Font"
                        or Key == "Cursor"
                        or Key == "Anchor"
                        or Key == "CanvasSize"
                        or Key == "ScrollOffset"
                        or Key == "Min"
                        or Key == "Max"
                        or Key == "CornerRadius"
                        or Key == "BorderSizePixel"
                        or Key == "ScrollBarThickness"
                    then
                        assert(
                            type(Value) == "number" and Value == Value and math.abs(Value) <= 65536,
                            "Invalid UI number"
                        )
                    elseif
                        Key == "BackgroundTransparency"
                        or Key == "HoverTransparency"
                        or Key == "BorderTransparency"
                        or Key == "TextTransparency"
                    then
                        assert(
                            type(Value) == "number" and Value >= 0 and Value <= 1,
                            "Invalid transparency"
                        )
                    elseif
                        Key == "TextColor3"
                        or Key == "BackgroundColor3"
                        or Key == "PlaceholderColor3"
                        or Key == "HoverColor3"
                        or Key == "BorderColor3"
                        or Key == "AccentColor3"
                        or Key == "KnobColor3"
                    then
                        assert(
                            Value
                                and type(Value.R) == "number"
                                and type(Value.G) == "number"
                                and type(Value.B) == "number",
                            "Invalid UI color"
                        )
                    end
                    if Key == "TextSize" then
                        assert(Value >= 1 and Value <= 10000, "Invalid text size")
                    end
                    if Key == "Value" and Data.Kind == "Slider" then
                        assert(
                            type(Value) == "number" and Value == Value and math.abs(Value) <= 65536,
                            "Invalid slider value"
                        )
                    end
                    if Data[Key] == Value then
                        return
                    end
                    if
                        (Key == "Position" or Key == "Size")
                        and Data[Key]
                        and Data[Key].X == Value.X
                        and Data[Key].Y == Value.Y
                    then
                        return
                    end
                    if
                        Key == "Position"
                        or Key == "Size"
                        or Key == "Visible"
                        or Key == "Parent"
                        or Key == "ScrollOffset"
                        or Key == "Destroyed"
                        or Key == "Active"
                        or Key == "ZIndex"
                        or Key == "ClipsDescendants"
                    then
                        LayoutVersion += 1
                    end
                    if
                        Key ~= "AbsolutePosition"
                        and Key ~= "AbsoluteSize"
                        and Key ~= "TextOffset"
                        and Key ~= "LastPointerX"
                    then
                        PaintDirty = true
                    end
                    Data[Key] = Value
                    if Key == "Text" then
                        Data.Cursor = math.min(Data.Cursor, #Value)
                        Data.Anchor = math.min(Data.Anchor, #Value)
                        Data.TextChanged:Fire(Value)
                    end
                    if Key == "ZIndex" or Key == "Parent" then
                        Dirty = true
                    end
                    if Data.ChangedEvents[Key] then
                        Data.ChangedEvents[Key]:Fire()
                    end
                    Data.Changed:Fire(Key)
                end,
            })
            if Properties then
                for Key, Value in Properties do
                    Object[Key] = Value
                end
            end
            Items[#Items + 1] = Object
            LayoutVersion += 1
            Dirty = true
            PaintDirty = true
            Start()
            return Object
        end
        function Library.isui(Object)
            for _, Item in Items do
                if Item == Object then
                    return not Item.Destroyed
                end
            end
            return false
        end
        function Library.getfocusedtextbox()
            return Focus
        end
        function Library.getpointer()
            return Pointer
        end
        function Library.newcontext()
            return CreateLibrary(Drawing, Services)
        end
        function Library.destroyui()
            for _, Item in Items do
                Item:Destroy()
            end
            Library.step()
        end
        return Library
    end
    return CreateLibrary
end)()

local Runtime = (function()
    local Runtime = {
        NeedsProjection = true,
        Tick = 0,
        Foreground = true,
        Order = {},
        OrderDirty = false,
        Alive = true,
        Objects = {},
        Connections = {},
        Jobs = {},
        Bindings = {},
        Elapsed = 0,
        Errors = {},
        Queue = {},
    }
    local NativePlayers = game:GetService("Players")
    local NativeInput = game:GetService("UserInputService")
    local NativeColor = Color3
    local NativeCamera = function()
        return workspace.CurrentCamera
    end
    local Clock = os and os.clock
    local NativeDraw = Drawing
    local UiLibrary
    function Runtime.Control(Kind, Properties)
        for _, Create in { NativeDraw.create, NativeDraw.new } do
            if type(Create) == "function" then
                local Ok, Control = pcall(Create, Kind, Properties)
                if Ok and Control then
                    local Compatible = pcall(function()
                        for Name, Value in Properties or {} do
                            Control[Name] = Value
                        end
                        if Kind == "TextBox" then
                            assert(
                                Control.FocusLost
                                    and Control.InputBegan
                                    and type(Control.CaptureFocus) == "function"
                                    and type(Control.ReleaseFocus) == "function"
                                    and type(Control.IsFocused) == "function"
                            )
                        elseif Kind == "Button" or Kind == "TextButton" then
                            assert(Control.MouseButton1Click)
                        end
                    end)
                    if Compatible then
                        Runtime.Objects[#Runtime.Objects + 1] = Control
                        return Control
                    end
                    pcall(function()
                        Control:Destroy()
                    end)
                end
            end
        end
        UiLibrary = UiLibrary or CreateUiLibrary(NativeDraw)
        local Control = UiLibrary.create(Kind, Properties)
        Runtime.Objects[#Runtime.Objects + 1] = Control
        return Control
    end
    local InputState = { Buttons = {}, Keys = {}, Position = Vector2.new(0, 0) }
    local KeyEnums = {}
    for _, Key in Enum.KeyCode:GetEnumItems() do
        KeyEnums[Key.Name] = Key
    end
    Runtime.Keys = KeyEnums
    local function Read(Object, Name)
        local Success, Value = pcall(function()
            return Object[Name]
        end)
        if Success then
            return Value
        end
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
        if not Values[1] then
            Runtime.Report(Name, Values[2])
        end
        return table.unpack(Values, 1, Values.n)
    end

    function Runtime.Defer(Callback, ...)
        if #Runtime.Queue >= 256 then
            return false
        end
        Runtime.Queue[#Runtime.Queue + 1] = { Callback = Callback, Arguments = table.pack(...) }
        return true
    end

    function Runtime.Signal()
        local Signal = { Listeners = {} }
        function Signal:Connect(Callback)
            assert(type(Callback) == "function", "Callback expected")
            local Connection = { Connected = true, Callback = Callback }
            function Connection:Disconnect()
                self.Connected = false
            end
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
                if not Connection.Connected then
                    table.remove(self.Listeners, Index)
                else
                    Runtime.Defer(function()
                        if Connection.Connected then
                            Connection.Callback(table.unpack(Arguments, 1, Arguments.n))
                        end
                    end)
                end
            end
        end
        function Signal:Wait()
            local Received, Arguments = false, nil
            local Connection = self:Once(function(...)
                Arguments = table.pack(...)
                Received = true
            end)
            while Runtime.Alive and not Received do
                task.wait()
            end
            Connection:Disconnect()
            if Arguments then
                return table.unpack(Arguments, 1, Arguments.n)
            end
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
            for Key, Value in Properties do
                Object[Key] = Value
            end
        end
        return Object
    end

    function Runtime.Stop()
        if not Runtime.Alive then
            return
        end
        Runtime.Alive = false
        if Runtime.InputContext then
            pcall(function()
                Runtime.InputContext:destroy()
            end)
        end
        for _, Connection in Runtime.Connections do
            pcall(function()
                Connection:Disconnect()
            end)
        end
        for _, Object in Runtime.Objects do
            pcall(function()
                Object:Remove()
            end)
        end
        for _, Job in Runtime.Jobs do
            if Job.Cancel then
                pcall(Job.Cancel)
            end
        end
        table.clear(Runtime.Queue)
        table.clear(Runtime.Bindings)
        table.clear(Runtime.Objects)
    end

    function Runtime.Step(Name, Priority, Callback)
        local Binding = { Name = Name, Priority = Priority, Callback = Callback }
        Runtime.Bindings[Name] = Binding
        Runtime.Order[#Runtime.Order + 1] = Binding
        Runtime.OrderDirty = true
    end

    local function KeyName(Item)
        if type(Item) == "string" then
            return Item:match("([^%.]+)$")
        end
        local Name = Read(Item, "Name")
        return Name or tostring(Item):match("([^%.]+)$")
    end
    Runtime.KeyName = KeyName

    Runtime.Input = {
        InputBegan = Runtime.Signal(),
        InputEnded = Runtime.Signal(),
        InputChanged = Runtime.Signal(),
        TextInput = Runtime.Signal(),
        PasteInput = Runtime.Signal(),
        KeyboardEnabled = true,
        MouseEnabled = true,
    }
    function Runtime.Input:IsKeyDown(Key)
        if Runtime.InterfaceActive then
            return false
        end
        if not Runtime.Foreground then
            return false
        end
        local Success, Value = pcall(function()
            return NativeInput:IsKeyDown(Key)
        end)
        return Success and Value == true or InputState.Keys[KeyName(Key)] == true
    end
    function Runtime.Input:IsMouseButtonPressed(Button)
        if Runtime.InterfaceActive then
            return false
        end
        return InputState.Buttons[Button] == true
    end
    function Runtime.Input:GetMouseLocation()
        if Runtime.PointerTick == Runtime.Tick then
            return InputState.Position
        end
        Runtime.PointerTick = Runtime.Tick
        if Runtime.InputContext then
            local Value = Runtime.InputContext:getpointer()
            if Value then
                InputState.Position = Vector2.new(Value.X, Value.Y)
                return InputState.Position
            end
        end
        local Success, Value = pcall(function()
            return NativeInput:GetMouseLocation()
        end)
        if Success and Value then
            InputState.Position = Vector2.new(Value.X, Value.Y)
        end
        return InputState.Position
    end
    function Runtime.Input:GetFocusedTextBox()
        return nil
    end

    local function Deliver(Input, Processed, Began)
        local Kind = KeyName(Read(Input, "UserInputType"))
        local Key = KeyName(Read(Input, "KeyCode"))
        if Key then
            InputState.Keys[Key] = Began
        end
        if Kind == "MouseButton1" then
            InputState.Buttons[1] = Began
        end
        if Kind == "MouseButton2" then
            InputState.Buttons[2] = Began
        end
        if Kind == "MouseButton3" then
            InputState.Buttons[3] = Began
        end
        Runtime.Defer(function()
            if
                Runtime.InterfaceActive
                or type(iswindowactive) == "function" and not iswindowactive()
            then
                return
            end
            local Signal = Began and Runtime.Input.InputBegan or Runtime.Input.InputEnded
            Signal:Fire(Input, Processed)
        end)
    end
    Runtime.Connect(NativeInput.InputBegan, function(Input, Processed)
        Deliver(Input, Processed, true)
    end)
    Runtime.Connect(NativeInput.InputEnded, function(Input, Processed)
        Deliver(Input, Processed, false)
    end)
    if NativeInput.InputChanged and type(NativeInput.InputChanged.Connect) == "function" then
        Runtime.Connect(NativeInput.InputChanged, function(Input, Processed)
            Runtime.Defer(function()
                Runtime.Input.InputChanged:Fire(Input, Processed)
            end)
        end)
    end

    local InputLibrary
    pcall(function()
        InputLibrary = input
    end)
    if type(InputLibrary) == "table" and type(InputLibrary.createcontext) == "function" then
        Runtime.InputContext = InputLibrary.createcontext()
    end
    function Runtime.Capture(Keyboard, Region)
        if not Runtime.InputContext then
            return false
        end
        if Runtime.InterfaceActive then
            Keyboard = false
            Region = nil
        end
        if Region then
            Runtime.InputContext:setregion(Region.X, Region.Y, Region.Width, Region.Height)
        end
        Runtime.InputContext:setcapture(Keyboard == true, Region ~= nil)
        return true
    end
    local VirtualKeys = {
        [8] = "Backspace",
        [9] = "Tab",
        [13] = "Return",
        [16] = "LeftShift",
        [17] = "LeftControl",
        [18] = "LeftAlt",
        [27] = "Escape",
        [32] = "Space",
        [33] = "PageUp",
        [34] = "PageDown",
        [35] = "End",
        [36] = "Home",
        [37] = "Left",
        [38] = "Up",
        [39] = "Right",
        [40] = "Down",
        [46] = "Delete",
        [160] = "LeftShift",
        [161] = "RightShift",
        [162] = "LeftControl",
        [163] = "RightControl",
        [186] = "Semicolon",
        [187] = "Equals",
        [188] = "Comma",
        [189] = "Minus",
        [190] = "Period",
        [191] = "Slash",
        [192] = "Backquote",
        [219] = "LeftBracket",
        [220] = "BackSlash",
        [221] = "RightBracket",
        [222] = "Quote",
    }
    for Code = 65, 90 do
        VirtualKeys[Code] = string.char(Code)
    end
    for Index, Name in
        { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
    do
        VirtualKeys[47 + Index] = Name
    end
    for Index = 1, 24 do
        VirtualKeys[111 + Index] = "F" .. Index
    end
    local function CapturedEvents()
        if not Runtime.InputContext then
            return
        end
        Runtime.InterfaceActive = type(InputLibrary.isinterfaceactive) == "function"
            and InputLibrary.isinterfaceactive()
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
            if Event.Type == "Text" then
                Runtime.Input.TextInput:Fire(Event.Text)
            elseif Event.Type == "Paste" then
                Runtime.Input.PasteInput:Fire(Event.Text)
            elseif Event.Type == "KeyDown" or Event.Type == "KeyUp" then
                local Name = VirtualKeys[Event.Code] or "Unknown"
                local Down = Event.Type == "KeyDown"
                InputState.Keys[Name] = Down
                local Signal = Down and Runtime.Input.InputBegan or Runtime.Input.InputEnded
                Signal:Fire({
                    KeyCode = KeyEnums[Name] or { Name = Name },
                    UserInputType = { Name = "Keyboard" },
                    Captured = true,
                    Repeated = Event.Repeat,
                }, false)
            elseif Event.Type == "MouseDown" or Event.Type == "MouseUp" then
                local Down = Event.Type == "MouseDown"
                InputState.Buttons[Event.Code] = Down
                local Signal = Down and Runtime.Input.InputBegan or Runtime.Input.InputEnded
                Signal:Fire({
                    KeyCode = Enum.KeyCode.Unknown,
                    UserInputType = { Name = "MouseButton" .. Event.Code },
                    Captured = true,
                }, false)
            elseif Event.Type == "Wheel" then
                Runtime.Input.InputChanged:Fire({
                    UserInputType = { Name = "MouseWheel" },
                    Position = { Z = Event.Delta },
                    Captured = true,
                }, false)
            elseif Event.Type == "MouseMove" then
                Runtime.Input.InputChanged:Fire({
                    UserInputType = { Name = "MouseMovement" },
                    Position = InputState.Position,
                    Captured = true,
                }, false)
            end
        end
    end

    local function Dot(A, B)
        return A.X * B.X + A.Y * B.Y + A.Z * B.Z
    end
    local function Unit(Value)
        local Length = math.sqrt(Dot(Value, Value))
        if Length < 0.000001 then
            return nil
        end
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
            Calibration = {
                Width = Size.X,
                Height = Size.Y,
                Aspect = Dot(Top.Direction, Up) / Dot(Top.Direction, Forward) / TangentX,
            }
            Runtime.Calibration = Calibration
        end
        local TangentY = TangentX * Calibration.Aspect
        assert(TangentX > 0 and TangentY > 0, "Invalid camera projection")
        return {
            Origin = Frame.Position,
            Forward = Forward,
            Right = Right,
            Up = Up,
            Width = Size.X,
            Height = Size.Y,
            ScaleX = Size.X / (2 * TangentX),
            ScaleY = Size.Y / (2 * TangentY),
        }
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
        if X ~= X or Y ~= Y or Depth ~= Depth then
            return rawget(Vector3, "new")(0, 0, -1), false
        end
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
        local Scale =
            math.max(1, math.abs(X) / math.max(1, HalfX), math.abs(Y) / math.max(1, HalfY))
        return Vector2.new(HalfX + X / Scale, HalfY + Y / Scale)
    end

    local CameraSignals = {}
    Runtime.Camera = setmetatable({}, {
        __index = function(_, Name)
            if Name == "WorldToViewportPoint" or Name == "WorldToScreenPoint" then
                return function(_, Position)
                    return Runtime.Project(Position)
                end
            end
            if Name == "Parent" then
                return workspace
            end
            if Name == "GetPropertyChangedSignal" then
                return function(_, Property)
                    CameraSignals[Property] = CameraSignals[Property] or Runtime.Signal()
                    return CameraSignals[Property]
                end
            end
            return NativeCamera()[Name]
        end,
        __newindex = function()
            error("Vortex does not expose writable camera controls")
        end,
    })

    local RootCache = setmetatable({}, { __mode = "k" })
    local CharacterCache = setmetatable({}, { __mode = "k" })
    local PlayerCache = setmetatable({}, { __mode = "k" })
    local function AdaptRoot(Root)
        if not Root then
            return nil
        end
        if RootCache[Root] then
            return RootCache[Root]
        end
        local Proxy = setmetatable({ _char = rawget(Root, "_char"), _id = rawget(Root, "_id") }, {
            __index = function(_, Name)
                if Name == "GetRenderCFrame" then
                    return function()
                        return Root.CFrame
                    end
                end
                return Root[Name]
            end,
            __newindex = function(_, Name, Value)
                Root[Name] = Value
            end,
        })
        RootCache[Root] = Proxy
        return Proxy
    end
    function Runtime.Character(Character)
        if not Character then
            return nil
        end
        if CharacterCache[Character] then
            return CharacterCache[Character]
        end
        local function Child(Name)
            if Name == "Humanoid" then
                return Character.Humanoid
            end
            if Name == "HumanoidRootPart" then
                return AdaptRoot(Character.HumanoidRootPart)
            end
            if Name == "Head" then
                return Character:FindFirstChild("Head") or Character:FindFirstChild("Head Hitbox")
            end
            return Character:FindFirstChild(Name)
        end
        local Proxy = setmetatable({ _id = rawget(Character, "_id") }, {
            __index = function(_, Name)
                if Name == "FindFirstChild" then
                    return function(_, Value)
                        return Child(Value)
                    end
                end
                if Name == "FindFirstChildOfClass" or Name == "FindFirstChildWhichIsA" then
                    return function(_, Class)
                        if Class == "Humanoid" then
                            return Character.Humanoid
                        end
                        for _, Item in Character:GetChildren() do
                            if Item:IsA(Class) then
                                return Item
                            end
                        end
                    end
                end
                if Name == "Head" or Name == "HumanoidRootPart" or Name == "Humanoid" then
                    return Child(Name)
                end
                local Value = Character[Name]
                if type(Value) == "function" then
                    return function(_, ...)
                        return Value(Character, ...)
                    end
                end
                return Value
            end,
            __newindex = function(_, Name, Value)
                Character[Name] = Value
            end,
        })
        CharacterCache[Character] = Proxy
        return Proxy
    end
    function Runtime.Player(Player)
        if not Player then
            return nil
        end
        if PlayerCache[Player] then
            return PlayerCache[Player]
        end
        local Proxy = setmetatable({ _id = rawget(Player, "_id") }, {
            __index = function(_, Name)
                if Name == "Character" then
                    return Runtime.Character(Player.Character)
                end
                local Value = Player[Name]
                if type(Value) == "function" then
                    return function(_, ...)
                        return Value(Player, ...)
                    end
                end
                return Value
            end,
            __newindex = function(_, Name, Value)
                Player[Name] = Value
            end,
        })
        PlayerCache[Player] = Proxy
        return Proxy
    end
    Runtime.Players = setmetatable({}, {
        __index = function(_, Name)
            if Name == "LocalPlayer" then
                return Runtime.Player(NativePlayers.LocalPlayer)
            end
            if Name == "GetPlayers" or Name == "GetChildren" then
                return function()
                    local Result = {}
                    for _, Player in NativePlayers:GetPlayers() do
                        Result[#Result + 1] = Runtime.Player(Player)
                    end
                    return Result
                end
            end
            if Name == "FindFirstChild" then
                return function(_, Search)
                    for _, Player in NativePlayers:GetPlayers() do
                        if Player.Name == Search then
                            return Runtime.Player(Player)
                        end
                    end
                end
            end
            return NativePlayers[Name]
        end,
    })

    function Runtime.Team(Player)
        local Team = Read(Player, "Team")
        if Team ~= nil then
            return Team
        end
        local Character = Read(Player, "Character")
        if Character and Read(Character, "GetAttribute") then
            local Success, Value = pcall(function()
                return Character:GetAttribute("Team")
            end)
            if Success then
                return Value
            end
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
            if Maximum == Value.R then
                Hue = ((Value.G - Value.B) / Difference) % 6
            elseif Maximum == Value.G then
                Hue = (Value.B - Value.R) / Difference + 2
            else
                Hue = (Value.R - Value.G) / Difference + 4
            end
        end
        return Hue / 6, Maximum == 0 and 0 or Difference / Maximum, Maximum
    end
    function Runtime.Color.new(R, G, B)
        local Value = NativeColor.new(R or 0, G or 0, B or 0)
        if type(Value) == "table" then
            rawset(Value, "ToHSV", Runtime.Color.ToHSV)
            rawset(Value, "toHSV", Runtime.Color.ToHSV)
        end
        return Value
    end
    function Runtime.Color.fromRGB(R, G, B)
        return Runtime.Color.new(R / 255, G / 255, B / 255)
    end
    function Runtime.Color.fromHex(Hex)
        Hex = Hex:gsub("#", "")
        assert(Hex:match("^%x%x%x%x%x%x$"), "Invalid color")
        return Runtime.Color.fromRGB(
            tonumber(Hex:sub(1, 2), 16),
            tonumber(Hex:sub(3, 4), 16),
            tonumber(Hex:sub(5, 6), 16)
        )
    end
    function Runtime.Color.fromHSV(H, S, V)
        H = (H % 1) * 6
        S, V = math.clamp(S, 0, 1), math.clamp(V, 0, 1)
        local C = V * S
        local X = C * (1 - math.abs(H % 2 - 1))
        local M = V - C
        local Colors =
            { { C, X, 0 }, { X, C, 0 }, { 0, C, X }, { 0, X, C }, { X, 0, C }, { C, 0, X } }
        local Value = Colors[math.floor(H) + 1]
        return Runtime.Color.new(Value[1] + M, Value[2] + M, Value[3] + M)
    end

    Runtime.Values = {}
    function Runtime.Value(Initial)
        local Value = Initial or 0
        local Changed = Runtime.Signal()
        return setmetatable({}, {
            __index = function(_, Name)
                if Name == "Value" then
                    return Value
                end
                if Name == "Changed" then
                    return Changed
                end
                if Name == "GetPropertyChangedSignal" then
                    return function()
                        return Changed
                    end
                end
                if Name == "Destroy" then
                    return function()
                        table.clear(Changed.Listeners)
                    end
                end
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
        local Tween = { Completed = Runtime.Signal(), Cancelled = false, Started = false }
        function Tween:Cancel()
            self.Cancelled = true
        end
        function Tween:Play()
            if self.Started then
                return
            end
            self.Started = true
            local Start = Runtime.Time()
            local Initial = {}
            for Name in Properties do
                Initial[Name] = Object[Name]
            end
            local Name = "Tween" .. tostring(self)
            Runtime.Step(Name, 400, function()
                if self.Cancelled then
                    Runtime.Bindings[Name] = nil
                    return
                end
                local Progress =
                    math.clamp((Runtime.Time() - Start) / math.max(Info.Time or 0.5, 0.001), 0, 1)
                local Ease = 1 - (1 - Progress) ^ 4
                for Property, Target in Properties do
                    Object[Property] = Initial[Property] + (Target - Initial[Property]) * Ease
                end
                if Progress == 1 then
                    Runtime.Bindings[Name] = nil
                    self.Completed:Fire()
                end
            end)
        end
        return Tween
    end

    Runtime.RunService = {}
    function Runtime.RunService:BindToRenderStep(Name, Priority, Callback)
        Runtime.Step(Name, Priority, Callback)
    end
    function Runtime.RunService:UnbindFromRenderStep(Name)
        Runtime.Bindings[Name] = nil
    end
    Runtime.RunService.Heartbeat = Runtime.Signal()
    Runtime.RunService.RenderStepped = Runtime.Signal()

    function Runtime.Start()
        if Runtime.Started then
            return
        end
        Runtime.Started = true
        task.spawn(function()
            local Width, Height = 0, 0
            while Runtime.Alive do
                local Foreground = type(iswindowactive) ~= "function" or iswindowactive()
                Runtime.Foreground = Foreground
                local Delta = task.wait(Foreground and 0 or 0.1)
                Runtime.Tick += 1
                if not Runtime.Alive then
                    break
                end
                Runtime.Elapsed += type(Delta) == "number" and math.clamp(Delta, 0.001, 1) or 1 / 60
                local WorkStarted = Runtime.Time()
                CapturedEvents()
                local Frame = type(NativeDraw.beginframe) == "function" and NativeDraw.beginframe()
                    or nil
                local Pending = Runtime.Queue
                Runtime.Queue = {}
                for _, Item in Pending do
                    Runtime.Try(
                        "Input",
                        Item.Callback,
                        table.unpack(Item.Arguments, 1, Item.Arguments.n)
                    )
                end
                local Project = Runtime.NeedsProjection
                if type(Project) == "function" then
                    Project = Project()
                end
                local Success, View
                if Project then
                    Success, View = pcall(Runtime.Projection)
                else
                    local Camera = NativeCamera()
                    local Size = Camera and Camera.ViewportSize
                    Success = Size ~= nil and Size.X > 0 and Size.Y > 0
                    View = { Width = Size and Size.X or 0, Height = Size and Size.Y or 0 }
                end
                if Success then
                    Runtime.View = View
                    if Width ~= View.Width or Height ~= View.Height then
                        Width, Height = View.Width, View.Height
                        if CameraSignals.ViewportSize then
                            CameraSignals.ViewportSize:Fire()
                        end
                    end
                else
                    Runtime.View = nil
                end
                if Runtime.OrderDirty then
                    table.sort(Runtime.Order, function(A, B)
                        return A.Priority == B.Priority and A.Name < B.Name
                            or A.Priority < B.Priority
                    end)
                    Runtime.OrderDirty = false
                end
                for Index = #Runtime.Order, 1, -1 do
                    local Binding = Runtime.Order[Index]
                    if Runtime.Bindings[Binding.Name] ~= Binding then
                        table.remove(Runtime.Order, Index)
                    end
                end
                if Runtime.View then
                    for _, Binding in Runtime.Order do
                        Runtime.Try("Frame", Binding.Callback, Delta or 1 / 60)
                    end
                end
                if Frame then
                    NativeDraw.endframe(Frame)
                end
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

local Previous = getgenv().UnnamedEsp

if Previous and type(Previous.Stop) == "function" then
    Previous.Stop()
end

local Color3 = Runtime.Color
local Drawing = {
    Fonts = Drawing.Fonts,
    new = function(Kind)
        return Runtime.Drawing(Kind)
    end,
}

local UserInputService = Runtime.Input
local Players = Runtime.Players
local RunService = Runtime.RunService
local TweenService = Runtime.Tween
local HttpService = {}

function HttpService:GenerateGUID()
    local Parts = {}

    for Index = 1, 32 do
        Parts[Index] = string.format("%x", math.random(0, 15))
    end

    return table.concat(Parts)
end

function HttpService:JSONDecode(Text)
    return json.decode(Text)
end

function HttpService:JSONEncode(Value)
    return json.encode(Value)
end

local Instance = {}

function Instance.new(Kind)
    if Kind == "NumberValue" then
        return Runtime.Value(0)
    end

    if Kind == "BindableEvent" then
        local Event = Runtime.Signal()

        return {
            Event = Event,
            Fire = function(_, ...)
                Event:Fire(...)
            end,
            Wait = function()
                return Event:Wait()
            end,
            Destroy = function()
                table.clear(Event.Listeners)
            end,
        }
    end

    error("Unsupported UI object: " .. tostring(Kind))
end

local TweenInfo = {
    new = function(Time)
        return { Time = Time }
    end,
}

local Camera = Runtime.Camera
local LocalPlayer = Players.LocalPlayer

assert(LocalPlayer, "Join a game before starting ESP")

local Mouse = LocalPlayer:GetMouse()
local tick = Runtime.Time
local spawn = task.spawn
local wait = task.wait
local table = table.clone(table)

table.foreach = function(Items, Callback)
    for Key, Value in pairs(Items) do
        Callback(Key, Value)
    end
end

local shared = { MenuDrawingData = { Instances = {} }, InstanceData = {} }
local OriginalWorkspace = workspace
local workspace = setmetatable({}, {
    __index = function(_, Name)
        if Name == "CurrentCamera" then
            return Camera
        end
        local Value = OriginalWorkspace[Name]
        if type(Value) == "function" then
            return function(_, ...)
                return Value(OriginalWorkspace, ...)
            end
        end
        return Value
    end,
})

local function SaveSettings(Options, TeamColor, EnemyColor)
    local Data = {}

    for Name, Option in Options do
        local Value = Option.Value

        if type(Value) == "boolean" or type(Value) == "number" then
            Data[Name] = { Value = Value }
        end
    end

    Data.MenuKey = Options.MenuKey.Value.Name
    Data.ToggleKey = Options.ToggleKey.Value.Name
    Data.TeamColor = { R = TeamColor.R, G = TeamColor.G, B = TeamColor.B }
    Data.EnemyColor = { R = EnemyColor.R, G = EnemyColor.G, B = EnemyColor.B }
    writefile("UnnamedEsp.json", json.encode(Data))
end

local V2New = Vector2.new
local V3New = Vector3.new
local WTVP = Camera.WorldToViewportPoint
local WorldToViewport = function(...)
    return WTVP(Camera, ...)
end

local Menu = {}
local MouseHeld = false
local LastRefresh = 0
local OptionsFile = "UnnamedEsp.json"
local Binding = false
local BindedKey = nil
local OIndex = 0
local LineBox = {}
local UIButtons = {}
local Sliders = {}
local ColorPicker = { Loading = false, LastGenerated = 0 }
local Dragging = false
local DraggingUI = false
local Rainbow = false
local DragOffset = V2New()
local DraggingWhat = nil
local OldData = {}
local IgnoreList = {}
local EnemyColor = Color3.new(1, 0, 0)
local TeamColor = Color3.new(0, 1, 0)
local MenuLoaded = false
local ErrorLogging = false
local TracerPosition = V2New(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y - 135)
local DragTracerPosition = false
local SubMenu = {}
local UseImageData = true
local Connections = { Active = {} }
local Signal = {}

Signal.__index = Signal

local GetCharacter, CurrentColorPicker, Spectating

local QUAD_SUPPORTED_EXPLOIT = pcall(function()
    Drawing.new("Quad"):Remove()
end)

shared.MenuDrawingData = shared.MenuDrawingData or { Instances = {} }
shared.InstanceData = shared.InstanceData or {}
shared.RSName = shared.RSName or ("UnnamedESP_by_ic3-" .. HttpService:GenerateGUID(false))

local GetDataName = shared.RSName .. "-GetData"
local UpdateName = shared.RSName .. "-Update"

local Debounce = setmetatable({}, {
    __index = function(t, i)
        return rawget(t, i) or false
    end,
})

if shared.UESP_InputChangedCon then
    shared.UESP_InputChangedCon:Disconnect()
end

if shared.UESP_InputBeganCon then
    shared.UESP_InputBeganCon:Disconnect()
end

if shared.UESP_InputEndedCon then
    shared.UESP_InputEndedCon:Disconnect()
end

if shared.CurrentColorPicker then
    shared.CurrentColorPicker:Dispose()
end

local function IsStringEmpty(String)
    if type(String) == "string" then
        return String:match("^%s+$") ~= nil or #String == 0 or String == "" or false
    end

    return false
end

local function Set(t, i, v)
    t[i] = v
end

local CustomTeams = {}
local RenderList = { Instances = {} }

function RenderList:AddOrUpdateInstance(Instance, Obj2Draw, Text, Color)
    RenderList.Instances[Instance] =
        { ParentInstance = Instance, Instance = Obj2Draw, Text = Text, Color = Color }

    return RenderList.Instances[Instance]
end

local CustomPlayerTag
local CustomESP
local CustomCharacter
local GetHealth
local GetAliveState
local CustomRootPartName

function GetCharacter(Player)
    return Player.Character
end

function GetMouseLocation()
    return UserInputService:GetMouseLocation()
end

function MouseHoveringOver(Values)
    local X1, Y1, X2, Y2 = Values[1], Values[2], Values[3], Values[4]
    local MLocation = GetMouseLocation()

    return (MLocation.x >= X1 and MLocation.x <= (X1 + (X2 - X1)))
        and (MLocation.y >= Y1 and MLocation.y <= (Y1 + (Y2 - Y1)))
end

function GetTableData(t)
    if typeof(t) ~= "table" then
        return
    end

    return setmetatable(t, {
        __call = function(t, func)
            if typeof(func) ~= "function" then
                return
            end
            for i, v in pairs(t) do
                pcall(func, i, v)
            end
        end,
    })
end

local function Format(format, ...)
    return string.format(format, ...)
end

function CalculateValue(Min, Max, Percent)
    return Min + math.floor(((Max - Min) * Percent) + 0.5)
end

function NewDrawing(InstanceName)
    local Instance = Drawing.new(InstanceName)

    return function(Properties)
        for i, v in pairs(Properties) do
            pcall(Set, Instance, i, v)
        end

        return Instance
    end
end

function Menu:AddMenuInstance(Name, DrawingType, Properties)
    local Instance

    if shared.MenuDrawingData.Instances[Name] ~= nil then
        Instance = shared.MenuDrawingData.Instances[Name]

        for i, v in pairs(Properties) do
            pcall(Set, Instance, i, v)
        end
    else
        Instance = NewDrawing(DrawingType)(Properties)
    end

    shared.MenuDrawingData.Instances[Name] = Instance

    return Instance
end

function Menu:UpdateMenuInstance(Name)
    local Instance = shared.MenuDrawingData.Instances[Name]

    if Instance ~= nil then
        return function(Properties)
            for i, v in pairs(Properties) do
                pcall(Set, Instance, i, v)
            end

            return Instance
        end
    end
end

function Menu:GetInstance(Name)
    return shared.MenuDrawingData.Instances[Name]
end

local Options = setmetatable({}, {
    __call = function(t, ...)
        local Arguments = { ... }
        local Name = Arguments[1]
        OIndex = OIndex + 1
        rawset(
            t,
            Name,
            setmetatable({
                Name = Arguments[1],
                Text = Arguments[2],
                Value = Arguments[3],
                DefaultValue = Arguments[3],
                AllArgs = Arguments,
                Index = OIndex,
            }, {
                __call = function(t, v, force)
                    local self = t

                    if typeof(t.Value) == "function" then
                        t.Value()
                    elseif typeof(t.Value) == "EnumItem" then
                        local BT = Menu:GetInstance(Format("%s_BindText", t.Name))
                        if not force then
                            Binding = true
                            local Val = 0
                            while Binding do
                                wait()
                                Val = (Val + 1) % 17
                                BT.Text = Val <= 8 and "|" or ""
                            end
                        end
                        t.Value = force and v or BindedKey
                        if BT and t.BasePosition and t.BaseSize then
                            BT.Text = tostring(t.Value):match("%w+%.%w+%.(.+)")
                            BT.Position = t.BasePosition
                                + V2New(t.BaseSize.X - BT.TextBounds.X - 20, -10)
                        end
                    else
                        local NewValue = v
                        if NewValue == nil then
                            NewValue = not t.Value
                        end
                        rawset(t, "Value", NewValue)

                        if Arguments[2] ~= nil and Menu:GetInstance("TopBar").Visible then
                            if typeof(Arguments[3]) == "number" then
                                local AMT = Menu:GetInstance(Format("%s_AmountText", t.Name))
                                if AMT then
                                    AMT.Text = tostring(t.Value)
                                end
                            else
                                local Inner = Menu:GetInstance(Format("%s_InnerCircle", t.Name))
                                if Inner then
                                    Inner.Visible = t.Value
                                end
                            end
                        end
                    end
                end,
            })
        )
    end,
})

function Load()
    local _, Result = pcall(readfile, OptionsFile)

    if _ then
        local _, Table = pcall(HttpService.JSONDecode, HttpService, Result)

        if _ and typeof(Table) == "table" then
            for i, v in pairs(Table) do
                if
                    typeof(Options[i]) == "table"
                    and Options[i].Value ~= nil
                    and (
                        typeof(Options[i].Value) == "boolean"
                        or typeof(Options[i].Value) == "number"
                    )
                then
                    Options[i].Value = v.Value
                    pcall(Options[i], v.Value)
                end
            end

            if Table.TeamColor then
                TeamColor = Color3.new(Table.TeamColor.R, Table.TeamColor.G, Table.TeamColor.B)
            end

            if Table.EnemyColor then
                EnemyColor = Color3.new(Table.EnemyColor.R, Table.EnemyColor.G, Table.EnemyColor.B)
            end

            if typeof(Table.MenuKey) == "string" then
                Options.MenuKey(Runtime.Keys[Table.MenuKey] or Runtime.Keys.F4, true)
            end

            if typeof(Table.ToggleKey) == "string" then
                Options.ToggleKey(Runtime.Keys[Table.ToggleKey] or Runtime.Keys.F3, true)
            end
        end
    end
end

Options("Enabled", "ESP Enabled", true)
Options("ShowTeam", "Show Team", true)
Options("ShowTeamColor", "Show Team Color", false)
Options("ShowName", "Show Names", true)
Options("ShowDistance", "Show Distance", true)
Options("ShowHealth", "Show Health", true)
Options("ShowBoxes", "Show Boxes", true)
Options("ShowTracers", "Show Tracers", true)
Options("ShowDot", "Show Head Dot", false)
Options("VisCheck", "Visibility Check", false)
Options("Crosshair", "Crosshair", false)
Options("TextOutline", "Text Outline", true)

Options("TextSize", "Text Size", 14, 10, 24)
Options("MaxDistance", "Max Distance", 2500, 100, 25000)
Options("RefreshRate", "Refresh Rate (ms)", 5, 1, 200)
Options("YOffset", "Y Offset", 0, -200, 200)
Options("MenuKey", "Menu Key", Enum.KeyCode.F4, 1)
Options("ToggleKey", "Toggle Key", Enum.KeyCode.F3, 1)
Options("ChangeColors", "Change Colors", function()
    SubMenu:Show(GetMouseLocation(), "Unnamed Colors", {
        {
            Type = "Color",
            Text = "Team Color",
            Color = TeamColor,

            Function = function(Circ, Position)
                if tick() - ColorPicker.LastGenerated < 1 then
                    return
                end

                if shared.CurrentColorPicker then
                    shared.CurrentColorPicker:Dispose()
                end
                local ColorPicker = ColorPicker.new(Position - V2New(-10, 50))
                CurrentColorPicker = ColorPicker
                shared.CurrentColorPicker = CurrentColorPicker
                ColorPicker.ColorChanged:Connect(function(Color)
                    Circ.Color = Color
                    TeamColor = Color
                    Options.TeamColor = Color
                end)
            end,
        },
        {
            Type = "Color",
            Text = "Enemy Color",
            Color = EnemyColor,

            Function = function(Circ, Position)
                if tick() - ColorPicker.LastGenerated < 1 then
                    return
                end

                if shared.CurrentColorPicker then
                    shared.CurrentColorPicker:Dispose()
                end
                local ColorPicker = ColorPicker.new(Position - V2New(-10, 50))
                CurrentColorPicker = ColorPicker
                shared.CurrentColorPicker = CurrentColorPicker
                ColorPicker.ColorChanged:Connect(function(Color)
                    Circ.Color = Color
                    EnemyColor = Color
                    Options.EnemyColor = Color
                end)
            end,
        },
        {
            Type = "Button",
            Text = "Reset Colors",

            Function = function()
                EnemyColor = Color3.new(1, 0, 0)
                TeamColor = Color3.new(0, 1, 0)

                local C1 = Menu:GetInstance("Sub-ColorPreview.1")
                if C1 then
                    C1.Color = TeamColor
                end
                local C2 = Menu:GetInstance("Sub-ColorPreview.2")
                if C2 then
                    C2.Color = EnemyColor
                end
            end,
        },
        {
            Type = "Button",
            Text = "Rainbow Mode",

            Function = function()
                Rainbow = not Rainbow
            end,
        },
    })
end, 2)
Options("ResetSettings", "Reset Settings", function()
    for i, v in pairs(Options) do
        if
            Options[i] ~= nil
            and Options[i].Value ~= nil
            and Options[i].Text ~= nil
            and (
                typeof(Options[i].Value) == "boolean"
                or typeof(Options[i].Value) == "number"
                or typeof(Options[i].Value) == "EnumItem"
            )
        then
            Options[i](Options[i].DefaultValue, true)
        end
    end
end, 5)
Options("LoadSettings", "Load Settings", Load, 4)
Options("SaveSettings", "Save Settings", function()
    SaveSettings(Options, TeamColor, EnemyColor)
end, 3)

Load(1)

Options("MenuOpen", nil, true)

local function Combine(...)
    local Output = {}

    for i, v in pairs({ ... }) do
        if typeof(v) == "table" then
            table.foreach(v, function(i, v)
                Output[i] = v
            end)
        end
    end

    return Output
end

function LineBox:Create(Properties)
    local Box = { Visible = true }

    local Properties = Combine({
        Transparency = 1,
        Thickness = 3,
        Visible = true,
    }, Properties)

    if shared.am_ic3 then
        Box["OutlineSquare"] = NewDrawing("Square")(Properties)
        Box["Square"] = NewDrawing("Square")(Properties)
    elseif QUAD_SUPPORTED_EXPLOIT then
        Box["Quad"] = NewDrawing("Quad")(Properties)
    else
        Box["TopLeft"] = NewDrawing("Line")(Properties)
        Box["TopRight"] = NewDrawing("Line")(Properties)
        Box["BottomLeft"] = NewDrawing("Line")(Properties)
        Box["BottomRight"] = NewDrawing("Line")(Properties)
    end

    function Box:Update(CF, Size, Color, Properties, Parts)
        if not CF or not Size then
            return
        end

        if shared.am_ic3 and typeof(Parts) == "table" then
            local AllCorners = {}

            for i, v in pairs(Parts) do
                local CF, Size = v.CFrame, v.Size

                local Corners = {
                    Vector3.new(CF.X + Size.X / 2, CF.Y + Size.Y / 2, CF.Z + Size.Z / 2),
                    Vector3.new(CF.X - Size.X / 2, CF.Y + Size.Y / 2, CF.Z + Size.Z / 2),
                    Vector3.new(CF.X - Size.X / 2, CF.Y - Size.Y / 2, CF.Z - Size.Z / 2),
                    Vector3.new(CF.X + Size.X / 2, CF.Y - Size.Y / 2, CF.Z - Size.Z / 2),
                    Vector3.new(CF.X - Size.X / 2, CF.Y + Size.Y / 2, CF.Z - Size.Z / 2),
                    Vector3.new(CF.X + Size.X / 2, CF.Y + Size.Y / 2, CF.Z - Size.Z / 2),
                    Vector3.new(CF.X - Size.X / 2, CF.Y - Size.Y / 2, CF.Z + Size.Z / 2),
                    Vector3.new(CF.X + Size.X / 2, CF.Y - Size.Y / 2, CF.Z + Size.Z / 2),
                }

                for i, v in pairs(Corners) do
                    table.insert(AllCorners, v)
                end
            end

            local xMin, yMin = Camera.ViewportSize.X, Camera.ViewportSize.Y
            local xMax, yMax = 0, 0
            local Vs = true

            for i, v in pairs(AllCorners) do
                local Position, V = WorldToViewport(v)

                if VS and not V then
                    Vs = false
                    break
                end

                if Position.X > xMax then
                    xMax = Position.X
                end

                if Position.X < xMin then
                    xMin = Position.X
                end

                if Position.Y > yMax then
                    yMax = Position.Y
                end

                if Position.Y < yMin then
                    yMin = Position.Y
                end
            end

            local xSize, ySize = xMax - xMin, yMax - yMin

            local Outline = Box["OutlineSquare"]
            local Square = Box["Square"]

            Outline.Visible = Vs
            Square.Visible = Vs
            Square.Position = V2New(xMin, yMin)
            Square.Color = Color
            Square.Thickness = math.floor(Outline.Thickness * 0.3)

            Square.Size = V2New(xSize, ySize)
            Outline.Position = Square.Position
            Outline.Size = Square.Size
            Outline.Color = Color3.new(0.12, 0.12, 0.12)
            Outline.Transparency = 0.75

            return
        end

        local TLPos, Visible1 = WorldToViewport((CF * CFrame.new(Size.X, Size.Y, 0)).Position)
        local TRPos, Visible2 = WorldToViewport((CF * CFrame.new(-Size.X, Size.Y, 0)).Position)
        local BLPos, Visible3 = WorldToViewport((CF * CFrame.new(Size.X, -Size.Y, 0)).Position)
        local BRPos, Visible4 = WorldToViewport((CF * CFrame.new(-Size.X, -Size.Y, 0)).Position)

        local Quad = Box["Quad"]

        if QUAD_SUPPORTED_EXPLOIT then
            if Visible1 and Visible2 and Visible3 and Visible4 then
                Quad.Visible = true
                Quad.Color = Color
                Quad.PointA = V2New(TLPos.X, TLPos.Y)
                Quad.PointB = V2New(TRPos.X, TRPos.Y)
                Quad.PointC = V2New(BRPos.X, BRPos.Y)
                Quad.PointD = V2New(BLPos.X, BLPos.Y)
            else
                Box["Quad"].Visible = false
            end
        else
            Visible1 = TLPos.Z > 0
            Visible2 = TRPos.Z > 0
            Visible3 = BLPos.Z > 0
            Visible4 = BRPos.Z > 0

            if Visible1 then
                Box["TopLeft"].Visible = true
                Box["TopLeft"].Color = Color
                Box["TopLeft"].From = V2New(TLPos.X, TLPos.Y)
                Box["TopLeft"].To = V2New(TRPos.X, TRPos.Y)
            else
                Box["TopLeft"].Visible = false
            end

            if Visible2 then
                Box["TopRight"].Visible = true
                Box["TopRight"].Color = Color
                Box["TopRight"].From = V2New(TRPos.X, TRPos.Y)
                Box["TopRight"].To = V2New(BRPos.X, BRPos.Y)
            else
                Box["TopRight"].Visible = false
            end

            if Visible3 then
                Box["BottomLeft"].Visible = true
                Box["BottomLeft"].Color = Color
                Box["BottomLeft"].From = V2New(BLPos.X, BLPos.Y)
                Box["BottomLeft"].To = V2New(TLPos.X, TLPos.Y)
            else
                Box["BottomLeft"].Visible = false
            end

            if Visible4 then
                Box["BottomRight"].Visible = true
                Box["BottomRight"].Color = Color
                Box["BottomRight"].From = V2New(BRPos.X, BRPos.Y)
                Box["BottomRight"].To = V2New(BLPos.X, BLPos.Y)
            else
                Box["BottomRight"].Visible = false
            end

            if Properties and typeof(Properties) == "table" then
                GetTableData(Properties)(function(i, v)
                    pcall(Set, Box["TopLeft"], i, v)
                    pcall(Set, Box["TopRight"], i, v)
                    pcall(Set, Box["BottomLeft"], i, v)
                    pcall(Set, Box["BottomRight"], i, v)
                end)
            end
        end
    end

    function Box:SetVisible(bool)
        if shared.am_ic3 then
            Box["Square"].Visible = bool
            Box["OutlineSquare"].Visible = bool
        elseif self.Quad then
            self.Quad.Visible = false
        elseif self.TopLeft and self.TopRight and self.BottomLeft and self.BottomRight then
            self.TopLeft.Visible = bool
            self.TopRight.Visible = bool
            self.BottomLeft.Visible = bool
            self.BottomRight.Visible = bool
        end
    end

    function Box:Remove()
        self:SetVisible(false)

        if shared.am_ic3 then
            Box["Square"]:Remove()
            Box["OutlineSquare"]:Remove()
        elseif self.Quad then
            Box["Quad"]:Remove()
        elseif self.TopLeft and self.TopRight and self.BottomLeft and self.BottomRight then
            self.TopLeft:Remove()
            self.TopRight:Remove()
            self.BottomLeft:Remove()
            self.BottomRight:Remove()
        end
    end

    return Box
end

local Colors = {
    White = Color3.fromHex("ffffff"),
    Primary = {
        Main = Color3.fromHex("424242"),
        Light = Color3.fromHex("6d6d6d"),
        Dark = Color3.fromHex("1b1b1b"),
    },
    Secondary = {
        Main = Color3.fromHex("e0e0e0"),
        Light = Color3.fromHex("ffffff"),
        Dark = Color3.fromHex("aeaeae"),
    },
}

function Connections:Listen(Connection, Function)
    local NewConnection = Connection:Connect(Function)

    table.insert(self.Active, NewConnection)

    return NewConnection
end

function Connections:DisconnectAll()
    for Index, Connection in pairs(self.Active) do
        if Connection.Connected then
            Connection:Disconnect()
        end
    end

    self.Active = {}
end

function Signal.new()
    local self = setmetatable({ _BindableEvent = Instance.new("BindableEvent") }, Signal)

    return self
end

function Signal:Connect(Callback)
    assert(typeof(Callback) == "function", "function expected; got " .. typeof(Callback))

    return self._BindableEvent.Event:Connect(function(...)
        Callback(...)
    end)
end

function Signal:Fire(...)
    self._BindableEvent:Fire(...)
end

function Signal:Wait()
    local Arguments = self._BindableEvent:Wait()

    return Arguments
end

function Signal:Disconnect()
    if self._BindableEvent then
        self._BindableEvent:Destroy()
    end
end

local function GetMouseLocation()
    return UserInputService:GetMouseLocation()
end

local function IsMouseOverDrawing(Drawing, MousePosition)
    local TopLeft = Drawing.Position
    local BottomRight = Drawing.Position + Drawing.Size
    local MousePosition = MousePosition or GetMouseLocation()

    return MousePosition.X > TopLeft.X
        and MousePosition.Y > TopLeft.Y
        and MousePosition.X < BottomRight.X
        and MousePosition.Y < BottomRight.Y
end

local ImageCache = {}

local function SetImage(Drawing, Url)
    local Data = UseImageData and game:HttpGet(Url) or Url

    Drawing[UseImageData and "Data" or "Uri"] = ImageCache[Url] or Data
    ImageCache[Url] = Data

    if not UseImageData then
        repeat
            wait()
        until Drawing.Loaded
    end
end

local function CreateDrawingsTable()
    local Drawings = { __Objects = {} }
    local Metatable = {}

    function Metatable.__index(self, Index)
        local Object = rawget(self.__Objects, Index)

        if not Object or (UseImageData and not Object.__SELF.__OBJECT_EXISTS) then
            local Type = Index:sub(1, Index:find("-") - 1)

            Success, Object = pcall(Drawing.new, Type)

            if not Object or not Success then
                return function() end
            end

            self.__Objects[Index] = setmetatable({ __SELF = Object, Type = Type }, {
                __call = function(self, Properties)
                    local Object = rawget(self, "__SELF")
                    if UseImageData and not Object.__OBJECT_EXISTS then
                        return false, "render object destroyed"
                    end

                    if Properties == false then
                        Object.Visible = false
                        Object.Transparency = 0
                        Object:Remove()

                        return true
                    end

                    if typeof(Properties) == "table" then
                        for Property, Value in pairs(Properties) do
                            local CanSet = true

                            if
                                self.Type == "Image"
                                and not UseImageData
                                and Property == "Size"
                                and typeof(Value) == "Vector2"
                            then
                                CanSet = false

                                spawn(function()
                                    repeat
                                        wait()
                                    until Object.Loaded
                                    if not self.DefaultSize then
                                        rawset(self, "DefaultSize", Object.Size)
                                    end

                                    Property = "ScaleFactor"
                                    Value = Value.X / self.DefaultSize.X

                                    Object[Property] = Value
                                end)
                            end

                            if CanSet then
                                Object[Property] = Value
                            end
                        end
                    end

                    return Object
                end,
            })

            Object.Visible = true
            Object.Transparency = 1

            if Type == "Text" then
                if Drawing.Fonts then
                    Object.Font = Drawing.Fonts.Monospace
                end

                Object.Size = 20
                Object.Color = Color3.new(1, 1, 1)
                Object.Center = true
                Object.Outline = true
                OutlineOpacity = 0.5
            elseif Type == "Square" or Type == "Rectangle" then
                Object.Thickness = 2
                Object.Filled = false
            end

            return self.__Objects[Index]
        end

        return Object
    end

    function Metatable.__call(self, Delete, ...)
        local Arguments = { Delete, ... }

        if Delete == false then
            for Index, Drawing in pairs(rawget(self, "__Objects")) do
                Drawing(false)
            end
        end
    end

    return setmetatable(Drawings, Metatable)
end

local Images = {}

spawn(function()
    Images.Ring = "https://i.imgur.com/q4qx26f.png"
    Images.Overlay = "https://i.imgur.com/gOCxbsR.png"
end)

function ColorPicker.new(Position, Size, Color)
    ColorPicker.LastGenerated = tick()
    ColorPicker.Loading = true

    local self = { Color = Color or Color3.new(1, 1, 1), HSV = { H = 0, S = 1, V = 1 } }
    local Drawings = CreateDrawingsTable()
    local Position = Position or V2New()
    local Size = Size or 150
    local Padding = { 10, 10, 10, 10 }

    self.ColorChanged = Signal.new()

    local Background = Drawings["Square-Background"]({
        Color = Color3.fromRGB(33, 33, 33),
        Filled = false,
        Visible = false,
        Position = Position - V2New(Padding[4], Padding[1]),
        Size = V2New(Size, Size) + V2New(Padding[4] + Padding[2], Padding[1] + Padding[3]),
    })

    local ColorPreview = Drawings["Circle-Preview"]({
        Position = Position + (V2New(Size, Size) / 2),
        Radius = Size / 2 - 8,
        Filled = true,
        Thickness = 0,
        NumSides = 20,
        Color = Color3.new(1, 0, 0),
    })

    local Main = Drawings["Image-Main"]({
        Position = Position,
        Size = V2New(Size, Size),
    })
    SetImage(Main, Images.Ring)

    local Preview = Drawings["Square-Preview"]({
        Position = Main.Position + (Main.Size / 4.5),
        Size = Main.Size / 1.75,
        Color = Color3.new(1, 0, 0),
        Filled = true,
        Thickness = 0,
    })

    local Overlay = Drawings["Image-Overlay"]({
        Position = Preview.Position,
        Size = Preview.Size,
        Transparency = 1,
    })
    SetImage(Overlay, Images.Overlay)

    local CursorOutline = Drawings["Circle-CursorOutline"]({
        Radius = 4,
        Thickness = 2,
        Filled = false,
        Color = Color3.new(0.2, 0.2, 0.2),
        Position = V2New(Main.Position.X + Main.Size.X - 10, Main.Position.Y + (Main.Size.Y / 2)),
    })

    local Cursor = Drawings["Circle-Cursor"]({
        Radius = 3,
        Transparency = 1,
        Filled = true,
        Color = Color3.new(1, 1, 1),
        Position = CursorOutline.Position,
    })

    local CursorOutline = Drawings["Circle-CursorOutlineSquare"]({
        Radius = 4,
        Thickness = 2,
        Filled = false,
        Color = Color3.new(0.2, 0.2, 0.2),
        Position = V2New(Preview.Position.X + Preview.Size.X - 2, Preview.Position.Y + 2),
    })
    Drawings["Circle-CursorSquare"]({
        Radius = 3,
        Transparency = 1,
        Filled = true,
        Color = Color3.new(1, 1, 1),
        Position = CursorOutline.Position,
    })

    function self:UpdatePosition(Input)
        local MousePosition = V2New(Input.Position.X, Input.Position.Y + 33)

        if self.MouseHeld then
            if self.Item == "Ring" then
                local Main = self.Drawings["Image-Main"]()
                local Preview = self.Drawings["Square-Preview"]()
                local Bounds = Main.Size / 2
                local Center = Main.Position + Bounds
                local Relative = MousePosition - Center
                local Direction = Relative.Unit
                local Position = Center + Direction * Main.Size.X / 2.15
                local H = (math.atan2(Position.Y - Center.Y, Position.X - Center.X)) * 60

                if H < 0 then
                    H = 360 + H
                end

                H = H / 360
                self.HSV.H = H

                local EndColor = Color3.fromHSV(H, self.HSV.S, self.HSV.V)

                if EndColor ~= self.Color then
                    self.ColorChanged:Fire(self.Color)
                end

                local Pointer = self.Drawings["Circle-Cursor"]({ Position = Position })

                self.Drawings["Circle-CursorOutline"]({ Position = Pointer.Position })
                Bounds = Bounds * 2
                Preview.Color = Color3.fromHSV(H, 1, 1)
                self.Color = EndColor
                self.Drawings["Circle-Preview"]({ Color = EndColor })
            elseif self.Item == "HL" then
                local Preview = self.Drawings["Square-Preview"]()
                local HSV = self.HSV
                local Position = V2New(
                    math.clamp(
                        MousePosition.X,
                        Preview.Position.X,
                        Preview.Position.X + Preview.Size.X
                    ),
                    math.clamp(
                        MousePosition.Y,
                        Preview.Position.Y,
                        Preview.Position.Y + Preview.Size.Y
                    )
                )
                HSV.S = (Position.X - Preview.Position.X) / Preview.Size.X
                HSV.V = 1 - (Position.Y - Preview.Position.Y) / Preview.Size.Y

                local EndColor = Color3.fromHSV(HSV.H, HSV.S, HSV.V)

                if EndColor ~= self.Color then
                    self.ColorChanged:Fire(self.Color)
                end

                self.Color = EndColor
                self.Drawings["Circle-Preview"]({ Color = EndColor })

                local Pointer = self.Drawings["Circle-CursorSquare"]({ Position = Position })

                self.Drawings["Circle-CursorOutlineSquare"]({ Position = Pointer.Position })
            end
        end
    end

    function self:HandleInput(Input, P, Type)
        if Type == "Began" then
            if Input.UserInputType.Name == "MouseButton1" then
                local Main = self.Drawings["Image-Main"]()
                local SquareSV = self.Drawings["Square-Preview"]()
                local MousePosition = V2New(Input.Position.X, Input.Position.Y + 33)

                self.MouseHeld = true

                local Bounds = Main.Size / 2
                local Center = Main.Position + Bounds
                local R = (MousePosition - Center)

                if R.Magnitude < Bounds.X and R.Magnitude > Bounds.X - 20 then
                    self.Item = "Ring"
                end

                if
                    MousePosition.X > SquareSV.Position.X
                    and MousePosition.Y > SquareSV.Position.Y
                    and MousePosition.X < SquareSV.Position.X + SquareSV.Size.X
                    and MousePosition.Y < SquareSV.Position.Y + SquareSV.Size.Y
                then
                    self.Item = "HL"
                end

                self:UpdatePosition(Input, P)
            end
        elseif Type == "Changed" then
            if Input.UserInputType.Name == "MouseMovement" then
                self:UpdatePosition(Input, P)
            end
        elseif Type == "Ended" and Input.UserInputType.Name == "MouseButton1" then
            self.Item = nil
        end
    end

    function self:Dispose()
        self.Drawings(false)
        self.UpdatePosition = nil
        self.HandleInput = nil
        Connections:DisconnectAll()
    end

    Connections:Listen(UserInputService.InputBegan, function(Input, Process)
        self:HandleInput(Input, Process, "Began")
    end)

    Connections:Listen(UserInputService.InputChanged, function(Input, Process)
        if Input.UserInputType.Name == "MouseMovement" then
            local MousePosition = V2New(Input.Position.X, Input.Position.Y + 33)
            local Cursor = self.Drawings["Triangle-Cursor"]({
                Filled = true,
                Color = Color3.new(0.9, 0.9, 0.9),
                PointA = MousePosition + V2New(0, 0),
                PointB = MousePosition + V2New(12, 14),
                PointC = MousePosition + V2New(0, 18),
                Thickness = 0,
            })
        end
        self:HandleInput(Input, Process, "Changed")
    end)

    Connections:Listen(UserInputService.InputEnded, function(Input, Process)
        self:HandleInput(Input, Process, "Ended")

        if Input.UserInputType.Name == "MouseButton1" then
            self.MouseHeld = false
        end
    end)

    ColorPicker.Loading = false

    self.Drawings = Drawings

    return self
end

function SubMenu:Show(Position, Title, Options)
    self.Open = true

    local Visible = true
    local BasePosition = Position
    local BaseSize = V2New(200, 140)
    local End = BasePosition + BaseSize

    self.Bounds = { BasePosition.X, BasePosition.Y, End.X, End.Y }

    delay(0.025, function()
        if not self.Open then
            return
        end

        Menu:AddMenuInstance("Sub-Main", "Square", {
            Size = BaseSize,
            Position = BasePosition,
            Filled = false,
            Color = Colors.Primary.Main,
            Thickness = 3,
            Visible = Visible,
        })
    end)

    Menu:AddMenuInstance("Sub-TopBar", "Square", {
        Position = BasePosition,
        Size = V2New(BaseSize.X, 10),
        Color = Colors.Primary.Dark,
        Filled = true,
        Visible = Visible,
    })
    Menu:AddMenuInstance("Sub-TopBarTwo", "Square", {
        Position = BasePosition + V2New(0, 10),
        Size = V2New(BaseSize.X, 20),
        Color = Colors.Primary.Main,
        Filled = true,
        Visible = Visible,
    })
    Menu:AddMenuInstance("Sub-TopBarText", "Text", {
        Size = 20,
        Position = shared.MenuDrawingData.Instances["Sub-TopBarTwo"].Position + V2New(15, -3),
        Text = Title or "",
        Color = Colors.Secondary.Light,
        Visible = Visible,
    })
    Menu:AddMenuInstance("Sub-Filling", "Square", {
        Size = BaseSize - V2New(0, 30),
        Position = BasePosition + V2New(0, 30),
        Filled = true,
        Color = Colors.Secondary.Main,
        Transparency = 0.75,
        Visible = Visible,
    })

    if Options then
        for Index, Option in pairs(Options) do
            local function GetName(Name)
                return ("Sub-%s.%d"):format(Name, Index)
            end

            local Position = shared.MenuDrawingData.Instances["Sub-Filling"].Position
                + V2New(20, Index * 25 - 10)

            if Option.Type == "Color" then
                local ColorPreview = Menu:AddMenuInstance(GetName("ColorPreview"), "Circle", {
                    Position = Position,
                    Color = Option.Color,
                    Radius = UseImageData and 10 or 10,
                    NumSides = 10,
                    Filled = true,
                    Visible = true,
                })

                local Text = Menu:AddMenuInstance(GetName("Text"), "Text", {
                    Text = Option.Text,
                    Position = ColorPreview.Position + V2New(15, -8),
                    Size = 16,
                    Color = Colors.Primary.Dark,
                    Visible = true,
                })
                UIButtons[#UIButtons + 1] = {
                    FromSubMenu = true,
                    Option = function()
                        return Option.Function(ColorPreview, BasePosition + V2New(BaseSize.X, 0))
                    end,
                    Instance = Menu:AddMenuInstance(
                        Format("%s_Hitbox", GetName("Button")),
                        "Square",
                        {
                            Position = Position - V2New(20, 12),
                            Size = V2New(BaseSize.X, 25),
                            Visible = false,
                        }
                    ),
                }
            elseif Option.Type == "Button" then
                UIButtons[#UIButtons + 1] = {
                    FromSubMenu = true,
                    Option = Option.Function,
                    Instance = Menu:AddMenuInstance(
                        Format("%s_Hitbox", GetName("Button")),
                        "Square",
                        {
                            Size = V2New(BaseSize.X, 20) - V2New(20, 0),
                            Visible = true,
                            Transparency = 0.5,
                            Position = Position - V2New(10, 10),
                            Color = Colors.Secondary.Light,
                            Filled = true,
                        }
                    ),
                }

                local Text = Menu:AddMenuInstance(Format("%s_Text", GetName("Text")), "Text", {
                    Text = Option.Text,
                    Size = 18,
                    Position = Position + V2New(5, -10),
                    Visible = true,
                    Color = Colors.Primary.Dark,
                })
            end
        end
    end
end

function SubMenu:Hide()
    self.Open = false

    for i, v in pairs(shared.MenuDrawingData.Instances) do
        if i:sub(1, 3) == "Sub" then
            v.Visible = false

            if i:sub(4, 4) == ":" then
                v:Remove()
                shared.MenuDrawingData.Instance[i] = nil
            end
        end
    end

    for i, Button in pairs(UIButtons) do
        if Button.FromSubMenu then
            UIButtons[i] = nil
        end
    end

    spawn(function()
        for i = 1, 10 do
            if shared.CurrentColorPicker then
                shared.CurrentColorPicker:Dispose()
            end
            wait(0.1)
        end
    end)

    CurrentColorPicker = nil
end

function CreateMenu(NewPosition)
    MenuLoaded = false
    UIButtons = {}
    Sliders = {}

    local BaseSize = V2New(300, 625)
    local BasePosition = NewPosition
        or V2New(
            Camera.ViewportSize.X / 8 - (BaseSize.X / 2),
            Camera.ViewportSize.Y / 2 - (BaseSize.Y / 2)
        )

    BasePosition = V2New(
        math.clamp(BasePosition.X, 0, Camera.ViewportSize.X),
        math.clamp(BasePosition.Y, 0, Camera.ViewportSize.Y)
    )

    Menu:AddMenuInstance("CrosshairX", "Line", {
        Visible = false,
        Color = Color3.new(0, 1, 0),
        Transparency = 1,
        Thickness = 1,
    })
    Menu:AddMenuInstance("CrosshairY", "Line", {
        Visible = false,
        Color = Color3.new(0, 1, 0),
        Transparency = 1,
        Thickness = 1,
    })

    delay(0.025, function()
        Menu:AddMenuInstance("Main", "Square", {
            Size = BaseSize,
            Position = BasePosition,
            Filled = false,
            Color = Colors.Primary.Main,
            Thickness = 3,
            Visible = true,
        })
    end)

    Menu:AddMenuInstance("TopBar", "Square", {
        Position = BasePosition,
        Size = V2New(BaseSize.X, 15),
        Color = Colors.Primary.Dark,
        Filled = true,
        Visible = true,
    })
    Menu:AddMenuInstance("TopBarTwo", "Square", {
        Position = BasePosition + V2New(0, 15),
        Size = V2New(BaseSize.X, 45),
        Color = Colors.Primary.Main,
        Filled = true,
        Visible = true,
    })
    Menu:AddMenuInstance("TopBarText", "Text", {
        Size = 25,
        Position = shared.MenuDrawingData.Instances.TopBarTwo.Position + V2New(25, 10),
        Text = "Unnamed ESP",
        Color = Colors.Secondary.Light,
        Visible = true,
        Transparency = 1,
        Outline = true,
        OutlineOpacity = 0.5,
    })
    Menu:AddMenuInstance("TopBarTextBR", "Text", {
        Size = 18,
        Position = shared.MenuDrawingData.Instances.TopBarTwo.Position + V2New(BaseSize.X - 75, 25),
        Text = "by ic3w0lf",
        Color = Colors.Secondary.Light,
        Visible = true,
        Transparency = 1,
        Outline = true,
        OutlineOpacity = 0.5,
    })
    Menu:AddMenuInstance("Filling", "Square", {
        Size = BaseSize - V2New(0, 60),
        Position = BasePosition + V2New(0, 60),
        Filled = true,
        Color = Colors.Secondary.Main,
        Transparency = 0.35,
        Visible = true,
    })

    local CPos = 0

    GetTableData(Options)(function(i, v)
        if typeof(v.Value) == "boolean" and not IsStringEmpty(v.Text) and v.Text ~= nil then
            CPos = CPos + 25
            local BaseSize = V2New(BaseSize.X, 30)
            local BasePosition = shared.MenuDrawingData.Instances.Filling.Position
                + V2New(30, v.Index * 25 - 10)
            UIButtons[#UIButtons + 1] = {
                Option = v,
                Instance = Menu:AddMenuInstance(Format("%s_Hitbox", v.Name), "Square", {
                    Position = BasePosition - V2New(30, 15),
                    Size = BaseSize,
                    Visible = false,
                }),
            }
            Menu:AddMenuInstance(Format("%s_OuterCircle", v.Name), "Circle", {
                Radius = 10,
                Position = BasePosition,
                Color = Colors.Secondary.Light,
                Filled = true,
                Visible = true,
            })
            Menu:AddMenuInstance(Format("%s_InnerCircle", v.Name), "Circle", {
                Radius = 7,
                Position = BasePosition,
                Color = Colors.Secondary.Dark,
                Filled = true,
                Visible = v.Value,
            })
            Menu:AddMenuInstance(Format("%s_Text", v.Name), "Text", {
                Text = v.Text,
                Size = 20,
                Position = BasePosition + V2New(20, -10),
                Visible = true,
                Color = Colors.Secondary.Light,
                Transparency = 1,
                Outline = true,
                OutlineOpacity = 0.5,
            })
        end
    end)

    GetTableData(Options)(function(i, v)
        if typeof(v.Value) == "number" then
            CPos = CPos + 25

            local BaseSize = V2New(BaseSize.X, 30)
            local BasePosition = shared.MenuDrawingData.Instances.Filling.Position
                + V2New(0, CPos - 10)

            local Line = Menu:AddMenuInstance(Format("%s_SliderLine", v.Name), "Square", {
                Transparency = 1,
                Color = Colors.Secondary.Light,

                Filled = true,
                Visible = true,
                Position = BasePosition + V2New(15, -5),
                Size = BaseSize - V2New(30, 10),
                Transparency = 0.5,
            })
            local Slider = Menu:AddMenuInstance(Format("%s_Slider", v.Name), "Square", {
                Visible = true,
                Filled = true,
                Color = Colors.Primary.Dark,
                Size = V2New(5, Line.Size.Y),
                Transparency = 0.5,
            })
            local Text = Menu:AddMenuInstance(Format("%s_Text", v.Name), "Text", {
                Text = v.Text,
                Size = 20,
                Center = true,
                Transparency = 1,
                Outline = true,
                OutlineOpacity = 0.5,
                Visible = true,
                Color = Colors.White,
            })
            Text.Position = Line.Position + (Line.Size / 2) - V2New(0, Text.TextBounds.Y / 1.75)
            local AMT = Menu:AddMenuInstance(Format("%s_AmountText", v.Name), "Text", {
                Text = tostring(v.Value),
                Size = 22,
                Center = true,
                Transparency = 1,
                Outline = true,
                OutlineOpacity = 0.5,
                Visible = true,
                Color = Colors.White,
                Position = Text.Position,
            })

            local CSlider =
                { Slider = Slider, Line = Line, Min = v.AllArgs[4], Max = v.AllArgs[5], Option = v }
            local Dummy = Instance.new("NumberValue")

            Dummy:GetPropertyChangedSignal("Value"):Connect(function()
                Text.Transparency = Dummy.Value

                AMT.Transparency = 1 - Dummy.Value
            end)

            Dummy.Value = 1

            function CSlider:ShowValue(Bool)
                self.ShowingValue = Bool

                TweenService
                    :Create(
                        Dummy,
                        TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
                        { Value = Bool and 0 or 1 }
                    )
                    :Play()
            end

            Sliders[#Sliders + 1] = CSlider

            Slider.Position = Line.Position + V2New(35, 0)

            v.BaseSize = BaseSize
            v.BasePosition = BasePosition
        end
    end)

    local FirstItem = false

    GetTableData(Options)(function(i, v)
        if typeof(v.Value) == "EnumItem" then
            CPos = CPos + (not FirstItem and 30 or 25)
            FirstItem = true

            local BaseSize = V2New(BaseSize.X, FirstItem and 30 or 25)
            local BasePosition = shared.MenuDrawingData.Instances.Filling.Position
                + V2New(0, CPos - 10)

            UIButtons[#UIButtons + 1] = {
                Option = v,
                Instance = Menu:AddMenuInstance(Format("%s_Hitbox", v.Name), "Square", {
                    Size = V2New(BaseSize.X, 20) - V2New(30, 0),
                    Visible = true,
                    Transparency = 0.5,
                    Position = BasePosition + V2New(15, -10),
                    Color = Colors.Secondary.Light,
                    Filled = true,
                }),
            }
            local Text = Menu:AddMenuInstance(Format("%s_Text", v.Name), "Text", {
                Text = v.Text,
                Size = 20,
                Position = BasePosition + V2New(20, -10),
                Visible = true,
                Color = Colors.Secondary.Light,
                Transparency = 1,
                Outline = true,
                OutlineOpacity = 0.5,
            })
            local BindText = Menu:AddMenuInstance(Format("%s_BindText", v.Name), "Text", {
                Text = tostring(v.Value):match("%w+%.%w+%.(.+)"),
                Size = 20,
                Position = BasePosition,
                Visible = true,
                Color = Colors.Secondary.Light,
                Transparency = 1,
                Outline = true,
                OutlineOpacity = 0.5,
            })

            Options[i].BaseSize = BaseSize
            Options[i].BasePosition = BasePosition
            BindText.Position = BasePosition + V2New(BaseSize.X - BindText.TextBounds.X - 20, -10)
        end
    end)

    GetTableData(Options)(function(i, v)
        if typeof(v.Value) == "function" then
            local BaseSize = V2New(BaseSize.X, 30)
            local BasePosition = shared.MenuDrawingData.Instances.Filling.Position
                + V2New(0, CPos + (25 * v.AllArgs[4]) - 35)

            UIButtons[#UIButtons + 1] = {
                Option = v,
                Instance = Menu:AddMenuInstance(Format("%s_Hitbox", v.Name), "Square", {
                    Size = V2New(BaseSize.X, 20) - V2New(30, 0),
                    Visible = true,
                    Transparency = 0.5,
                    Position = BasePosition + V2New(15, -10),
                    Color = Colors.Secondary.Light,
                    Filled = true,
                }),
            }
            local Text = Menu:AddMenuInstance(Format("%s_Text", v.Name), "Text", {
                Text = v.Text,
                Size = 20,
                Position = BasePosition + V2New(20, -10),
                Visible = true,
                Color = Colors.Secondary.Light,
                Transparency = 1,
                Outline = true,
                OutlineOpacity = 0.5,
            })
        end
    end)

    delay(0.1, function()
        MenuLoaded = true
    end)

    Menu:AddMenuInstance("Cursor1", "Line", {
        Visible = false,
        Color = Color3.new(1, 0, 0),
        Transparency = 1,
        Thickness = 2,
    })
    Menu:AddMenuInstance("Cursor2", "Line", {
        Visible = false,
        Color = Color3.new(1, 0, 0),
        Transparency = 1,
        Thickness = 2,
    })
    Menu:AddMenuInstance("Cursor3", "Line", {
        Visible = false,
        Color = Color3.new(1, 0, 0),
        Transparency = 1,
        Thickness = 2,
    })
end

CreateMenu()
delay(0.1, function()
    SubMenu:Show(V2New())
    SubMenu:Hide()
end)

shared.UESP_InputChangedCon = UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType.Name == "MouseMovement" and Options.MenuOpen.Value then
        for i, v in pairs(Sliders) do
            local Values = {
                v.Line.Position.X,
                v.Line.Position.Y,
                v.Line.Position.X + v.Line.Size.X,
                v.Line.Position.Y + v.Line.Size.Y,
            }
            if MouseHoveringOver(Values) then
                v:ShowValue(true)
            else
                if not MouseHeld then
                    v:ShowValue(false)
                end
            end
        end
    end
end)

shared.UESP_InputBeganCon = UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType.Name == "MouseButton1" and Options.MenuOpen.Value then
        MouseHeld = true
        local Bar = Menu:GetInstance("TopBar")
        local Values = {
            Bar.Position.X,
            Bar.Position.Y,
            Bar.Position.X + Bar.Size.X,
            Bar.Position.Y + Bar.Size.Y,
        }
        if MouseHoveringOver(Values) then
            DraggingUI = true
            DragOffset = Menu:GetInstance("Main").Position - GetMouseLocation()
        else
            for i, v in pairs(Sliders) do
                local Values = {
                    v.Line.Position.X,
                    v.Line.Position.Y,
                    v.Line.Position.X + v.Line.Size.X,
                    v.Line.Position.Y + v.Line.Size.Y,
                }
                if MouseHoveringOver(Values) then
                    DraggingWhat = v
                    Dragging = true
                    break
                end
            end

            if not Dragging then
                local Values = {
                    TracerPosition.X - 10,
                    TracerPosition.Y - 10,
                    TracerPosition.X + 10,
                    TracerPosition.Y + 10,
                }
                if MouseHoveringOver(Values) then
                    DragTracerPosition = true
                end
            end
        end
    end
end)

shared.UESP_InputEndedCon = UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType.Name == "MouseButton1" and Options.MenuOpen.Value then
        MouseHeld = false
        DragTracerPosition = false
        local IgnoreOtherInput = false

        if SubMenu.Open and not MouseHoveringOver(SubMenu.Bounds) then
            if
                CurrentColorPicker
                and IsMouseOverDrawing(CurrentColorPicker.Drawings["Square-Background"]())
            then
                IgnoreOtherInput = true
            end
            if not IgnoreOtherInput then
                SubMenu:Hide()
            end
        end

        if not IgnoreOtherInput then
            for i, v in pairs(UIButtons) do
                if v.Control then
                    continue
                end
                if SubMenu.Open and MouseHoveringOver(SubMenu.Bounds) and not v.FromSubMenu then
                    continue
                end

                local Values = {
                    v.Instance.Position.X,
                    v.Instance.Position.Y,
                    v.Instance.Position.X + v.Instance.Size.X,
                    v.Instance.Position.Y + v.Instance.Size.Y,
                }
                if MouseHoveringOver(Values) then
                    v.Option()
                    IgnoreOtherInput = true
                    break
                end
            end
            for i, v in pairs(Sliders) do
                if IgnoreOtherInput then
                    break
                end

                local Values = {
                    v.Line.Position.X,
                    v.Line.Position.Y,
                    v.Line.Position.X + v.Line.Size.X,
                    v.Line.Position.Y + v.Line.Size.Y,
                }
                if not MouseHoveringOver(Values) then
                    v:ShowValue(false)
                end
            end
        end
    elseif
        input.UserInputType.Name == "MouseButton2"
        and Options.MenuOpen.Value
        and not DragTracerPosition
    then
        local Values = {
            TracerPosition.X - 10,
            TracerPosition.Y - 10,
            TracerPosition.X + 10,
            TracerPosition.Y + 10,
        }
        if MouseHoveringOver(Values) then
            DragTracerPosition = false
            TracerPosition = V2New(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y - 135)
        end
    elseif input.UserInputType.Name == "Keyboard" then
        if Binding then
            BindedKey = input.KeyCode
            Binding = false
        elseif input.KeyCode == Options.MenuKey.Value then
            Options.MenuOpen()
        elseif input.KeyCode == Options.ToggleKey.Value then
            Options.Enabled()
        elseif false then
            local HD, LPlayer, LCharacter = 0.95

            for i, Player in pairs(Players:GetPlayers()) do
                local Character = GetCharacter(Player)

                if
                    Player ~= LocalPlayer
                    and Player ~= Spectating
                    and Character
                    and Character:FindFirstChild("HumanoidRootPart")
                then
                    local Head = Character:FindFirstChild("Head")
                    local Humanoid = Character:FindFirstChildOfClass("Humanoid")

                    if Head then
                        local Distance = (Camera.CFrame.Position - Head.Position).Magnitude

                        if Distance > Options.MaxDistance.Value then
                            continue
                        end

                        local Direction = -(Camera.CFrame.Position - Mouse.Hit.Position).Unit
                        local Relative = Character.Head.Position - Camera.CFrame.Position
                        local Unit = Relative.Unit

                        local DP = Direction:Dot(Unit)

                        if DP > HD then
                            HD = DP
                            LPlayer = Player
                            LCharacter = Character
                        end
                    end
                end
            end

            if LPlayer and LPlayer ~= Spectating and LCharacter then
                Camera.CameraSubject = LCharacter.Head
                Spectating = LPlayer
            else
                if
                    LocalPlayer.Character
                    and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                then
                    Camera.CameraSubject = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                    Spectating = nil
                end
            end
        end
    end
end)

local function CameraCon()
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        TracerPosition = V2New(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y - 135)
    end)
end

CameraCon()

local function ToggleMenu()
    if Options.MenuOpen.Value then
        GetTableData(shared.MenuDrawingData.Instances)(function(i, v)
            if OldData[v] then
                pcall(Set, v, "Visible", true)
            end
        end)
    else
        GetTableData(shared.MenuDrawingData.Instances)(function(i, v)
            OldData[v] = v.Visible
            if v.Visible then
                pcall(Set, v, "Visible", false)
            end
        end)
    end
end

local LastRayIgnoreUpdate, RayIgnoreList = 0, {}

local function CheckRay(Object, Distance, Position, Unit)
    local Character = Object.ClassName == "Player" and Object.Character or Object

    if not Character then
        return false
    end

    local Ignore = { LocalPlayer.Character }

    for Pass = 1, 16 do
        local Hit = OriginalWorkspace:Raycast(
            Position,
            Unit * Distance,
            { FilterDescendantsInstances = Ignore, FilterType = Enum.RaycastFilterType.Exclude }
        )

        if not Hit or not Hit.Instance then
            return true
        end

        if Hit.Instance:IsDescendantOf(Character) then
            return true
        end

        if Hit.Instance.Transparency >= 0.3 or Hit.Instance.CanCollide == false then
            Ignore[#Ignore + 1] = Hit.Instance
        else
            return false
        end
    end

    return false
end

local function CheckTeam(Player)
    return Runtime.SameTeam(Player, LocalPlayer)
end

local CustomTeam = CustomTeams[game.PlaceId]

if CustomTeam ~= nil then
    if CustomTeam.Initialize then
        ypcall(CustomTeam.Initialize)
    end

    CheckTeam = CustomTeam.CheckTeam
end

local function CheckPlayer(Player, Character)
    if not Options.Enabled.Value then
        return false
    end

    local Pass = true
    local Distance = 0

    if Player ~= LocalPlayer and Character then
        if not Options.ShowTeam.Value and CheckTeam(Player) then
            Pass = false
        end

        local Head = Character:FindFirstChild("Head")

        if Pass and Character and Head then
            Distance = (Camera.CFrame.Position - Head.Position).Magnitude

            if Options.VisCheck.Value then
                Pass = CheckRay(
                    Player,
                    Distance,
                    Camera.CFrame.Position,
                    (Head.Position - Camera.CFrame.Position).Unit
                )
            end

            if Distance > Options.MaxDistance.Value then
                Pass = false
            end
        end
    else
        Pass = false
    end

    return Pass, Distance
end

local function CheckDistance(Instance)
    if not Options.Enabled.Value then
        return false
    end

    local Pass = true
    local Distance = 0

    if Instance ~= nil then
        Distance = (Camera.CFrame.Position - Instance.Position).Magnitude

        if Options.VisCheck.Value then
            Pass = CheckRay(
                Instance,
                Distance,
                Camera.CFrame.Position,
                (Instance.Position - Camera.CFrame.Position).Unit
            )
        end

        if Distance > Options.MaxDistance.Value then
            Pass = false
        end
    else
        Pass = false
    end

    return Pass, Distance
end

local function UpdatePlayerData()
    if (tick() - LastRefresh) > (Options.RefreshRate.Value / 1000) then
        LastRefresh = tick()

        if CustomESP and Options.Enabled.Value then
            local a, b = pcall(CustomESP)
        end

        for i, v in pairs(RenderList.Instances) do
            if v.Instance ~= nil and v.Instance.Parent ~= nil and v.Instance:IsA("BasePart") then
                local Data = shared.InstanceData[v.Instance:GetDebugId()]
                    or { Instances = {}, DontDelete = true }

                Data.Instance = v.Instance

                Data.Instances["OutlineTracer"] = Data.Instances["OutlineTracer"]
                    or NewDrawing("Line")({
                        Transparency = 0.75,
                        Thickness = 5,
                        Color = Color3.new(0.1, 0.1, 0.1),
                    })
                Data.Instances["Tracer"] = Data.Instances["Tracer"]
                    or NewDrawing("Line")({
                        Transparency = 1,
                        Thickness = 2,
                    })
                Data.Instances["NameTag"] = Data.Instances["NameTag"]
                    or NewDrawing("Text")({
                        Size = Options.TextSize.Value,
                        Center = true,
                        Outline = Options.TextOutline.Value,
                        Visible = true,
                    })
                Data.Instances["DistanceTag"] = Data.Instances["DistanceTag"]
                    or NewDrawing("Text")({
                        Size = Options.TextSize.Value - 1,
                        Center = true,
                        Outline = Options.TextOutline.Value,
                        Visible = true,
                    })

                local NameTag = Data.Instances["NameTag"]
                local DistanceTag = Data.Instances["DistanceTag"]
                local Tracer = Data.Instances["Tracer"]
                local OutlineTracer = Data.Instances["OutlineTracer"]

                local Pass, Distance = CheckDistance(v.Instance)

                if Pass then
                    local ScreenPosition, Vis = WorldToViewport(v.Instance.Position)
                    local Color = v.Color
                    local OPos = Camera.CFrame:PointToObjectSpace(v.Instance.Position)

                    if ScreenPosition.Z < 0 then
                        local AT = math.atan2(OPos.Y, OPos.X) + math.pi

                        OPos = CFrame.Angles(0, 0, AT):VectorToWorldSpace(
                            (
                                CFrame.Angles(0, math.rad(89.9), 0)
                                    :VectorToWorldSpace(V3New(0, 0, -1))
                            )
                        )
                    end

                    local Position = WorldToViewport(Camera.CFrame:PointToWorldSpace(OPos))

                    if Options.ShowTracers.Value then
                        Tracer.Transparency = math.clamp(Distance / 200, 0.45, 0.8)
                        Tracer.Visible = true
                        Tracer.From = TracerPosition
                        Tracer.To = Runtime.ScreenEdge(Position)
                        Tracer.Color = Color
                        OutlineTracer.Visible = true
                        OutlineTracer.Transparency = Tracer.Transparency - 0.1
                        OutlineTracer.From = Tracer.From
                        OutlineTracer.To = Tracer.To
                        OutlineTracer.Color = Color3.new(0.1, 0.1, 0.1)
                    else
                        Tracer.Visible = false
                        OutlineTracer.Visible = false
                    end

                    if ScreenPosition.Z > 0 then
                        local ScreenPositionUpper = ScreenPosition

                        if Options.ShowName.Value then
                            LocalPlayer.NameDisplayDistance = 0
                            NameTag.Visible = true
                            NameTag.Text = v.Text
                            NameTag.Size = Options.TextSize.Value
                            NameTag.Outline = Options.TextOutline.Value
                            NameTag.Position = V2New(ScreenPositionUpper.X, ScreenPositionUpper.Y)
                            NameTag.Color = Color

                            if Drawing.Fonts and shared.am_ic3 then
                                NameTag.Font = Drawing.Fonts.Monospace
                            end
                        else
                            LocalPlayer.NameDisplayDistance = 100
                            NameTag.Visible = false
                        end

                        if Options.ShowDistance.Value or Options.ShowHealth.Value then
                            DistanceTag.Visible = true
                            DistanceTag.Size = Options.TextSize.Value - 1
                            DistanceTag.Outline = Options.TextOutline.Value
                            DistanceTag.Color = Color3.new(1, 1, 1)

                            if Drawing.Fonts and shared.am_ic3 then
                                NameTag.Font = Drawing.Fonts.Monospace
                            end

                            local Str = ""

                            if Options.ShowDistance.Value then
                                Str = Str .. Format("[%d] ", Distance)
                            end

                            DistanceTag.Text = Str
                            DistanceTag.Position = V2New(
                                ScreenPositionUpper.X,
                                ScreenPositionUpper.Y
                            ) + V2New(0, NameTag.TextBounds.Y)
                        else
                            DistanceTag.Visible = false
                        end
                    else
                        NameTag.Visible = false
                        DistanceTag.Visible = false
                    end
                else
                    NameTag.Visible = false
                    DistanceTag.Visible = false
                    Tracer.Visible = false
                    OutlineTracer.Visible = false
                end

                Data.Instances["NameTag"] = NameTag
                Data.Instances["DistanceTag"] = DistanceTag
                Data.Instances["Tracer"] = Tracer
                Data.Instances["OutlineTracer"] = OutlineTracer

                shared.InstanceData[v.Instance:GetDebugId()] = Data
            end
        end

        for i, v in pairs(Players:GetPlayers()) do
            local Data = shared.InstanceData[v.Name] or { Instances = {} }

            Data.Instances["Box"] = Data.Instances["Box"] or LineBox:Create({ Thickness = 4 })
            Data.Instances["OutlineTracer"] = Data.Instances["OutlineTracer"]
                or NewDrawing("Line")({
                    Transparency = 1,
                    Thickness = 3,
                    Color = Color3.new(0.1, 0.1, 0.1),
                })
            Data.Instances["Tracer"] = Data.Instances["Tracer"]
                or NewDrawing("Line")({
                    Transparency = 1,
                    Thickness = 1,
                })
            Data.Instances["HeadDot"] = Data.Instances["HeadDot"]
                or NewDrawing("Circle")({
                    Filled = true,
                    NumSides = 30,
                })
            Data.Instances["NameTag"] = Data.Instances["NameTag"]
                or NewDrawing("Text")({
                    Size = Options.TextSize.Value,
                    Center = true,
                    Outline = Options.TextOutline.Value,
                    OutlineOpacity = 1,
                    Visible = true,
                })
            Data.Instances["DistanceHealthTag"] = Data.Instances["DistanceHealthTag"]
                or NewDrawing("Text")({
                    Size = Options.TextSize.Value - 1,
                    Center = true,
                    Outline = Options.TextOutline.Value,
                    OutlineOpacity = 1,
                    Visible = true,
                })

            local NameTag = Data.Instances["NameTag"]
            local DistanceTag = Data.Instances["DistanceHealthTag"]
            local Tracer = Data.Instances["Tracer"]
            local OutlineTracer = Data.Instances["OutlineTracer"]
            local HeadDot = Data.Instances["HeadDot"]
            local Box = Data.Instances["Box"]

            local Character = GetCharacter(v)
            local Pass, Distance = CheckPlayer(v, Character)

            if Pass and Character then
                local Humanoid = Character:FindFirstChildOfClass("Humanoid")
                local Head = Character:FindFirstChild("Head")
                local HumanoidRootPart =
                    Character:FindFirstChild(CustomRootPartName or "HumanoidRootPart")

                local Dead = (Humanoid and (Humanoid.Health <= 0))

                if type(GetAliveState) == "function" then
                    Dead = (not GetAliveState(v, Character))
                end

                if Character ~= nil and Head and HumanoidRootPart and not Dead then
                    local ScreenPosition, Vis = WorldToViewport(Head.Position)
                    local Color = Rainbow and Color3.fromHSV(tick() * 128 % 255 / 255, 1, 1)
                        or (CheckTeam(v) and TeamColor or EnemyColor)
                    Color = Options.ShowTeamColor.Value and v.TeamColor and v.TeamColor.Color
                        or Color

                    local OPos = Camera.CFrame:PointToObjectSpace(Head.Position)

                    if ScreenPosition.Z < 0 then
                        local AT = math.atan2(OPos.Y, OPos.X) + math.pi

                        OPos = CFrame.Angles(0, 0, AT):VectorToWorldSpace(
                            (
                                CFrame.Angles(0, math.rad(89.9), 0)
                                    :VectorToWorldSpace(V3New(0, 0, -1))
                            )
                        )
                    end

                    local Position = WorldToViewport(Camera.CFrame:PointToWorldSpace(OPos))

                    if Options.ShowTracers.Value then
                        if
                            TracerPosition.X >= Camera.ViewportSize.X
                            or TracerPosition.Y >= Camera.ViewportSize.Y
                            or TracerPosition.X < 0
                            or TracerPosition.Y < 0
                        then
                            TracerPosition =
                                V2New(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y - 135)
                        end

                        Tracer.Visible = true
                        Tracer.Transparency = math.clamp(1 - (Distance / 200), 0.25, 0.75)
                        Tracer.From = TracerPosition
                        Tracer.To = Runtime.ScreenEdge(Position)
                        Tracer.Color = Color
                        OutlineTracer.From = Tracer.From
                        OutlineTracer.To = Tracer.To
                        OutlineTracer.Transparency = Tracer.Transparency - 0.15
                        OutlineTracer.Visible = true
                    else
                        Tracer.Visible = false
                        OutlineTracer.Visible = false
                    end

                    if ScreenPosition.Z > 0 then
                        local ScreenPositionUpper = WorldToViewport(
                            (HumanoidRootPart:GetRenderCFrame() * CFrame.new(
                                0,
                                Head.Size.Y + HumanoidRootPart.Size.Y + (Options.YOffset.Value / 25),
                                0
                            )).Position
                        )

                        local Scale = Head.Size.Y / 2

                        if Options.ShowName.Value then
                            NameTag.Visible = true
                            NameTag.Text = v.Name .. (CustomPlayerTag and CustomPlayerTag(v) or "")
                            NameTag.Size = Options.TextSize.Value
                            NameTag.Outline = Options.TextOutline.Value
                            NameTag.Position = V2New(ScreenPositionUpper.X, ScreenPositionUpper.Y)
                                - V2New(0, NameTag.TextBounds.Y)
                            NameTag.Color = Color
                            NameTag.Color = Color
                            NameTag.OutlineColor = Color3.new(0.05, 0.05, 0.05)
                            NameTag.Transparency = 0.85

                            if Drawing.Fonts and shared.am_ic3 then
                                NameTag.Font = Drawing.Fonts.Monospace
                            end
                        else
                            NameTag.Visible = false
                        end

                        if Options.ShowDistance.Value or Options.ShowHealth.Value then
                            DistanceTag.Visible = true
                            DistanceTag.Size = Options.TextSize.Value - 1
                            DistanceTag.Outline = Options.TextOutline.Value
                            DistanceTag.Color = Color3.new(1, 1, 1)
                            DistanceTag.Transparency = 0.85

                            if Drawing.Fonts and shared.am_ic3 then
                                NameTag.Font = Drawing.Fonts.Monospace
                            end

                            local Str = ""

                            if Options.ShowDistance.Value then
                                Str = Str .. Format("[%d] ", Distance)
                            end

                            if Options.ShowHealth.Value then
                                if typeof(Humanoid) == "Instance" then
                                    Str = Str
                                        .. Format(
                                            "[%d/%d] [%s%%]",
                                            Humanoid.Health,
                                            Humanoid.MaxHealth,
                                            math.floor(Humanoid.Health / Humanoid.MaxHealth * 100)
                                        )
                                elseif type(GetHealth) == "function" then
                                    local health, maxHealth = GetHealth(v)

                                    if type(health) == "number" and type(maxHealth) == "number" then
                                        Str = Str
                                            .. Format(
                                                "[%d/%d] [%s%%]",
                                                health,
                                                maxHealth,
                                                math.floor(health / maxHealth * 100)
                                            )
                                    end
                                end
                            end

                            DistanceTag.Text = Str
                            DistanceTag.OutlineColor = Color3.new(0.05, 0.05, 0.05)
                            DistanceTag.Position = (
                                NameTag.Visible
                                    and NameTag.Position + V2New(0, NameTag.TextBounds.Y)
                                or V2New(ScreenPositionUpper.X, ScreenPositionUpper.Y)
                            )
                        else
                            DistanceTag.Visible = false
                        end

                        if Options.ShowDot.Value and Vis then
                            local Top =
                                WorldToViewport((Head.CFrame * CFrame.new(0, Scale, 0)).Position)

                            local Bottom =
                                WorldToViewport((Head.CFrame * CFrame.new(0, -Scale, 0)).Position)

                            local Radius = math.abs((Top - Bottom).Y)

                            HeadDot.Visible = true
                            HeadDot.Color = Color
                            HeadDot.Position = V2New(ScreenPosition.X, ScreenPosition.Y)
                            HeadDot.Radius = math.min(Radius, 10000)
                        else
                            HeadDot.Visible = false
                        end

                        if Options.ShowBoxes.Value and Vis and HumanoidRootPart then
                            local Body = {
                                Head,
                                Character:FindFirstChild("Left Leg")
                                    or Character:FindFirstChild("LeftLowerLeg"),
                                Character:FindFirstChild("Right Leg")
                                    or Character:FindFirstChild("RightLowerLeg"),
                                Character:FindFirstChild("Left Arm")
                                    or Character:FindFirstChild("LeftLowerArm"),
                                Character:FindFirstChild("Right Arm")
                                    or Character:FindFirstChild("RightLowerArm"),
                            }
                            Box:Update(
                                HumanoidRootPart.CFrame,
                                V3New(2, 3, 1) * (Scale * 2),
                                Color,
                                nil,
                                shared.am_ic3 and Body
                            )
                        else
                            Box:SetVisible(false)
                        end
                    else
                        NameTag.Visible = false
                        DistanceTag.Visible = false
                        HeadDot.Visible = false

                        Box:SetVisible(false)
                    end
                else
                    NameTag.Visible = false
                    DistanceTag.Visible = false
                    HeadDot.Visible = false
                    Tracer.Visible = false
                    OutlineTracer.Visible = false

                    Box:SetVisible(false)
                end
            else
                NameTag.Visible = false
                DistanceTag.Visible = false
                HeadDot.Visible = false
                Tracer.Visible = false
                OutlineTracer.Visible = false

                Box:SetVisible(false)
            end

            shared.InstanceData[v.Name] = Data
        end
    end
end

local LastInvalidCheck = 0

local function Update()
    if tick() - LastInvalidCheck > 0.3 then
        LastInvalidCheck = tick()

        if false then
            Camera = workspace.CurrentCamera
            CameraCon()
            WTVP = Camera.WorldToViewportPoint
        end

        for i, v in pairs(shared.InstanceData) do
            if not Players:FindFirstChild(tostring(i)) then
                if not shared.InstanceData[i].DontDelete then
                    GetTableData(v.Instances)(function(i, obj)
                        obj.Visible = false
                        obj:Remove()
                        v.Instances[i] = nil
                    end)

                    shared.InstanceData[i] = nil
                else
                    if
                        shared.InstanceData[i].Instance == nil
                        or shared.InstanceData[i].Instance.Parent == nil
                    then
                        GetTableData(v.Instances)(function(i, obj)
                            obj.Visible = false
                            obj:Remove()
                            v.Instances[i] = nil
                        end)

                        shared.InstanceData[i] = nil
                    end
                end
            end
        end
    end

    local CX = Menu:GetInstance("CrosshairX")
    local CY = Menu:GetInstance("CrosshairY")

    if Options.Crosshair.Value then
        CX.Visible = true
        CY.Visible = true

        CX.To = V2New((Camera.ViewportSize.X / 2) - 8, (Camera.ViewportSize.Y / 2))
        CX.From = V2New((Camera.ViewportSize.X / 2) + 8, (Camera.ViewportSize.Y / 2))
        CY.To = V2New((Camera.ViewportSize.X / 2), (Camera.ViewportSize.Y / 2) - 8)
        CY.From = V2New((Camera.ViewportSize.X / 2), (Camera.ViewportSize.Y / 2) + 8)
    else
        CX.Visible = false
        CY.Visible = false
    end

    if Options.MenuOpen.Value and MenuLoaded then
        local MLocation = GetMouseLocation()

        shared.MenuDrawingData.Instances.Main.Color = Color3.fromHSV(tick() * 24 % 255 / 255, 1, 1)

        local MainInstance = Menu:GetInstance("Main")

        local Values = {
            MainInstance.Position.X,
            MainInstance.Position.Y,
            MainInstance.Position.X + MainInstance.Size.X,
            MainInstance.Position.Y + MainInstance.Size.Y,
        }

        if
            MainInstance
            and (MouseHoveringOver(Values) or (SubMenu.Open and MouseHoveringOver(SubMenu.Bounds)))
        then
            Debounce.CursorVis = true

            Menu:UpdateMenuInstance("Cursor1")({
                Visible = true,
                From = V2New(MLocation.x, MLocation.y),
                To = V2New(MLocation.x + 5, MLocation.y + 6),
            })
            Menu:UpdateMenuInstance("Cursor2")({
                Visible = true,
                From = V2New(MLocation.x, MLocation.y),
                To = V2New(MLocation.x, MLocation.y + 8),
            })
            Menu:UpdateMenuInstance("Cursor3")({
                Visible = true,
                From = V2New(MLocation.x, MLocation.y + 6),
                To = V2New(MLocation.x + 5, MLocation.y + 5),
            })
        else
            if Debounce.CursorVis then
                Debounce.CursorVis = false

                Menu:UpdateMenuInstance("Cursor1")({ Visible = false })
                Menu:UpdateMenuInstance("Cursor2")({ Visible = false })
                Menu:UpdateMenuInstance("Cursor3")({ Visible = false })
            end
        end

        if MouseHeld then
            local MousePos = GetMouseLocation()

            if Dragging then
                DraggingWhat.Slider.Position = V2New(
                    math.clamp(
                        MLocation.X - DraggingWhat.Slider.Size.X / 2,
                        DraggingWhat.Line.Position.X,
                        DraggingWhat.Line.Position.X
                            + DraggingWhat.Line.Size.X
                            - DraggingWhat.Slider.Size.X
                    ),
                    DraggingWhat.Slider.Position.Y
                )

                local Percent = (DraggingWhat.Slider.Position.X - DraggingWhat.Line.Position.X)
                    / (
                        (
                            DraggingWhat.Line.Position.X
                            + DraggingWhat.Line.Size.X
                            - DraggingWhat.Line.Position.X
                        ) - DraggingWhat.Slider.Size.X
                    )

                local Value = CalculateValue(DraggingWhat.Min, DraggingWhat.Max, Percent)

                DraggingWhat.Option(Value)
            elseif DraggingUI then
                Debounce.UIDrag = true

                local Main = Menu:GetInstance("Main")

                Main.Position = MousePos + DragOffset
            elseif DragTracerPosition then
                TracerPosition = MousePos
            end
        else
            Dragging = false
            DragTracerPosition = false

            if DraggingUI and Debounce.UIDrag then
                Debounce.UIDrag = false
                DraggingUI = false
                CreateMenu(Menu:GetInstance("Main").Position)
            end
        end

        if not Debounce.Menu then
            Debounce.Menu = true
            ToggleMenu()
        end
    elseif Debounce.Menu and not Options.MenuOpen.Value then
        Debounce.Menu = false
        ToggleMenu()
    end
end

RunService:UnbindFromRenderStep(GetDataName)
RunService:UnbindFromRenderStep(UpdateName)

RunService:BindToRenderStep(GetDataName, 300, UpdatePlayerData)
RunService:BindToRenderStep(UpdateName, 199, Update)

local Controller = { Options = Options, Runtime = Runtime, Stop = Runtime.Stop }

function Controller.AddInstance(Object, Label, Color)
    return RenderList:AddOrUpdateInstance(
        Object,
        Object,
        Label or Object.Name,
        Color or Color3.new(1, 1, 1)
    )
end

function Controller.RemoveInstance(Object)
    RenderList.Instances[Object] = nil
end

getgenv().UnnamedEsp = Controller
Runtime.Step("EspInput", 500, function()
    local Current = {}
    for _, Entry in UIButtons do
        Current[Entry] = true
        if not Entry.Control then
            local Success, Control = pcall(
                Runtime.Control,
                "TextButton",
                { Text = "", BackgroundTransparency = 1, ZIndex = 1100 }
            )
            if Success then
                Entry.Control = Control
                Runtime.Connect(Control.MouseButton1Click, function()
                    Runtime.Try("Button", Entry.Option)
                end)
            end
        end
        if Entry.Control then
            Entry.Control.Position = Entry.Instance.Position
            Entry.Control.Size = Entry.Instance.Size
            Entry.Control.Visible = Options.MenuOpen.Value
                and (not SubMenu.Open or Entry.FromSubMenu == true)
        end
    end
    Runtime.EspButtons = Runtime.EspButtons or {}
    for Entry in Runtime.EspButtons do
        if not Current[Entry] and Entry.Control then
            Entry.Control:Destroy()
            Entry.Control = nil
        end
    end
    Runtime.EspButtons = Current
    local Main = Menu:GetInstance("Main")
    if Options.MenuOpen.Value and Main and Main.Visible then
        Runtime.Capture(
            false,
            { X = Main.Position.X, Y = Main.Position.Y, Width = Main.Size.X, Height = Main.Size.Y }
        )
    else
        Runtime.Capture(false, nil)
    end
end)

Runtime.Start()
print("Unnamed ESP for Vortex loaded. F4: menu, F3: toggle")

return Controller
