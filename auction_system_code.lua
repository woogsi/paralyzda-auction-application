--\\ AUCTION SYSTEM made by paralyzda for game Build A Toy

local module = {}

--\\ SERVICES
local services = shared.services
local isstudio = services.run:IsStudio()
local testplace = workspace:GetAttribute("testplace")

--\\ MODULES
local config = require(services.sss.config) --Game settings
local data = require(shared.data) --Data module

local toys = require(script.Parent.Parent.toys) --Grab toy list
local mainfunctions = require(script.Parent.Parent.mainfunctions) --Module for main functions
local funcs = require(services.rs.modules.funcs) --Module for general functions

--\\ VARIABLES
local auction = services.mss:GetSortedMap(config.DATA_KEYS.auctionhouse)
local counter = services.mss:GetSortedMap(config.DATA_KEYS.auctioncounter)

local auctioninboxes = services.dss:GetDataStore(config.DATA_KEYS.auctioninbox)

local auctionexpire = config.SHOPS.market.expiretime
local itemcooldown = config.SHOPS.market.itemcooldown
local deletionstamp = config.SHOPS.market.deletionstamp

local rng = Random.new()


--\\ QUICK FUNCTIONS //--
local function round(num, numDecimalPlaces)
	return math.floor(num * (10^(numDecimalPlaces or 0)) + 0.5) / (10^(numDecimalPlaces or 0))
end

local function getunixtime()
	return math.floor(workspace:GetServerTimeNow())
end

--Send notifications
local function noti(plr, msg, msgcolor)
	if not plr or not msg then return end
	if not msgcolor then msgcolor = "default" end

	local s,e = pcall(function()
		plr.notis:SetAttribute("msg", msg.."|"..msgcolor)
		plr.notis:SetAttribute("tick", (plr.notis:GetAttribute("tick") or 0) + 1)
	end) ; if not s then print(e) end
end

