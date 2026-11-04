-- Credits -- __cats_____ (cat.) - MAGMATTER

local component = require("component")
local sides = require("sides")
local computer = require("computer")

-- USER CONFIG - This section MUST be edited to match your specific arrangement and orientation
-- Use an Analyzer on the component to print its address in chat. Click the address to copy it to your clipboard.
-- Available sides: sides.north, sides.east, sides.south, sides.west, sides.top, sides.bottom

local plasmaTransposerAddress = "SSR_TRANSPOSER_ADDRESS" -- Replace with the address of the transposer adjacent to the SSR. A single transposer must be use for this.
local bufferTransposerAddress = "IO_PORT_TRANSPOSER_ADDRESS" -- Replace with the address of the transposer adjacent to the output subnet ME IO Port.

local plasmaInterfaceSide = EDIT_ME -- Replace with the side that the ME Dual Interface is on relative to the Transposer
local replenisherSides = {SIDE_1, SIDE_2} -- Replace with the side that the SSRs are on relative to transposer. Example: replenisherSides = {sides.east, sides.south}

local bufferIOSide = EDIT_ME -- Side of the bufferTransposer that the ME IO port is on
local activitySide = EDIT_ME -- Side of the Redstone I/O that receives the activity detector cover signal

local trackFluidProduction = false -- Enable this to track total and average rate of Quark Gluon Plasma.
local fluidProducedPerCycle = 0 -- Set this to the observed output in litres. This value can be seen in the controller while mid-recipe.
local productionRateReportInterval = 10 -- Report average production every 10 completed cycles.

local verifyFluidListEnabled = true -- Recommended to keep enabled for ease of debugging. Verifies that the SSRs contain exactly the expected fluids

-- SYSTEM CONFIG - Recommended to keep as is unless you know what you're doing

local expectedPlasmaMappingCount = 14
local expectedFluidCount = 16
local slotsPerReplenisher = 9
local plasmaInsertionAmount = 144
local expectedRequestCount = 3

local tachyonFluidIdentifier = "temporalfluid"
local spatialFluidIdentifier = "spatialfluid"

-- Altering these values may cause inconsistencies and unexpected issues during runtime
local eventDebounce = 0.10
local redstoneCheckInterval = 0.05

local verificationExportMode = false -- Used for exporting all SSR fluids to a text file for debugging and sharing

-- HARDWARE

local Hardware = {
  bufferController = nil,
  bufferTransposer = nil,
  redstone = nil
}

-- LOOKUP TABLES

