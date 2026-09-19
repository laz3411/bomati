-- 위치: StarterPlayer > StarterPlayerScripts > LocalScript (이름: WheelchairSpawnerClient)

local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local spawnEvent = ReplicatedStorage:WaitForChild("SpawnWheelchairEvent")

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end

	-- D키 입력 감지
	if input.KeyCode == Enum.KeyCode.D then
		-- LeftShift 또는 RightShift가 같이 눌려있는지 확인
		local isShiftPressed = UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)

		if isShiftPressed then
			spawnEvent:FireServer()
		end
	end
end)