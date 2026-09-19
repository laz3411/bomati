--[[
    버스 선택창 클라이언트 스크립트

    설치 위치: StarterPlayer > StarterPlayerScripts
    게임 안에서 B를 누르면 ReplicatedStorage.BusModels의 목록을 보여 줍니다.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local busFolder = ReplicatedStorage:WaitForChild("BusModels", 15)
local spawnRemote = ReplicatedStorage:WaitForChild("BusSpawnRequest", 15)
local catalogRemote = ReplicatedStorage:WaitForChild("BusCatalog", 15)

if not busFolder or not spawnRemote or not catalogRemote then
    warn("[버스 선택] 서버 스크립트의 RemoteEvent/RemoteFunction을 찾지 못했습니다.")
    return
end

local previewModel = nil
local previewBusName = nil
local previewRotation = 0
local PREVIEW_DISTANCE = 24
local PREVIEW_HEIGHT = 3
local ROTATION_STEP = math.rad(15)

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BusSelectorGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.fromScale(0.5, 0.5)
frame.Size = UDim2.fromOffset(390, 440)
frame.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
frame.BorderSizePixel = 0
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(20, 14)
title.Size = UDim2.new(1, -40, 0, 34)
title.Font = Enum.Font.GothamBold
title.Text = "버스 선택"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 22
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local help = Instance.new("TextLabel")
help.Name = "Help"
help.BackgroundTransparency = 1
help.Position = UDim2.fromOffset(20, 48)
help.Size = UDim2.new(1, -40, 0, 24)
help.Font = Enum.Font.Gotham
help.Text = "마우스 이동: 위치 · 휠/R: 회전 · 좌클릭/T: 설치 · B/ESC: 취소"
help.TextColor3 = Color3.fromRGB(180, 187, 200)
help.TextSize = 13
help.TextXAlignment = Enum.TextXAlignment.Left
help.Parent = frame

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -14, 0, 14)
closeButton.Size = UDim2.fromOffset(32, 32)
closeButton.BackgroundColor3 = Color3.fromRGB(55, 60, 72)
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 15
closeButton.Parent = frame

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeButton

local list = Instance.new("ScrollingFrame")
list.Name = "BusList"
list.Position = UDim2.fromOffset(20, 84)
list.Size = UDim2.new(1, -40, 1, -104)
list.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = frame

local listCorner = Instance.new("UICorner")
listCorner.CornerRadius = UDim.new(0, 8)
listCorner.Parent = list

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = list

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local function clearButtons()
    for _, child in ipairs(list:GetChildren()) do
        if child:IsA("TextButton") or child:IsA("TextLabel") then
            child:Destroy()
        end
    end
end

local function destroyPreview()
    if previewModel then
        previewModel:Destroy()
    end
    previewModel = nil
    previewBusName = nil
    previewRotation = 0
end

local function getPreviewCFrame()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return nil
    end

    local camera = workspace.CurrentCamera
    local look = camera and camera.CFrame.LookVector or root.CFrame.LookVector
    local forward = Vector3.new(look.X, 0, look.Z)
    if forward.Magnitude < 0.01 then
        local rootLook = root.CFrame.LookVector
        forward = Vector3.new(rootLook.X, 0, rootLook.Z)
    end
    if forward.Magnitude < 0.01 then
        forward = Vector3.new(0, 0, -1)
    else
        forward = forward.Unit
    end

    local position = root.Position + forward * PREVIEW_DISTANCE

    -- 미리보기 중에는 마우스가 가리키는 월드 표면으로 위치를 옮깁니다.
    -- 표면을 찾지 못하면 기존의 플레이어 앞쪽 배치를 유지합니다.
    if previewModel then
        local mousePosition = UserInputService:GetMouseLocation()
        local inset = GuiService:GetGuiInset()
        local ray = camera:ViewportPointToRay(
            mousePosition.X - inset.X,
            mousePosition.Y - inset.Y
        )
        local rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
        rayParams.FilterDescendantsInstances = { character, previewModel }
        rayParams.IgnoreWater = false
        local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, rayParams)
        if hit then
            position = hit.Position
        end
    end

    position = position + Vector3.new(0, PREVIEW_HEIGHT, 0)
    local facing = CFrame.lookAt(position, position + forward)
    return facing * CFrame.Angles(0, previewRotation, 0)
end

local function updatePreview()
    if not previewModel or not previewModel.Parent then
        return
    end
    local placementCFrame = getPreviewCFrame()
    if placementCFrame then
        previewModel:PivotTo(placementCFrame)
    end
end

