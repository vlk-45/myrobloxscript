```
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer      = Players.LocalPlayer
local Camera           = workspace.CurrentCamera

local library = loadstring(game:HttpGet("https://raw.githubusercontent.com/imagoodpersond/puppyware/main/lib"))()

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
local TixSettings = {
    -- Aimbot
    Sticky              = false,
    InstantAim          = false,
    Smoothness          = 0.35,
    HeadOnly            = false,
    UsePrediction       = true,
    Prediction          = 0.14,
    WallCheck           = true,
    TeamCheck           = false,
    NPCs                = false,
    FOV                 = 150,
    CircleVis           = false,
    CloseRange          = 35,
    ToggleKey           = Enum.KeyCode.RightAlt,
    -- ESP
    ESP                 = false,
    SkeletonESP         = false,
    ShowHealthBar       = true,
    ShowHealthNum       = true,
    ShowDistance        = true,
    -- Tracers
    Tracers             = false,
    TracerFromCenter    = false,       -- true = from screen center
    TracerRange         = 0,           -- 0 = unlimited
    BehindTracers       = false,
    BehindColor         = "Red",
    -- Team
    TeamTracers         = false,
    TeamTracerColor     = "Blue",
    -- Style
    RainbowStyle        = false,
}

local PrimaryPurple = Color3.fromRGB(150, 50, 250)

local visualCache        = {}
local connections        = {}
local selectedBoneName   = "Head"
local lastBoneSwitchTime = 0
local BoneSwitchInterval = 0.22

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function getRainbow()
    return Color3.fromHSV(tick() % 5 / 5, 0.7, 1)
end

local function healthColor(pct)
    if pct > 0.5 then
        return Color3.fromRGB(math.floor((1 - pct) * 2 * 255), 255, 0)
    else
        return Color3.fromRGB(255, math.floor(pct * 2 * 255), 0)
    end
end

----------------------------------------------------------------------
-- Wall check
----------------------------------------------------------------------
local wallParams = RaycastParams.new()
wallParams.FilterType  = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true

local function isVisible(targetPart)
    if not TixSettings.WallCheck then return true end
    if not targetPart then return false end
    local origin = Camera.CFrame.Position
    local dir    = targetPart.Position - origin
    if dir.Magnitude < 1 then return true end
    wallParams.FilterDescendantsInstances = { LocalPlayer.Character, Camera }
    local result = workspace:Raycast(origin, dir, wallParams)
    if not result then return true end
    return result.Instance:IsDescendantOf(targetPart.Parent)
end

----------------------------------------------------------------------
-- Prediction
----------------------------------------------------------------------
local function getPredicted(part)
    if not TixSettings.UsePrediction then return part.Position end
    local vel = part.AssemblyLinearVelocity or Vector3.zero
    return part.Position + vel * TixSettings.Prediction
end

----------------------------------------------------------------------
-- Target acquisition
----------------------------------------------------------------------
local function getClosest()
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local bestModel, bestScore = nil, math.huge
    local potentials = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local hum = plr.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                if not (TixSettings.TeamCheck
                    and LocalPlayer.Team
                    and plr.Team == LocalPlayer.Team)
                then
                    table.insert(potentials, plr.Character)
                end
            end
        end
    end

    if TixSettings.NPCs then
        for _, v in ipairs(workspace:GetDescendants()) do
            if v:IsA("Model") and v:FindFirstChildOfClass("Humanoid") then
                local hum = v:FindFirstChildOfClass("Humanoid")
                if hum.Health > 0
                    and not Players:GetPlayerFromCharacter(v)
                    and v ~= LocalPlayer.Character
                then
                    table.insert(potentials, v)
                end
            end
        end
    end

    for _, model in ipairs(potentials) do
        local root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
        if not root then continue end
        local sp, onScreen = Camera:WorldToViewportPoint(root.Position)
        if not onScreen or sp.Z <= 0 then continue end
        if not isVisible(root) then continue end

        local dist2d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
        if dist2d > TixSettings.FOV then continue end

        local dist3d = (root.Position - Camera.CFrame.Position).Magnitude
        local score  = dist2d + dist3d * 0.15

        if score < bestScore then
            bestScore = score
            bestModel = model
        end
    end

    return bestModel
end

----------------------------------------------------------------------
-- Tracer screen pos
----------------------------------------------------------------------
local function getTracerPos(worldPos, viewport)
    local sp     = Camera:WorldToViewportPoint(worldPos)
    local sx, sy = sp.X, sp.Y
    local behind = sp.Z <= 0
    if behind then
        sx = viewport.X - sx
        sy = viewport.Y - sy
    end
    local mg = 8
    sx = math.clamp(sx, mg, viewport.X - mg)
    sy = math.clamp(sy, mg, viewport.Y - mg)
    return Vector2.new(sx, sy), behind
end

----------------------------------------------------------------------
-- Exact character bounds — project all 8 corners of every BasePart
----------------------------------------------------------------------
local function getCharacterBounds(char)
    local minX, minY =  math.huge,  math.huge
    local maxX, maxY = -math.huge, -math.huge
    local valid = false

    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Transparency < 1 then
            local cf, size = part.CFrame, part.Size
            local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
            -- 8 corners of the part's oriented bounding box
            for _, sx in ipairs({ -hx, hx }) do
                for _, sy in ipairs({ -hy, hy }) do
                    for _, sz in ipairs({ -hz, hz }) do
                        local world = (cf * CFrame.new(sx, sy, sz)).Position
                        local sp = Camera:WorldToViewportPoint(world)
                        if sp.Z > 0 then
                            if sp.X < minX then minX = sp.X end
                            if sp.Y < minY then minY = sp.Y end
                            if sp.X > maxX then maxX = sp.X end
                            if sp.Y > maxY then maxY = sp.Y end
                            valid = true
                        end
                    end
                end
            end
        end
    end

    if not valid or maxX <= minX or maxY <= minY then return nil end
    -- 1px pad only so the box sits on the silhouette, not inside it
    local pad = 1
    return {
        x = minX - pad,
        y = minY - pad,
        w = (maxX - minX) + pad * 2,
        h = (maxY - minY) + pad * 2,
    }
end

----------------------------------------------------------------------
-- Skeleton bones (R15 + R6)
----------------------------------------------------------------------
local SKELETON_BONES = {
    { "Head", "UpperTorso" }, { "Head", "Torso" },
    { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" },  { "LeftUpperArm",  "LeftLowerArm" },  { "LeftLowerArm",  "LeftHand" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
    { "LowerTorso", "LeftUpperLeg" },  { "LeftUpperLeg",  "LeftLowerLeg" },  { "LeftLowerLeg",  "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
    { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}
local BONE_COUNT = #SKELETON_BONES

----------------------------------------------------------------------
-- Visual cache
----------------------------------------------------------------------
local function newD(kind, props)
    local d = Drawing.new(kind)
    for k, v in pairs(props) do d[k] = v end
    return d
end

local function createVisuals(char)
    if visualCache[char] then return visualCache[char] end

    local corners = {}
    for _ = 1, 8 do
        corners[#corners + 1] = newD("Line", { Visible = false, Thickness = 2 })
    end

    local bones = {}
    for _ = 1, BONE_COUNT do
        bones[#bones + 1] = newD("Line", { Visible = false, Thickness = 1.25 })
    end

    local v = {
        Line          = newD("Line",   { Visible = false, Thickness = 1.5 }),
        Box           = newD("Square", { Visible = false, Filled = false, Thickness = 1 }),
        Corners       = corners,
        Bones         = bones,
        HealthBarBg   = newD("Square", {
            Visible = false, Filled = true,
            Color = Color3.fromRGB(15, 15, 15), Transparency = 0.5,
        }),
        HealthBarFill = newD("Square", {
            Visible = false, Filled = true, Transparency = 0,
        }),
        HealthText    = newD("Text", {
            Visible = false, Size = 11, Center = true,
            Outline = true, OutlineColor = Color3.fromRGB(0, 0, 0),
            Color = Color3.fromRGB(255, 255, 255),
        }),
        DistText      = newD("Text", {
            Visible = false, Size = 11, Center = true,
            Outline = true, OutlineColor = Color3.fromRGB(0, 0, 0),
            Color = Color3.fromRGB(180, 180, 180),
        }),
    }

    visualCache[char] = v
    return v
end

local function hideAll(visual)
    visual.Line.Visible          = false
    visual.Box.Visible           = false
    visual.HealthBarBg.Visible   = false
    visual.HealthBarFill.Visible = false
    visual.HealthText.Visible    = false
    visual.DistText.Visible      = false
    for _, c in ipairs(visual.Corners) do c.Visible = false end
    for _, b in ipairs(visual.Bones)   do b.Visible = false end
end

local function removeVisuals(char)
    local cache = visualCache[char]
    if not cache then return end
    hideAll(cache)
    cache.Line:Remove()
    cache.Box:Remove()
    cache.HealthBarBg:Remove()
    cache.HealthBarFill:Remove()
    cache.HealthText:Remove()
    cache.DistText:Remove()
    for _, c in ipairs(cache.Corners) do c:Remove() end
    for _, b in ipairs(cache.Bones)   do b:Remove() end
    visualCache[char] = nil
end

local function monitorCharacter(char)
    if char == LocalPlayer.Character then return end
    local hum = char:WaitForChild("Humanoid", 5)
    if hum then
        createVisuals(char)
        table.insert(connections, hum.Died:Connect(function()
            task.delay(0.1, function() removeVisuals(char) end)
        end))
    end
end

local function updateCorners(corners, x, y, w, h, color)
    local len = math.clamp(math.min(w, h) * 0.22, 4, 14)
    corners[1].From = Vector2.new(x, y);         corners[1].To = Vector2.new(x + len, y)
    corners[2].From = Vector2.new(x, y);         corners[2].To = Vector2.new(x, y + len)
    corners[3].From = Vector2.new(x + w, y);     corners[3].To = Vector2.new(x + w - len, y)
    corners[4].From = Vector2.new(x + w, y);     corners[4].To = Vector2.new(x + w, y + len)
    corners[5].From = Vector2.new(x, y + h);     corners[5].To = Vector2.new(x + len, y + h)
    corners[6].From = Vector2.new(x, y + h);     corners[6].To = Vector2.new(x, y + h - len)
    corners[7].From = Vector2.new(x + w, y + h); corners[7].To = Vector2.new(x + w - len, y + h)
    corners[8].From = Vector2.new(x + w, y + h); corners[8].To = Vector2.new(x + w, y + h - len)
    for _, c in ipairs(corners) do c.Visible = true; c.Color = color end
end

----------------------------------------------------------------------
-- FOV circle
----------------------------------------------------------------------
local Circle = Drawing.new("Circle")
Circle.Visible   = false
Circle.Thickness = 2
Circle.NumSides  = 64
Circle.Radius    = TixSettings.FOV
Circle.Filled    = false
Circle.Color     = PrimaryPurple

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local Window         = library:new({ name = "Aimbot Universal", accent = PrimaryPurple, textsize = 13 })
local MainTab        = Window:page({ name = "Main" })
local AimSection     = MainTab:section({ name = "Aimlock Settings", side = "left",  size = 350 })
local VisualSection  = MainTab:section({ name = "Visual Settings",  side = "right", size = 360 })
local ExtrasTab      = Window:page({ name = "Extras" })
local ScriptsSection = ExtrasTab:section({ name = "Scripts", side = "left", size = 310 })

ScriptsSection:button({ name = "PurpsUtils", callback = function()
    loadstring(game:HttpGet("https://raw.githubusercontent.com/PurpleWorksKirnotP/PurpleScripts/refs/heads/main/PurpsUtility/PurpsUtility.lua"))()
end })

-- Aimbot
AimSection:toggle({ name = "Sticky Aimlock",     def = TixSettings.Sticky,        callback = function(v) TixSettings.Sticky = v end })
AimSection:toggle({ name = "Instant Aim",         def = TixSettings.InstantAim,    callback = function(v) TixSettings.InstantAim = v end })
AimSection:toggle({ name = "Head Only",           def = TixSettings.HeadOnly,      callback = function(v) TixSettings.HeadOnly = v end })
AimSection:toggle({ name = "Use Prediction",      def = TixSettings.UsePrediction, callback = function(v) TixSettings.UsePrediction = v end })
AimSection:slider({ name = "Smoothness", min = 5,  max = 100, def = TixSettings.Smoothness * 100, callback = function(v) TixSettings.Smoothness = v / 100 end })
AimSection:slider({ name = "Prediction", min = 0,  max = 40,  def = TixSettings.Prediction * 100, callback = function(v) TixSettings.Prediction = v / 100 end })
AimSection:toggle({ name = "Wall Check",          def = TixSettings.WallCheck,     callback = function(v) TixSettings.WallCheck = v end })
AimSection:toggle({ name = "Team Check",          def = TixSettings.TeamCheck,     callback = function(v) TixSettings.TeamCheck = v end })
AimSection:toggle({ name = "Include Bots / NPCs", def = TixSettings.NPCs,          callback = function(v) TixSettings.NPCs = v end })

-- Visuals
VisualSection:toggle({ name = "Visual ESP",              def = TixSettings.ESP,              callback = function(v) TixSettings.ESP = v end })
VisualSection:toggle({ name = "Skeleton ESP",            def = TixSettings.SkeletonESP,      callback = function(v) TixSettings.SkeletonESP = v end })
VisualSection:toggle({ name = "Show Health Bar",         def = TixSettings.ShowHealthBar,    callback = function(v) TixSettings.ShowHealthBar = v end })
VisualSection:toggle({ name = "Show Health Number",      def = TixSettings.ShowHealthNum,    callback = function(v) TixSettings.ShowHealthNum = v end })
VisualSection:toggle({ name = "Show Distance (studs)",   def = TixSettings.ShowDistance,     callback = function(v) TixSettings.ShowDistance = v end })
VisualSection:toggle({ name = "Tracers",                 def = TixSettings.Tracers,          callback = function(v) TixSettings.Tracers = v end })
VisualSection:toggle({ name = "Tracer From Center",      def = TixSettings.TracerFromCenter, callback = function(v) TixSettings.TracerFromCenter = v end })
VisualSection:slider({ name = "Tracer Range (0=unlim)",  min = 0, max = 2000, def = TixSettings.TracerRange, callback = function(v) TixSettings.TracerRange = v end })
VisualSection:toggle({ name = "Behind Tracers",          def = TixSettings.BehindTracers,    callback = function(v) TixSettings.BehindTracers = v end })
VisualSection:dropdown({ name = "Behind Tracer Color",   options = {"Red","Purple"}, def = TixSettings.BehindColor, callback = function(v) TixSettings.BehindColor = v end })
VisualSection:toggle({ name = "Team Tracers",            def = TixSettings.TeamTracers,      callback = function(v) TixSettings.TeamTracers = v end })
VisualSection:dropdown({ name = "Team Tracer Color",     options = {"Blue","Green"}, def = TixSettings.TeamTracerColor, callback = function(v) TixSettings.TeamTracerColor = v end })
VisualSection:toggle({ name = "Rainbow Mode",            def = TixSettings.RainbowStyle,     callback = function(v) TixSettings.RainbowStyle = v end })
VisualSection:toggle({ name = "Show FOV Circle",         def = TixSettings.CircleVis,        callback = function(v) TixSettings.CircleVis = v; Circle.Visible = v end })
VisualSection:slider({ name = "FOV Size", min = 10, max = 1200, def = TixSettings.FOV, callback = function(v) TixSettings.FOV = v; Circle.Radius = v end })

-- Sticky Aim actif uniquement pendant le maintien du clic droit
local RightMouseHeld = false

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gpe)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        RightMouseHeld = true
    end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        RightMouseHeld = false
    end
end))

----------------------------------------------------------------------
-- Character listeners
----------------------------------------------------------------------
for _, p in ipairs(Players:GetPlayers()) do
    if p.Character then task.spawn(monitorCharacter, p.Character) end
    table.insert(connections, p.CharacterAdded:Connect(monitorCharacter))
end
table.insert(connections, Players.PlayerAdded:Connect(function(p)
    table.insert(connections, p.CharacterAdded:Connect(monitorCharacter))
end))

if TixSettings.NPCs then
    for _, v in ipairs(workspace:GetDescendants()) do
        if v:IsA("Model") and v:FindFirstChildOfClass("Humanoid") then
            task.spawn(monitorCharacter, v)
        end
    end
end

table.insert(connections, workspace.DescendantAdded:Connect(function(v)
    if TixSettings.NPCs and v:IsA("Model") then
        task.spawn(function()
            RunService.Heartbeat:Wait()
            if v:FindFirstChildOfClass("Humanoid") then monitorCharacter(v) end
        end)
    end
end))

----------------------------------------------------------------------
-- Core render loop
----------------------------------------------------------------------
local runtimeLoop = RunService.RenderStepped:Connect(function(dt)
    local accent   = TixSettings.RainbowStyle and getRainbow() or PrimaryPurple
    local viewport = Camera.ViewportSize
    local center   = Vector2.new(viewport.X / 2, viewport.Y / 2)

    Circle.Position = center
    Circle.Color    = accent
    Circle.Radius   = TixSettings.FOV
    Circle.Visible  = TixSettings.CircleVis

    ------------------------------------------------------------
    -- Aimbot
    ------------------------------------------------------------
    if TixSettings.Sticky and RightMouseHeld then
        local targetModel = getClosest()
        if targetModel then
            local root   = targetModel:FindFirstChild("HumanoidRootPart") or targetModel:FindFirstChild("Head")
            local dist3d = root and (root.Position - Camera.CFrame.Position).Magnitude or 999

            local boneName
            if TixSettings.HeadOnly or dist3d <= TixSettings.CloseRange then
                boneName = "Head"
            else
                if tick() - lastBoneSwitchTime > BoneSwitchInterval then
                    lastBoneSwitchTime = tick()
                    selectedBoneName   = math.random() > 0.4 and "Head" or "HumanoidRootPart"
                end
                boneName = selectedBoneName
            end

            local lockPart = targetModel:FindFirstChild(boneName)
                or targetModel:FindFirstChild("HumanoidRootPart")
                or targetModel:FindFirstChild("Head")

            if lockPart then
                local aimPos   = getPredicted(lockPart)
                local targetCF = CFrame.new(Camera.CFrame.Position, aimPos)
                if TixSettings.InstantAim then
                    Camera.CFrame = targetCF
                else
                    local f = math.clamp(TixSettings.Smoothness * dt * 60, 0.01, 1)
                    Camera.CFrame = Camera.CFrame:Lerp(targetCF, f)
                end
            end
        end
    end

    ------------------------------------------------------------
    -- Color precompute
    ------------------------------------------------------------
    local behindColor = TixSettings.BehindColor == "Purple"
        and Color3.fromRGB(180, 0, 255)
        or  Color3.fromRGB(255, 40, 40)

    local teamColor = TixSettings.TeamTracerColor == "Green"
        and Color3.fromRGB(0, 220, 80)
        or  Color3.fromRGB(50, 130, 255)

    local tracerFrom = TixSettings.TracerFromCenter
        and center
        or  Vector2.new(viewport.X / 2, viewport.Y)

    ------------------------------------------------------------
    -- ESP + Tracers + Skeleton
    ------------------------------------------------------------
    for char, visual in pairs(visualCache) do
        if not char or not char.Parent then
            removeVisuals(char)
            continue
        end

        local hum      = char:FindFirstChildOfClass("Humanoid")
        local root     = char:FindFirstChild("HumanoidRootPart")
        local head     = char:FindFirstChild("Head")
        local plr      = Players:GetPlayerFromCharacter(char)
        local sameTeam = plr and LocalPlayer.Team ~= nil and plr.Team == LocalPlayer.Team
        local alive    = hum and hum.Health > 0
        local anchor   = head or root

        if not alive then
            hideAll(visual)
            continue
        end

        local dist3d  = anchor and (anchor.Position - Camera.CFrame.Position).Magnitude or 0
        local inRange = TixSettings.TracerRange == 0 or dist3d <= TixSettings.TracerRange

        -- teammate branch
        if sameTeam then
            visual.Box.Visible           = false
            visual.HealthBarBg.Visible   = false
            visual.HealthBarFill.Visible = false
            visual.HealthText.Visible    = false
            visual.DistText.Visible      = false
            for _, c in ipairs(visual.Corners) do c.Visible = false end
            for _, b in ipairs(visual.Bones)   do b.Visible = false end

            if TixSettings.TeamTracers and anchor and inRange then
                local tracerPt = getTracerPos(anchor.Position, viewport)
                visual.Line.Visible   = true
                visual.Line.From      = tracerFrom
                visual.Line.To        = tracerPt
                visual.Line.Color     = teamColor
                visual.Line.Thickness = 1.5
            else
                visual.Line.Visible = false
            end
            continue
        end

        -- Tracer
        if TixSettings.Tracers and anchor and inRange then
            local tracerPt, behind = getTracerPos(anchor.Position, viewport)
            if behind and not TixSettings.BehindTracers then
                visual.Line.Visible = false
            else
                visual.Line.Visible   = true
                visual.Line.From      = tracerFrom
                visual.Line.To        = tracerPt
                visual.Line.Color     = behind and behindColor or accent
                visual.Line.Thickness = 1.5
            end
        else
            visual.Line.Visible = false
        end

        -- ESP box (exact fit)
        if TixSettings.ESP then
            local bounds = getCharacterBounds(char)
            if bounds then
                local x, y, w, h = bounds.x, bounds.y, bounds.w, bounds.h

                visual.Box.Visible   = true
                visual.Box.Position  = Vector2.new(x, y)
                visual.Box.Size      = Vector2.new(w, h)
                visual.Box.Color     = Color3.fromRGB(
                    math.floor(accent.R * 255 * 0.3),
                    math.floor(accent.G * 255 * 0.3),
                    math.floor(accent.B * 255 * 0.3)
                )
                visual.Box.Thickness = 1

                updateCorners(visual.Corners, x, y, w, h, accent)

                local healthPct = math.clamp(hum.Health / hum.MaxHealth, 0, 1)
                local barW, barGap = 3, 3
                local barX  = x - barW - barGap
                local fillH = math.max(1, math.floor(h * healthPct))

                if TixSettings.ShowHealthBar then
                    visual.HealthBarBg.Visible    = true
                    visual.HealthBarFill.Visible  = true
                    visual.HealthBarBg.Position   = Vector2.new(barX, y)
                    visual.HealthBarBg.Size       = Vector2.new(barW, h)
                    visual.HealthBarFill.Position = Vector2.new(barX, y + h - fillH)
                    visual.HealthBarFill.Size     = Vector2.new(barW, fillH)
                    visual.HealthBarFill.Color    = healthColor(healthPct)
                else
                    visual.HealthBarBg.Visible   = false
                    visual.HealthBarFill.Visible = false
                end

                local labelY = y + h + 2

                if TixSettings.ShowHealthNum then
                    visual.HealthText.Visible  = true
                    visual.HealthText.Text     = math.floor(hum.Health) .. " / " .. math.floor(hum.MaxHealth)
                    visual.HealthText.Position = Vector2.new(x + w / 2, labelY)
                    visual.HealthText.Color    = healthColor(healthPct)
                    labelY += 12
                else
                    visual.HealthText.Visible = false
                end

                if TixSettings.ShowDistance then
                    visual.DistText.Visible  = true
                    visual.DistText.Text     = math.floor(dist3d) .. " studs"
                    visual.DistText.Position = Vector2.new(x + w / 2, labelY)
                else
                    visual.DistText.Visible = false
                end
            else
                visual.Box.Visible           = false
                visual.HealthBarBg.Visible   = false
                visual.HealthBarFill.Visible = false
                visual.HealthText.Visible    = false
                visual.DistText.Visible      = false
                for _, c in ipairs(visual.Corners) do c.Visible = false end
            end
        else
            visual.Box.Visible           = false
            visual.HealthBarBg.Visible   = false
            visual.HealthBarFill.Visible = false
            visual.HealthText.Visible    = false
            visual.DistText.Visible      = false
            for _, c in ipairs(visual.Corners) do c.Visible = false end
        end

        -- Skeleton
        if TixSettings.SkeletonESP then
            for i, pair in ipairs(SKELETON_BONES) do
                local pA   = char:FindFirstChild(pair[1])
                local pB   = char:FindFirstChild(pair[2])
                local bone = visual.Bones[i]
                if pA and pB and pA:IsA("BasePart") and pB:IsA("BasePart") then
                    local sA = Camera:WorldToViewportPoint(pA.Position)
                    local sB = Camera:WorldToViewportPoint(pB.Position)
                    if sA.Z > 0 and sB.Z > 0 then
                        bone.Visible   = true
                        bone.From      = Vector2.new(sA.X, sA.Y)
                        bone.To        = Vector2.new(sB.X, sB.Y)
                        bone.Color     = accent
                        bone.Thickness = 1.25
                    else
                        bone.Visible = false
                    end
                else
                    bone.Visible = false
                end
            end
        else
            for _, b in ipairs(visual.Bones) do b.Visible = false end
        end
    end
end)

table.insert(connections, runtimeLoop)
MainTab:openpage()
```