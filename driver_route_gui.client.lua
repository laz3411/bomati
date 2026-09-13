--[[
    버스 상행/하행 운행 시작 GUI
    설치 위치: StarterPlayer > StarterPlayerScripts > LocalScript

    서버의 roblox_script.lua가 만드는 BusRouteDirectionRequest RemoteEvent와 연결됩니다.
    운전석(VehicleSeat)에 앉으면 상행/하행을 선택하고 운행을 시작할 수 있습니다.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local routeDirectionRemote = ReplicatedStorage:WaitForChild("BusRouteDirectionRequest", 20)

if not routeDirectionRemote then
    warn("[운행 방향 GUI] BusRouteDirectionRequest를 찾지 못했습니다. roblox_script.lua를 확인하세요.")
    return
end

local selectedDirection = "up"
local currentBus = nil
local activeDriverBus = nil
local requestPending = false
local humanoidConnection = nil

local function addCorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = parent
    return corner
end

local function addStroke(parent, color, transparency, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Transparency = transparency
    stroke.Thickness = thickness
    stroke.Parent = parent
    return stroke
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BusRouteDirectionGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.DisplayOrder = 45
screenGui.Enabled = false
screenGui.Parent = playerGui

local shade = Instance.new("Frame")
shade.Name = "Shade"
shade.Size = UDim2.fromScale(1, 1)
shade.BackgroundColor3 = Color3.fromRGB(2, 8, 23)
shade.BackgroundTransparency = 0.28
shade.BorderSizePixel = 0
shade.Parent = screenGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.new(0.88, 0, 0, 310)
panel.BackgroundColor3 = Color3.fromRGB(13, 31, 54)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.ClipsDescendants = true
panel.Parent = shade
addCorner(panel, 24)
addStroke(panel, Color3.fromRGB(125, 211, 252), 0.52, 1)

local sizeConstraint = Instance.new("UISizeConstraint")
sizeConstraint.MinSize = Vector2.new(300, 310)
sizeConstraint.MaxSize = Vector2.new(440, 310)
sizeConstraint.Parent = panel

local panelGradient = Instance.new("UIGradient")
panelGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(25, 58, 94)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(9, 20, 39))
})
panelGradient.Rotation = 135
panelGradient.Parent = panel

local topGlow = Instance.new("Frame")
topGlow.Size = UDim2.new(1, 0, 0, 3)
topGlow.BackgroundColor3 = Color3.fromRGB(56, 189, 248)
topGlow.BackgroundTransparency = 0.12
topGlow.BorderSizePixel = 0
topGlow.Parent = panel

local eyebrow = Instance.new("TextLabel")
eyebrow.BackgroundTransparency = 1
eyebrow.Position = UDim2.fromOffset(22, 21)
eyebrow.Size = UDim2.new(1, -44, 0, 18)
eyebrow.Font = Enum.Font.GothamBold
eyebrow.Text = "BOMATI DRIVER"
eyebrow.TextColor3 = Color3.fromRGB(125, 211, 252)
eyebrow.TextSize = 11
eyebrow.TextXAlignment = Enum.TextXAlignment.Left
eyebrow.Parent = panel

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(22, 42)
title.Size = UDim2.new(1, -44, 0, 32)
title.Font = Enum.Font.GothamBold
title.Text = "운행 방향을 선택하세요"
title.TextColor3 = Color3.fromRGB(248, 250, 252)
title.TextSize = 22
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = panel

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -18, 0, 17)
closeButton.Size = UDim2.fromOffset(34, 34)
closeButton.BackgroundColor3 = Color3.fromRGB(30, 58, 86)
closeButton.BackgroundTransparency = 0.18
closeButton.BorderSizePixel = 0
closeButton.Text = "✕"
closeButton.TextColor3 = Color3.fromRGB(226, 232, 240)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 15
closeButton.ZIndex = 5
closeButton.Parent = panel
addCorner(closeButton, 11)
addStroke(closeButton, Color3.fromRGB(186, 230, 253), 0.65, 1)

