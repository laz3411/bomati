--[[
    관리자 비행/투명화 클라이언트 스크립트

    설치 위치: StarterPlayer > StarterPlayerScripts

    Shift + F: 비행 켜기/끄기
    Shift + V: 투명화 켜기/끄기
    W/A/S/D: 이동
    Space: 상승
    LeftControl: 하강
    비행 중 마우스 휠: 속도 조절
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local checkRemote = ReplicatedStorage:WaitForChild("AdminAbilityCheck", 15)
local appearanceRemote = ReplicatedStorage:WaitForChild("AdminAppearanceRequest", 15)

if not checkRemote or not appearanceRemote then
    warn("[관리자 기능] 서버 스크립트를 찾지 못했습니다.")
    return
end

local success, isAdmin = pcall(function()
    return checkRemote:InvokeServer()
end)
if not success or isAdmin ~= true then
    return
end

local flying = false
local invisible = false
local bodyVelocity = nil
local bodyGyro = nil
local savedAutoRotate = true
local heldKeys = {}
local FLY_SPEED = 70
local MIN_FLY_SPEED = 10
local MAX_FLY_SPEED = 250
local FLY_SPEED_STEP = 10

local statusGui = Instance.new("ScreenGui")
statusGui.Name = "AdminAbilityStatus"
statusGui.ResetOnSpawn = false
statusGui.Parent = player:WaitForChild("PlayerGui")

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(1, 0)
status.Position = UDim2.new(1, -18, 0, 18)
status.Size = UDim2.fromOffset(290, 32)
status.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
status.BackgroundTransparency = 0.2
status.BorderSizePixel = 0
status.Font = Enum.Font.GothamSemibold
status.TextColor3 = Color3.fromRGB(235, 240, 250)
status.TextSize = 13
status.Text = "관리자 기능: Shift+F 비행 · Shift+V 투명화"
status.Visible = false
status.Parent = statusGui

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 8)
statusCorner.Parent = status

local function getCharacterParts()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return character, humanoid, root
end

local function setStatus(text, visible)
    status.Text = text
    status.Visible = visible
end

local function stopFlying()
    flying = false

    if bodyVelocity then
        bodyVelocity:Destroy()
        bodyVelocity = nil
    end
    if bodyGyro then
        bodyGyro:Destroy()
        bodyGyro = nil
    end

    local _, humanoid = getCharacterParts()
    if humanoid then
        humanoid.PlatformStand = false
        humanoid.AutoRotate = savedAutoRotate
        humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
    end

    if not invisible then
        setStatus("관리자 기능: Shift+F 비행 · Shift+V 투명화", false)
    end
end

local function startFlying()
    local _, humanoid, root = getCharacterParts()
    if not humanoid or not root then
        return
    end

    flying = true
    savedAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false
    humanoid.PlatformStand = true

    bodyVelocity = Instance.new("BodyVelocity")
    bodyVelocity.Name = "AdminFlyVelocity"
    bodyVelocity.MaxForce = Vector3.new(1e9, 1e9, 1e9)
    bodyVelocity.P = 25000
    bodyVelocity.Velocity = Vector3.zero
    bodyVelocity.Parent = root

    bodyGyro = Instance.new("BodyGyro")
    bodyGyro.Name = "AdminFlyRotation"
    bodyGyro.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
    bodyGyro.P = 25000
    bodyGyro.D = 800
    bodyGyro.CFrame = root.CFrame
    bodyGyro.Parent = root

    setStatus(string.format("비행 ON · Shift+F 끄기 · 속도 %d · 휠로 조절", FLY_SPEED), true)
end

local function toggleFlying()
    if flying then
        stopFlying()
    else
        startFlying()
    end
end

local function toggleInvisible()
    invisible = not invisible
    appearanceRemote:FireServer(invisible)

    if invisible then
        setStatus("투명화 ON · Shift+V 끄기", true)
    elseif flying then
        setStatus(string.format("비행 ON · Shift+F 끄기 · 속도 %d · 휠로 조절", FLY_SPEED), true)
    else
        setStatus("관리자 기능: Shift+F 비행 · Shift+V 투명화", false)
    end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end

    local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

    if shiftHeld and input.KeyCode == Enum.KeyCode.F then
        toggleFlying()
        return
    elseif shiftHeld and input.KeyCode == Enum.KeyCode.V then
        toggleInvisible()
        return
    end

    if flying then
        heldKeys[input.KeyCode] = true
    end
end)

local function handleFlySpeedWheel(_, inputState, inputObject)
    if not flying then
        -- 비행 중이 아니면 Roblox 기본 카메라 줌이 휠을 사용할 수 있게 합니다.
        return Enum.ContextActionResult.Pass
    end

    if inputState == Enum.UserInputState.Change then
        local wheelDirection = inputObject.Position.Z
        if wheelDirection > 0 then
            FLY_SPEED = math.min(MAX_FLY_SPEED, FLY_SPEED + FLY_SPEED_STEP)
        elseif wheelDirection < 0 then
            FLY_SPEED = math.max(MIN_FLY_SPEED, FLY_SPEED - FLY_SPEED_STEP)
        end

        setStatus(string.format("비행 ON · Shift+F 끄기 · 속도 %d · 휠로 조절", FLY_SPEED), true)
    end

    -- 비행 중에는 카메라가 같은 휠 입력으로 줌되지 않게 차단합니다.
    return Enum.ContextActionResult.Sink
end

ContextActionService:BindActionAtPriority(
    "AdminFlySpeedWheel",
    handleFlySpeedWheel,
    false,
    Enum.ContextActionPriority.High.Value,
    Enum.UserInputType.MouseWheel
)

UserInputService.InputEnded:Connect(function(input)
    heldKeys[input.KeyCode] = nil
end)

UserInputService.WindowFocusReleased:Connect(function()
    heldKeys = {}
end)

RunService.RenderStepped:Connect(function()
    if not flying or not bodyVelocity or not bodyGyro then
        return
    end

    local _, humanoid, root = getCharacterParts()
    local camera = workspace.CurrentCamera
    if not humanoid or not root or not camera then
        stopFlying()
        return
    end

    local direction = Vector3.zero
    local cameraLook = camera.CFrame.LookVector
    local cameraRight = camera.CFrame.RightVector

    if heldKeys[Enum.KeyCode.W] then direction += cameraLook end
    if heldKeys[Enum.KeyCode.S] then direction -= cameraLook end
    if heldKeys[Enum.KeyCode.D] then direction += cameraRight end
    if heldKeys[Enum.KeyCode.A] then direction -= cameraRight end
    if heldKeys[Enum.KeyCode.Space] then direction += Vector3.yAxis end
    if heldKeys[Enum.KeyCode.LeftControl] then direction -= Vector3.yAxis end

    if direction.Magnitude > 0 then
        direction = direction.Unit
    end
    bodyVelocity.Velocity = direction * FLY_SPEED

    local facing = Vector3.new(cameraLook.X, 0, cameraLook.Z)
    if facing.Magnitude > 0.01 then
        bodyGyro.CFrame = CFrame.lookAt(root.Position, root.Position + facing.Unit)
    end
end)

player.CharacterAdded:Connect(function()
    stopFlying()
    invisible = false
end)
