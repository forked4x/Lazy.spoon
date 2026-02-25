local obj = {}
obj.__index = obj
obj.name = "Lazy"
obj.version = "0.1"
obj.author = "forked4x"
obj.license = "MIT"

local log = hs.logger.new("Lazy", "info")

local function parseMods(mods)
    if type(mods) == "table" then return mods end
    if type(mods) ~= "string" or mods == "" then return {} end
    local result = {}
    for mod in mods:gmatch("[^,%s]+") do
        table.insert(result, mod)
    end
    return result
end

local function addShift(mods)
    local copy = {}
    for i, v in ipairs(mods) do copy[i] = v end
    table.insert(copy, "shift")
    return copy
end

-- Internal state
obj._specs = {}
obj._pendingInstalls = 0
obj._spoons_dir = nil
obj._modal = nil
obj._app_modals = {}     -- app name -> hs.hotkey.modal
obj._app_watcher = nil   -- hs.application.watcher

--- Parse the first element of a LazySpec into a structured table.
--- @param source string The source string (short GitHub path or full URL)
--- @return table|nil Parsed spec info, or nil on error
local function parseSpec(source)
    local url = source
    if not url:match("^https?://") then
        url = "https://github.com/" .. url
    end

    local is_zip = url:match("%.zip$") ~= nil
    local name, dir_name

    if is_zip then
        -- Extract Name from Name.spoon.zip
        name = url:match("([%w_%-]+)%.spoon%.zip$")
        if name then
            dir_name = name .. ".spoon"
        end
    else
        -- Extract Name from trailing Name.spoon segment
        name = url:match("([%w_%-]+)%.spoon/?$")
        if name then
            dir_name = name .. ".spoon"
        end
    end

    if not name then
        log.w("cannot parse spec:", source)
        return nil
    end

    return {
        name = name,
        dir_name = dir_name,
        url = url,
        is_zip = is_zip,
    }
end

--- Shallow git clone a repository.
--- @param url string Repository URL
--- @param dest string Destination path
--- @param callback function Called with (success, error_string)
local function gitClone(url, dest, callback)
    hs.task.new("/usr/bin/git", function(exitCode, stdout, stderr)
        if exitCode == 0 then
            callback(true, nil)
        else
            callback(false, stderr or "git clone failed")
        end
    end, { "clone", "--depth", "1", url, dest }):start()
end

--- Download a zip file and extract it into the Spoons directory.
--- @param url string URL to the .zip file
--- @param spoons_dir string Path to the Spoons directory
--- @param dir_name string Expected directory name (e.g. "Name.spoon")
--- @param callback function Called with (success, error_string)
local function downloadAndExtract(url, spoons_dir, dir_name, callback)
    local tmp_path = "/tmp/" .. dir_name .. ".zip"

    hs.task.new("/usr/bin/curl", function(curlExit, _, curlStderr)
        if curlExit ~= 0 then
            os.remove(tmp_path)
            callback(false, curlStderr or "curl download failed")
            return
        end

        hs.task.new("/usr/bin/unzip", function(unzipExit, _, unzipStderr)
            os.remove(tmp_path)
            if unzipExit == 0 then
                callback(true, nil)
            else
                callback(false, unzipStderr or "unzip failed")
            end
        end, { "-o", "-q", tmp_path, "-d", spoons_dir }):start()
    end, { "-fSL", "-o", tmp_path, url }):start()
end

--- Log installation progress.
function obj:_showProgress(msg)
    log.i(msg)
end

--- Log progress update with current install count.
function obj:_updateProgress(name, remaining)
    log.i("installed", name, "(" .. remaining .. " remaining)")
end

--- Log completion message.
function obj:_closeProgress()
    log.i("all spoons installed!")
end

--- Bind key remappings and hotkeys to a modal.
--- @param keys table Mapping of {mods, key} -> rhs
--- @param modal hs.hotkey.modal The modal to bind keys to
function obj:_bindKeys(keys, modal)
    for lhs, rhs in pairs(keys) do
        local lhs_mods = parseMods(lhs[1])
        local lhs_key = lhs[2]

        if type(rhs) == "function" then
            modal:bind(lhs_mods, lhs_key, rhs)
        elseif type(rhs) == "table" then
            local rhs_mods = parseMods(rhs[1])
            local rhs_key = rhs[2]
            local opts = rhs[3] or {}

            local pressedfn = function()
                hs.eventtap.keyStroke(rhs_mods, rhs_key, 0)
            end

            if opts.noremap then
                local raw = pressedfn
                pressedfn = function()
                    self._modal:exit()
                    local saved = self._active_app_modal
                    if saved then saved:exit() end
                    raw()
                    hs.timer.doAfter(0.1, function()
                        self._modal:enter()
                        if saved then saved:enter() end
                    end)
                end
            end

            local repeatfn = opts.repeat_ and pressedfn or nil
            modal:bind(lhs_mods, lhs_key, pressedfn, nil, repeatfn)

            if opts.shift then
                local shifted_pressedfn = function()
                    hs.eventtap.keyStroke(addShift(rhs_mods), rhs_key, 0)
                end

                if opts.noremap then
                    local raw = shifted_pressedfn
                    shifted_pressedfn = function()
                        self._modal:exit()
                        local saved = self._active_app_modal
                        if saved then saved:exit() end
                        raw()
                        self._modal:enter()
                        if saved then saved:enter() end
                    end
                end

                local shifted_repeatfn = opts.repeat_ and shifted_pressedfn or nil
                modal:bind(addShift(lhs_mods), lhs_key, shifted_pressedfn, nil, shifted_repeatfn)
            end
        end
    end
