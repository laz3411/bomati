--[[
    카드 단말기 운전석 UI 차단 클라이언트 스크립트

    설치 위치: StarterPlayer > StarterPlayerScripts > LocalScript
    지정한 운전석에 앉아 있는 동안에만 그 플레이어에게
    카드 태그 홀드 UI가 보이지 않게 합니다.

    실제 운전석의 Attribute: CardTerminalDriverSeat = true (권장)
    또는 좌석 이름: DriveSeat / DriverSeat / 운전석
--]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local PROMPT_NAME = "BusCardTerminalPrompt"
local promptEnabledBeforeDriverSeat = setmetatable({}, { __mode = "k" })
local seatedConnection = nil
local seatedInDriverSeat = false

local function isCardTerminalPrompt(instance)
	return instance:IsA("ProximityPrompt")
		and (instance.Name == PROMPT_NAME or instance:GetAttribute("CardTerminalType") ~= nil)
end

local function isCardTerminalDriverSeat(seatPart)
	if not seatPart or not seatPart:IsA("VehicleSeat") then
		return false
	end

	if seatPart:GetAttribute("CardTerminalDriverSeat") == true then
		return true
	end

	if seatPart.Name == "운전석" then
		return true
	end
	local seatName = string.lower(seatPart.Name)
	return seatName == "driveseat"
		or seatName == "driverseat"
		or seatName == "driver"
		or string.find(seatName, "driver", 1, true) ~= nil
		or string.find(seatName, "drive", 1, true) ~= nil
end

local function setCardPromptsForDriverSeat(hidePrompts)
	for _, instance in ipairs(workspace:GetDescendants()) do
		if isCardTerminalPrompt(instance) then
			if hidePrompts then
				if promptEnabledBeforeDriverSeat[instance] == nil then
					promptEnabledBeforeDriverSeat[instance] = instance.Enabled
					instance.Enabled = false
				end
			else
				local previousEnabled = promptEnabledBeforeDriverSeat[instance]
				if previousEnabled ~= nil then
					instance.Enabled = previousEnabled
					promptEnabledBeforeDriverSeat[instance] = nil
				end
			end
		end
	end
end

local function leaveDriverSeat()
	seatedInDriverSeat = false
	-- Humanoid.Seated(false, nil) 신호가 오면 이전 Enabled 상태를 무조건 복구합니다.
	-- SeatPart 갱신이 한 프레임 늦어도 카드 UI가 계속 꺼진 채 남지 않습니다.
	setCardPromptsForDriverSeat(false)
end

local function connectCharacter(character)
	if seatedConnection then
		seatedConnection:Disconnect()
		seatedConnection = nil
	end

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	-- active/seatPart 이벤트 인자를 그대로 사용합니다. 나중에 SeatPart를 다시 읽어
	-- 판단하면 내린 직후에도 아직 운전석으로 남아 있다고 오인할 수 있습니다.
	seatedConnection = humanoid.Seated:Connect(function(active, seatPart)
		seatedInDriverSeat = active == true and isCardTerminalDriverSeat(seatPart)
		setCardPromptsForDriverSeat(seatedInDriverSeat)
	end)

	-- 리스폰 직후의 잔여 로컬 상태를 정리하고, 이미 앉은 채로 시작했다면 숨깁니다.
	leaveDriverSeat()
	seatedInDriverSeat = isCardTerminalDriverSeat(humanoid.SeatPart)
	setCardPromptsForDriverSeat(seatedInDriverSeat)
end

workspace.DescendantAdded:Connect(function(instance)
	if seatedInDriverSeat and isCardTerminalPrompt(instance) then
		promptEnabledBeforeDriverSeat[instance] = instance.Enabled
		instance.Enabled = false
	end
end)

-- 프롬프트가 잠깐 먼저 보이는 경우까지 막습니다.
ProximityPromptService.PromptShown:Connect(function(prompt)
	if seatedInDriverSeat and isCardTerminalPrompt(prompt) then
		if promptEnabledBeforeDriverSeat[prompt] == nil then
			promptEnabledBeforeDriverSeat[prompt] = prompt.Enabled
		end
		prompt.Enabled = false
	end
end)

player.CharacterAdded:Connect(connectCharacter)
if player.Character then
	connectCharacter(player.Character)
end
