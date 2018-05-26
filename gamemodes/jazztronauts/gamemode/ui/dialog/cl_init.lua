include("shared.lua")
include("cl_styling.lua")
local ScrW = ScrW
local ScrH = ScrH
local draw = draw
local surface = surface
local math = math
local string = string
local FrameTime = FrameTime
local print = print
local pairs = pairs
local ipairs = ipairs
local net = net
local util = util
local tostring = tostring
local tonumber = tonumber
local unpack = unpack
local coroutine = coroutine
local ErrorNoHalt = ErrorNoHalt
local type = type
local PrintTable = PrintTable


local STATE_IDLE = 0
local STATE_OPENING = 1
local STATE_OPENED = 2
local STATE_PRINTING = 3
local STATE_DONEPRINTING = 4
local STATE_CHOOSE = 5
local STATE_DONECHOOSE = 6
local STATE_CLOSING = 7
local STATE_WAIT = 8
local STATE_EXEC = 9

local _dialog = {
	options = {},
	rate = 1,
	time = 0,
	duration = 1,
	text = "",
	printed = "",
	open = 0,
	nodeiter = nil,
}

module("dialog")

PrintSpeedScale = 1.0

Init()

local State = nil
local DT = nil
local Done = nil
local Time = nil

local function InvokeEvent(eventName, ...)
	if not _dialog.defaultcallbacktbl then return end
	if type(_dialog.defaultcallbacktbl[eventName]) != 'function' then return end

	_dialog.defaultcallbacktbl[eventName](...)
end

function Start( text, delay )

	_dialog.text = text
	_dialog.printed = ""
	State( STATE_OPENING, delay )

end

-- Register a new function that can be executed within a script
function RegisterFunc(name, func)
	if not g_funcs then g_funcs = {} end

	g_funcs[name] = func;
end

--STATE MACHINE

local edges = {
	[STATE_OPENING] = function(d) _ = Done() and State( STATE_OPENED ) end,
	[STATE_OPENED] = function(d) _ = Done() and State( STATE_PRINTING ) end,
	[STATE_PRINTING] = function(d) _ = Done() and State( string.len(d.text) == 0 and STATE_DONEPRINTING or STATE_PRINTING ) end,
	[STATE_CHOOSE] = function(d) _ = Done() and State( STATE_CHOOSE ) end,
	[STATE_DONECHOOSE] = function(d) State( STATE_CLOSING ) end,
	[STATE_CLOSING] = function(d) _ = Done() and State( STATE_IDLE ) end,
	[STATE_WAIT] = function(d) _ = Done() and State( d.nextstate ) end,
	[STATE_EXEC] = function(d) _ = Done() and State( STATE_EXEC ) end,
}