local fluidSlots = {}
local sourceToPlasma = {}
local tachyonSlot = nil
local spatialSlot = nil

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
  for address in component.list("me_controller") do
    Hardware.bufferController = component.proxy(address)
    break
  end

  for address in component.list("transposer") do
    if address == plasmaTransposerAddress then
      Hardware.plasmaTransposer = component.proxy(address)
    elseif address == bufferTransposerAddress then
      Hardware.bufferTransposer = component.proxy(address)
    end
  end

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
    error("Fluid verification is enabled, but the expected fluid list could not be opened: " ..
      filename .. "\n" .. tostring(reason) ..
      "\nEnsure you have downloaded the expected fluid list from the GTNH-OC-CatForge GitHub repository.")
  end

  local expectedFluids = {}
  local missingFluids = {}
  local unexpectedFluids = {}
  local expectedCount = 0

  for fluidLabel in file:lines() do
    if fluidLabel ~= "" and fluidLabel:sub(1, 1) ~= "#" then
      if expectedFluids[fluidLabel] then
        file:close()
        error("Duplicate fluid entry in " .. filename .. ": " .. fluidLabel)
      end

      expectedFluids[fluidLabel] = true
      expectedCount = expectedCount + 1

      if not fluidSlots[fluidLabel] then
        table.insert(missingFluids, fluidLabel)
      end
    end
  end

  file:close()

  for fluidLabel in pairs(fluidSlots) do
    if not expectedFluids[fluidLabel] then
      table.insert(unexpectedFluids, fluidLabel)
    end
  end

  if #missingFluids > 0 or #unexpectedFluids > 0 then
    local message = {"Fluid verification failed!"}

    if #missingFluids > 0 then
      table.sort(missingFluids)
      table.insert(message, "\nMissing fluids (" .. #missingFluids .. "):")
      for _, label in ipairs(missingFluids) do
        table.insert(message, "  - " .. label)
      end
    end

    if #unexpectedFluids > 0 then
      table.sort(unexpectedFluids)
      table.insert(message, "\nUnexpected fluids (" .. #unexpectedFluids .. "):")
      for _, label in ipairs(unexpectedFluids) do
        table.insert(message, "  - " .. label)
      end
    end

    error(table.concat(message, "\n"))
  end

  print("Fluid verification successful: " .. expectedCount .. " fluids verified.")
end

local function verifyHardware()
  if Hardware.bufferController == nil then error("ME controller not found.") end
  if Hardware.plasmaTransposer == nil then error("Plasma transposer not found: " .. plasmaTransposerAddress) end
  if Hardware.bufferTransposer == nil then error("Buffer transposer not found: " .. bufferTransposerAddress) end
  if Hardware.redstone == nil then error("Redstone component not found.") end
  if plasmaInterfaceSide == nil then error("Missing plasmaInterfaceSide configuration.") end
  if activitySide == nil then error("Missing activitySide configuration.") end
  if #replenisherSides == 0 then error("No replenisher sides configured.") end
  if tachyonFluidIdentifier == spatialFluidIdentifier then error("Tachyon and spatial fluid identifiers cannot be identical.") end
  if trackFluidProduction and fluidProducedPerCycle <= 0 then error("Set fluidProducedPerCycle before enabling production tracking.") end
  if Hardware.redstone.getInput(activitySide) == 0 then error("Exoticizer is not idle. Check activitySide configuration.") end
  if productionRateReportInterval < 1 or productionRateReportInterval % 1 ~= 0 then error("productionRateReportInterval must be a positive integer.") end
end

-- FLUID SLOT DISCOVERY

local function discoverFluidSlots()
  local found = 0

  for _, side in ipairs(replenisherSides) do
    for slot = 1, slotsPerReplenisher do
      local fluid = Hardware.plasmaTransposer.getFluidInTank(side, slot)

      if fluid and fluid.amount > 0 then
        local label = fluid.label or fluid.name
        if label == nil then error("Fluid found in replenisher without a label or name.") end
        if fluidSlots[label] ~= nil then error("Duplicate fluid found in replenisher: " .. label) end

        local source = {side = side, slot = slot - 1}
        fluidSlots[label] = source
        found = found + 1

        if fluid.name == tachyonFluidIdentifier or fluid.label == tachyonFluidIdentifier then
          if tachyonSlot ~= nil then error("Duplicate tachyon fluid found.") end
          tachyonSlot = source
        end

        if fluid.name == spatialFluidIdentifier or fluid.label == spatialFluidIdentifier then
          if spatialSlot ~= nil then error("Duplicate spatial fluid found.") end
          spatialSlot = source
        end
      end
    end
  end
  
  return found
end

-- PLASMA MAPPING DISCOVERY

local function discoverSourceMappings()
  local mappingCount = 0

  for plasmaLabel in pairs(fluidSlots) do
    local material = plasmaLabel:match("^(.-) Plasma$")

    if material ~= nil then
      local dustLabel = material .. " Dust"

      if sourceToPlasma[dustLabel] ~= nil then
        error("Duplicate dust mapping found: " .. dustLabel)
      end

      sourceToPlasma[dustLabel] = plasmaLabel
      mappingCount = mappingCount + 1
    end
  end

  if mappingCount ~= expectedPlasmaMappingCount then
    error("Expected " .. expectedPlasmaMappingCount .. " plasma mappings, found " .. mappingCount)
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
  local requests = {tachyon = nil, spatial = nil, dust = nil}
  local fluids = Hardware.bufferController.getFluidsInNetwork()
  local items = Hardware.bufferController.getItemsInNetwork()

  if #fluids ~= 2 or #items ~= 1 then return nil end

  for _, fluid in ipairs(fluids) do
    if fluid.name == tachyonFluidIdentifier or fluid.label == tachyonFluidIdentifier then
      if requests.tachyon ~= nil then error("Duplicate tachyon fluid in output buffer.") end
      requests.tachyon = fluid.size
    elseif fluid.name == spatialFluidIdentifier or fluid.label == spatialFluidIdentifier then
      if requests.spatial ~= nil then error("Duplicate spatial fluid in output buffer.") end
      requests.spatial = fluid.size
    else
      error("Unexpected fluid in Exoticizer buffer: " .. tostring(fluid.label))
    end
  end

  requests.dust = items[1].label

  if requests.tachyon == nil or requests.spatial == nil then error("Missing tachyon or spatial fluid in output buffer.") end
  if requests.dust == nil then error("Magmatter dust output has no label.") end
  if requests.tachyon < 1 or requests.tachyon > 50 then error("Invalid tachyon amount: " .. tostring(requests.tachyon) .. " L") end
  if requests.spatial < 51 or requests.spatial > 100 then error("Invalid spatial amount: " .. tostring(requests.spatial) .. " L") end

  requests.plasmaUnits = requests.spatial - requests.tachyon
  requests.plasmaAmount = requests.plasmaUnits * plasmaInsertionAmount

  if requests.plasmaAmount <= 0 then error("Calculated plasma amount is invalid: " .. tostring(requests.plasmaAmount)) end

  return requests
end

-- FLUID TRANSFER

local function transferFluid(source, amount, label)
  if source == nil then error("Missing replenisher source for " .. tostring(label)) end

  local transferred = Hardware.plasmaTransposer.transferFluid(source.side, plasmaInterfaceSide, amount, source.slot)

  if transferred == false or transferred == nil or transferred == 0 then error("Fluid transfer failed for " .. tostring(label)) end
  if type(transferred) == "number" and transferred < amount then error("Partial transfer for " .. tostring(label) .. ": " .. transferred .. "/" .. amount .. " L") end

  return transferred
end

local function transferMagmatterInputs(requests)
  local plasmaLabel = sourceToPlasma[requests.dust]
  if plasmaLabel == nil then error("No plasma mapping exists for dust: " .. tostring(requests.dust)) end

  local plasmaSource = fluidSlots[plasmaLabel]
  if plasmaSource == nil then error("Plasma not found in replenisher lookup: " .. plasmaLabel) end

  transferFluid(tachyonSlot, requests.tachyon, "Tachyon")
  transferFluid(spatialSlot, requests.spatial, "Spatial")
  transferFluid(plasmaSource, requests.plasmaAmount, plasmaLabel)

  return plasmaLabel
end

-- CYCLE CONTROL

local processing = false
local bufferChangePending = false
local awaitingNextCycle = false
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

  if requests == nil then return end

  processing = true
  bufferChangePending = false

  if not clearBufferSubnet() then
    processing = false
    error("Failed to clear Exoticizer output buffer.")
  end

  transferMagmatterInputs(requests)

  awaitingNextCycle = true
  processing = false
  cycleCount = cycleCount + 1

  local totalTime = computer.uptime() - cycleStarted

  if trackFluidProduction then
    totalFluidProduced = totalFluidProduced + fluidProducedPerCycle

    print(string.format("[MAGMATTER] Cycle %d completed in %.3fs | Total produced: %s", cycleCount, totalTime, formatLitres(totalFluidProduced)))

    if cycleCount % productionRateReportInterval == 0 then
      local elapsed = computer.uptime() - productionTrackingStarted
      local ratePerSecond = totalFluidProduced / elapsed

      print(string.format("[MAGMATTER] Average production: %s/s | %s/min | %s/h",
        formatLitres(ratePerSecond),
        formatLitres(ratePerSecond * 60),
        formatLitres(ratePerSecond * 3600)
      ))
    end
  else
    print(string.format("[MAGMATTER] Cycle %d completed in %.3fs", cycleCount, totalTime))
  end
end

-- EVENT HANDLING

local function isBufferChangeEvent(signalName)
  return signalName == "network_fluid_changed" or signalName == "network_item_changed"
end

-- STARTUP

local function startup()
  print("[MAGMATTER] Initialising components...")

  discoverHardware()
  verifyHardware()

  print("[MAGMATTER] Hardware verified.")

  local scanStarted = computer.uptime()
  local fluidCount = discoverFluidSlots()
  local scanTime = computer.uptime() - scanStarted

  if verificationExportMode then
    print("Verification export mode is enabled. Exporting SSR fluid list and exiting script early...")
    exportFluidList("expected_fluid_list.txt")
    return
  end

  if verifyFluidListEnabled then
    print("[MAGMATTER] Verifying SSR fluid inventory...")
    verifyFluidList()
  else
    print("[MAGMATTER] SSR fluid inventory verification disabled.")
    if fluidCount ~= expectedFluidCount then
      error("Expected " .. expectedFluidCount .. " fluids, found " .. fluidCount)
    end
  end

  local mappingCount = discoverSourceMappings()

  Hardware.bufferController.setFluidEventSubscription(true)
  Hardware.bufferController.setItemEventSubscription(true)

  if trackFluidProduction then productionTrackingStarted = computer.uptime() end

  local fluids = Hardware.bufferController.getFluidsInNetwork()
  local items = Hardware.bufferController.getItemsInNetwork()

  if #fluids + #items == expectedRequestCount then bufferChangePending = true end

  print(string.format("[MAGMATTER] Ready | %d fluids indexed in %.3fs | %d plasma mappings loaded", fluidCount, scanTime, mappingCount))
  
  if trackFluidProduction then print(string.format("[MAGMATTER] Production tracking enabled | %.0f L per cycle", fluidProducedPerCycle)) end
  print("[MAGMATTER] Waiting for Exoticizer output.")
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
        if isBufferChangeEvent(nextSignal) then deadline = computer.uptime() + eventDebounce end
      end
    end

    if bufferChangePending then
      bufferChangePending = false
      pendingRequests = readRequests()
    end

    if pendingRequests ~= nil and isExoticizerIdle() then
      local requests = pendingRequests
      pendingRequests = nil
      awaitingNextCycle = false

      processCycle(requests)
    end
  end
end

startup()
if not verificationExportMode then
  main()
end
