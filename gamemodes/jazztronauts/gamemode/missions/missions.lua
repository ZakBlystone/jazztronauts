AddCSLuaFile("missions.lua")
AddCSLuaFile("missionlist.lua")

module( "missions", package.seeall )

MissionList = {}
NPCList = {}

function AddMission(id, npcid, mdata)
    id = IndexToMID(id, npcid)
    if not id or not mdata then
        error("Invalid arguments, id or mdata is nil")
        return
    end

    if MissionList[id] then
        error("Mission id ".. id .. " already exists in mission table.")
        return 
    end
    mdata.missionid = id
    mdata.NPCId = npcid
    MissionList[id] = mdata
end

function AddNPC(strname, prettyname)
    local idx = table.insert(NPCList, 
    {
        name = strname,
        prettyname = prettyname
    })
    _G[strname] = idx
end

function IndexToMID(index, npcid)
    return npcid * 1000 + index
end

function MIDToIndex(mid, npcid)
    return mid - 1000 * npcid
end

function GetNPCName(id)
    return NPCList[id] and NPCList[id].name or "Invalid"
end

function GetNPCPrettyName(id)
    return NPCList[id] and NPCList[id].prettyname or "Invalid"
end

function GetMissionInfo(id)
    return MissionList[id]
end

function ResetMissions()
    MissionList = {}
end

-- Load in the mission list now
include("missionlist.lua")

local function isAvailable(mission, history)
    if not mission.Prerequisites or #mission.Prerequisites == 0 then return true end

    for _, v in pairs(mission.Prerequisites) do
        if not history[v] or not history[v].completed then return false end
    end

    return true
end

local function isReadyToTurnIn(mdata)
    local minfo = GetMissionInfo(mdata.missionid)
        
    -- They must have started the mission and not already completed it
    if not mdata or mdata.completed then return false end

    -- They gotta collect ALL of the props
    if mdata.progress < minfo.Count then return false end 

    return true
end

local function filterNPCID(missions, npcid)
    if not npcid then return missions end

    for k, v in pairs(missions) do
        local minfo = v.NPCId and v or MissionList[v.missionid]
        if minfo.NPCId != npcid then 
            missions[k] = nil 
        end
    end

    return missions
end

-- Retrieve a list of missions the player has available to start
function GetAvailableMissions(ply, npcid, h)
    local hist = h or GetMissionHistory(ply)
    local available = table.Copy(MissionList)

    -- Remove accepted/completed missions
    for k, v in pairs(hist) do
        available[k] = nil
    end

    -- Remove missions we don't qualify for
    for k, v in pairs(available) do
        if not isAvailable(v, hist) then 
            available[k] = nil 
        end
    end

    -- Filter missions from other npcids (if requested)
    available = filterNPCID(available, npcid)

    return available
end

-- Retrieve a list of missions the player is currently in progress
function GetActiveMissions(ply, npcid, h, excludeReady)
    local hist = h or GetMissionHistory(ply)
    local active = {}

    -- Insert every mission that is in progress (or ready to turn in)
    for k, v in pairs(hist) do
        local ready = isReadyToTurnIn(v)
        if not v.completed and (not ready or not excludeReady) then 
            active[k] = v
        end
    end
    
    -- Filter missions from other npcids (if requested)
    active = filterNPCID(active, npcid)

    return active
end

-- Retrieve a list of missions the player is ready to turn in
function GetReadyMissions(ply, npcid, h)
    local hist = h or GetMissionHistory(ply)
    local active = {}
 
    -- Insert every mission that is ready to turn in
    for k, v in pairs(hist) do
        if isReadyToTurnIn(v) then
            active[k] = v
        end 
    end

    -- Filter missions from other npcids (if requested)
    active = filterNPCID(active, npcid)

    return active
end

