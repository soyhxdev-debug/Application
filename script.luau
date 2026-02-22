-- Module in ReplicatedStorage
-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Combat class
local Combat = {}
Combat.__index = Combat

-- each hit in the combo, finisher hits way harder
local COMBO_DATA = {
	[1] = { damage = 10, knockback = 10, stunTime = 0.3,  hitAt = 0.25 },
	[2] = { damage = 12, knockback = 15, stunTime = 0.35, hitAt = 0.35 },
	[3] = { damage = 18, knockback = 50, stunTime = 0.6,  hitAt = 0.25 },
}

-- animation ids, swap with urs
local ANIMATIONS = {
	combo = {
		[1] = "rbxassetid://113126602071470",
		[2] = "rbxassetid://110935729489168",
		[3] = "rbxassetid://113126602071470",
	},
	block = "rbxassetid://98948247798860", -- loops while holding F
	dash = "rbxassetid://88487319022664",  -- plays once on Q
}

-- feel free to mess with these
local HITBOX_SIZE = Vector3.new(5, 5, 4)
local HITBOX_OFFSET = Vector3.new(0, 0, -3)
local COMBO_RESET = 1.2
local M1_COOLDOWN = 0.5
local HIT_COOLDOWN = 0.6
local DASH_FORCE = 80
local DASH_DURATION = 0.2
local DASH_COOLDOWN = 1.0

-- creates a new combat instance for a character
function Combat.new(character)
	local hrp = character:WaitForChild("HumanoidRootPart")
	local hum = character:WaitForChild("Humanoid")

	local self = setmetatable({
		character = character,
		hrp = hrp,
		humanoid = hum,
		comboCount = 0,
		lastHit = 0,
		comboTimer = nil,
		stunned = false,
		blocking = false,
		dashOnCooldown = false,
		hitCooldowns = {},
		animTracks = {},
		_debug = true,
	}, Combat)

	self:_setupRemote()
	self:_loadAnimations()
	self:_bindInputs()
	self:_bindRenderStep()

	return self
end

-- grabs the remote or makes one if it doesnt exist
function Combat:_setupRemote()
	local remote = ReplicatedStorage:FindFirstChild("CombatRemote")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "CombatRemote"
		remote.Parent = ReplicatedStorage
	end
	self.remote = remote

	-- server tells us when to stun ourselves
	self.remote.OnClientEvent:Connect(function(action, ...)
		if action == "Stun" then
			self:_applyStunLocal(...)
		end
	end)
end

-- loads all anims at the start so theres no delay mid fight
function Combat:_loadAnimations()
	local animator = self.humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = self.humanoid
	end

	for i, id in ANIMATIONS.combo do
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local track = animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
		self.animTracks[i] = track
	end

	-- block loops the whole time ur holding F
	local blockAnim = Instance.new("Animation")
	blockAnim.AnimationId = ANIMATIONS.block
	self.blockTrack = animator:LoadAnimation(blockAnim)
	self.blockTrack.Priority = Enum.AnimationPriority.Action
	self.blockTrack.Looped = true

	-- dash plays once and stops
	local dashAnim = Instance.new("Animation")
	dashAnim.AnimationId = ANIMATIONS.dash
	self.dashTrack = animator:LoadAnimation(dashAnim)
	self.dashTrack.Priority = Enum.AnimationPriority.Action
	self.dashTrack.Looped = false
end

-- click to attack, F to block, Q to dash
function Combat:_bindInputs()
	self._inputBegan = UIS.InputBegan:Connect(function(input, gameProcessedEvent)
		if gameProcessedEvent then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:attack()
		end
		if input.KeyCode == Enum.KeyCode.F then
			self:setBlocking(true)
			self.remote:FireServer("Block", true)
		end
		if input.KeyCode == Enum.KeyCode.Q then
			self:dash()
		end
	end)

	self._inputEnded = UIS.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F then
			self:setBlocking(false)
			self.remote:FireServer("Block", false)
		end
	end)
end

-- keeps debug hitbox aligned every frame if debug is on
function Combat:_bindRenderStep()
	RunService:BindToRenderStep("CombatDebug", Enum.RenderPriority.Camera.Value, function()
		if not self._debugPart then return end
		self._debugPart.CFrame = self.hrp.CFrame * CFrame.new(HITBOX_OFFSET)
	end)
end

