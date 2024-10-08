local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Janitor = require(script.Parent.Packages.Janitor)
local Signal = require(script.Parent.Packages.Signal)

local EaseFuncs = require(script.EaseFuncs)
local OrthoUtil = require(script.Parent.OrthoUtil)
local Specials = require(script.Specials)
local Types = require(script.Types)

if RunService:IsServer() then
	warn("Moonlite should NOT be used on the server! Rig transforms will not be replicated.")
end

local animationsMemo = setmetatable({}, {
	__index = function(t, k)
		local v = Instance.new("Animation")
		v.AnimationId = k
		rawset(t, k, v)
		return v
	end,
})

type Signal = typeof(Signal.new())
type Janitor = typeof(Janitor.new())
type Scratchpad = Types.Scratchpad
type MoonItem = Types.MoonItem
type MoonAnimInfo = Types.MoonAnimInfo
type MoonAnimItem = Types.MoonAnimItem
type MoonCamRef = Types.MoonCamRef
type MoonAnimPath = Types.MoonAnimPath
type MoonAnimSave = Types.MoonAnimSave
type MoonEaseInfo = Types.MoonEaseInfo
type MoonKeyframe = Types.MoonKeyframe
type MoonProperty = Types.MoonProperty
type MoonJointInfo = Types.MoonJointInfo
type MoonKeyframePack = Types.MoonKeyframePack
type GetSet<Inst, Value> = Types.GetSet<Inst, Value>

local MoonTrack = {}
MoonTrack.__index = MoonTrack

export type MoonTrack = typeof(setmetatable(
	{} :: {
		Completed: Signal,
		Looped: boolean,
		Playing: boolean,
		Length: number,
		_janitor: Janitor,
		_items: { MoonItem },
		_targets: { [Instance]: MoonItem },
		_save: StringValue,
		_data: MoonAnimSave,
		_startTime: number,
		_savedTime: number,
		_markerSignals: { [string]: Signal },
		_markers: { [number]: { { Name: string, Value: any } } },
		_camRef: MoonCamRef,
	},
	MoonTrack
))

local CONSTANT_INTERPS = {
	["Instance"] = true,
	["boolean"] = true,
	["nil"] = true,
}

local function readValue(value: Instance)
	if value:IsA("ValueBase") then
		-- stylua: ignore
		local bin = if tonumber(value.Name)
			then assert(value.Parent)
			else value

		local read = (value :: any).Value
		local enumType = bin:FindFirstChild("EnumType")

		if enumType and enumType:IsA("StringValue") then
			read = (Enum :: any)[enumType.Value][read]
		elseif bin:FindFirstChild("Vector2") then
			read = Vector2.new(read.X, read.Y)
		elseif bin:FindFirstChild("ColorSequence") then
			read = ColorSequence.new(read)
		elseif bin:FindFirstChild("NumberSequence") then
			read = NumberSequence.new(read)
		elseif bin:FindFirstChild("NumberRange") then
			read = NumberRange.new(read)
		end

		return read
	else
		return value:GetAttribute("Value")
	end
end

local function setPropValue(
	scratch: Scratchpad,
	inst: Instance?,
	propName: string,
	value: any,
	isDefault: boolean?
): boolean
	if inst then
		local binding = Specials.Get(scratch, inst, propName)

		if binding then
			if binding.Get == nil and isDefault and value == true then
				-- Ugh, This is an action(?), but for some reason six
				-- sets the default value to true here, which
				-- would behave as an immediate dispatch.
				-- Not the behavior we need.
				warn("Unexplained remnants of Moonlite. If anyone sees this let RoboGojo know.")
				value = false
			end

			return pcall(binding.Set, value)
		end
	end

	return pcall(function()
		(inst :: any)[propName] = value
	end)
end

local function lerp<T>(a: T, b: T, t: number): any
	if type(a) == "number" then
		return a + ((b - a) * t)
	else
		return (a :: any):Lerp(b, t)
	end
