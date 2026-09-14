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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- 사용자 지정 Firebase Realtime Database URL
local FIREBASE_DATABASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"
local RADAR_ENDPOINT = FIREBASE_DATABASE_URL .. "/radar.json"
local RESERVATIONS_ENDPOINT = FIREBASE_DATABASE_URL .. "/radar/reservations.json"
local ROUTE_DIRECTION_REMOTE_NAME = "BusRouteDirectionRequest"

local routeDirectionRemote = ReplicatedStorage:FindFirstChild(ROUTE_DIRECTION_REMOTE_NAME)
if not routeDirectionRemote then
    routeDirectionRemote = Instance.new("RemoteEvent")
    routeDirectionRemote.Name = ROUTE_DIRECTION_REMOTE_NAME
    routeDirectionRemote.Parent = ReplicatedStorage
end

-- 지도에 표시할 Roblox 계정입니다. UserId를 우선 사용하고 이름은 구버전 호환에 사용합니다.
local TARGET_ROBLOX_USER_NAME = "beargobearman"
local TARGET_ROBLOX_USER_ID = 1463187453
-- Roblox Studio에 현재 파일이 실제로 반영됐는지 Output/Firebase에서 확인하는 버전입니다.
local RADAR_SCRIPT_VERSION = "beargobearman-userid-20260914-1"

-- 지도 전송은 초당 2회면 위치 보간에 충분합니다. 물리 벨/예약 조회와 합쳐도
-- Roblox HttpService 요청 한도를 넘지 않도록 여유를 둡니다.
local SEND_INTERVAL = 0.50

-- 하차 예약 정류장에 도착하기 전 하차벨을 울릴 거리 (studs)
-- 버스가 감속·정차하기 전에 충분히 안내되도록 기존 65에서 늘렸습니다.
local ARRIVAL_TRIGGER_DISTANCE = 170

local isSending = false
local radarClearedForAbsentTarget = false
-- Firebase /radar는 전역 단일 경로입니다. 대상 사용자가 실제로 접속한 서버만
-- 이 스트림을 쓰거나 삭제할 수 있게 소유권을 기록합니다.
local targetStreamOwnedByThisServer = false
local SERVER_SESSION_ID = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(game.PlaceId))
-- collectBusData와 collectBellContext가 같은 탑승 상태를 공유해야 합니다.
-- Lua의 local 범위는 선언 이후부터이므로 파일 아래쪽에서 선언하면 collectBusData는
-- 다른 전역 변수를 보게 됩니다.
local lastBoardedBus = nil

local function isConfiguredTargetPlayer(player)
    if not player then return false end
    if tonumber(TARGET_ROBLOX_USER_ID) and TARGET_ROBLOX_USER_ID > 0
        and player.UserId == TARGET_ROBLOX_USER_ID then
        return true
    end
    return TARGET_ROBLOX_USER_NAME ~= ""
        and player.Name:lower() == TARGET_ROBLOX_USER_NAME:lower()
end

local function isTargetPlayerConnected()
    -- 대상 사용자를 지정하지 않은 개발 환경에서는 기존 전체 전송 동작을 유지합니다.
    if (not TARGET_ROBLOX_USER_NAME or TARGET_ROBLOX_USER_NAME == "")
        and (not TARGET_ROBLOX_USER_ID or TARGET_ROBLOX_USER_ID <= 0) then
        return true
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if isConfiguredTargetPlayer(player) then
            return true
        end
    end
    return false
end

-- 대상 플레이어가 퇴장하면 지도/예약용 실시간 데이터만 제거합니다.
-- /bell/events는 디버그 이력으로 남기고, 현재 상태(/bell/latest)는 함께 초기화합니다.
local function clearLiveRadarData(reason)
    -- 대상 사용자가 없는 다른 서버가 현재 시연 서버의 지도 데이터를 지우지 않게 합니다.
    if not targetStreamOwnedByThisServer then return end
    if radarClearedForAbsentTarget then return end
    radarClearedForAbsentTarget = true
    task.spawn(function()
        local success, err = pcall(function()
            local radarResponse = HttpService:RequestAsync({
                Url = RADAR_ENDPOINT,
                Method = "DELETE"
            })
            if not radarResponse.Success then
                error("radar delete failed: " .. tostring(radarResponse.StatusMessage))
            end
            HttpService:RequestAsync({
                Url = FIREBASE_DATABASE_URL .. "/bell/latest.json",
                Method = "DELETE"
            })
        end)
        if success then
            print("[로블록스 레이더] 대상 플레이어 퇴장 -> 라이브 데이터/예약 삭제:", reason)
        else
            warn("[로블록스 레이더] 퇴장 데이터 삭제 실패:", err)
            radarClearedForAbsentTarget = false
        end
    end)
end

print(string.format(
    "[로블록스 레이더] 버전=%s / 지정 사용자=%s(%s) / Firebase=%s",
    RADAR_SCRIPT_VERSION,
    TARGET_ROBLOX_USER_NAME,
    tostring(TARGET_ROBLOX_USER_ID),
    RADAR_ENDPOINT
))

local FRONT_TAGS = { "BUS_FRONT", "BusFront", "FRONT", "Front" }
local BACK_TAGS = { "BUS_BACK", "BusBack", "BACK", "Back" }
local BUSIN_TAGS = { "BUSin", "BusIn", "busin", "BUSIN", "Busin", "BUS_IN" }

local function isTruthy(val)
    if val == true or val == 1 then
        return true
    end
    if type(val) == "string" then
        local s = val:lower():gsub("%s+", "")
        return s == "true" or s == "high" or s == "고상" or s == "1" or s == "yes" or s == "y"
    end
    return false
end

local function isFalsy(val)
    if val == false or val == 0 then
        return true
    end
    if type(val) == "string" then
        local s = val:lower():gsub("%s+", "")
        return s == "false" or s == "low" or s == "저상" or s == "0" or s == "no" or s == "n"
    end
    return false
end

local function getFirstAttribute(instance, names, fallback)
    if not instance then return fallback end
    for _, name in ipairs(names) do
        local value = instance:GetAttribute(name)
        if value ~= nil then
            return value
        end
    end
    return fallback
end

local function getValueFromInstance(inst, names, fallback)
    if not inst then return fallback end
    for _, name in ipairs(names) do
        local val = inst:GetAttribute(name)
        if val ~= nil then
            return val
        end
        local child = inst:FindFirstChild(name)
        if child and child:IsA("ValueBase") then
            return child.Value
        end
    end
    return fallback
end

local function normalizeRouteDirection(value)
    local text = tostring(value or ""):lower():gsub("%s+", "")
    if text == "up" or text == "upbound" or text == "상행" or text == "상행선" or text == "상" or text == "1" then
        return "up"
    end
    if text == "down" or text == "downbound" or text == "하행" or text == "하행선" or text == "하" or text == "2" then
        return "down"
    end
    if text == "both" or text == "all" or text == "공통" or text == "양방향" then
        return "both"
    end
    return nil
end

local function getBusRouteDirection(model)
    return normalizeRouteDirection(getValueFromInstance(model, {
        "RouteDirection", "routeDirection", "Direction", "direction", "운행방향"
    }, nil))
end

local function getBusLicense(model)
    local value = getValueFromInstance(model, {
        "BusLicense", "busLicense", "VehicleNumber", "vehicleNumber", "BusNumber", "busNumber", "차량번호"
    }, nil)
    if value == nil then return nil end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

local function getStopRouteDirection(instance)
    local foundUp = false
    local foundDown = false
    local current = instance
    while current and current ~= workspace do
        if CollectionService:HasTag(current, "BUS_STOP_UP")
            or CollectionService:HasTag(current, "BusStopUp")
            or CollectionService:HasTag(current, "UPBOUND")
            or CollectionService:HasTag(current, "상행정류장") then
            foundUp = true
        end
        if CollectionService:HasTag(current, "BUS_STOP_DOWN")
            or CollectionService:HasTag(current, "BusStopDown")
            or CollectionService:HasTag(current, "DOWNBOUND")
            or CollectionService:HasTag(current, "하행정류장") then
            foundDown = true
        end
        local attributeDirection = normalizeRouteDirection(getFirstAttribute(current, {
            "RouteDirection", "routeDirection", "Direction", "direction",
            "DirectionTag", "directionTag", "Tag", "tag", "운행방향", "방향태그", "상하행"
        }, nil))
        if attributeDirection == "both" then return "both" end
        if attributeDirection == "up" then foundUp = true end
        if attributeDirection == "down" then foundDown = true end
        current = current.Parent
    end
    if foundUp and foundDown then return "both" end
    if foundUp then return "up" end
    if foundDown then return "down" end
    return nil
end

local function stopSupportsRouteDirection(stopDirection, routeDirection)
    local requested = normalizeRouteDirection(routeDirection)
    local available = normalizeRouteDirection(stopDirection)
    if not requested or requested == "both" or not available or available == "both" then
        return true
    end
    return requested == available
end

local function round1(value)
    return math.round(value * 10) / 10
end

-- 지도 정류장 Part는 표시를 위해 도로보다 크게 아래/위에 배치될 수 있으므로
-- 차량 접근, 통과, 예약 도착 판정에는 높이(Y)를 제외한 X/Z 거리만 사용합니다.
local function horizontalDistance(firstPosition, secondPosition)
    local dx = firstPosition.X - secondPosition.X
    local dz = firstPosition.Z - secondPosition.Z
    return math.sqrt(dx * dx + dz * dz)
end


-- =========================================================================
-- [1. 하차벨 시스템 통합 관리 (모든 Point ProximityPrompt, Main.Bell, Light 일원화)]
-- =========================================================================
local busBellSystems = {} -- [busModel] = { prompts = {}, bellSound = sound, lights = {}, isRinging = false }

local triggerBusBell
local resetBusBell
local determineIsHighFloor
local isGameBellTurnedOff

-- 기존 차량마다 제각각인 일반 벨 구조는 그대로 지원하면서, 첨부된
-- sxnhe_0 구성(Point/SPoint, Light/SLight, Bell/SBell, StopBell/StopBell1)도 구분합니다.
local function isSpecialBellInstance(instance)
    local current = instance
    while current do
        local name = current.Name:lower()
        if name == "spoint" or name == "slight" or name:find("special") or name:find("disabled") or name:find("wheelchair") then
            return true
        end
        current = current.Parent
    end
    return false
end

-- sxnhe_0 원본 스크립트의 BellModel을 찾습니다. B벨은 반드시 이 모델의
-- Speaker.StopBell1을 사용해야 하므로 버스 전체 검색 결과와 섞지 않습니다.
local function findSxnheBellRoot(instance, busModel)
    local current = instance
    while current and current ~= busModel do
        local speaker = current:FindFirstChild("Speaker")
        if speaker
            and current:FindFirstChild("Bell")
            and current:FindFirstChild("SBell")
            and speaker:FindFirstChild("StopBell")
            and speaker:FindFirstChild("StopBell1") then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function addUnique(list, value)
    if value and not table.find(list, value) then
        table.insert(list, value)
    end
end

