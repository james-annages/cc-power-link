--
-- cc-power-link Network Layer
-- Wireless NIC bring-up plus receive-side checks, built on cc-mek-scada's comms/network/ppm
--

local comms    = require("scada-common.comms")
local log      = require("scada-common.log")
local network  = require("scada-common.network")
local ppm      = require("scada-common.ppm")
local util     = require("scada-common.util")
local array    = require("lockbox.util.array")

local clock    = require("ccpl.clock")
local protocol = require("ccpl.protocol")

local link = {}

-- log every Nth rejection of each kind so a noisy network can't flood the log
local LOG_EVERY = 100

-- create a new link
---@nodiscard
---@param cfg table validated configuration
---@param role "sender"|"display"
---@return ccpl_link|nil lk, string|nil error_message
function link.new(cfg, role)
    local is_sender = role == "sender"

    -- mount all peripherals (the sender also uses this to find the matrix)
    ppm.mount_all()

    local modem = ppm.get_wireless_modem()

    if modem == nil then return nil, "no wireless or ender modem found" end

    -- message authentication only applies to wireless modems (the NIC skips it otherwise)
    local use_auth = #cfg.AuthKey > 0 and modem.isWireless()

    -- message authentication must be set up before the NIC connects to the modem
    if #cfg.AuthKey > 0 then
        -- the key derivation expects a byte array; handing it a string leaves the key independent of the passkey
        local ms = network.init_mac(array.fromString(cfg.AuthKey))
        log.info("LINK: message authentication ready (" .. ms .. "ms)")
    end

    -- across dimensions the modem reports no distance, so a range limit would drop everything
    comms.set_trusted_range(cfg.TrustedRange)

    local listen_chan = util.trinary(is_sender, cfg.SenderChannel, cfg.DisplayChannel)
    local dest_chan   = util.trinary(is_sender, cfg.DisplayChannel, cfg.SenderChannel)

    -- only the display probes (link layer discovery), the sender just answers probes
    local nic = network.nic(modem, util.trinary(is_sender, nil, cfg.SenderChannel))

    nic.closeAll()
    nic.open(listen_chan)

    local self = {
        seq = clock.now_ms() * 10, -- restarting won't re-use sequence numbers due to the message rate (UTC, never goes back)
        last_src = nil,            ---@type integer|nil
        last_seq = -1,
        was_up = false,
        stats = { auth = 0, peer = 0, order = 0, malformed = 0, accepted = 0 }
    }

    ---@class ccpl_link
    local public = {}

    -- the NIC (for peripheral queries)
    public.nic = nic

    -- send a message to the other end
    ---@param msg_type CCPL_MSG
    ---@param fields table
    function public.send(msg_type, fields)
        local dest = util.trinary(cfg.PeerID ~= 0, cfg.PeerID, comms.BROADCAST)

        nic.transmit(dest_chan, listen_chan, protocol.make_frame(dest, self.seq, msg_type, fields))
        self.seq = self.seq + 1
    end

    -- count a rejection and occasionally log it
    ---@param kind string
    ---@param detail string
    local function reject(kind, detail)
        self.stats[kind] = self.stats[kind] + 1

        if self.stats[kind] % LOG_EVERY == 1 then
            log.warning(util.c("LINK: rejected message (", detail, ") [", self.stats[kind], " total]"))
        end
    end

    -- handle a modem_message event<br>
    -- returns the decoded message if it passed every check
    ---@nodiscard
    ---@param side string
    ---@param channel integer
    ---@param reply_to integer
    ---@param message any
    ---@param distance number|nil
    ---@return CCPL_MSG|nil msg_type, table|nil message
    function public.receive(side, channel, reply_to, message, distance)
        local frame = nic.receive(side, channel, reply_to, message, distance)

        -- nil for other traffic and link layer discovery
        if frame == nil or frame.protocol() ~= protocol.PROTOCOL then return nil, nil end

        -- the NIC passes frames up even when the HMAC failed, so the application has to check
        if use_auth and not frame.is_authenticated() then
            reject("auth", "failed authentication from computer " .. frame.src_addr())
            return nil, nil
        end

        if cfg.PeerID ~= 0 and frame.src_addr() ~= cfg.PeerID then
            reject("peer", "unexpected computer " .. frame.src_addr())
            return nil, nil
        end

        local msg_type, msg = protocol.decode(frame)

        if msg_type == nil then
            reject("malformed", "malformed message from computer " .. frame.src_addr())
            return nil, nil
        end

        -- sequence numbers only move forward per source, a new source starts over
        local src, seq = frame.src_addr(), frame.seq_num()

        if src ~= self.last_src then
            self.last_src = src
            self.last_seq = -1
        end

        if seq <= self.last_seq then
            reject("order", "out of order from computer " .. src)
            return nil, nil
        end

        self.last_seq = seq
        self.stats.accepted = self.stats.accepted + 1

        return msg_type, msg
    end

    -- run the NIC's periodic link detection, logging link changes<br>
    -- returns true if the network link appears up
    ---@return boolean link_up
    function public.periodic()
        local up = nic.periodic()

        if up ~= self.was_up then
            self.was_up = up
            log.info("LINK: network link " .. util.trinary(up, "up", "down"))
        end

        return up
    end

    -- handle a peripheral attach event, returns the mounted type and device
    ---@param iface string
    ---@return string|nil type, ppm_generic|nil device
    function public.handle_attach(iface)
        local ptype, dev = ppm.mount(iface)

        if ptype == "modem" and dev and dev.isWireless() and not nic.is_connected() then
            nic.connect(dev --[[@as Modem]])
            log.info("LINK: modem reconnected on " .. iface)
        end

        return ptype, dev
    end

    -- handle a peripheral detach event, returns the unmounted type and device
    ---@param iface string
    ---@return string|nil type, ppm_generic|nil device
    function public.handle_detach(iface)
        local ptype, dev = ppm.handle_unmount(iface)

        if ptype == "modem" and dev and nic.is_modem(dev) then
            nic.disconnect()
            log.warning("LINK: modem lost on " .. iface)
        end

        return ptype, dev
    end

    -- get the rejection/acceptance counters
    ---@nodiscard
    function public.get_stats() return self.stats end

    -- check if the modem is connected
    ---@nodiscard
    function public.is_connected() return nic.is_connected() end

    return public, nil
end

return link