end

local function toPath(path: MoonAnimPath): string
	return table.concat(path.InstanceNames, ".")
end

local function parseEase(easeInst: Instance): MoonEaseInfo
	local typeInst = easeInst:FindFirstChild("Type")
	local paramInst = easeInst:FindFirstChild("Params")

	local ease = {
		-- stylua: ignore
		Type = assert(if typeInst and typeInst:IsA("StringValue")
			then typeInst.Value :: any
			else nil),

		Params = {},
	}

	if paramInst then
		for i, param in paramInst:GetChildren() do
			if param:IsA("ValueBase") then
				local value = (param :: any).Value
				ease.Params[param.Name] = value
			end
		end
	end

	return ease
end

local function parseEaseOld(easeInst: Instance): MoonEaseInfo
	local style = easeInst:FindFirstChild("Style")
	assert(style and style:IsA("StringValue"), "No style in legacy ease!")

	local dir = easeInst:FindFirstChild("Direction")
	assert(dir and dir:IsA("StringValue"), "No direction in legacy ease!")

	return {
		Type = style.Value :: any,

		Params = {
			Direction = dir.Value :: any,
		},
	}
end

local function parseKeyframePack(kf: Instance): MoonKeyframePack
	local frame = tonumber(kf.Name)
	assert(frame, "Bad frame number")

	local valueBin = kf:FindFirstChild("Values")
	assert(valueBin, "No value folder!")

	local zero = valueBin:FindFirstChild("0")
	assert(zero, "No starting value!")

	local values = {}
	local maxIndex = 0

	for i, value in valueBin:GetChildren() do
		local index = tonumber(value.Name)

		if index then
			local success, read = pcall(readValue, value)

			if success then
				values[index] = read
				maxIndex = math.max(index, maxIndex)
			end
		end
	end

	local easesBin = kf:FindFirstChild("Eases")
	local easeOld = kf:FindFirstChild("Ease")
	local eases = {}

	if easesBin then
		for _, easeBin in easesBin:GetChildren() do
			local index = tonumber(easeBin.Name)
			assert(index, `Bad index on ease @{easeBin:GetFullName()}`)

			local ease = parseEase(easeBin)
			eases[index] = ease
		end
	elseif easeOld then
		eases[maxIndex] = parseEaseOld(easeOld)
	end

	return {
		FrameIndex = frame,
		FrameCount = maxIndex,

		Values = values,
		Eases = eases,
	}
end

local function unpackKeyframes(container: Folder, modifier: ((any) -> any)?, default: any)
	local packs = {}

	local indices = {}
	for _, frameFolder in container:GetChildren() do
		local frame = tonumber(frameFolder.Name)
		if frame then
			packs[frame] = parseKeyframePack(frameFolder)
			table.insert(indices, frame)
		end
	end
	table.sort(indices)

	for i = 2, #indices do
		local prev = packs[indices[i - 1]]
		local curr = packs[indices[i]]
		prev.Next = curr
		curr.Prev = prev
	end

	local keyframes = {}
	local current: MoonKeyframePack? = packs[indices[1]]
	while current do
		local baseIndex, lastEase = current.FrameIndex, nil
		for i = 0, current.FrameCount do
			local value = current.Values[i]
			if value == nil then continue end
			local ease = current.Eases[i] or lastEase
			if ease then lastEase = ease end

			local currentTime = baseIndex + i
			table.insert(keyframes, {
				Time = currentTime,
				Value = if modifier then modifier(value) else value,
				Ease = ease,
			})
		end

		current = current.Next
	end

	local sequence = {}
	for i = 1, #keyframes - 1 do
		local kf = keyframes[i]
		local nextKf = keyframes[i + 1]

		local start = kf.Value
		local goal = nextKf.Value

		local handler: (number) -> any
		if typeof(goal) == "ColorSequence" then
			start = start.Keypoints[1].Value
			goal = goal.Keypoints[1].Value
			handler = function(t: number)
				return ColorSequence.new(lerp(start, goal, t))
			end
		elseif typeof(goal) == "NumberSequence" then
			start = start.Keypoints[1].Value
			goal = goal.Keypoints[1].Value
			handler = function(t: number)
				return NumberSequence.new(lerp(start, goal, t))
			end
		elseif typeof(goal) == "NumberRange" then
			start = start.Min
			goal = goal.Min
			handler = function(t: number)
				return NumberRange.new(lerp(start, goal, t))
			end
		elseif CONSTANT_INTERPS[typeof(goal)] then
			handler = function(t: number)
				return if t >= 1 then goal else start
			end
		else
			handler = function(t: number)
				return lerp(start, goal, t)
			end
		end

		local ease = EaseFuncs.Get(kf.Ease)
		table.insert(sequence, {
			Time = kf.Time,
			Duration = nextKf.Time - kf.Time,
			Handler = function(t)
				return handler(ease(t))
			end,
			Value = nextKf.Value,
		})
	end

	return sequence
