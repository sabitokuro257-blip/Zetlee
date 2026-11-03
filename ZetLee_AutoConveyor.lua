--[[
    ZetLee - Auto Conveyor (v4)
    - Auto roll conveyor (NewRequestConveyorRoll)
    - Tab "Box": pilih jenis box (hanya di script, tidak mengubah pengaturan game)
    - Tab "Mutasi": pilih mutasi (Normal, Golden, Unbound, dst), terpisah dari pilihan box
    - Auto berhenti hanya saat box terpilih (dengan mutasi terpilih, jika ada) muncul akibat roll;
      lanjut saat box itu hilang (dibeli / roll manual) atau tombol "Lanjut"
    - Reset: batalkan semua pilihan box + mutasi
    - Scan hanya di plot milik pemain sendiri
    - Tab "Item": auto ambil item spawn (token varian + item acak), mode Jalan / Teleport cepat, lalu kembali ke base
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

---------------------------------------------------------------------
-- KONFIGURASI
---------------------------------------------------------------------
local BOXES = {
    "Slayer", "Pirate", "Guild", "Ninja", "Hunter", "Warrior",
    "Grimoire", "Reaper", "Titan", "Devil", "Journey", "Shadow",
    "Stand", "Sin", "Sorcerer", "Ghoul", "Inferno", "Tempest",
}

-- Daftar mutasi (urut seperti di Index game). Tambah di sini jika ada mutasi lain.
local VARIANTS = {
    "Normal", "Golden", "Diamond", "Swift", "Blazing", "Electric", "Unbound",
    "Moonlit", "Transcendent", "Cursed", "Malevolent", "Admin", "Eternal",
}

-- Nama lain (terjemahan) yang tampil di game. Tambahkan sendiri jika bahasa game bukan Inggris.
local ALIASES = {
    Hunter = { "Pemburu" },
}
local VARIANT_ALIASES = {
    Golden = { "Emas" },
    Diamond = { "Berlian" },
    Swift = { "Cepat" },
    Eternal = { "Abadi" },
}

local ROLL_DELAY = 0.5    -- jeda setelah roll sebelum scan (detik)
local SCOPE_MODE = "both" -- "both" | "prompt" | "conveyor"
local CONVEYOR_HINT = "conveyor"
local PLOT_NAME = nil     -- nama plot milikmu di Workspace.Map.PlotModels; nil = otomatis pakai nama akun
local EXCLUDE_HINTS = {
    "setting", "config", "button", "locker", "loker",
    "dropper", "showcase", "pedestal", "collectpart", "sellcrate", "droppedobject",
}
local LOCKER_WORDS = { "loker", "locker", "pulih", "restore" }
local PURCHASE_WORDS = { "purchase", "buy", "pembelian", "beli" }

-- Auto ambil item: folder di Workspace.Systems dan remote untuk mengambilnya
local COLLECT_SOURCES = {
    { folder = "VariantTokenSpawns", remote = "CollectVariantTokenSpawn", label = "Token" },
    { folder = "CollectableObjects", remote = "CollectCollectableObject", label = "Acak" },
}
local COLLECT_COOLDOWN = 8   -- jika pengambilan tidak terkonfirmasi, coba lagi setelah N detik
local REQUIRE_VISIBLE = true -- hanya item yang tampak (part, billboard/ikon, decal, efek) dianggap sudah spawn
local TRIP_TIMEOUT = 40      -- batas waktu satu perjalanan jalan (detik)
local WALK_STALL = 3         -- waypoint tidak tercapai dalam N detik = hitung ulang jalur (detik)
local STUCK_TIME = 6         -- tidak ada kemajuan menuju tujuan selama N detik = dianggap macet (detik)
local EARLY_FIRE_RANGE = 12  -- saat jalan, mulai coba ambil begitu sedekat N stud (maks 3x)
local AVOID_BELTS = true     -- hindari speed track / sabuk conveyor saat mencari jalur
local HAZARD_NAME_HINTS = { "tower", "portal", "obby" } -- objek bernama ini dianggap area bahaya (tidak dilewati)
local WALK_FALLBACK_TP = true -- mode Jalan: jika macet/tidak sampai, lanjut dengan teleport agar item tidak terlewat
local TP_STAY = 0.35         -- jeda di lokasi item sebelum mengambil, agar posisi terkirim ke server (detik)
local CONFIRM_WAIT = 0.6     -- lama menunggu server menandai item sudah diambil (Occupied = false)

-- Auto level up
local LEVEL_OPEN_TIMEOUT = 900 -- batas menunggu countdown box sampai terbuka (detik)
local LEVEL_UP_TIMEOUT = 600   -- batas waktu level up sampai level target (detik)

---------------------------------------------------------------------
-- REMOTE
---------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RollRemote = Remotes:WaitForChild("NewRequestConveyorRoll")

pcall(function()
    return ReplicatedStorage:WaitForChild("Client", 5)
        :WaitForChild("Core", 5)
        :WaitForChild("Classes", 5)
        :WaitForChild("ConveyorButtonPart", 5)
end)

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local autoOn = false
local paused = false
local pausedHits = {}
local ignoredSig = setmetatable({}, { __mode = "k" }) -- [instance] = "Box|Mutasi" yang diabaikan
local alive = true
local minimized = false
local selected = {}    -- box terpilih
local selectedVar = {} -- mutasi terpilih per box: selectedVar[box][mutasi] = true/false

local collectOn = false
local collectMode = "walk" -- "walk" | "tp"
local baseCF = nil
local collectedAt = setmetatable({}, { __mode = "k" })
local collectCount = 0
local collectTried = 0
local actionText = "menunggu item"
local lastItemCount = 0

local levelOn = false
local levelBusy = false
local levelMult = 3      -- uang minimal = levelMult x harga box
local levelTarget = 50   -- level target unit baru
local levelProtect = 5   -- jumlah unit income tertinggi yang tidak boleh dikeluarkan
local levelStatus = "idle"
local levelLast = "-"
local levelCount = 0
local levelCooldownUntil = 0

local function buildTerms(names, aliases)
    local t = {}
    for _, n in ipairs(names) do
        t[n] = { n }
        for _, a in ipairs(aliases[n] or {}) do table.insert(t[n], a) end
    end
    return t
end
local TERMS = buildTerms(BOXES, ALIASES)
local VTERMS = buildTerms(VARIANTS, VARIANT_ALIASES)
for _, n in ipairs(BOXES) do
    selected[n] = false
    selectedVar[n] = {}
    for _, v in ipairs(VARIANTS) do selectedVar[n][v] = false end
end

-- jumlah mutasi yang dipilih untuk sebuah box (0 = semua mutasi dianggap cocok)
local function boxVarCount(box)
    local n = 0
    for _, v in ipairs(VARIANTS) do
        if selectedVar[box][v] then n += 1 end
    end
    return n
end

---------------------------------------------------------------------
-- AREA SCAN
---------------------------------------------------------------------
local conveyorRoots = {}
local lastRootScan = 0
local prompts = setmetatable({}, { __mode = "k" })
local scopeCache, scopeStamp = {}, 0

local function trackPrompt(d)
    if d:IsA("ProximityPrompt") then prompts[d] = true end
end
task.spawn(function()
    for _, d in ipairs(workspace:GetDescendants()) do trackPrompt(d) end
end)
workspace.DescendantAdded:Connect(trackPrompt)

-- plot milik pemain ini: Workspace.Map.PlotModels.<nama>
local function getPlot()
    local map = workspace:FindFirstChild("Map")
    local plots = map and map:FindFirstChild("PlotModels")
    if not plots then return nil end
    local plot = plots:FindFirstChild(PLOT_NAME or player.Name) or plots:FindFirstChild(player.DisplayName)
    if plot then return plot end
    for _, p in ipairs(plots:GetChildren()) do
        for _, key in ipairs({ "Owner", "OwnerId", "OwnerUserId", "UserId", "PlayerName" }) do
            local v = p:GetAttribute(key)
            if v ~= nil and (v == player.UserId or v == player.Name) then return p end
        end
    end
    return nil
end

local function refreshRoots()
    if os.clock() - lastRootScan < 3 then return end
    lastRootScan = os.clock()
    conveyorRoots = {}
    local plot = getPlot()
    if not plot then return end
    local tc = plot:FindFirstChild("TycoonConveyor", true)
    if tc then
        table.insert(conveyorRoots, tc)
        return
    end
    for _, d in ipairs(plot:GetDescendants()) do
        if (d:IsA("Folder") or d:IsA("Model")) and string.find(string.lower(d.Name), CONVEYOR_HINT, 1, true) then
            table.insert(conveyorRoots, d)
        end
    end
end

local function containsAny(str, words)
    local s = string.lower(str)
    for _, w in ipairs(words) do
        if string.find(s, w, 1, true) then return true end
    end
    return false
end

local function isPurchasePrompt(p)
    local t = p.ActionText .. " " .. p.ObjectText
    if containsAny(t, LOCKER_WORDS) then return false end
    return containsAny(t, PURCHASE_WORDS)
end

local function getScopes(force)
    if not force and os.clock() - scopeStamp < 0.4 then return scopeCache end
    scopeStamp = os.clock()
    local roots, seen = {}, {}
    local function add(r)
        if r and not seen[r] and r:IsDescendantOf(workspace) then
            seen[r] = true
            table.insert(roots, r)
        end
    end
    local plot = getPlot()
    if SCOPE_MODE ~= "conveyor" and plot then
        for p in pairs(prompts) do
            if p.Parent and p:IsDescendantOf(plot) and isPurchasePrompt(p) then
                add(p:FindFirstAncestorOfClass("Model") or p.Parent)
            end
        end
    end
    if SCOPE_MODE ~= "prompt" then
        refreshRoots()
        for _, r in ipairs(conveyorRoots) do add(r) end
    end
    scopeCache = roots
    return roots
end

---------------------------------------------------------------------
-- PENCOCOKAN BOX & MUTASI
---------------------------------------------------------------------
local function nameHas(str, term)
    local h, t = string.lower(str), string.lower(term)
    if #t <= 3 then
        return string.find(h, "%f[%a]" .. t .. "%f[%A]") ~= nil
    end
    return string.find(h, t, 1, true) ~= nil
end

local function textHas(str, term)
    return string.find(string.lower(str), "%f[%a]" .. string.lower(term) .. "%f[%A]") ~= nil
end

local function matchBox(inst, onlySelected)
    local isText = inst:IsA("TextLabel") or inst:IsA("TextButton")
    local isObj = inst:IsA("Model") or inst:IsA("BasePart")
    if not (isText or isObj) then return nil end

    local attr = nil
    if isObj then
        attr = inst:GetAttribute("BoxType") or inst:GetAttribute("Type")
        if type(attr) ~= "string" then attr = nil end
    end

    for _, box in ipairs(BOXES) do
        if not onlySelected or selected[box] then
            for _, term in ipairs(TERMS[box]) do
                if isText then
                    if textHas(inst.Text, term) then return box end
                else
                    if nameHas(inst.Name, term) or (attr and nameHas(attr, term)) then return box end
                end
            end
        end
    end
    return nil
end

local function isExcluded(inst)
    local p = inst
    while p and p ~= workspace do
        if containsAny(p.Name, EXCLUDE_HINTS) then return true end
        p = p.Parent
    end
    return false
end

local function inLockerGui(inst)
    local g = inst:FindFirstAncestorWhichIsA("BillboardGui") or inst:FindFirstAncestorWhichIsA("SurfaceGui")
    if not g then return false end
    for _, d in ipairs(g:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and containsAny(d.Text, LOCKER_WORDS) then
            return true
        end
    end
    return false
end

local function isVisible(inst)
    local p = inst
    while p and p ~= workspace do
        if p:IsA("GuiObject") and not p.Visible then return false end
        if (p:IsA("BillboardGui") or p:IsA("SurfaceGui")) and not p.Enabled then return false end
        p = p.Parent
    end
    return true
end

local function valid(inst)
    return isVisible(inst) and not isExcluded(inst) and not inLockerGui(inst)
end

-- mutasi item: dicari di label-label yang satu GUI dengan label nama box
local function variantContainer(inst)
    return inst:FindFirstAncestorWhichIsA("BillboardGui")
        or inst:FindFirstAncestorWhichIsA("SurfaceGui")
        or (inst:IsA("Model") and inst)
        or inst:FindFirstAncestorOfClass("Model")
        or inst.Parent
end

local function variantMatches(inst, onlySelected, box)
    local c = variantContainer(inst)
    if not c then return nil end
    local texts = {}
    local function add(x)
        if (x:IsA("TextLabel") or x:IsA("TextButton")) and x.Text ~= "" and isVisible(x) then
            table.insert(texts, x.Text)
        end
    end
    add(c)
    for _, d in ipairs(c:GetDescendants()) do add(d) end
    for _, key in ipairs({ "Variant", "Mutation" }) do
        for _, o in ipairs({ inst, c }) do
            local a = o:GetAttribute(key)
            if type(a) == "string" then table.insert(texts, a) end
        end
    end
    for _, v in ipairs(VARIANTS) do
        if not onlySelected or selectedVar[box][v] then
            for _, term in ipairs(VTERMS[v]) do
                for _, t in ipairs(texts) do
                    if textHas(t, term) then return v end
                end
            end
        end
    end
    return nil
end

-- return hits, jumlah area, peta jenis box yang terlihat { [box] = { [mutasi] = true } }
local function scanConveyor(useIgnore)
    local hits, seenNames, dedupe = {}, {}, {}
    local roots = getScopes(false)
    for _, root in ipairs(roots) do
        local list = root:GetDescendants()
        table.insert(list, root)
        for _, d in ipairs(list) do
            if not dedupe[d] then
                local anyBox = matchBox(d, false)
                if anyBox then
                    dedupe[d] = true
                    if valid(d) then
                        local varAny = variantMatches(d, false)
                        seenNames[anyBox] = seenNames[anyBox] or {}
                        seenNames[anyBox][varAny or "?"] = true

                        local selBox = matchBox(d, true)
                        if selBox then
                            local varSel = nil
                            local pass = true
                            if boxVarCount(selBox) > 0 then
                                varSel = variantMatches(d, true, selBox)
                                pass = varSel ~= nil
                            end
                            if pass then
                                local sig = selBox .. "|" .. (varSel or "")
                                if not (useIgnore and ignoredSig[d] == sig) then
                                    table.insert(hits, { inst = d, name = selBox, variant = varSel, sig = sig })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return hits, #roots, seenNames
end

local function isLive(h)
    local inst = h.inst
    if not (inst.Parent and inst:IsDescendantOf(workspace)) then return false end
    if not selected[h.name] then return false end
    if not valid(inst) then return false end
    if matchBox(inst, false) ~= h.name then return false end
    if h.variant and variantMatches(inst, true, h.name) ~= h.variant then return false end
    return true
end

local function ignoreHits(hits, onlyName)
    for _, h in ipairs(hits) do
        if not onlyName or h.name == onlyName then
            ignoredSig[h.inst] = h.sig
        end
    end
end

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ZetLee"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local okParent = pcall(function()
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not okParent or not gui.Parent then
    gui.Parent = player:WaitForChild("PlayerGui")
end

local WIDTH, TITLE_H, BODY_H = 260, 34, 330

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, WIDTH, 0, TITLE_H + BODY_H)
main.Position = UDim2.new(0, 20, 0.3, 0)
main.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
titleBar.BorderSizePixel = 0
titleBar.Parent = main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 80, 1, 0)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "ZetLee"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local autoBtn = Instance.new("TextButton")
autoBtn.Size = UDim2.new(0, 84, 0, 24)
autoBtn.Position = UDim2.new(1, -128, 0.5, -12)
autoBtn.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
autoBtn.Text = "AUTO: OFF"
autoBtn.TextColor3 = Color3.new(1, 1, 1)
autoBtn.Font = Enum.Font.GothamBold
autoBtn.TextSize = 12
autoBtn.Parent = titleBar
Instance.new("UICorner", autoBtn).CornerRadius = UDim.new(0, 6)

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 28, 0, 24)
minBtn.Position = UDim2.new(1, -36, 0.5, -12)
minBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
minBtn.Text = "-"
minBtn.TextColor3 = Color3.new(1, 1, 1)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 16
minBtn.Parent = titleBar
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