local busInfo = Instance.new("TextLabel")
busInfo.BackgroundTransparency = 1
busInfo.Position = UDim2.fromOffset(22, 76)
busInfo.Size = UDim2.new(1, -44, 0, 22)
busInfo.Font = Enum.Font.Gotham
busInfo.Text = "버스 정보를 확인하는 중입니다."
busInfo.TextColor3 = Color3.fromRGB(186, 230, 253)
busInfo.TextSize = 13
busInfo.TextXAlignment = Enum.TextXAlignment.Left
busInfo.TextTruncate = Enum.TextTruncate.AtEnd
busInfo.Parent = panel

local slider = Instance.new("Frame")
slider.Name = "DirectionSlider"
slider.Position = UDim2.fromOffset(22, 116)
slider.Size = UDim2.new(1, -44, 0, 66)
slider.BackgroundColor3 = Color3.fromRGB(5, 19, 38)
slider.BackgroundTransparency = 0.22
slider.BorderSizePixel = 0
slider.Parent = panel
addCorner(slider, 17)
addStroke(slider, Color3.fromRGB(125, 211, 252), 0.72, 1)

local knob = Instance.new("Frame")
knob.Name = "SelectedDirection"
knob.Position = UDim2.new(0, 5, 0, 5)
knob.Size = UDim2.new(0.5, -8, 1, -10)
knob.BackgroundColor3 = Color3.fromRGB(2, 132, 199)
knob.BorderSizePixel = 0
knob.Parent = slider
addCorner(knob, 13)
addStroke(knob, Color3.fromRGB(186, 230, 253), 0.45, 1)

local knobGradient = Instance.new("UIGradient")
knobGradient.Color = ColorSequence.new(Color3.fromRGB(14, 165, 233), Color3.fromRGB(37, 99, 235))
knobGradient.Rotation = 110
knobGradient.Parent = knob

local upButton = Instance.new("TextButton")
upButton.Name = "Up"
upButton.Size = UDim2.new(0.5, 0, 1, 0)
upButton.BackgroundTransparency = 1
upButton.Text = "상행"
upButton.TextColor3 = Color3.fromRGB(255, 255, 255)
upButton.Font = Enum.Font.GothamBold
upButton.TextSize = 16
upButton.ZIndex = 3
upButton.Parent = slider

local downButton = Instance.new("TextButton")
downButton.Name = "Down"
downButton.Position = UDim2.fromScale(0.5, 0)
downButton.Size = UDim2.new(0.5, 0, 1, 0)
downButton.BackgroundTransparency = 1
downButton.Text = "하행"
downButton.TextColor3 = Color3.fromRGB(148, 163, 184)
downButton.Font = Enum.Font.GothamBold
downButton.TextSize = 16
downButton.ZIndex = 3
downButton.Parent = slider

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(22, 190)
status.Size = UDim2.new(1, -44, 0, 34)
status.Font = Enum.Font.Gotham
status.Text = "정류장 태그에 맞는 방향별 정차 순서가 적용됩니다."
status.TextColor3 = Color3.fromRGB(148, 163, 184)
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = panel

local confirmButton = Instance.new("TextButton")
confirmButton.Name = "Confirm"
confirmButton.Position = UDim2.new(0, 22, 1, -66)
confirmButton.Size = UDim2.new(1, -44, 0, 46)
confirmButton.BackgroundColor3 = Color3.fromRGB(14, 165, 233)
confirmButton.BorderSizePixel = 0
confirmButton.Text = "상행 운행 시작"
confirmButton.TextColor3 = Color3.fromRGB(255, 255, 255)
confirmButton.Font = Enum.Font.GothamBold
confirmButton.TextSize = 15
confirmButton.Parent = panel
addCorner(confirmButton, 14)
addStroke(confirmButton, Color3.fromRGB(186, 230, 253), 0.5, 1)

local confirmGradient = Instance.new("UIGradient")
confirmGradient.Color = ColorSequence.new(Color3.fromRGB(14, 165, 233), Color3.fromRGB(37, 99, 235))
confirmGradient.Rotation = 115
confirmGradient.Parent = confirmButton

local toastGui = Instance.new("ScreenGui")
toastGui.Name = "BusRouteDirectionToastGui"
toastGui.ResetOnSpawn = false
toastGui.DisplayOrder = 46
toastGui.Parent = playerGui