end

local function resolveAnimPath(path: MoonAnimPath?, root: Instance?): Instance?
	if not path then return nil end

	local numSteps = #path.InstanceNames
	local current: Instance = root or game

	local success = pcall(function()
		for i = 2, numSteps do
			local name = path.InstanceNames[i]
			local class = path.InstanceTypes[i]

			local nextInst = (current :: any)[name]
			assert(typeof(nextInst) == "Instance")
			assert(nextInst.ClassName == class)

			current = nextInst
		end

		if path.ItemType == "Rig" then assert(current:FindFirstChildWhichIsA("Animator", true)) end
	end)

	return if success then current else nil
end

local function MakeItem(moonItem: MoonAnimItem, itemSave: Instance, root: Instance?): MoonItem
	local target = resolveAnimPath(moonItem.Path, root)

	local item: MoonItem
	if moonItem.Path.ItemType == "Rig" then
		item = {
			Locks = {},
			Props = {},
			Animation = animationsMemo[moonItem.ID or ""],
			Markers = {},
			Target = target,
			Path = moonItem.Path,
		}

		assert(item.Markers)

		local markerTrack = itemSave:FindFirstChild("MarkerTrack")
		if markerTrack then
			for _, KF in markerTrack:GetChildren() do
				local frameNumber = tonumber(KF.Name)
				if not frameNumber then continue end
				for _, MF in KF.KFMarkers:GetChildren() do
					table.insert(item.Markers, {
						Frame = frameNumber,
						Name = MF.Value,
						Value = MF.Val.Value,
					})
				end
			end
		end
	else
		local props = {}
		for _, prop in itemSave:GetChildren() do
			local default: any = prop:FindFirstChild("default")
			props[prop.Name] = {
				Default = default and readValue(default),
				Sequence = unpackKeyframes(prop),
			}
		end

		item = {
			Locks = {},
			Props = props,
			Target = target,
			Path = moonItem.Path,
		}
	end

	return item
end

local function MakeMarkerSignal(self: MoonTrack, item: MoonItem, markerName: string)
	assert(item.Markers)

	for _, markerData in item.Markers do
		if markerData.Name ~= markerName then continue end
		local markerDatum = self._markers[markerData.Frame]
		if not markerDatum then
			markerDatum = {}
			self._markers[markerData.Frame] = markerDatum
		end
		table.insert(markerDatum, markerData)
	end

	self._markerSignals[markerName] = Signal.new()
	return self._markerSignals[markerName]
end

local function CheckMarkerSignal(self: MoonTrack, frame: number)
	local markerDatum = self._markers[frame]
	if not markerDatum then return end
	for _, markerData in ipairs(markerDatum) do
		self._markerSignals[markerData.Name]:Fire(markerData.Value)
	end
end

