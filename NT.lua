-- TennisCurveShot.client.lua
-- RS Tennis (и другие теннисные плейсы): "идеальный" удар через HitBallRF.
--
-- Что делает:
--   * Находит живых врагов (по командам, иначе всех кроме себя), считает их центр.
--   * Определяет, с какой стороны (относительно игрока) стоит враг/враги:
--       враг справа  -> бьём влево, враг слева -> бьём вправо.
--       враг по центру / два врага по бокам -> выбираем более пустой угол
--       (или случайный, для непредсказуемости).
--   * Строит CamDir с БЕЗУМНЫМ боковым курвом + высокой дугой (чтобы мяч
--     вылетал за корт раньше и по более короткой дистанции, а враг не достал).
--   * Прибавляет силу через AttackMoveSpeed (инерция удара).
--   * Учитывает разные корты: никаких хардкод-координат, всё от текущих позиций.
--
-- Запуск: положи как LocalScript (StarterPlayerScripts / StarterGui).
-- Удар: клавиша G (можно поменять ниже).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- ===== Настройки (подбирай под свой вкус) =====
local TRIGGER_KEY      = Enum.KeyCode.G
local SIDE_THRESHOLD   = 99999      -- studs: сверхчувствительное определение стороны
local HEIGHT           = 0.50  -- умеренная высота CamDir (не "удар сверху")
local SIDE_COEFF       = 10.0  -- БЕСКОНЕЧНЫЙ курв: мяч уходит максимально вбок
local HIT_POWER        = 4800  -- БЕСКОНЕЧНАЯ сила удара через AttackMoveSpeed
local FALLBACK_DIST    = 35    -- дистанция для HitPos, если мяч не найден

-- ===== Вспомогательные =====
local function isEnemy(p)
	if p == LocalPlayer then return false end
	if LocalPlayer.Team and p.Team then
		return p.Team ~= LocalPlayer.Team
	end
	-- если команд нет, считаем всех чужими
	return true
end

local function getEnemies()
	local res = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if isEnemy(p) then
			local ch = p.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if hrp and hrp:IsA("BasePart") and hum and hum.Health > 0 then
				table.insert(res, { player = p, hrp = hrp })
			end
		end
	end
	return res
end

local function getBall()
	local b = Workspace:FindFirstChild("Ball")
	if b and b:IsA("BasePart") then return b end
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Ball" or d.Name:lower():find("ball")) then
			return d
		end
	end
	return nil
end

local function getCamPos()
	local cam = Workspace.CurrentCamera
	if cam then return cam.CFrame.Position end
	local ch = LocalPlayer.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position + Vector3.new(0, 5, 0) end
	return Vector3.zero
end

-- ===== Основной расчёт удара =====
local function computeShot()
	local camPos = getCamPos()

	local ch = LocalPlayer.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	local playerPos = hrp and hrp.Position or camPos

	local enemies = getEnemies()

	-- центр врагов (или направление камеры, если врагов нет)
	local enemyCenter
	if #enemies == 0 then
		local cam = Workspace.CurrentCamera
		local look = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
		enemyCenter = playerPos + look * 60
	else
		local sum = Vector3.zero
		for _, e in ipairs(enemies) do
			sum = sum + e.hrp.Position
		end
		enemyCenter = sum / #enemies
	end

	-- горизонтальный forward (к врагам)
	local toEnemy = enemyCenter - playerPos
	local forward = Vector3.new(toEnemy.X, 0, toEnemy.Z)
	if forward.Magnitude < 1e-3 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end

	-- правый вектор относительно forward
	local right = forward:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude < 1e-3 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end

	-- среднее смещение врагов вдоль right
	local enemyOffset = 0
	for _, e in ipairs(enemies) do
		local rel = e.hrp.Position - playerPos
		enemyOffset = enemyOffset + rel:Dot(right)
	end
	if #enemies > 0 then
		enemyOffset = enemyOffset / #enemies
	end

	-- определение стороны удара
	local sideSign = 0
	if enemyOffset > SIDE_THRESHOLD then
		sideSign = -1  -- враг справа -> бьём влево
	elseif enemyOffset < -SIDE_THRESHOLD then
		sideSign = 1   -- враг слева -> бьём вправо
	else
		-- по центру: случайно для непредсказуемости
		sideSign = (math.random() > 0.5) and 1 or -1
	end

	-- если два+ врага, бьём в более пустой угол
	if #enemies >= 2 then
		local leftCount, rightCount = 0, 0
		for _, e in ipairs(enemies) do
			local rel = e.hrp.Position - playerPos
			if rel:Dot(right) > 0 then
				rightCount = rightCount + 1
			else
				leftCount = leftCount + 1
			end
		end
		if leftCount ~= rightCount then
			-- бьём туда, где меньше врагов
			if leftCount < rightCount then
				sideSign = -1  -- влево (меньше врагов слева -> бьём влево? корректируем)
			else
				sideSign = 1
			end
		end
	end

	-- горизонтальное направление с боковым курвом
	local curvedSide = sideSign * (SIDE_COEFF + (math.random() - 0.5) * 4.0)
	local horizontal = forward + right * curvedSide
	if horizontal.Magnitude > 1e-3 then
		horizontal = horizontal.Unit
	else
		horizontal = forward
	end

	-- высокая дуга: Y = HEIGHT, X/Z масштабируются
	-- небольшой шум для непредсказуемости (сила/высота/курв)
	local hNoise = (math.random() - 0.5) * 0.02
	local sideNoise = (math.random() - 0.5) * 2.0
	local heightNow = math.clamp(HEIGHT + hNoise, 0.6, 0.9)
	local xzScale = math.sqrt(math.clamp(1 - heightNow * heightNow, 0, 1))
	local camDir = Vector3.new(horizontal.X * xzScale, heightNow, horizontal.Z * xzScale)
	if camDir.Magnitude < 1e-3 then
		camDir = Vector3.new(0, 1, 0)
	else
		camDir = camDir.Unit
	end

	-- сила удара + отдельный вертикальный подъём после удара (не "сверху")
	local attackMove = camDir * HIT_POWER + Vector3.new(0, 3840, 0)

	-- HitPos: реальная позиция мяча, иначе fallback
	local ball = getBall()
	local hitPos
	if ball then
		hitPos = ball.Position + Vector3.new(0, 15, 0)
	else
		hitPos = camPos + camDir * FALLBACK_DIST + Vector3.new(0, 15, 0)
	end

	local args = {
		[1] = {
			CamPos = camPos,
			HitPos = hitPos,
			HitBallType = 3,        -- Perfect (оставляем тип, меняем векторы)
			ClientTick = tick(),
			CamDir = camDir,
			AttackMoveSpeed = attackMove,
		}
	}
	return args, sideSign, camDir