-- invisible part that detects if we hit someone, lives for 0.1s then dies
function Combat:_spawnHitbox()
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Size = HITBOX_SIZE
	hitbox.Anchored = false
	hitbox.CanCollide = false
	hitbox.Massless = true
	hitbox.Transparency = self._debug and 0.5 or 1
	hitbox.Color = Color3.fromRGB(255, 0, 0)
	hitbox.Material = Enum.Material.Neon
	hitbox.CFrame = self.hrp.CFrame * CFrame.new(HITBOX_OFFSET)

	-- weld so it stays in front while it exists
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hitbox
	weld.Part1 = self.hrp
	weld.Parent = hitbox

	hitbox.Parent = workspace
	Debris:AddItem(hitbox, 0.1)
	return hitbox
end

-- true if the target was already hit recently
function Combat:_onHitCooldown(victimChar)
	local last = self.hitCooldowns[victimChar]
	return last and (tick() - last) < HIT_COOLDOWN
end

-- locks ur movement for a bit, server fires this when u get hit
function Combat:_applyStunLocal(duration)
	if self.stunned then return end
	self.stunned = true
	self.humanoid.WalkSpeed = 0
	self.humanoid.JumpPower = 0

	task.delay(duration, function()
		self.stunned = false
		if self.humanoid and self.humanoid.Parent and self.humanoid.Health > 0 then
			self.humanoid.WalkSpeed = 16
			self.humanoid.JumpPower = 50
		end
	end)
end

-- checks whos inside the hitbox and tells the server to deal damage
function Combat:_processHit(hitbox, comboStep)
	local data = COMBO_DATA[comboStep]
	local attacker = Players:GetPlayerFromCharacter(self.character)

	-- need a temp connection or GetTouchingParts wont find non-collidable parts
	local conn = hitbox.Touched:Connect(function() end)
	local parts = hitbox:GetTouchingParts()
	conn:Disconnect()

	for _, part in parts do
		local victimChar = part.Parent
		local victim = Players:GetPlayerFromCharacter(victimChar)

		if not victim or victim == attacker then continue end
		if self:_onHitCooldown(victimChar) then continue end

		local hum = victimChar:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then continue end

		self.hitCooldowns[victimChar] = tick()
		self.remote:FireServer("Hit", victim, data.damage, data.stunTime, data.knockback)
	end
end

-- steps the combo forward, resets if u stop attacking for too long
function Combat:_advanceCombo()
	if self.comboTimer then task.cancel(self.comboTimer) end

	self.comboCount = self.comboCount + 1
	if self.comboCount > #COMBO_DATA then
		self.comboCount = 1
	end

	self.comboTimer = task.delay(COMBO_RESET, function()
		self.comboCount = 0
		self.comboTimer = nil
	end)
end

-- plays the swing anim then spawns the hitbox at the right moment
function Combat:attack()
	if self.stunned then return end
	if (tick() - self.lastHit) < M1_COOLDOWN then return end
	self.lastHit = tick()

	self:_advanceCombo()

	local data = COMBO_DATA[self.comboCount]
	local track = self.animTracks[self.comboCount]
	local thisCombo = self.comboCount -- lock this in before the next click changes it

	if track then track:Play() end

	task.delay(data.hitAt, function()
		if not self.character or not self.character.Parent then return end
		local hitbox = self:_spawnHitbox()
		task.wait(0.05)
		self:_processHit(hitbox, thisCombo)
	end)

	self.remote:FireServer("Swing", self.comboCount)
end

-- starts or stops the block anim depending on state
function Combat:setBlocking(state)
	self.blocking = state
	if state then
		self.blockTrack:Play()
	else
		self.blockTrack:Stop()
	end
end

-- launches u forward, gravity still applies since MaxForce Y is 0
function Combat:dash()
	if self.stunned then return end
	if self.dashOnCooldown then return end

	self.dashOnCooldown = true

	if self.dashTrack then self.dashTrack:Play() end

	local direction = self.hrp.CFrame.LookVector

	local bv = Instance.new("BodyVelocity")
	bv.Velocity = direction * DASH_FORCE
	bv.MaxForce = Vector3.new(1e5, 0, 1e5)
	bv.P = 1e4
	bv.Parent = self.hrp
	Debris:AddItem(bv, DASH_DURATION)

	task.delay(DASH_COOLDOWN, function()
		self.dashOnCooldown = false
	end)

	self.remote:FireServer("Dash")
end