end

--- Start an application watcher that activates app-specific modals.
function obj:_startAppWatcher()
    self._active_app_modal = nil

    self._app_watcher = hs.application.watcher.new(function(name, event, _)
        if event == hs.application.watcher.activated then
            if self._active_app_modal then
                self._active_app_modal:exit()
                self._active_app_modal = nil
            end
            local modal = self._app_modals[name]
            if modal then
                modal:enter()
                self._active_app_modal = modal
            end
        end
    end)
    self._app_watcher:start()
end

--- Load, configure, and start all parsed specs.
function obj:_loadAndConfigureAll()
    for _, spec in ipairs(self._specs) do
        local name = spec.parsed.name
        local dir = self._spoons_dir .. spec.parsed.dir_name

        -- Verify directory exists
        if not hs.fs.attributes(dir) then
            log.w("missing", name .. ", skipping")
            goto continue
        end

        -- Load the spoon
        local ok, err = pcall(hs.loadSpoon, name)
        if not ok then
            log.w("failed to load", name .. ":", tostring(err))
            goto continue
        end

        local s = spoon[name]

        -- Run config function
        if spec.config and type(spec.config) == "function" and s then
            local cfg_ok, cfg_err = pcall(spec.config, s)
            if not cfg_ok then
                log.w("config error for", name .. ":", tostring(cfg_err))
            end
        end

        -- Start the spoon
        if spec.start and s and s.start then
            local st_ok, st_err = pcall(function() s:start() end)
            if not st_ok then
                log.w("start error for", name .. ":", tostring(st_err))
            end
        end

        ::continue::
    end
end

--- Set up spoons from a list of LazySpec tables.
--- @param specs table List of LazySpec tables
function obj:setup(specs)
    local keys = specs.keys
    if keys then
        local global_keys = {}
        local app_keys = {}

        for k, v in pairs(keys) do
            if type(k) == "string" then
                app_keys[k] = v
            else
                global_keys[k] = v
            end
        end

        if next(global_keys) then
            self:_bindKeys(global_keys, self._modal)
        end
        self._modal:enter()

        for app_name, binds in pairs(app_keys) do
            local app_modal = hs.hotkey.modal.new()
            self:_bindKeys(binds, app_modal)
            self._app_modals[app_name] = app_modal
        end

        if next(self._app_modals) then
            self:_startAppWatcher()
        end
    end

    self._specs = {}
    local to_install = {}

    -- Parse all specs
    for _, spec in ipairs(specs) do
        local source = spec[1]
        if not source then
            log.w("spec missing source, skipping")
            goto next_spec
        end

        local parsed = parseSpec(source)
        if not parsed then
            goto next_spec
        end

        table.insert(self._specs, {
            parsed = parsed,
            config = spec.config,
            start = spec.start ~= false,
        })

        -- Check if spoon needs installation
        local dir = self._spoons_dir .. parsed.dir_name
        if not hs.fs.attributes(dir) then
            table.insert(to_install, self._specs[#self._specs])
        end

        ::next_spec::
    end

    -- If nothing to install, load immediately
    if #to_install == 0 then
        self:_loadAndConfigureAll()
        return
    end

    -- Install missing spoons in parallel
    self._pendingInstalls = #to_install
    self:_showProgress("installing " .. #to_install .. " spoon(s)...")

    for _, spec in ipairs(to_install) do
        local p = spec.parsed
        local dest = self._spoons_dir .. p.dir_name

        local function onComplete(success, err)
            if not success then
                log.w("install failed for", p.name .. ":", tostring(err))
            end

            self._pendingInstalls = self._pendingInstalls - 1

            if self._pendingInstalls > 0 then
                self:_updateProgress(p.name, self._pendingInstalls)
            else
                self:_closeProgress()
                self:_loadAndConfigureAll()
            end
        end

        if p.is_zip then
            downloadAndExtract(p.url, self._spoons_dir, p.dir_name, onComplete)
        else
            gitClone(p.url, dest, onComplete)
        end
    end
end

function obj:init()
    self._spoons_dir = hs.configdir .. "/Spoons/"
    self._modal = hs.hotkey.modal.new()
    self._app_modals = {}
    self._app_watcher = nil
end

return obj
