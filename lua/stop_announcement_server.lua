--[[
    접촉식 정류장 안내 방송 서버 스크립트

    설치 위치: ServerScriptService > Script

    설정 방법:
    1. 정류장 트리거 BasePart에 StopId 또는 stopID Attribute를 지정합니다.
       예: "001", "002", "003"
    2. Sound에도 같은 StopId Attribute를 지정합니다.
       예: Sound.StopId = "001"
    3. Sound는 Workspace, SoundService, ReplicatedStorage, ServerStorage 중
       어디에 있어도 검색합니다.

    버스는 BUS CollectionService 태그가 붙은 Model 또는 그 안의 기준 Part만
    인식합니다. VehicleSeat, Route, SpawnedBus 속성만 있는 탈것은 제외합니다.
--]]

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local STOP_ID_ATTRIBUTES = {
    "StopId", "stopId", "StopID", "stopID",
    "StationId", "stationId", "정류장고유번호", "정류장번호"
}

local TRIGGER_NAME_HINTS = { "trigger", "touch", "stop", "정류장" }

local PREVIEW_SOUND_PREFIX = "StopAnnouncement_"
-- 버스 실내 길이 정도까지는 충분한 음량을 유지하고, 차 밖에서는 거리와 함께
-- 빠르게 줄어들게 합니다. 원본 Sound의 Volume이 작아도 아래 최소 음량을 보장합니다.
local SOUND_MIN_DISTANCE = 28
local SOUND_MAX_DISTANCE = 120
local SOUND_VOLUME_MINIMUM = 2.5
local SOUND_VOLUME_DEFAULT = 0.95
local SOUND_LOAD_TIMEOUT = 8
local CONTACT_REARM_DELAY = 0.75
local SCAN_INTERVAL = 0.25
local CACHE_LOG_INTERVAL = 3

local announcementByStopId = {}
local triggerParts = {} -- [BasePart] = normalized stopId
local connectedTriggerParts = {}
local busStates = {} -- [busModel] = { triggered, lastContactAt, activeSound, activeEmitter }
local announcementEmitterFolder = nil
local lastCacheLogAt = 0
local previousSoundCount = -1
local previousTriggerCount = -1

local function firstAttribute(instance, names)
    if not instance then return nil end
    for _, name in ipairs(names) do
        local value = instance:GetAttribute(name)
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function normalizeStopId(value)
    local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end

    -- 1, 01, 001을 모두 001로 맞춥니다.
    if text:match("^%d+$") then
        local number = tonumber(text)
        if number then
            return string.format("%03d", number)
        end
    end
    return string.lower(text)
end

local function getDirectStopId(instance)
    return normalizeStopId(firstAttribute(instance, STOP_ID_ATTRIBUTES))
end

local function hasTriggerNameHint(name)
    local lowerName = string.lower(name or "")
    for _, hint in ipairs(TRIGGER_NAME_HINTS) do
        if string.find(lowerName, hint, 1, true) then
            return true
        end
    end
    return false
end

local function getTriggerStopId(part)
    local directId = getDirectStopId(part)
    if directId then
        return directId
    end

    -- StopId가 상위 Model에 붙은 경우에는 PrimaryPart 또는 Trigger 이름의
    -- 파트만 트리거로 사용하여 모델의 모든 파트가 중복 연결되지 않게 합니다.
    local parent = part.Parent
    if parent and parent:IsA("Model") then
        local parentId = getDirectStopId(parent)
        if parentId and (parent.PrimaryPart == part or hasTriggerNameHint(part.Name)) then
            return parentId
        end
    end

    return nil
end

local function getBusModel(instance)
    local current = instance
    local taggedModel = nil
    while current and current ~= workspace do
        if CollectionService:HasTag(current, "BUS") then
            if current:IsA("Model") then
                -- 중첩 모델에 BUS 태그가 여러 개 있으면 가장 바깥쪽 태그 모델을 사용합니다.
                taggedModel = current
            elseif current:IsA("BasePart") then
                -- 기준 Part에 BUS 태그를 붙인 기존 차량도 지원합니다.
                local ownerModel = current:FindFirstAncestorOfClass("Model")
                if ownerModel then
                    taggedModel = ownerModel
                end
            end
        end
        current = current.Parent
    end
    return taggedModel
