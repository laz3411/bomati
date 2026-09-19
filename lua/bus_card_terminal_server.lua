--[[
    버스 승·하차 카드 단말기 서버 스크립트

    설치 위치: ServerScriptService > Script

    Studio 설정
    1. 각 버스 Model에 CollectionService 태그 "BUS"를 붙입니다.
    2. 입구 단말기 Model(또는 투명 트리거 Part)에 "CARD_TERMINAL_ENTRY" 태그를 붙입니다.
    3. 뒷문 하차 단말기 Model(또는 투명 트리거 Part)에 "CARD_TERMINAL_EXIT" 태그를 붙입니다.
    4. 단말기 Model에 태그를 붙인 경우, 그 안의 투명 BasePart 이름을
       "CardTerminalTrigger"로 하거나 Attribute "CardTerminalTrigger"를 true로 설정합니다.

    플레이어가 트리거 근처에서 C를 2초간 누르면 카드 태그가 처리됩니다.
    - 같은 버스 입구 단말기를 다시 태그: 이미 처리된 카드입니다
    - 다른 버스 입구 단말기를 태그: 환승입니다
    - 하차 단말기를 태그: 하차입니다
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local BUS_TAG = "BUS"
local ENTRY_TERMINAL_TAG = "CARD_TERMINAL_ENTRY"
local EXIT_TERMINAL_TAG = "CARD_TERMINAL_EXIT"
local TRIGGER_PART_NAME = "CardTerminalTrigger"
local PROMPT_NAME = "BusCardTerminalPrompt"

local HOLD_DURATION_SECONDS = 0.2
local ACTIVATION_DISTANCE = 4
local REPEAT_GUARD_SECONDS = 0.75

local SOUND_IDS = {
	transfer = "rbxassetid://80688349662411",
	alreadyProcessed = "rbxassetid://75212638692984",
	thankYou = "rbxassetid://101551481799156",
	alight = "rbxassetid://119019553196511",
}

local playerCardStates = {} -- [userId] = { lastEntryBusKey, activeBusKey, lastActionAt }
local registeredPrompts = {} -- [ProximityPrompt] = true
local busRuntimeKeys = setmetatable({}, { __mode = "k" })
local terminalRuntimeKeys = setmetatable({}, { __mode = "k" })
local nextBusRuntimeKey = 0
local nextTerminalRuntimeKey = 0

local function getRuntimeKey(instance, keys, nextKeyName)
	if keys[instance] then
		return keys[instance]
	end

	if nextKeyName == "bus" then
		nextBusRuntimeKey += 1
		keys[instance] = "bus-" .. tostring(nextBusRuntimeKey)
	else
		nextTerminalRuntimeKey += 1
		keys[instance] = "terminal-" .. tostring(nextTerminalRuntimeKey)
	end
	return keys[instance]
end

local function getBusModel(instance)
	local current = instance
	local taggedBus = nil
	while current and current ~= workspace do
		if current:IsA("Model") and CollectionService:HasTag(current, BUS_TAG) then
			-- 중첩 모델에 BUS 태그가 있어도 가장 바깥쪽 실제 차량을 사용합니다.
			taggedBus = current
		end
		current = current.Parent
	end
	return taggedBus
end

local function findTriggerPart(terminal)
	if terminal:IsA("BasePart") then
		return terminal
	end

	for _, descendant in ipairs(terminal:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("CardTerminalTrigger") == true then
			return descendant
		end
	end

	local namedTrigger = terminal:FindFirstChild(TRIGGER_PART_NAME, true)
	if namedTrigger and namedTrigger:IsA("BasePart") then
		return namedTrigger
	end

	return nil
end

local function getCardState(player)
	local state = playerCardStates[player.UserId]
	if not state then
		state = {
			lastEntryBusKey = nil,
			activeBusKey = nil,
			lastActionAt = {},
		}
		playerCardStates[player.UserId] = state
	end
	return state
end

local function playTerminalVoice(triggerPart, soundId, label)
	local previous = triggerPart:FindFirstChild("BusCardTerminalVoice")
	if previous and previous:IsA("Sound") then
		previous:Stop()
		previous:Destroy()
	end

	local sound = Instance.new("Sound")
	sound.Name = "BusCardTerminalVoice"
	sound.SoundId = soundId
	sound.Volume = 1.5
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 8
	sound.RollOffMaxDistance = 48
	sound.EmitterSize = 4
	sound.Looped = false
	sound.Parent = triggerPart
	sound:Play()

	-- 오디오가 로드되지 않거나 Ended가 오지 않아도 단말기 안에 Sound가 쌓이지 않게 합니다.
	task.delay(20, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)

	print(string.format("[카드 단말기] %s: %s", triggerPart:GetFullName(), label))
end

local function processCardTag(player, terminalType, terminal, triggerPart)
	local busModel = getBusModel(terminal) or getBusModel(triggerPart)
	if not busModel then
		warn(string.format("[카드 단말기] BUS 태그가 붙은 상위 버스를 찾지 못했습니다: %s", terminal:GetFullName()))
		return
	end

	local state = getCardState(player)
	local terminalKey = getRuntimeKey(terminal, terminalRuntimeKeys, "terminal")
	local now = os.clock()
	if now - (state.lastActionAt[terminalKey] or 0) < REPEAT_GUARD_SECONDS then
		return
	end
	state.lastActionAt[terminalKey] = now

	local busKey = getRuntimeKey(busModel, busRuntimeKeys, "bus")
	if terminalType == "entry" then
		if state.lastEntryBusKey == busKey then
			playTerminalVoice(triggerPart, SOUND_IDS.alreadyProcessed, "이미 처리된 카드입니다")
			return
		end

		local isTransfer = state.lastEntryBusKey ~= nil and state.lastEntryBusKey ~= busKey
		state.lastEntryBusKey = busKey
		state.activeBusKey = busKey
		if isTransfer then
			playTerminalVoice(triggerPart, SOUND_IDS.transfer, "환승입니다")
		else
			playTerminalVoice(triggerPart, SOUND_IDS.thankYou, "감사합니다")
		end
		return
	end

	state.activeBusKey = nil
	playTerminalVoice(triggerPart, SOUND_IDS.alight, "하차입니다")
end

local function configurePrompt(prompt, terminalType, terminal, triggerPart)
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "카드 태그"
	prompt.ObjectText = terminalType == "entry" and "입구 단말기" or "하차 단말기"
	prompt.KeyboardKeyCode = Enum.KeyCode.C
	prompt.HoldDuration = HOLD_DURATION_SECONDS
	prompt.MaxActivationDistance = ACTIVATION_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.ClickablePrompt = true
	prompt:SetAttribute("IgnoreBusBell", true)
	prompt:SetAttribute("CardTerminalType", terminalType)

	if registeredPrompts[prompt] then
		return
	end
	registeredPrompts[prompt] = true
	prompt.Triggered:Connect(function(player)
		if not player or not player:IsDescendantOf(Players) then
			return
		end
		processCardTag(player, terminalType, terminal, triggerPart)
	end)
end

local function registerTerminal(terminal, terminalType)
	if not terminal or not terminal:IsDescendantOf(workspace) then
		return
	end

	local triggerPart = findTriggerPart(terminal)
	if not triggerPart then
		warn(string.format(
			"[카드 단말기] %s에 투명 트리거 Part가 없습니다. %s 이름 또는 CardTerminalTrigger=true Attribute를 설정하세요.",
			terminal:GetFullName(),
			TRIGGER_PART_NAME
		))
		return
	end

	if not getBusModel(terminal) and not getBusModel(triggerPart) then
		warn(string.format("[카드 단말기] %s의 상위 Model에 BUS 태그가 없습니다.", terminal:GetFullName()))
		return
	end

	local prompt = triggerPart:FindFirstChild(PROMPT_NAME)
	if prompt and not prompt:IsA("ProximityPrompt") then
		prompt = nil
	end
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		-- 버스 하차벨 스크립트가 DescendantAdded에서 모든 프롬프트를 감시하므로,
		-- 제외 Attribute를 먼저 설정한 뒤 월드에 넣어야 카드 태그가 벨로 처리되지 않습니다.
		configurePrompt(prompt, terminalType, terminal, triggerPart)
		prompt.Parent = triggerPart
		return
	end
	configurePrompt(prompt, terminalType, terminal, triggerPart)
end

local function registerTaggedTerminals(tagName, terminalType)
	for _, terminal in ipairs(CollectionService:GetTagged(tagName)) do
		registerTerminal(terminal, terminalType)
	end

	CollectionService:GetInstanceAddedSignal(tagName):Connect(function(terminal)
		task.defer(registerTerminal, terminal, terminalType)
	end)
end

local function registerAncestorTerminal(instance)
	local current = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, ENTRY_TERMINAL_TAG) then
			registerTerminal(current, "entry")
		end
		if CollectionService:HasTag(current, EXIT_TERMINAL_TAG) then
			registerTerminal(current, "exit")
		end
		current = current.Parent
	end
end

Players.PlayerRemoving:Connect(function(player)
	playerCardStates[player.UserId] = nil
end)

workspace.DescendantAdded:Connect(function(instance)
	task.defer(registerAncestorTerminal, instance)
end)

registerTaggedTerminals(ENTRY_TERMINAL_TAG, "entry")
registerTaggedTerminals(EXIT_TERMINAL_TAG, "exit")

print("[카드 단말기] 활성화: C키 2초 홀드 / 입구·하차·환승 처리")
