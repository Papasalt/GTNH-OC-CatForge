-- Credits -- __cats_____ (cat.) - QUARK GLUON PLASMA

local component = require("component")
local sides = require("sides")
local computer = require("computer")

-- USER CONFIG

-- This MUST be configured to match your specific SSR arrangement
-- Available sides: sides.north, sides.east, sides.south, sides.west, sides.top, sides.bottom
local transposerConfig = { 
	{
		address = "SSR_TRANSPOSER_ADDRESS_1",
		interfaceSide = EDIT_ME,
		replenisherSides = {SIDE_1, SIDE_2, SIDE_3} -- Example configuration replenisherSides {sides.top, sides.west, sides.south}
	},
	{
		address = "SSR_TRANSPOSER_ADDRESS_2",
		interfaceSide = EDIT_ME,
		replenisherSides = {SIDE_1, SIDE_2, SIDE_3}
	},
	{
		address = "SSR_TRANSPOSER_ADDRESS_3",
		interfaceSide = EDIT_ME,
		replenisherSides = {SIDE_1, SIDE_2, SIDE_3}
	}
}

local bufferTransposerAddress = "IO_PORT_TRANSPOSER" -- Address of the transposer adjacent to the output subnet ME IO Port

local bufferIOSide = EDIT_ME -- Side of the bufferTransposer that the ME IO port is on
local activitySide = EDIT_ME -- Side of the Redstone I/O that receives the activity detector cover signal

local trackFluidProduction = false
local fluidProducedPerCycle = 0 -- Set this to the observed output in litres. This value can be seen in the controller while mid-recipe.
local productionRateReportInterval = 10 -- Report average production every 10 completed cycles.

local verifyFluidListEnabled = true -- Recommended to keep enabled for ease of debugging. Enforces that all unique fluids exist in the SSRs

-- SYSTEM CONFIG - Recommended to keep as is unless you know what you're doing

local expectedPlasmaMappingCount = 80
local slotsPerReplenisher = 9
local expectedRequestCount = 7

local eventDebounce = 0.15
local redstoneCheckInterval = 0.20

local verificationExportMode = false -- Used for exporting all SSR fluids to a text file for debugging and sharing

-- PLASMA TYPES SUPPLIED DIRECTLY AS FLUIDS

local fluidSourcePlasmas = {
	["Argon"] = true,
	["Tritium"] = true,
	["Helium"] = true,
	["Nitrogen"] = true,
	["Hydrogen"] = true,
	["Chlorine"] = true,
	["Mercury"] = true,
	["Radon"] = true,
	["Deuterium"] = true,
	["Fluorine"] = true
}

-- HARDWARE

local Hardware = {
	bufferController = nil,
	bufferTransposer = nil,
	redstone = nil
}

-- LOOKUP TABLES

local fluidSlots = {}
local sourceToPlasma = {}

-- LITRE FORMATTING

local function formatLitres(litres)
	if litres >= 1000000000 then
		return string.format("%.3f billion L", litres / 1000000000)
	elseif litres >= 1000000 then
		return string.format("%.2f million L", litres / 1000000)
	else
		return string.format("%.0f L", litres)
	end
end

-- PLASMA LIST EXPORT

local function exportFluidList(filename)
  local file = io.open(filename, "w")
  local count = 0
  for plasmaLabel, details in pairs(fluidSlots) do
    file:write(plasmaLabel, "\n")
    count = count + 1
  end
  file:close()
  print("Number of plasmas exported: " .. tostring(count))
  print("Filename: " .. filename)
end

-- HARDWARE DISCOVERY AND VERIFICATION