local inits = {
	[STATE_IDLE] = function(d)
		_dialog.nodeiter = nil 
		InvokeEvent("DialogEnd", d) 
	end,
	[STATE_OPENING] = function(d) d.rate = 2 d.printed = "" end,
	[STATE_OPENED] = function(d) d.rate = 12 d.nodeiter() end,
	[STATE_PRINTING] = function(d)
		d.rate = 60 * PrintSpeedScale
		local numc = math.Clamp(math.Round(FrameTime() * d.rate), 1, #d.text)
		d.printed = d.printed .. d.text:sub(1, numc)
		d.text = d.text:sub(numc + 1,-1)
	end,
	[STATE_DONEPRINTING] = function(d)
		d.nodeiter()
	end,
	[STATE_CHOOSE] = function(d) d.rate = 1 end,
	[STATE_CLOSING] = function(d) d.rate = 2 d.printed = "" end,
	[STATE_EXEC] = function(d)
		local cmds = string.Split(d.exec, " ")
		local func = cmds[1]
		local res = ""

		-- If no coroutine is running, create a new one for the specified function
		if not d.coroutine and g_funcs[func] then
			d.coroutine = coroutine.create(g_funcs[func])
		elseif not g_funcs[func] then ErrorNoHalt("Invalid dialog function \"" .. func .. "\"") end

		-- Start/resume the coroutine
		if d.coroutine then

			-- Resume the coroutine for this iteration
			local succ, ret = coroutine.resume(d.coroutine, d, unpack(cmds, 2))
			if not succ then ErrorNoHalt("DIALOG FUNCTION " .. func .. " ERRORED: ", res) end
			res = ret and tostring(ret) or ""
	
			-- Append function result
			d.printed = d.printed .. res

			-- If the coroutine is dead, move onto the next node
			if coroutine.status(d.coroutine) == "dead" then
				d.coroutine = nil
				d.nodeiter()
			end
		else -- Nothing running, probably invalid function. Just skip ahead
			d.nodeiter()
		end

	end,
}

local ticks = {
	[STATE_OPENING] = function(d) d.open = DT() end,
	[STATE_CLOSING] = function(d) d.open = 1 - DT() end,
}

local function nop() end

Time = function( newtime )

	if newtime then _dialog.time = newtime end
	return _dialog.time

end

State = function( newstate, wait )

	if not newstate then return _dialog.state end

	if wait then
		_dialog.state = STATE_WAIT
		_dialog.rate = PrintSpeedScale * 1/wait
		_dialog.nextstate =  newstate
		return _dialog
	end

	Time( 0 )
	_dialog.state = newstate
	_ = ( inits[ newstate ] or nop )( _dialog )

	return _dialog

end

DT = function( advance )

	if advance then _dialog.time = _dialog.time + advance * _dialog.rate end
	return math.Clamp( _dialog.time / _dialog.duration, 0, 1 )

end

Done = function() return DT() >= 1 end

function ScriptCallback(cmd, data)

	if cmd == CMD_JUMP then
		_dialog.waitdata = {
			cmd = cmd,
			data = data
		} 
	end
	if cmd == CMD_LAYOUT then
		//CalcTextRect( data )
	end
	if cmd == CMD_PRINT then
		_dialog.text = data
		State( STATE_PRINTING )
	end
	if cmd == CMD_NEWLINE then
		_dialog.text = "\n"
		State( STATE_PRINTING )
	end
	if cmd == CMD_WAIT then
		State( STATE_PRINTING, .2 )
	end
	if cmd == CMD_OPTIONLIST then
		InvokeEvent("ListOptions", data)
	end
	if cmd == CMD_EXIT then
		_dialog.waitdata = {
			cmd = cmd,
			data = data
		}
	end
	if cmd == CMD_EXEC then
		_dialog.exec = data
		State( STATE_EXEC, .1 )
	end
end

local function Update( deltatime )

	DT( deltatime )

	_ = ( ticks[ State() ] or nop )( _dialog )
	_ = ( edges[ State() ] or nop )( _dialog )

end

function PaintAll()

	Update( FrameTime() )

	InvokeEvent("Paint", _dialog)
end


-- Immediately start the dialog at a new specified entry
function StartGraph(cmd, skipOpen, options)
	_dialog.options = options or {}
	local t = type(cmd)
	if t == "table" then
		_dialog.nodeiter = EnterNode( cmd, ScriptCallback )
	elseif t == "string" then
		_dialog.nodeiter = EnterGraph( cmd, ScriptCallback )
		_dialog.entrypoint = cmd
		_dialog.seen = false
	end

	if _dialog.nodeiter != nil then
		PrintSpeedScale = 1.0

		_dialog.printed = ""
		_dialog.text = ""

		State(skipOpen and STATE_OPENED or STATE_OPENING)

		if skipOpen then _dialog.nodeiter() end
	
		InvokeEvent("DialogStart", _dialog)
	end
end

-- Skip printing out text
function SkipText()
	PrintSpeedScale = math.huge
end

-- Continue onto the next page of dialog
function Continue(options)
	if not ReadyToContinue() then return end

	local data = _dialog.waitdata
	if data.cmd == "jump" then
		StartGraph(data.data[1], true)
	elseif data.cmd == "exit" then
		State(STATE_CLOSING, 2)
	else
		print("UNHANDLED CONTINUE STATE: " .. data.cmd )
	end

	_dialog.options = options or {}
	_dialog.waitdata = nil

	return true
end

-- Retrieves who is currently the speaker in the dialog
function GetSpeaker()
	return _dialog.options.speaker or GetFocus()
end

function ReadyToContinue()
	return _dialog.waitdata != nil
end

function GetFocus()
	return _dialog.focus
end

function GetCamera()
	return _dialog.camera
end

function IsInDialog()
	return _dialog.nodeiter != nil
end

function SetCallbackTable(tbl)
	_dialog.defaultcallbacktbl = tbl
end

function InformScriptFinished(entrypoint, seen)
	local scriptid = util.NetworkStringToID(entrypoint)
	if not scriptid then return false end

	net.Start( "dialog_dispatch" )
	net.WriteUInt( scriptid, 16 )
	net.WriteBit(seen)

	net.SendToServer()
	return true
end

net.Receive( "dialog_dispatch", function( len, ply )

	local script = util.NetworkIDToString( net.ReadUInt( 16 ) )
	local camera = nil
	local focus = nil
	
	if net.ReadBit() then focus = net.ReadEntity() end
	if net.ReadBit() then camera = net.ReadEntity() end
	if script == nil then script = "<no script>" end

	//Setup command variables
	_dialog.camera = camera
	_dialog.focus = focus

	StartGraph(script, false)
end )

-- Mark this script's entrypoint as 'seen', used for some other systems
RegisterFunc("mark_seen", function(d)
	d.seen = true
end )