function MoonTrack.new(save: StringValue, root: Instance?, camRefOriginCF: CFrame?): MoonTrack
	local data: MoonAnimSave = HttpService:JSONDecode(save.Value)
	local janitor = Janitor.new()

	data.Information.FPS = data.Information.FPS or 60

	local self = setmetatable({
		Completed = janitor:Add(Signal.new(), "Destroy"),
		Looped = data.Information.Looped,
		Playing = false,
		Length = data.Information.Length / data.Information.FPS,
		_janitor = janitor,
		_playingJanitor = janitor:Add(Janitor.new(), "Destroy"),
		_items = {},
		_save = save,
		_data = data,
		_scratch = {},
		_targets = {},
		_startTime = 0,
		_savedTime = 0,
		_markerSignals = {},
		_markers = {},
		_camRef = data.Information.CamRef and {
			Target = resolveAnimPath(data.Information.CamRef, root),
			Path = data.Information.CamRef,
			OriginCF = camRefOriginCF,
		},
	}, MoonTrack)

	if self._camRef and not camRefOriginCF then
		warn("Must specify the camera origin, or else the camera animation may be off.")
	end

	for i, moonItem in data.Items do
		local itemSave = assert(save:FindFirstChild(i))
		local item = MakeItem(moonItem, itemSave, root)
		table.insert(self._items, item)
		if item.Target then
			if item.Path.ItemType == "Rig" then
				local animator = item.Target:FindFirstChildWhichIsA("Animator", true)
				local target = animator
					and self._janitor:Add(animator:LoadAnimation(item.Animation), "Stop")
				self._targets[item.Target] = item
				item.Target = target
			else
				self._targets[item.Target] = item
			end
		end
	end

	return self
end

function MoonTrack.Destroy(self: MoonTrack)
	if not self._janitor.Destroy then return end
	self._janitor:Destroy()
end

function MoonTrack.Play(self: MoonTrack)
	self:Reset()
	self:Resume()
end

function MoonTrack.Resume(self: MoonTrack)
	self._startTime = os.clock() - self._savedTime

	local lastFrame = self._savedTime * self._data.Information.FPS // 1
	local conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - self._startTime
		local frameTime = t * self._data.Information.FPS
		local frame = frameTime // 1

		for i = lastFrame + 1, frame do
			CheckMarkerSignal(self, i)
		end
		lastFrame = frame

		local completed = frame > self._data.Information.Length
		if completed and self._data.Information.Looped then
			frame %= self._data.Information.Length
			frameTime %= self._data.Information.Length
			self:Reset()
		end

		for _, item in self._items do
			if next(item.Locks) then continue end

			if item.Path.ItemType == "Rig" then
				if not item.Target then continue end
				local target: AnimationTrack = item.Target
				if not target.IsPlaying then
					target:Play()
					target:AdjustSpeed(0)
					self._janitor:Add(target, "Stop")
				end
				target.TimePosition = t

				continue
			end

			for propName, prop in item.Props do
				if not prop._currentFrame then continue end
				local kf = prop.Sequence[prop._currentFrame]

				while kf and frame >= kf.Time + kf.Duration do
					prop._currentFrame += 1
					kf = prop.Sequence[prop._currentFrame]
				end

				local v
				if kf then
					v = kf.Handler(math.clamp((frameTime - kf.Time) / kf.Duration, 0, 1))
				else
					v = prop.Sequence[prop._currentFrame - 1].Value
					prop._currentFrame = nil
				end

				if
					item.Path.ItemType == "Camera"
					and propName == "CFrame"
					and self._camRef
					and self._camRef.Target
				then
					v = self._camRef.Target.CFrame * self._camRef.OriginCF:Inverse() * v
				end

				setPropValue(self._scratch, item.Target, propName, v)
			end
		end

		if completed then
			if not self._data.Information.Looped then self:Pause() end
			self.Completed:Fire()
		end
	end)

	self.Playing = true
	self._playingJanitor:Add(function()
		conn:Disconnect()
		self.Playing = false
	end, true)
