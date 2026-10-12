--
-- cc-power-link Clock
-- Wall clock in UTC milliseconds
--
-- cc-mek-scada's util.time_ms() uses the server's local time zone, which jumps back an hour when daylight saving
-- ends. Sequence numbers, telemetry timestamps and the stale timer must never go backwards, so use UTC.
--

local clock = {}

-- current time in milliseconds since the epoch, UTC
---@nodiscard
---@return integer milliseconds
function clock.now_ms() return os.epoch("utc") end

return clock
