--[[
    버스 소환 서버 스크립트

    설치 위치: ServerScriptService

    ReplicatedStorage 안의 BusModels 폴더에 넣어 둔 Model만 소환합니다.
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

local function findSpawnPart()
    -- 전용 파트를 우선 사용합니다.
    for _, name in ipairs({ "BusSpawn", "BusSpawnLocation" }) do
        local part = workspace:FindFirstChild(name, true)
        if part and part:IsA("BasePart") then
            return part
        end
    end

    -- BUS_SPAWN 태그가 붙은 파트도 지원합니다.
    for _, tagged in ipairs(CollectionService:GetTagged("BUS_SPAWN")) do
        if tagged:IsA("BasePart") and tagged:IsDescendantOf(workspace) then
            return tagged
        end
    end

    -- 기존 맵의 SpawnLocation을 마지막 대체 위치로 사용합니다.
    local fallback = workspace:FindFirstChild("SpawnLocation", true)
    if fallback and fallback:IsA("BasePart") then
        return fallback
    end

    return nil
end

local function getSpawnCFrame(player)
    local spawnPart = findSpawnPart()
    if spawnPart then
        -- 파트의 앞 방향과 회전값을 그대로 사용합니다.
        return spawnPart.CFrame * CFrame.new(0, 3, 0)
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root then
        return root.CFrame * CFrame.new(0, 2, -28)
    end

    return CFrame.new(0, 5, 0)
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

spawnRemote.OnServerEvent:Connect(function(player, requestedName)
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

    newBus.Parent = workspace
    newBus:PivotTo(getSpawnCFrame(player))

    destroyActiveBus(player)
    activeBuses[player] = newBus

    print(string.format("[버스 소환] %s -> %s", player.Name, newBus.Name))
end)

Players.PlayerRemoving:Connect(function(player)
    destroyActiveBus(player)
    lastRequestAt[player] = nil
end)
