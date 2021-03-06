math.tau = math.pi * 2 -- detmath.tau is just as good-- they're both just plain floats, detmath's isn't slower in any way-- but when you're not using any other parts of detmath, requiring it just for tau isn't very nice

local ffi = require("ffi")
local uint64 = ffi.typeof("uint64_t")

local constants, registry, settings, assets =
	require("constants"),
	require("registry"), -- NOTE: registry must be required before assets because of terrainClone hack
	require("systems.settings"),
	require("assets")

local suit, bump, list, detmath, cpml, noice =
	require("lib.suit"),
	require("lib.bump-3dpd"),
	require("lib.list"),
	require("lib.detmath"),
	require("lib.cpml"),
	require("lib.noice")

local think, getWill, move, newChunk, scene, input, ui, takeScreenshot, newEntity, modifyChunk, chunkManager, save, load =
	require("systems.think"),
	require("systems.getWill"),
	require("systems.move"),
	require("systems.newChunk"),
	require("systems.scene"),
	require("systems.input"),
	require("systems.ui"),
	require("systems.takeScreenshot"),
	require("systems.newEntity"),
	require("systems.modifyChunk"),
	require("systems.chunkManager"),
	require("systems.save"),
	require("systems.load")

local outlineShader
local infoCanvas, contentCanvas
local world

-- For love.draw and mousemoved, written to in love.run
local performance

-- For an "onPaused" function to trigger input.clearFixedCommandsList
local previousFramePaused

-- Used for mouse movement
local mdx, mdy

function love.handlers.save()
	save(world)
end

-- print(detmath.getRoundingMode())

function love.load(args)
	love.graphics.setMeshCullMode("back")
	love.graphics.setDefaultFilter("nearest", "nearest")
	love.graphics.setLineStyle("rough")
	love.graphics.setDepthMode("lequal", true)
	
	infoCanvas = love.graphics.newCanvas(constants.infoWidth, constants.infoHeight)
	contentCanvas = love.graphics.newCanvas(constants.width, constants.height)
	outlineShader = love.graphics.newShader("shaders/outline.glsl")
	outlineShader:send("windowSize", {constants.infoWidth, constants.infoHeight})
	
	input.clearRawCommands()
	input.clearFixedCommandsList()
	settings("load")
	assets("load")
	
	scene.init()
	
	love.graphics.setFont(assets.ui.font.value)
	
	if not args[1] or args[1] == "new" then
		local max32 = math.ldexp(1, 32)-1
		local seed1 = args[2] or love.math.random(max32+1)-1
		local seed2 = args[3] or 0
		assert(math.floor(seed1) == seed1 and seed1 >= 0 and seed1 < max32, "First seed is not a 32-bit integer")
		assert(math.floor(seed2) == seed2 and seed2 >= 0 and seed2 < max32, "Second seed is not a 32-bit integer")
		local seed = uint64(seed2) * uint64(max32) + uint64(seed1)
		world = {
			seed1 = seed1, -- normal lua number
			seed2 = seed2, -- "
			seed = seed, -- unsigned long long int
			rng = love.math.newRandomGenerator(seed1, seed2),
			bumpWorld = bump.newWorld(constants.bumpCellSize),
			simplexer = noice.newNoiser("OpenSimplex", seed),
			entities = list.new(),
			chunks = {},
			chunksById = {},
			freeChunkIdsToUse = {len = 0},
			nextIdAfterChunkIdListEnd = 0, -- TODO: max chunk ID from cw, ch, cd and maximum integer
			lights = list.new():add({isDirectional = true, angle={0.4, 0.8, 0.6}, colour={1, 1, 1}, strength = 3}),
			gravityAmount = 9.8 and 0,
			gravityMaxFallSpeed = 50,
			unsaved = true
		}
		local testmanPlayer = newEntity(world, "epicman", 4, 9, 4, 1)
		scene.cameraEntity = testmanPlayer
		local worldWidth, worldHeight, worldDepth = 16, 8, 16
		for x = 0, worldWidth - 1 do
			for y = 0, worldHeight - 1 do
				for z = 0, worldDepth - 1 do
					local newChunk = newChunk(x, y, z, world, true)
				end 
			end
		end
		
		chunkManager.doUpdates(world)
		for _,chunk in pairs(world.chunksById)do scene.chunksToDraw:add(chunk)end -- TEMP
	elseif args[1] == "load" then
		local path = args[2]
		world = load(path)
	else
		error("Invalid first argument: " .. args[1])
	end
	
	mdx, mdy = 0, 0
	move.initialise(world.bumpWorld)
end