local function discoverHardware()
	local transposerLookup = {}

	for _, config in ipairs(transposerConfig) do
		if transposerLookup[config.address] ~= nil then error("Duplicate transposer address: " .. config.address) end
		transposerLookup[config.address] = config
		config.proxy = nil
	end

	for address in component.list("transposer") do
		if address == bufferTransposerAddress then
			Hardware.bufferTransposer = component.proxy(address)
		else
			local config = transposerLookup[address]
			if config ~= nil then config.proxy = component.proxy(address) end
		end
	end

	local controllerCount = 0
	for address in component.list("me_controller") do
		Hardware.bufferController = component.proxy(address)
		controllerCount = controllerCount + 1
	end

	if controllerCount ~= 1 then error("Expected exactly one ME controller, found " .. controllerCount) end

	local redstoneCount = 0
	for address in component.list("redstone") do
		Hardware.redstone = component.proxy(address)
		redstoneCount = redstoneCount + 1
	end

	if redstoneCount ~= 1 then error("Expected exactly one redstone component, found " .. redstoneCount) end
end

local function verifyFluidList()
	local filename = "expected_fluid_list.txt"
	local file, reason = io.open(filename, "r")

	if file == nil then
		error("Plasma verification is enabled, but the expected fluid list could not be opened: " ..
			filename .. "\n" .. tostring(reason) ..
			"\nEnsure you have downloaded the expected fluid list from the GTNH-OC-CatForge GitHub repository.")
	end

	local expectedPlasmas = {}
	local missingFluid = {}
	local unexpectedFluid = {}
	local expectedCount = 0

	for plasmaLabel in file:lines() do
		if plasmaLabel ~= "" and plasmaLabel:sub(1, 1) ~= "#" then
			if expectedPlasmas[plasmaLabel] then
				file:close()
				error("Duplicate plasma entry in " .. filename .. ": " .. plasmaLabel)
			end

			expectedPlasmas[plasmaLabel] = true
			expectedCount = expectedCount + 1

			if not fluidSlots[plasmaLabel] then
				table.insert(missingFluid, plasmaLabel)
			end
		end
	end

	file:close()

	for plasmaLabel in pairs(fluidSlots) do
		if not expectedPlasmas[plasmaLabel] then
			table.insert(unexpectedFluid, plasmaLabel)
		end
	end

	if #missingFluid > 0 or #unexpectedFluid > 0 then
		local message = {"Plasma verification failed!"}

		if #missingFluid > 0 then
      table.sort(missingFluid)
			table.insert(message, "\nMissing plasmas (" .. #missingFluid .. "):")
			for _, label in ipairs(missingFluid) do
				table.insert(message, "  - " .. label)
			end
		end

		if #unexpectedFluid > 0 then
      table.sort(unexpectedFluid)
			table.insert(message, "\nUnexpected plasmas (" .. #unexpectedFluid .. "):")
			for _, label in ipairs(unexpectedFluid) do
				table.insert(message, "  - " .. label)
			end
		end

		error(table.concat(message, "\n"))
	end

	print("Plasma verification successful: " .. expectedCount .. " plasmas verified.")
end

local function verifyHardware()
	if Hardware.bufferController == nil then error("Buffer ME controller not found.") end
	if Hardware.bufferTransposer == nil then error("Buffer transposer not found.") end
	if Hardware.redstone == nil then error("Redstone component not found.") end
	if activitySide == nil then error("Missing activitySide configuration.") end
	if trackFluidProduction and fluidProducedPerCycle <= 0 then error("Set fluidProducedPerCycle before enabling production tracking.") end

	for i, config in ipairs(transposerConfig) do
		if config.proxy == nil then error("Plasma transposer " .. i .. " not found: " .. config.address) end
		if config.interfaceSide == nil then error("Missing interfaceSide for plasma transposer " .. i) end
		if config.replenisherSides == nil or #config.replenisherSides ~= 3 then error("Plasma transposer " .. i .. " must have exactly 3 replenisher sides.") end
	end

	if Hardware.redstone.getInput(activitySide) == 0 then error("Exoticizer is not idle. Check activitySide configuration.") end
end

-- PLASMA SLOT DISCOVERY

local function discoverFluidSlots()
	local found = 0

	for _, config in ipairs(transposerConfig) do
		for _, side in ipairs(config.replenisherSides) do
			for slot = 1, slotsPerReplenisher do
				local fluid = config.proxy.getFluidInTank(side, slot)

				if fluid and fluid.amount > 0 then
					local label = fluid.label or fluid.name
					if not label then error("Fluid found in replenisher without a label.") end
					if fluidSlots[label] then error("Duplicate plasma found: " .. label) end

					fluidSlots[label] = {
						transposer = config.proxy,
						side = side,
						slot = slot - 1,
						interfaceSide = config.interfaceSide
					}
					found = found + 1
				end
			end
		end
	end

	return found
end

-- SOURCE-TO-PLASMA MAPPING DISCOVERY

local function discoverSourceMappings()
	local fluidSourceLookup = {}
	local matchedFluidSources = {}
	local mappingCount = 0

	-- Index the special direct-fluid sources by their first word.
	for sourceLabel in pairs(fluidSourcePlasmas) do
		local material = sourceLabel:match("^(%S+)")
		if fluidSourceLookup[material] ~= nil then error("Duplicate direct-fluid material identifier: " .. material) end

		fluidSourceLookup[material] = sourceLabel
	end

	-- Generate source mappings directly from the discovered plasma names.
	for plasmaLabel in pairs(fluidSlots) do
		local material = plasmaLabel:match("^(.-) Plasma$")
		if material == nil then
			error("Unexpected plasma name: " .. tostring(plasmaLabel))
		end

		local sourceLabel = fluidSourceLookup[material] or (material .. " Dust")
		if sourceToPlasma[sourceLabel] ~= nil then
			error("Duplicate source mapping found: " .. sourceLabel)
		end

		sourceToPlasma[sourceLabel] = plasmaLabel
		mappingCount = mappingCount + 1

		if fluidSourceLookup[material] ~= nil then
			matchedFluidSources[material] = true
		end
	end

	-- Ensure every special direct-fluid source has a corresponding plasma.
	for material, sourceLabel in pairs(fluidSourceLookup) do
		if not matchedFluidSources[material] then
			error("No stocked plasma found for direct-fluid source: " .. sourceLabel)
		end
	end

	if mappingCount ~= expectedPlasmaMappingCount then
		error("Expected " .. expectedPlasmaMappingCount .. " source mappings, found " .. mappingCount)
	end

	return mappingCount
end

-- OUTPUT BUFFER

local function clearBufferSubnet()
	local success1 = Hardware.bufferTransposer.transferItem(bufferIOSide, bufferIOSide, 1, 7, 1) > 0
	local success2 = Hardware.bufferTransposer.transferItem(bufferIOSide, bufferIOSide, 1, 8, 2) > 0
	return success1 and success2
end

local function readRequests()
	local requests = {}
	local count = 0

	for _, fluid in ipairs(Hardware.bufferController.getFluidsInNetwork()) do
		local label = fluid.label
		if label == nil or requests[label] ~= nil then error("Invalid or duplicate fluid entry in output buffer.") end
		requests[label] = fluid.size
		count = count + 1
	end

	for _, item in ipairs(Hardware.bufferController.getItemsInNetwork()) do
		local label = item.label
		if label == nil or requests[label] ~= nil then error("Invalid or duplicate item entry in output buffer.") end
		requests[label] = item.size
		count = count + 1
	end

	if count ~= expectedRequestCount then return nil end
	return requests
end

-- PLASMA TRANSFER

local function transferPlasma(requests)
	for sourceLabel, requestSize in pairs(requests) do
		local plasmaLabel = sourceToPlasma[sourceLabel]
		if plasmaLabel == nil then error("No plasma mapping exists for Exoticizer output: " .. tostring(sourceLabel)) end

		local source = fluidSlots[plasmaLabel]
		if source == nil then error("Plasma not found in replenisher lookup: " .. tostring(plasmaLabel)) end

		local amountPerRequest = fluidSourcePlasmas[sourceLabel] and 1000 or 1296
		local amount = requestSize * amountPerRequest
		local transferred = source.transposer.transferFluid(source.side, source.interfaceSide, amount, source.slot)

		if transferred == false or transferred == nil or transferred == 0 then error("Fluid transfer failed for " .. tostring(plasmaLabel)) end
		if type(transferred) == "number" and transferred < amount then error("Partial transfer for " .. tostring(plasmaLabel) .. ": " .. transferred .. "/" .. amount .. " L") end
	end
end

-- CYCLE CONTROL

local processing = false
local bufferChangePending = false
local pendingRequests = nil
local cycleCount = 0
local totalFluidProduced = 0
local productionTrackingStarted = nil

local function isExoticizerIdle()
	return Hardware.redstone.getInput(activitySide) ~= 0
end

local function processCycle(requests)
	if processing or not isExoticizerIdle() then return end

	local cycleStarted = computer.uptime()
	processing = true

	if not clearBufferSubnet() then
		processing = false
		error("Failed to clear Exoticizer output buffer.")
	end

	transferPlasma(requests)

	pendingRequests = nil
	processing = false
	cycleCount = cycleCount + 1

	local totalTime = computer.uptime() - cycleStarted

	if trackFluidProduction then
		totalFluidProduced = totalFluidProduced + fluidProducedPerCycle

		print(string.format("[QGP] Cycle %d completed in %.3fs | Total produced: %s", cycleCount, totalTime, formatLitres(totalFluidProduced)))

		if cycleCount % productionRateReportInterval == 0 then
			local elapsed = computer.uptime() - productionTrackingStarted
			local ratePerSecond = totalFluidProduced / elapsed

			print(string.format("[QGP] Average production: %s/s | %s/min | %s/h",
				formatLitres(ratePerSecond),
				formatLitres(ratePerSecond * 60),
				formatLitres(ratePerSecond * 3600)
			))
		end
	else
		print(string.format("[QGP] Cycle %d completed in %.3fs", cycleCount, totalTime))
	end
end

-- EVENT HANDLING

local function isBufferChangeEvent(signalName)
	return signalName == "network_fluid_changed" or signalName == "network_item_changed"
end

-- STARTUP

local function startup()
	print("[QGP] Initialising components...")

	discoverHardware()
	verifyHardware()
  
  print("[QGP] Hardware verified.")

  if verificationExportMode then
    print("Verification export mode is enabled. Exporting SSR fluid list and exiting script early...")
    exportFluidList("expected_fluid_list.txt")
    return
  end
  
	local scanStarted = computer.uptime()
	local fluidCount = discoverFluidSlots()
	local scanTime = computer.uptime() - scanStarted

  if verifyFluidListEnabled then
		print("[QGP] Performing detailed plasma verification...")
		verifyFluidList()
	else
		print("[QGP] Detailed plasma verification disabled.")
		if fluidCount ~= expectedPlasmaMappingCount then
			error("Expected " .. expectedPlasmaMappingCount .. " plasmas, found " .. fluidCount)
		end
	end

	local mappingCount = discoverSourceMappings()

	Hardware.bufferController.setFluidEventSubscription(true)
	Hardware.bufferController.setItemEventSubscription(true)

	if trackFluidProduction then productionTrackingStarted = computer.uptime() end

	print(string.format("[QGP] Ready | %d plasma sources indexed in %.3fs | %d mappings generated", fluidCount, scanTime, mappingCount))
	if trackFluidProduction then print(string.format("[QGP] Production tracking enabled | %.0f L per cycle", fluidProducedPerCycle)) end

  local initialRequests = readRequests()
  if initialRequests ~= nil then
    pendingRequests = initialRequests
    print("[QGP] Existing output detected in buffer. Processing on startup.")
  end
	print("[QGP] Waiting for Exoticizer output.")
end

-- MAIN LOOP

local function main()
	while true do
		local signalName = computer.pullSignal(redstoneCheckInterval)

		if isBufferChangeEvent(signalName) then
			bufferChangePending = true
			local deadline = computer.uptime() + eventDebounce

			while computer.uptime() < deadline do
				local remaining = deadline - computer.uptime()
				local nextSignal = computer.pullSignal(remaining)

				if isBufferChangeEvent(nextSignal) then
					deadline = computer.uptime() + eventDebounce
				end
			end
		end

		if bufferChangePending then
			local requests = readRequests()

			if requests ~= nil then
				pendingRequests = requests
				bufferChangePending = false
			end
		end

		if pendingRequests ~= nil and isExoticizerIdle() then
			processCycle(pendingRequests)
		end
	end
end

startup()
if not verificationExportMode then
  main()
end
