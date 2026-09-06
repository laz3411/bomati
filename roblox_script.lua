--[[
    [로블록스 스튜디오 -> Firebase Realtime Database 연동 스크립트]
    위치: ServerScriptService 아래에 "Script"를 생성하고 본 코드를 붙여넣으세요.
    
    [사전 설정]
    로블록스 스튜디오 상단 [Home] -> [Game Settings] -> [Security] -> "Allow HTTP Requests" ON
--]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- 사용자 지정 Firebase Realtime Database URL
local FIREBASE_DATABASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"
local REST_ENDPOINT = FIREBASE_DATABASE_URL .. "/players.json"

-- 전송 주기 (초당 약 3회)
local SEND_INTERVAL = 0.35

local isSending = false

print("[로블록스 레이더] Firebase 연동 활성화됨. 대상:", REST_ENDPOINT)

task.spawn(function()
    while RunService:IsRunning() do
        if not isSending then
            local currentPlayers = Players:GetPlayers()
            local playersData = {}

            for _, player in ipairs(currentPlayers) do
                local char = player.Character
                if char and char:FindFirstChild("HumanoidRootPart") then
                    local hrp = char.HumanoidRootPart
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
                        x = math.round(pos.X * 10) / 10,
                        y = math.round(pos.Y * 10) / 10,
                        z = math.round(pos.Z * 10) / 10,
                        angle = angle,
                        health = math.round(health),
                        maxHealth = math.round(maxHealth),
                        timestamp = os.time()
                    })
                end
            end

            isSending = true
            task.spawn(function()
                local success, err = pcall(function()
                    return HttpService:RequestAsync({
                        Url = REST_ENDPOINT,
                        Method = "PUT",
                        Headers = { ["Content-Type"] = "application/json" },
                        Body = HttpService:JSONEncode(playersData)
                    })
                end)

                isSending = false

                if not success then
                    -- 실패 시 3초 대기 (로블록스 렉 방지)
                    task.wait(3.0)
                end
            end)
        end

        task.wait(SEND_INTERVAL)
    end
end)