local body = Instance.new("Frame")
body.Size = UDim2.new(1, 0, 0, BODY_H)
body.Position = UDim2.new(0, 0, 0, TITLE_H)
body.BackgroundTransparency = 1
body.Parent = main

local function makeButton(text, color, size, pos, textSize)
    local b = Instance.new("TextButton")
    b.Size = size
    b.Position = pos
    b.BackgroundColor3 = color
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = textSize or 11
    b.Parent = body
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    return b
end

local resumeBtn = makeButton("Lanjut", Color3.fromRGB(60, 90, 160), UDim2.new(0, 56, 0, 20), UDim2.new(1, -64, 0, 5))

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -80, 0, 22)
status.Position = UDim2.new(0, 8, 0, 4)
status.BackgroundTransparency = 1
status.Text = "Status: idle"
status.TextColor3 = Color3.fromRGB(200, 200, 210)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextTruncate = Enum.TextTruncate.AtEnd
status.Parent = body

local seenLabel = Instance.new("TextLabel")
seenLabel.Size = UDim2.new(1, -90, 0, 22)
seenLabel.Position = UDim2.new(0, 8, 0, 29)
seenLabel.BackgroundTransparency = 1
seenLabel.Text = "Terlihat: -"
seenLabel.TextColor3 = Color3.fromRGB(150, 200, 255)
seenLabel.Font = Enum.Font.Gotham
seenLabel.TextSize = 12
seenLabel.TextXAlignment = Enum.TextXAlignment.Left
seenLabel.TextTruncate = Enum.TextTruncate.AtEnd
seenLabel.Parent = body

local debugBtn = makeButton("Debug", Color3.fromRGB(80, 60, 110), UDim2.new(0, 74, 0, 22), UDim2.new(1, -82, 0, 29))

-- Tab: Box | Mutasi | Reset
local tabBox = makeButton("Box", Color3.fromRGB(60, 90, 160), UDim2.new(0, 44, 0, 22), UDim2.new(0, 8, 0, 56), 11)
local tabVar = makeButton("Mutasi", Color3.fromRGB(55, 55, 70), UDim2.new(0, 52, 0, 22), UDim2.new(0, 54, 0, 56), 11)
local tabItem = makeButton("Item", Color3.fromRGB(55, 55, 70), UDim2.new(0, 42, 0, 22), UDim2.new(0, 108, 0, 56), 11)
local tabLevel = makeButton("Level", Color3.fromRGB(55, 55, 70), UDim2.new(0, 46, 0, 22), UDim2.new(0, 152, 0, 56), 11)
local resetBtn = makeButton("Reset", Color3.fromRGB(150, 60, 60), UDim2.new(0, 50, 0, 22), UDim2.new(0, 200, 0, 56), 11)

local function makeList()
    local sf = Instance.new("ScrollingFrame")
    sf.Size = UDim2.new(1, -16, 1, -88)
    sf.Position = UDim2.new(0, 8, 0, 82)
    sf.BackgroundTransparency = 1
    sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 4
    sf.CanvasSize = UDim2.new(0, 0, 0, 0)
    sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.Parent = body
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = sf
    return sf
end

local boxList = makeList()

-- Halaman Mutasi: pilih box (‹ ›), lalu atur mutasi khusus untuk box itu
local varPage = Instance.new("Frame")
varPage.Size = UDim2.new(1, -16, 1, -88)
varPage.Position = UDim2.new(0, 8, 0, 82)
varPage.BackgroundTransparency = 1
varPage.Visible = false
varPage.Parent = body

local varPrev = makeButton("<", Color3.fromRGB(70, 70, 90), UDim2.new(0, 30, 0, 26), UDim2.new(0, 0, 0, 0), 14)
local varTitle = makeButton("", Color3.fromRGB(55, 55, 70), UDim2.new(1, -136, 0, 26), UDim2.new(0, 34, 0, 0), 12)
local varNext = makeButton(">", Color3.fromRGB(70, 70, 90), UDim2.new(0, 30, 0, 26), UDim2.new(1, -98, 0, 0), 14)
local varClear = makeButton("Kosongkan", Color3.fromRGB(150, 60, 60), UDim2.new(0, 64, 0, 26), UDim2.new(1, -64, 0, 0), 10)
for _, b in ipairs({ varPrev, varTitle, varNext, varClear }) do b.Parent = varPage end
varTitle.TextTruncate = Enum.TextTruncate.AtEnd