-- how long until next swing is allowed
function Combat:getAttackCooldownRemaining()
	return math.max(0, M1_COOLDOWN - (tick() - self.lastHit))
end

-- current state snapshot, useful if u wanna make a HUD
function Combat:getState()
	return {
		combo = self.comboCount,
		stunned = self.stunned,
		blocking = self.blocking,
		canDash = not self.dashOnCooldown,
	}
end

-- shows the hitbox visually in studio
function Combat:setDebug(enabled)
	self._debug = enabled
end

-- resets everything back to default
function Combat:reset()
	self.comboCount = 0
	self.stunned = false
	self.blocking = false
	self.lastHit = 0
	self.dashOnCooldown = false
	self.hitCooldowns = {}
	if self.blockTrack then self.blockTrack:Stop() end
	if self.comboTimer then task.cancel(self.comboTimer) end
	self.comboTimer = nil
	self.humanoid.WalkSpeed = 16
	self.humanoid.JumpPower = 50
end

-- cleanup when the character dies or gets removed
function Combat:destroy()
	if self._inputBegan then self._inputBegan:Disconnect() end
	if self._inputEnded then self._inputEnded:Disconnect() end
	RunService:UnbindFromRenderStep("CombatDebug")
	if self.comboTimer then task.cancel(self.comboTimer) end
	for _, track in self.animTracks do track:Destroy() end
	if self.blockTrack then self.blockTrack:Destroy() end
	if self.dashTrack then self.dashTrack:Destroy() end
	self.hitCooldowns = {}
end

Combat.cleanup = Combat.destroy

return Combat

-- Server
-- Services
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- grab or create the remote
local remote = ReplicatedStorage:FindFirstChild("CombatRemote")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "CombatRemote"
	remote.Parent = ReplicatedStorage
end

-- rate limit so exploiters cant spam hits
local lastDamage = {}
local DAMAGE_COOLDOWN = 0.3

remote.OnServerEvent:Connect(function(attacker, action, ...)
	if action == "Hit" then
		local victim, damage, stunTime, knockback = ...

		if not victim or not victim.Character then return end

		-- rate limit check
		local now = tick()
		if lastDamage[attacker] and (now - lastDamage[attacker]) < DAMAGE_COOLDOWN then return end
		lastDamage[attacker] = now

		-- sanity check so exploiters cant send garbage values
		if type(damage) ~= "number" or damage <= 0 or damage > 100 then return end
		if type(knockback) ~= "number" or knockback <= 0 or knockback > 200 then return end

		local victimChar = victim.Character
		local hum = victimChar:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end

		-- cut damage if theyre blocking
		local blockVal = victimChar:FindFirstChild("Blocking")
		if blockVal and blockVal.Value then
			damage = math.floor(damage * 0.2)
			knockback = knockback * 0.2
		end

		hum:TakeDamage(damage)

		-- knockback has to run server side or it wont affect the victim
		local attackerHrp = attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart")
		local victimHrp = victimChar:FindFirstChild("HumanoidRootPart")

		if attackerHrp and victimHrp then
			local dir = (victimHrp.Position - attackerHrp.Position).Unit + Vector3.new(0, 0.4, 0)

			local bv = Instance.new("BodyVelocity")
			bv.Velocity = dir * knockback
			bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
			bv.P = 1e4
			bv.Parent = victimHrp
			Debris:AddItem(bv, 0.15)
		end

		-- tell the victim to play their stun
		if hum.Health > 0 then
			remote:FireClient(victim, "Stun", stunTime)
		end

	elseif action == "Block" then
		local state = ...
		local char = attacker.Character
		if not char then return end

		-- store block state in a BoolValue so we can check it when hits come in
		local blockVal = char:FindFirstChild("Blocking") or Instance.new("BoolValue", char)
		blockVal.Name = "Blocking"
		blockVal.Value = state == true

	elseif action == "Dash" then
		-- nothing needed here for now, good place to add stamina later
	end
end)

-- clean up when player leaves so the table doesnt grow forever
Players.PlayerRemoving:Connect(function(player)
	lastDamage[player] = nil
end)

-- Client
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()

local Combat = require(ReplicatedStorage:WaitForChild("CombatSystem"))
local combat  = Combat.new(character)

-- recreate the combat instance when the player respawns
player.CharacterAdded:Connect(function(newChar)
	combat:destroy()
	combat = Combat.new(newChar)
end)