end

local function getBusEmitter(model)
    -- PrimaryPart보다 실제 운전석을 우선합니다. 버스 모델마다 운전석 이름이
    -- 달라도 DriveSeat/DriverSeat/운전석 또는 VehicleSeat를 모두 지원합니다.
    for _, name in ipairs({ "DriveSeat", "DriverSeat", "운전석" }) do
        local seat = model:FindFirstChild(name, true)
        if seat and seat:IsA("BasePart") then
            return seat
        end
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("VehicleSeat") then
            local seatName = string.lower(descendant.Name)
            if string.find(seatName, "drive", 1, true) or string.find(seatName, "driver", 1, true) then
                return descendant
            end
        end
    end

    local vehicleSeat = model:FindFirstChildWhichIsA("VehicleSeat", true)
    if vehicleSeat then return vehicleSeat end
    return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function normalizeSoundId(value)
    local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "" end
    if text:match("^%d+$") then
        return "rbxassetid://" .. text
    end
    return text
end

local function registerSound(instance)
    if not instance:IsA("Sound") then return end
    if string.sub(instance.Name, 1, #PREVIEW_SOUND_PREFIX) == PREVIEW_SOUND_PREFIX then
        return
    end

    local stopId = getDirectStopId(instance)
    if not stopId and instance.Parent then
        stopId = getDirectStopId(instance.Parent)
    end
    if stopId and normalizeSoundId(instance.SoundId) ~= "" then
        announcementByStopId[stopId] = instance
    end
end

local function refreshSoundCache()
    announcementByStopId = {}
    local roots = { workspace, SoundService, ReplicatedStorage, ServerStorage }
    for _, root in ipairs(roots) do
        for _, descendant in ipairs(root:GetDescendants()) do
            registerSound(descendant)
        end
    end
end

local function getBusState(busModel)
    local state = busStates[busModel]
    if not state then
        state = {
            triggered = {},
            lastContactAt = {},
            activeSound = nil,
            activeEmitter = nil,
        }
        busStates[busModel] = state
    end
    return state
end

local function getAnnouncementEmitterFolder()
    if announcementEmitterFolder and announcementEmitterFolder.Parent then
        return announcementEmitterFolder
    end

    announcementEmitterFolder = workspace:FindFirstChild("StopAnnouncementEmitters")
    if not announcementEmitterFolder then
        announcementEmitterFolder = Instance.new("Folder")
        announcementEmitterFolder.Name = "StopAnnouncementEmitters"
        announcementEmitterFolder.Parent = workspace
    end
    return announcementEmitterFolder
end

local function createAnnouncementEmitter(busModel, stopId)
    local busEmitter = getBusEmitter(busModel)
    if not busEmitter then return nil end

    -- 기존 차량 효과음 스크립트와 분리하기 위해 Workspace에 두되, 운전석과
    -- WeldConstraint로 연결해 차량을 따라 움직이는 3D 발신점으로 만듭니다.
    local emitter = Instance.new("Part")
    emitter.Name = "StopAnnouncementEmitter_" .. tostring(stopId)
    emitter.Size = Vector3.new(1, 1, 1)
    emitter.CFrame = busEmitter.CFrame
    emitter.Transparency = 1
    emitter.Anchored = false
    emitter.Massless = true
    emitter.CanCollide = false
    emitter.CanTouch = false
    emitter.CanQuery = false
    emitter.CastShadow = false
    emitter.Parent = getAnnouncementEmitterFolder()

    local weld = Instance.new("WeldConstraint")
    weld.Name = "FollowDriverSeat"
    weld.Part0 = emitter
    weld.Part1 = busEmitter
    weld.Parent = emitter
    return emitter
end

local function playAnnouncement(busModel, sourceSound, stopId)
    local emitter = getBusEmitter(busModel)
    local sourceSoundId = sourceSound and normalizeSoundId(sourceSound.SoundId) or ""
    if not emitter or not sourceSound or sourceSoundId == "" then
        warn(string.format("[정류장 안내 방송] 재생 대상 누락: 버스=%s StopId=%s", busModel.Name, tostring(stopId)))
        return
    end

    local state = getBusState(busModel)
    if state.activeSound and state.activeSound.Parent then
        state.activeSound:Stop()
        state.activeSound:Destroy()
        state.activeSound = nil
    end
    if state.activeEmitter and state.activeEmitter.Parent then
        state.activeEmitter:Destroy()
        state.activeEmitter = nil
    end

    local sound = sourceSound:Clone()
    sound.Name = PREVIEW_SOUND_PREFIX .. tostring(stopId)
    sound.SoundId = sourceSoundId
    sound.Looped = false
    sound.TimePosition = 0
    local requestedVolume = sourceSound.Volume > 0 and sourceSound.Volume or SOUND_VOLUME_DEFAULT
    sound.Volume = math.clamp(math.max(requestedVolume, SOUND_VOLUME_MINIMUM), 0, 4)
    -- 원본이 조용한 SoundGroup에 묶여 있더라도 안내방송 복제본에는 적용하지 않습니다.
    sound.SoundGroup = nil
    sound.RollOffMode = Enum.RollOffMode.InverseTapered
    sound.RollOffMinDistance = SOUND_MIN_DISTANCE
    sound.RollOffMaxDistance = SOUND_MAX_DISTANCE
    sound.EmitterSize = 4
    local announcementEmitter = createAnnouncementEmitter(busModel, stopId)
    if not announcementEmitter then
        warn(string.format("[정류장 안내 방송] 월드 재생 위치 생성 실패: 버스=%s StopId=%s", busModel.Name, tostring(stopId)))
        sound:Destroy()
        return
    end
    sound.Parent = announcementEmitter
    state.activeSound = sound
    state.activeEmitter = announcementEmitter

    sound.Ended:Connect(function()
        if sound.Parent then
            sound:Destroy()
        end
        if state.activeSound == sound then
            state.activeSound = nil
        end
        if state.activeEmitter == announcementEmitter then
            announcementEmitter:Destroy()
            state.activeEmitter = nil
        end
    end)

    task.spawn(function()
        local preloadSuccess, preloadError = pcall(function()
            ContentProvider:PreloadAsync({ sound })
        end)
        local deadline = os.clock() + SOUND_LOAD_TIMEOUT
        while sound.Parent and not sound.IsLoaded and os.clock() < deadline do
            task.wait(0.1)
        end

        if not sound.Parent then return end
        if not sound.IsLoaded then
            warn(string.format(
                "[정류장 안내 방송] 오디오 로드 실패: StopId=%s SoundId=%s loaded=%s preload=%s error=%s",
                tostring(stopId), tostring(sourceSoundId), tostring(sound.IsLoaded), tostring(preloadSuccess), tostring(preloadError)
            ))
            sound:Destroy()
            if state.activeSound == sound then
                state.activeSound = nil
            end
            if state.activeEmitter == announcementEmitter then
                announcementEmitter:Destroy()
                state.activeEmitter = nil
            end
            return
        end

        sound.TimePosition = 0
        sound:Play()
        if not sound.IsPlaying then
            warn(string.format("[정류장 안내 방송] Play 호출 후에도 재생되지 않음: StopId=%s SoundId=%s", tostring(stopId), tostring(sourceSoundId)))
        else
            print(string.format(
                "[정류장 안내 방송] 재생: 버스=%s StopId=%s 운전석=%s 음량=%.2f 감쇠=%d~%d SoundId=%s",
                busModel.Name,
                tostring(stopId),
                emitter:GetFullName(),
                sound.Volume,
                SOUND_MIN_DISTANCE,
                SOUND_MAX_DISTANCE,
                tostring(sourceSoundId)
            ))
        end
    end)
end

local function markBusContact(triggerPart, otherPart)
    if not otherPart or not otherPart:IsA("BasePart") then return end
    local busModel = getBusModel(otherPart)
    if not busModel then return end

    local stopId = triggerParts[triggerPart]
    if not stopId then return end

    local state = getBusState(busModel)
    state.lastContactAt[stopId] = os.clock()

    if state.triggered[stopId] then
        return
    end

    local sourceSound = announcementByStopId[stopId]
    if not sourceSound then
        warn(string.format("[정류장 안내 방송] StopId=%s에 대응하는 Sound가 없습니다.", tostring(stopId)))
        state.triggered[stopId] = true
        return
    end

    state.triggered[stopId] = true
    playAnnouncement(busModel, sourceSound, stopId)
end

local function registerTriggerPart(part)
    if not part:IsA("BasePart") then return end

    local stopId = getTriggerStopId(part)
    if not stopId then return end
    triggerParts[part] = stopId

    -- CanTouch=false인 트리거도 접촉 감지가 되도록 보장합니다.
    pcall(function() part.CanTouch = true end)
    pcall(function() part.CanQuery = true end)

    if connectedTriggerParts[part] then return end
    connectedTriggerParts[part] = true

    part.Touched:Connect(function(otherPart)
        markBusContact(part, otherPart)
    end)
end

local function refreshTriggerCache()
    for _, descendant in ipairs(workspace:GetDescendants()) do
        registerTriggerPart(descendant)
    end
end

local function scanTriggerOverlaps()
    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude

    for part, _ in pairs(triggerParts) do
        if part and part.Parent then
            local success, touchingParts = pcall(function()
                return workspace:GetPartsInPart(part, overlapParams)
            end)
            if success and touchingParts then
                for _, otherPart in ipairs(touchingParts) do
                    markBusContact(part, otherPart)
                end
            end
        else
            triggerParts[part] = nil
            connectedTriggerParts[part] = nil
        end
    end
end

local function updateStates()
    local now = os.clock()
    for busModel, state in pairs(busStates) do
        if not busModel or not busModel:IsDescendantOf(workspace) then
            if state.activeSound then
                state.activeSound:Stop()
                state.activeSound:Destroy()
            end
            if state.activeEmitter then
                state.activeEmitter:Destroy()
            end
            busStates[busModel] = nil
        else
            for stopId, lastContactAt in pairs(state.lastContactAt) do
                if now - lastContactAt >= CONTACT_REARM_DELAY then
                    state.lastContactAt[stopId] = nil
                    state.triggered[stopId] = nil
                end
            end
        end
    end
end

workspace.DescendantAdded:Connect(function(descendant)
    registerTriggerPart(descendant)
    registerSound(descendant)
end)

refreshSoundCache()
refreshTriggerCache()

local soundCount = 0
for _ in pairs(announcementByStopId) do soundCount += 1 end
local triggerCount = 0
for _ in pairs(triggerParts) do triggerCount += 1 end
print(string.format("[정류장 안내 방송] 접촉식 모드 활성화: 오디오 %d개 / 트리거 파트 %d개", soundCount, triggerCount))

while true do
    scanTriggerOverlaps()
    updateStates()

    if os.clock() - lastCacheLogAt >= CACHE_LOG_INTERVAL then
        refreshSoundCache()
        refreshTriggerCache()

        local currentSoundCount = 0
        for _ in pairs(announcementByStopId) do currentSoundCount += 1 end
        local currentTriggerCount = 0
        for _ in pairs(triggerParts) do currentTriggerCount += 1 end
        if currentSoundCount ~= previousSoundCount or currentTriggerCount ~= previousTriggerCount then
            print(string.format("[정류장 안내 방송] 인식 상태: 오디오 %d개 / 트리거 파트 %d개", currentSoundCount, currentTriggerCount))
            previousSoundCount = currentSoundCount
            previousTriggerCount = currentTriggerCount
        end
        lastCacheLogAt = os.clock()
    end

    task.wait(SCAN_INTERVAL)
end
