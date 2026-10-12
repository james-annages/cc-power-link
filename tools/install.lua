--
-- cc-power-link Installer
--
--   install <sender|display>   install a role on this computer (first time)
--   update                     update to the newest published version
--   check                      compare this computer with the published version
--   remove [--purge]           uninstall (--purge also deletes the configuration)
--
-- options: --url <address>  where the published files are (remembered after install)
--          -y               do not ask questions
--          --no-self-update do not replace this installer with the published one first
--
-- Every run first compares this installer with the one published next to the files and switches to the newer
-- one, so a copy of this file that was uploaded once (for example to pastebin) never needs to be updated by hand.
-- Running it with no command on a computer that already has cc-power-link installed updates that computer.
--

local INSTALLER_VERSION = "1.1"

-- where the published files are, filled in when the project is built
local DEFAULT_URL = "@BASE_URL@"

local RECORD   = "/ccpl_install.json"
local STAGING  = "/.ccpl-staging"
local KEEP     = { ["/ccpl_sender.cfg"] = true, ["/ccpl_display.cfg"] = true }

-- files from before the project was renamed (it was called "ESS Link"): read once, then moved to the new names
local LEGACY_RECORD = "/ess_install.json"
local LEGACY_CONFIGS = { sender = "/ess_sender.cfg", display = "/ess_display.cfg" }

local args = { ... }

----------------------------------------
-- output
----------------------------------------

local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function say(c, text) color(c); print(text); color(colors.white) end
local function info(text) say(colors.white, text) end
local function good(text) say(colors.green, text) end
local function warn(text) say(colors.yellow, text) end
local function bad(text) say(colors.red, text) end

local assume_yes = false

-- ask a yes/no question, default no
---@return boolean
local function ask(question)
    if assume_yes then return true end

    color(colors.yellow)
    write(question .. " [y/N] ")
    color(colors.white)

    local answer = read()

    return answer ~= nil and (answer:lower() == "y" or answer:lower() == "yes")
end

----------------------------------------
-- helpers
----------------------------------------

-- Adler-32 checksum of a string (catches truncated or damaged downloads)
local function adler32(data)
    local a, b = 1, 0

    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end

    return b * 65536 + a
end