local toast = Instance.new("TextLabel")
toast.AnchorPoint = Vector2.new(0.5, 0)
toast.Position = UDim2.new(0.5, 0, 0, -80)
toast.Size = UDim2.new(0.86, 0, 0, 58)
toast.BackgroundColor3 = Color3.fromRGB(8, 47, 73)
toast.BackgroundTransparency = 0.08
toast.BorderSizePixel = 0
toast.Font = Enum.Font.GothamBold
toast.TextColor3 = Color3.fromRGB(224, 242, 254)
toast.TextSize = 14
toast.TextWrapped = true
toast.Visible = false
toast.Parent = toastGui
addCorner(toast, 17)
addStroke(toast, Color3.fromRGB(34, 211, 238), 0.42, 1)

local toastConstraint = Instance.new("UISizeConstraint")
toastConstraint.MinSize = Vector2.new(290, 58)
toastConstraint.MaxSize = Vector2.new(460, 58)
toastConstraint.Parent = toast

local settingsButton = Instance.new("TextButton")
settingsButton.Name = "RouteDirectionSettings"
settingsButton.AnchorPoint = Vector2.new(1, 0)
settingsButton.Position = UDim2.new(1, -18, 0, 18)
settingsButton.Size = UDim2.fromOffset(50, 50)
settingsButton.BackgroundColor3 = Color3.fromRGB(8, 47, 73)
settingsButton.BackgroundTransparency = 0.08
settingsButton.BorderSizePixel = 0
settingsButton.Text = "⚙"
settingsButton.TextColor3 = Color3.fromRGB(224, 242, 254)
settingsButton.Font = Enum.Font.GothamBold
settingsButton.TextSize = 25
settingsButton.Visible = false
settingsButton.Parent = toastGui
addCorner(settingsButton, 16)
addStroke(settingsButton, Color3.fromRGB(34, 211, 238), 0.38, 1)

local function normalizeDirection(value)
    local text = string.lower(tostring(value or "")):gsub("%s+", "")
    if text == "down" or text == "downbound" or text == "하행" or text == "하" then return "down" end
    return "up"
end

local function findBusModel(instance)
    local highestTagged = nil
    local current = instance
    while current and current ~= workspace and current ~= game do
        if current:IsA("Model") then
            if CollectionService:HasTag(current, "BUS") then highestTagged = current end
            if not highestTagged and (current:GetAttribute("route") ~= nil or current:GetAttribute("Route") ~= nil) then
                highestTagged = current
            end
        end
        current = current.Parent
    end
    return highestTagged
end

local function formatLicense(model)
    local value = model and (model:GetAttribute("BusLicense") or model:GetAttribute("VehicleNumber"))
    if value == nil then return "차량번호 미설정" end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "차량번호 미설정" end
    if text:sub(-#("호")) == "호" then return text end
    if text:match("^%d+$") and #text < 4 then
        text = string.rep("0", 4 - #text) .. text
    end
    return text .. "호"
end

local function updateDirection(direction, instant)
    selectedDirection = normalizeDirection(direction)
    local targetPosition = selectedDirection == "up" and UDim2.new(0, 5, 0, 5) or UDim2.new(0.5, 3, 0, 5)
    if instant then
        knob.Position = targetPosition
    else
        TweenService:Create(knob, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Position = targetPosition
        }):Play()
    end
    upButton.TextColor3 = selectedDirection == "up" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(148, 163, 184)
    downButton.TextColor3 = selectedDirection == "down" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(148, 163, 184)
    local isChanging = currentBus and currentBus:GetAttribute("RouteDirectionConfirmed") == true
    confirmButton.Text = (selectedDirection == "up" and "상행" or "하행") .. (isChanging and " 방향 변경" or " 운행 시작")
end

local toastSequence = 0
local function showToast(message)
    toastSequence += 1
    local sequence = toastSequence
    toast.Text = "🚌  " .. tostring(message)
    toast.Visible = true
    toast.Position = UDim2.new(0.5, 0, 0, -80)
    TweenService:Create(toast, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.new(0.5, 0, 0, 22)
    }):Play()
    task.delay(3.2, function()
        if sequence ~= toastSequence then return end
        local tween = TweenService:Create(toast, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Position = UDim2.new(0.5, 0, 0, -80)
        })
        tween:Play()
        tween.Completed:Wait()
        if sequence == toastSequence then toast.Visible = false end
    end)
