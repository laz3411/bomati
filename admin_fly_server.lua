--[[
    관리자 비행/투명화 서버 스크립트

    설치 위치: ServerScriptService
    관리자 여부와 투명화는 서버에서 검증합니다.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- 현재 프로젝트의 기존 대상 계정을 기본 관리자로 등록합니다.
-- 이름은 바뀔 수 있으므로, 실제 운영 전에는 UserId를 ADMIN_USER_IDS에 넣는 것을 권장합니다.
local ADMIN_USER_IDS = {
    -- [123456789] = true,
}

local ADMIN_USER_NAMES = {
    ["laz3411"] = true,
}

local CHECK_REMOTE_NAME = "AdminAbilityCheck"
local APPEARANCE_REMOTE_NAME = "AdminAppearanceRequest"

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

local invisiblePlayers = {}
local originalAppearance = {}

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
end)

