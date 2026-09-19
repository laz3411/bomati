--[[
    관리자 비행/투명화 서버 스크립트

    설치 위치: ServerScriptService
    관리자 여부와 투명화는 서버에서 검증합니다.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

-- 현재 프로젝트의 기존 대상 계정을 기본 관리자로 등록합니다.
-- 이름은 바뀔 수 있으므로, 실제 운영 전에는 UserId를 ADMIN_USER_IDS에 넣는 것을 권장합니다.
local ADMIN_USER_IDS = {
	[123456789] = true,
	[1463187453] = true,
	[1883086963] = true,
}

local ADMIN_USER_NAMES = {
	["laz3411"] = true,
	["beargobearman"] = true,
}

local CHECK_REMOTE_NAME = "AdminAbilityCheck"
local APPEARANCE_REMOTE_NAME = "AdminAppearanceRequest"
local RESET_REMOTE_NAME = "AdminWorldReset"
local RESET_SIGNAL_NAME = "AdminWorldResetSignal"
local FIREBASE_DATABASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"

local checkRemote = ReplicatedStorage:FindFirstChild(CHECK_REMOTE_NAME)
if not checkRemote then
	checkRemote = Instance.new("RemoteFunction")
	checkRemote.Name = CHECK_REMOTE_NAME
	checkRemote.Parent = ReplicatedStorage
end

local appearanceRemote = ReplicatedStorage:FindFirstChild(APPEARANCE_REMOTE_NAME)
if not appearanceRemote then
	appearanceRemote = Instance.new("RemoteEvent")
	appearanceRemote.Name = APPEARANCE_REMOTE_NAME
	appearanceRemote.Parent = ReplicatedStorage
end

local resetRemote = ReplicatedStorage:FindFirstChild(RESET_REMOTE_NAME)
if not resetRemote then
	resetRemote = Instance.new("RemoteEvent")
	resetRemote.Name = RESET_REMOTE_NAME
	resetRemote.Parent = ReplicatedStorage
end

local resetSignal = ReplicatedStorage:FindFirstChild(RESET_SIGNAL_NAME)
if not resetSignal then
	resetSignal = Instance.new("BindableEvent")
	resetSignal.Name = RESET_SIGNAL_NAME
	resetSignal.Parent = ReplicatedStorage
end

local invisiblePlayers = {}
local originalAppearance = {}
local lastResetAt = {}

local function isAdmin(player)
	return ADMIN_USER_IDS[player.UserId] == true
		or ADMIN_USER_NAMES[player.Name:lower()] == true
end

checkRemote.OnServerInvoke = function(player)
	return isAdmin(player)
end

local function saveAndHide(instance, saved)
	if instance:IsA("BasePart") then
		saved[instance] = { kind = "BasePart", value = instance.Transparency }
		instance.Transparency = 1
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		saved[instance] = { kind = "Image", value = instance.Transparency }
		instance.Transparency = 1
	elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") then
		saved[instance] = { kind = "Enabled", value = instance.Enabled }
		instance.Enabled = false
	elseif instance:IsA("BillboardGui") or instance:IsA("SurfaceGui") then
		saved[instance] = { kind = "Enabled", value = instance.Enabled }
		instance.Enabled = false
	elseif instance:IsA("Highlight") then
		saved[instance] = { kind = "Enabled", value = instance.Enabled }
		instance.Enabled = false
	end
end

local function setInvisible(player, invisible)
	local character = player.Character
	if not character then
		return
	end

	if invisible then
		local saved = {}
		for _, descendant in ipairs(character:GetDescendants()) do
			saveAndHide(descendant, saved)
		end
		originalAppearance[player] = saved
		invisiblePlayers[player] = true
	else
		local saved = originalAppearance[player]
		if saved then
			for instance, state in pairs(saved) do
				if instance and instance.Parent then
					if state.kind == "BasePart" or state.kind == "Image" then
						instance.Transparency = state.value
					elseif state.kind == "Enabled" then
						instance.Enabled = state.value
					end
				end
			end
		end
		originalAppearance[player] = nil
		invisiblePlayers[player] = nil
	end
end

appearanceRemote.OnServerEvent:Connect(function(player, requestedInvisible)
	if not isAdmin(player) or type(requestedInvisible) ~= "boolean" then
		return
	end

	setInvisible(player, requestedInvisible)
end)

local function deleteFirebasePath(path)
	local response = HttpService:RequestAsync({
		Url = FIREBASE_DATABASE_URL .. path,
		Method = "DELETE",
	})
	if not response.Success then
		error(path .. " 삭제 실패: " .. tostring(response.StatusMessage))
	end
end

local function publishBellReset()
	local timestamp = DateTime.now().UnixTimestampMillis
	local response = HttpService:RequestAsync({
		Url = FIREBASE_DATABASE_URL .. "/bell/latest.json",
		Method = "PUT",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode({
			type = "bell_reset",
			source = "admin_reset",
			button = "RESET",
			eventId = "admin-reset-" .. tostring(timestamp),
			receivedAtMs = timestamp,
			deviceTimestampMs = timestamp,
		}),
	})
	if not response.Success then
		error("/bell/latest 초기화 신호 실패: " .. tostring(response.StatusMessage))
	end
end

local function isLegacySpawnedWheelchair(model)
	return string.sub(model.Name, -11) == "_Wheelchair"
		and model:FindFirstChildWhichIsA("VehicleSeat", true) ~= nil
end

local function isResettableDynamicModel(model)
	return model:GetAttribute("SpawnedBus") == true
		or model:GetAttribute("SpawnedWheelchair") == true
		or model:GetAttribute("AdminResettable") == true
		or CollectionService:HasTag(model, "ADMIN_RESETTABLE")
		-- 기존에 이미 소환돼 Attribute가 없는 휠체어도 이번 초기화에서 정리합니다.
		or isLegacySpawnedWheelchair(model)
end

local function releaseVehicleOccupants(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("VehicleSeat") and descendant.Occupant then
			descendant.Occupant.Sit = false
		end
	end
end

local function clearDynamicWorldObjects()
	local targets = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("Model") and isResettableDynamicModel(descendant) then
			table.insert(targets, descendant)
		end
	end

	for _, model in ipairs(targets) do
		if model.Parent then
			releaseVehicleOccupants(model)
			model:Destroy()
		end
	end

	-- 정류장 안내방송이 재생 중이었다면 남아 있는 임시 발신점과 Sound도 제거합니다.
	local emitters = workspace:FindFirstChild("StopAnnouncementEmitters")
	if emitters then
		emitters:Destroy()
	end
end

local function resetWorld(player)
	local now = os.clock()
	if now - (lastResetAt[player] or 0) < 3 then
		return
	end
	lastResetAt[player] = now

	-- 소환 시스템이 만든 버스·휠체어 등만 삭제하고, 맵에 원래 배치된 버스는 보존합니다.
	clearDynamicWorldObjects()

	-- 레이더/하차벨 스크립트가 보유한 게임 내 벨 상태와 예약 캐시를 초기화합니다.
	resetSignal:Fire()

	-- 캐릭터, 위치, 체력, 캐릭터에 붙은 임시 상태를 Roblox 기본 스폰 상태로 되돌립니다.
	for _, target in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			pcall(function()
				target:LoadCharacter()
			end)
		end)
	end

	-- Firebase의 라이브 위치/예약/벨 상태와 벨 이력을 모두 지웁니다.
	task.spawn(function()
		local success, err = pcall(function()
			publishBellReset()
			deleteFirebasePath("/radar.json")
			deleteFirebasePath("/radar/reservations.json")
			deleteFirebasePath("/bell/events.json")

			-- 브리지가 RESET 명령을 받을 시간을 확보한 뒤 최신 벨 노드도 제거합니다.
			task.delay(5, function()
				pcall(function()
					deleteFirebasePath("/bell/latest.json")
				end)
			end)
		end)

		if success then
			print("[관리자 초기화] 게임 상태와 Firebase 데이터를 초기화했습니다:", player.Name)
		else
			warn("[관리자 초기화] Firebase 초기화 실패:", err)
		end
	end)
end

resetRemote.OnServerEvent:Connect(function(player)
	if isAdmin(player) then
		resetWorld(player)
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		-- 리스폰하면 새 캐릭터는 기본적으로 보이게 시작합니다.
		invisiblePlayers[player] = nil
		originalAppearance[player] = nil
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	if invisiblePlayers[player] then
		setInvisible(player, false)
	end
	invisiblePlayers[player] = nil
	originalAppearance[player] = nil
	lastResetAt[player] = nil
end)
