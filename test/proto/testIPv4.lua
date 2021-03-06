describe("IPv4 class", function()
	local ffi = require "ffi"
	local pkt = require "packet"
	it("should parse", function()
		local ip = parseIP4Address("1.2.3.4")
		assert.are.same(ip, 0x01020304)
	end)
	it("should return in correct byteorder", function()
		local ipString = "123.56.200.42"
		local ip = ffi.new("union ipv4_address")
		ip:setString(ipString)
	
		assert.are.same(ipString, ip:getString())
	end)
	it("should support ==", function()
		-- in uint32 format
		local ip = parseIP4Address("123.56.200.42")
		local ip2 = parseIP4Address("123.56.200.42")
		local ip3 = parseIP4Address("123.56.200.43")

		assert.are.same(ip, ip2)
		assert.are.not_same(ip, ip3)
		assert.are.not_same(ip, 0)

		-- in ipv4_address format
		local ipAddress = ffi.new("union ipv4_address")
		local ipAddress2 = ffi.new("union ipv4_address")
		local ipAddress3 = ffi.new("union ipv4_address")
		ipAddress:set(ip)
		ipAddress2:set(ip2)
		ipAddress3:set(ip3)

		assert.are.same(ip, ip2)
		assert.are.not_same(ip, ip3)
		assert.are.not_same(ip, 0)
	end)
	it("should do arithmetic", function()
		local ip = parseIP4Address("0.0.0.0") + 1
		assert.are.same(ip, parseIP4Address("0.0.0.1"))
		ip = ip + 256
		assert.are.same(ip, parseIP4Address("0.0.1.1"))
		ip = ip - 2
		assert.are.same(ip, parseIP4Address("0.0.0.255"))
	end)

end)

