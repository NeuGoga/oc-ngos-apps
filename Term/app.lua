local component = require("component")
local computer = require("computer")
local shell = require("shell")
local fs = require("filesystem")
local gpu = component.gpu
local w, h = gpu.getResolution()
local T = _G.ngos.theme

local logs = {"NgOS Terminal v1.1", "Type 'exit' to close."}

local function redrawAll()
    gpu.setBackground(T.bg); gpu.fill(1, 1, w, h, " ")
    gpu.setBackground(T.header); gpu.fill(1, 1, w, 1, " ")
    
    gpu.setForeground(T.headerText)
    gpu.set(2, 1, "Terminal - " .. shell.getWorkingDirectory())
    
    gpu.setBackground(T.bg); gpu.setForeground(T.text)
    
    local logIdx = math.max(1, #logs - (h - 4))
    for y = 2, h - 2 do
        if logs[logIdx] then
            gpu.set(2, y, logs[logIdx]:sub(1, w - 2))
            logIdx = logIdx + 1
        end
    end
end

local function readCommand()
    local input = ""
    while true do
        local cwd = shell.getWorkingDirectory()
        local prompt = cwd .. "> "
        local promptLen = string.len(prompt) + 2
        
        gpu.setBackground(T.bg)
        gpu.setForeground(T.accent)
        gpu.set(2, h-1, prompt)
        
        gpu.setForeground(T.text)
        gpu.set(promptLen, h-1, input .. "   ")
        
        local evData = { coroutine.yield() }
        if evData[1] == "key_down" then
            local char, code = evData[3], evData[4]
            
            if code == 28 then
                return input 
            elseif code == 14 and #input > 0 then
                input = input:sub(1, -2)
            elseif code == 15 then
                local prefix = input:match("(%S+)$") or ""
                local searchDir = cwd
                
                if prefix:find("/") then
                    local lastSlash = prefix:match("^.*()/")
                    searchDir = shell.resolve(prefix:sub(1, lastSlash))
                    prefix = prefix:sub(lastSlash + 1)
                end
                
                local matches = {}
                if fs.isDirectory(searchDir) then
                    for file in fs.list(searchDir) do
                        if file:sub(1, #prefix) == prefix then
                            table.insert(matches, file)
                        end
                    end
                end
                
                if #matches == 1 then
                    input = input .. matches[1]:sub(#prefix + 1)
                elseif #matches > 1 then
                    table.insert(logs, prompt .. input)
                    local mStr = ""
                    for _, m in ipairs(matches) do mStr = mStr .. m .. "  " end
                    table.insert(logs, mStr)
                    redrawAll()
                end
            elseif char >= 32 and char <= 126 and (#input + promptLen) < w then
                input = input .. string.char(char)
            end
            
        elseif evData[1] == "refresh" then
            redrawAll()
        end
    end
end

redrawAll()
while true do
    local cmd = readCommand()
    if cmd == "exit" then break end
    
    table.insert(logs, shell.getWorkingDirectory() .. "> " .. cmd)
    redrawAll()
    
    if cmd ~= "" then
        if cmd:sub(1,3) == "cd " then
            local target = cmd:sub(4)
            local newPath = shell.resolve(target)
            if fs.isDirectory(newPath) then
                shell.setWorkingDirectory(newPath)
            else
                table.insert(logs, "cd: " .. target .. ": No such directory")
            end
        else
            os.execute(cmd .. " > /tmp/term_out.txt 2>&1")
            local f = io.open("/tmp/term_out.txt", "r")
            if f then
                for line in f:lines() do table.insert(logs, line) end
                f:close()
            end
        end
    end
    redrawAll()
end