local function getOrCreateBusBellSystem(busModel)
    if busBellSystems[busModel] then
        return busBellSystems[busModel]
    end

    local system = {
        busModel = busModel,
        prompts = {},
        normalPrompts = {},
        specialPrompts = {},
        bellSound = nil,
        specialBellSound = nil,
        lights = {},
        specialLights = {},
        driverLights = {},
        normalBellValue = nil,
        specialBellValue = nil,
        doorOpenValue = nil,
        -- sxnhe_0은 일반/장애인 벨을 서로 전환할 수 있는 원본 구조입니다.
        hasSxnheBell = false,
        -- 차량별 조명 원래 상태를 보존해, 켠 뒤에도 올바른 방식으로 복구합니다.
        lightStates = {},
        isRinging = false,
        isSpecialRinging = false,
        -- sxnhe_0에서는 한 정차 주기 동안 일반/장애인 벨을 각각 한 번만 허용합니다.
        normalBellUsed = false,
        specialBellUsed = false,
        lastTriggeredTime = 0,
        lastTriggeredAtMs = nil,
        lastTriggerReason = nil,
        lastTriggeredPlayerName = nil,
        lastBellType = nil,
        connectedPrompts = {},
        connectedClicks = {},
        promptSxnheRoots = {},
        clickSxnheRoots = {},
        sxnheBellRoots = {}
    }

    local function hookPrompt(prompt, isSpecial, sxnheRoot)
        if not prompt:IsA("ProximityPrompt") or system.connectedPrompts[prompt] then
            return
        end
        system.connectedPrompts[prompt] = true
        table.insert(system.prompts, prompt)
        addUnique(isSpecial and system.specialPrompts or system.normalPrompts, prompt)
        if sxnheRoot then
            system.promptSxnheRoots[prompt] = sxnheRoot
            addUnique(system.sxnheBellRoots, sxnheRoot)
        end

        prompt.Triggered:Connect(function(player)
            local partName = prompt.Parent and prompt.Parent.Name or "Button"
            triggerBusBell(busModel, player, "PROXIMITY_PROMPT: " .. partName, false, isSpecial, system.promptSxnheRoots[prompt])
        end)
    end

    local function hookClick(click, isSpecial, sxnheRoot)
        if not click:IsA("ClickDetector") or system.connectedClicks[click] then return end
        system.connectedClicks[click] = true
        if sxnheRoot then
            system.clickSxnheRoots[click] = sxnheRoot
            addUnique(system.sxnheBellRoots, sxnheRoot)
        end
        click.MouseClick:Connect(function(player)
            local partName = click.Parent and click.Parent.Name or "Button"
            triggerBusBell(busModel, player, "CLICK_DETECTOR: " .. partName, false, isSpecial, system.clickSxnheRoots[click])
        end)
    end

    local function registerLight(list, desc, role, usesMaterialSignal)
        addUnique(list, desc)
        if not system.lightStates[desc] then
            local state = { role = role, usesMaterialSignal = usesMaterialSignal == true }
            if desc:IsA("BasePart") then
                state.transparency = desc.Transparency
                state.material = desc.Material
                state.color = desc.Color
            elseif desc:IsA("Light") then
                state.enabled = desc.Enabled
            end
            system.lightStates[desc] = state
        end
    end

    -- sxnhe_0 원본 벨 스크립트는 BellModel 안에 Speaker/StopBell/StopBell1,
    -- Bell, SBell을 두고 Light/SLight/Driver의 Material을 Neon으로 바꿉니다.
    -- 이름만 Light인 다른 차량은 기존처럼 Transparency 방식이므로, 이름만으로
    -- Neon 방식을 판단하면 두 벨 시스템의 동작이 서로 깨집니다.
    local function isSxnheBellVisual(desc)
        return findSxnheBellRoot(desc, busModel) ~= nil
    end

    local function registerVisual(desc)
        local lowerName = desc.Name:lower()
        if desc:IsA("Sound") then
            -- sxnhe_0의 장애인 벨은 Speaker.StopBell1입니다. 다른 이름에
            -- special이 들어간 효과음이 이를 덮어쓰지 않게 정확한 이름을 우선합니다.
            if lowerName == "stopbell1" then
                system.specialBellSound = desc
            elseif lowerName:find("special") and not system.specialBellSound then
                system.specialBellSound = desc
            elseif (lowerName == "bell" or lowerName:find("bell")) and (not system.bellSound or desc.Name == "Bell" or lowerName == "stopbell") then
                system.bellSound = desc
            end
        elseif desc:IsA("BoolValue") then
            if lowerName == "sbell" or lowerName:find("specialbell") then
                system.specialBellValue = desc
            elseif lowerName == "bell" then
                system.normalBellValue = desc
            elseif lowerName == "dooropen" then
                system.doorOpenValue = desc
            end
        elseif desc:IsA("BasePart") or desc:IsA("Light") then
            local sxnheMaterialLight = isSxnheBellVisual(desc)
            if sxnheMaterialLight then
                system.hasSxnheBell = true
            end
            if lowerName == "slight" or lowerName:find("speciallight") then
                registerLight(system.specialLights, desc, "special", sxnheMaterialLight)
            elseif lowerName == "driver" or lowerName:find("driverlight") then
                registerLight(system.driverLights, desc, "driver", sxnheMaterialLight)
            elseif lowerName == "light" or lowerName == "light2" or lowerName:find("belllight") then
                -- Point1~Point19의 기존 벨 로직은 Light/Light2.Transparency = 0
                -- 으로 점등합니다. 이름이 Light라는 이유만으로 Neon으로 바꾸면
                -- 실제 파트가 투명한 상태로 남아 소리만 들리는 문제가 생깁니다.
                -- 단, sxnhe_0 원본 BellModel 안의 Light는 Neon 방식입니다.
                registerLight(system.lights, desc, "normal", sxnheMaterialLight)
            end
        end
    end

    -- Point1~Point19 안의 Prompt가 속한 벨 묶음에서 Light/Light2를 직접 찾습니다.
    -- 개별 버튼 스크립트의 `script.Parent.Parent.Parent.Light` 구조도 여기서 지원됩니다.
    local function registerPromptAssemblyVisuals(prompt)
        local current = prompt and prompt.Parent
        for _ = 1, 3 do
            if not current or current == busModel then break end
            for _, name in ipairs({ "Light", "Light2", "SLight", "Driver" }) do
                local visual = current:FindFirstChild(name)
                if visual then registerVisual(visual) end
            end
            current = current.Parent
        end
    end

    -- 1. 버스 모델 내부의 모든 ProximityPrompt, Main.Bell, Light/Light2 자동 수집 및 이벤트 연결
    for _, desc in ipairs(busModel:GetDescendants()) do
        if desc:IsA("ProximityPrompt") then
            hookPrompt(desc, isSpecialBellInstance(desc.Parent), findSxnheBellRoot(desc, busModel))
            registerPromptAssemblyVisuals(desc)
        elseif desc:IsA("ClickDetector") then
            hookClick(desc, isSpecialBellInstance(desc.Parent), findSxnheBellRoot(desc, busModel))
        end
        registerVisual(desc)
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
            registerLight(system.lights, l1, "normal", false)
        end
        local l2 = mainPart:FindFirstChild("Light2")
        if l2 and not table.find(system.lights, l2) then
            registerLight(system.lights, l2, "normal", false)
        end
    end

    -- 실시간으로 생성되거나 로드되는 하차벨 및 프롬프트 동적 감지
    busModel.DescendantAdded:Connect(function(desc)
        if desc:IsA("ProximityPrompt") then
            hookPrompt(desc, isSpecialBellInstance(desc.Parent), findSxnheBellRoot(desc, busModel))
            registerPromptAssemblyVisuals(desc)
        elseif desc:IsA("ClickDetector") then
            hookClick(desc, isSpecialBellInstance(desc.Parent), findSxnheBellRoot(desc, busModel))
        end
        registerVisual(desc)
    end)

    -- RearDoor.DoorOpen 등 차량별 문 열림 BoolValue를 찾아 열리는 순간 벨을 초기화합니다.
    if system.doorOpenValue then
        system.doorOpenValue:GetPropertyChangedSignal("Value"):Connect(function()
            if system.doorOpenValue.Value == true then
                resetBusBell(busModel, true)
            end
        end)
    end

    busBellSystems[busModel] = system
    return system
end

-- 기본 Point 벨은 Light/Light2의 Transparency를 직접 바꿉니다. 별도로
-- usesMaterialSignal=true로 등록한 특수 차량만 Material/Color 방식을 씁니다.
local function setBellLightState(system, light, isOn)
    if not light or not light.Parent then return end
    local saved = system.lightStates[light]

    if light:IsA("BasePart") then
        if isOn then
            if saved and saved.usesMaterialSignal then
                light.Material = Enum.Material.Neon
                light.Color = saved.role == "normal"
                    and Color3.fromRGB(196, 40, 28)
                    or Color3.fromRGB(255, 0, 0)
            else
                light.Transparency = 0
            end
        elseif saved then
            light.Transparency = saved.transparency
            light.Material = saved.material
            light.Color = saved.color
        else
            light.Transparency = 1
        end
    elseif light:IsA("Light") then
        light.Enabled = isOn and true or (saved and saved.enabled or false)
    end
end

local function isBellLightOn(system, light)
    if not light or not light.Parent then return false end
    local saved = system.lightStates[light]
    if light:IsA("BasePart") then
        if saved and saved.usesMaterialSignal then
            return light.Material == Enum.Material.Neon
        end
        return light.Transparency < 0.5
    elseif light:IsA("Light") then
        return light.Enabled
    end
    return false
end

local function isTargetPlayersCurrentBus(busModel)
    local state = lastBoardedBus
    if not state or state.model ~= busModel or not busModel or not busModel.Parent then
        return false
    end
    local evidence = state.boardingEvidence
    local confirmed = evidence == "seat"
        or evidence == "floor"
        or evidence == "busin"
        or evidence == "boarding_part"
    if not confirmed then
        return false
    end
    -- 탑승 판정 루프가 중단되거나 대상 사용자가 나간 뒤 남은 상태는 사용하지 않습니다.
    return isTargetPlayerConnected() and (os.clock() - tonumber(state.time or 0)) <= (SEND_INTERVAL * 4)
end