function love.draw(lerp)
	if settings.graphics.showPerformance then
		love.graphics.setCanvas(infoCanvas)
		love.graphics.clear(0, 0, 0, 0)
		love.graphics.print(
			"FPS: " .. love.timer.getFPS() .. "\n" ..
			-- "Garbage: " .. collectgarbage("count") * 1024 -- counts all memory for some reason
			"Tick time: " .. (type(performance) == "number" and math.floor(performance * 100 + 0.5) .. "%" or "N/A")
		, 1, 1)
	end
	if scene.cameraEntity and not (ui.current and ui.current.causesPause) then
		if not settings.graphics.interpolation then
			lerp = nil
		end
		scene.setTransforms(world, lerp)
		scene.render(world)
	end
	love.graphics.setCanvas(contentCanvas)
	love.graphics.clear(0, 0, 0)
	if ui.current then love.graphics.setColor(0.5, 0.5, 0.5) end
	love.graphics.draw(scene.outputCanvas)
	if settings.graphics.showPerformance then
		love.graphics.setColor(1, 1, 1)
		love.graphics.setShader(outlineShader)
		love.graphics.draw(infoCanvas, 1, 1)
		love.graphics.setShader()
	end
	if ui.current then
		if ui.current.draw then
			ui.current.draw() -- stuff SUIT can't do: rectangles, lines, etc
		end
		suit.draw()
		love.graphics.setColor(settings.mouse.cursorColour)
		love.graphics.draw(assets.ui.cursor.value, math.floor(ui.current.mouseX), math.floor(ui.current.mouseY))
	else
		-- draw HUD
		scene.drawBlockCursor(world, lerp)
		local chw, chh = assets.ui.crosshairs.value:getDimensions()
		love.graphics.draw(assets.ui.crosshairs.value, (constants.width - chw) / 2, (constants.height - chh) / 2)
	end
	love.graphics.setColor(1, 1, 1)
	
	love.graphics.setCanvas()
	
	local x, y
	if settings.graphics.fullscreen then
		local width, height = love.window.getDesktopDimensions()
		x = (width - constants.width * settings.graphics.scale) / 2
		y = (height - constants.height * settings.graphics.scale) / 2
	else
		x, y = 0, 0
	end
	
	love.graphics.draw(contentCanvas, x, y, 0, settings.graphics.scale)
end

function love.frameUpdate(dt)
	do -- Check hotkeys for settings and screenshots etc
		if input.didFrameCommand("pause") then
			if ui.current then
				if not ui.current.ignorePausePress then
					ui.destroy()
				end
			else
				ui.construct("plainPause")
			end
		end
		
		if input.didFrameCommand("toggleMouseGrab") then
			love.mouse.setRelativeMode(not love.mouse.getRelativeMode())
		end
		if input.didFrameCommand("takeScreenshot") then
			-- If uiModifier is held then takeScreenshot will include HUD et cetera.
			takeScreenshot(input.didFrameCommand("uiModifier") and contentCanvas or scene.outputCanvas)
		end
		if not ui.current or ui.current.type ~= "settings" then
			if input.didFrameCommand("toggleInfo") then
				settings.graphics.showPerformance = not settings.graphics.showPerformance
				settings("save")
			end
			
			if input.didFrameCommand("previousDisplay") and love.window.getDisplayCount() > 1 then
				settings.graphics.display = (settings.graphics.display - 2) % love.window.getDisplayCount() + 1
				settings("apply") -- TODO: test thingy... y'know, "press enter to save or wait 5 seconds to revert"
				settings("save")
			end
			
			if input.didFrameCommand("nextDisplay") and love.window.getDisplayCount() > 1 then
				settings.graphics.display = (settings.graphics.display) % love.window.getDisplayCount() + 1
				settings("apply")
				settings("save")
			end
			
			if input.didFrameCommand("scaleDown") and settings.graphics.scale > 1 then
				settings.graphics.scale = settings.graphics.scale - 1
				settings("apply")
				settings("save")
			end
			
			if input.didFrameCommand("scaleUp") then
				settings.graphics.scale = settings.graphics.scale + 1
				settings("apply")
				settings("save")
			end
			
			if input.didFrameCommand("toggleFullscreen") then
				settings.graphics.fullscreen = not settings.graphics.fullscreen
				settings("apply")
				settings("save")
			end
		end
	end
	
	if ui.current then
		ui.update()
	end
	
	if not (ui.current and ui.current.causesPause) then
		-- TODO: particles and such
	end
	
	input.stepRawCommands(ui.current and ui.current.causesPause)
end

