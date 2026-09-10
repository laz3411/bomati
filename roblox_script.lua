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
local RESERVATIONS_ENDPOINT = FIREBASE_DATABASE_URL .. "/radar/reservations.json"

-- 지도에 표시할 실제 Roblox 사용자명(Player.Name)입니다. 표시명(DisplayName)이 아닙니다.
local TARGET_ROBLOX_USER_NAME = "laz3411"

-- 전송 주기 (초당 약 3회)
local SEND_INTERVAL = 0.35

-- 하차 예약 정류장 도착 시 하차벨 자동 울림 거리 (studs)
local ARRIVAL_TRIGGER_DISTANCE = 65

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

-- =========================================================================
-- [1. 하차벨 시스템 통합 관리 (모든 Point ProximityPrompt, Main.Bell, Light 일원화)]
-- =========================================================================
local busBellSystems = {} -- [busModel] = { prompts = {}, bellSound = sound, lights = {}, isRinging = false }

local triggerBusBell
local resetBusBell

local function getOrCreateBusBellSystem(busModel)
    if busBellSystems[busModel] then
        return busBellSystems[busModel]
    end

    local system = {
        busModel = busModel,
        prompts = {},
        bellSound = nil,
        lights = {},
        isRinging = false,
        lastTriggeredTime = 0,
        connectedPrompts = {}
    }

    local function hookPrompt(prompt)
        if not prompt:IsA("ProximityPrompt") or system.connectedPrompts[prompt] then
            return
        end
        system.connectedPrompts[prompt] = true
        table.insert(system.prompts, prompt)

        prompt.Triggered:Connect(function(player)
            local partName = prompt.Parent and prompt.Parent.Name or "Button"
            triggerBusBell(busModel, player, "PROXIMITY_PROMPT: " .. partName)
        end)
    end

    -- 1. 버스 모델 내부의 모든 ProximityPrompt, Main.Bell, Light/Light2 자동 수집 및 이벤트 연결
    for _, desc in ipairs(busModel:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            hookPrompt(desc)
        elseif desc:IsA("Sound") and (desc.Name == "Bell" or desc.Name:lower():find("bell")) then
            if not system.bellSound or desc.Name == "Bell" then
                system.bellSound = desc
            end
        elseif desc:IsA("BasePart") or desc:IsA("Light") then
            local lowerName = desc.Name:lower()
            if lowerName == "light" or lowerName == "light2" or lowerName:find("belllight") then
                table.insert(system.lights, desc)
            end
        end
    end

    -- Main 하위 명시적 탐색 (Main.Bell, Main.Light, Main.Light2)
    local mainPart = busModel:FindFirstChild("Main", true)
    if mainPart then
        if not system.bellSound then
            local b = mainPart:FindFirstChild("Bell")
            if b and b:IsA("Sound") then
                system.bellSound = b
            end
        end
        local l1 = mainPart:FindFirstChild("Light")
        if l1 and not table.find(system.lights, l1) then
            table.insert(system.lights, l1)
        end
        local l2 = mainPart:FindFirstChild("Light2")
        if l2 and not table.find(system.lights, l2) then
            table.insert(system.lights, l2)
        end
    end

    -- 실시간으로 생성되거나 로드되는 하차벨 및 프롬프트 동적 감지
    busModel.DescendantAdded:Connect(function(desc)
        if desc:IsA("ProximityPrompt") then
            hookPrompt(desc)
        elseif desc:IsA("Sound") and (desc.Name == "Bell" or desc.Name:lower():find("bell")) then
            if not system.bellSound or desc.Name == "Bell" then
                system.bellSound = desc
            end
        elseif desc:IsA("BasePart") or desc:IsA("Light") then
            local lowerName = desc.Name:lower()
            if lowerName == "light" or lowerName == "light2" or lowerName:find("belllight") then
                if not table.find(system.lights, desc) then
                    table.insert(system.lights, desc)
                end
            end
        end
    end)

    busBellSystems[busModel] = system
    return system
end

-- suppressFirebase=true인 경우, 물리 벨에서 이미 Firebase에 기록한 이벤트를
-- Roblox에서 재생만 하고 다시 Firebase로 되쏘지 않아 무한 반복을 막습니다.
triggerBusBell = function(busModel, player, triggerReason, suppressFirebase)
    local system = getOrCreateBusBellSystem(busModel)
    if system.isRinging then
        return
    end
    system.isRinging = true
    system.lastTriggeredTime = os.clock()

    print(string.format("[하차벨 작동] 버스: %s, 사유: %s, 트리거: %s", busModel.Name, tostring(triggerReason), player and player.Name or "자동예약"))

    -- 1. 모든 ProximityPrompt 일괄 비활성화
    for _, prompt in ipairs(system.prompts) do
        if prompt.Parent then
            prompt.Enabled = false
        end
    end

    -- 2. 하차벨 소리 재생
    if system.bellSound and system.bellSound.Parent then
        system.bellSound:Play()
    end

    -- 3. 하차벨 라이트 점등 (Transparency = 0 또는 Light.Enabled = true)
    for _, light in ipairs(system.lights) do
        if light.Parent then
            if light:IsA("BasePart") then
                light.Transparency = 0
            elseif light:IsA("Light") then
                light.Enabled = true
            end
        end
    end

    if not suppressFirebase then
        -- 4. 피지컬 하차벨 브리지 및 Firebase로 이벤트 전송
        task.spawn(function()
            pcall(function()
                local position = busModel.PrimaryPart and busModel.PrimaryPart.Position or busModel:GetPivot().Position
                local timestamp = DateTime.now().UnixTimestampMillis
                local isHighFloor = busModel:GetAttribute("isHighFloor") == true
                local payload = {
                    type = "bell_press",
                    source = player and "roblox" or "roblox_auto",
                    eventId = string.format("roblox-%d-%d", timestamp, math.floor(os.clock() * 1000)),
                    button = player and "A" or "AUTO",
                    mode = isHighFloor and "high" or "low",
                    triggerReason = triggerReason or "MANUAL",
                    playerName = player and player.Name or "AUTO",
                    deviceTimestampMs = timestamp,
                    receivedAtMs = timestamp,
                    bus = {
                        id = busModel:GetFullName(),
                        name = busModel.Name,
                        route = tostring(getFirstAttribute(busModel, { "route", "Route", "ROUTE" }, "")),
                        isHighFloor = isHighFloor,
                    },
                    bellPosition = {
                        x = round1(position.X),
                        y = round1(position.Y),
                        z = round1(position.Z),
                    }
                }
                HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/bell/latest.json",
                    Method = "PUT",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
                HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/bell/events.json",
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
            end)
        end)
    end
end

resetBusBell = function(busModel)
    local system = busBellSystems[busModel]
    if not system or not system.isRinging then
        return
    end

    system.isRinging = false

    -- 1. 모든 ProximityPrompt 활성화
    for _, prompt in ipairs(system.prompts) do
        if prompt.Parent then
            prompt.Enabled = true
        end
    end

    -- 2. 하차벨 라이트 소등 (Transparency = 1 또는 Light.Enabled = false)
    for _, light in ipairs(system.lights) do
        if light.Parent then
            if light:IsA("BasePart") then
                light.Transparency = 1
            elseif light:IsA("Light") then
                light.Enabled = false
            end
        end
    end
end

-- =========================================================================
-- [2. 노선 정류장 폴더 자동 로드 및 자연수 순서 정렬]
-- =========================================================================
local routeStopsCache = {}
local lastCacheCheckTime = 0

local function loadRouteStops(routeName)
    if not routeName or routeName == "" then
        return {}
    end

    local now = os.clock()
    if routeStopsCache[routeName] and (now - lastCacheCheckTime < 2.0) then
        return routeStopsCache[routeName]
    end

    local folder = workspace:FindFirstChild(routeName)
    if not folder then
        for _, child in ipairs(workspace:GetChildren()) do
            if (child:IsA("Folder") or child:IsA("Model")) and child.Name:lower() == routeName:lower() then
                folder = child
                break
            end
        end
    end

    if not folder then
        return {}
    end

    local stops = {}
    for _, child in ipairs(folder:GetChildren()) do
        local num = tonumber(child.Name:match("%d+"))
        if num then
            local pos = nil
            if child:IsA("BasePart") then
                pos = child.Position
            elseif child:IsA("Model") then
                pos = child:GetPivot().Position
            end

            if pos then
                local stopName = getFirstAttribute(child, { "StopName", "stopName", "Name", "정류장명" }, child.Name)
                table.insert(stops, {
                    index = num,
                    name = tostring(stopName),
                    instance = child,
                    position = pos,
                    x = round1(pos.X),
                    y = round1(pos.Y),
                    z = round1(pos.Z)
                })
            end
        end
    end

    table.sort(stops, function(a, b)
        return a.index < b.index
    end)

    routeStopsCache[routeName] = stops
    lastCacheCheckTime = now
    return stops
end

-- =========================================================================
-- [3. 버스 앞/뒤 인식 파트를 통한 지나간 정류장 제외 & 다음 남은 정류장 산출]
-- =========================================================================
local busRouteProgress = {} -- [busId] = lastPassedIndex

local function calculateStopProgress(model, routeStops, frontPart, backPart, busPos)
    local busId = model:GetFullName()
    if #routeStops == 0 then
        return nil, {}, {}
    end

    local forwardVector = Vector3.new(0, 0, 1)
    if frontPart and backPart then
        local delta = frontPart.Position - backPart.Position
        if delta.Magnitude > 0.05 then
            forwardVector = delta.Unit
        end
    else
        forwardVector = (model.PrimaryPart and model.PrimaryPart.CFrame or model:GetPivot()).LookVector
    end

    local referencePos = frontPart and frontPart.Position or busPos

    local closestStop = nil
    local closestDist = math.huge

    for _, stop in ipairs(routeStops) do
        local dist = (referencePos - stop.position).Magnitude
        if dist < closestDist then
            closestDist = dist
            closestStop = stop
        end
    end

    -- 버스가 특정 정류장 반경 45 studs 이내에 진입하면 "현재 있는 정류장"으로 판정
    local currentStop = nil
    if closestDist <= 45 then
        currentStop = closestStop
        busRouteProgress[busId] = math.max(busRouteProgress[busId] or 0, closestStop.index)
    end

    local passedThresholdIndex = busRouteProgress[busId] or 0
    if closestStop and not currentStop then
        local toStop = (closestStop.position - referencePos)
        local dot = forwardVector:Dot(toStop)
        -- 가장 가까운 정류장이 버스 진행방향 뒤쪽(-5 이하)에 있고 20 studs 이상 떨어져 있다면 통과한 것으로 처리
        if dot < -5 and closestDist > 20 then
            passedThresholdIndex = math.max(passedThresholdIndex, closestStop.index)
            busRouteProgress[busId] = passedThresholdIndex
        else
            passedThresholdIndex = math.max(passedThresholdIndex, closestStop.index - 1)
        end
    end

    local upcomingStops = {}
    local allStopsData = {}

    for _, stop in ipairs(routeStops) do
        local dist = (referencePos - stop.position).Magnitude
        table.insert(allStopsData, {
            index = stop.index,
            name = stop.name,
            x = stop.x,
            y = stop.y,
            z = stop.z,
            distance = round1(dist)
        })

        -- 지나간 정류장 제외, 현재 있는 정류장 제외 -> 다음 정류장들부터만 하차 예약 대상에 포함
        local isPassed = stop.index <= passedThresholdIndex
        local isCurrent = currentStop and (stop.index == currentStop.index)
        if not isPassed and not isCurrent then
            table.insert(upcomingStops, {
                index = stop.index,
                name = stop.name,
                x = stop.x,
                y = stop.y,
                z = stop.z,
                distance = round1(dist)
            })
        end
    end

    local currentStopData = currentStop and {
        index = currentStop.index,
        name = currentStop.name,
        distance = round1(closestDist)
    } or nil

    return currentStopData, upcomingStops, allStopsData
end

-- =========================================================================
-- [4. Firebase 하차 예약 폴링 및 목표 정류장 접근 시 자동 하차벨 트리거]
-- =========================================================================
local activeReservations = {}
local lastReservationPollTime = 0

local function pollReservationsAsync()
    local now = os.clock()
    if now - lastReservationPollTime < 0.8 then
        return
    end
    lastReservationPollTime = now

    task.spawn(function()
        local success, response = pcall(function()
            return HttpService:RequestAsync({
                Url = RESERVATIONS_ENDPOINT,
                Method = "GET"
            })
        end)

        if success and response.Success and response.Body and response.Body ~= "null" then
            local data = HttpService:JSONDecode(response.Body)
            if typeof(data) == "table" then
                activeReservations = data
            end
        end
    end)
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

local lastLogTime = 0

local function collectPlayersData()
    local playersData = {}
    local allPlayers = Players:GetPlayers()
    if #allPlayers == 0 then
        return playersData
    end

    local now = os.clock()
    local shouldLog = (now - lastLogTime >= 3.0)

    for _, player in ipairs(allPlayers) do
        -- laz3411 계정 우선 매칭 (플레이어가 1명이면 무조건 매칭)
        local isTarget = (#allPlayers == 1)
        if not isTarget and TARGET_ROBLOX_USER_NAME and TARGET_ROBLOX_USER_NAME ~= "" then
            local t = TARGET_ROBLOX_USER_NAME:lower()
            if player.Name:lower() == t or player.DisplayName:lower() == t then
                isTarget = true
            end
        elseif not TARGET_ROBLOX_USER_NAME or TARGET_ROBLOX_USER_NAME == "" then
            isTarget = true
        end

        -- 테스트 서버에 다른 플레이어가 먼저 들어와도 전송이 멈추지 않도록
        -- 설정한 이름을 찾지 못하면 첫 번째 플레이어를 예비 대상으로 사용합니다.
        if not isTarget and #allPlayers > 1 then
            local hasExactTarget = false
            if TARGET_ROBLOX_USER_NAME and TARGET_ROBLOX_USER_NAME ~= "" then
                local targetName = TARGET_ROBLOX_USER_NAME:lower()
                for _, candidate in ipairs(allPlayers) do
                    if candidate.Name:lower() == targetName then
                        hasExactTarget = true
                        break
                    end
                end
            end
            if not hasExactTarget and player == allPlayers[1] then
                isTarget = true
            end
        end

        if isTarget then
            local char = player.Character or workspace:FindFirstChild(player.Name)
            if char then
                local rootPart = char:FindFirstChild("HumanoidRootPart")
                    or char:FindFirstChild("Torso")
                    or char:FindFirstChild("UpperTorso")
                    or char.PrimaryPart

                local pos = nil
                local lookVector = nil

                if rootPart and rootPart:IsA("BasePart") then
                    pos = rootPart.Position
                    lookVector = rootPart.CFrame.LookVector
                elseif char:IsA("Model") then
                    local pivot = char:GetPivot()
                    pos = pivot.Position
                    lookVector = pivot.LookVector
                end

                if pos and lookVector then
                    local angle = math.atan2(lookVector.X, lookVector.Z)
                    local humanoid = char:FindFirstChildOfClass("Humanoid")
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

                    if shouldLog then
                        print(string.format("[레이더 GPS 전송중] 플레이어: %s (%s) -> X: %.1f, Z: %.1f", player.Name, player.DisplayName, pos.X, pos.Z))
                    end
                end
            end
        end
    end

    if shouldLog then
        if #playersData == 0 then
            warn(string.format(
                "[로블록스 레이더] 플레이어 %d명은 감지했지만 캐릭터 좌표를 얻지 못했습니다. Character/HumanoidRootPart 로딩을 확인하세요.",
                #allPlayers
            ))
        end
        lastLogTime = now
    end

    return playersData
end

local function determineIsHighFloor(model, taggedPart, boardingPart)
    local candidates = { boardingPart, taggedPart, model }

    -- 1. 고상(High floor) 속성 확인
    for _, inst in ipairs(candidates) do
        if inst then
            local val = getFirstAttribute(inst, { "isHighFloor", "IsHighFloor", "highFloor", "HighFloor", "High", "고상" }, nil)
            if val ~= nil then
                return val == true
            end
        end
    end

    -- 2. 저상(Low floor) 속성 확인 (저상이 true면 고상은 false)
    for _, inst in ipairs(candidates) do
        if inst then
            local val = getFirstAttribute(inst, { "isLowFloor", "IsLowFloor", "lowFloor", "LowFloor", "Low", "저상" }, nil)
            if val ~= nil then
                return val ~= true
            end
        end
    end

    return false -- 기본값: 저상 (false)
end

local function collectBusData()
    pollReservationsAsync()

    local busesData = {}
    local seenModels = {}

    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getVehicleModel(tagged)
        if model and not seenModels[model] then
            seenModels[model] = true

            local frontPart, backPart = getBusParts(model)
            local pos, angle, frontPartName, backPartName, positionPartName = getBusPose(model, tagged)
            local isHighFloor = determineIsHighFloor(model, tagged, nil)
            local routeName = tostring(getFirstAttribute(model, { "route", "Route", "ROUTE" }, ""))

            -- 하차벨 시스템 초기화 (ProximityPrompt 등 연결)
            local bellSystem = getOrCreateBusBellSystem(model)

            -- 노선 정류장 및 다음 남은 정류장 계산
            local routeStops = loadRouteStops(routeName)
            local currentStop, upcomingStops, allStops = calculateStopProgress(model, routeStops, frontPart, backPart, pos)

            -- 하차 예약 감지 및 자동 트리거 검사
            local busKey = model:GetFullName():gsub("[%.%#%$/%[%]]", "_")
            local reservation = activeReservations[busKey] or activeReservations[model.Name]
            if reservation and (reservation.status == "pending" or reservation.status == nil) then
                local targetIndex = tonumber(reservation.targetStopIndex)
                for _, stop in ipairs(routeStops) do
                    if stop.index == targetIndex then
                        local referencePos = frontPart and frontPart.Position or pos
                        local distToTarget = (referencePos - stop.position).Magnitude
                        if distToTarget <= ARRIVAL_TRIGGER_DISTANCE then
                            triggerBusBell(model, nil, "AUTO_RESERVATION: " .. stop.name)
                            reservation.status = "triggered"
                            task.spawn(function()
                                pcall(function()
                                    HttpService:RequestAsync({
                                        Url = FIREBASE_DATABASE_URL .. "/radar/reservations/" .. busKey .. "/status.json",
                                        Method = "PUT",
                                        Headers = { ["Content-Type"] = "application/json" },
                                        Body = HttpService:JSONEncode("triggered")
                                    })
                                end)
                            end)
                        end
                        break
                    end
                end
            end

            -- 하차벨이 울린 후 30초 경과 시 자동 리셋
            if bellSystem.isRinging and (os.clock() - bellSystem.lastTriggeredTime > 30) then
                resetBusBell(model)
            end

            table.insert(busesData, {
                id = model:GetFullName(),
                name = model.Name,
                route = routeName,
                x = round1(pos.X),
                y = round1(pos.Y),
                z = round1(pos.Z),
                angle = angle,
                isHighFloor = isHighFloor == true,
                floorType = isHighFloor == true and "high" or "low",
                frontPart = frontPartName,
                backPart = backPartName,
                positionPart = positionPartName,
                currentStop = currentStop,
                upcomingStops = upcomingStops,
                allStops = allStops,
                isBellRinging = bellSystem.isRinging == true,
                timestamp = DateTime.now().UnixTimestampMillis
            })
        end
    end

    return busesData
end

local function findTargetPlayer()
    local allPlayers = Players:GetPlayers()
    if #allPlayers == 0 then
        return nil
    end

    if TARGET_ROBLOX_USER_NAME and TARGET_ROBLOX_USER_NAME ~= "" then
        for _, player in ipairs(allPlayers) do
            if player.Name:lower() == TARGET_ROBLOX_USER_NAME:lower() then
                return player
            end
        end
    end

    return allPlayers[1]
end

-- 플레이어가 특정 파트(캔콜/캔쿼리 OFF 파트 포함)에 닿아 있거나 내부 영역에 있는지 판정
local function isCharacterTouchingPart(character, part)
    if not character or not part or not part:IsA("BasePart") then
        return false
    end

    local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso") or character.PrimaryPart
    if not hrp then
        return false
    end

    -- 1. 공간 쿼리 (CanQuery=false인 파트여도 대상 캐릭터 파트들은 CanQuery=true이므로 감지 가능)
    local overlapParams = OverlapParams.new()
    -- Roblox enum은 전역 RaycastFilterType이 아니라 Enum 아래에 있습니다.
    -- 잘못된 이름이면 BUS 탑승 감지 순간 메인 Firebase 전송 루프가 죽습니다.
    overlapParams.FilterType = Enum.RaycastFilterType.Include
    overlapParams.FilterDescendantsInstances = { character }
    local querySize = part.Size + Vector3.new(1.0, 2.0, 1.0)
    local foundParts = workspace:GetPartBoundsInBox(part.CFrame, querySize, overlapParams)
    if #foundParts > 0 then
        return true
    end

    -- 2. 수학적 회전 바운딩 박스(OBB) 영역 판정 (물리 지연 보완)
    local halfSize = part.Size * 0.5
    local marginX = halfSize.X + 1.2
    local marginY = halfSize.Y + 2.5
    local marginZ = halfSize.Z + 1.2

    local testPoints = {
        hrp.Position,
        hrp.Position - Vector3.new(0, 2.5, 0), -- 발 부근
        hrp.Position + Vector3.new(0, 1.5, 0)  -- 머리 부근
    }

    for _, pt in ipairs(testPoints) do
        local lp = part.CFrame:PointToObjectSpace(pt)
        if math.abs(lp.X) <= marginX and math.abs(lp.Y) <= marginY and math.abs(lp.Z) <= marginZ then
            return true
        end
    end

    return false
end

-- 버스에 속한 탑승 판정 대상 파트들(BUS 태그 파트, 캔콜/캔쿼리 OFF 파트) 추출
local function getBoardingPartsForBus(model, tagged)
    local parts = {}
    local seen = {}

    local function addPart(p)
        if p and p:IsA("BasePart") and not seen[p] then
            seen[p] = true
            table.insert(parts, p)
        end
    end

    -- 지도 표시용으로 직접 태그된 파트
    if tagged and tagged:IsA("BasePart") then
        addPart(tagged)
    end

    -- 버스 모델 내부의 캔콜끄고 캔쿼리 끈 파트 및 BUS 태그 파트
    if model then
        for _, desc in ipairs(model:GetDescendants()) do
            if desc:IsA("BasePart") then
                if not desc.CanCollide and not desc.CanQuery then
                    addPart(desc)
                elseif CollectionService:HasTag(desc, "BUS") then
                    addPart(desc)
                end
            end
        end
    end

    return parts
end

-- 플레이어가 해당 버스에 탑승(닿아있음 또는 착석)했는지 탐색
local function findBusForPlayer(player)
    local character = player and player.Character
    if not character then
        return nil, nil, nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local seatPart = humanoid and humanoid.SeatPart

    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getVehicleModel(tagged)
        if model then
            -- A. 좌석에 착석한 경우
            if seatPart and seatPart:IsDescendantOf(model) then
                return model, tagged, seatPart
            end

            -- B. 캔콜/캔쿼리 OFF 파트 또는 BUS 파트에 닿아있는 경우
            local boardingParts = getBoardingPartsForBus(model, tagged)
            for _, bPart in ipairs(boardingParts) do
                if isCharacterTouchingPart(character, bPart) then
                    return model, tagged, bPart
                end
            end
        end
    end

    return nil, nil, nil
end

local lastBoardedBus = nil
local BOARDING_GRACE_PERIOD_SEC = 1.0 -- 버스에서 내리면 정확히 1초 뒤에 연동 해제

-- 선택한 플레이어가 탄 BUS의 상태(접촉 탑승 및 고상/저상 여부)를 하차벨 브리지에 전달
local function collectBellContext()
    local player = findTargetPlayer()
    if not player then
        lastBoardedBus = nil
        return { active = false, timestamp = DateTime.now().UnixTimestampMillis }
    end

    local model, tagged, detectedPart = findBusForPlayer(player)
    local now = os.clock()

    if model then
        lastBoardedBus = {
            model = model,
            tagged = tagged,
            part = detectedPart,
            time = now
        }
    elseif lastBoardedBus then
        -- 이탈 직후 버퍼 시간 동안은 탑승 상태 유지
        if (now - lastBoardedBus.time) <= BOARDING_GRACE_PERIOD_SEC and lastBoardedBus.model.Parent then
            model = lastBoardedBus.model
            tagged = lastBoardedBus.tagged
            detectedPart = lastBoardedBus.part
        else
            lastBoardedBus = nil
        end
    end

    if not model then
        return { active = false, timestamp = DateTime.now().UnixTimestampMillis }
    end

    local position = getBusPosition(model, tagged)
    local isHighFloor = determineIsHighFloor(model, tagged, detectedPart)

    return {
        active = true,
        mode = isHighFloor and "high" or "low",
        busId = model:GetFullName(),
        busName = model.Name,
        route = tostring(getFirstAttribute(model, { "route", "Route", "ROUTE" }, "")),
        isHighFloor = isHighFloor,
        x = round1(position.X),
        y = round1(position.Y),
        z = round1(position.Z),
        timestamp = DateTime.now().UnixTimestampMillis
    }
end

-- 실제 벨에서 Firebase로 올라온 이벤트를 Roblox 버스에서도 재생합니다.
-- 최신 이벤트만 읽고 eventId를 기억해 중복 재생을 방지합니다.
local lastPhysicalBellEventId = nil
local isPollingPhysicalBell = false
local PHYSICAL_BELL_MAX_AGE_MS = 5_000

local function pollPhysicalBell()
    if isPollingPhysicalBell then
        return
    end
    isPollingPhysicalBell = true

    task.spawn(function()
        local success, err = pcall(function()
            local response = HttpService:RequestAsync({
                Url = FIREBASE_DATABASE_URL .. "/bell/latest.json",
                Method = "GET"
            })

            if not response.Success or not response.Body or response.Body == "null" then
                return
            end

            local event = HttpService:JSONDecode(response.Body)
            if typeof(event) ~= "table" or event.source ~= "physical" then
                return
            end

            local receivedAt = tonumber(event.receivedAtMs)
            if not receivedAt or DateTime.now().UnixTimestampMillis - receivedAt > PHYSICAL_BELL_MAX_AGE_MS then
                return
            end

            local eventId = tostring(event.eventId or (tostring(receivedAt) .. ":" .. tostring(event.button)))
            if eventId == lastPhysicalBellEventId then
                return
            end
            lastPhysicalBellEventId = eventId

            local player = findTargetPlayer()
            local model = player and select(1, findBusForPlayer(player)) or nil
            if not model and lastBoardedBus and lastBoardedBus.model and lastBoardedBus.model.Parent then
                model = lastBoardedBus.model
            end

            if model then
                triggerBusBell(model, nil, "PHYSICAL: " .. tostring(event.button or "A"), true)
            else
                warn("[로블록스 레이더] 실제 벨 이벤트를 받았지만 탑승 중인 BUS를 찾지 못했습니다.")
            end
        end)

        isPollingPhysicalBell = false
        if not success then
            warn("[로블록스 레이더] 실제 벨 이벤트 수신 실패:", err)
        end
    end)
end

task.spawn(function()
    while RunService:IsRunning() do
        if not isSending then
            -- 좌표/탑승 정보 수집 오류가 나도 전체 루프가 죽지 않도록 보호합니다.
            local collectSuccess, playersData, busesData, bellData = pcall(function()
                return collectPlayersData(), collectBusData(), collectBellContext()
            end)

            if not collectSuccess then
                warn("[로블록스 레이더] 데이터 수집 실패:", playersData)
            else
                local radarData = {
                    players = playersData,
                    buses = busesData,
                    bell = bellData,
                    timestamp = DateTime.now().UnixTimestampMillis
                }

                pollPhysicalBell()

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
        end

        task.wait(SEND_INTERVAL)
    end
end)
