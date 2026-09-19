-- 위치: ServerScriptService > Script (이름: WheelchairSpawnerServer)

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- ★ [설정] 허용할 플레이어의 영어 닉네임("이름") 또는 UserId(숫자)
local ALLOWED_USERS = {
	"beargobearman", -- 본인 영어 닉네임
	--12345678,         -- 본인 UserId 숫자
}

local spawnEvent = ReplicatedStorage:FindFirstChild("SpawnWheelchairEvent") or Instance.new("RemoteEvent")
spawnEvent.Name = "SpawnWheelchairEvent"
spawnEvent.Parent = ReplicatedStorage

local function isAllowed(player)
	for _, identifier in ipairs(ALLOWED_USERS) do
		if type(identifier) == "string" then
			if string.lower(player.Name) == string.lower(identifier) then
				return true
			end
		elseif type(identifier) == "number" then
			if player.UserId == identifier then
				return true
			end
		end
	end
	return false
end

spawnEvent.OnServerEvent:Connect(function(player)
	if not isAllowed(player) then return end

	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")

	if not hum or not hrp then return end

	-- 기존에 소환해둔 휠체어 검색
	local existingWheelchair = workspace:FindFirstChild(player.Name .. "_Wheelchair")

	-- ★ [토글 로직] 이미 휠체어가 소환되어 있다면 삭제 후 일어서기
	if existingWheelchair then
		hum.Sit = false -- 착석 해제 (일어서기)
		task.wait(0.05)
		existingWheelchair:Destroy() -- 휠체어 제거
		return
	end

	-- 휠체어가 없을 때: 새로 생성 및 탑승
	local wheelchairTemplate = ServerStorage:FindFirstChild("Wheelchair Prop")
	if not wheelchairTemplate then
		warn("⚠️ ServerStorage 안에 'Wheelchair Prop' 모델이 없습니다!")
		return
	end

	local wheelchair = wheelchairTemplate:Clone()
	wheelchair.Name = player.Name .. "_Wheelchair"
	-- Shift+N 관리자 초기화에서 일반 맵 오브젝트와 구분해 제거할 수 있게 표시합니다.
	wheelchair:SetAttribute("SpawnedWheelchair", true)
	wheelchair:SetAttribute("AdminResettable", true)
	wheelchair:SetAttribute("SpawnedByUserId", player.UserId)
	wheelchair:SetAttribute("SpawnedByUserName", player.Name)
	CollectionService:AddTag(wheelchair, "ADMIN_RESETTABLE")

	local seat = wheelchair:FindFirstChildOfClass("VehicleSeat")
	if not seat then return end

	wheelchair:PivotTo(hrp.CFrame)
	wheelchair.Parent = workspace

	task.wait(0.05)
	seat:Sit(hum)
end)
