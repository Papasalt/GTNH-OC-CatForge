-- Credits -- __cats_____ (cat.) - PLASMA MAINTAINER

local component = require("component")
local term = require("term")

-- User config

local checkInterval = 60 -- How often, in seconds, the script reads the network to check if any plasmas are below the set threshold
local minimumStock = 100000000 -- If the stored plasma is below this value, AE2 will trigger a craft of batch size 1 to attempt to raise it above the threshold
local maxRequestCount = 16 -- Set this to the number of crafting CPUs available or lower.
local retryInterval = 5 -- Number of network checks before reattempting a previously failed plasma craft
local ignorePatternCountCheck = false -- If this is true, then you risk running out of/not having any of any plasma that has missing patterns

-- End user config

-- Declarations

local meController = component.me_controller

local plasmaLookup = {}
local activeRequests = 0
local loopCount = 0

-- End declarations --

local function initialisePlasmaCraftables()
	local craftables = meController.getCraftables()
	local patternCount = 0

	for i, craftable in ipairs(craftables) do
		local stack = craftable.getStack()

		if stack.name:match("^plasma%.") then
			if plasmaLookup[stack.name] ~= nil then
				error("Duplicate pattern found: " .. stack.label)
			end

			plasmaLookup[stack.name] = {
				quantity = 0,
				label = stack.label,
				craftable = craftable,
				request = nil,
				failed = false,
				failedAt = 0
			}

			patternCount = patternCount + 1
		else
			error("Non-plasma pattern found in network: " .. stack.name)
		end
	end

	if not ignorePatternCountCheck and not (patternCount == 80 or patternCount == 94) then
		error("Unexpected number of patterns discovered. There must be exactly 80 (QGP) or 94 (QGP+Magmatter) patterns. Ensure you do not have duplicates or are missing any.")
	end
end

local function updatePlasmaQuantities()
	local fluids = meController.getFluidsInNetwork()

	for _, fluid in ipairs(fluids) do
		local plasma = plasmaLookup[fluid.name]

		if plasma then
			plasma.quantity = fluid.amount
		end
	end
end

local function updateCraftingRequests()
	for name, plasma in pairs(plasmaLookup) do
		if plasma.request ~= nil then
			if plasma.request.hasFailed() or plasma.request.isCanceled() then
				plasma.request = nil
				plasma.failed = true
				plasma.failedAt = loopCount
				activeRequests = activeRequests - 1

			elseif plasma.request.isDone() then
				plasma.request = nil
				plasma.failed = false
				activeRequests = activeRequests - 1
			end
		end
	end
end

local function processPlasmaRequests()
	for name, plasma in pairs(plasmaLookup) do
		if activeRequests >= maxRequestCount then
			return
		end

		if plasma.failed and loopCount - plasma.failedAt >= retryInterval then
			plasma.failed = false
		end

		if plasma.quantity < minimumStock
		and plasma.request == nil
		and plasma.failed == false then

			local request = plasma.craftable.request(1)

			if request.hasFailed() or request.isCanceled() then
				plasma.failed = true
				plasma.failedAt = loopCount
			else
				plasma.request = request
				activeRequests = activeRequests + 1
			end
		end
	end
end

local function printSummary()
	local total = 0
	local healthy = 0
	local understocked = 0
	local active = 0
	local failed = 0
	local failedNames = {}

	for name, plasma in pairs(plasmaLookup) do
		total = total + 1

		if plasma.request ~= nil then
			active = active + 1
		elseif plasma.failed then
			failed = failed + 1
			table.insert(failedNames, plasma.label)
		elseif plasma.quantity < minimumStock then
			understocked = understocked + 1
		else
			healthy = healthy + 1
		end
	end

	table.sort(failedNames)

	term.clear()
	term.setCursor(1, 1)

	print("========== PLASMA MAINTAINER ==========")
	print("Patterns: " .. total)
	print("Healthy: " .. healthy .. " | Understocked: " .. understocked)
	print("Active: " .. active .. "/" .. maxRequestCount .. " | Failed: " .. failed)
  print("Iteration count: " .. loopCount)
	print("---------------------------------------")
	print("Failed crafts:")

	if failed == 0 then
		print("None")
	else
		for _, name in ipairs(failedNames) do
			print("- " .. name)
		end
	end

	print("=======================================")
end

local function startup()
	print("Initialising plasma tables...")
	initialisePlasmaCraftables()
	updatePlasmaQuantities()
	print("Initialisation has completed. Starting main loop...")
end

local function main()
	while true do
		loopCount = loopCount + 1

		updateCraftingRequests()
		updatePlasmaQuantities()
		processPlasmaRequests()

		printSummary()
		os.sleep(checkInterval)
	end
end

startup()
main()