--Update inbox
local function updateinbox(plrid, newtbl)
	local dataToInsert = funcs.deepclone(newtbl) --Create deep clone of table to prevent mutations

	local success, result = pcall(function()
		return auctioninboxes:UpdateAsync(plrid, function(inbox)
			inbox = inbox or {} --If no data, create empty table

			for _, item in ipairs(inbox) do
				if item.id == dataToInsert.id then
					return inbox --Item already exists, return original table
				end
			end
			
			--Add item to inbox
			inbox[#inbox + 1] = dataToInsert

			return inbox
		end)
	end)

	return success, result
end

--Update leaderstats
local function updateleaderstats(plr, cash, cashadded)
	if not (plr and plr:FindFirstChild("leaderstats") and plr.leaderstats:FindFirstChild("Cash")) then
		return --If player is invalid, return
	end

	local s,e = pcall(function()
		plr:SetAttribute("cash", cash) --Set player cash

		local moneyval = plr.leaderstats.Cash
		moneyval.Value = "$"..shared.numabbrev(cash) --Set abbreviated leaderstats cash

		if cashadded then
			--Set last collected amount
			moneyval:SetAttribute("lastCollected", cashadded)
			moneyval:SetAttribute("lastCollectedPing", (moneyval:GetAttribute("lastCollectedPing") or 0) + 1)
		end
	end) ; if not s then warn("update leaderstats failed:", e) end
end

--Update displays
local function updatebasedisplay(sellerid, index, displayinfo)
	if not sellerid or not index or not displayinfo then return end
	
	local s,e = pcall(function()
		
		--Grab player base, return if nil
		local mybase ; for _,base in ipairs(workspace.bases:GetChildren()) do if base:GetAttribute("ownerid") == sellerid then mybase = base ; break end end
		if not mybase then return end
		
		--Grab display spot, return if nil
		local displayspot = mybase.displays:FindFirstChild(tostring(index))
		if not displayspot then return end
		
		--Clear display info
		local keys = {}
		for k in pairs(displayspot:GetAttributes()) do table.insert(keys, k) end
		for _,k in ipairs(keys) do displayspot:SetAttribute(k, nil) end
		
		--Update seller display info
		if displayinfo.info then
			for z,x in pairs(displayinfo) do if z ~= "info" then displayspot:SetAttribute(z, x) end end
			for z,x in pairs(displayinfo.info) do if z ~= "itemname" then displayspot:SetAttribute(z, x) end end
			
			displayspot:SetAttribute("itemname", displayinfo.info.itemname)
		end
	end) ; if not s then warn("update display failed:", e) end
end

--Update counter
local function updateCounter(num)
	if num == 0 then return end
	
	local success,result = pcall(function()
		return counter:UpdateAsync("count", function(oldcount)
			oldcount = math.max((oldcount or 0) + num, 0)
			return oldcount
		end, auctionexpire)
	end) ; if not success then print(result) end

	if success then
		return true, result
	end

	return false, nil
end


--\\ BUY ITEM FROM AUCTION //--
local function processBuyer(buyerid, buyer, buyerdata, newinfo)
	if not buyer or not buyerdata then
		--If buyer is offline, update inbox instead
		
		local updated, result = updateinbox(buyerid, {
			["id"] = newinfo.txid, 
			["type"] = "toy", 
			["cash"] = -newinfo.price, 
			["itemname"] = newinfo.info.itemname, 
			["serial"] = newinfo.info.serial, 
			["originalid"] = newinfo.info.originalid, 
			["info"] = funcs.deepclone(newinfo.info), 
			["timestamp"] = getunixtime()
		})
		
		if not updated then print(result) end
		
		return updated
	end
	
	--Check for sufficient funds
	if buyerdata.Data.cash < newinfo.price then noti(buyer, "Not enough cash", "red") return false end

	--If this transaction was already completed then return
	local foundtx ; for _,t in pairs(buyerdata.Data.completedtx) do if t.id == newinfo.txid then foundtx = true ; break end end
	if foundtx then noti(buyer, "Transaction already completed", "red") return false end
	
	--Add toy
	mainfunctions.toy("add", {buyer, buyerdata}, newinfo.info)

	--Remove cash
	buyerdata.Data.cash -= newinfo.price

	--Add transaction ID
	buyerdata.Data.completedtx[#buyerdata.Data.completedtx + 1] = {id = newinfo.txid, timestamp = getunixtime() + deletionstamp}
	
	--Update visuals and notify
	updateleaderstats(buyer, buyerdata.Data.cash)
	noti(buyer, newinfo.info.itemname.." (#"..tostring(newinfo.info.serial)..") bought for $"..shared.addcommas(newinfo.price), "green")
	
	return true
end

local function processSeller(sellerid, seller, sellerdata, newinfo)
	if not seller or not sellerdata then
		--If seller is offline, update inbox instead
		
		local updated, result = updateinbox(sellerid, {
			["id"] = newinfo.txid, 
			["type"] = "toy", 
			["cash"] = newinfo.price, 
			["itemname"] = newinfo.info.itemname, 
			["serial"] = newinfo.info.serial, 
			["originalid"] = newinfo.info.originalid, 
			["info"] = funcs.deepclone(newinfo.info), 
			["timestamp"] = getunixtime()
		})
		
		if not updated then print(result) end
		
		return updated
	end
	
	local foundtx ; for _,t in pairs(sellerdata.Data.completedtx) do if t.id == newinfo.txid then foundtx = true ; break end end
	if foundtx then noti(seller, "Transaction already completed", "red") return false, nil end
	
	-- Remove toy from seller display
	local olddisplayinfo
	for i,v in pairs(sellerdata.Data.base.displays) do
		if v.info and v.info.itemname == newinfo.info.itemname and v.info.serial == newinfo.info.serial and v.info.originalid == newinfo.info.originalid then
			olddisplayinfo = {index = i, datainfo = funcs.deepclone(v)}
			sellerdata.Data.base.displays[i] = {}
			break
		end
	end
	
	--Add cash to seller
	sellerdata.Data.cash += newinfo.price
	
	--Add transaction id
	sellerdata.Data.completedtx[#sellerdata.Data.completedtx + 1] = {
		id = newinfo.txid, 
		timestamp = getunixtime() + deletionstamp
	}
	
	updateleaderstats(seller, sellerdata.Data.cash, newinfo.price)
	updatebasedisplay(sellerid, olddisplayinfo and olddisplayinfo.index, {})
	noti(seller, newinfo.info.itemname.." (#"..tostring(newinfo.info.serial)..")".." sold for $"..shared.addcommas(newinfo.price), "green")
	
	return true, olddisplayinfo
end

local function rollbackTransaction(buyer, buyerdata, seller, sellerdata, olddisplayinfo, newinfo)
	if buyer and buyerdata then
		buyerdata.Data.cash += newinfo.price
		mainfunctions.toy("remove", {buyer, buyerdata}, newinfo.info)
		updateleaderstats(buyer, buyerdata.Data.cash, newinfo.price)
	end
	
	if seller and sellerdata and olddisplayinfo then
		sellerdata.Data.base.displays[olddisplayinfo.index] = olddisplayinfo.datainfo
		updatebasedisplay(seller.UserId, olddisplayinfo and olddisplayinfo.index, olddisplayinfo and olddisplayinfo.datainfo)
	end
end

function module.buyitem(plr, key)
	local now = getunixtime()
	
	local plrid, plrdata = plr.UserId, data.getdata(plr)
	if not plrdata then return noti(plr, "Error while getting player data", "red") end
	
	--Generate transaction id
	local transactionid = services.http:GenerateGUID(false)
	if not transactionid then return noti(plr, "Error while buying auction item", "red") end
	
	
	local resultstatus
	
	local success, newinfo = pcall(function()
		return auction:UpdateAsync(key, function(oldinfo)
			if not oldinfo or not oldinfo.info or not oldinfo.expire then
				resultstatus = "Auction item does not exist"
				return nil
			end

			--Auction state checks inside atomic block
			if oldinfo.removed then
				resultstatus = "Auction item was removed"
				return oldinfo
			elseif oldinfo.bought then
				resultstatus = "Auction item was bought already"
				return oldinfo
			elseif oldinfo.hasexpired or now >= oldinfo.expire then
				resultstatus = "Auction item has expired"
				return oldinfo
			end

			--Ownership check
			if oldinfo.info.ownerid == plrid then
				resultstatus = "Cannot buy your own item"
				return oldinfo
			end

			--Funds check
			if plrdata.Data.cash < oldinfo.price then
				resultstatus = "Not enough cash"
				return oldinfo
			end
			
			--Mark auction
			oldinfo.bought = plrid
			oldinfo.seller = oldinfo.info.ownerid
			oldinfo.txid = oldinfo.txid or transactionid
			oldinfo.state = "sold_pending"
			
			return oldinfo
		end, auctionexpire + 1800)
	end)
	
	if resultstatus then
		return noti(plr, resultstatus, "red")
	end
	
	if not success or not newinfo then
		return noti(plr, "Failed to mark auction as pending", "red")
	end
	
	
	--Process buyer and seller
	local buyerSuccess = processBuyer(plrid, plr, plrdata, newinfo)
	local seller = game.Players:GetPlayerByUserId(newinfo.seller)
	local sellerdata = seller and data.getdata(seller)
	local sellerSuccess, olddisplayinfo = processSeller(newinfo.seller, seller, sellerdata, newinfo)
	
	
	-- Rollback if needed
	if not buyerSuccess or not sellerSuccess then		
		rollbackTransaction(plr, plrdata, seller, sellerdata, olddisplayinfo, newinfo)
		
		local timeleft = math.max(newinfo.expire - now, 1)
		auction:UpdateAsync(key, function(oldinfo)
			if not oldinfo then return nil end
			
			if oldinfo.bought and oldinfo.txid == transactionid then
				oldinfo.bought = nil
				oldinfo.seller = oldinfo.info and oldinfo.info.ownerid
				oldinfo.txid = nil
				oldinfo.state = nil
			end
			
			return oldinfo
		end, timeleft)
		
		return noti(plr, "Transaction failed, rollback applied", "red")
	end
	
	--Finalize auction
	local s,e = pcall(function()
		return auction:UpdateAsync(key, function(oldinfo)
			if oldinfo.state and oldinfo.state == "sold_pending" then oldinfo.state = "sold_complete" end
			
			return oldinfo
		end, 600)
	end) ; if not s then print(e) end
	
	--Decrease auction house total by 1
	updateCounter(-1)

	--Notify other servers
	module.auctionalert((not seller and newinfo.seller) or 0, {
		["itemname"] = newinfo.info.itemname, 
		["serial"] = newinfo.info.serial,
		["originalid"] = newinfo.info.originalid,
		["result"] = "sold"
	})
	
	return true
end


--\\ ADD ITEM TO AUCTION //--
local function validateItem(plr, info, price)
	if not info or not info.itemname then
		noti(plr, "Error while placing item on auction (1)", "red")
		return false
	end

	local toyinfo = toys.toys[info.itemname]
	if not toyinfo then
		noti(plr, "Error while finding toy info", "red")
		return false
	end

	return true
end

local function createData(info, price, now)
	-- Build data table used in memory store
	local newdata = {
		["price"] = price, --Item price
		["info"] = funcs.deepclone(info), --Deep clone of item info preventing mutations
		["expire"] = now + auctionexpire --Expiration of item
	}

	-- Save snapshot of toy's money to display in auction gui
	local newper,_ = mainfunctions.updateper(info, "", false, nil)
	newdata.savedper = newper

	-- Save snapshot of toy's quality to display in auction gui
	newdata.info.qualityleft = math.max((newdata.info.qualityfinish or now) - now, 0)
	
	return newdata
end

function module.additem(plr, info, price)
	local now = getunixtime()
	
	--Reserving auction house slot
	local countsuccess, newcount = updateCounter(1)
	if not countsuccess then return false, "Error while placing item on auction (1)" end
	
	--Create unique key and data
	local auctionkey = info.itemname.."_"..tostring(info.serial).."_"..tostring(info.originalid)
	local newdata = createData(info, price, now)

	--Add item to auction house
	local success,result = pcall(function()
		return auction:SetAsync(auctionkey, newdata, auctionexpire, newcount)
	end)
	
	if success then
		--Return data if success
		return true, newdata
	else
		--Rollback Failure
		updateCounter(-1)
		
		return false, "Couldn't place toy on sale"
	end
end


--\\ REMOVE ITEM FROM AUCTION //--
local function collectInboxDeliveries(plrid)
	local deliveries = {}
	
	local success, result = pcall(function()
		return auctioninboxes:UpdateAsync(plrid, function(oldinbox)
			local now = getunixtime()
			
			oldinbox = oldinbox or {}

			--Loop through inbox in reverse order to clear out entries that aren't delivered
			for i = #oldinbox, 1, -1 do
				local entry = oldinbox[i]

				if not entry.delivered then
					entry.delivered = true

					if entry.info then 
						entry.info.auctioncooldown = now + itemcooldown 
					end

					table.insert(deliveries, entry)
					table.remove(oldinbox, i)
				end
			end

			return oldinbox
		end)
	end) ; if not success then print(result) end
	
	return success, deliveries
end

local function updateAuctionState(key)
	local removedbyseller
	local outcome = ""

	--Find if bought/expired
	local success, result = pcall(function()
		return auction:UpdateAsync(key, function(oldinfo)
			local now = getunixtime()
			
			if not oldinfo or not oldinfo.info then 
				outcome = "Auction item does not exist" 
				return nil 
			end
			
			local itemname = oldinfo.info.itemname or "???"
			local itemserial = oldinfo.info.serial or 0
			
			if oldinfo.removed then
				outcome = itemname.." (#"..tostring(itemserial)..") was removed from auction" 
				return oldinfo
			elseif oldinfo.bought then
				outcome = itemname.." (#"..tostring(itemserial)..") was bought already" 
				return oldinfo
			elseif oldinfo.hasexpired or (oldinfo.expire and now >= oldinfo.expire) then
				oldinfo.hasexpired = true
				outcome = itemname.." (#"..tostring(itemserial)..") has expired already" 
				return oldinfo
			end

			--Set auction state
			oldinfo.hasexpired = true
			oldinfo.removed = true
			removedbyseller = true

			return oldinfo
		end, auctionexpire + 1800)
	end)
	
	return success, result, removedbyseller, outcome
end

local function expiredfromDisplay(plr, plrdata, iteminfo, removedbyseller, deliveries)
	if not iteminfo then return false, nil end
	
	local now = getunixtime()
	
	local plrid = plr.UserId
	local plrdisplays = plrdata.Data.base.displays
	local index
	
	--Find display index if there is any
	for i,v in pairs(plrdisplays) do
		if not v.info then continue end
		
		if iteminfo.info then
			if v.info.itemname == iteminfo.info.itemname and v.info.serial == iteminfo.info.serial and v.info.originalid == iteminfo.info.originalid then
				index = i

				if not removedbyseller and v.expire and now >= v.expire and (not iteminfo or iteminfo and not iteminfo.bought) then
					removedbyseller = true
				end

				break
			end
		elseif iteminfo.itemname and iteminfo.serial and iteminfo.originalid then
			if v.info.itemname == iteminfo.itemname and v.info.serial == iteminfo.serial and v.info.originalid == iteminfo.originalid then
				index = i

				if not removedbyseller and v.expire and now >= v.expire then
					removedbyseller = true
				end

				break
			end
		end
	end
	
	if not index then return false, nil end
	
	local displayinfo = plrdisplays[index]
	local newdelivery
	
	if removedbyseller and displayinfo and displayinfo.info then
		local newinfo = funcs.deepclone(displayinfo.info)
		newinfo.ownerid = plrid
		newinfo.auctioncooldown = now + itemcooldown
		
		--Check if delivery is already logged
		local found
		for _,t in ipairs(deliveries) do
			if t.info and t.info.itemname == newinfo.itemname and t.info.serial == newinfo.serial and t.info.originalid == newinfo.originalid then found = true end
		end
		
		--Add to deliveries if expired or removed if not already logged
		if not found then
			if now >= displayinfo.expire then
				newdelivery = {type = "expiration", id = displayinfo.id, info = newinfo}
			elseif removedbyseller then
				newdelivery = {type = "removed", id = displayinfo.id, info = newinfo}
			end
		end
	end
	
	plrdisplays[index] = {}
	
	return removedbyseller, newdelivery
end

local function makeDeliveries(plr, plrdata, deliveries)
	local now = getunixtime()
	local totalcash = 0
	
	for _,v in ipairs(deliveries) do
		if not v.type or not v.info then continue end
		
		v.id = v.id or services.http:GenerateGUID(false)

		--Check if this transaction was already completed
		local foundtx ; for _,t in pairs(plrdata.Data.completedtx) do if t.id == v.id then foundtx = true ; break end end
		if foundtx then continue end	

		local notimsg = "" --Noti message for plr

		--Add item to inventory
		if v.type == "expiration" or v.type == "removed" then --If item was removed (manual removal or expiration)
			mainfunctions.toy("add", {plr, plrdata}, v.info)		
			notimsg = v.info.itemname.." (#"..tostring(v.info.serial)..") "..(v.type == "expiration" and "has expired in auction" or "removed from auction")
		else
			if v.cash > 0 then --If item was sold give cash
				plrdata.Data.cash += v.cash
				totalcash += v.cash
				notimsg = v.info.itemname.." (#"..tostring(v.info.serial)..")".." sold for $"..shared.addcommas(v.cash)
			elseif v.cash < 0 then --If item was bought give toy
				mainfunctions.toy("add", {plr, plrdata}, v.info)
				notimsg = v.info.itemname.." (#"..tostring(v.info.serial)..")".." bought for $"..shared.addcommas(math.abs(v.cash))
			end
		end

		--Remove from display if there (extra protection)
		for r,t in pairs(plrdata.Data.base.displays) do
			if t.info and v.info and t.info.itemname == v.info.itemname and t.info.serial == v.info.serial and t.info.originalid == v.info.originalid then
				plrdata.Data.base.displays[r] = {}
				break
			end
		end

		--Add Transaction id
		plrdata.Data.completedtx[#plrdata.Data.completedtx + 1] = {id = v.id, timestamp = getunixtime() + deletionstamp}

		--Trim Transaction Ids
		for i = #plrdata.Data.completedtx, 1, -1 do
			local current = plrdata.Data.completedtx[i]
			if not current then continue end

			if now >= current.timestamp then table.remove(plrdata.Data.completedtx, i) end
		end

		--Send Notification
		noti(plr, notimsg, "green")
	end
	
	return totalcash
end

function module.removeitem(allkeys, plrinfo, sendalert, studioprint)
	local plr, plrdata = plrinfo[1], plrinfo[2]
	local plrid = plr.UserId
	
	--Check for outstanding deliveries
	local inboxsuccess, deliveries = collectInboxDeliveries(plrid)
	if not inboxsuccess then return "Couldn't find inbox" end
	
	local keysremoved = 0
	
	--Run through manual deliveries
	for _,v in ipairs(allkeys) do
		
		--Check if toy was removed from auction manually
		local success, info, removedbyseller, outcome = updateAuctionState(v.key)
		if not success then
			noti(plr, outcome, "red")
			continue
		end
		
		--Add to key total for accurate counter removal amount
		if removedbyseller then keysremoved += 1 end
		
		--Check if toy expired while on display
		local removed, newdelivery = expiredfromDisplay(plr, plrdata, info or v, removedbyseller, deliveries)
		
		if newdelivery then table.insert(deliveries, newdelivery) end
		
		if removed and sendalert then
			module.auctionalert(0, {
				itemname = v.itemname,
				serial = v.serial,
				originalid = v.originalid,
				result = "removed"
			})
		end
	end
	
	
	--MAKE ALL DELIVERIES
	local totalcash = makeDeliveries(plr, plrdata, deliveries)
	
	--Update player leaderstats
	if totalcash > 0 then
		updateleaderstats(plr, plrdata.Data.cash, totalcash) 
	end
	
	--Update counter
	updateCounter(keysremoved)
	
	return true
end


--\\ GRAB ITEMS FROM AUCTION //--
function module.getnewitems()
	--[[
	NOTES:
	This function runs every 2-3 minutes to refresh the server's storage
	Players can then choose from the server's storage every minute.
	]]
	
	
	--Grab global auction total & return empty if there are no items in the global auction
	local total = counter:GetAsync("count") or 0
	if total <= 0 then return {} end
	
	
	local itemrng = rng:NextInteger(0, total) -- Select a random starting point in the total auction list
	local maxnumber = 100 -- Total items to retrieve
	
	
	--List of items to return
	local result, items1, items2 = {}, {}, {}
	
	
	--Get 100 items from the starting point moving forward
	local s1,e1 = pcall(function() 
		items1 = auction:GetRangeAsync(Enum.SortDirection.Ascending, maxnumber, {["sortKey"] = itemrng - 1}, nil) 
	end) ; if not s1 then print(e1) end
	
	
	--Get 100 items from the starting point moving backwards if max number is not reached
	if #items1 < maxnumber then
		local s2, e2 = pcall(function()
			items2 = auction:GetRangeAsync(Enum.SortDirection.Descending, maxnumber - #items1, nil, {["sortKey"] = itemrng}) 
		end) ; if not s2 then print(e2) end
	end
	
	
	--Add only values to the results table from both items lists
	for _,v in ipairs(items1) do result[#result+1] = v.value end
	for _,v in ipairs(items2) do result[#result+1] = v.value end
	
	
	--Return result
	return result
end


--\\ ALERT SERVERS //--
function module.auctionalert(sellerid, iteminfo, bypass)
	if not isstudio and not bypass then
		--send message
		shared.stackmsg("auctionalert", {id = sellerid, info = iteminfo})
	else
		for _,plr in pairs(game.Players:GetPlayers()) do
			local plrdata = data.getdata(plr)
			if not plrdata then continue end --skip if no data

			--Check seller's inbox
			if sellerid and plr.UserId == sellerid then
				local auctionkey = iteminfo.itemname.."_"..tostring(iteminfo.serial).."_"..tostring(iteminfo.originalid)
				local key = {["key"] = auctionkey, ["itemname"] = iteminfo.itemname, ["serial"] = iteminfo.serial, ["originalid"] = iteminfo.originalid}
				task.spawn(function() module.removeitem({key}, {plr, plrdata}) end)
			end

			--Check everyone's market items
			for r,t in ipairs(plrdata.Data.shops.market["items"] or {}) do
				if not t or not t.info then continue end

				if t.info["itemname"] == iteminfo["itemname"] and t.info["serial"] == iteminfo["serial"] and t.info["originalid"] == iteminfo["originalid"] then
					plrdata.Data.shops.market["items"][r]["result"] = iteminfo.result or "removed"
				end
			end

			--Change server market item
			require(script.Parent).marketchange(iteminfo)

			--Notify all players
			services.rs.remotes.shopnoti:FireAllClients("global market", iteminfo)
		end
	end	
end


--
return module