local varList = Instance.new("ScrollingFrame")
varList.Size = UDim2.new(1, 0, 1, -30)
varList.Position = UDim2.new(0, 0, 0, 30)
varList.BackgroundTransparency = 1
varList.BorderSizePixel = 0
varList.ScrollBarThickness = 4
varList.CanvasSize = UDim2.new(0, 0, 0, 0)
varList.AutomaticCanvasSize = Enum.AutomaticSize.Y
varList.Parent = varPage
do
    local vl = Instance.new("UIListLayout")
    vl.Padding = UDim.new(0, 4)
    vl.SortOrder = Enum.SortOrder.LayoutOrder
    vl.Parent = varList
end

-- Halaman Item
local itemPage = Instance.new("Frame")
itemPage.Size = UDim2.new(1, -16, 1, -88)
itemPage.Position = UDim2.new(0, 8, 0, 82)
itemPage.BackgroundTransparency = 1
itemPage.Visible = false
itemPage.Parent = body
do
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 6)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = itemPage
end

local function pageButton(parent, text, order, h)
    local b = Instance.new("TextButton")
    b.LayoutOrder = order
    b.Size = UDim2.new(1, -6, 0, h or 28)
    b.Font = Enum.Font.Gotham
    b.TextSize = 13
    b.TextColor3 = Color3.new(1, 1, 1)
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.BackgroundColor3 = Color3.fromRGB(55, 55, 70)
    b.Text = text
    b.Parent = parent
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    return b
end

local collectToggle = pageButton(itemPage, "  Auto Ambil Item  [OFF]", 1)

local modeFrame = Instance.new("Frame")
modeFrame.LayoutOrder = 2
modeFrame.Size = UDim2.new(1, -6, 0, 62)
modeFrame.BackgroundTransparency = 1
modeFrame.Visible = false
modeFrame.Parent = itemPage
local mode1 = pageButton(modeFrame, "  1. Jalan (dari base)", 1)
mode1.Size = UDim2.new(1, 0, 0, 28)
mode1.Position = UDim2.new(0, 0, 0, 0)
local mode2 = pageButton(modeFrame, "  2. Teleport cepat", 2)
mode2.Size = UDim2.new(1, 0, 0, 28)
mode2.Position = UDim2.new(0, 0, 0, 34)

local setBaseBtn = pageButton(itemPage, "  Set Base (posisi sekarang)", 3, 26)
setBaseBtn.BackgroundColor3 = Color3.fromRGB(80, 60, 110)

local itemInfo = Instance.new("TextLabel")
itemInfo.LayoutOrder = 4
itemInfo.Size = UDim2.new(1, -6, 0, 108)
itemInfo.BackgroundTransparency = 1
itemInfo.TextWrapped = true
itemInfo.TextXAlignment = Enum.TextXAlignment.Left
itemInfo.TextYAlignment = Enum.TextYAlignment.Top
itemInfo.Font = Enum.Font.Gotham
itemInfo.TextSize = 12
itemInfo.TextColor3 = Color3.fromRGB(200, 200, 210)
itemInfo.Text = "Base: belum diset"
itemInfo.Parent = itemPage

-- Halaman Level (auto level up)
local levelPage = Instance.new("ScrollingFrame")
levelPage.Size = UDim2.new(1, -16, 1, -88)
levelPage.Position = UDim2.new(0, 8, 0, 82)
levelPage.BackgroundTransparency = 1
levelPage.BorderSizePixel = 0
levelPage.ScrollBarThickness = 4
levelPage.CanvasSize = UDim2.new(0, 0, 0, 0)
levelPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
levelPage.Visible = false
levelPage.Parent = body
do
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 5)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = levelPage
end

local levelToggle = pageButton(levelPage, "  Auto Level Up  [OFF]", 1)

local function inputRow(order, labelText, default)
    local row = Instance.new("Frame")
    row.LayoutOrder = order
    row.Size = UDim2.new(1, -6, 0, 26)
    row.BackgroundTransparency = 1
    row.Parent = levelPage
    local lab = Instance.new("TextLabel")
    lab.Size = UDim2.new(1, -74, 1, 0)
    lab.BackgroundTransparency = 1
    lab.Text = labelText
    lab.TextColor3 = Color3.fromRGB(200, 200, 210)
    lab.Font = Enum.Font.Gotham
    lab.TextSize = 12
    lab.TextXAlignment = Enum.TextXAlignment.Left
    lab.TextTruncate = Enum.TextTruncate.AtEnd
    lab.Parent = row
    local tb = Instance.new("TextBox")
    tb.Size = UDim2.new(0, 68, 1, 0)
    tb.Position = UDim2.new(1, -68, 0, 0)
    tb.BackgroundColor3 = Color3.fromRGB(55, 55, 70)
    tb.TextColor3 = Color3.new(1, 1, 1)
    tb.Font = Enum.Font.GothamBold
    tb.TextSize = 13
    tb.ClearTextOnFocus = false
    tb.Text = tostring(default)
    tb.Parent = row
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 5)
    return tb
end
local multBox = inputRow(2, "Uang min (x harga box)", levelMult)
local lvlBox = inputRow(3, "Level target unit", levelTarget)
local protectBox = inputRow(4, "Unit teratas dilindungi", levelProtect)
local calBox = inputRow(5, "Uang di layar (kalibrasi)", "")
calBox.PlaceholderText = "598.05T"

local levelInfo = Instance.new("TextLabel")
levelInfo.LayoutOrder = 6
levelInfo.Size = UDim2.new(1, -6, 0, 104)
levelInfo.BackgroundTransparency = 1
levelInfo.TextWrapped = true
levelInfo.TextXAlignment = Enum.TextXAlignment.Left
levelInfo.TextYAlignment = Enum.TextYAlignment.Top
levelInfo.Font = Enum.Font.Gotham
levelInfo.TextSize = 12
levelInfo.TextColor3 = Color3.fromRGB(200, 200, 210)
levelInfo.Text = "idle"
levelInfo.Parent = levelPage

local function showTab(which)
    boxList.Visible = (which == "box")
    varPage.Visible = (which == "var")
    itemPage.Visible = (which == "item")
    levelPage.Visible = (which == "level")
    tabBox.BackgroundColor3 = (which == "box") and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(55, 55, 70)
    tabVar.BackgroundColor3 = (which == "var") and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(55, 55, 70)
    tabItem.BackgroundColor3 = (which == "item") and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(55, 55, 70)
    tabLevel.BackgroundColor3 = (which == "level") and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(55, 55, 70)
end
tabBox.MouseButton1Click:Connect(function() showTab("box") end)
tabVar.MouseButton1Click:Connect(function() showTab("var") end)
tabItem.MouseButton1Click:Connect(function() showTab("item") end)
tabLevel.MouseButton1Click:Connect(function() showTab("level") end)

local function setStatus(text)
    status.Text = "Status: " .. text
end

local function styleToggle(btn, on)
    btn.BackgroundColor3 = on and Color3.fromRGB(40, 140, 70) or Color3.fromRGB(55, 55, 70)
end

local boxButtons, varButtons = {}, {}
local boxIndex, varIndex = {}, {}
local boxCfgButtons = {}
local configBox = BOXES[1] -- box yang sedang diatur mutasinya

local function refreshBtn(btn, i, name, on)
    btn.Text = "  " .. i .. ". " .. name .. (on and "  [ON]" or "  [OFF]")
    styleToggle(btn, on)
end

local function baseline()
    -- objek yang sudah ada saat pilihan berubah tidak dihitung; hanya yang baru muncul akibat roll
    local hits = scanConveyor(false)
    ignoreHits(hits)
end

local function varBadge(box)
    local n = boxVarCount(box)
    return n == 0 and "Mutasi" or ("Mutasi:" .. n)
end

local function refreshVarPage()
    local n = boxVarCount(configBox)
    varTitle.Text = configBox .. (n == 0 and " (semua mutasi)" or (" (" .. n .. " mutasi)"))
    styleToggle(varTitle, selected[configBox])
    for i, v in ipairs(VARIANTS) do
        if varButtons[v] then refreshBtn(varButtons[v], i, v, selectedVar[configBox][v]) end
    end
    if boxCfgButtons[configBox] then boxCfgButtons[configBox].Text = varBadge(configBox) end
end

local function setBox(name, on)
    selected[name] = on
    refreshBtn(boxButtons[name], boxIndex[name], name, on)
    if name == configBox then refreshVarPage() end
end

local function openVarPage(name)
    configBox = name
    refreshVarPage()
    showTab("var")
end

local function makeToggle(parent, i, name, store, indexMap, onClick)
    local btn = Instance.new("TextButton")
    btn.LayoutOrder = i
    btn.Size = UDim2.new(1, -6, 0, 26)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 13
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    store[name] = btn
    indexMap[name] = i
    refreshBtn(btn, i, name, false)
    btn.MouseButton1Click:Connect(onClick)
    return btn
end

-- baris box: tombol pilih box + tombol "Mutasi" untuk mengatur mutasi khusus box itu
for i, name in ipairs(BOXES) do
    local row = Instance.new("Frame")
    row.LayoutOrder = i
    row.Size = UDim2.new(1, -6, 0, 26)
    row.BackgroundTransparency = 1
    row.Parent = boxList

    local btn = makeToggle(row, i, name, boxButtons, boxIndex, function()
        setBox(name, not selected[name])
        baseline()
    end)
    btn.Size = UDim2.new(1, -62, 1, 0)

    local cfg = Instance.new("TextButton")
    cfg.Size = UDim2.new(0, 58, 1, 0)
    cfg.Position = UDim2.new(1, -58, 0, 0)
    cfg.BackgroundColor3 = Color3.fromRGB(70, 60, 110)
    cfg.TextColor3 = Color3.new(1, 1, 1)
    cfg.Font = Enum.Font.GothamBold
    cfg.TextSize = 11
    cfg.Text = varBadge(name)
    cfg.Parent = row
    Instance.new("UICorner", cfg).CornerRadius = UDim.new(0, 5)
    boxCfgButtons[name] = cfg
    cfg.MouseButton1Click:Connect(function() openVarPage(name) end)
