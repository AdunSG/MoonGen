local dpdk		= require "dpdk"
local memory	= require "memory"
local device	= require "device"
local ts		= require "timestamping"
local dpdkc		= require "dpdkc"
local filter	= require "filter"
local ffi		= require "ffi"

function master(...)
	local portA, portB, rate, size = tonumberall(...)
	if not portA or not portB then
		errorf("usage: portA portB [rate [size]]")
	end
	rate = rate or 2000
	size = (size or 128) - 4
	local rxMempool = memory.createMemPool()
	if portA == portB then
		errorf("you must define 2 different ports")
	else
		devA = device.config(portA, rxMempool, 1, 2)
		devB = device.config(portB, rxMempool, 2, 1)
		device.waitForDevs(devA, devB)
	end
	
	devA:getTxQueue(1):setRate(rate)
	devB:getTxQueue(1):setRate(rate)
	
	dpdk.launchLua("timerSlave", portA, portB, 0, 0, size)
	dpdk.launchLua("trafficSlave", portA, 1, size)
	
	dpdk.launchLua("timerSlave", portB, portA, 0, 0, size)
	dpdk.launchLua("trafficSlave", portB, 1, size)
	
	dpdk.waitForSlaves()
end

function trafficSlave(port, queue, size)
	local queue = device.get(port):getTxQueue(queue)
	local mempool = memory.createMemPool(function(buf)
		ts.fillPacket(buf, 1234, size) 
		local data = ffi.cast("uint8_t*", buf.pkt.data)
		data[43] = 0x00 -- PTP version, set to 0 to disable timestamping for load packets
	end)
	local lastPrint = dpdk.getTime()
	local totalSent = 0
	local totalRecv = 0
	local lastTotal = 0
	local lastSent = 0
	local bufs = mempool:bufArray(128)
	local srcIP = parseIPAddress("192.168.240." .. port)
	local dstIP
	if(port == 8) then
		dstIP = parseIPAddress("192.168.240.9")
	else
		dstIP = parseIPAddress("192.168.240.8")
	end
	while dpdk.running() do
		bufs:fill(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUDPPacket()
			pkt.ip.src:set(srcIP)
			pkt.ip.dst:set(dstIP)
		end
		-- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
		bufs:offloadUdpChecksums()
		totalSent = totalSent + queue:send(bufs)
		local time = dpdk.getTime()
		if time - lastPrint > 1 then
			--Sending
			local mpps = (totalSent - lastTotal) / (time - lastPrint) / 10^6
			printf("Sent %d packets, current rate %.2f Mpps, %.2f MBit/s, %.2f MBit/s wire rate", totalSent, mpps, mpps * (size + 4) * 8, mpps * (size + 24) * 8)
			lastTotal = totalSent
			--Receiving
			local pkts = dev:getRxStats(port)
			totalRecv = totalRecv + pkts
			printf("Received %d packets, current rate %.2f Mpps", total, pkts / elapsed / 10^6)
			lastPrint = time
		end
	end
	printf("Sent %d packets", totalSent)
end

function timerSlave(txPort, rxPort, txQueue, rxQueue, size)
	local txDev = device.get(txPort)
	local rxDev = device.get(rxPort)
	local txQueue = txDev:getTxQueue(txQueue)
	local rxQueue = rxDev:getRxQueue(rxQueue)
	local mem = memory.createMemPool()
	local bufs = mem:bufArray(1)
	local rxBufs = mem:bufArray(128)
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps(1234)
	rxDev:filterTimestamps(rxQueue)
	
	local srcIP = parseIPAddress("192.168.240." .. txPort)
	local dstIP = parseIPAddress("192.168.240." .. rxPort)
	local hist = {}
	-- wait one second, otherwise we might start timestamping before the load is applied
	dpdk.sleepMillis(1000)
	
	while dpdk.running() do
		bufs:fill(size + 4)
		local pkt = bufs[1]:getUDPPacket()
		ts.fillPacket(bufs[1], 1234, size + 4)
		pkt.ip.src:set(srcIP)
		pkt.ip.dst:set(dstIP)
		bufs:offloadUdpChecksums()
		-- sync clocks and send
		ts.syncClocks(txDev, rxDev)
		txQueue:send(bufs)
		-- increment the wait time when using large packets or slower links
		local tx = txQueue:getTimestamp(100)
		if tx then
			dpdk.sleepMicros(500) -- minimum latency to limit the packet rate
			-- sent was successful, try to get the packet back (max. 10 ms wait time before we assume the packet is lost)
			local rx = rxQueue:tryRecv(rxBufs, 10000)
			if rx > 0 then
				local numPkts = 0
				for i = 1, rx do
					if bit.bor(rxBufs[i].ol_flags, dpdk.PKT_RX_IEEE1588_TMST) ~= 0 then
						numPkts = numPkts + 1
					end
				end
				local delay = (rxQueue:getTimestamp() - tx) * 6.4
				if numPkts == 1 then
					if delay > 0 and delay < 100000000 then
						hist[delay] = (hist[delay] or 0) + 1
					end
				end -- else: got more than one packet, so we got a problem
				-- TODO: use sequence numbers in the packets to avoid bugs here
				rxBufs:freeAll()
			end
		end
	end
	local sortedHist = {}
	for k, v in pairs(hist) do 
		table.insert(sortedHist,  { k = k, v = v })
	end
	local sum = 0
	local samples = 0
	table.sort(sortedHist, function(e1, e2) return e1.k < e2.k end)
	print("Histogram:")
	for _, v in ipairs(sortedHist) do
		sum = sum + v.k * v.v
		samples = samples + v.v
		print(v.k, v.v)
	end
	print()
	print("Average: " .. (sum / samples) .. " ns, " .. samples .. " samples")
	print("----------------------------------------------")
end

