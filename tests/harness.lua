-- tiny test harness; each test file returns the number of failures
local H = { fails = 0, passes = 0 }
function H.check(cond, msg)
    if cond then H.passes = H.passes + 1 else H.fails = H.fails + 1; print("  FAIL: " .. msg) end
end
function H.eq(a, b, msg) H.check(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
function H.near(a, b, tol, msg) H.check(type(a) == "number" and math.abs(a - b) <= tol, string.format("%s (got %s, want ~%s)", msg, tostring(a), tostring(b))) end
function H.has(s, sub, msg) H.check(type(s) == "string" and s:find(sub, 1, true) ~= nil, string.format("%s (missing %q)", msg, sub)) end
function H.hasnt(s, sub, msg) H.check(type(s) == "string" and s:find(sub, 1, true) == nil, string.format("%s (unexpected %q)", msg, sub)) end
function H.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then H.fails = H.fails + 1; print("  ERROR in " .. name .. ": " .. tostring(err)) end
end
function H.done() print(string.format("  %d passed, %d failed", H.passes, H.fails)) return H.fails end
return H