local MISSION_TYPE_SIZE = 64
if SERVER then 
    util.AddNetworkString("jazz_missionupdate")

    -- Try adding a prop to the player's active missions
    -- Returns true if the prop was accepted as a mission prop, false otherwise
    function AddMissionProp(ply, mdl)
        if not IsValid(ply) or not mdl then return false end 

        local addedProp = false
        local missions = GetActiveMissions(ply)
        for k, v in pairs(missions) do
            local minfo = GetMissionInfo(k)
            if minfo.Filter(mdl) then 
                addedProp = true
                _addMissionProgress(ply, k)
            end
        end

        -- Update clientside player mission info
        if addedProp then
            UpdatePlayerMissionInfo(ply)
        end

        return addedProp
    end

    -- Manually increment a specific mission id's progress
    function AddMissionProgress(ply, mid)
        local minfo = GetMissionInfo(mid)
        if not IsValid(ply) or not minfo then return false end

        local added = _addMissionProgress(ply, mid)
        if added then 
            UpdatePlayerMissionInfo(ply)
        end

        return added
    end

    -- Try to complete a mission if requirements are met
    function CompleteMission(ply, mid)
        if not IsValid(ply) then return false end

        local minfo = GetMissionInfo(mid)
        local active = GetMission(ply, mid)
        
        if not isReadyToTurnIn(active, minfo) then return false end
        if not _completeMission(ply, mid) then return false end

        -- Grant the player their reward
        if minfo.OnCompleted then minfo.OnCompleted(ply) end

        UpdatePlayerMissionInfo(ply)
        return true
    end

    -- Try to start a mission if they've completed all the prequisite missions
    function StartMission(ply, mid)
        if not IsValid(ply) then return false end

        local minfo = GetMissionInfo(mid)
        local active = GetMission(ply, mid)
        local avail = GetAvailableMissions(ply)
        
        -- They must not have started the mission before
        if active then return false end

        -- The mission must be available with required prereqs 
        if not avail[mid] then return false end 
        if not _startMission(ply, mid) then return false end

        UpdatePlayerMissionInfo(ply)
        return true
    end

    -- Update the player client about their newest mission data
    -- Includes completed misssions and active mission progress
    function UpdatePlayerMissionInfo(ply)
        local hist = GetMissionHistory(ply)
        local active = {}

        -- Save off the active missions
        for k, v in pairs(hist) do
            if not v.completed then active[k] = v end
        end

        net.Start("jazz_missionupdate")

            -- Seralize finished maps into the bits of an integer
            for i=0, MISSION_TYPE_SIZE do
                net.WriteBit(hist[i] and hist[i].completed)
            end

            -- Send the progress of in-progress missions
            -- array of tuples of <missionId>:<count>
            net.WriteUInt(table.Count(active), 8) -- Count

            -- Write info for each active mission
            for k, v in pairs(active) do
                net.WriteInt(k, 16) -- MissionID
                net.WriteUInt(v.progress, 8) -- Progress
            end

        net.Send(ply)
    end

    -- Receive requests from players to try to start/finish missions
    net.Receive("jazz_missionupdate", function(len, ply)
        local mid = net.ReadUInt(16)
        local tryFinish = net.ReadBit() == 1

        if not mapcontrol.IsInHub() then 
            print(ply:GetNick(), "tried to do mission stuff outside of the hub. ")
            return
        end

        if tryFinish then 
            missions.CompleteMission(ply, mid)
        else
            missions.StartMission(ply, mid)
        end
    end )

elseif CLIENT then 
    Active = Active or {}
    Finished = Finished or {}

    function TryStartMission(mid)
        net.Start("jazz_missionupdate")
            net.WriteUInt(mid, 16)
            net.WriteBit(false)
        net.SendToServer()
    end

    function TryFinishMission(mid)
        net.Start("jazz_missionupdate")
            net.WriteUInt(mid, 16)
            net.WriteBit(true)
        net.SendToServer()
    end

    net.Receive("jazz_missionupdate", function(len, ply)

        -- Read a bitstream of finished maps
        local hist = {}
        local prog = {}

        for i=0, MISSION_TYPE_SIZE do
            local finished = net.ReadBit() == 1
            if finished then hist[i] = i end
        end

        -- Read the number of active missions
        local numActive = net.ReadUInt(8)

        -- Go through and read each mission-progress pair
        for i=1, numActive do
            local mid = net.ReadUInt(16)
            local num = net.ReadUInt(8)

            prog[mid] = num
        end

        Active = prog
        Finished = hist

        hook.Call("JazzMissionsUpdated", GAMEMODE, hist, prog)
    end )
end