end

-- ===== Вызов ремоута =====
local function findRemote()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes then
		local r = remotes:FindFirstChild("HitBallRF")
		if r then return r end
	end
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d.Name == "HitBallRF" then
			return d
		end
	end
	return nil
end

local function fireShot()
	local args, sideSign, camDir = computeShot()
	local remote = findRemote()
	if not remote then
		warn("[TennisCurveShot] HitBallRF не найден")
		return
	end
	local ok, err = pcall(function()
		remote:InvokeServer(unpack(args))
	end)
	if not ok then
		warn("[TennisCurveShot] InvokeServer ошибка:", err)
	else
		print(string.format("[TennisCurveShot] удар отправлен | side=%s CamDir=(%.2f,%.2f,%.2f) power=%d",
			sideSign > 0 and "RIGHT" or "LEFT", camDir.X, camDir.Y, camDir.Z, HIT_POWER))
	end
end

-- ===== Управление =====
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == TRIGGER_KEY then
		fireShot()
	end
end)

-- Авто-выстрел при появлении мяча рядом (опционально, можно отключить)
--[[
Workspace.ChildAdded:Connect(function(child)
	if child.Name == "Ball" then
		task.wait(0.1)
		fireShot()
	end
end)
]]

print("[TennisCurveShot] загружен. Нажми G для удара с курвом.")

-- ===== Кнопка Attack в правом верхнем углу =====
local function isGrounded()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return true end
	if hum.FloorMaterial ~= Enum.Material.Air then return true end
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping
		or st == Enum.HumanoidStateType.FallingDown then
		return false
	end
	return true
end

local function playAnim(id)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. tostring(id)
	local ok, track = pcall(function() return hum:LoadAnimation(anim) end)
	if ok and track then
		track:Play()
	end
end

local function setupAttackButton()
	local pg = LocalPlayer:WaitForChild("PlayerGui", 10)
	if not pg then return end

	local srcBtn
	local screenInMatch = pg:FindFirstChild("ScreenInMatch")
	if screenInMatch then
		local rightDown = screenInMatch:FindFirstChild("RightDown")
		if rightDown then
			local atk = rightDown:FindFirstChild("Attack")
			if atk and atk:IsA("GuiButton") then
				srcBtn = atk:Clone()
			end
		end
	end

	local btn = srcBtn
	if not btn then
		btn = Instance.new("TextButton")
		btn.Text = "ATTACK"
		btn.Size = UDim2.new(0, 70, 0, 70)
		btn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 14
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "TennisAttackButton"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.Parent = pg

	btn.Parent = sg
	btn.AnchorPoint = Vector2.new(1, 0)
	-- адаптивный размер: сохраняем пропорции оригинала, но не больше 70px
	if srcBtn then
		local origSize = srcBtn.Size
		-- если оригинал в Scale, оставляем как есть, иначе ограничиваем
		if origSize.X.Scale == 0 and origSize.X.Offset > 70 then
			btn.Size = UDim2.new(0, 70, 0, math.max(32, math.floor(70 * (origSize.Y.Offset / origSize.X.Offset))))
		end
	end
	btn.Position = UDim2.new(1, -10, 0, 10)

	-- UIScale для адаптивности на всех устройствах
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.6
	uiScale.Parent = btn

	btn.Activated:Connect(function()
		local animId = isGrounded() and 117002541983750 or 113744984282505
		task.spawn(playAnim, animId)
		fireShot()
	end)
end

task.spawn(setupAttackButton)