end

function MoonTrack.Pause(self: MoonTrack)
	if not self._playingJanitor.Cleanup then return end
	self._playingJanitor:Cleanup()
	self._savedTime = os.clock() - self._startTime
end

function MoonTrack.Reset(self: MoonTrack)
	self._startTime = os.clock()
	self._savedTime = 0

	for _, item in self._items do
		if not item.Target then continue end

		if item.Path.ItemType == "Rig" then
			item.Target.TimePosition = 0
		else
			for propName: string, prop in item.Props do
				local default = prop.Default
				if
					item.Path.ItemType == "Camera"
					and propName == "CFrame"
					and self._camRef
					and self._camRef.Target
				then
					default = self._camRef.Target.CFrame * self._camRef.OriginCF:Inverse() * default
				end

				setPropValue(self._scratch, item.Target, propName, default, true)
				prop._currentFrame = if prop.Sequence[1] then 1 else nil
			end
		end
	end
end

function MoonTrack.LockItem(self: MoonTrack, target: Instance?, lock: any?)
	local item = target and self._targets[target]
	if item then
		item.Locks[lock or "Default"] = true
		if item.Path.ItemType == "Rig" then item.Target:Stop() end

		return true
	end

	return false
end

function MoonTrack.UnlockItem(self: MoonTrack, target: Instance?, lock: any?)
	local item = target and self._targets[target]
	if item then
		item.Locks[lock or "Default"] = nil
		if item.Path.ItemType == "Rig" and self.Playing then
			local current = item.Target
			current:Play()
			current.Speed = 0
			current.TimePosition = 0
		end

		return true
	end

	return false
end

function MoonTrack.ReplaceCameraRefByPath(
	self: MoonTrack,
	targetPath: string,
	replacement: Instance
): boolean
	if
		self._camRef
		and toPath(self._camRef.Path):lower() == targetPath:lower()
		and replacement:IsA(self._camRef.Path.ItemType)
	then
		self._camRef.Target = replacement :: BasePart
		return true
	else
		return false
	end
end

function MoonTrack.ReplaceItemByPath(
	self: MoonTrack,
	targetPath: string,
	replacement: Instance
): boolean
	for _, item in self._items do
		if toPath(item.Path):lower() ~= targetPath:lower() then continue end
		local itemType = item.Path.ItemType

		if itemType == "Rig" then
			local animator = replacement:FindFirstChildWhichIsA("Animator", true)
			if animator then
				item.Target = self._janitor:Add(animator:LoadAnimation(item.Animation), "Stop")
				self._targets[replacement] = item
				return true
			end
		end

		if replacement:IsA(itemType) then
			item.Target = replacement
			self._targets[replacement] = item
			return true
		end
	end

	return false
end

local function getRig(self: MoonTrack, targetPath: string)
	for _, item in self._items do
		if toPath(item.Path):lower() ~= targetPath:lower() then continue end
		local itemType = item.Path.ItemType
		if itemType == "Rig" then return item end
	end

	return nil
end

function MoonTrack.GetRigTrack(self: MoonTrack, targetPath: string): AnimationTrack?
	local item = getRig(self, targetPath)
	return item and item.Target
end

function MoonTrack.GetRigTracks(self: MoonTrack)
	return OrthoUtil.filter_map(self._items, function(item)
		return if item.Path.ItemType == "Rig" then item.Target else nil
	end)
end

function MoonTrack.GetMarkerReachedSignal(self: MoonTrack, targetPath: string, markerName: string)
	local item = getRig(self, targetPath)
	return item and MakeMarkerSignal(self, item, markerName)
end

function MoonTrack.GetSetting<T>(self: MoonTrack, name: string): T
	return self._scratch[name]
end

function MoonTrack.SetSetting<T>(self: MoonTrack, name: string, value: T)
	self._scratch[name] = value
end

return MoonTrack
