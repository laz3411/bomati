-- 정류장 안내 방송 서버 스크립트
-- 설치 위치: ServerScriptService > Script
--
-- Workspace 안의 "정류장 안내 방송" 폴더(StopAnnouncements/StopAnnouncement도 지원)에
-- Sound를 넣고 Sound의 StopId String Attribute를 정류장 StopId와 동일하게 지정합니다.
-- 버스는 BUS CollectionService 태그 또는 Route/route Attribute가 있는 Model을 사용합니다.

local CollectionService = game:GetService("CollectionService")

local ANNOUNCEMENT_FOLDER_NAMES = {
    ["정류장 안내 방송"] = true,
    ["StopAnnouncements"] = true,
    ["StopAnnouncement"] = true,
    ["StopAudio"] = true
}

local STOP_ID_ATTRIBUTES = { "StopId", "stopId", "StopID", "stopID", "StationId", "stationId", "정류장고유번호" }
local ROUTE_ATTRIBUTES = { "Route", "route", "Line", "line", "노선" }
local DIRECTION_ATTRIBUTES = { "RouteDirection", "routeDirection", "Direction", "direction", "운행방향", "방향" }
local ORDER_ATTRIBUTES = { "StopIndex", "stopIndex", "Index", "index", "Order", "order", "순번" }

-- 한 번에 인접 정류장까지 함께 "도착" 처리되지 않도록, 실제 도착에 가까운
-- 범위에서 현재 가장 가까운 정류장만 방송 후보로 판정합니다.
local ANNOUNCE_DISTANCE = 120
-- 서버 시작/버스 등록 직후 정류장 바로 옆에 있던 경우에는 그 한 정류장만
-- 이미 접근한 것으로 간주하여 시작 안내방송을 재생하지 않습니다.
local INITIAL_STOP_SUPPRESS_DISTANCE = 70
local SOUND_MAX_DISTANCE = 75
local SOUND_MIN_DISTANCE = 8
local SOUND_LOAD_TIMEOUT = 4
local SOUND_FALLBACK_TIMEOUT = 30
local UPDATE_INTERVAL = 0.5
local CACHE_REFRESH_INTERVAL = 2

local announcementFolder = nil
local announcementByStopId = {}
local routeStops = {}
local routeBusModels = {}
local cacheUpdatedAt = 0
local busStates = {}
local diagnosticsPrinted = false

local function firstAttribute(instance, names)
    if not instance then return nil end
    for _, name in ipairs(names) do
        local value = instance:GetAttribute(name)
        if value ~= nil then return value end
    end
    return nil
end

local function stringAttribute(instance, names)
    local value = firstAttribute(instance, names)
    if value == nil then return nil end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

local function normalizeStopId(value)
    local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return string.lower(text)
end

local function normalizeDirection(value)
    local text = string.lower(tostring(value or "")):gsub("%s+", "")
    if text == "up" or text == "upbound" or text == "상행" or text == "상" or text == "1" then return "up" end
    if text == "down" or text == "downbound" or text == "하행" or text == "하" or text == "2" then return "down" end
    return nil
end

local function getAnnouncementFolder()
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Folder") and ANNOUNCEMENT_FOLDER_NAMES[descendant.Name] then
            return descendant
        end
        if descendant:IsA("Folder") then
            local normalizedName = string.lower(descendant.Name):gsub("%s+", "")
            if normalizedName:find("정류장", 1, true) and normalizedName:find("방송", 1, true) then
                return descendant
            end
        end
    end
    return nil
end

local function getWorldPosition(instance)
    if instance:IsA("BasePart") then return instance.Position end
    if instance:IsA("Model") then return instance:GetPivot().Position end
    if instance:IsA("Attachment") then return instance.WorldPosition end
    if instance:IsA("Folder") then
        local part = instance:FindFirstChildWhichIsA("BasePart", true)
        return part and part.Position or nil
    end
    return nil
end

local function getBusModel(instance)
    local current = instance
    local candidate = nil
    while current and current ~= workspace do
        if current:IsA("Model") then
            if CollectionService:HasTag(current, "BUS") or firstAttribute(current, ROUTE_ATTRIBUTES) ~= nil then
                candidate = current
            end
        end
        current = current.Parent
    end
    return candidate
end

local function getBusEmitter(model)
    if model.PrimaryPart then return model.PrimaryPart end
    local seat = model:FindFirstChildWhichIsA("VehicleSeat", true)
    if seat then return seat end
    local namedDriveSeat = model:FindFirstChild("DriveSeat", true)
    if namedDriveSeat and namedDriveSeat:IsA("BasePart") then return namedDriveSeat end
    return model:FindFirstChildWhichIsA("BasePart", true)
