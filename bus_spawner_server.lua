--[[
    버스 소환 서버 스크립트

    설치 위치: ServerScriptService

    ReplicatedStorage 안의 BusModels 폴더에 넣어 둔 Model만 소환합니다.
    클라이언트가 미리 배치한 CFrame으로 확정하되, 플레이어와 너무 먼 위치는 거부합니다.
    같은 플레이어가 새 버스를 소환하면, 그 플레이어가 전에 소환한 버스는 삭제됩니다.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local BUS_FOLDER_NAME = "BusModels"
local SPAWN_REMOTE_NAME = "BusSpawnRequest"
local CATALOG_REMOTE_NAME = "BusCatalog"
local SPAWN_COOLDOWN = 0.75

local busFolder = ReplicatedStorage:FindFirstChild(BUS_FOLDER_NAME)
if not busFolder then
    busFolder = Instance.new("Folder")
    busFolder.Name = BUS_FOLDER_NAME
    busFolder.Parent = ReplicatedStorage
end

local spawnRemote = ReplicatedStorage:FindFirstChild(SPAWN_REMOTE_NAME)
if not spawnRemote then
    spawnRemote = Instance.new("RemoteEvent")
    spawnRemote.Name = SPAWN_REMOTE_NAME
    spawnRemote.Parent = ReplicatedStorage
end

local catalogRemote = ReplicatedStorage:FindFirstChild(CATALOG_REMOTE_NAME)
if not catalogRemote then
    catalogRemote = Instance.new("RemoteFunction")
    catalogRemote.Name = CATALOG_REMOTE_NAME
    catalogRemote.Parent = ReplicatedStorage
end

local activeBuses = {} -- [player] = spawned Model
local lastRequestAt = {} -- [player] = os.clock()

local function getBusTemplates()
    local templates = {}
    for _, child in ipairs(busFolder:GetChildren()) do
        if child:IsA("Model") then
            table.insert(templates, child)
        end
    end
    table.sort(templates, function(a, b)
        return a.Name:lower() < b.Name:lower()
    end)
    return templates
end

catalogRemote.OnServerInvoke = function()
    local names = {}
    for _, template in ipairs(getBusTemplates()) do
        table.insert(names, template.Name)
    end
    return names
end

local function getFallbackCFrame(player)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root then
        local look = root.CFrame.LookVector
        local forward = Vector3.new(look.X, 0, look.Z)
        if forward.Magnitude < 0.01 then
            forward = Vector3.new(0, 0, -1)
        else
            forward = forward.Unit
        end
        local position = root.Position + forward * 24 + Vector3.new(0, 3, 0)
        return CFrame.lookAt(position, position + forward)
    end

    return CFrame.new(0, 5, 0)
end

local function isNearbyPlacement(player, placementCFrame)
    if typeof(placementCFrame) ~= "CFrame" then
        return false
    end

    local position = placementCFrame.Position
    -- NaN 값이 들어오면 비교 결과가 이상해질 수 있으므로 명시적으로 거부합니다.
    if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
        return false
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return false
    end

    return (position - root.Position).Magnitude <= 100
end

local function destroyActiveBus(player)
    local oldBus = activeBuses[player]
    activeBuses[player] = nil
    if oldBus and oldBus.Parent then
        oldBus:Destroy()
    end
end

local function hasBasePart(model)
    return model:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

spawnRemote.OnServerEvent:Connect(function(player, requestedName, requestedCFrame)
    if typeof(requestedName) ~= "string" then
        return
    end

    local now = os.clock()
    if now - (lastRequestAt[player] or 0) < SPAWN_COOLDOWN then
        return
    end
    lastRequestAt[player] = now

    -- 클라이언트가 보낸 이름을 그대로 복제하지 않고 서버 폴더에서 다시 검증합니다.
    local template = busFolder:FindFirstChild(requestedName)
    if not template or not template:IsA("Model") then
        warn("[버스 소환] 허용되지 않은 모델:", requestedName, "요청자:", player.Name)
        return
    end

    local newBus = template:Clone()
    if not hasBasePart(newBus) then
        warn("[버스 소환] BasePart가 없는 모델은 소환할 수 없습니다:", template:GetFullName())
        newBus:Destroy()
        return
    end

    newBus:SetAttribute("SpawnedByUserId", player.UserId)
    newBus:SetAttribute("SpawnedByUserName", player.Name)
    newBus:SetAttribute("SpawnedBus", true)

    -- 기존 레이더/탑승/하차벨 시스템이 새 차량으로 인식하도록 BUS 태그를 보장합니다.
    if not CollectionService:HasTag(newBus, "BUS") then
        CollectionService:AddTag(newBus, "BUS")
    end

    local placementCFrame = requestedCFrame
    if not isNearbyPlacement(player, placementCFrame) then
        placementCFrame = getFallbackCFrame(player)
    end

    newBus.Parent = workspace
    newBus:PivotTo(placementCFrame)

    destroyActiveBus(player)
    activeBuses[player] = newBus

    print(string.format("[버스 소환] %s -> %s", player.Name, newBus.Name))
end)

Players.PlayerRemoving:Connect(function(player)
    destroyActiveBus(player)
    lastRequestAt[player] = nil
end)