local function read_all(path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local data = f.readAll()
    f.close()
    return data
end

local function write_all(path, data)
    local f = fs.open(path, "wb")
    if not f then return false end
    f.write(data)
    f.close()
    return true
end

-- download a URL, three tries
---@return string|nil body, string|nil error
local function download(url)
    local err = "unknown error"

    for attempt = 1, 3 do
        local resp, e = http.get({ url = url, binary = true })

        if resp then
            local body = resp.readAll()
            resp.close()

            if body then return body, nil end

            err = "empty response"
        else
            err = tostring(e)
        end

        if attempt < 3 then sleep(attempt / 2) end
    end

    return nil, err
end

local function join_url(base, path)
    if base:sub(-1) ~= "/" then base = base .. "/" end
    return base .. path
end

local function read_record()
    local data = read_all(RECORD) or read_all(LEGACY_RECORD)
    if not data then return nil end

    local ok, rec = pcall(textutils.unserializeJSON, data)

    if ok and type(rec) == "table" then return rec end

    return nil
end

local function write_record(rec)
    return write_all(RECORD, textutils.serializeJSON(rec))
end

-- move the configuration files and install record of the old project name to the new names<br>
-- (the old program files are removed by the update itself, they are listed in the old record)
local function migrate_legacy()
    for role, old in pairs(LEGACY_CONFIGS) do
        local new = "/ccpl_" .. role .. ".cfg"

        if fs.exists(old) and not fs.exists(new) then
            local text = read_all(old)

            if text then
                -- the default log file was renamed too
                text = text:gsub('"/ess%.log"', '"/ccpl.log"')

                if write_all(new, text) then
                    fs.delete(old)
                    info("moved " .. old .. " to " .. new)
                end
            end
        end
    end

    if fs.exists(LEGACY_RECORD) then fs.delete(LEGACY_RECORD) end
end

-- remove empty directories above a deleted file
local function prune(path)
    local dir = fs.getDir(path)

    while dir ~= "" and fs.isDir(dir) and #fs.list(dir) == 0 do
        fs.delete(dir)
        dir = fs.getDir(dir)
    end
end

-- count the files of a role that are missing or differ from the published version
---@return integer problems, string[] details
local function find_problems(spec)
    local problems, details = 0, {}

    for _, f in ipairs(spec.files) do
        local data = read_all("/" .. f.path)

        if data == nil then
            problems = problems + 1; details[#details + 1] = "missing: " .. f.path
        elseif #data ~= f.size or adler32(data) ~= f.sum then
            problems = problems + 1; details[#details + 1] = "differs from published: " .. f.path
        end
    end

    return problems, details
end

-- manifests already fetched in this run (or the reason they failed), so a flaky server isn't asked twice
local manifest_cache = {}

local function fetch_manifest(base)
    local cached = manifest_cache[base]

    if cached then return cached.manifest, cached.err end

    local manifest, err

    local body, e = download(join_url(base, "manifest.json"))

    if not body then
        err = "could not download the manifest: " .. e
    else
        local ok, parsed = pcall(textutils.unserializeJSON, body)

        if ok and type(parsed) == "table" and type(parsed.roles) == "table" then
            manifest = parsed
        else
            err = "the manifest is not valid"
        end
    end

    manifest_cache[base] = { manifest = manifest, err = err }

    return manifest, err
end

----------------------------------------
-- install / update
----------------------------------------

-- download every file of a role into the staging directory, verifying each, then move them into place
---@return boolean ok
local function deploy(base, manifest, role, previous)
    local spec = manifest.roles[role]

    if not spec then
        bad("the published version has no role '" .. role .. "'")
        return false
    end

    local files = spec.files

    if fs.exists(STAGING) then fs.delete(STAGING) end

    info("downloading " .. #files .. " files...")

    for i, f in ipairs(files) do
        local body, err = download(join_url(base, role .. "/" .. f.path))

        if not body then
            bad("failed: " .. f.path .. " (" .. err .. ")")
            fs.delete(STAGING)
            return false
        end

        if #body ~= f.size or adler32(body) ~= f.sum then
            bad("damaged download: " .. f.path .. ", nothing was changed")
            fs.delete(STAGING)
            return false
        end

        if not write_all(STAGING .. "/" .. f.path, body) then
            bad("could not write " .. f.path .. " (out of space?), nothing was changed")
            fs.delete(STAGING)
            return false
        end

        if i % 10 == 0 or i == #files then info("  " .. i .. "/" .. #files) end
    end

    -- everything arrived intact, now swap the files in
    local paths = {}

    for _, f in ipairs(files) do
        local target = "/" .. f.path

        if fs.exists(target) then fs.delete(target) end

        fs.move(STAGING .. "/" .. f.path, target)
        paths[#paths + 1] = f.path
    end

    fs.delete(STAGING)

    -- delete files from the previous version that no longer exist (never the configuration)
    if previous and previous.files then
        local keep = {}
        for _, p in ipairs(paths) do keep[p] = true end

        for _, p in ipairs(previous.files) do
            if not keep[p] and not KEEP["/" .. p] and fs.exists("/" .. p) then
                fs.delete("/" .. p)
                prune("/" .. p)
                info("removed old " .. p)
            end
        end
    end

    write_record({ role = role, version = manifest.version, url = base, files = paths })

    migrate_legacy()

    -- refresh the installer itself
    if manifest.installer then
        local body = download(join_url(base, manifest.installer.path))

        if body and #body == manifest.installer.size and adler32(body) == manifest.installer.sum then
            write_all("/install.lua", body)
        end
    end

    return true
end

local function parse_options()
    local opts = { positional = {} }
    local i = 1

    while i <= #args do
        local a = args[i]

        if a == "-y" then assume_yes = true
        elseif a == "--url" then i = i + 1; opts.url = args[i]
        elseif a == "--purge" then opts.purge = true
        elseif a == "--no-self-update" then opts.no_self_update = true
        else opts.positional[#opts.positional + 1] = a end

        i = i + 1
    end

    return opts
end

local function finish_install()
    good("done. The first start walks you through the configuration.")

    if ask("reboot now?") then
        sleep(1)
        os.reboot()
    end
end

local function do_install(opts, update)
    local record = read_record()
    local role = opts.positional[2]

    if update then
        if not record then bad("nothing is installed (no " .. RECORD .. "), use: install <sender|display>"); return end
        role = record.role
    elseif role ~= "sender" and role ~= "display" then
        bad("usage: install <sender|display> [--url <address>] [-y]")
        return
    end

    local base = opts.url or (record and record.url) or DEFAULT_URL

    -- (the placeholder is split so the build does not fill it in here)
    if base == "" or base == "@BASE" .. "_URL@" then
        bad("no download address set, use --url <address>")
        return
    end

    if not http then bad("http is disabled on this server, ask the admin to enable it"); return end

    local manifest, err = fetch_manifest(base)

    if not manifest then bad(err); return end

    if update and record.version == manifest.version and manifest.roles[role] then
        local problems = find_problems(manifest.roles[role])

        if problems == 0 then
            good("already up to date (version " .. tostring(manifest.version) .. ")")
            return
        end

        warn(problems .. " file(s) are missing or changed, repairing")
    end

    if record and record.role ~= role then
        warn("this computer is installed as " .. record.role .. ", installing " .. role .. " replaces it")
        if not ask("continue?") then return end
    elseif not record and fs.exists("/startup.lua") then
        warn("/startup.lua already exists and will be overwritten")
        if not ask("continue?") then return end
    end

    info(string.format("%s %s: %s -> %s", update and "updating" or "installing", role,
                       record and tostring(record.version) or "new", tostring(manifest.version)))

    if deploy(base, manifest, role, record) then finish_install() end
end

----------------------------------------
-- check
----------------------------------------

local function do_check(opts)
    local record = read_record()

    if not record then bad("nothing is installed"); return end

    info("installed: " .. record.role .. " " .. tostring(record.version))

    local manifest, err = fetch_manifest(opts.url or record.url)

    if not manifest then bad(err); return end

    local spec = manifest.roles[record.role]
    local problems, details = 0, {}

    if spec then problems, details = find_problems(spec) end

    for _, d in ipairs(details) do warn(d) end

    if manifest.version ~= record.version then
        warn("a newer version is published: " .. tostring(manifest.version) .. " (run: install update)")
    elseif problems == 0 then
        good("up to date, all files match")
    end

    if problems > 0 then warn(problems .. " file(s) differ (run: install update to repair)") end
end

----------------------------------------
-- remove
----------------------------------------

local function do_remove(opts)
    local record = read_record()

    if not record then bad("nothing is installed"); return end

    if not ask("remove cc-power-link " .. record.role .. " from this computer?") then return end

    for _, p in ipairs(record.files or {}) do
        local path = "/" .. p

        if not (KEEP[path] and not opts.purge) and fs.exists(path) then
            fs.delete(path)
            prune(path)
        end
    end

    if opts.purge then
        for path in pairs(KEEP) do if fs.exists(path) then fs.delete(path) end end
        for _, path in pairs(LEGACY_CONFIGS) do if fs.exists(path) then fs.delete(path) end end
    end

    fs.delete(RECORD)
    if fs.exists(LEGACY_RECORD) then fs.delete(LEGACY_RECORD) end

    good("removed" .. (opts.purge and " (including the configuration)" or ", the configuration was kept"))
end

----------------------------------------
-- self update
----------------------------------------

-- if a different installer is published, download it and run it in place of this one<br>
-- returns true if the newer installer ran, so the caller has nothing left to do
---@return boolean handled
local function self_update(opts, record)
    if opts.no_self_update or not http then return false end

    local base = opts.url or (record and record.url) or DEFAULT_URL

    -- (the placeholder is split so the build does not fill it in here)
    if base == "" or base == "@BASE" .. "_URL@" then return false end

    -- a server that can't be reached is reported by the command itself
    local manifest = fetch_manifest(base)
    local want = manifest and manifest.installer

    if type(want) ~= "table" or type(want.path) ~= "string" then return false end

    local self_path = shell and shell.getRunningProgram and shell.getRunningProgram() or "/install.lua"
    local mine = read_all(self_path)

    -- already the published one (or this copy can't be read, e.g. it was run straight from pastebin)
    if mine and #mine == want.size and adler32(mine) == want.sum then return false end

    local body = download(join_url(base, want.path))

    if not body or #body ~= want.size or adler32(body) ~= want.sum then
        warn("a newer installer is published but could not be downloaded, continuing with this one")
        return false
    end

    local fn = load(body, "=install.lua", "t", _ENV or _G)

    if not fn then return false end

    info("installer updated, restarting it")

    -- keep this copy current too (not possible for read-only or missing files)
    if not (fs.exists(self_path) and write_all(self_path, body)) then write_all("/install.lua", body) end

    -- keep the address this run was started with, the published installer may be built for another one
    local again = {}
    for i = 1, #args do again[i] = args[i] end
    if not opts.url then again[#again + 1] = "--url"; again[#again + 1] = base end
    again[#again + 1] = "--no-self-update"

    fn((table.unpack or unpack)(again))

    return true
end

----------------------------------------
-- main
----------------------------------------

local opts = parse_options()
local mode = opts.positional[1]

info("cc-power-link installer v" .. INSTALLER_VERSION)

-- a bare "install" on an installed computer means update (so the one command to remember is always the same)
if mode == nil and read_record() then
    mode = "update"
    opts.positional[1] = mode
end

if mode ~= "remove" and (mode == "sender" or mode == "display" or mode == "update" or mode == "check") then
    if self_update(opts, read_record()) then return end
end

if mode == "sender" or mode == "display" then
    table.insert(opts.positional, 2, mode)
    do_install(opts, false)
elseif mode == "update" then do_install(opts, true)
elseif mode == "check" then do_check(opts)
elseif mode == "remove" then do_remove(opts)
else
    info("usage:")
    info("  install <sender|display> [--url <address>] [-y]")
    info("  install update | check | remove [--purge]")
end
