local fs = require("filesystem")
local computer = require("computer")
local component = require("component")
local gpu = component.gpu
local w, h = gpu.getResolution()
local T = _G.ngos.theme

local currentDir = "/"
local hitboxes = {}

local function redrawAll()
    hitboxes = {}
    gpu.setBackground(T.bg); gpu.fill(1, 1, w, h, " ")
    
    gpu.setBackground(T.header); gpu.fill(1, 1, w, 1, " ")
    gpu.setForeground(T.headerText)
    gpu.set(2, 1, "NgOS Files - " .. currentDir)
    
    if currentDir ~= "/" then
        gpu.setBackground(T.accent); gpu.setForeground(T.bg)
        gpu.set(2, 3, " [ Up to Parent ] ")
        table.insert(hitboxes, {x1=2, x2=18, y1=3, y2=3, action=function()
            currentDir = fs.path(currentDir:sub(1, -2)) or "/"
            if currentDir ~= "/" and currentDir:sub(-1) ~= "/" then currentDir = currentDir .. "/" end
            redrawAll()
        end})
    end
    
    local y = 5
    for file in fs.list(currentDir) do
        if y > h - 1 then break end
        
        local isDir = fs.isDirectory(currentDir .. file)
        local icon = isDir and "[DIR]" or "[FILE]"
        local color = isDir and T.accent or T.text
        
        gpu.setBackground(T.bg); gpu.setForeground(color)
        gpu.set(3, y, icon .. " " .. file)
        
        table.insert(hitboxes, {x1=3, x2=w-2, y1=y, y2=y, action=function()
            if isDir then
                currentDir = currentDir .. file
                redrawAll()
            elseif file:sub(-4) == ".lua" then
                computer.pushSignal("ngos_launch", currentDir .. file)
            end
        end})
        y = y + 1
    end
end

redrawAll()
while true do
    local evData = { coroutine.yield() }
    local ev = evData[1]
    if ev == "touch" then
        local x, y = evData[3], evData[4]
        for _, box in ipairs(hitboxes) do
            if x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2 then
                box.action(); break
            end
        end
    elseif ev == "refresh" then redrawAll() end
end