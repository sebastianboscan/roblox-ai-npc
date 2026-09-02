-- NPCController.server.lua
-- Translates natural-language chat instructions into NPC actions via Roblox's TextGenerator.
-- Requires an experience with a Moderate/Restricted content maturity rating.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local SYSTEM_PROMPT = [[
You control an NPC in a 3D scene. Given a player's instruction, output ONLY a JSON array
of actions to perform, in order, representing the final intended plan after resolving
any corrections in the instruction (e.g. "actually do X instead" means X replaces the
earlier step, not that both happen).

Allowed actions:
- {"action": "move_to", "target": "<object name>"}
- {"action": "open", "target": "<object name>"}
- {"action": "close", "target": "<object name>"}
- {"action": "pickup", "target": "<object name>"}
- {"action": "drop", "target": "<object name>"}

Known objects in the scene: WoodenDoor, Sword, Trophy, Exit.
Special target "Player" refers to the player who gave the instruction. Use target "Player"
whenever the instruction asks the NPC to approach, follow, or return to them -- including
phrasings like "come to me", "come here", "come to player", "follow me", "return to me".
Do NOT use "Exit" for these phrasings -- "Exit" only applies if the instruction explicitly
mentions leaving, exiting, or going to the exit.

Return ONLY the raw JSON array. No disclaimers, explanations, or markdown fences.
]]

local textGenerator = Instance.new("TextGenerator")
textGenerator.Parent = workspace
textGenerator.SystemPrompt = SYSTEM_PROMPT
textGenerator.Temperature = 0.3
textGenerator.TopP = 0.9

local function requestPlan(instruction)
	local ok, response = pcall(function()
		return textGenerator:GenerateTextAsync({
			UserPrompt = instruction,
			MaxTokens = 400,
		})
	end)

	if not ok or not response then
		warn("Text generation failed:", response)
		return nil
	end

	local text = response.GeneratedText

	-- The model occasionally prepends disclaimer text despite instructions not to,
	-- so extract the JSON array rather than trusting the whole response.
	local jsonText = text:match("%[.*%]")
	if not jsonText then
		warn("No JSON array found in response:", text)
		return nil
	end

	local planOk, plan = pcall(function()
		return HttpService:JSONDecode(jsonText)
	end)

	if not planOk then
		warn("Could not parse plan as JSON:", jsonText)
		return nil
	end

	return plan
end

local actions = {}

local function getPrimaryPart(object)
	if object:IsA("BasePart") then
		return object
	elseif object:IsA("Model") then
		return object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Case-insensitive lookup, since the LLM doesn't always return exact casing.
local function findSceneObject(targetName)
	if not targetName then return nil end

	local direct = workspace:FindFirstChild(targetName)
	if direct then return direct end

	local lowerTarget = targetName:lower()
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name:lower() == lowerTarget then
			return child
		end
	end

	return nil
end

function actions.move_to(npc, targetName, player)
	local part

	if targetName and targetName:lower() == "player" then
		part = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not part then
			warn("move_to: could not find the player's character")
			return
		end
	else
		local target = findSceneObject(targetName)
		if not target then
			warn("move_to: no object named", targetName)
			return
		end
		part = getPrimaryPart(target)
		if not part then
			warn("move_to: object", targetName, "has no usable part")
			return
		end
	end

	npc.Humanoid:MoveTo(part.Position)
	npc.Humanoid.MoveToFinished:Wait()
end

function actions.open(npc, targetName)
	local part = getPrimaryPart(findSceneObject(targetName) or {})
	if not part then
		warn("open: no object named", targetName)
		return
	end
	part.CanCollide = false
	part.Transparency = 0.7
end

function actions.close(npc, targetName)
	local part = getPrimaryPart(findSceneObject(targetName) or {})
	if not part then
		warn("close: no object named", targetName)
		return
	end
	part.CanCollide = true
	part.Transparency = 0
end

function actions.pickup(npc, targetName)
	local item = findSceneObject(targetName)
	if not item then
		warn("pickup: no object named", targetName)
		return
	end
	item.Parent = npc
end

function actions.drop(npc, targetName)
	local lowerTarget = targetName and targetName:lower()
	local item = npc:FindFirstChild(targetName)

	if not item then
		for _, child in ipairs(npc:GetChildren()) do
			if child.Name:lower() == lowerTarget then
				item = child
				break
			end
		end
	end

	if not item then
		warn("drop: NPC isn't holding", targetName)
		return
	end
	item.Parent = workspace
end

local function executePlan(npc, plan, player)
	for _, step in ipairs(plan) do
		local handler = actions[step.action]
		if handler then
			handler(npc, step.target, player)
		else
			warn("Unknown action:", step.action)
		end
	end
end

local function onPlayerChatted(player, instructionText)
	local npc = workspace:FindFirstChild("NPC")
	if not npc then
		warn("No NPC found in workspace")
		return
	end

	task.spawn(function()
		local plan = requestPlan(instructionText)
		if plan then
			executePlan(npc, plan, player)
		end
	end)
end

local function onPlayerAdded(player)
	player.Chatted:Connect(function(message)
		onPlayerChatted(player, message)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