end

local function showForBus(model)
    if not model then return end
    currentBus = model
    activeDriverBus = model
    requestPending = false
    local route = tostring(model:GetAttribute("route") or model:GetAttribute("Route") or model.Name:match("%d+") or "노선 미설정")
    busInfo.Text = string.format("%s번 · %s", route, formatLicense(model))
    local isChanging = model:GetAttribute("RouteDirectionConfirmed") == true
    title.Text = isChanging and "운행 방향을 변경하세요" or "운행 방향을 선택하세요"
    status.Text = isChanging
        and "변경 즉시 선택한 방향의 정류장 순서로 갱신됩니다."
        or "정류장 태그에 맞는 방향별 정차 순서가 적용됩니다."
    status.TextColor3 = Color3.fromRGB(148, 163, 184)
    confirmButton.Active = true
    confirmButton.AutoButtonColor = true
    updateDirection(model:GetAttribute("RouteDirection") or "up", true)
    settingsButton.Visible = false
    screenGui.Enabled = true
    panel.Position = UDim2.fromScale(0.5, 0.54)
    panel.BackgroundTransparency = 0.35
    TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.fromScale(0.5, 0.5),
        BackgroundTransparency = 0.08
    }):Play()
end

local function handleSeatState(isSeated, seatPart)
    if not isSeated or not seatPart or not seatPart:IsA("VehicleSeat") then
        screenGui.Enabled = false
        currentBus = nil
        activeDriverBus = nil
        settingsButton.Visible = false
        requestPending = false
        return
    end
    local model = findBusModel(seatPart)
    if not model then return end
    activeDriverBus = model
    if model:GetAttribute("RouteDirectionConfirmed") == true then
        screenGui.Enabled = false
        currentBus = nil
        settingsButton.Visible = true
    else
        showForBus(model)
    end
end

local function connectCharacter(character)
    if humanoidConnection then humanoidConnection:Disconnect() end
    local humanoid = character:WaitForChild("Humanoid", 15)
    if not humanoid then return end
    humanoidConnection = humanoid.Seated:Connect(handleSeatState)
    if humanoid.SeatPart then handleSeatState(true, humanoid.SeatPart) end
end

upButton.Activated:Connect(function() updateDirection("up", false) end)
downButton.Activated:Connect(function() updateDirection("down", false) end)

settingsButton.Activated:Connect(function()
    if activeDriverBus and activeDriverBus:IsDescendantOf(workspace) then
        showForBus(activeDriverBus)
    end
end)

closeButton.Activated:Connect(function()
    if requestPending then return end
    screenGui.Enabled = false
    currentBus = nil
    settingsButton.Visible = activeDriverBus ~= nil and activeDriverBus:IsDescendantOf(workspace)
end)

confirmButton.Activated:Connect(function()
    if requestPending or not currentBus then return end
    requestPending = true
    confirmButton.Active = false
    confirmButton.AutoButtonColor = false
    confirmButton.Text = "운행 정보를 확인하는 중..."
    status.Text = "서버에서 운전석과 버스 정보를 확인하고 있습니다."
    status.TextColor3 = Color3.fromRGB(186, 230, 253)
    routeDirectionRemote:FireServer(currentBus, selectedDirection)
end)

routeDirectionRemote.OnClientEvent:Connect(function(result)
    if typeof(result) ~= "table" then return end
    requestPending = false
    if result.success == true then
        screenGui.Enabled = false
        showToast(result.message or "운행을 시작합니다.")
        currentBus = nil
        settingsButton.Visible = activeDriverBus ~= nil and activeDriverBus:IsDescendantOf(workspace)
        return
    end
    confirmButton.Active = true
    confirmButton.AutoButtonColor = true
    updateDirection(selectedDirection, true)
    status.Text = tostring(result.message or "운행 방향을 저장하지 못했습니다.")
    status.TextColor3 = Color3.fromRGB(253, 164, 175)
end)

player.CharacterAdded:Connect(connectCharacter)
if player.Character then connectCharacter(player.Character) end