end

local function getBusRoute(model)
    local route = stringAttribute(model, ROUTE_ATTRIBUTES)
    if route then return route end
    local number = string.match(model.Name, "%d+")
    return number
end

local function getBusDirection(model)
    return normalizeDirection(stringAttribute(model, DIRECTION_ATTRIBUTES))
end

local function getStopRoute(instance)
    local route = stringAttribute(instance, ROUTE_ATTRIBUTES)
    if route then return route end
    local current = instance.Parent
    while current and current ~= workspace do
        local ancestorRoute = stringAttribute(current, ROUTE_ATTRIBUTES)
        if ancestorRoute then return ancestorRoute end
        local number = string.match(current.Name, "^%s*(%d+)%s*")
        if number then return number end
        current = current.Parent
    end
    return nil
end

local function getStopDirection(instance)
    local direction = normalizeDirection(stringAttribute(instance, DIRECTION_ATTRIBUTES))
    if direction then return direction end
    local current = instance.Parent
    while current and current ~= workspace do
        direction = normalizeDirection(stringAttribute(current, DIRECTION_ATTRIBUTES))
        if direction then return direction end
        current = current.Parent
    end
    return nil
end

local function getStopOrder(instance)
    local order = tonumber(firstAttribute(instance, ORDER_ATTRIBUTES))
    if order then return order end
    local number = tonumber(string.match(instance.Name, "^%s*(%d+)%s*$"))
    return number or math.huge
end

local function refreshCaches()
    announcementFolder = getAnnouncementFolder()
    announcementByStopId = {}
    if announcementFolder then
        for _, descendant in ipairs(announcementFolder:GetDescendants()) do
            if descendant:IsA("Sound") then
                local stopId = stringAttribute(descendant, STOP_ID_ATTRIBUTES)
                    or stringAttribute(descendant.Parent, STOP_ID_ATTRIBUTES)
                if stopId then
                    announcementByStopId[normalizeStopId(stopId)] = descendant
                end
            end
        end
    end

    routeStops = {}
    routeBusModels = {}
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Model")
            and (firstAttribute(descendant, ROUTE_ATTRIBUTES) ~= nil
                or descendant:FindFirstChildWhichIsA("VehicleSeat", true) ~= nil
                or descendant:FindFirstChild("DriveSeat", true) ~= nil) then
            routeBusModels[descendant] = true
        end
        if not (announcementFolder and descendant:IsDescendantOf(announcementFolder)) then
            local stopId = stringAttribute(descendant, STOP_ID_ATTRIBUTES)
            local position = getWorldPosition(descendant)
            if stopId and position and (descendant:IsA("BasePart") or descendant:IsA("Model") or descendant:IsA("Attachment") or descendant:IsA("Folder")) then
                local key = stopId .. "|" .. tostring(math.floor(position.X * 10)) .. "|" .. tostring(math.floor(position.Z * 10))
                local route = getStopRoute(descendant)
                local direction = getStopDirection(descendant) or "both"
                local bucketKey = tostring(route or "*") .. "|" .. tostring(direction or "both")
                routeStops[bucketKey] = routeStops[bucketKey] or {}
                local alreadyAdded = false
                for _, existing in ipairs(routeStops[bucketKey]) do
                    if existing.key == key then alreadyAdded = true break end
                end
                if not alreadyAdded then
                    table.insert(routeStops[bucketKey], {
                        id = normalizeStopId(stopId),
                        position = position,
                        order = getStopOrder(descendant),
                        route = route,
                        direction = direction,
                        key = key
                    })
                end
            end
        end
    end
    for _, stops in pairs(routeStops) do
        table.sort(stops, function(first, second) return first.order < second.order end)
        for index, stop in ipairs(stops) do
            if stop.order == math.huge then stop.order = index end
        end
    end
    if not diagnosticsPrinted then
        local soundCount = 0
        for _ in pairs(announcementByStopId) do soundCount += 1 end
        local stopCount = 0
        for _, stops in pairs(routeStops) do stopCount += #stops end
        if not announcementFolder then
            warn('[정류장 안내 방송] Workspace에서 안내 방송 폴더를 찾지 못했습니다. 폴더명을 확인하세요.')
        elseif soundCount == 0 then
            warn('[정류장 안내 방송] StopId String Attribute가 있는 Sound를 찾지 못했습니다.')
        end
        if stopCount == 0 then
            warn('[정류장 안내 방송] StopId String Attribute가 있는 정류장을 찾지 못했습니다.')
        end
        print(string.format('[정류장 안내 방송] 오디오 %d개 / 정류장 %d개를 인식했습니다.', soundCount, stopCount))
        diagnosticsPrinted = true
    end
    cacheUpdatedAt = os.clock()