-- suppressFirebase=true인 경우, 물리 벨에서 이미 Firebase에 기록한 이벤트를
-- Roblox에서 재생만 하고 다시 Firebase로 되쏘지 않아 무한 반복을 막습니다.
triggerBusBell = function(busModel, player, triggerReason, suppressFirebase, isSpecial, sourceSxnheRoot)
    local system = getOrCreateBusBellSystem(busModel)
    isSpecial = isSpecial == true
    -- 같은 벨은 한 정차 주기 동안 한 번만, sxnhe_0의 반대 종류 벨도 아직
    -- 누르지 않은 경우에만 한 번 전환할 수 있습니다.
    if (isSpecial and system.specialBellUsed) or ((not isSpecial) and system.normalBellUsed) then
        return
    end
    if isSpecial then
        system.specialBellUsed = true
    else
        system.normalBellUsed = true
    end
    system.isRinging = true
    system.isSpecialRinging = isSpecial
    system.lastTriggeredTime = os.clock()
    system.lastTriggeredAtMs = DateTime.now().UnixTimestampMillis
    system.lastTriggerReason = tostring(triggerReason or "MANUAL")
    system.lastTriggeredPlayerName = player and player.Name or "AUTO"
    system.lastBellType = isSpecial and "special" or "normal"

    print(string.format("[하차벨 작동] 버스: %s, 사유: %s, 트리거: %s", busModel.Name, tostring(triggerReason), player and player.Name or "자동예약"))

    -- 1. 같은 종류를 여러 번 누르는 것은 막습니다. 단 sxnhe_0은 원본 설계대로
    --    일반(A) 후 장애인(B), 또는 B 후 A로 한 번 전환할 수 있어야 합니다.
    local function applyPromptLock()
        for _, prompt in ipairs(system.prompts) do
            if prompt.Parent then
                prompt.Enabled = false
            end
        end

        if system.hasSxnheBell then
            local switchTargets = nil
            if isSpecial and not system.normalBellUsed then
                switchTargets = system.normalPrompts
            elseif (not isSpecial) and not system.specialBellUsed then
                switchTargets = system.specialPrompts
            end
            if not switchTargets then return end
            for _, prompt in ipairs(switchTargets) do
                if prompt.Parent then
                    prompt.Enabled = true
                end
            end
        end
    end
    applyPromptLock()

    -- 같은 Triggered 이벤트에서 원본 스크립트가 Prompt를 다시 켠 경우에도
    -- 현재 벨과 반대 종류만 남긴 상태로 다시 적용합니다.
    task.defer(function()
        if system.isRinging then
            applyPromptLock()
        end
    end)

    -- 2. 일반/장애인 하차벨 상태 및 소리. 일반 벨만 있는 기존 차량은 기존 Sound를 그대로 사용합니다.
    if isSpecial and system.specialBellValue then
        system.specialBellValue.Value = true
    elseif system.normalBellValue then
        system.normalBellValue.Value = true
    end
    local sound = system.bellSound
    if isSpecial then
        -- 자동 수집 결과와 무관하게, 방금 누른 sxnhe_0 BellModel의
        -- Speaker.StopBell1만 B벨 소리로 사용합니다.
        local sxnheRoot = sourceSxnheRoot or system.sxnheBellRoots[1]
        local speaker = sxnheRoot and sxnheRoot:FindFirstChild("Speaker")
        local sxnheSpecialSound = speaker and speaker:FindFirstChild("StopBell1")
        if sxnheSpecialSound and sxnheSpecialSound:IsA("Sound") then
            sound = sxnheSpecialSound
        else
            sound = system.specialBellSound or system.bellSound
        end
    end
    if sound and sound.Parent then
        sound:Stop()
        sound.TimePosition = 0
        sound:Play()
    end

    -- 3. 하차벨 라이트 점등 (차량별 Transparency 또는 Material/Color 방식 지원)
    local lightsToEnable = isSpecial and system.specialLights or system.lights
    for _, light in ipairs(lightsToEnable) do
        setBellLightState(system, light, true)
    end
    for _, light in ipairs(system.driverLights) do
        setBellLightState(system, light, true)
    end

    local shouldSyncTargetBell = not suppressFirebase and isTargetPlayersCurrentBus(busModel)
    if shouldSyncTargetBell then
        system.syncedToTargetBridge = true
        -- 4. 피지컬 하차벨 브리지 및 Firebase로 이벤트 전송
        task.spawn(function()
            local success, err = pcall(function()
                local position = busModel.PrimaryPart and busModel.PrimaryPart.Position or busModel:GetPivot().Position
                local timestamp = DateTime.now().UnixTimestampMillis
                local isHighFloor = determineIsHighFloor(busModel, nil, nil)
                local payload = {
                    type = "bell_press",
                    source = player and "roblox" or "roblox_auto",
                    eventId = string.format("roblox-%d-%d", timestamp, math.floor(os.clock() * 1000)),
                    -- 자동 예약의 장애인 벨도 Firebase 브리지가 B 신호로 보드에 전달할 수 있게 명시합니다.
                    button = isSpecial and "B" or (player and "A" or "AUTO"),
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
                local latestResponse = HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/bell/latest.json",
                    Method = "PUT",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
                if not latestResponse.Success then
                    error(string.format("Firebase bell/latest HTTP %s: %s", latestResponse.StatusCode, latestResponse.StatusMessage))
                end

                local eventsResponse = HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/bell/events.json",
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
                if not eventsResponse.Success then
                    error(string.format("Firebase bell/events HTTP %s: %s", eventsResponse.StatusCode, eventsResponse.StatusMessage))
                end
            end)
            if not success then
                warn("[로블록스 하차벨] Firebase 이벤트 전송 실패:", err)
            end
        end)
    elseif not suppressFirebase then
        print(string.format("[하차벨 연동 제외] 지정 사용자 탑승 차량이 아님: %s", busModel.Name))
    end
end

-- 게임 내 하차벨 신호(라이트 소등, 프롬프트 재활성화 등)에 의해 꺼졌는지 검사
isGameBellTurnedOff = function(system)
    if not system or not system.isRinging then
        return false
    end
    -- 하차벨이 울린 직후 1초 동안은 자체 점등 처리 시간이므로 검사 유예
    if (os.clock() - system.lastTriggeredTime) < 1.0 then
        return false
    end

    -- 1. 라이트 소등 상태 검사
    local hasTrackedLight = false
    local anyLightOn = false

    local trackedLights = {}
    for _, list in ipairs({ system.lights, system.specialLights, system.driverLights }) do
        for _, light in ipairs(list) do addUnique(trackedLights, light) end
    end
    for _, light in ipairs(trackedLights) do
        if light.Parent then
            hasTrackedLight = true
            if isBellLightOn(system, light) then
                anyLightOn = true
                break
            end
        end
    end

    -- 라이트가 등록되어 있고, 켜져있는 라이트가 하나도 없다면 게임 스크립트에 의해 꺼진 것!
    if hasTrackedLight and not anyLightOn then
        return true
    end

    -- 2. sxnhe_0은 반대편 Prompt 하나만 켜진 상태가 정상입니다. 그 외 차량은
    --    Prompt가 다시 켜져도 중복 입력이 되지 않게 즉시 잠급니다.
    for _, prompt in ipairs(system.prompts) do
        if prompt.Parent and prompt.Enabled then
            local isSxnheSwitch = system.hasSxnheBell and (
                (system.isSpecialRinging and not system.normalBellUsed and table.find(system.normalPrompts, prompt))
                or ((not system.isSpecialRinging) and not system.specialBellUsed and table.find(system.specialPrompts, prompt))
            )
            if not isSxnheSwitch then
                prompt.Enabled = false
            end
        end
    end

    -- 3. 버스 모델의 명시적 속성 검사
    local attrBell = system.busModel:GetAttribute("isBellRinging")
    if attrBell == false then
        return true
    end

    return false
end

resetBusBell = function(busModel, notifyFirebase)
    local system = busBellSystems[busModel]
    if not system or not system.isRinging then
        return
    end

    system.isRinging = false
    system.isSpecialRinging = false
    system.normalBellUsed = false
    system.specialBellUsed = false
    system.lastResetTime = os.clock()

    -- 1. 모든 ProximityPrompt 활성화
    for _, prompt in ipairs(system.prompts) do
        if prompt.Parent then
            prompt.Enabled = true
        end
    end

    -- 2. 하차벨 라이트 소등 (점등 전 차량 고유 상태로 복원)
    local allLights = {}
    for _, list in ipairs({ system.lights, system.specialLights, system.driverLights }) do
        for _, light in ipairs(list) do addUnique(allLights, light) end
    end
    for _, light in ipairs(allLights) do
        setBellLightState(system, light, false)
    end
    if system.normalBellValue then system.normalBellValue.Value = false end
    if system.specialBellValue then system.specialBellValue.Value = false end

    print(string.format("[하차벨 소등 완료] 버스: %s", busModel.Name))

    local shouldNotifyFirebase = notifyFirebase and system.syncedToTargetBridge == true
    system.syncedToTargetBridge = false
    if shouldNotifyFirebase then
        task.spawn(function()
            local success, err = pcall(function()
                local timestamp = DateTime.now().UnixTimestampMillis
                local isHighFloor = determineIsHighFloor(busModel, nil, nil)
                local payload = {
                    type = "bell_reset",
                    source = "roblox",
                    eventId = string.format("roblox-reset-%d-%d", timestamp, math.floor(os.clock() * 1000)),
                    button = "RESET",
                    mode = isHighFloor and "high" or "low",
                    deviceTimestampMs = timestamp,
                    receivedAtMs = timestamp,
                    bus = {
                        id = busModel:GetFullName(),
                        name = busModel.Name,
                        route = tostring(getFirstAttribute(busModel, { "route", "Route", "ROUTE" }, "")),
                        isHighFloor = isHighFloor,
                    }
                }
                HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/bell/latest.json",
                    Method = "PUT",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
            end)
            if not success then
                warn("[로블록스 하차벨] Firebase 소등 이벤트 전송 실패:", err)
            end
        end)
    end
end


-- =========================================================================
-- [2. 노선 정류장 폴더 자동 로드 및 자연수 순서 정렬]
-- =========================================================================
local routeStopsCache = {}
local routeStopsCacheCheckedAt = {}

-- 같은 노선에 상행/하행 폴더가 각각 존재할 수 있으므로 일치하는 루트 폴더를 모두 찾습니다.
-- 각 폴더에는 String 속성 RouteDirection = "상행" 또는 "하행"을 지정할 수 있습니다.
local function findRouteFolders(routeName)
    if not routeName or routeName == "" then
        return {}
    end

    local routeNameLower = routeName:lower()
    local routeNumber = routeName:match("%d+")
    local function getRouteFolderMatchScore(instance)
        if not (instance:IsA("Folder") or instance:IsA("Model")) then return 0 end
        -- 실제 운행 차량 모델명이 노선번호를 포함해도 정류장 폴더로 수집하지 않습니다.
        if instance:IsA("Model") and (
            CollectionService:HasTag(instance, "BUS")
            or instance:GetAttribute("SpawnedBus") == true
            or instance:FindFirstChildWhichIsA("VehicleSeat", true) ~= nil
        ) then
            return 0
        end
        local nameLower = instance.Name:lower()
        -- 이전 정상 버전과 동일하게 노선명과 정확히 같은 폴더를 최우선으로 사용합니다.
        if nameLower == routeNameLower then return 10 end

        local declaredRoute = getValueFromInstance(instance, {
            "Route", "route", "ROUTE", "Line", "line", "노선", "노선번호"
        }, nil)
        if declaredRoute ~= nil then
            local declaredText = tostring(declaredRoute)
            if declaredText:lower() == routeNameLower then return 5 end
            local declaredNumber = declaredText:match("%d+")
            if routeNumber and declaredNumber == routeNumber then return 3 end
        end
        -- "Route 115", "115번 정류장"처럼 노선번호를 포함한 폴더명도 지원합니다.
        if routeNumber then
            local nameNumber = instance.Name:match("%d+")
            if nameNumber == routeNumber then return 1 end
        end
        return 0
    end

    local candidates = {}
    local candidateSet = {}
    local bestMatchScore = 0
    local function addCandidate(instance)
        local score = getRouteFolderMatchScore(instance)
        if score <= 0 or score < bestMatchScore then return end
        if score > bestMatchScore then
            candidates = {}
            candidateSet = {}
            bestMatchScore = score
        end
        if not candidateSet[instance] then
            candidateSet[instance] = true
            table.insert(candidates, instance)
        end
    end

    -- 1. workspace 직속 탐색
    for _, child in ipairs(workspace:GetChildren()) do
        addCandidate(child)
    end

    -- 2. 흔히 정류장을 묶어두는 상위 폴더 안에서 모든 방향 폴더 탐색
    local commonContainerNames = { "Routes", "Route", "Map", "Stops", "BusStops", "BUS", "노선", "정류장" }
    for _, containerName in ipairs(commonContainerNames) do
        local container = workspace:FindFirstChild(containerName)
        if container then
            for _, descendant in ipairs(container:GetDescendants()) do
                addCandidate(descendant)
            end
        end
    end

    -- 3. 이전 정상 버전처럼 workspace 전체에서 정확한 폴더명도 끝까지 확인합니다.
    -- 앞 단계에서 숫자만 같은 후보를 찾았더라도 뒤쪽의 정확한 노선 폴더가 우선됩니다.
    for _, descendant in ipairs(workspace:GetDescendants()) do
        addCandidate(descendant)
    end

    -- 노선 루트 아래에 "115 상행" 같은 보조 폴더가 중복 검색된 경우에는
    -- 가장 바깥 노선 루트만 남깁니다. 추출기가 내부 방향 폴더까지 재귀 탐색합니다.
    local roots = {}
    for _, candidate in ipairs(candidates) do
        local ancestor = candidate.Parent
        local hasCandidateAncestor = false
        while ancestor and ancestor ~= workspace do
            if candidateSet[ancestor] then
                hasCandidateAncestor = true
                break
            end
            ancestor = ancestor.Parent
        end
        if not hasCandidateAncestor then
            table.insert(roots, candidate)
        end
    end
    return roots
end

local function extractStopsFromFolder(folder, routeDirection)
    if not folder then return {} end
    local folderDirection = normalizeRouteDirection(getFirstAttribute(folder, {
        "RouteDirection", "routeDirection", "Direction", "direction",
        "DirectionTag", "directionTag", "Tag", "tag", "운행방향", "방향태그", "상하행"
    }, nil))
    if not stopSupportsRouteDirection(folderDirection, routeDirection) then
        return {}
    end

    local stops = {}
    local seenInstances = {}
    local autoIndex = 1
    local children = folder:GetChildren()

    table.sort(children, function(a, b)
        local na = tonumber(a.Name:match("%d+"))
        local nb = tonumber(b.Name:match("%d+"))
        if na and nb then return na < nb end
        return a.Name < b.Name
    end)

    local function addStopInstance(instance, allowImplicit)
        if seenInstances[instance] then return end
        if not (instance:IsA("BasePart") or instance:IsA("Model") or instance:IsA("Folder")) then return end
        local hasStopMetadata = instance:GetAttribute("StopId") ~= nil
            or instance:GetAttribute("stopId") ~= nil
            or instance:GetAttribute("StopName") ~= nil
            or instance:GetAttribute("정류장명") ~= nil
        local namedIndex = tonumber(instance.Name:match("%d+"))
        local declaredContainerDirection = normalizeRouteDirection(getFirstAttribute(instance, {
            "RouteDirection", "routeDirection", "Direction", "direction",
            "DirectionTag", "directionTag", "Tag", "tag", "운행방향", "방향태그", "상하행"
        }, nil))
        -- 방향 폴더가 Model로 구성되어 있어도 정류장 자체로 오인하지 않습니다.
        if (instance:IsA("Model") or instance:IsA("Folder")) and declaredContainerDirection and not hasStopMetadata then return end
        if not allowImplicit and not hasStopMetadata and not namedIndex then return end

        local pos = nil
        if instance:IsA("BasePart") then
            pos = instance.Position
        elseif instance:IsA("Model") then
            pos = instance:GetPivot().Position
        elseif instance:IsA("Folder") then
            local positionPart = instance:FindFirstChildWhichIsA("BasePart", true)
            if positionPart then pos = positionPart.Position end
        end

        local stopDirection = getStopRouteDirection(instance) or folderDirection
        if pos and stopSupportsRouteDirection(stopDirection, routeDirection) then
            local num = namedIndex or autoIndex
            local stopName = getFirstAttribute(instance, { "StopName", "stopName", "Name", "정류장명" }, instance.Name)
            -- StopId(정류장 고유 번호)가 있으면 노선별 순번과 분리해 사용합니다.
            -- 같은 실제 정류장을 여러 노선 폴더에 넣어도 지도/예약에서 하나로 매칭됩니다.
            local stopId = getFirstAttribute(instance, {
                "StopId", "stopId", "StopNumber", "stopNumber", "StationId", "stationId",
                "UniqueStopId", "uniqueStopId", "정류장고유번호", "정류장번호"
            }, nil)
            seenInstances[instance] = true
            table.insert(stops, {
                index = num,
                stopId = stopId ~= nil and tostring(stopId) or nil,
                name = tostring(stopName),
                direction = stopDirection,
                instance = instance,
                position = pos,
                x = round1(pos.X),
                y = round1(pos.Y),
                z = round1(pos.Z)
            })
            autoIndex = autoIndex + 1
        end
    end

    for _, child in ipairs(children) do
        addStopInstance(child, true)
    end

    -- 직접 정류장과 방향별 하위 폴더가 함께 있어도 둘 다 읽습니다.
    for _, descendant in ipairs(folder:GetDescendants()) do
        local ancestorAlreadyAdded = false
        local ancestor = descendant.Parent
        while ancestor and ancestor ~= folder do
            if seenInstances[ancestor] then
                ancestorAlreadyAdded = true
                break
            end
            ancestor = ancestor.Parent
        end
        if not ancestorAlreadyAdded then
            addStopInstance(descendant, false)
        end
    end

    table.sort(stops, function(a, b)
        return a.index < b.index
    end)
    return stops
end

-- 폴더 배치 위치나 이름이 기존 탐색 규칙과 달라도 숫자 이름의 정류장 Part에서
-- 조상 노선 폴더를 역추적해 복구합니다. 실제 BUS 내부 숫자 Part는 제외합니다.
local function discoverRouteStopsFromParts(routeName, routeDirection)
    local routeText = tostring(routeName or "")
    local routeLower = routeText:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local routeNumber = routeText:match("%d+")
    local stops = {}
    local seen = {}

    local function ancestorMatchesRoute(instance)
        local declaredRoute = getValueFromInstance(instance, {
            "Route", "route", "ROUTE", "Line", "line", "노선", "노선번호"
        }, nil)
        if declaredRoute ~= nil then
            local declaredText = tostring(declaredRoute)
            local declaredLower = declaredText:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if declaredLower == routeLower then return true end
            if routeNumber and declaredText:match("%d+") == routeNumber then return true end
        end

        local nameLower = instance.Name:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if nameLower == routeLower then return true end
        return routeNumber ~= nil and instance.Name:match("%d+") == routeNumber
    end

    for _, part in ipairs(workspace:GetDescendants()) do
        if part:IsA("BasePart") then
            local index = tonumber(part.Name:match("^%s*(%d+)%s*$"))
            local hasStopMetadata = part:GetAttribute("StopId") ~= nil
                or part:GetAttribute("stopId") ~= nil
                or part:GetAttribute("StopName") ~= nil
                or part:GetAttribute("정류장명") ~= nil
            if index or hasStopMetadata then
                local cursor = part.Parent
                local belongsToBus = false
                local matchesRoute = false
                while cursor and cursor ~= workspace do
                    if cursor:IsA("Model") and (
                        CollectionService:HasTag(cursor, "BUS")
                        or cursor:GetAttribute("SpawnedBus") == true
                        or cursor:FindFirstChildOfClass("VehicleSeat") ~= nil
                    ) then
                        belongsToBus = true
                        break
                    end
                    if (cursor:IsA("Folder") or cursor:IsA("Model")) and ancestorMatchesRoute(cursor) then
                        matchesRoute = true
                    end
                    cursor = cursor.Parent
                end

                local stopDirection = getStopRouteDirection(part)
                if not belongsToBus and matchesRoute and stopSupportsRouteDirection(stopDirection, routeDirection) then
                    local stopId = getFirstAttribute(part, {
                        "StopId", "stopId", "StopNumber", "stopNumber", "StationId", "stationId",
                        "UniqueStopId", "uniqueStopId", "정류장고유번호", "정류장번호"
                    }, nil)
                    local key = stopId ~= nil and ("id:" .. tostring(stopId)) or part
                    if not seen[key] then
                        seen[key] = true
                        local stopName = getFirstAttribute(part, { "StopName", "stopName", "Name", "정류장명" }, part.Name)
                        table.insert(stops, {
                            index = index or (#stops + 1),
                            stopId = stopId ~= nil and tostring(stopId) or nil,
                            name = tostring(stopName),
                            direction = stopDirection,
                            instance = part,
                            position = part.Position,
                            x = round1(part.Position.X),
                            y = round1(part.Position.Y),
                            z = round1(part.Position.Z)
                        })
                    end
                end
            end
        end
    end

    table.sort(stops, function(first, second)
        return first.index < second.index
    end)
    return stops
end

local function loadRouteStops(routeName, routeDirection)
    if not routeName or routeName == "" then
        return {}
    end

    local directionKey = normalizeRouteDirection(routeDirection) or "all"
    local cacheKey = tostring(routeName) .. "|" .. directionKey
    local now = os.clock()
    local checkedAt = routeStopsCacheCheckedAt[cacheKey] or 0
    if routeStopsCache[cacheKey] and (now - checkedAt < 2.0) then
        return routeStopsCache[cacheKey]
    end

    local folders = findRouteFolders(routeName)
    local stops = {}
    local seenStopKeys = {}
    local function appendFolderStops(routeFolders)
        for _, folder in ipairs(routeFolders) do
            for _, stop in ipairs(extractStopsFromFolder(folder, directionKey)) do
                local key = stop.stopId and ("id:" .. tostring(stop.stopId)) or stop.instance
                if not seenStopKeys[key] then
                    seenStopKeys[key] = true
                    table.insert(stops, stop)
                end
            end
        end
    end
    appendFolderStops(folders)

    -- 혹시 노선 번호만 숫자로 추출해서 다시 시도
    if #stops == 0 then
        local numOnly = routeName:match("%d+")
        if numOnly and numOnly ~= routeName then
            appendFolderStops(findRouteFolders(numOnly))
        end
    end

    if #stops == 0 then
        for _, stop in ipairs(discoverRouteStopsFromParts(routeName, directionKey)) do
            local key = stop.stopId and ("id:" .. tostring(stop.stopId)) or stop.instance
            if not seenStopKeys[key] then
                seenStopKeys[key] = true
                table.insert(stops, stop)
            end
        end
    end

    table.sort(stops, function(first, second)
        return first.index < second.index
    end)
    for _, stop in ipairs(stops) do
        stop.route = tostring(routeName)
        stop.direction = normalizeRouteDirection(stop.direction)
    end
    routeStopsCache[cacheKey] = stops
    routeStopsCacheCheckedAt[cacheKey] = now
    return stops
end

-- 맵 전체에 존재하는 모든 정류장(모든 노선 폴더 + BUS_STOP 태그) 수집
local function collectAllMapStops()
    local allStops = {}
    local seenPositions = {}

    local function addStop(stop, routeHint)
        local position = stop.position
        local x = tonumber(stop.x) or (position and position.X)
        local y = tonumber(stop.y) or (position and position.Y) or 0
        local z = tonumber(stop.z) or (position and position.Z)
        if not x or not z then
            return
        end

        -- 고유 번호가 설정된 정류장은 위치가 조금 달라도 같은 하나의 정류장으로 표시합니다.
        local key = stop.stopId and ("id:" .. tostring(stop.stopId))
            or string.format("pos:%.1f,%.1f", x, z)
        if not seenPositions[key] then
            -- Firebase 전송용 정류장에는 Instance/Vector3를 넣지 않습니다. 노선
            -- 계산용 Vector3는 buildFallbackRouteStops에서 다시 생성합니다.
            local resolvedRoute = routeHint and tostring(routeHint) or (stop.route and tostring(stop.route) or nil)
            local row = {
                index = tonumber(stop.index) or (#allStops + 1),
                stopId = stop.stopId ~= nil and tostring(stop.stopId) or nil,
                name = tostring(stop.name or ("정류장 " .. tostring(#allStops + 1))),
                route = resolvedRoute,
                routes = resolvedRoute and { resolvedRoute } or {},
                direction = normalizeRouteDirection(stop.direction),
                x = round1(x),
                y = round1(y),
                z = round1(z)
            }
            seenPositions[key] = row
            table.insert(allStops, row)
        else
            -- 같은 StopId가 양방향 노선에서 공유되면 지도에는 하나만 유지하되
            -- 어느 방향에서도 사용할 수 있도록 방향만 병합합니다.
            local existing = seenPositions[key]
            local incomingRoute = routeHint and tostring(routeHint) or (stop.route and tostring(stop.route) or nil)
            if incomingRoute then
                existing.routes = existing.routes or {}
                local routeExists = false
                for _, existingRoute in ipairs(existing.routes) do
                    if tostring(existingRoute) == incomingRoute then
                        routeExists = true
                        break
                    end
                end
                if not routeExists then table.insert(existing.routes, incomingRoute) end
            end
            local existingDirection = normalizeRouteDirection(existing.direction)
            local incomingDirection = normalizeRouteDirection(stop.direction)
            if existingDirection and incomingDirection and existingDirection ~= incomingDirection then
                existing.direction = "both"
            elseif not existingDirection then
                existing.direction = incomingDirection
            end
        end
    end

    -- 1. 캐시된 노선 정류장들
    for cachedRouteName, stops in pairs(routeStopsCache) do
        local routeHint = tostring(cachedRouteName):match("^(.-)|") or cachedRouteName
        for _, s in ipairs(stops) do
            addStop(s, s.route or routeHint)
        end
    end

    -- 2. 공용/상행/하행 태그가 붙은 정류장들
    for _, tag in ipairs({
        "BUS_STOP", "BusStop", "bus_stop", "BUS_STATION", "BusStation", "정류장",
        "BUS_STOP_UP", "BusStopUp", "UPBOUND", "상행정류장",
        "BUS_STOP_DOWN", "BusStopDown", "DOWNBOUND", "하행정류장"
    }) do
        for _, tagged in ipairs(CollectionService:GetTagged(tag)) do
            local pos = nil
            if tagged:IsA("BasePart") then
                pos = tagged.Position
            elseif tagged:IsA("Model") then
                pos = tagged:GetPivot().Position
            end
            if pos then
                local num = tonumber(tagged.Name:match("%d+")) or (#allStops + 1)
                local explicitStopName = getFirstAttribute(tagged, { "StopName", "stopName", "정류장명" }, nil)
                local stopId = getFirstAttribute(tagged, {
                    "StopId", "stopId", "StopNumber", "stopNumber", "StationId", "stationId",
                    "UniqueStopId", "uniqueStopId", "정류장고유번호", "정류장번호"
                }, nil)
                local stopRoute = getFirstAttribute(tagged, {
                    "Route", "route", "ROUTE", "Line", "line", "노선", "노선번호"
                }, nil)
                local lowerName = tagged.Name:lower()
                -- 단순 ArrivalSensor 같은 감지 파트는 지도 정류장으로 쓰지 않습니다.
                -- 실제 정류장은 이름에 stop/station/정류장이 있거나 StopName/StopId 속성이 있어야 합니다.
                local looksLikeStop = lowerName:find("stop") or lowerName:find("station") or lowerName:find("정류장")
                if explicitStopName or stopId ~= nil or looksLikeStop then
                    addStop({
                        index = num,
                        stopId = stopId ~= nil and tostring(stopId) or nil,
                        name = tostring(explicitStopName or tagged.Name),
                        direction = getStopRouteDirection(tagged),
                        x = round1(pos.X),
                        y = round1(pos.Y),
                        z = round1(pos.Z)
                    }, stopRoute)
                end
            end
        end
    end

    return allStops
end

-- 게임 접속 직후 노선 탐색이 한 프레임 늦어도 이미 확인한 정류장을 빈 배열로 덮어쓰지 않습니다.
local lastKnownMapStops = {}
local function collectStableMapStops()
    local freshStops = collectAllMapStops()
    if #freshStops > 0 then
        lastKnownMapStops = freshStops
    end
    return lastKnownMapStops
end

-- 노선 폴더가 없거나 차량의 Route 값과 폴더명이 맞지 않을 때 BUS_STOP 태그
-- 정류장을 노선 진행 판정용 형태로 변환합니다. Route 속성이 붙은 정류장이 하나라도
-- 있으면 해당 노선만 사용하고, 전부 미지정일 때만 공용 정류장 순서를 사용합니다.
local function buildFallbackRouteStops(routeName, routeDirection)
    local mapStops = collectAllMapStops()
    local routeText = tostring(routeName or "")
    local routeNumber = routeText:match("%d+")
    local hasScopedStops = false
    local matchingStops = {}
    local unscopedStops = {}

    local function routeMatches(stopRoute)
        local stopRouteText = tostring(stopRoute or "")
        if stopRouteText == "" then return false end
        if stopRouteText:lower() == routeText:lower() then return true end
        local stopRouteNumber = stopRouteText:match("%d+")
        return routeNumber ~= nil and stopRouteNumber == routeNumber
    end

    for _, stop in ipairs(mapStops) do
        local target = unscopedStops
        if stop.route and tostring(stop.route) ~= "" then
            hasScopedStops = true
            target = routeMatches(stop.route) and matchingStops or nil
        end

        if target and stopSupportsRouteDirection(stop.direction, routeDirection) then
            local x = tonumber(stop.x)
            local y = tonumber(stop.y) or 0
            local z = tonumber(stop.z)
            if x and z then
                table.insert(target, {
                    index = tonumber(stop.index) or (#target + 1),
                    stopId = stop.stopId ~= nil and tostring(stop.stopId) or nil,
                    name = tostring(stop.name or ("정류장 " .. tostring(#target + 1))),
                    route = routeText,
                    direction = normalizeRouteDirection(stop.direction),
                    position = Vector3.new(x, y, z),
                    x = x,
                    y = y,
                    z = z
                })
            end
        end
    end

    local selectedStops = hasScopedStops and matchingStops or unscopedStops
    table.sort(selectedStops, function(first, second)
        return first.index < second.index
    end)
    return selectedStops
end

local routeFallbackNotices = {}

-- =========================================================================
-- [3. 노선 선분 진행도와 거리 변화로 지나간 정류장 제외 & 다음 남은 정류장 산출]
-- =========================================================================
local busRouteProgress = {} -- [busId] = 진행 상태
local ROUTE_CURRENT_STOP_RADIUS = 45
local ROUTE_PASS_APPROACH_RADIUS = 110
local ROUTE_PASS_MAX_MIN_DISTANCE = 90
local ROUTE_PASS_CONFIRM_DISTANCE = 60
local ROUTE_PASS_DISTANCE_GAIN = 16
local ROUTE_PROGRESS_MAX_VALID_SPEED = 180
local ROUTE_POLYLINE_MAX_DISTANCE = 140

local function getRouteFingerprint(routeStops)
    local first = routeStops[1]
    local last = routeStops[#routeStops]
    return string.format(
        "%d|%s|%.1f|%.1f|%s|%.1f|%.1f",
        #routeStops,
        tostring(first and (first.stopId or first.index) or ""),
        first and first.position.X or 0,
        first and first.position.Z or 0,
        tostring(last and (last.stopId or last.index) or ""),
        last and last.position.X or 0,
        last and last.position.Z or 0
    )
end

-- 버스 회전값 대신 정류장들을 이은 노선 선분에 현재 위치를 투영합니다.
-- 반환값은 정류장 배열 순서를 기준으로 한 연속 진행도(예: 3.4 = 3번과 4번 사이)입니다.
local function estimateRouteSequenceProgress(routeStops, position, passedOrder)
    if #routeStops < 2 then
        return nil, math.huge
    end

    local bestProgress = nil
    local bestDistance = math.huge
    local bestScore = math.huge

    for order = 1, #routeStops - 1 do
        local startPosition = routeStops[order].position
        local endPosition = routeStops[order + 1].position
        local flatStart = Vector3.new(startPosition.X, 0, startPosition.Z)
        local flatEnd = Vector3.new(endPosition.X, 0, endPosition.Z)
        local flatPosition = Vector3.new(position.X, 0, position.Z)
        local segment = flatEnd - flatStart
        local lengthSquared = segment:Dot(segment)
        if lengthSquared > 0.01 then
            local rawT = (flatPosition - flatStart):Dot(segment) / lengthSquared
            local t = math.clamp(rawT, 0, 1)
            local closestPoint = flatStart + segment * t
            local distance = horizontalDistance(flatPosition, closestPoint)
            local progress = order + t
            local score = distance

            -- 교차로나 평행 노선에서 먼 구간으로 순간 이동하지 않도록, 지금까지
            -- 확정한 순서보다 뒤로 가는 후보와 여러 정류장을 건너뛰는 후보에 벌점을 줍니다.
            if passedOrder ~= nil then
                if progress < passedOrder - 0.25 then
                    score = score + 10000
                elseif progress > passedOrder + 3.5 then
                    score = score + (progress - passedOrder - 3.5) * 80
                end
            end

            if score < bestScore then
                bestScore = score
                bestDistance = distance
                bestProgress = progress
            end
        end
    end

    return bestProgress, bestDistance
end

local function calculateStopProgress(model, routeStops, frontPart, backPart, busPos)
    local busId = model:GetFullName()
    if #routeStops == 0 then
        busRouteProgress[busId] = nil
        return nil, {}, {}
    end

    -- FRONT/BACK 태그의 위치·회전 설정이 잘못돼도 진행 판정이 흔들리지 않도록
    -- 레이더가 실제 전송하는 버스 중심 좌표만 사용합니다.
    local referencePos = busPos
    local now = os.clock()
    local routeFingerprint = getRouteFingerprint(routeStops)
    local state = busRouteProgress[busId]

    if not state or state.routeFingerprint ~= routeFingerprint then
        local initialProgress, initialLineDistance = estimateRouteSequenceProgress(routeStops, referencePos, nil)
        local initialPassedOrder = 0
        if initialProgress and initialLineDistance <= ROUTE_POLYLINE_MAX_DISTANCE then
            initialPassedOrder = math.max(0, math.floor(initialProgress - 0.12))
        end
        state = {
            routeFingerprint = routeFingerprint,
            passedOrder = math.min(initialPassedOrder, #routeStops),
            lastPosition = referencePos,
            lastSampleAt = now,
            approach = nil
        }
        busRouteProgress[busId] = state
    end

    local sampleSeconds = math.max(now - state.lastSampleAt, 0)
    local sampleSpeed = 0
    if sampleSeconds > 0.01 then
        sampleSpeed = horizontalDistance(referencePos, state.lastPosition) / sampleSeconds
    end
    local motionIsValid = sampleSeconds <= 0.01 or sampleSpeed <= ROUTE_PROGRESS_MAX_VALID_SPEED
    state.lastPosition = referencePos
    state.lastSampleAt = now
    if not motionIsValid then
        -- 좌표 순간이동 프레임으로 여러 정류장이 한꺼번에 지나간 것으로 처리하지 않습니다.
        state.approach = nil
    end

    local closestStop = nil
    local closestDist = math.huge
    local closestOrder = nil

    for order, stop in ipairs(routeStops) do
        local dist = horizontalDistance(referencePos, stop.position)
        if dist < closestDist then
            closestDist = dist
            closestStop = stop
            closestOrder = order
        end
    end

    -- 가까운 정류장은 방향값과 무관하게 현재 정류장으로 확정합니다.
    local currentStop = nil
    if motionIsValid
        and closestStop
        and closestOrder >= state.passedOrder
        and closestDist <= ROUTE_CURRENT_STOP_RADIUS then
        currentStop = closestStop
        state.passedOrder = math.max(state.passedOrder, closestOrder)
        state.approach = nil
    end

    if motionIsValid and not currentStop then
        -- 1차 판정: 노선 선분 위 진행도가 다음 정류장을 충분히 넘어갔는지 확인합니다.
        local routeProgress, lineDistance = estimateRouteSequenceProgress(routeStops, referencePos, state.passedOrder)
        if routeProgress and lineDistance <= ROUTE_POLYLINE_MAX_DISTANCE then
            local confirmedOrder = math.max(0, math.floor(routeProgress - 0.12))
            if confirmedOrder > state.passedOrder then
                state.passedOrder = math.min(confirmedOrder, #routeStops)
                state.approach = nil
            end
        end

        -- 2차 판정: 도로가 굽어 노선 직선에서 벗어나도 다음 정류장까지 가까워졌다가
        -- 다시 멀어졌다면 통과로 확정합니다. 버스 회전/앞뒤 파트 방향은 사용하지 않습니다.
        local nextOrder = state.passedOrder + 1
        local nextStop = routeStops[nextOrder]
        if nextStop then
            local distance = horizontalDistance(referencePos, nextStop.position)
            if not state.approach or state.approach.order ~= nextOrder then
                if distance <= ROUTE_PASS_APPROACH_RADIUS then
                    state.approach = {
                        order = nextOrder,
                        minimumDistance = distance,
                        lastDistance = distance
                    }
                end
            else
                local approach = state.approach
                approach.minimumDistance = math.min(approach.minimumDistance, distance)
                local movedAway = approach.minimumDistance <= ROUTE_PASS_MAX_MIN_DISTANCE
                    and distance > approach.lastDistance + 0.75
                    and distance >= ROUTE_PASS_CONFIRM_DISTANCE
                    and distance >= approach.minimumDistance + ROUTE_PASS_DISTANCE_GAIN
                if movedAway then
                    state.passedOrder = nextOrder
                    state.approach = nil
                else
                    approach.lastDistance = distance
                end
            end
        end
    end

    local upcomingStops = {}
    local allStopsData = {}

    for order, stop in ipairs(routeStops) do
        local dist = horizontalDistance(referencePos, stop.position)
        table.insert(allStopsData, {
            index = stop.index,
            stopId = stop.stopId,
            name = stop.name,
            route = stop.route,
            direction = stop.direction,
            x = stop.x,
            y = stop.y,
            z = stop.z,
            distance = round1(dist)
        })

        -- 지나간 정류장 제외, 현재 있는 정류장 제외 -> 다음 정류장들부터만 하차 예약 대상에 포함
        local isPassed = order <= state.passedOrder
        local isCurrent = currentStop and order == closestOrder
        if not isPassed and not isCurrent then
            table.insert(upcomingStops, {
                index = stop.index,
                stopId = stop.stopId,
                name = stop.name,
                route = stop.route,
                direction = stop.direction,
                x = stop.x,
                y = stop.y,
                z = stop.z,
                distance = round1(dist)
            })
        end
    end

    local currentStopData = currentStop and {
        index = currentStop.index,
        stopId = currentStop.stopId,
        name = currentStop.name,
        route = currentStop.route,
        direction = currentStop.direction,
        distance = round1(closestDist)
    } or nil

    return currentStopData, upcomingStops, allStopsData
end

-- =========================================================================
-- [4. Firebase 하차 예약 폴링 및 목표 정류장 접근 시 자동 하차벨 트리거]
-- =========================================================================
local activeReservations = {}
local lastReservationPollTime = 0
local boardingConflictDeletesInFlight = {}
local boardingConflictIgnoredUntil = {}

local function pollReservationsAsync()
    local now = os.clock()
    if now - lastReservationPollTime < 1.2 then
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

        if success and response.Success then
            -- 예약이 모두 취소되어 Firebase가 null을 돌려주면 이전 예약을 메모리에
            -- 남기지 않습니다. 남은 데이터 때문에 벨이 다시 작동하는 문제를 막습니다.
            if not response.Body or response.Body == "null" then
                activeReservations = {}
            else
                local data = HttpService:JSONDecode(response.Body)
                if typeof(data) == "table" then
                    local pollNow = os.clock()
                    for reservationKey, ignoredUntil in pairs(boardingConflictIgnoredUntil) do
                        if ignoredUntil > pollNow then
                            data[reservationKey] = nil
                        else
                            boardingConflictIgnoredUntil[reservationKey] = nil
                        end
                    end
                    activeReservations = data
                end
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
    if not instance then return nil end

    -- 1. 조상들을 거슬러 올라가며 CollectionService에 "BUS" 태그가 붙은 최상위 버스 모델을 찾음
    local highestBusModel = nil
    local current = instance
    while current and current ~= workspace and current ~= game do
        if current:IsA("Model") and CollectionService:HasTag(current, "BUS") then
            highestBusModel = current -- 더 상위에 BUS 태그 모델이 있다면 계속 갱신
        end
        current = current.Parent
    end
    if highestBusModel then
        return highestBusModel
    end

    -- 2. "BUS" 태그가 상위에 없다면, VehicleSeat이나 노선/고상 속성을 가진 상위 모델 탐색
    current = instance
    local candidateModel = nil
    while current and current ~= workspace and current ~= game do
        if current:IsA("Model") then
            candidateModel = candidateModel or current
            if current:FindFirstChildOfClass("VehicleSeat")
               or current:GetAttribute("route")
               or current:GetAttribute("isHighFloor")
               or current:GetAttribute("BUS") then
                return current
            end
        end
        current = current.Parent
    end

    -- 3. workspace 바로 아래에 위치한 최상위 모델 탐색 (대부분의 버스 완성체 모델)
    current = instance
    local topLevelModel = nil
    while current and current.Parent and current.Parent ~= game do
        if current:IsA("Model") and current.Parent == workspace then
            topLevelModel = current
            break
        end
        current = current.Parent
    end
    if topLevelModel then
        return topLevelModel
    end

    -- 4. 폴백: instance 자체 또는 가장 가까운 상위 Model
    if instance:IsA("Model") then
        return instance
    end

    return instance:FindFirstAncestorOfClass("Model") or candidateModel
end

local lastRouteDirectionRequest = {}

local function replyRouteDirection(player, success, message, model, direction, action)
    routeDirectionRemote:FireClient(player, {
        success = success,
        message = message,
        busId = model and model:GetFullName() or nil,
        route = model and tostring(getValueFromInstance(model, { "route", "Route", "ROUTE", "Line", "line", "노선" }, "")) or "",
        direction = direction,
        action = action or "start",
        inService = model and model:GetAttribute("RouteDirectionConfirmed") == true or false
    })
end

routeDirectionRemote.OnServerEvent:Connect(function(player, requestedModel, requestedDirection, requestedAction)
    local now = os.clock()
    if now - (lastRouteDirectionRequest[player] or 0) < 0.5 then return end
    lastRouteDirectionRequest[player] = now

    local action = tostring(requestedAction or "start"):lower()
    if action ~= "stop" then action = "start" end
    local direction = normalizeRouteDirection(requestedDirection)

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local seat = humanoid and humanoid.SeatPart
    if not seat or not seat:IsA("VehicleSeat") then
        local seatMessage = action == "stop"
            and "운전석에 앉은 상태에서만 운행을 중지할 수 있습니다."
            or "운전석에 앉은 상태에서만 운행을 시작할 수 있습니다."
        replyRouteDirection(player, false, seatMessage, nil, nil, action)
        return
    end

    local model = getVehicleModel(seat)
    if not model or not model:IsDescendantOf(workspace) or requestedModel ~= model then
        replyRouteDirection(player, false, "현재 운전 중인 버스를 확인할 수 없습니다.", nil, nil, action)
        return
    end

    if action == "stop" then
        if model:GetAttribute("RouteDirectionConfirmed") ~= true then
            replyRouteDirection(player, false, "이미 운행이 중지된 버스입니다.", model, getBusRouteDirection(model), action)
            return
        end
        model:SetAttribute("RouteDirectionConfirmed", false)
        model:SetAttribute("RouteDirectionStoppedAt", DateTime.now().UnixTimestampMillis)
        model:SetAttribute("RouteDirectionStoppedByUserId", player.UserId)
        busRouteProgress[model:GetFullName()] = nil
        local routeName = tostring(getValueFromInstance(model, { "route", "Route", "ROUTE", "Line", "line", "노선" }, ""))
        print(string.format("[버스 운행 중지] %s / %s번 / 운전자 %s", model.Name, routeName, player.Name))
        replyRouteDirection(player, true, string.format("%s번 버스 운행을 중지했습니다.", routeName ~= "" and routeName or "해당"), model, getBusRouteDirection(model), action)
        return
    end

    if direction ~= "up" and direction ~= "down" then
        replyRouteDirection(player, false, "상행 또는 하행을 선택해 주세요.", model, nil, action)
        return
    end

    local wasAlreadyInService = model:GetAttribute("RouteDirectionConfirmed") == true
    model:SetAttribute("RouteDirection", direction)
    model:SetAttribute("RouteDirectionConfirmed", true)
    model:SetAttribute("RouteDirectionDriverUserId", player.UserId)
    if not wasAlreadyInService then
        model:SetAttribute("RouteDirectionStartedAt", DateTime.now().UnixTimestampMillis)
    end
    model:SetAttribute("RouteDirectionUpdatedAt", DateTime.now().UnixTimestampMillis)
    busRouteProgress[model:GetFullName()] = nil

    local directionLabel = direction == "up" and "상행" or "하행"
    local routeName = tostring(getValueFromInstance(model, { "route", "Route", "ROUTE", "Line", "line", "노선" }, ""))
    local actionLabel = wasAlreadyInService and "방향 변경" or "운행 시작"
    print(string.format("[버스 %s] %s / %s번 %s / 운전자 %s", actionLabel, model.Name, routeName, directionLabel, player.Name))
    replyRouteDirection(player, true, string.format("%s번 %s%s.", routeName ~= "" and routeName or "버스", directionLabel, wasAlreadyInService and "으로 변경했습니다" or " 운행을 시작합니다"), model, direction, action)
end)

Players.PlayerRemoving:Connect(function(player)
    lastRouteDirectionRequest[player] = nil
end)

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
        -- UserId를 우선 사용하므로 표시명 변경이나 대소문자 차이에도 같은 계정을 찾습니다.
        -- 서버 인원수를 이용한 대체 선택은 하지 않습니다.
        local hasConfiguredTarget = (TARGET_ROBLOX_USER_NAME and TARGET_ROBLOX_USER_NAME ~= "")
            or (TARGET_ROBLOX_USER_ID and TARGET_ROBLOX_USER_ID > 0)
        local isTarget = not hasConfiguredTarget
            or isConfiguredTargetPlayer(player)

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

determineIsHighFloor = function(model, taggedPart, boardingPart)
    local HIGH_TAGS = {
        "HIGH", "High", "high",
        "HIGH_FLOOR", "HighFloor", "high_floor", "highfloor", "High_Floor",
        "고상", "고상버스", "고상형",
        "TWO_STEP", "TwoStep", "twostep", "two_step", "투스텝",
        "UNIVERSE", "Universe", "universe", "유니버스",
        "GRANBIRD", "Granbird", "granbird", "그랜버드"
    }

    local LOW_TAGS = {
        "LOW", "Low", "low",
        "LOW_FLOOR", "LowFloor", "low_floor", "lowfloor", "Low_Floor",
        "저상", "저상버스", "초저상", "초저상버스",
        "NON_STEP", "NonStep", "nonstep", "non_step", "논스텝"
    }

    local HIGH_KEYS = {
        "ishighfloor", "highfloor", "high", "ishigh", "is_high", "is_high_floor",
        "floortype", "floor", "type", "bustype", "차종", "타입", "고상", "고상버스"
    }

    local LOW_KEYS = {
        "islowfloor", "lowfloor", "low", "islow", "is_low", "is_low_floor",
        "저상", "저상버스", "초저상"
    }

    -- 검사 대상 인스턴스들 수집
    local checkTargets = {}
    local seen = {}
    local function addTarget(inst)
        if inst and not seen[inst] then
            seen[inst] = true
            table.insert(checkTargets, inst)
        end
    end

    addTarget(boardingPart)
    addTarget(taggedPart)
    addTarget(model)
    if model and model.Parent and model.Parent:IsA("Model") then
        addTarget(model.Parent)
    end

    -- 모델 내부의 중요 서브 구성품 추가
    if model then
        for _, name in ipairs({ "Body", "Main", "Chassis", "Configuration", "Settings", "Values", "Interior", "Seats" }) do
            local child = model:FindFirstChild(name)
            if child then
                addTarget(child)
            end
        end
    end

    -- 1. CollectionService 태그 검사 (타겟 및 모델 직속/주요 파트)
    for _, inst in ipairs(checkTargets) do
        for _, tag in ipairs(HIGH_TAGS) do
            if CollectionService:HasTag(inst, tag) then
                return true
            end
        end
        for _, tag in ipairs(LOW_TAGS) do
            if CollectionService:HasTag(inst, tag) then
                return false
            end
        end
    end

    -- 모델 전체 자손 중 태그 검사
    if model then
        for _, desc in ipairs(model:GetDescendants()) do
            for _, tag in ipairs(HIGH_TAGS) do
                if CollectionService:HasTag(desc, tag) then
                    return true
                end
            end
        end
    end

    -- 2. Attribute(속성) 및 ValueBase(값 객체) 전수 조사
    for _, inst in ipairs(checkTargets) do
        -- A. Attributes 검사
        local attrs = inst:GetAttributes()
        for attrName, attrVal in pairs(attrs) do
            local lowerKey = attrName:lower()
            for _, hk in ipairs(HIGH_KEYS) do
                if lowerKey == hk or lowerKey:find(hk) then
                    if isTruthy(attrVal) then
                        return true
                    elseif isFalsy(attrVal) then
                        return false
                    end
                end
            end
            for _, lk in ipairs(LOW_KEYS) do
                if lowerKey == lk or lowerKey:find(lk) then
                    if isTruthy(attrVal) then
                        return false
                    end
                end
            end
        end

        -- B. ValueBase 자식 검사
        for _, child in ipairs(inst:GetChildren()) do
            if child:IsA("ValueBase") then
                local lowerName = child.Name:lower()
                for _, hk in ipairs(HIGH_KEYS) do
                    if lowerName == hk or lowerName:find(hk) then
                        if isTruthy(child.Value) then
                            return true
                        elseif isFalsy(child.Value) then
                            return false
                        end
                    end
                end
                for _, lk in ipairs(LOW_KEYS) do
                    if lowerName == lk or lowerName:find(lk) then
                        if isTruthy(child.Value) then
                            return false
                        end
                    end
                end
            end
        end
    end

    -- 3. 모델 자손 전체에서 Attributes / ValueBase / 파트 이름 심층 탐색
    if model then
        for _, desc in ipairs(model:GetDescendants()) do
            -- A. 자손 Attributes 전수 조사
            local descAttrs = desc:GetAttributes()
            for attrName, attrVal in pairs(descAttrs) do
                local lowerKey = attrName:lower()
                for _, hk in ipairs(HIGH_KEYS) do
                    if lowerKey == hk or lowerKey:find(hk) then
                        if isTruthy(attrVal) then
                            return true
                        end
                    end
                end
            end

            -- B. 자손 ValueBase 검사
            if desc:IsA("ValueBase") then
                local lowerName = desc.Name:lower()
                for _, hk in ipairs(HIGH_KEYS) do
                    if lowerName == hk or lowerName:find(hk) then
                        if isTruthy(desc.Value) then
                            return true
                        end
                    end
                end
            end

            -- C. 파트 이름 자체에 고상 키워드가 있는 경우 (예: HighFloor, 고상발판, BUSin_HIGH, TwoStep 등)
            local lowerDescName = desc.Name:lower()
            if lowerDescName:find("highfloor") or lowerDescName:find("high_floor") or lowerDescName:find("고상") or lowerDescName:find("twostep") or lowerDescName:find("투스텝") then
                return true
            end
        end
    end

    -- 4. 모델 및 부모 이름 키워드 분석 (유니버스, 그랜버드, 에어로스페이스, 고상 등)
    if model then
        local fullName = (model.Name .. " " .. (model.Parent and model.Parent.Name or "")):lower()
        local highKeywords = {
            "고상", "high", "universe", "유니버스", "granbird", "그랜버드",
            "aerospace", "에어로스페이스", "fx116", "fx120", "fx212",
            "bh090", "bh115", "bh116", "bh120", "bx212", "투스텝", "twostep"
        }
        local lowKeywords = { "저상", "low", "nonstep", "초저상" }

        local hasLow = false
        for _, lk in ipairs(lowKeywords) do
            if fullName:find(lk) then
                hasLow = true
                break
            end
        end

        if not hasLow then
            for _, hk in ipairs(highKeywords) do
                if fullName:find(hk) then
                    return true
                end
            end
        end
    end

    return false -- 기본값: 저상 (false)
end

local reservationBindingUpdatesInFlight = {}

local function reservationMatchesVehicleIdentity(reservation, routeName, routeDirection, busLicense)
    if typeof(reservation) ~= "table" then return false end

    local reservedLicense = reservation.vehicleNumber ~= nil and tostring(reservation.vehicleNumber) or ""
    local liveLicense = busLicense ~= nil and tostring(busLicense) or ""
    if reservedLicense ~= "" or liveLicense ~= "" then
        if reservedLicense == "" or liveLicense == "" or reservedLicense ~= liveLicense then return false end
        if tostring(reservation.route or "") ~= tostring(routeName or "") then return false end
        local reservedDirection = normalizeRouteDirection(reservation.direction)
        return not reservedDirection or not routeDirection or reservedDirection == routeDirection
    end

    -- 차량번호가 양쪽 모두 없는 이전 예약은 호출부의 버스 경로 ID 비교를 사용합니다.
    return true
end

local function findReservationForBus(model, routeName, routeDirection, busLicense)
    local liveBusId = model:GetFullName()
    local liveBusKey = liveBusId:gsub("[%.%#%$/%[%]]", "_")

    local directReservation = activeReservations[liveBusKey]
    if directReservation and reservationMatchesVehicleIdentity(directReservation, routeName, routeDirection, busLicense) then
        return directReservation, liveBusKey
    end
    local legacyNamedReservation = activeReservations[model.Name]
    if legacyNamedReservation
        and legacyNamedReservation.vehicleNumber ~= nil
        and busLicense ~= nil
        and reservationMatchesVehicleIdentity(legacyNamedReservation, routeName, routeDirection, busLicense) then
        return legacyNamedReservation, model.Name
    end

    -- Firebase 키는 예전 차량명으로 남아 있어도 payload의 busId가 현재 차량과
    -- 갱신된 예약은 계속 같은 차량의 예약으로 처리합니다.
    for reservationKey, reservation in pairs(activeReservations) do
        if typeof(reservation) == "table"
            and tostring(reservation.busId or "") == liveBusId
            and reservationMatchesVehicleIdentity(reservation, routeName, routeDirection, busLicense) then
            return reservation, reservationKey
        end
    end

    -- 승차 전에 예약한 차량 모델이 탑승 시 복제·개명되면 FullName이 달라질 수
    -- 있습니다. 실제 지정 플레이어가 이 모델에 탑승한 경우에만 같은 노선의
    -- 승차 대기 예약 하나를 현재 차량에 결속합니다.
    local boardingEvidence = lastBoardedBus and lastBoardedBus.boardingEvidence or nil
    local hasConfirmedBoarding = boardingEvidence == "seat"
        or boardingEvidence == "floor"
        or boardingEvidence == "busin"
        or boardingEvidence == "boarding_part"
    if not lastBoardedBus or lastBoardedBus.model ~= model or not hasConfirmedBoarding then
        return nil, liveBusKey
    end

    local matchedReservation = nil
    local matchedKey = nil
    for reservationKey, reservation in pairs(activeReservations) do
        local isPending = typeof(reservation) == "table"
            and (reservation.status == nil or reservation.status == "pending")
        local isWaiting = isPending and reservation.awaitingBoarding == true
        local sameRoute = isWaiting and tostring(reservation.route or "") == tostring(routeName or "")
        local reservedDirection = normalizeRouteDirection(reservation.direction)
        local sameDirection = not reservedDirection or not routeDirection or reservedDirection == routeDirection
        local reservedLicense = reservation.vehicleNumber ~= nil and tostring(reservation.vehicleNumber) or nil
        -- 차량 FullName이 바뀐 경우의 재결속은 차량번호가 양쪽에 있고 정확히
        -- 일치할 때만 허용합니다. 차량번호가 없는 같은 노선의 다른 버스에
        -- 예약이 잘못 붙는 것을 방지합니다.
        local sameVehicle = reservedLicense ~= nil
            and busLicense ~= nil
            and reservationMatchesVehicleIdentity(reservation, routeName, routeDirection, busLicense)
        if sameRoute and sameDirection and sameVehicle then
            if matchedReservation then
                warn(string.format(
                    "[하차 예약 결속 보류] 노선 %s의 승차 대기 예약이 여러 개라 차량을 확정할 수 없습니다.",
                    tostring(routeName)
                ))
                return nil, liveBusKey
            end
            matchedReservation = reservation
            matchedKey = reservationKey
        end
    end

    if not matchedReservation then
        return nil, liveBusKey
    end

    matchedReservation.busId = liveBusId
    matchedReservation.busName = model.Name
    matchedReservation.awaitingBoarding = false
    matchedReservation.boardedAt = DateTime.now().UnixTimestampMillis

    if not reservationBindingUpdatesInFlight[matchedKey] then
        reservationBindingUpdatesInFlight[matchedKey] = true
        task.spawn(function()
            local success, err = pcall(function()
                local response = HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/radar/reservations/" .. matchedKey .. ".json",
                    Method = "PATCH",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode({
                        busId = liveBusId,
                        busName = model.Name,
                        awaitingBoarding = false,
                        boardedAt = matchedReservation.boardedAt
                    })
                })
                if not response.Success then
                    error(string.format("Firebase reservation binding HTTP %s: %s", response.StatusCode, response.StatusMessage))
                end
            end)
            reservationBindingUpdatesInFlight[matchedKey] = nil
            if success then
                print(string.format(
                    "[하차 예약 차량 결속] %s -> %s (노선 %s)",
                    tostring(matchedKey),
                    liveBusId,
                    tostring(routeName)
                ))
            else
                warn("[하차 예약 차량 결속 실패]", err)
            end
        end)
    end

    return matchedReservation, matchedKey
end

local function reservationBelongsToBoardedBus(reservationKey, reservation, model)
    if typeof(reservation) ~= "table" or not model then return false end

    local liveBusId = model:GetFullName()
    local liveBusKey = liveBusId:gsub("[%.%#%$/%[%]]", "_")
    local reservedLicense = reservation.vehicleNumber ~= nil and tostring(reservation.vehicleNumber) or ""
    local liveLicenseValue = getBusLicense(model)
    local liveLicense = liveLicenseValue ~= nil and tostring(liveLicenseValue) or ""
    local liveRoute = tostring(getValueFromInstance(model, { "route", "Route", "ROUTE", "Line", "line", "노선" }, ""))
    local liveDirection = getBusRouteDirection(model)

    -- 같은 이름의 버스 Model은 GetFullName도 같을 수 있습니다. 차량번호가
    -- 하나라도 있으면 경로 ID보다 차량번호·노선·방향 일치를 우선합니다.
    if reservedLicense ~= "" or liveLicense ~= "" then
        return reservationMatchesVehicleIdentity(reservation, liveRoute, liveDirection, liveLicenseValue)
    end

    -- 차량번호가 양쪽 모두 없는 이전 데이터만 경로 ID로 호환합니다.
    return reservationKey == liveBusKey or tostring(reservation.busId or "") == liveBusId
end

local function cancelReservationsForDifferentBoardedBus(model)
    if not model then return 0 end

    local conflicts = {}
    for reservationKey, reservation in pairs(activeReservations) do
        local status = typeof(reservation) == "table" and tostring(reservation.status or "pending") or ""
        local isActive = status == "pending" or status == "triggered"
        if isActive
            and not boardingConflictDeletesInFlight[reservationKey]
            and not reservationBelongsToBoardedBus(reservationKey, reservation, model) then
            table.insert(conflicts, {
                key = reservationKey,
                reservation = reservation
            })
        end
    end

    for _, conflict in ipairs(conflicts) do
        local reservationKey = conflict.key
        local reservation = conflict.reservation
        activeReservations[reservationKey] = nil
        boardingConflictDeletesInFlight[reservationKey] = true
        boardingConflictIgnoredUntil[reservationKey] = os.clock() + 5
        task.spawn(function()
            local success, err = pcall(function()
                local response = HttpService:RequestAsync({
                    Url = FIREBASE_DATABASE_URL .. "/radar/reservations/" .. reservationKey .. ".json",
                    Method = "DELETE"
                })
                if not response.Success then
                    error(string.format("Firebase reservation delete HTTP %s: %s", response.StatusCode, response.StatusMessage))
                end
            end)
            boardingConflictDeletesInFlight[reservationKey] = nil
            if success then
                print(string.format(
                    "[탑승 차량 변경 예약 취소] %s 예약 삭제 -> 탑승 버스 %s",
                    tostring(reservationKey),
                    model:GetFullName()
                ))
            else
                boardingConflictIgnoredUntil[reservationKey] = nil
                if activeReservations[reservationKey] == nil then
                    activeReservations[reservationKey] = reservation
                end
                warn("[탑승 차량 변경 예약 취소 실패]", err)
            end
        end)
    end

    return #conflicts
end

local function collectBusData()
    pollReservationsAsync()

    local busesData = {}
    local seenModels = {}

    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getVehicleModel(tagged)
        -- ReplicatedStorage의 BusModels는 차량 복제용 원본입니다. 실제 게임 월드의
        -- 버스가 아니므로 BUS 태그가 있어도 레이더에 전송하지 않습니다.
        if model and model:IsDescendantOf(workspace) and not seenModels[model] then
            seenModels[model] = true

            -- 좌표와 방향은 이후 정류장 계산 및 Firebase payload 양쪽에서 사용됩니다.
            -- 이전에는 pos/angle이 선언되지 않아 버스가 하나라도 있으면 이 함수가
            -- 오류로 중단되고, 결과적으로 지도 위치 전체가 갱신되지 않았습니다.
            local pos, angle, frontPartName, backPartName, positionPartName = getBusPose(model, tagged)
            local frontPart, backPart = getBusParts(model)
            local activeBoardingPart = (lastBoardedBus and lastBoardedBus.model == model and lastBoardedBus.part) or nil
            local isHighFloor = determineIsHighFloor(model, tagged, activeBoardingPart)
            if not isHighFloor and lastBoardedBus and lastBoardedBus.model == model and lastBoardedBus.isHighFloor ~= nil then
                isHighFloor = lastBoardedBus.isHighFloor
            end
            local routeName = tostring(getValueFromInstance(model, { "route", "Route", "ROUTE", "Line", "line", "노선" }, ""))
            if routeName == "" and model then
                routeName = tostring(model.Name:match("%d+") or "")
            end
            local routeDirection = getBusRouteDirection(model)
            local routeDirectionConfirmed = model:GetAttribute("RouteDirectionConfirmed") == true
            -- 운행 시작/중지는 운전자 GUI 버튼으로만 제어합니다. 운전자가 잠시
            -- 내려도 시작 상태를 유지하여 지도와 기존 하차 예약이 끊기지 않습니다.
            local isInService = routeDirectionConfirmed
                and (routeDirection == "up" or routeDirection == "down")
            local busLicense = getBusLicense(model)
            -- 하차벨 시스템 초기화 (ProximityPrompt 등 연결)
            local bellSystem = getOrCreateBusBellSystem(model)

            -- 이전 정상 커밋과 동일하게 정류장 로딩은 운전자 착석/isInService와
            -- 분리합니다. 운전자 판정이 잠깐 끊겨도 지도 정류장과 남은 목록은 유지됩니다.
            local routeStops = loadRouteStops(routeName, routeDirection)
            if #routeStops == 0 then
                routeStops = buildFallbackRouteStops(routeName, routeDirection)
                if #routeStops > 0 and not routeFallbackNotices[routeName] then
                    routeFallbackNotices[routeName] = true
                    warn(string.format(
                        "[노선 정류장 대체 연결] 노선 %s: 노선 폴더 대신 BUS_STOP 태그 정류장 %d개를 사용합니다.",
                        tostring(routeName),
                        #routeStops
                    ))
                end
            end
            local currentStop, upcomingStops, allStops = calculateStopProgress(model, routeStops, frontPart, backPart, pos)

            -- 하차 예약 감지 및 자동 트리거 검사
            local reservation, reservationKey = findReservationForBus(model, routeName, routeDirection, busLicense)
            if isInService
                and reservation
                and reservation.awaitingBoarding ~= true
                and (reservation.status == "pending" or reservation.status == nil) then
                local targetIndex = tonumber(reservation.targetStopIndex)
                local targetStopId = reservation.targetStopId and tostring(reservation.targetStopId) or nil
                local targetStop = nil
                for _, stop in ipairs(routeStops) do
                    -- 신규 예약은 정류장 고유 번호를 우선 사용합니다. 예전 예약은 순번으로 계속 호환합니다.
                    local isTarget = targetStopId and stop.stopId and tostring(stop.stopId) == targetStopId
                        or (not targetStopId and stop.index == targetIndex)
                    if isTarget then
                        targetStop = stop
                        break
                    end
                end

                -- 새 웹 예약은 좌표도 저장합니다. 게임 접속 직후 routeStops가 아직 비어도 자동 예약이 작동합니다.
                if not targetStop then
                    local x, y, z = tonumber(reservation.targetStopX), tonumber(reservation.targetStopY), tonumber(reservation.targetStopZ)
                    if x and z then
                        targetStop = {
                            name = tostring(reservation.targetStopName or "예약 정류장"),
                            position = Vector3.new(x, y or pos.Y, z)
                        }
                    end
                end

                if targetStop then
                    local referencePos = frontPart and frontPart.Position or pos
                    local distToTarget = horizontalDistance(referencePos, targetStop.position)
                    if distToTarget <= ARRIVAL_TRIGGER_DISTANCE then
                        -- 이미 게임 하차벨이 켜진 차량은 예약 도착으로 다시 울리지 않습니다.
                        -- 예약 상태만 triggered로 바꿔 앱의 진동/알림은 계속 전달합니다.
                        if not bellSystem.isRinging then
                            -- 장애인 모드 + 저상버스이면 B(장애인) 벨을, 그 외에는 기존 일반 벨을 사용합니다.
                            local useAccessibilityBell = reservation.accessibilityMode == true and not isHighFloor
                            triggerBusBell(model, nil, "AUTO_RESERVATION: " .. targetStop.name, false, useAccessibilityBell)
                        else
                            print("[하차 예약] 기존 하차벨 작동 중 - 게임 벨 재작동 없이 앱 알림만 전송:", targetStop.name)
                        end
                        reservation.status = "triggered"
                        task.spawn(function()
                            pcall(function()
                                HttpService:RequestAsync({
                                    Url = FIREBASE_DATABASE_URL .. "/radar/reservations/" .. reservationKey .. "/status.json",
                                    Method = "PUT",
                                    Headers = { ["Content-Type"] = "application/json" },
                                    Body = HttpService:JSONEncode("triggered")
                                })
                            end)
                        end)
                    end
                end
            end

            -- 몇 초 후 자동 소등이 아닌, 게임 내 하차벨 신호(라이트 소등 등) 감지 시 소등 및 Firebase 전송
            if bellSystem.isRinging and isGameBellTurnedOff(bellSystem) then
                resetBusBell(model, true)
            end

            table.insert(busesData, {
                id = model:GetFullName(),
                name = model.Name,
                route = routeName,
                vehicleNumber = busLicense,
                direction = routeDirection,
                directionLabel = routeDirection == "up" and "상행" or (routeDirection == "down" and "하행" or "미설정"),
                inService = isInService,
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
                -- 지도/앱에는 지정 사용자가 실제 탑승한 차량의 벨 상태만 전달합니다.
                -- 다른 플레이어가 다른 버스에서 누른 벨은 게임 안에서만 동작합니다.
                isBellRinging = isTargetPlayersCurrentBus(model) and bellSystem.isRinging == true,
                timestamp = DateTime.now().UnixTimestampMillis
            })
        end
    end

    -- 하나의 실제 버스에 BUS 태그가 여러 하위 모델/파트에 붙은 경우, 서로 다른
    -- 모델로 수집될 수 있습니다. 같은 노선·차종이며 좌표가 4 studs 이내인 경우만
    -- 중복으로 합칩니다. 고상/저상처럼 차종이 다른 실제 차량은 절대 합치지 않습니다.
    local uniqueBuses = {}
    for _, bus in ipairs(busesData) do
        local duplicate = nil
        for _, existing in ipairs(uniqueBuses) do
            local sameRoute = tostring(existing.route or "") == tostring(bus.route or "")
            local sameDirection = tostring(existing.direction or "") == tostring(bus.direction or "")
            local sameFloor = existing.isHighFloor == bus.isHighFloor
            local existingLicense = existing.vehicleNumber ~= nil and tostring(existing.vehicleNumber) or nil
            local incomingLicense = bus.vehicleNumber ~= nil and tostring(bus.vehicleNumber) or nil
            local sameVehicle = true
            if existingLicense and incomingLicense then
                sameVehicle = existingLicense == incomingLicense
            end
            local distance = math.sqrt((existing.x - bus.x) ^ 2 + (existing.z - bus.z) ^ 2)
            if sameRoute and sameDirection and sameFloor and sameVehicle and distance <= 4 then
                duplicate = existing
                break
            end
        end

        if duplicate then
            -- 정류장 정보가 더 풍부한 쪽을 유지합니다.
            if #(duplicate.allStops or {}) == 0 and #(bus.allStops or {}) > 0 then
                duplicate.allStops = bus.allStops
                duplicate.upcomingStops = bus.upcomingStops
                duplicate.currentStop = bus.currentStop
            end
            duplicate.isBellRinging = duplicate.isBellRinging or bus.isBellRinging
            warn(string.format("[로블록스 레이더] 중복 BUS 태그 병합: %s / %s", duplicate.id, bus.id))
        else
            table.insert(uniqueBuses, bus)
        end
    end

    return uniqueBuses
end

local function findTargetPlayer()
    local allPlayers = Players:GetPlayers()
    if #allPlayers == 0 then
        return nil
    end

    if (TARGET_ROBLOX_USER_NAME and TARGET_ROBLOX_USER_NAME ~= "")
        or (TARGET_ROBLOX_USER_ID and TARGET_ROBLOX_USER_ID > 0) then
        for _, player in ipairs(allPlayers) do
            if isConfiguredTargetPlayer(player) then
                return player
            end
        end
        return nil
    end

    return allPlayers[1]
end

-- 특정 파트가 BUSin(탑승 감지용 파트)인지 판별 (태그, 이름, 속성 모두 지원)
local function isBusInPart(part)
    if not part or not part:IsA("BasePart") then
        return false
    end
    for _, tag in ipairs(BUSIN_TAGS) do
        if CollectionService:HasTag(part, tag) then
            return true
        end
    end
    local nameLower = part.Name:lower()
    if nameLower == "busin" or nameLower:find("busin") or nameLower == "bus_in" then
        return true
    end
    for _, tag in ipairs(BUSIN_TAGS) do
        if part:GetAttribute(tag) ~= nil then
            return true
        end
    end
    return false
end

-- 플레이어의 발 아래에 있는 실제 접촉 바닥 파트 탐색 (Raycast 기반 - 서 있거나 걷는 경우 100% 감지)
local function getFloorPartUnderCharacter(character)
    if not character then return nil end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character.PrimaryPart
    if not hrp then return nil end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { character }
    rayParams.IgnoreWater = true

    -- 허리(HRP) 기준 아래로 4.5 studs (발바닥 및 지면) 레이캐스트
    local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -4.5, 0), rayParams)
    if hit and hit.Instance and hit.Instance:IsA("BasePart") then
        return hit.Instance
    end

    -- 걷기/달리기/미세 점프 중일 때를 위한 7.0 studs 확장 레이캐스트
    hit = workspace:Raycast(hrp.Position, Vector3.new(0, -7.0, 0), rayParams)
    if hit and hit.Instance and hit.Instance:IsA("BasePart") then
        return hit.Instance
    end

    return nil
end

-- 3D 공간 상에서 특정 좌표가 파트 내부 또는 상단 탑승 영역에 있는지 판정 (파트 회전 방향 무관 수학 계산)
local function isPointInsidePartAnyOrientation(point, part, heightMargin)
    local lp = part.CFrame:PointToObjectSpace(point)
    local h = heightMargin or 8.5
    local sx, sy, sz = part.Size.X * 0.5, part.Size.Y * 0.5, part.Size.Z * 0.5

    -- 1) Y축이 높이 방향인 일반적인 파트
    if math.abs(lp.X) <= (sx + 1.2) and math.abs(lp.Z) <= (sz + 1.2) and (lp.Y >= -sy - 1.2 and lp.Y <= sy + h) then
        return true
    end
    -- 2) X축이 높이 방향인 90도 회전 파트
    if math.abs(lp.Y) <= (sy + 1.2) and math.abs(lp.Z) <= (sz + 1.2) and (lp.X >= -sx - 1.2 and lp.X <= sx + h) then
        return true
    end
    -- 3) Z축이 높이 방향인 90도 회전 파트
    if math.abs(lp.X) <= (sx + 1.2) and math.abs(lp.Y) <= (sy + 1.2) and (lp.Z >= -sz - 1.2 and lp.Z <= sz + h) then
        return true
    end

    -- 4) 월드 좌표 수평/수직 보조 판정 (초대형 바닥 파트)
    local worldDelta = point - part.Position
    local maxHoriz = math.max(part.Size.X, part.Size.Z, part.Size.Y) * 0.6 + 1.5
    if math.abs(worldDelta.Y) <= 8.5 and (worldDelta.X * worldDelta.X + worldDelta.Z * worldDelta.Z) <= (maxHoriz * maxHoriz) then
        if worldDelta.Y >= -2.0 then
            return true
        end
    end

    return false
end

-- 플레이어가 특정 파트(바닥, 발판, BUSin 파트, 내부 영역) 안에 들어가 있거나 닿아있는지 판정
local function isCharacterTouchingPart(character, part)
    if not character or not part or not part:IsA("BasePart") then
        return false
    end

    local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso") or character.PrimaryPart
    if not hrp then
        return false
    end

    -- 1. 검사할 캐릭터의 신체 주요 부위 좌표 수집 (HRP, 발바닥, 다리, 몸통)
    local testPoints = { hrp.Position, hrp.Position - Vector3.new(0, 2.7, 0) }
    for _, partName in ipairs({ "LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg", "LowerTorso", "Torso", "UpperTorso" }) do
        local bodyPart = character:FindFirstChild(partName)
        if bodyPart and bodyPart:IsA("BasePart") then
            table.insert(testPoints, bodyPart.Position)
        end
    end

    -- 2. 회전 무관 3D 공간 판정 (CanCollide/CanQuery 꺼짐 파트도 100% 안전하게 계산)
    for _, pt in ipairs(testPoints) do
        if isPointInsidePartAnyOrientation(pt, part, 8.5) then
            return true
        end
    end

    -- 3. 로블록스 물리 공간 쿼리 보조 (오류 방지를 위해 pcall로 안전 실행)
    local isBoxOverlap = false
    pcall(function()
        local pSize = part.Size
        local boxSize = Vector3.new(pSize.X + 2.0, math.max(pSize.Y + 8.0, 10.0), pSize.Z + 2.0)
        local overlapParams = OverlapParams.new()
        overlapParams.FilterType = Enum.RaycastFilterType.Include
        overlapParams.FilterDescendantsInstances = { character }
        overlapParams.RespectCanCollide = false
        local found = workspace:GetPartBoundsInBox(part.CFrame * CFrame.new(0, 4.0, 0), boxSize, overlapParams)
        if found and #found > 0 then
            isBoxOverlap = true
        end
    end)
    if isBoxOverlap then
        return true
    end

    return false
end

-- 플레이어가 버스 모델의 3D 바운딩 박스(차체 내부 공간) 안에 들어와 있는지 판정 (최종 안전장치)
local function isCharacterInsideModelBoundingBox(character, model)
    if not character or not model then return false end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    if not hrp then return false end

    local success, cframe, size = pcall(function()
        return model:GetBoundingBox()
    end)
    if not success or not cframe or not size then return false end

    local localPos = cframe:PointToObjectSpace(hrp.Position)
    local half = size * 0.5
    -- 차체 외벽 안쪽(X 마진 -0.1, Z 마진 -0.2)이고, 바닥면보다 위쪽(Y >= -half.Y + 0.5)에 위치
    if math.abs(localPos.X) <= math.max(half.X - 0.1, 1.0) and math.abs(localPos.Z) <= math.max(half.Z - 0.2, 1.0) then
        if localPos.Y >= (-half.Y + 0.5) and localPos.Y <= (half.Y + 1.0) then
            return true
        end
    end
    return false
end

-- 전역의 모든 BUSin 파트 수집 (태그된 파트 + 모델 내부의 BUSin 이름 파트)
local function getAllBusInParts()
    local parts = {}
    local seen = {}

    local function addPart(p)
        if p and p:IsA("BasePart") and not seen[p] then
            seen[p] = true
            table.insert(parts, p)
        end
    end

    for _, tag in ipairs(BUSIN_TAGS) do
        for _, p in ipairs(CollectionService:GetTagged(tag)) do
            addPart(p)
        end
    end

    -- 버스 모델들 내부에서 이름이나 속성에 busin이 포함된 파트도 자동 수집
    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getVehicleModel(tagged)
        if model then
            for _, desc in ipairs(model:GetDescendants()) do
                if isBusInPart(desc) then
                    addPart(desc)
                end
            end
        end
    end

    return parts
end

-- 버스에 속한 탑승 판정 대상 파트들(BUSin 파트, 캔콜/캔쿼리 OFF 파트, 바닥 파트) 추출
local function getBoardingPartsForBus(model, tagged)
    local parts = {}
    local seen = {}

    local function addPart(p)
        if p and p:IsA("BasePart") and not seen[p] then
            seen[p] = true
            table.insert(parts, p)
        end
    end

    if tagged and tagged:IsA("BasePart") then
        addPart(tagged)
    end

    if model then
        for _, desc in ipairs(model:GetDescendants()) do
            if desc:IsA("BasePart") then
                if isBusInPart(desc) then
                    addPart(desc)
                elseif not desc.CanCollide and not desc.CanQuery then
                    addPart(desc)
                elseif CollectionService:HasTag(desc, "BUS") then
                    addPart(desc)
                else
                    local lowerName = desc.Name:lower()
                    if lowerName:find("floor") or lowerName:find("step") or lowerName:find("바닥") or lowerName:find("발판") then
                        addPart(desc)
                    end
                end
            end
        end
    end

    return parts
end

-- 플레이어가 해당 버스에 탑승(착석, 바닥 접촉, BUSin 진입, 차체 내부 진입)했는지 다계층 탐색
local function findBusForPlayer(player)
    local character = player and player.Character
    if not character then
        return nil, nil, nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local seatPart = humanoid and humanoid.SeatPart

    -- 1계층: 좌석 착석 검사 (기존 동작 완벽 보장)
    if seatPart then
        for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
            local model = getVehicleModel(tagged)
            if model and seatPart:IsDescendantOf(model) then
                return model, tagged, seatPart, "seat"
            end
        end
        local seatBus = getVehicleModel(seatPart)
        if seatBus then
            return seatBus, seatPart, seatPart, "seat"
        end
    end

    -- 2계층: 발 아래 바닥 파트 직접 접촉 검사 (서 있거나 걷는 경우 즉시 감지)
    local floorPart = getFloorPartUnderCharacter(character)
    if floorPart then
        -- A. 밟고 있는 파트가 BUSin 태그/이름인 경우
        if isBusInPart(floorPart) then
            local model = getVehicleModel(floorPart)
            if model then
                return model, floorPart, floorPart, "floor"
            end
        end

        -- B. 밟고 있는 파트가 등록된 버스 모델의 구성품인 경우
        for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
            local model = getVehicleModel(tagged)
            if model and floorPart:IsDescendantOf(model) then
                return model, tagged, floorPart, "floor"
            end
        end
    end

    -- 3계층: BUSin 태그/이름 파트 3D 탑승 영역 검사 (안에 들어가 서 있는 경우)
    local busInParts = getAllBusInParts()
    for _, bPart in ipairs(busInParts) do
        if isCharacterTouchingPart(character, bPart) then
            local model = getVehicleModel(bPart)
            if model then
                return model, bPart, bPart, "busin"
            end
        end
    end

    -- 4계층: 버스 내부의 탑승 대상 파트(캔콜/캔쿼리 OFF 바닥, 발판 등) 검사
    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getVehicleModel(tagged)
        if model then
            local boardingParts = getBoardingPartsForBus(model, tagged)
            for _, bPart in ipairs(boardingParts) do
                if isCharacterTouchingPart(character, bPart) then
                    return model, tagged, bPart, "boarding_part"
                end
            end

            -- 5계층: 버스 모델 3D 차체 내부(Bounding Box) 진입 검사 (최종 안전장치)
            if isCharacterInsideModelBoundingBox(character, model) then
                return model, tagged, model.PrimaryPart or tagged, "bounds"
            end
        end
    end

    return nil, nil, nil, nil
end

local lastBoardingReportedBus = nil
local BOARDING_GRACE_PERIOD_SEC = 1.0 -- 버스에서 내리면 정확히 1초 뒤에 연동 해제

-- 선택한 플레이어가 탄 BUS의 상태(접촉 탑승 및 고상/저상 여부, 하차벨 점등 여부)를 하차벨 브리지에 전달
local function collectBellContext()
    local player = findTargetPlayer()
    if not player then
        lastBoardedBus = nil
        return { active = false, canImmediateExit = false, timestamp = DateTime.now().UnixTimestampMillis }
    end

    local model, tagged, detectedPart, boardingEvidence = findBusForPlayer(player)
    local now = os.clock()

    local isHighFloor = false
    if model then
        isHighFloor = determineIsHighFloor(model, tagged, detectedPart)
        lastBoardedBus = {
            model = model,
            tagged = tagged,
            part = detectedPart,
            boardingEvidence = boardingEvidence,
            isHighFloor = isHighFloor,
            time = now
        }
    elseif lastBoardedBus then
        -- 이탈 직후 버퍼 시간 동안은 탑승 상태 유지
        if (now - lastBoardedBus.time) <= BOARDING_GRACE_PERIOD_SEC and lastBoardedBus.model.Parent then
            model = lastBoardedBus.model
            tagged = lastBoardedBus.tagged
            detectedPart = lastBoardedBus.part
            boardingEvidence = "grace"
            lastBoardedBus.boardingEvidence = "grace"
            isHighFloor = lastBoardedBus.isHighFloor or determineIsHighFloor(model, tagged, detectedPart)
        else
            lastBoardedBus = nil
        end
    end

    if not model then
        if lastBoardingReportedBus ~= nil then
            print(string.format("[버스 하차 확인] 플레이어: %s 버스에서 내림 (미탑승 상태 전환)", player.Name))
            lastBoardingReportedBus = nil
        end
        return { active = false, canImmediateExit = false, timestamp = DateTime.now().UnixTimestampMillis }
    end

    local position = getBusPosition(model, tagged)
    if isHighFloor == nil then
        isHighFloor = determineIsHighFloor(model, tagged, detectedPart)
    end
    local bellSystem = busBellSystems[model] or getOrCreateBusBellSystem(model)
    local isBellRinging = (bellSystem and bellSystem.isRinging == true) or false

    -- 삭제 요청이 일시 실패하더라도 탑승 중에는 다음 수집 주기에 다시 확인합니다.
    -- 예약한 차량이 아닌 다른 버스의 예약만 제거됩니다.
    cancelReservationsForDifferentBoardedBus(model)

    if model ~= lastBoardingReportedBus then
        lastBoardingReportedBus = model
        print(string.format("[버스 탑승 확인] 플레이어: %s -> 버스: %s (감지파트: %s, 하차벨: %s, 차종: %s)",
            player.Name,
            model.Name,
            detectedPart and detectedPart.Name or "차체내부",
            isBellRinging and "점등중" or "소등",
            isHighFloor and "고상" or "저상"
        ))
    end

    return {
        active = true,
        -- 즉시 하차는 실제 좌석·바닥·BUSin 접촉이 확인될 때만 허용합니다.
        canImmediateExit = boardingEvidence == "seat"
            or boardingEvidence == "floor"
            or boardingEvidence == "busin"
            or boardingEvidence == "boarding_part",
        boardingEvidence = boardingEvidence,
        mode = isHighFloor and "high" or "low",
        busId = model:GetFullName(),
        busName = model.Name,
        route = tostring(getFirstAttribute(model, { "route", "Route", "ROUTE" }, "")),
        vehicleNumber = getBusLicense(model),
        direction = getBusRouteDirection(model),
        isHighFloor = isHighFloor,
        isBellRinging = isBellRinging,
        x = round1(position.X),
        y = round1(position.Y),
        z = round1(position.Z),
        timestamp = DateTime.now().UnixTimestampMillis
    }
end

-- 실제 벨(마이크로파이썬)에서 Firebase로 올라온 이벤트를 초저지연(0.12초 주기)으로 감지하여 로블록스 버스에서 즉각 재생
local lastPhysicalBellEventId = nil
local isPollingPhysicalBell = false
local PHYSICAL_BELL_MAX_AGE_MS = 5_000
local lastPhysicalBellPollTime = 0
-- 0.25초면 버튼 체감 지연 없이 약 240회/분입니다. 이전 0.10초(600회/분)는
-- 지도·예약 요청과 합쳐 HttpService 제한을 초과해 연결이 불안정해질 수 있었습니다.
local PHYSICAL_BELL_POLL_INTERVAL = 0.25

local function pollPhysicalBellFast()
    local now = os.clock()
    if isPollingPhysicalBell or (now - lastPhysicalBellPollTime) < PHYSICAL_BELL_POLL_INTERVAL then
        return
    end
    lastPhysicalBellPollTime = now
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
            local source = typeof(event) == "table" and tostring(event.source or "") or ""
            if typeof(event) ~= "table" or (source ~= "physical" and source ~= "web_manual") then
                return
            end

            local receivedAt = tonumber(event.receivedAtMs) or tonumber(event.deviceTimestampMs)
            if not receivedAt or (DateTime.now().UnixTimestampMillis - receivedAt) > PHYSICAL_BELL_MAX_AGE_MS then
                return
            end

            local eventId = tostring(event.eventId or (tostring(receivedAt) .. ":" .. tostring(event.button)))
            if eventId == lastPhysicalBellEventId then
                return
            end
            lastPhysicalBellEventId = eventId

            local player = findTargetPlayer()
            local model = nil
            local boardingEvidence = nil
            if player then
                local detectedModel, detectedTag, detectedPart, detectedEvidence = findBusForPlayer(player)
                model = detectedModel
                boardingEvidence = detectedEvidence
            end
            local confirmedBoarding = boardingEvidence == "seat"
                or boardingEvidence == "floor"
                or boardingEvidence == "busin"
                or boardingEvidence == "boarding_part"
            if not confirmedBoarding then
                model = nil
            end
            if not model and player and lastBoardedBus and isTargetPlayersCurrentBus(lastBoardedBus.model) then
                model = lastBoardedBus.model
            end

            if model then
                local button = tostring(event.button or "A"):upper()
                local reason = source == "web_manual" and "WEB_MANUAL" or "PHYSICAL"
                triggerBusBell(model, nil, reason .. ": " .. button, true, button == "B" or button == "SPECIAL")
            else
                warn("[로블록스 레이더] 하차벨 이벤트를 받았지만 탑승 중인 BUS를 찾지 못했습니다.")
            end
        end)

        isPollingPhysicalBell = false
    end)
end

-- Roblox HTTP 요청 한도를 고려한 저지연 전담 폴러 (실제 GET은 0.25초마다)
task.spawn(function()
    while RunService:IsRunning() do
        pollPhysicalBellFast()
        task.wait(0.10)
    end
end)

-- 관리자 Shift+N 초기화 신호: 게임 내부의 하차벨/예약/탑승 캐시도 함께 초기화합니다.
task.spawn(function()
    local resetSignal = ReplicatedStorage:WaitForChild("AdminWorldResetSignal", 30)
    if not resetSignal or not resetSignal:IsA("BindableEvent") then
        return
    end

    resetSignal.Event:Connect(function()
        for busModel, _ in pairs(busBellSystems) do
            if busModel and busModel.Parent then
                resetBusBell(busModel, false)
            end
        end

        activeReservations = {}
        lastBoardedBus = nil
        lastPhysicalBellEventId = nil
        radarClearedForAbsentTarget = false
        print("[로블록스 레이더] 관리자 초기화 신호 수신 -> 벨/예약/탑승 상태 초기화")
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    if isConfiguredTargetPlayer(player) then
        clearLiveRadarData("PlayerRemoving: " .. player.Name)
    end
end)

task.spawn(function()
    while RunService:IsRunning() do
        if not isTargetPlayerConnected() then
            -- 이 서버가 대상 사용자 데이터를 전송한 적이 있을 때만 삭제합니다.
            -- 대상이 없는 다른 서버는 현재 시연 서버의 데이터를 건드리지 않습니다.
            clearLiveRadarData("target not connected")
        elseif not isSending then
            targetStreamOwnedByThisServer = true
            radarClearedForAbsentTarget = false
            -- 좌표/탑승 정보 수집 오류가 나도 전체 루프가 죽지 않도록 보호합니다.
            local collectSuccess, playersData, busesData, bellData = pcall(function()
                local bell = collectBellContext()
                local players = collectPlayersData()
                local buses = collectBusData()
                return players, buses, bell
            end)

            if not collectSuccess then
                warn("[로블록스 레이더] 데이터 수집 실패:", playersData)
            elseif #playersData == 0 then
                -- 대상 사용자의 캐릭터가 생성/리스폰 중인 짧은 구간에는 빈 사용자와
                -- 다른 버스·정류장으로 기존 정상 묶음을 덮어쓰지 않습니다.
            else
                local radarData = {
                    scriptVersion = RADAR_SCRIPT_VERSION,
                    serverSessionId = SERVER_SESSION_ID,
                    -- 수집된 첫 사용자나 DisplayName으로 소유자가 바뀌지 않도록
                    -- 서버 설정의 대상 Player.Name을 항상 그대로 기록합니다.
                    targetUserName = TARGET_ROBLOX_USER_NAME,
                    targetUserId = TARGET_ROBLOX_USER_ID,
                    players = playersData,
                    buses = busesData,
                    bell = bellData,
                    stops = collectStableMapStops(),
                    timestamp = DateTime.now().UnixTimestampMillis
                }

                isSending = true
                task.spawn(function()
                    local success, err = pcall(function()
                        local radarResponse = HttpService:RequestAsync({
                            Url = RADAR_ENDPOINT,
                            -- PUT은 /radar 전체를 교체하므로 웹이 저장한
                            -- /radar/reservations까지 매 전송마다 삭제합니다.
                            -- PATCH로 위치/벨 데이터만 갱신해 예약을 보존합니다.
                            Method = "PATCH",
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
