local registry = require("registry")

local deepCopy

local function newEntity(world, type, x, y, z, controller)
	local ret = {
		controller = controller,
		theta = 0, preModuloTheta = 0,
		phi = 0, preModuloPhi = 0,
		vx = 0, vy = 0, vz = 0, vtheta = 0, vphi = 0
	}
	
	local base = registry.entities[type]
	if base.abilities and base.abilities.inventoryCapacity then
		ret.inventory = {}
	end
	deepCopy(base, ret)
	
	world.entities:add(ret)
	world.bumpWorld:add(ret, x, y, z, ret.diameter, ret.height, ret.diameter)
	return ret
end

function deepCopy(from, to)
	for k, v in pairs(from) do
		if type(v) == "table" then
			local to2 = {}
			to[k] = to2
			deepCopy(v, to2)
		else
			to[k] = v
		end
	end
end

return newEntity