local function makePreview(busName)
    destroyPreview()

    local source = busFolder:FindFirstChild(busName)
    if not source or not source:IsA("Model") then
        warn("[버스 선택] 선택한 버스를 찾지 못했습니다:", tostring(busName))
        return
    end

    previewBusName = busName
    previewRotation = 0
    previewModel = source:Clone()

    -- 미리보기 안의 Script가 실행되거나 실제 차량 입력을 가로채지 않도록 제거합니다.
    for _, descendant in ipairs(previewModel:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        elseif descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.LocalTransparencyModifier = math.max(descendant.LocalTransparencyModifier, 0.35)
        end
    end

    local outline = Instance.new("Highlight")
    outline.Name = "PlacementOutline"
    outline.Adornee = previewModel
    outline.FillColor = Color3.fromRGB(80, 190, 255)
    outline.FillTransparency = 0.82
    outline.OutlineColor = Color3.fromRGB(255, 230, 80)
    outline.OutlineTransparency = 0
    outline.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    outline.Parent = previewModel

    previewModel.Parent = workspace
    updatePreview()
end

local function addMessage(text)
    local message = Instance.new("TextLabel")
    message.Size = UDim2.new(1, -4, 0, 42)
    message.BackgroundTransparency = 1
    message.Font = Enum.Font.Gotham
    message.Text = text
    message.TextColor3 = Color3.fromRGB(190, 195, 205)
    message.TextSize = 14
    message.TextWrapped = true
    message.Parent = list
end

local function refreshList()
    clearButtons()

    local success, names = pcall(function()
        return catalogRemote:InvokeServer()
    end)
    if not success or type(names) ~= "table" or #names == 0 then
        addMessage("ReplicatedStorage > BusModels 폴더에 Model을 넣어 주세요.")
        return
    end

    for index, busName in ipairs(names) do
        local button = Instance.new("TextButton")
        button.Name = "Bus_" .. tostring(index)
        button.LayoutOrder = index
        button.Size = UDim2.new(1, -4, 0, 46)
        button.BackgroundColor3 = Color3.fromRGB(42, 48, 60)
        button.AutoButtonColor = true
        button.Font = Enum.Font.GothamSemibold
        button.Text = tostring(busName)
        button.TextColor3 = Color3.fromRGB(255, 255, 255)
        button.TextSize = 15
        button.TextTruncate = Enum.TextTruncate.AtEnd
        button.Parent = list

        local buttonCorner = Instance.new("UICorner")
        buttonCorner.CornerRadius = UDim.new(0, 7)
        buttonCorner.Parent = button

        button.Activated:Connect(function()
            makePreview(busName)
            screenGui.Enabled = false
        end)
    end
end

local function toggleSelector()
    screenGui.Enabled = not screenGui.Enabled
    if screenGui.Enabled then
        refreshList()
    end
end

local function isShiftHeld()
    return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

closeButton.Activated:Connect(function()
    screenGui.Enabled = false
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if UserInputService:GetFocusedTextBox() then
        return
    end

    -- Shift+N은 관리자 월드 초기화입니다. 서버가 실제 소환물을 지우기 전에
    -- 이 클라이언트에만 존재하는 배치 미리보기와 선택창도 함께 닫습니다.
    if isShiftHeld() and input.KeyCode == Enum.KeyCode.N then
        destroyPreview()
        screenGui.Enabled = false
        return
    end

    -- 미리보기 중에는 마우스 클릭을 배치 조작으로 사용합니다.
    if previewModel then
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            local placementCFrame = getPreviewCFrame()
            if placementCFrame and previewBusName then
                local installName = previewBusName
                destroyPreview()
                spawnRemote:FireServer(installName, placementCFrame)
            end
            return
        elseif input.UserInputType == Enum.UserInputType.MouseWheel then
            previewRotation = previewRotation + ROTATION_STEP * (input.Position.Z >= 0 and 1 or -1)
            updatePreview()
            return
        end
    end

    if gameProcessed then
        return
    end

    if input.KeyCode == Enum.KeyCode.B then
        if previewModel then
            destroyPreview()
        else
            toggleSelector()
        end
    elseif input.KeyCode == Enum.KeyCode.R and previewModel then
        previewRotation = previewRotation + ROTATION_STEP
        updatePreview()
    elseif input.KeyCode == Enum.KeyCode.T and previewModel and previewBusName then
        local placementCFrame = getPreviewCFrame()
        if placementCFrame then
            local installName = previewBusName
            destroyPreview()
            spawnRemote:FireServer(installName, placementCFrame)
        end
    elseif input.KeyCode == Enum.KeyCode.Escape and screenGui.Enabled then
        screenGui.Enabled = false
    elseif input.KeyCode == Enum.KeyCode.Escape and previewModel then
        destroyPreview()
    end
end)

RunService.RenderStepped:Connect(function()
    if previewModel then
        updatePreview()
    end
end)