function love.fixedUpdate(dt)
	world.unsaved = true
	local blockDamages, blockBuildings, blockMetadataBuildings = {}, {}, {}
	local bumpCubesToUpdate, chunksToUpdate = {}, {}
	local wills = {}
	
	for i = 1, world.entities.size do
		local entity = world.entities:get(i)
		-- Back up previous fields for interpolation
		entity.ptheta, entity.pphi, entity.px, entity.py, entity.pz, entity.pw, entity.ph, entity.pd = entity.theta, entity.phi, world.bumpWorld:getCube(entity)
		if entity.controller then -- Do own movement
			local will
			if type(entity.controller) == "number" then
				assert(entity.controller == 1, "Multiplayer is not here yet")
				will = getWill(entity, mdx, mdy)
			else
				will = think(entity, world)
			end
			wills[entity] = will
			move.selfAccelerate(entity, will, dt, world, bumpCubesToUpdate)
			modifyChunk.damageBlocks(entity, will, world, blockDamages)
		end
		move.gravitate(entity, world.gravityAmount, world.gravityMaxFallSpeed, dt)
	end
	modifyChunk.doDamages(world, blockDamages, chunksToUpdate)
	
	-- For crouching
	for entity in pairs(bumpCubesToUpdate) do
		local x, y, z, w, _, d = world.bumpWorld:getCube(entity)
		local h = entity.height
		world.bumpWorld:update(entity, x, y, z, w, h, d)
	end
	
	for i = 1, world.entities.size do
		local entity = world.entities:get(i)
		modifyChunk.buildBlocks(entity, wills[entity], world, blockBuildings, blockMetadataBuildings)
	end
	modifyChunk.doBuildings(world, blockBuildings, blockMetadataBuildings, chunksToUpdate)
	
	chunkManager.doUpdates(world, chunksToUpdate)
	
	for i = 1, world.entities.size do
		move.collide(world.entities:get(i), world.bumpWorld, dt)
	end
	
	for i = 1, world.entities.size do
		local entity = world.entities:get(i)
		world.bumpWorld:update(entity, entity.nextX, entity.nextY, entity.nextZ)
		entity.vx, entity.vy, entity.vz, entity.nextVx, entity.nextVy, entity.nextVz, entity.nextX, entity.nextY, entity.nextZ =
			entity.nextVx, entity.nextVy, entity.nextVz
		-- snap y velocity
		entity.vy = math.abs(entity.vy) > constants.velocitySnap and entity.vy or 0
	end
	
	-- TODO push apart entities that're in the same place and use random (in a deterministic order) in the resolutions on their ambiguities
	
	mdx, mdy = 0, 0
	input.clearFixedCommandsList()
end

-- The following function is based on the MIT licensed code here: https://gist.github.com/Positive07/5e80f03cabd069087930d569c148241c
-- Copyright (c) 2019 Arvid Gerstmann, Jake Besworth, Max, Pablo Mayobre, LÖVE Developers, Henry Fleminger Thomson

local delta = 0 -- For mousemoved
function love.run()
	love.load(love.arg.parseGameArguments(arg))
	local lag = constants.tickWorth
	love.timer.step()
	
	return function()
		love.event.pump()
		for name, a,b,c,d,e,f in love.event.poll() do -- Events
			if name == "quit" then
				if not love.quit() then
					return a or 0
				end
			end
			love.handlers[name](a,b,c,d,e,f)
		end
		
		do -- Update
			delta = love.timer.step()
			lag = math.min(lag + delta, constants.tickWorth * settings.graphics.maxTicksPerFrame)
			local frames = math.floor(lag / constants.tickWorth)
			lag = lag % constants.tickWorth
			love.frameUpdate(delta)
			if not (ui.current and ui.current.causesPause) then
				local start = love.timer.getTime()
				for _=1, frames do
					love.fixedUpdate(constants.tickWorth)
				end
				if frames ~= 0 then performance = (love.timer.getTime() - start) / (frames * constants.tickWorth) end
			else
				performance = nil
				if previousFramePaused then
					-- "onPause"
					input.clearFixedCommandsList()
				end
			end
			local previousFramePaused = ui.current and ui.current.causesPause
		end
		
		if love.graphics.isActive() then -- Rendering
			love.graphics.origin()
			love.graphics.clear(love.graphics.getBackgroundColor())
			love.draw(lag / constants.tickWorth)
			love.graphics.present()
		end
		
		love.timer.sleep(0.001)
	end
end

function love.mousemoved(x, y, dx, dy)
	if love.window.hasFocus() and love.window.hasMouseFocus() and love.mouse.getRelativeMode() then
		if ui.current then
			ui.mouse(dx, dy)
		elseif scene.cameraEntity then -- TODO: not just else? (reason being, what if demo replay had its own, separate camera)
			mdx, mdy = mdx + dx * delta, mdy + dy * delta
		end
	end
end

function love.quit()
	if world.unsaved then
		if ui.current and ui.current.type == "quitConfirmation" then return false end
		ui.construct("quitConfirmation")
		return true
	end
end
