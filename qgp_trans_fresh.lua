
-- Credits -- __cats_____ (cat.) - QUARK GLUON PLASMA

local component = require("component")
local sides = require("sides")
local computer = require("computer")

-- USER CONFIG

local transposerConfig = {
	{
		address = "44add4e8-60d9-4403-85f6-76b5bfba416e",
		interfaceSide = sides.north,
		replenisherSides = {sides.top, sides.west, sides.south}
	},
	{
		address = "b85c3566-2229-44c8-956c-bf0ce20aef5a",
		interfaceSide = sides.west,
		replenisherSides = {sides.top, sides.east, sides.bottom}
	},
	{
		address = "32bfd0f6-cc63-434e-a20d-db33af40582e",
		interfaceSide = sides.south,
		replenisherSides = {sides.top, sides.west, sides.north}
	}
}

local bufferTransposerAddress = "cd5b6335-ac50-437a-b522-27f0ff2e3279"

local bufferIOSide = sides.north
local activitySide = sides.top

local expectedRequestCount = 7
local slotsPerReplenisher = 9
local interfaceSlots = 36

local trackFluidProduction = true
local fluidProducedPerCycle = 1607000 -- Set this to the observed output in litres.
local productionRateReportInterval = 10 -- Report average production every 10 completed cycles.

local eventDebounce = 0.15
local redstoneCheckInterval = 0.20

-- Plasma types supplied directly as fluids rather than dusts.
-- These use 1000 L per request instead of 1296 L.

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

local plasmaSlots = {}
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

local function discoverPlasmaSlots()
	local found = 0

	for _, config in ipairs(transposerConfig) do
		for _, side in ipairs(config.replenisherSides) do
			for slot = 1, slotsPerReplenisher do
				local fluid = config.proxy.getFluidInTank(side, slot)

				if fluid and fluid.amount > 0 then
					local label = fluid.label or fluid.name
					if not label then error("Fluid found in replenisher without a label.") end
					if plasmaSlots[label] then error("Duplicate plasma found: " .. label) end

					plasmaSlots[label] = {
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
	local matchedInterfaces = 0
	local patternCount = 0
	local fluidPlasmaLookup = {}

	for sourceLabel in pairs(fluidSourcePlasmas) do
		local material = sourceLabel:match("^(%S+)")
		fluidPlasmaLookup[material] = sourceLabel
	end

	for address in component.list("fluid_interface") do
		local interface = component.proxy(address)
		local interfaceMatched = false

		for slot = 1, interfaceSlots do
			local pattern = ({interface.getInterfacePattern(slot)})[1]

			if pattern ~= nil then
				local input = pattern.inputs and pattern.inputs[1]
				local output = pattern.outputs and pattern.outputs[1]

				if input ~= nil and output ~= nil then
					local sourceLabel = input.label
					local plasmaLabel = output.label

					if sourceLabel ~= nil and plasmaLabel ~= nil and plasmaSlots[plasmaLabel] ~= nil then
						local sourceMaterial = sourceLabel:match("^(%S+)")
						local plasmaMaterial = plasmaLabel:match("^(%S+)")

						local isDust = sourceLabel:match(" Dust$") ~= nil
						local isPlasma = plasmaLabel:match(" Plasma$") ~= nil
						local validMapping = false

						if isDust and isPlasma and sourceMaterial == plasmaMaterial then
							validMapping = true
						elseif isPlasma and fluidPlasmaLookup[plasmaMaterial] == sourceLabel then
							validMapping = true
						end

						if validMapping then
							if sourceToPlasma[sourceLabel] ~= nil then error("Duplicate source mapping found: " .. tostring(sourceLabel)) end

							sourceToPlasma[sourceLabel] = plasmaLabel
							patternCount = patternCount + 1
							interfaceMatched = true
						end
					end
				end
			end
		end

		if interfaceMatched then matchedInterfaces = matchedInterfaces + 1 end
	end

	if matchedInterfaces ~= 3 then error("Expected mappings across 3 fabrication interfaces, found " .. matchedInterfaces) end
	if patternCount ~= 80 then error("Expected 80 source-to-plasma mappings, found " .. patternCount) end

	return patternCount
end

local function verifyLookups()
	local mappingCount = 0

	for sourceLabel, plasmaLabel in pairs(sourceToPlasma) do
		mappingCount = mappingCount + 1
		if plasmaSlots[plasmaLabel] == nil then error("No replenisher slot found for plasma '" .. tostring(plasmaLabel) .. "' (source: " .. tostring(sourceLabel) .. ")") end
	end

	if mappingCount == 0 then error("No source-to-plasma mappings were found in the fabrication interfaces.") end
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

		local source = plasmaSlots[plasmaLabel]
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
local awaitingNextCycle = false
local sawExoticizerActive = false
local cycleCount = 0
local totalFluidProduced = 0
local productionTrackingStarted = nil

local function isExoticizerIdle()
	return Hardware.redstone.getInput(activitySide) ~= 0
end

local function processCycle()
	if processing or not isExoticizerIdle() then return end

	local cycleStarted = computer.uptime()
	local requests = readRequests()
	if requests == nil then return end

	processing = true
	bufferChangePending = false

	if not clearBufferSubnet() then
		processing = false
		error("Failed to clear Exoticizer output buffer.")
	end

	transferPlasma(requests)

	awaitingNextCycle = true
	sawExoticizerActive = false
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
	print("[QGP] Initialising transposer controller...")

	discoverHardware()
	verifyHardware()

	local scanStarted = computer.uptime()
	local plasmaCount = discoverPlasmaSlots()
	local scanTime = computer.uptime() - scanStarted

	local mappingCount = discoverSourceMappings()
	verifyLookups()

	if plasmaCount ~= 80 then error("Expected 80 plasma sources, found " .. plasmaCount) end

	Hardware.bufferController.setFluidEventSubscription(true)
	Hardware.bufferController.setItemEventSubscription(true)

  if trackFluidProduction then productionTrackingStarted = computer.uptime() end

	print(string.format("[QGP] Ready | %d plasma sources indexed in %.3fs | %d mappings loaded", plasmaCount, scanTime, mappingCount))
	if trackFluidProduction then print(string.format("[QGP] Production tracking enabled | %.0f L per cycle", fluidProducedPerCycle)) end
  
  local initialRequests = readRequests()
  if initialRequests ~= nil then
    bufferChangePending = true
    print("[QGP] Existing output detected in buffer. Processing on startup.")
  end
  
	print("[QGP] Waiting for Exoticizer output.")
end

-- MAIN LOOP

local function main()
	local lastRedstoneCheck = 0

	while true do
		local signalName = computer.pullSignal(redstoneCheckInterval)

		if isBufferChangeEvent(signalName) then
			bufferChangePending = true
			local deadline = computer.uptime() + eventDebounce

			while computer.uptime() < deadline do
				local remaining = deadline - computer.uptime()
				local nextSignal = computer.pullSignal(remaining)
				if isBufferChangeEvent(nextSignal) then deadline = computer.uptime() + eventDebounce end
			end
		end

		local now = computer.uptime()

		if now - lastRedstoneCheck >= redstoneCheckInterval then
			lastRedstoneCheck = now

			if awaitingNextCycle and not isExoticizerIdle() then sawExoticizerActive = true end

			if awaitingNextCycle and sawExoticizerActive and isExoticizerIdle() then
				awaitingNextCycle = false
				bufferChangePending = true
			end
		end

		if bufferChangePending and not awaitingNextCycle and isExoticizerIdle() then processCycle() end
	end
end

startup()
main()