end

local function getStopsForBus(route, direction)
    local result = {}
    local seenByLocation = {}
    local SAME_STOP_DISTANCE = 10
    for _, stops in pairs(routeStops) do
        for _, stop in ipairs(stops) do
            -- 안내방송은 노선/방향이 아니라 StopId로 연결합니다. 여러 노선이
            -- 같은 정류장 ID를 공유할 수 있으므로 모든 노선의 Part를 후보로 합칩니다.
            local idKey = tostring(stop.id)
            local duplicate = false
            for _, existing in ipairs(seenByLocation[idKey] or {}) do
                if (existing.position - stop.position).Magnitude <= SAME_STOP_DISTANCE then
                    duplicate = true
                    if stop.order < existing.order then existing.order = stop.order end
                    break
                end
            end
            if not duplicate then
                seenByLocation[idKey] = seenByLocation[idKey] or {}
                table.insert(seenByLocation[idKey], stop)
                table.insert(result, stop)
            end
        end
    end
    table.sort(result, function(first, second) return first.order < second.order end)
    return result
end

local function playAnnouncement(model, sourceSound, stopId)
    local emitter = getBusEmitter(model)
    if not emitter or not sourceSound or sourceSound.SoundId == "" then
        warn(string.format('[정류장 안내 방송] 재생 대상 누락: 버스=%s 정류장=%s', model.Name, tostring(stopId)))
        return
    end
    local state = busStates[model]
    if state and state.activeSound then
        state.activeSound:Stop()
        state.activeSound:Destroy()
        state.activeSound = nil
        state.activeSoundExpiresAt = nil
    end

    local sound = sourceSound:Clone()
    sound.Name = "StopAnnouncement_" .. tostring(stopId)
    sound.Looped = false
    sound.Volume = math.clamp(sourceSound.Volume > 0 and sourceSound.Volume or 0.95, 0, 1)
    sound.RollOffMode = Enum.RollOffMode.InverseTapered
    sound.RollOffMinDistance = SOUND_MIN_DISTANCE
    sound.RollOffMaxDistance = SOUND_MAX_DISTANCE
    sound.EmitterSize = 4
    sound.Parent = emitter
    state.activeSound = sound
    state.activeSoundExpiresAt = os.clock() + SOUND_LOAD_TIMEOUT
    task.spawn(function()
        local deadline = os.clock() + SOUND_LOAD_TIMEOUT
        while sound.Parent and not sound.IsLoaded and os.clock() < deadline do
            task.wait(0.1)
        end
        if not sound.Parent then return end
        if not sound.IsLoaded then
            warn(string.format('[정류장 안내 방송] Sound 에셋 로드 실패: StopId=%s SoundId=%s', tostring(stopId), tostring(sound.SoundId)))
            sound:Destroy()
            if state.activeSound == sound then
                state.activeSound = nil
                state.activeSoundExpiresAt = nil
            end
            return
        end
        sound.TimePosition = 0
        sound:Play()
        -- Ended 이벤트가 누락되어도 이후 정류장 방송이 영구히 막히지 않도록
        -- 실제 길이보다 여유를 둔 만료 시각을 함께 기록합니다.
        local duration = sound.TimeLength
        if duration <= 0 then duration = SOUND_FALLBACK_TIMEOUT - SOUND_LOAD_TIMEOUT end
        state.activeSoundExpiresAt = os.clock() + math.clamp(duration + 2, 3, SOUND_FALLBACK_TIMEOUT)
        print(string.format('[정류장 안내 방송] 재생: 버스=%s StopId=%s', model.Name, tostring(stopId)))
    end)
    sound.Ended:Connect(function()
        if sound.Parent then sound:Destroy() end
        if state.activeSound == sound then
            state.activeSound = nil
            state.activeSoundExpiresAt = nil
        end
    end)
end

