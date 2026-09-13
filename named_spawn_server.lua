--[[
    플레이어 이름별 지정 스폰 위치

    설치 위치: ServerScriptService

    Workspace 안에 지정한 이름의 Anchored Part를 만들면,
    해당 플레이어가 입장하거나 리스폰할 때 그 파트 위로 이동합니다.
--]]

local Players = game:GetService("Players")

-- Player.Name 기준입니다. 이름은 대소문자를 자동으로 무시합니다.
local PLAYER_SPAWN_PARTS = {
    ["laz3411"] = "Spawn_A",
    -- ["다른플레이어이름"] = "Spawn_B",
}

local function getSpawnPartForPlayer(player)
    local partName = PLAYER_SPAWN_PARTS[player.Name:lower()]
    if not partName then
        for configuredName, configuredPart in pairs(PLAYER_SPAWN_PARTS) do
            if tostring(configuredName):lower() == player.Name:lower() then
                partName = configuredPart
                break
            end
        end
    end
    if not partName then
        return nil
    end

    local spawnPart = workspace:FindFirstChild(partName, true)
    if not spawnPart or not spawnPart:IsA("BasePart") then
        warn("[지정 스폰] 파트를 찾지 못했습니다:", partName, "플레이어:", player.Name)
        return nil
    end

    return spawnPart
end

local function moveToNamedSpawn(player, character)
    local spawnPart = getSpawnPartForPlayer(player)
    if not spawnPart or not character or not character.Parent then
        return
    end

    local root = character:WaitForChild("HumanoidRootPart", 10)
    if not root or not character.Parent then
        return
    end

    -- 파트 윗면에서 약간 띄워 바닥에 끼지 않게 합니다.
    local heightOffset = spawnPart.Size.Y / 2 + 3
    character:PivotTo(spawnPart.CFrame * CFrame.new(0, heightOffset, 0))
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function setupPlayer(player)
    player.CharacterAdded:Connect(function(character)
        task.defer(function()
            moveToNamedSpawn(player, character)
        end)
    end)

    -- 스크립트가 플레이어 입장 이후 추가된 경우에도 현재 캐릭터를 처리합니다.
    if player.Character then
        task.defer(function()
            moveToNamedSpawn(player, player.Character)
        end)
    end
end

Players.PlayerAdded:Connect(setupPlayer)

for _, player in ipairs(Players:GetPlayers()) do
    setupPlayer(player)
end
