--[[
    버스 선택창 클라이언트 스크립트

    설치 위치: StarterPlayer > StarterPlayerScripts
    게임 안에서 B를 누르면 ReplicatedStorage.BusModels의 목록을 보여 줍니다.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local spawnRemote = ReplicatedStorage:WaitForChild("BusSpawnRequest", 15)
local catalogRemote = ReplicatedStorage:WaitForChild("BusCatalog", 15)

if not spawnRemote or not catalogRemote then
    warn("[버스 선택] 서버 스크립트의 RemoteEvent/RemoteFunction을 찾지 못했습니다.")
    return
end

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
help.Text = "B로 열고, 버스를 고르면 기존 버스가 교체됩니다."
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
            spawnRemote:FireServer(busName)
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

closeButton.Activated:Connect(function()
    screenGui.Enabled = false
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if UserInputService:GetFocusedTextBox() then
        return
    end
    if input.KeyCode == Enum.KeyCode.B then
        toggleSelector()
    elseif input.KeyCode == Enum.KeyCode.Escape and screenGui.Enabled then
        screenGui.Enabled = false
    end
end)