end

-- daftar mutasi (berlaku untuk configBox)
for i, v in ipairs(VARIANTS) do
    makeToggle(varList, i, v, varButtons, varIndex, function()
        selectedVar[configBox][v] = not selectedVar[configBox][v]
        refreshVarPage()
        baseline()
    end)
end

varPrev.MouseButton1Click:Connect(function()
    local idx = table.find(BOXES, configBox) or 1
    configBox = BOXES[((idx - 2) % #BOXES) + 1]
    refreshVarPage()
end)
varNext.MouseButton1Click:Connect(function()
    local idx = table.find(BOXES, configBox) or 1
    configBox = BOXES[(idx % #BOXES) + 1]
    refreshVarPage()
end)
varTitle.MouseButton1Click:Connect(function() -- ketuk judul = nyalakan/matikan box ini
    setBox(configBox, not selected[configBox])
    baseline()
end)
varClear.MouseButton1Click:Connect(function()
    for _, v in ipairs(VARIANTS) do selectedVar[configBox][v] = false end
    refreshVarPage()
    baseline()
end)
refreshVarPage()

---------------------------------------------------------------------
-- AUTO AMBIL ITEM
---------------------------------------------------------------------
local remoteCache = {}
local function getRemote(name)
    local r = remoteCache[name]
    if r and r.Parent then return r end
    r = Remotes:FindFirstChild(name) or Remotes:WaitForChild(name, 3)
    remoteCache[name] = r
    return r
end

local function getCharParts()
    local c = player.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local hrp = c and c:FindFirstChild("HumanoidRootPart")
    if hum and hrp and hum.Health > 0 then return hum, hrp end
    return nil, nil
end

local function itemPosition(item)
    if item:IsA("BasePart") then return item.Position end
    if item:IsA("Model") then return item:GetPivot().Position end
    return nil
end

-- item dianggap tampak jika ada part, ikon billboard/surface, decal, atau efek yang aktif
-- (part spawn sering transparan sementara ikonnya ada di BillboardGui)
local function itemVisible(item)
    local list = item:GetDescendants()
    table.insert(list, item)
    for _, d in ipairs(list) do
        if d:IsA("BasePart") and d.Transparency < 1 then return true end
        if (d:IsA("BillboardGui") or d:IsA("SurfaceGui")) and d.Enabled then return true end
        if (d:IsA("Decal") or d:IsA("Texture")) and d.Transparency < 1 then return true end
        if d:IsA("ParticleEmitter") and d.Enabled then return true end
    end
    return false
end

local function itemActive(item)
    if not item.Parent then return false end
    local t = collectedAt[item]
    if t and os.clock() - t < COLLECT_COOLDOWN then return false end
    -- titik spawn menandai item aktif lewat atribut Occupied (true = ada item)
    local occ = item:GetAttribute("Occupied")
    if occ ~= nil then
        return occ == true and itemPosition(item) ~= nil
    end
    if item:GetAttribute("Collected") == true then return false end
    if REQUIRE_VISIBLE and not itemVisible(item) then return false end
    return itemPosition(item) ~= nil
end

local itemStats = {}

local function findItems()
    local items = {}
    local systems = workspace:FindFirstChild("Systems")
    for si, src in ipairs(COLLECT_SOURCES) do
        local folder = systems and systems:FindFirstChild(src.folder)
        if folder then
            local kids = folder:GetChildren()
            local active = 0
            for _, item in ipairs(kids) do
                if itemActive(item) then
                    active += 1
                    table.insert(items, { inst = item, remote = src.remote, prio = si, label = src.label })
                end
            end
            itemStats[src.label] = active .. "/" .. #kids
        else
            itemStats[src.label] = "folder tidak ada"
        end
    end
    local origin = baseCF and baseCF.Position
    table.sort(items, function(x, y)
        if x.prio ~= y.prio then return x.prio < y.prio end
        if not origin then return false end
        return (itemPosition(x.inst) - origin).Magnitude < (itemPosition(y.inst) - origin).Magnitude
    end)
    return items
end

local function setAction(t)
    actionText = t
end

local function stillOccupied(inst)
    if not inst.Parent then return false end
    local o = inst:GetAttribute("Occupied")
    return o == nil or o == true
end

local function horizDist(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function teleportTo(cf)
    local _, hrp = getCharParts()
    if hrp then
        hrp.CFrame = cf
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
    return hrp
end

-- Tandai rintangan untuk pencari jalur:
--  - speed track / sabuk (part diam yang bergerak) = biaya tinggi (dihindari)
--  - area bahaya (nama memuat tower/portal/obby) = tidak dilewati
local obstacleStats = { belts = 0, hazards = 0 }
local obstacleSamples = { belts = {}, hazards = {} }
local obstacleTagged = setmetatable({}, { __mode = "k" })
local obstacleScanning, lastObstacleScan = false, 0

local function tagPart(d, label, kind)
    if obstacleTagged[d] then return end
    obstacleTagged[d] = true
    local ok = pcall(function()
        local m = Instance.new("PathfindingModifier")
        m.Label = label
        m.Parent = d
    end)
    if ok then
        obstacleStats[kind] += 1
        if #obstacleSamples[kind] < 10 then table.insert(obstacleSamples[kind], d:GetFullName()) end
    end
end

local function markObstacles(force)
    if not AVOID_BELTS or obstacleScanning then return end
    if not force and os.clock() - lastObstacleScan < 90 then return end
    obstacleScanning, lastObstacleScan = true, os.clock()
    task.spawn(function()
        local n = 0
        local hazardRoots = {}
        local plot = getPlot()
        for _, d in ipairs(workspace:GetDescendants()) do
            n += 1
            if n % 2500 == 0 then task.wait() end
            if d:IsA("BasePart") then
                if d.Anchored and d.AssemblyLinearVelocity.Magnitude > 1 then
                    tagPart(d, "SpeedTrack", "belts")
                end
            elseif (d:IsA("Model") or d:IsA("Folder")) and containsAny(d.Name, HAZARD_NAME_HINTS) then
                local mine = plot and (d == plot or d:IsDescendantOf(plot))
                local hasChar = player.Character and (d == player.Character or player.Character:IsDescendantOf(d))
                if not mine and not hasChar then table.insert(hazardRoots, d) end
            end
        end
        for _, root in ipairs(hazardRoots) do
            local list = root:GetDescendants()
            if #list <= 3000 then
                for i, d in ipairs(list) do
                    if i % 2500 == 0 then task.wait() end
                    if d:IsA("BasePart") then tagPart(d, "Hazard", "hazards") end
                end
            end
        end
        obstacleScanning = false
    end)
end

local function computePath(from, to)
    local path = PathfindingService:CreatePath({
        AgentRadius = 3,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentCanClimb = true,
        WaypointSpacing = 5,
        Costs = { SpeedTrack = 30, Hazard = math.huge },
    })
    local ok = pcall(function()
        path:ComputeAsync(from, to)
    end)
    if ok and path.Status == Enum.PathStatus.Success then
        return path:GetWaypoints()
    end
    return nil
end

-- coba keluar saat tersangkut: lompat, bergeser ke samping/belakang, lalu lompat lagi
local function unstick(hum, hrp)
    hum.Jump = true
    local cf = hrp.CFrame
    for _, v in ipairs({ -cf.LookVector, cf.RightVector, -cf.RightVector }) do
        hum:MoveTo(hrp.Position + v * 8)
        local t = os.clock()
        while os.clock() - t < 0.8 do task.wait(0.1) end
        hum.Jump = true
    end
end

-- jalan ke posisi (jarak mendatar <= 4 = sampai).
-- Jalur dihitung ulang jika terdorong/melenceng (speed track, rintangan); menyerah jika tidak ada kemajuan.
local function walkTo(pos, abortFn)
    local baseY = baseCF and baseCF.Position.Y or pos.Y
    local target = Vector3.new(pos.X, baseY, pos.Z)
    local t0, bestDist, bestAt = os.clock(), math.huge, os.clock()
    local escapes = 0
    while os.clock() - t0 < TRIP_TIMEOUT do
        if abortFn() then return false end
        local hum, hrp = getCharParts()
        if not hum then return false end
        local d = horizDist(hrp.Position, pos)
        if d <= 4 then return true end
        if d < bestDist - 3 then bestDist, bestAt = d, os.clock() end
        if os.clock() - bestAt > STUCK_TIME then -- macet
            escapes += 1
            if escapes > 2 then return false end
            setAction("tersangkut, mencoba keluar (" .. escapes .. ")")
            unstick(hum, hrp)
            bestAt, bestDist = os.clock(), math.huge
        end

        local wps = computePath(hrp.Position, target)
        if not wps then
            wps = { { Position = target, Action = Enum.PathWaypointAction.Walk } } -- tanpa jalur: jalan lurus
        end
        local replan = false
        for i, wp in ipairs(wps) do
            if not (i == 1 and #wps > 1) then
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                hum:MoveTo(wp.Position)
                local t1, minD = os.clock(), math.huge
                while true do
                    if abortFn() then return false end
                    hum, hrp = getCharParts()
                    if not hum then return false end
                    if horizDist(hrp.Position, pos) <= 4 then return true end
                    local dw = horizDist(hrp.Position, wp.Position)
                    if dw <= 3.5 then break end
                    if dw < minD then
                        minD = dw
                    elseif dw > minD + 6 then
                        replan = true -- terdorong menjauh dari waypoint
                        break
                    end
                    if os.clock() - t1 > WALK_STALL then
                        replan = true -- waypoint tidak tercapai
                        break
                    end
                    task.wait(0.05)
                end
                if replan then
                    hum.Jump = true
                    break
                end
            end
        end
    end
    return false
end

local function fireCollect(entry)
    local r = getRemote(entry.remote)
    if r then
        pcall(function()
            r:FireServer(entry.inst)
        end)
        return true
    end
    return false
end

-- tunggu server menandai titik spawn kosong (Occupied = false) = pengambilan berhasil
local function waitUnoccupied(inst)
    local t0 = os.clock()
    while os.clock() - t0 < CONFIRM_WAIT do
        if not inst.Parent or inst:GetAttribute("Occupied") == false then return true end
        task.wait(0.05)
    end
    return false
end

local function collectOne(entry)
    local inst = entry.inst
    local pos = itemPosition(inst)
    if not pos then return end
    local hum, hrp = getCharParts()
    if not hum then return end
    if not baseCF then baseCF = hrp.CFrame end

    local name = entry.label .. ":" .. inst.Name
    local hasOcc = inst:GetAttribute("Occupied") ~= nil
    local fired, confirmed = false, false
    local earlyFires, lastEarly, lastShow = 0, 0, 0

    local function itemGone() return not stillOccupied(inst) end
    local function abortAny() return not collectOn end
    -- dipanggil terus saat berjalan: batalkan jika item hilang; coba ambil begitu sudah dekat
    local function abortItem()
        if not collectOn then return true end
        if itemGone() then
            if fired and hasOcc and inst.Parent and inst:GetAttribute("Occupied") == false then
                confirmed = true
            end
            return true
        end
        local _, h = getCharParts()
        if h and earlyFires < 3 and os.clock() - lastEarly > 0.7
            and (h.Position - pos).Magnitude <= EARLY_FIRE_RANGE then
            earlyFires += 1
            lastEarly = os.clock()
            setAction("mengambil " .. name)
            if fireCollect(entry) then fired = true end
        elseif h and os.clock() - lastShow > 0.5 then
            lastShow = os.clock()
            setAction(string.format("jalan ke %s (jarak %d)", name, math.floor((h.Position - pos).Magnitude)))
        end
        return false
    end
    if abortItem() then return end

    local function grabByTeleport()
        setAction("teleport ke " .. name)
        -- Part yang di-anchor TIDAK mengirim posisinya ke server, jadi karakter tidak di-anchor.
        -- Posisi ditahan lewat Heartbeat supaya tidak jatuh dan terbaca server di dekat item.
        local holding = true
        local conn = RunService.Heartbeat:Connect(function()
            local _, hh = getCharParts()
            if hh and holding then
                hh.AssemblyLinearVelocity = Vector3.zero
                hh.CFrame = CFrame.new(pos)
            end
        end)
        teleportTo(CFrame.new(pos))
        task.wait(TP_STAY)
        setAction("mengambil " .. name)
        for _ = 1, 3 do
            if fireCollect(entry) then fired = true end
            if not hasOcc then break end
            if waitUnoccupied(inst) then
                confirmed = true
                break
            end
            task.wait(0.1)
        end
        holding = false
        conn:Disconnect()
    end

    if collectMode == "tp" then
        grabByTeleport()
        teleportTo(baseCF)
    else
        setAction("jalan ke " .. name)
        markObstacles(false)
        local reached = walkTo(pos, abortItem)
        if reached then
            if not confirmed then
                setAction("mengambil " .. name)
                task.wait(0.15) -- diam sebentar agar posisi terbaca server
                for _ = 1, 3 do
                    if fireCollect(entry) then fired = true end
                    if not hasOcc then break end
                    if waitUnoccupied(inst) then
                        confirmed = true
                        break
                    end
                    task.wait(0.1)
                end
            end
        elseif not confirmed and WALK_FALLBACK_TP and collectOn and not itemGone() then
            setAction("jalan macet, teleport ke " .. name)
            grabByTeleport()
        end
        if collectOn then
            setAction("kembali ke base")
            if not walkTo(baseCF.Position, abortAny) and collectOn then
                teleportTo(baseCF)
            end
        end
    end

    if fired then collectTried += 1 end
    if confirmed or (fired and not hasOcc) then
        collectCount += 1
        setAction("berhasil: " .. name)
    elseif fired then
        collectedAt[inst] = os.clock()
        setAction("tidak terkonfirmasi (server menolak?): " .. name)
    elseif itemGone() then
        setAction("item hilang sebelum sampai: " .. name)
    else
        collectedAt[inst] = os.clock()
        setAction("gagal sampai: " .. name)
    end
end

local function updateItemInfo()
    local lines = { "Base: " .. (baseCF and "sudah diset" or "belum diset") }
    for _, src in ipairs(COLLECT_SOURCES) do
        table.insert(lines, src.label .. " (aktif/total): " .. (itemStats[src.label] or "-"))
    end
    table.insert(lines, "Diambil: " .. collectCount .. " (percobaan: " .. collectTried .. ")")
    table.insert(lines, "Aksi: " .. actionText)
    table.insert(lines, "Dihindari: sabuk " .. obstacleStats.belts .. " | bahaya " .. obstacleStats.hazards)
    itemInfo.Text = table.concat(lines, "\n")
end

local function refreshModeButtons()
    mode1.BackgroundColor3 = (collectMode == "walk") and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(55, 55, 70)
    mode2.BackgroundColor3 = (collectMode == "tp") and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(55, 55, 70)
end
refreshModeButtons()

collectToggle.MouseButton1Click:Connect(function()
    collectOn = not collectOn
    collectToggle.Text = "  Auto Ambil Item  " .. (collectOn and "[ON]" or "[OFF]")
    styleToggle(collectToggle, collectOn)
    modeFrame.Visible = collectOn
    if collectOn then
        local _, hrp = getCharParts()
        if hrp then baseCF = hrp.CFrame end -- posisi saat ON = base
        markObstacles(false)
    end
    updateItemInfo()
end)

mode1.MouseButton1Click:Connect(function()
    collectMode = "walk"
    refreshModeButtons()
end)
mode2.MouseButton1Click:Connect(function()
    collectMode = "tp"
    refreshModeButtons()
end)

setBaseBtn.MouseButton1Click:Connect(function()
    local _, hrp = getCharParts()
    if hrp then baseCF = hrp.CFrame end
    updateItemInfo()
end)

task.spawn(function()
    while alive and gui.Parent do
        if collectOn then
            local ok, err = pcall(function()
                local items = findItems()
                lastItemCount = #items
                if #items == 0 then setAction("menunggu item") end
                for _, entry in ipairs(items) do
                    if not collectOn then break end
                    if itemActive(entry.inst) then
                        local okOne, errOne = pcall(collectOne, entry)
                        if not okOne then
                            collectedAt[entry.inst] = os.clock()
                            setAction("error: " .. tostring(errOne))
                            warn("ZetLee error: " .. tostring(errOne))
                        end
                        local _, h = getCharParts()
                        if h and h.Anchored then h.Anchored = false end
                    end
                end
            end)
            if not ok then
                setAction("error: " .. tostring(err))
                warn("ZetLee error: " .. tostring(err))
            end
        end
        if not minimized then updateItemInfo() end
        task.wait(0.25)
    end
end)

---------------------------------------------------------------------
-- PEREKAM EVENT (hasilnya ikut tercetak di laporan Debug)
-- Mencatat: perubahan pada folder item, objek baru di dekat titik spawn, dan event dari server
---------------------------------------------------------------------
local evLog = {}
local function logEv(msg)
    table.insert(evLog, string.format("[%.1f] %s", os.clock() % 10000, msg))
    if #evLog > 150 then table.remove(evLog, 1) end
end

local throttleMap = {}
local function throttled(key)
    local now = os.clock()
    if throttleMap[key] and now - throttleMap[key] < 1 then return true end
    throttleMap[key] = now
    return false
end

local function brief(v)
    local t = typeof(v)
    if t == "Instance" then return v:GetFullName() end
    if t == "table" then
        local n = 0
        for _ in pairs(v) do n += 1 end
        return "table(" .. n .. ")"
    end
    return tostring(v)
end

local WATCH_PROPS = { Transparency = true, CanTouch = true, CanCollide = true, Position = true, Parent = true, Size = true }

local function hookInstance(inst, tag)
    pcall(function()
        inst.AttributeChanged:Connect(function(attr)
            logEv(tag .. " attr " .. attr .. "=" .. tostring(inst:GetAttribute(attr)))
        end)
        inst.Changed:Connect(function(prop)
            if WATCH_PROPS[prop] and not throttled(tag .. prop) then
                local ok, v = pcall(function() return inst[prop] end)
                logEv(tag .. " " .. prop .. "=" .. (ok and brief(v) or "?"))
            end
        end)
    end)
end

local function watchFolder(src)
    local systems = workspace:FindFirstChild("Systems") or workspace:WaitForChild("Systems", 5)
    local folder = systems and (systems:FindFirstChild(src.folder) or systems:WaitForChild(src.folder, 5))
    if not folder then
        logEv("folder " .. src.folder .. " tidak ditemukan")
        return
    end
    for _, d in ipairs(folder:GetDescendants()) do hookInstance(d, src.label .. ":" .. d.Name) end
    folder.DescendantAdded:Connect(function(d)
        logEv(src.label .. " +" .. d.ClassName .. " " .. d:GetFullName())
        hookInstance(d, src.label .. ":" .. d.Name)
    end)
    folder.DescendantRemoving:Connect(function(d)
        logEv(src.label .. " -" .. d.ClassName .. " " .. d.Name)
    end)
end
for _, src in ipairs(COLLECT_SOURCES) do task.spawn(watchFolder, src) end

-- objek baru yang muncul dalam radius 20 stud dari titik spawn manapun
local function nearSpawn(pos)
    local systems = workspace:FindFirstChild("Systems")
    if not systems then return nil end
    for _, src in ipairs(COLLECT_SOURCES) do
        local folder = systems:FindFirstChild(src.folder)
        if folder then
            for _, c in ipairs(folder:GetChildren()) do
                local cp = itemPosition(c)
                if cp and (cp - pos).Magnitude <= 20 then return src.label .. ":" .. c.Name end
            end
        end
    end
    return nil
end

workspace.DescendantAdded:Connect(function(d)
    if not (d:IsA("BasePart") or d:IsA("Model")) then return end
    if player.Character and d:IsDescendantOf(player.Character) then return end
    local mapRoot = workspace:FindFirstChild("Map")
    if mapRoot and d:IsDescendantOf(mapRoot) then return end
    local pos = itemPosition(d)
    if not pos then return end
    local near = nearSpawn(pos)
    if near and not throttled("add" .. d.Name) then
        logEv("BARU dekat " .. near .. ": " .. d.ClassName .. " " .. d:GetFullName())
    end
end)

-- event dari server (maks 3 baris per remote per detik)
local rateMap = {}
local LOG_REMOTE_HINTS = { "variant", "collect", "spawn", "token", "rain", "item" }
for _, r in ipairs(Remotes:GetChildren()) do
    if r:IsA("RemoteEvent") and containsAny(r.Name, LOG_REMOTE_HINTS) then
        pcall(function()
            r.OnClientEvent:Connect(function(...)
                local now = os.clock()
                local rm = rateMap[r.Name]
                if not rm or now - rm.t >= 1 then
                    rm = { t = now, n = 0 }
                    rateMap[r.Name] = rm
                end
                rm.n += 1
                if rm.n > 3 then return end
                local parts = {}
                for i = 1, math.min(select("#", ...), 4) do
                    table.insert(parts, brief((select(i, ...))))
                end
                logEv("REMOTE " .. r.Name .. "(" .. table.concat(parts, ", ") .. ")")
            end)
        end)
    end
end

---------------------------------------------------------------------
-- AUTO LEVEL UP
-- Urutan wajib: 1 beli box -> 2 keluarkan unit income terendah -> 3 taruh box -> 4 buka box
--               -> 5 level up -> 6 equip best. Jika satu langkah gagal, langkah berikutnya tidak jalan.
---------------------------------------------------------------------
local AMOUNT_SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15, qd = 1e15, qi = 1e18, qn = 1e18, sx = 1e21, sp = 1e24, oc = 1e27, no = 1e30, dc = 1e33 }
local SUFFIX_ORDER = {
    { 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" },
    { 1e18, "Qn" }, { 1e15, "Qd" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" },
}

-- "$4.41B/Drop" -> 4.41e9 ; "36.13T" -> 36.13e12 ; nil jika bukan angka
local function parseAmount(text)
    local num, suf = string.match(text, "(%d[%d%.,]*)%s*(%a*)")
    if not num then return nil end
    num = string.gsub(num, ",", "")
    local n = tonumber(num)
    if not n then return nil end
    suf = string.lower(suf or "")
    if suf == "" then return n end
    local m = AMOUNT_SUFFIX[suf]
    if not m then return nil end
    return n * m
end

local function formatAmount(n)
    if not n then return "?" end
    for _, pr in ipairs(SUFFIX_ORDER) do
        if n >= pr[1] then return string.format("%.2f%s", n / pr[1], pr[2]) end
    end
    return tostring(math.floor(n))
end

local function parseCountdown(text)
    local h, m, sec = string.match(text, "(%d+):(%d+):(%d+)")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec) end
    m, sec = string.match(text, "(%d+):(%d+)")
    if m then return tonumber(m) * 60 + tonumber(sec) end
    local only = string.match(text, "^%s*(%d+)%s*[sS]%s*$")
    if only then return tonumber(only) end
    return nil
end

-- uang pemain: label uang yang tampil di layar (kiri bawah) -> atribut -> Value di bawah pemain
local CASH_NAMES = { "cash", "money", "coins" }
local CASH_LABEL_PATH = { "FrontGui", "LeftBottomFrame", "CashHolder", "ImageLabel", "AmountLabel" }
local AMOUNT_PATTERN = "^%s*%$?%s*%d[%d%.,]*%s*%a*%s*$"
local cashLabelCache = nil
local cashCacheAt = 0
local cashCal = nil -- label hasil kalibrasi manual (kolom "Uang di layar")

local function guiShown(d)
    local p = d
    while p do
        if p:IsA("GuiObject") and not p.Visible then return false end
        if p:IsA("LayerCollector") and not p.Enabled then return false end
        p = p.Parent
    end
    return true
end

-- skor label sebagai kandidat uang: posisi kiri-bawah layar (+10), nama memuat cash/money (+5)
local function cashScore(d, vp)
    local pos, size = d.AbsolutePosition, d.AbsoluteSize
    local cx, cy = (pos.X + size.X / 2) / vp.X, (pos.Y + size.Y / 2) / vp.Y
    local score = 0
    if cx < 0.4 and cy > 0.75 then score += 10 end
    if containsAny(d.Name, CASH_NAMES) then score += 5 end
    score += math.min(d.TextSize, 60) / 100
    return score, cx, cy
end

-- Kandidat: label angka murni yang tampak di layar. Di kiri-bawah dipilih NILAI TERBESAR
-- (dompet selalu lebih besar dari label kecil lain seperti hadiah/popup); jika tidak ada, nilai terbesar di layar.
local function findCashLabel()
    local pg = player:FindFirstChild("PlayerGui")
    local cam = workspace.CurrentCamera
    if not pg or not cam then return nil end
    local vp = cam.ViewportSize
    if vp.X <= 0 or vp.Y <= 0 then return nil end
    local bestLeft, bestLeftVal = nil, 0
    local bestAny, bestAnyVal = nil, 0
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.match(d.Text, AMOUNT_PATTERN) and guiShown(d) then
            local n = parseAmount(d.Text)
            if n and n > 0 and d.AbsoluteSize.X > 1 and d.TextTransparency < 0.95
                and not containsAny(d.Name, { "price", "cost", "reward", "bonus" }) then
                local _, cx, cy = cashScore(d, vp)
                if cx >= 0 and cx <= 1 and cy >= 0 and cy <= 1 then
                    if cx < 0.4 and cy > 0.75 and n > bestLeftVal then bestLeft, bestLeftVal = d, n end
                    if n > bestAnyVal then bestAny, bestAnyVal = d, n end
                end
            end
        end
    end
    return bestLeft or bestAny
end

local function getCash()
    if cashCal and cashCal.Parent then
        local n = parseAmount(cashCal.Text)
        if n and n > 0 then return n, "kalibrasi: " .. cashCal.Name end
    end
    -- label dompet game ini (jalur diketahui dari laporan Debug)
    local node = player:FindFirstChild("PlayerGui")
    for _, nm in ipairs(CASH_LABEL_PATH) do
        node = node and node:FindFirstChild(nm)
    end
    if node and node:IsA("TextLabel") then
        local n = parseAmount(node.Text)
        if n and n > 0 then return n, "label dompet" end
    end
    local cached = cashLabelCache
    if cached and cached.Parent and guiShown(cached) and os.clock() - cashCacheAt < 5 then
        local n = parseAmount(cached.Text)
        if n and n > 0 then return n, "label " .. cached.Name end
    end
    cashLabelCache = findCashLabel()
    cashCacheAt = os.clock()
    if cashLabelCache then
        local n = parseAmount(cashLabelCache.Text)
        if n and n > 0 then return n, "label " .. cashLabelCache.Name end
    end
    for _, k in ipairs({ "Cash", "Money", "Coins" }) do
        local a = player:GetAttribute(k)
        if type(a) == "number" then return a, "atribut " .. k end
    end
    for _, root in ipairs({ player, player:FindFirstChild("leaderstats") }) do
        for _, d in ipairs(root:GetChildren()) do
            if (d:IsA("NumberValue") or d:IsA("IntValue")) and containsAny(d.Name, CASH_NAMES) then
                return d.Value, "value " .. d.Name
            end
        end
    end
    return nil, nil
end

-- harga box dari atribut Price/Cost, atau teks berawalan $ di GUI box
local function readBoxPrice(inst)
    local c = variantContainer(inst)
    for _, o in ipairs({ inst, c }) do
        for _, key in ipairs({ "Price", "Cost" }) do
            local a = o and o:GetAttribute(key)
            if type(a) == "number" then return a end
        end
    end
    local best = nil
    local list = c and c:GetDescendants() or {}
    if c then table.insert(list, c) end
    for _, d in ipairs(list) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.find(d.Text, "%$") and isVisible(d) then
            local n = parseAmount(d.Text)
            if n and (not best or n > best) then best = n end
        end
    end
    return best
end

local function getDroppers()
    local out = {}
    local plot = getPlot()
    if not plot then return out end
    local tc = plot:FindFirstChild("TycoonConveyor", true)
    local conveyors = tc and tc:FindFirstChild("Conveyors")
    if not conveyors then return out end
    for _, conv in ipairs(conveyors:GetChildren()) do
        local dr = conv:FindFirstChild("Droppers")
        if dr then
            for _, d in ipairs(dr:GetChildren()) do table.insert(out, d) end
        end
    end
    return out
end

-- kind: "empty" | "box" (box sedang countdown) | "unit"
local function dropperInfo(d)
    local info = { dropper = d, kind = "empty", income = 0, level = 0, countdown = nil }
    local boxModel = d:FindFirstChild("BoxModel")
    if boxModel then
        info.kind = "box"
        for _, t in ipairs(boxModel:GetDescendants()) do
            if t:IsA("TextLabel") and t.Text ~= "" then
                local cd = parseCountdown(t.Text)
                if cd then info.countdown = cd break end
            end
        end
        return info
    end
    for _, c in ipairs(d:GetChildren()) do
        if c:IsA("Model") and c.Name ~= "DropperTemplate" and c.Name ~= "BoxModel" then
            info.unit = c
            info.kind = "unit"
            break
        end
    end
    if info.kind == "unit" then
        local bb = d:FindFirstChild("PlayerUnitShowcaseBillboard", true)
        if bb then
            for _, t in ipairs(bb:GetDescendants()) do
                if t:IsA("TextLabel") and t.Text ~= "" then
                    local low = string.lower(t.Text)
                    local lv = string.match(low, "level%s*(%d+)") or string.match(low, "lv%.?%s*(%d+)")
                    if lv then info.level = tonumber(lv) end
                    if string.find(low, "/drop", 1, true) or string.find(low, "/s", 1, true) then
                        local n = parseAmount(t.Text)
                        if n then info.income = n end
                    end
                end
            end
        end
    end
    return info
end

local function invokeTimeout(remote, timeout, ...)
    local args = table.pack(...)
    local done, res = false, nil
    task.spawn(function()
        local ok, r = pcall(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end)
        res = ok and r or nil
        done = true
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < timeout do task.wait(0.05) end
    return done, res
end

local function waitUntil(fn, timeout, interval)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if not levelOn then return false end
        if fn() then return true end
        task.wait(interval or 0.2)
    end
    return fn() and true or false
end

local function setLevelStep(n, text)
    levelStatus = string.format("Langkah %d/6: %s", n, text)
end

local function failLevel(step, reason)
    levelLast = string.format("gagal di langkah %d: %s", step, reason)
    levelStatus = levelLast
    levelCooldownUntil = os.clock() + 20
    return false
end

local function runLevelProcedure(hit)
    levelBusy = true
    local ok, err = pcall(function()
        local inst = hit.inst

        -- 1. beli box (uang harus >= levelMult x harga)
        setLevelStep(1, "membeli " .. hit.name)
        local mutation = variantMatches(inst, nil)
        if not mutation then return failLevel(1, "mutasi box tidak terbaca") end
        local price = readBoxPrice(inst)
        if not price then return failLevel(1, "harga box tidak terbaca") end
        if levelMult > 0 then
            local cash = getCash()
            if not cash then
                return failLevel(1, "uang tidak terbaca (isi 'Uang min' = 0 untuk melewati cek, atau lihat Debug)")
            end
            if cash < price * levelMult then
                return failLevel(1, "uang kurang (" .. formatAmount(cash) .. " < " .. levelMult .. "x " .. formatAmount(price) .. ")")
            end
        end
        local rBuy = getRemote("PurchaseConveyorRoll")
        if not rBuy then return failLevel(1, "remote PurchaseConveyorRoll tidak ada") end
        rBuy:FireServer(hit.name, mutation, math.floor(price + 0.5))
        if not waitUntil(function() return not isLive(hit) end, 4, 0.2) then
            return failLevel(1, "pembelian tidak terkonfirmasi")
        end

        -- 2. siapkan slot: pakai dropper kosong, atau keluarkan unit income terendah (top N dilindungi)
        setLevelStep(2, "mencari slot")
        local infos = {}
        for _, d in ipairs(getDroppers()) do table.insert(infos, dropperInfo(d)) end
        if #infos == 0 then return failLevel(2, "dropper tidak ditemukan") end
        local target = nil
        for _, i in ipairs(infos) do
            if i.kind == "empty" then target = i break end
        end
        if not target then
            local units = {}
            for _, i in ipairs(infos) do
                if i.kind == "unit" then
                    if i.income <= 0 then
                        return failLevel(2, "income unit " .. i.dropper.Name .. " tidak terbaca (tidak ada yang dihapus)")
                    end
                    table.insert(units, i)
                end
            end
            table.sort(units, function(a, b) return a.income > b.income end)
            if #units <= levelProtect then
                return failLevel(2, "tidak ada unit yang boleh dikeluarkan (" .. levelProtect .. " teratas dilindungi)")
            end
            local lowest = units[#units]
            setLevelStep(2, "mengeluarkan unit dropper " .. lowest.dropper.Name .. " (" .. formatAmount(lowest.income) .. "/drop)")
            local rRem = getRemote("RemovePlayerUnitFromDropper")
            if not rRem then return failLevel(2, "remote RemovePlayerUnitFromDropper tidak ada") end
            rRem:FireServer(lowest.dropper)
            if not waitUntil(function() return dropperInfo(lowest.dropper).kind == "empty" end, 5, 0.2) then
                return failLevel(2, "unit tidak keluar dari dropper")
            end
            target = lowest
        end

        -- 3. taruh box yang baru dibeli di slot itu
        setLevelStep(3, "menaruh " .. hit.name .. " (" .. mutation .. ") di dropper " .. target.dropper.Name)
        local rPlace = getRemote("PlaceBoxOnDropper")
        if not rPlace then return failLevel(3, "remote PlaceBoxOnDropper tidak ada") end
        rPlace:FireServer(target.dropper, hit.name, mutation)
        if not waitUntil(function() return dropperInfo(target.dropper).kind == "box" end, 5, 0.2) then
            return failLevel(3, "box tidak muncul di dropper")
        end

        -- 4. tunggu countdown, lalu buka box
        local rOpen = getRemote("OpenBoxOnDropper")
        if not rOpen then return failLevel(4, "remote OpenBoxOnDropper tidak ada") end
        local t0, opened = os.clock(), false
        while os.clock() - t0 < LEVEL_OPEN_TIMEOUT do
            if not levelOn then return false end
            local di = dropperInfo(target.dropper)
            if di.kind == "unit" then opened = true break end
            if di.countdown and di.countdown > 0 then
                levelStatus = string.format("Langkah 4/6: menunggu countdown %ds", math.floor(di.countdown))
                task.wait(1)
            else
                setLevelStep(4, "membuka box")
                invokeTimeout(rOpen, 5, target.dropper)
                if waitUntil(function() return dropperInfo(target.dropper).kind == "unit" end, 3, 0.2) then
                    opened = true
                    break
                end
                task.wait(2)
            end
        end
        if not opened then return failLevel(4, "box tidak terbuka (timeout)") end

        -- 5. level up unit baru sampai level target
        local rLvl = getRemote("RequestPlayerUnitLevelUp")
        if not rLvl then return failLevel(5, "remote RequestPlayerUnitLevelUp tidak ada") end
        local lastLevel = dropperInfo(target.dropper).level
        if lastLevel <= 0 then return failLevel(5, "level unit tidak terbaca (lihat Debug)") end
        local tLv, noProgress = os.clock(), 0
        while lastLevel < levelTarget do
            if not levelOn then return false end
            if os.clock() - tLv > LEVEL_UP_TIMEOUT then
                return failLevel(5, "timeout di level " .. lastLevel .. " (uang kurang?)")
            end
            setLevelStep(5, "level " .. lastLevel .. "/" .. levelTarget)
            rLvl:FireServer(target.dropper)
            task.wait(0.15)
            local cur = dropperInfo(target.dropper).level
            if cur > lastLevel then
                lastLevel, noProgress = cur, 0
            else
                noProgress += 1
                if noProgress >= 10 then
                    task.wait(3) -- tidak naik: mungkin uang belum cukup, tunggu sebentar
                    noProgress = 0
                end
            end
        end

        -- 6. equip best (urutan unit dari income terendah ke tertinggi)
        setLevelStep(6, "equip best")
        local rEq = getRemote("EquipBestPlayerUnits")
        if not rEq then return failLevel(6, "remote EquipBestPlayerUnits tidak ada") end
        rEq:FireServer()
        task.wait(0.5)
        levelCount += 1
        levelLast = "selesai: " .. hit.name .. " (" .. mutation .. ") di dropper " .. target.dropper.Name
        levelStatus = levelLast
        return true
    end)
    if not ok then
        levelLast = "error: " .. tostring(err)
        levelStatus = levelLast
        levelCooldownUntil = os.clock() + 20
    elseif not levelOn then
        levelStatus = "dihentikan"
    end
    levelBusy = false
end

levelToggle.MouseButton1Click:Connect(function()
    levelOn = not levelOn
    levelToggle.Text = "  Auto Level Up  " .. (levelOn and "[ON]" or "[OFF]")
    styleToggle(levelToggle, levelOn)
    if levelOn then
        levelStatus = "menunggu box terpilih dari auto roll"
        levelCooldownUntil = 0
    end
end)

multBox.FocusLost:Connect(function()
    local n = tonumber(multBox.Text)
    if n and n >= 0 then levelMult = n end
    multBox.Text = tostring(levelMult)
end)
lvlBox.FocusLost:Connect(function()
    local n = tonumber(lvlBox.Text)
    if n and n >= 1 then levelTarget = math.floor(n) end
    lvlBox.Text = tostring(levelTarget)
end)
calBox.FocusLost:Connect(function()
    if calBox.Text == "" then
        cashCal = nil
        levelStatus = "kalibrasi uang dihapus (otomatis)"
        return
    end
    local target = parseAmount(calBox.Text)
    if not target then
        levelStatus = "angka kalibrasi tidak valid (contoh: 598.05T)"
        return
    end
    local pg = player:FindFirstChild("PlayerGui")
    local bestL, bestDiff = nil, nil
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.match(d.Text, AMOUNT_PATTERN) and guiShown(d) then
                local n = parseAmount(d.Text)
                if n and n > 0 then
                    local diff = math.abs(n - target) / target
                    if diff < 0.02 and (not bestDiff or diff < bestDiff) then bestL, bestDiff = d, diff end
                end
            end
        end
    end
    if bestL then
        cashCal = bestL
        levelStatus = "uang terkalibrasi: " .. bestL:GetFullName()
    else
        levelStatus = "tidak ada label dengan nilai itu (samakan dengan angka di layar)"
    end
end)
protectBox.FocusLost:Connect(function()
    local n = tonumber(protectBox.Text)
    if n and n >= 0 then levelProtect = math.floor(n) end
    protectBox.Text = tostring(levelProtect)
end)

task.spawn(function()
    while alive and gui.Parent do
        if levelPage.Visible and not minimized then
            local cash, csrc = getCash()
            levelInfo.Text = table.concat({
                "Uang: " .. (cash and (formatAmount(cash) .. " (" .. tostring(csrc) .. ")") or "tidak terbaca"),
                levelStatus,
                "Selesai: " .. levelCount .. " siklus",
                "Terakhir: " .. levelLast,
            }, "\n")
        end
        task.wait(1.5)
    end
end)

autoBtn.MouseButton1Click:Connect(function()
    autoOn = not autoOn
    paused = false
    pausedHits = {}
    if autoOn then baseline() end
    autoBtn.Text = autoOn and "AUTO: ON" or "AUTO: OFF"
    autoBtn.BackgroundColor3 = autoOn and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(170, 50, 50)
    setStatus(autoOn and "rolling..." or "idle")
end)

resumeBtn.MouseButton1Click:Connect(function()
    if paused then
        ignoreHits(pausedHits)
        paused = false
        pausedHits = {}
        if autoOn then setStatus("rolling...") end
    end
end)

-- Reset: batalkan semua pilihan box dan mutasi
resetBtn.MouseButton1Click:Connect(function()
    paused = false
    pausedHits = {}
    for _, name in ipairs(BOXES) do
        setBox(name, false)
        for _, v in ipairs(VARIANTS) do selectedVar[name][v] = false end
        boxCfgButtons[name].Text = varBadge(name)
    end
    refreshVarPage()
    setStatus(autoOn and "pilihan direset, rolling..." or "pilihan direset")
end)

-- Debug: laporan scan
local function inScope(d, roots)
    for _, r in ipairs(roots) do
        if d == r or d:IsDescendantOf(r) then return true end
    end
    return false
end

debugBtn.MouseButton1Click:Connect(function()
    lastRootScan = 0
    local roots = getScopes(true)
    local lines = { "ZetLee report v4", "Mode: " .. SCOPE_MODE, "Area scan: " .. #roots }
    for i, r in ipairs(roots) do
        if i > 12 then break end
        table.insert(lines, "  area: " .. r:GetFullName())
    end
    local plot = getPlot()
    table.insert(lines, "Plot: " .. (plot and plot:GetFullName() or "TIDAK DITEMUKAN (isi PLOT_NAME)"))
    table.insert(lines, "Struktur area (Model, maks 50):")
    local sc = 0
    for _, r in ipairs(roots) do
        for _, d in ipairs(r:GetDescendants()) do
            if sc >= 50 then break end
            if d:IsA("Model") then
                sc += 1
                table.insert(lines, "  " .. d:GetFullName() .. " | excluded=" .. tostring(isExcluded(d)))
            end
        end
    end
    table.insert(lines, "Tombol beli (maks 10):")
    local pc = 0
    for p in pairs(prompts) do
        if pc >= 10 then break end
        if p.Parent and p:IsDescendantOf(workspace) and isPurchasePrompt(p) then
            pc += 1
            table.insert(lines, "  " .. p:GetFullName() .. " | " .. p.ActionText .. " | " .. p.ObjectText)
        end
    end
    table.insert(lines, "Objek yang cocok nama box di plot/area (maks 60):")
    local count = 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if count >= 60 then break end
        local box = matchBox(d, false)
        if box and inScope(d, roots) then
            count += 1
            local extra = (d:IsA("TextLabel") or d:IsA("TextButton")) and (" | text=" .. d.Text) or ""
            table.insert(lines, string.format("%s | %s | %s | mutasi=%s | visible=%s | excluded=%s | loker=%s%s",
                d:GetFullName(), d.ClassName, box, tostring(variantMatches(d, false)),
                tostring(isVisible(d)), tostring(isExcluded(d)), tostring(inLockerGui(d)), extra))
        end
    end
    table.insert(lines, "Isi Workspace.Systems:")
    local systems = workspace:FindFirstChild("Systems")
    if systems then
        for i, c in ipairs(systems:GetChildren()) do
            if i > 40 then break end
            table.insert(lines, "  " .. c.Name .. " (" .. c.ClassName .. ", " .. #c:GetChildren() .. " anak)")
        end
    else
        table.insert(lines, "  Workspace.Systems TIDAK ADA")
    end
    table.insert(lines, "Item spawn (maks 13 per folder):")
    for _, src in ipairs(COLLECT_SOURCES) do
        local folder = systems and systems:FindFirstChild(src.folder)
        if not folder then
            table.insert(lines, "  " .. src.folder .. ": TIDAK ADA")
        else
            local kids = folder:GetChildren()
            table.insert(lines, "  " .. src.folder .. ": " .. #kids .. " anak")
            for i, k in ipairs(kids) do
                if i > 13 then break end
                local pos = itemPosition(k)
                local desc = {}
                for j, d in ipairs(k:GetDescendants()) do
                    if j > 6 then break end
                    table.insert(desc, d.ClassName .. ":" .. d.Name)
                end
                local attrs = {}
                for ak, av in pairs(k:GetAttributes()) do table.insert(attrs, ak .. "=" .. tostring(av)) end
                local props = "-"
                if k:IsA("BasePart") then
                    props = string.format("CanTouch=%s CanCollide=%s Anchored=%s Size=%s",
                        tostring(k.CanTouch), tostring(k.CanCollide), tostring(k.Anchored), tostring(k.Size))
                end
                table.insert(lines, string.format("    %s | %s | transp=%s | tampak=%s | aktif=%s | pos=%s | %s | attr=%s | isi=%s",
                    k.Name, k.ClassName, k:IsA("BasePart") and tostring(k.Transparency) or "-",
                    tostring(itemVisible(k)), tostring(itemActive(k)), pos and tostring(pos) or "-",
                    props, #attrs > 0 and table.concat(attrs, ",") or "-",
                    #desc > 0 and table.concat(desc, ", ") or "-"))
            end
        end
    end
    local rnames = {}
    for _, r in ipairs(Remotes:GetChildren()) do
        table.insert(rnames, r.Name .. "(" .. (r:IsA("RemoteEvent") and "E" or "F") .. ")")
    end
    table.insert(lines, "Remotes (" .. #rnames .. "): " .. table.concat(rnames, ", "))
    table.insert(lines, "LOG EVENT (terbaru di bawah):")
    for _, l in ipairs(evLog) do table.insert(lines, "  " .. l) end
    table.insert(lines, "Rintangan ditandai: sabuk=" .. obstacleStats.belts .. " bahaya=" .. obstacleStats.hazards)
    for _, nm in ipairs(obstacleSamples.belts) do table.insert(lines, "  sabuk: " .. nm) end
    for _, nm in ipairs(obstacleSamples.hazards) do table.insert(lines, "  bahaya: " .. nm) end
    table.insert(lines, "Dropper (plot sendiri):")
    for _, d in ipairs(getDroppers()) do
        local di = dropperInfo(d)
        local texts = {}
        local src = d:FindFirstChild("PlayerUnitShowcaseBillboard", true) or d:FindFirstChild("BoxModel")
        if src then
            for _, t in ipairs(src:GetDescendants()) do
                if t:IsA("TextLabel") and t.Text ~= "" then table.insert(texts, t.Name .. "=" .. t.Text) end
            end
        end
        table.insert(lines, string.format("  %s | %s | unit=%s | income=%s | level=%s | countdown=%s | %s",
            d.Name, di.kind, di.unit and di.unit.Name or "-", formatAmount(di.income), tostring(di.level),
            tostring(di.countdown), table.concat(texts, "; ")))
    end
    local cashNow, cashSrc = getCash()
    table.insert(lines, "Uang: " .. (cashNow and formatAmount(cashNow) or "TIDAK TERBACA") .. " | sumber=" .. tostring(cashSrc))
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            table.insert(lines, "  leaderstats: " .. v.Name .. " (" .. v.ClassName .. ")" .. (v:IsA("ValueBase") and (" = " .. tostring(v.Value)) or ""))
        end
    end
    for k, v in pairs(player:GetAttributes()) do
        table.insert(lines, "  atribut pemain: " .. k .. " = " .. tostring(v))
    end
    local bp = player:FindFirstChild("Backpack")
    if bp then
        for i, tool in ipairs(bp:GetChildren()) do
            if i > 25 then break end
            local at = {}
            for k, v in pairs(tool:GetAttributes()) do table.insert(at, k .. "=" .. tostring(v)) end
            table.insert(lines, "  tas: " .. tool.Name .. " (" .. tool.ClassName .. ") " .. table.concat(at, ","))
        end
    end
    local pgui = player:FindFirstChild("PlayerGui")
    if pgui then
        local cc = 0
        local camVp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1, 1)
        table.insert(lines, "Label uang terpilih: " .. (cashLabelCache and (cashLabelCache:GetFullName() .. " = " .. cashLabelCache.Text) or "-"))
        table.insert(lines, "Label angka di PlayerGui (kandidat uang, maks 20):")
        for _, d in ipairs(pgui:GetDescendants()) do
            if cc >= 20 then break end
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and guiShown(d) and string.match(d.Text, AMOUNT_PATTERN) then
                cc += 1
                local sc, cx, cy = cashScore(d, camVp)
                table.insert(lines, string.format("  %s | %s | x=%.2f y=%.2f skor=%.2f", d:GetFullName(), d.Text, cx, cy, sc))
            end
        end
    end
    local report = table.concat(lines, "\n")
    print(report)
    local copied = false
    if setclipboard then copied = pcall(setclipboard, report) end
    setStatus(copied and ("laporan disalin (" .. count .. " objek)") or ("laporan dicetak ke console (" .. count .. ")"))
end)

minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.new(0, WIDTH, 0, TITLE_H) or UDim2.new(0, WIDTH, 0, TITLE_H + BODY_H)
    minBtn.Text = minimized and "+" or "-"
end)

do
    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

---------------------------------------------------------------------
-- LOOP UTAMA
---------------------------------------------------------------------
local function seenText(seen)
    local parts = {}
    for _, b in ipairs(BOXES) do
        if seen[b] then
            local vs = {}
            for _, v in ipairs(VARIANTS) do
                if seen[b][v] then table.insert(vs, v) end
            end
            table.insert(parts, b .. (#vs > 0 and ("(" .. table.concat(vs, "/") .. ")") or ""))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "-"
end

local function hitText(h)
    return h.name .. (h.variant and (" (" .. h.variant .. ")") or "")
end

task.spawn(function()
    while alive and gui.Parent do
        local needScan = (autoOn and not paused) or not minimized
        if needScan then
            local hits, rootCount, seen = scanConveyor(true)
            seenLabel.Text = "Terlihat: " .. seenText(seen)

            if autoOn and not paused then
                if rootCount == 0 then
                    setStatus("area conveyor tidak ditemukan (Debug)")
                elseif #hits > 0 then
                    paused = true
                    pausedHits = hits
                    setStatus("berhenti: " .. hitText(hits[1]))
                else
                    setStatus("rolling...")
                    pcall(function()
                        RollRemote:FireServer()
                    end)
                end
            end
        end

        if autoOn and paused then
            local anyLive = false
            for _, h in ipairs(pausedHits) do
                if isLive(h) then anyLive = true break end
            end
            if not anyLive then
                paused = false
                pausedHits = {}
                setStatus("rolling...")
            end
        end

        -- auto level up: beli box terpilih yang membuat auto roll berhenti
        if levelOn and autoOn and paused and not levelBusy and os.clock() >= levelCooldownUntil and pausedHits[1] then
            task.spawn(runLevelProcedure, pausedHits[1])
        end

        task.wait(ROLL_DELAY)
    end
end)
