--[[
    [로블록스 스튜디오 -> Firebase Realtime Database 연동 스크립트]
    위치: ServerScriptService 아래에 "Script"를 생성하고 본 코드를 붙여넣으세요.
    
    [사전 설정]
    로블록스 스튜디오 상단 [Home] -> [Game Settings] -> [Security] -> "Allow HTTP Requests" ON
--]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

-- 사용자 지정 Firebase Realtime Database URL
local FIREBASE_DATABASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"
local RADAR_ENDPOINT = FIREBASE_DATABASE_URL .. "/radar.json"

-- 지도에 표시할 실제 Roblox 사용자명(Player.Name)입니다. 표시명(DisplayName)이 아닙니다.
local TARGET_ROBLOX_USER_NAME = "laz3411"

-- 전송 주기 (초당 약 3회)
local SEND_INTERVAL = 0.35

local isSending = false

print("[로블록스 레이더] Firebase 연동 활성화됨. 대상:", RADAR_ENDPOINT)

local FRONT_TAGS = { "BUS_FRONT", "BusFront", "FRONT", "Front" }
local BACK_TAGS = { "BUS_BACK", "BusBack", "BACK", "Back" }

local function getFirstAttribute(instance, names, fallback)
    for _, name in ipairs(names) do
        local value = instance:GetAttribute(name)
        if value ~= nil then
            return value
        end
    end
    return fallback
end

local function round1(value)
    return math.round(value * 10) / 10
end

local function findTaggedDescendant(root, tagNames)
    for _, tagName in ipairs(tagNames) do
        for _, tagged in ipairs(CollectionService:GetTagged(tagName)) do
            if tagged:IsDescendantOf(root) and tagged:IsA("BasePart") then
                return tagged
            end
        end
    end
    return nil
end

local function getVehicleModel(instance)
    if instance:IsA("Model") then
        return instance
    end

    return instance:FindFirstAncestorOfClass("Model")
end

local function getVehicleCFrame(model)
    if model.PrimaryPart then
        return model.PrimaryPart.CFrame
    end

    return model:GetPivot()
end

local function findFirstMovingPart(model)
    if model.PrimaryPart then
        return model.PrimaryPart
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
            return descendant
        end
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") and not descendant.Anchored then
            return descendant.AssemblyRootPart or descendant
        end
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            return descendant
        end
    end

    return nil
end

local function getBusParts(model)
    local frontPart = findTaggedDescendant(model, FRONT_TAGS)
    local backPart = findTaggedDescendant(model, BACK_TAGS)

    return frontPart, backPart
end

local function getBusPosition(model, taggedInstance)
    if taggedInstance:IsA("BasePart") then
        local rootPart = taggedInstance.AssemblyRootPart
        if rootPart then
            return rootPart.Position, rootPart.Name, rootPart.CFrame
        end

        return taggedInstance.Position, taggedInstance.Name, taggedInstance.CFrame
    end

    local movingPart = findFirstMovingPart(model)
    if movingPart then
        local rootPart = movingPart.AssemblyRootPart
        if rootPart then
            return rootPart.Position, rootPart.Name, rootPart.CFrame
        end

        return movingPart.Position, movingPart.Name, movingPart.CFrame
    end

    local boundingCFrame = model:GetBoundingBox()
    return boundingCFrame.Position, "BoundingBox", boundingCFrame
end

local function getBusPose(model, taggedInstance)
    local fallbackCFrame = getVehicleCFrame(model)
    local frontPart, backPart = getBusParts(model)
    local position, positionPartName, positionCFrame = getBusPosition(model, taggedInstance)

    if frontPart and backPart then
        local delta = frontPart.Position - backPart.Position
        if delta.Magnitude > 0.05 then
            return position, math.atan2(delta.X, delta.Z), frontPart.Name, backPart.Name, positionPartName
        end
    end

    local lookVector = (positionCFrame or fallbackCFrame).LookVector
    return position, math.atan2(lookVector.X, lookVector.Z), frontPart and frontPart.Name or nil, backPart and backPart.Name or nil, positionPartName
end

local function collectPlayersData()
    local playersData = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player.Name:lower() == TARGET_ROBLOX_USER_NAME:lower() then
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then
                continue
            end

            local humanoid = char:FindFirstChild("Humanoid")
            local pos = hrp.Position
            local lookVector = hrp.CFrame.LookVector
            local angle = math.atan2(lookVector.X, lookVector.Z)

            local health = humanoid and humanoid.Health or 100
            local maxHealth = humanoid and humanoid.MaxHealth or 100

            table.insert(playersData, {
                id = player.UserId,
                name = player.Name,
                displayName = player.DisplayName,
                x = round1(pos.X),
                y = round1(pos.Y),
                z = round1(pos.Z),
                angle = angle,
                health = math.round(health),
                maxHealth = math.round(maxHealth),
                timestamp = DateTime.now().UnixTimestampMillis
            })
        end
    end

    return playersData
end

local function collectBusData()
    local busesData = {}
    local seenModels = {}

    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getVehicleModel(tagged)
        if model and not seenModels[model] then
            seenModels[model] = true

            local pos, angle, frontPartName, backPartName, positionPartName = getBusPose(model, tagged)
            local isHighFloor = getFirstAttribute(model, { "isHighFloor", "IsHighFloor", "highFloor", "HighFloor", "High", "고상" }, false)

            table.insert(busesData, {
                id = model:GetFullName(),
                name = model.Name,
                route = tostring(getFirstAttribute(model, { "route", "Route", "ROUTE" }, "")),
                x = round1(pos.X),
                y = round1(pos.Y),
                z = round1(pos.Z),
                angle = angle,
                isHighFloor = isHighFloor == true,
                floorType = isHighFloor == true and "high" or "low",
                frontPart = frontPartName,
                backPart = backPartName,
                positionPart = positionPartName,
                timestamp = DateTime.now().UnixTimestampMillis
            })
        end
    end

    return busesData
end

task.spawn(function()
    while RunService:IsRunning() do
        if not isSending then
            local playersData = collectPlayersData()
            local busesData = collectBusData()
            local radarData = {
                players = playersData,
                buses = busesData,
                timestamp = DateTime.now().UnixTimestampMillis
            }

            isSending = true
            task.spawn(function()
                local success, err = pcall(function()
                    local radarResponse = HttpService:RequestAsync({
                        Url = RADAR_ENDPOINT,
                        Method = "PUT",
                        Headers = { ["Content-Type"] = "application/json" },
                        Body = HttpService:JSONEncode(radarData)
                    })

                    if not radarResponse.Success then
                        error(string.format("Firebase HTTP %s: %s", radarResponse.StatusCode, radarResponse.StatusMessage))
                    end
                end)

                isSending = false

                if not success then
                    warn("[로블록스 레이더] Firebase 전송 실패:", err)
                    -- 실패 시 3초 대기 (로블록스 렉 방지)
                    task.wait(3.0)
                end
            end)
        end

        task.wait(SEND_INTERVAL)
    end
end)