local function updateBus(model)
    if not model:IsDescendantOf(workspace) then return end
    local emitter = getBusEmitter(model)
    local position = emitter and emitter.Position
    if not position then return end

    local route = getBusRoute(model)
    local direction = getBusDirection(model)
    local state = busStates[model]
    local routeKey = tostring(route or "*") .. "|" .. tostring(direction or "") .. "|" .. tostring(model:GetAttribute("RouteDirectionStartedAt") or "")
	if not state or state.routeKey ~= routeKey then
		state = {
			routeKey = routeKey,
			insideStops = {},
			initialSuppressedStopKey = nil,
			initialized = false,
			missingSoundLogged = {},
			pendingStops = {},
			pendingStopKeys = {},
			activeSound = nil,
			activeSoundExpiresAt = nil,
		}
		busStates[model] = state
	end

	local stops = getStopsForBus(route, direction)
	if not state.initialized then
		local initialStop = nil
		local initialDistance = math.huge
		for _, stop in ipairs(stops) do
			local distance = (stop.position - position).Magnitude
			if distance < initialDistance then
				initialStop = stop
				initialDistance = distance
			end
		end
		if initialStop and initialDistance <= INITIAL_STOP_SUPPRESS_DISTANCE then
			state.initialSuppressedStopKey = initialStop.key
			state.insideStops[initialStop.key] = true
			print(string.format('[정류장 안내 방송] 시작 위치와 가까운 StopId=%s 안내방송은 이번 1회만 건너뜁니다.', tostring(initialStop.id)))
		end
		state.initialized = true
	end

	-- 반경을 벗어난 정류장은 다음 접근 때 다시 방송할 수 있도록 재무장합니다.
	for _, stop in ipairs(stops) do
		if (stop.position - position).Magnitude > ANNOUNCE_DISTANCE then
			state.insideStops[stop.key] = false
		end
	end

	-- 여러 정류장이 가까이 있어도 현재 버스와 가장 가까운 한 곳만 처리합니다.
	-- 이 규칙 때문에 001 근처에서 002가 미리 "처리됨" 상태가 되지 않습니다.
	local nearestStop = nil
	local nearestDistance = math.huge
	for _, stop in ipairs(stops) do
		local distance = (stop.position - position).Magnitude
		if distance < nearestDistance then
			nearestStop = stop
			nearestDistance = distance
		end
	end

	if nearestStop and nearestDistance <= ANNOUNCE_DISTANCE then
		if state.initialSuppressedStopKey == nearestStop.key then
			state.insideStops[nearestStop.key] = true
		elseif not state.insideStops[nearestStop.key] and not state.pendingStopKeys[nearestStop.key] then
			state.pendingStopKeys[nearestStop.key] = true
			table.insert(state.pendingStops, { stop = nearestStop, enteredDistance = nearestDistance })
			state.insideStops[nearestStop.key] = true
		end
	end

	if state.initialSuppressedStopKey and not state.insideStops[state.initialSuppressedStopKey] then
		state.initialSuppressedStopKey = nil
	end

	-- Sound가 로드/재생 중이면 대기하되, Ended 이벤트가 오지 않는 에셋도
	-- 만료 시각 이후 정리하여 이후 정류장 안내를 막지 않게 합니다.
	if state.activeSound and state.activeSound.Parent then
		if os.clock() < (state.activeSoundExpiresAt or 0) then return end
		warn(string.format('[정류장 안내 방송] 재생 종료 신호 시간 초과: 버스=%s. 다음 방송을 계속합니다.', model.Name))
		state.activeSound:Stop()
		state.activeSound:Destroy()
		state.activeSound = nil
		state.activeSoundExpiresAt = nil
	end

	while #state.pendingStops > 0 do
		table.sort(state.pendingStops, function(first, second)
			return first.enteredDistance < second.enteredDistance
		end)
		local candidate = table.remove(state.pendingStops, 1)
		local stop = candidate.stop
		state.pendingStopKeys[stop.key] = nil

		local sourceSound = announcementByStopId[normalizeStopId(stop.id)]
		if sourceSound then
			print(string.format('[정류장 안내 방송] 접근 감지: 버스=%s StopId=%s 거리=%.1f', model.Name, tostring(stop.id), candidate.enteredDistance))
			playAnnouncement(model, sourceSound, stop.id)
			return
		end

		if not state.missingSoundLogged[stop.key] then
			state.missingSoundLogged[stop.key] = true
			warn(string.format('[정류장 안내 방송] StopId=%s에 대응하는 Sound가 없습니다.', tostring(stop.id)))
		end
	end
end

while true do
    if os.clock() - cacheUpdatedAt >= CACHE_REFRESH_INTERVAL then refreshCaches() end
    local liveModels = {}
    for _, tagged in ipairs(CollectionService:GetTagged("BUS")) do
        local model = getBusModel(tagged) or (tagged:IsA("Model") and tagged or nil)
        if model then liveModels[model] = true end
    end
    for model in pairs(routeBusModels) do
        if model:IsDescendantOf(workspace) then
            liveModels[model] = true
        end
    end
    for model in pairs(liveModels) do updateBus(model) end
    for model, state in pairs(busStates) do
        if not liveModels[model] then
            if state.activeSound then state.activeSound:Stop(); state.activeSound:Destroy() end
            busStates[model] = nil
        end
    end
    task.wait(UPDATE_INTERVAL)
end
