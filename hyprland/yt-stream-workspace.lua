-- yt-stream-workspace: the Hyprland half of the stream boundary.
--
-- Load it from hyprland.lua (Hyprland 0.55+):
--
--     require("yt-stream-workspace")
--
-- workspace-stream starts and stops sessions; this module does everything that
-- has to happen inside the compositor. While a session is active it keeps one
-- invariant from Hyprland's own event handlers, which run synchronously and
-- therefore before any frame of the stream output can be rendered or captured:
--
--     The stream output shows the stream workspace (or the curtain) and
--     nothing else. No other workspace is assigned to it and no special
--     workspace is shown on it.
--
-- It also hands input between the physical monitor and the stream output,
-- places the preview window, raises the curtain, and keeps layer surfaces and
-- private windows out of the capture. Session state lives in
-- $XDG_RUNTIME_DIR/yt-stream-workspace, so the guard re-arms itself whenever
-- Hyprland reloads its configuration.
--
-- Default bindings:
--     SUPER + F11   control the stream workspace (enter)
--     SUPER + F12   return to the physical monitor (leave)
--     SUPER + F10   raise or lower the curtain
-- Rebind with YTWS.bind({ enter = "...", leave = "...", curtain = "..." }) after
-- the require line; pass false for a key to leave it unbound.

local PROTOCOL = 1
local PREVIEW_NAME = "stream-preview"
local CURTAIN_NAME = "stream-curtain"
local PREVIEW_CLASS = "at.yrlf.wl_mirror"
local PREVIEW_TITLE = "yt-stream-workspace preview"
local PREVIEW_MATCH = { class = "^at\\.yrlf\\.wl_mirror$", title = "^yt-stream-workspace preview$" }
local OUTPUT_GAP = 256 -- logical px between the physical layout and the output
local CURSOR_SAMPLE_MS = 250

local M = {}
M.protocol = PROTOCOL

local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
local RUN = runtime_dir and (runtime_dir .. "/yt-stream-workspace") or nil
local SESSION_FILE = RUN and (RUN .. "/session.lua")
local STATE_FILE = RUN and (RUN .. "/compositor.lua")
local PHASE_FILE = RUN and (RUN .. "/phase")

-- A second load into the same Lua state (dofile) replaces the first cleanly.
if YTWS and YTWS._unload then
    pcall(YTWS._unload)
end

YTWS = M

local S = nil -- the active session, or nil
local rules = {}
local timers = {}
local subscriptions = {}
local busy = false -- true while the module itself is moving things around
local binds = {}

---------------------------------------------------------------------------
-- small utilities

local function now()
    return os.time()
end

local function serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(value)
    elseif t == "table" then
        local keys = {}
        for k in pairs(value) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        local inner = indent .. "    "
        local parts = {}
        for _, k in ipairs(keys) do
            local key = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
            parts[#parts + 1] = inner .. key .. " = " .. serialize(value[k], inner) .. ","
        end
        return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

local function json(value)
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        if math.type(value) == "integer" then
            return tostring(value)
        end
        return string.format("%.6g", value)
    elseif t == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
            return map[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "table" then
        if next(value) == nil then
            return value.__object and "{}" or "[]"
        end
        if #value > 0 then
            local parts = {}
            for i = 1, #value do
                parts[i] = json(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do
            if k ~= "__object" then
                keys[#keys + 1] = tostring(k)
            end
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = json(k) .. ":" .. json(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end
M.json = json

local function write_file(path, text)
    if not path then
        return false
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return false
    end
    f:write(text)
    f:close()
    return os.rename(tmp, path) ~= nil
end

local function read_table(path)
    if not path then
        return nil
    end
    local chunk = loadfile(path, "t", {})
    if not chunk then
        return nil
    end
    local ok, value = pcall(chunk)
    if ok and type(value) == "table" then
        return value
    end
    return nil
end

local function save()
    if not S then
        return
    end
    write_file(STATE_FILE, "return " .. serialize(S) .. "\n")
    write_file(PHASE_FILE, S.phase .. "\n")
end

local function record_error(message)
    if not S then
        return
    end
    S.errors = (S.errors or 0) + 1
    S.last_error = tostring(message)
    save()
end

local function protected(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            record_error(err)
        end
    end
end

local function dispatch(dsp)
    hl.dispatch(dsp)
end

local function after(ms, fn)
    -- Run fn once Hyprland has finished the action that is in progress.
    hl.timer(protected(fn), { timeout = ms, type = "oneshot" })
end

---------------------------------------------------------------------------
-- compositor queries

local function monitor(name)
    if not name or name == "" then
        return nil
    end
    return hl.get_monitor(name)
end

local function is_output(mon)
    return S ~= nil and mon ~= nil and mon.name == S.output
end

local function physical_monitors()
    local list = {}
    for _, m in ipairs(hl.get_monitors()) do
        if not is_output(m) then
            list[#list + 1] = m
        end
    end
    table.sort(list, function(a, b)
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.y < b.y
    end)
    return list
end

local function preview_monitor()
    if not S then
        return nil
    end
    local m = monitor(S.preview_monitor)
    if m and not is_output(m) then
        return m
    end
    return physical_monitors()[1]
end

local function selector(ws)
    if ws.special then
        return ws.name
    elseif ws.id > 0 then
        return tostring(ws.id)
    end
    return "name:" .. ws.name
end

local function stream_name()
    return tostring(S.workspace)
end

local function workspace_named(name)
    for _, ws in ipairs(hl.get_workspaces()) do
        if ws.name == name then
            return ws
        end
    end
    return nil
end

local function logical_box(mon)
    local w, h = mon.width, mon.height
    if mon.transform % 2 == 1 then
        w, h = h, w
    end
    return { x = mon.x, y = mon.y, w = w / mon.scale, h = h / mon.scale }
end

local function inside(box, p)
    return p.x >= box.x and p.y >= box.y and p.x < box.x + box.w and p.y < box.y + box.h
end

local function clamp_into(box, x, y)
    return math.max(box.x, math.min(box.x + box.w - 1, x)), math.max(box.y, math.min(box.y + box.h - 1, y))
end

-- wl-mirror shows the output scaled to fit the preview monitor, centred.
local function fit(view, source)
    local s = math.min(view.w / source.w, view.h / source.h)
    return s, view.x + (view.w - source.w * s) / 2, view.y + (view.h - source.h * s) / 2
end

local function preview_to_output(p, pm, out)
    local view, source = logical_box(pm), logical_box(out)
    local s, ox, oy = fit(view, source)
    return clamp_into(source, source.x + (p.x - ox) / s, source.y + (p.y - oy) / s)
end

local function output_to_preview(p, pm, out)
    local view, source = logical_box(pm), logical_box(out)
    local s, ox, oy = fit(view, source)
    return clamp_into(view, ox + (p.x - source.x) * s, oy + (p.y - source.y) * s)
end

local function warp(x, y)
    dispatch(hl.dsp.cursor.move({ x = math.floor(x + 0.5), y = math.floor(y + 0.5) }))
end

local function notify(text)
    -- Hyprland draws its notifications on the focused monitor; never let one
    -- land on the stream output.
    local focused = hl.get_active_monitor()
    if is_output(focused) then
        return
    end
    hl.notification.create({ text = "Stream: " .. text, timeout = 4000 })
end

---------------------------------------------------------------------------
-- rules

local function set_rules(enabled)
    for _, rule in pairs(rules) do
        pcall(function()
            rule:set_enabled(enabled)
        end)
    end
end

local function install_rules()
    hl.monitor({ output = S.output, mode = S.mode, position = S.position, scale = S.scale })
    rules.preview_workspace = hl.workspace_rule({
        workspace = "name:" .. PREVIEW_NAME,
        monitor = S.preview_monitor,
        persistent = true,
        gaps_in = 0,
        gaps_out = 0,
        border_size = 0,
        no_rounding = true,
        no_shadow = true,
        decorate = false,
    })
    rules.curtain_workspace = hl.workspace_rule({
        workspace = "name:" .. CURTAIN_NAME,
        monitor = S.output,
        persistent = true,
    })
    rules.preview = hl.window_rule({
        name = "yt-stream-workspace-preview",
        match = PREVIEW_MATCH,
        workspace = "name:" .. PREVIEW_NAME .. " silent",
        fullscreen = true,
        -- no_focus keeps input on the stream output. (no_initial_focus would
        -- also stop Hyprland applying the fullscreen rule at map time.)
        no_focus = true,
        no_anim = true,
        no_blur = true,
        no_shadow = true,
        no_dim = true,
        decorate = false,
        border_size = 0,
        rounding = 0,
        opaque = true,
    })
    rules.layers = hl.layer_rule({
        name = "yt-stream-workspace-layers",
        match = { namespace = "negative:" .. S.stream_layers },
        no_screen_share = true,
    })
    if S.private_windows and S.private_windows ~= "" then
        rules.private = hl.window_rule({
            name = "yt-stream-workspace-private",
            match = { class = S.private_windows },
            no_screen_share = true,
        })
    end
end

-- Persistent workspace rules only take effect on Hyprland's next refresh,
-- and that refresh skips rules whose monitor does not exist yet. Re-issue
-- them (a no-op merge) and run the refresh now.
local function materialize_workspaces()
    rules.preview_workspace = hl.workspace_rule({
        workspace = "name:" .. PREVIEW_NAME,
        monitor = S.preview_monitor,
        persistent = true,
    })
    rules.curtain_workspace = hl.workspace_rule({
        workspace = "name:" .. CURTAIN_NAME,
        monitor = S.output,
        persistent = true,
    })
    hl.exec_scheduled_prop_refresh_immediately()
end

---------------------------------------------------------------------------
-- the guard

local TRACE_LENGTH = 20

local function correction(reason, what)
    S.corrections = (S.corrections or 0) + 1
    S.last_correction = reason .. ": " .. what
    S.last_correction_at = now()
    S.trace = S.trace or {}
    S.trace[#S.trace + 1] = os.date("%H:%M:%S") .. " " .. S.last_correction
    while #S.trace > TRACE_LENGTH do
        table.remove(S.trace, 1)
    end
end

-- Keep focus and the pointer where they were while fn rearranges workspaces.
local function preserving_focus(fn)
    local window = hl.get_active_window()
    local mon = hl.get_active_monitor()
    local cursor = hl.get_cursor_pos()
    fn()
    local focused = hl.get_active_monitor()
    if mon and focused and focused.name ~= mon.name then
        if window and window.workspace and window.monitor and window.monitor.name == mon.name then
            dispatch(hl.dsp.focus({ window = "address:" .. window.address }))
        else
            dispatch(hl.dsp.focus({ monitor = mon.name }))
        end
        if cursor then
            warp(cursor.x, cursor.y)
        end
    end
end

local function allowed_on_output(ws)
    if ws.special then
        return false
    end
    if ws.name == CURTAIN_NAME then
        return true
    end
    return ws.name == stream_name() and not S.curtain
end

local function home_for(ws)
    local origin = monitor(S.origins and S.origins[ws.name])
    if origin and not is_output(origin) then
        return origin
    end
    return preview_monitor()
end

local tidy_scheduled = false
local tidy -- forward

-- Synchronous part: whatever the output is about to render must be the
-- wanted workspace with no special workspace over it. Neither step needs a
-- destination elsewhere, so both are safe while monitors are appearing or
-- disappearing. Foreign workspaces that end up assigned to the output are
-- inactive, so never rendered, and tidy() moves them out on the next tick.
local function enforce_once(reason)
    for _ = 1, 6 do
        local out = monitor(S.output)
        if not out then
            return
        end
        local changed = false

        local special = out.active_special_workspace
        if special then
            out:set_special_workspace({})
            correction(reason, "hid special workspace " .. special.name)
            S.reshow_special = special.name
            S.reshow_focus = is_output(hl.get_active_monitor())
            changed = true
        end

        local want = S.curtain and CURTAIN_NAME or stream_name()
        local target = workspace_named(want)
        if target and (not target.monitor or not is_output(target.monitor)) then
            dispatch(hl.dsp.workspace.move({ workspace = selector(target), monitor = S.output }))
            correction(reason, "returned workspace " .. want .. " to the stream output")
            changed = true
            out = monitor(S.output)
        end
        local active = out and out.active_workspace
        if target and out and (not active or active.name ~= want) then
            if active and not allowed_on_output(active) and is_output(hl.get_active_monitor()) then
                -- The streamer asked for this workspace; take them to it
                -- privately once it has been moved out.
                S.follow = selector(active)
            end
            preserving_focus(function()
                out:set_workspace({ workspace = want })
            end)
            correction(reason, "kept " .. want .. " on the stream output instead of " .. (active and active.name or "nothing"))
            changed = true
        end

        if not changed then
            break
        end
    end
    for _, ws in ipairs(hl.get_workspaces()) do
        if ws.monitor and is_output(ws.monitor) and not allowed_on_output(ws) then
            if not tidy_scheduled then
                tidy_scheduled = true
                after(1, tidy)
            end
            break
        end
    end
    if S.reshow_special and not tidy_scheduled then
        tidy_scheduled = true
        after(1, tidy)
    end
end

local reconcile_focus -- defined with the input handoff below

local function enforce(reason)
    if not S or S.phase ~= "active" or busy then
        return
    end
    busy = true
    local before = S.corrections or 0
    local ok, err = pcall(enforce_once, reason)
    busy = false
    if not ok then
        record_error(err)
    elseif (S.corrections or 0) ~= before then
        reconcile_focus()
        save()
    end
end
M.enforce = function()
    enforce("manual")
end

-- Deferred part: move foreign workspaces off the output to where they belong,
-- now that any monitor change in progress has finished.
tidy = function()
    tidy_scheduled = false
    if not S or S.phase ~= "active" then
        return
    end
    busy = true
    local ok, err = pcall(function()
        for _, ws in ipairs(hl.get_workspaces()) do
            if ws.monitor and is_output(ws.monitor) and not allowed_on_output(ws) then
                local dest = home_for(ws)
                if dest then
                    dispatch(hl.dsp.workspace.move({ workspace = selector(ws), monitor = dest.name }))
                    correction("tidy", "moved workspace " .. ws.name .. " to " .. dest.name)
                end
            end
        end
        if S.follow then
            local sel = S.follow
            S.follow = nil
            local ws = hl.get_workspace(sel)
            if ws and ws.monitor and not is_output(ws.monitor) then
                ws.monitor:set_workspace({ workspace = ws.name })
                dispatch(hl.dsp.focus({ monitor = ws.monitor.name }))
                local last = ws.last_window
                if last then
                    dispatch(hl.dsp.focus({ window = "address:" .. last.address }))
                end
            elseif not ws then
                -- It was empty and Hyprland dropped it; create it privately.
                local pm = preview_monitor()
                if pm then
                    dispatch(hl.dsp.focus({ monitor = pm.name }))
                    dispatch(hl.dsp.focus({ workspace = sel }))
                end
            end
        end
        if S.reshow_special then
            local name = S.reshow_special
            local take_focus = S.reshow_focus
            S.reshow_special, S.reshow_focus = nil, nil
            local pm = preview_monitor()
            local ws = workspace_named(name)
            if pm and ws then
                -- Show it where the streamer can still use it, privately.
                pm:set_special_workspace({ workspace = name })
                local last = ws.last_window
                if take_focus and last then
                    dispatch(hl.dsp.focus({ window = "address:" .. last.address }))
                elseif take_focus then
                    dispatch(hl.dsp.focus({ monitor = pm.name }))
                end
            end
        end
    end)
    busy = false
    if not ok then
        record_error(err)
    end
    enforce("tidy")
    reconcile_focus()
    save()
end

---------------------------------------------------------------------------
-- input handoff
--
-- Input is "in the stream" exactly when the stream output has focus; the
-- physical monitor then shows the preview. Every way of moving focus works:
-- Super+F11/F12, the stream workspace's own key, any other workspace key.
-- Hyprland announces a focus change before it records it, and may move the
-- pointer afterwards, so anything that depends on the final focus runs from
-- settle() on the next tick.

local function stop_timer(name)
    if timers[name] then
        pcall(function()
            timers[name]:set_enabled(false)
        end)
        timers[name] = nil
    end
end

local function sample_cursor()
    if not S or not S.entered then
        return
    end
    local out = monitor(S.output)
    local p = hl.get_cursor_pos()
    if out and p and inside(logical_box(out), p) then
        S.cursor_stream = { x = p.x, y = p.y }
    end
end

local function set_entered(on)
    if on == S.entered then
        return
    end
    if not on then
        sample_cursor()
    end
    S.entered = on
    stop_timer("cursor")
    if on then
        timers.cursor = hl.timer(protected(sample_cursor), { timeout = CURSOR_SAMPLE_MS, type = "repeat" })
    end
end

local function focus_stream_window()
    local active = hl.get_active_window()
    if active and active.monitor and is_output(active.monitor) then
        return
    end
    local ws = workspace_named(S.curtain and CURTAIN_NAME or stream_name())
    local last = ws and ws.last_window
    if last then
        dispatch(hl.dsp.focus({ window = "address:" .. last.address }))
    end
end

local function show_preview()
    local pm = preview_monitor()
    if not pm or pm.active_special_workspace then
        return
    end
    local active = pm.active_workspace
    if active and active.name == PREVIEW_NAME then
        return
    end
    if active then
        S.return_workspace = selector(active)
    end
    if workspace_named(PREVIEW_NAME) then
        pm:set_workspace({ workspace = PREVIEW_NAME })
    end
end

local function hide_preview()
    local pm = preview_monitor()
    if not pm or not pm.active_workspace or pm.active_workspace.name ~= PREVIEW_NAME then
        return
    end
    local back = S.return_workspace and hl.get_workspace(S.return_workspace)
    if back and back.monitor and back.monitor.name == pm.name then
        pm:set_workspace({ workspace = back.name })
        return
    end
    for _, ws in ipairs(hl.get_workspaces()) do
        if not ws.special and ws.monitor and ws.monitor.name == pm.name and ws.name ~= PREVIEW_NAME then
            pm:set_workspace({ workspace = ws.name })
            return
        end
    end
    dispatch(hl.dsp.focus({ workspace = "emptym" }))
end

local function pointer_target_on_output()
    local out, pm = monitor(S.output), preview_monitor()
    local p = hl.get_cursor_pos()
    if not out or not pm or not p or not inside(logical_box(pm), p) then
        return nil
    end
    S.cursor_back = { x = p.x, y = p.y }
    if pm.active_workspace and pm.active_workspace.name == PREVIEW_NAME then
        -- Pointer is over the preview: carry it to the same spot on the output.
        local x, y = preview_to_output(p, pm, out)
        return { x = x, y = y }
    end
    return nil
end

local settle_reason = nil

local function settle()
    local reason = settle_reason
    settle_reason = nil
    if not S or S.phase ~= "active" then
        return
    end
    local focused = hl.get_active_monitor()
    local out = monitor(S.output)
    local pm = preview_monitor()
    if not focused or not out then
        return
    end
    busy = true
    local ok, err = pcall(function()
        if S.curtain then
            if is_output(focused) and pm then
                -- Nothing typed while the curtain is up may reach the output.
                dispatch(hl.dsp.focus({ monitor = pm.name }))
                notify("the curtain is up; press Super+F10 to lower it")
            end
            set_entered(false)
            return
        end
        if is_output(focused) then
            show_preview()
            -- An explicit target (the pointer carried in from the preview)
            -- always wins; otherwise return to where the pointer last was.
            local p = S.enter_target or (not S.entered and S.cursor_stream) or nil
            set_entered(true)
            if p then
                warp(clamp_into(logical_box(out), p.x, p.y))
            end
            S.enter_target = nil
            focus_stream_window()
            return
        end
        set_entered(false)
        if pm and focused.name == pm.name then
            local active = pm.active_workspace
            if active and active.name == PREVIEW_NAME and not pm.active_special_workspace then
                if reason == "focus" then
                    -- Focus was moved here on purpose: show the workspace the
                    -- streamer came from rather than a preview they cannot type in.
                    hide_preview()
                else
                    -- They looked at the preview: put them in the stream.
                    S.enter_target = pointer_target_on_output()
                    dispatch(hl.dsp.focus({ monitor = S.output }))
                    settle_reason = "enter"
                    after(1, settle)
                end
            end
        end
    end)
    busy = false
    if not ok then
        record_error(err)
    end
    save()
end

local function schedule_settle(reason)
    if not S or S.phase ~= "active" then
        return
    end
    if settle_reason == nil then
        after(1, settle)
    end
    if settle_reason ~= "focus" then
        settle_reason = reason
    end
end

reconcile_focus = function()
    schedule_settle("guard")
end

local function on_focus(mon)
    if not S or S.phase ~= "active" or busy or not mon then
        return
    end
    if is_output(mon) and not S.curtain then
        -- Same frame as the focus change: the physical monitor shows what
        -- the streamer is now typing into. The preview never takes focus.
        busy = true
        local ok, err = pcall(show_preview)
        busy = false
        if not ok then
            record_error(err)
        end
    end
    schedule_settle("focus")
end

function M.enter()
    if not S or S.phase ~= "active" then
        notify("no stream session is prepared")
        return
    end
    if S.curtain then
        notify("the curtain is up; press Super+F10 to lower it")
        return
    end
    S.enter_target = pointer_target_on_output() or S.cursor_stream
    if is_output(hl.get_active_monitor()) then
        schedule_settle("enter")
        return
    end
    dispatch(hl.dsp.focus({ monitor = S.output }))
    schedule_settle("enter")
end

function M.leave()
    if not S or S.phase ~= "active" then
        return
    end
    local out = monitor(S.output)
    local pm = preview_monitor()
    if not pm then
        return
    end
    sample_cursor()
    local p = hl.get_cursor_pos()
    local target = S.cursor_back
    if out and p and inside(logical_box(out), p) then
        local x, y = output_to_preview(p, pm, out)
        target = { x = x, y = y }
    end
    busy = true
    local ok, err = pcall(function()
        dispatch(hl.dsp.focus({ monitor = pm.name }))
        hide_preview()
        if target then
            warp(target.x, target.y)
        end
    end)
    busy = false
    if not ok then
        record_error(err)
    end
    set_entered(false)
    schedule_settle("leave")
    save()
end

function M.toggle()
    if S and is_output(hl.get_active_monitor()) then
        M.leave()
    else
        M.enter()
    end
end

-- Compatibility for wrappers that route every workspace switch through
-- `workspace-stream workspace SELECTOR`. Ordinary dispatches are already safe;
-- this only adds the old conveniences.
function M.workspace(sel)
    sel = tostring(sel)
    if S and S.phase == "active" then
        if sel == stream_name() then
            M.enter()
            return
        end
        if is_output(hl.get_active_monitor()) and (sel:match("^m") or sel:match("^e[%+%-~]") or sel:match("^empty")) then
            -- Relative selectors mean the physical monitor's workspaces.
            M.leave()
        end
    end
    dispatch(hl.dsp.focus({ workspace = sel }))
end

---------------------------------------------------------------------------
-- the curtain

-- Silence the stream mix. Through PipeWire's Pulse layer neither muting the
-- monitor source nor muting the recorder's own stream silences a capture of
-- the monitor; zero volume on the sink and on its monitor does.
local function curtain_audio(on)
    if S.mix_sink and S.mix_sink ~= "" then
        local level = on and "0" or "100%"
        hl.exec_cmd(string.format("pactl set-sink-volume %s %s; pactl set-source-volume %s.monitor %s",
            S.mix_sink, level, S.mix_sink, level))
    end
end

function M.curtain(want)
    if not S or S.phase ~= "active" then
        notify("no stream session is prepared")
        return json({ ok = false, error = "no active session" })
    end
    if want == nil then
        want = not S.curtain
    end
    if want == S.curtain then
        return json({ ok = true, curtain = S.curtain })
    end
    local was_entered = S.entered
    S.curtain = want
    busy = true
    local ok, err = pcall(function()
        local out = monitor(S.output)
        local pm = preview_monitor()
        if want then
            curtain_audio(true)
            materialize_workspaces()
            if out and workspace_named(CURTAIN_NAME) then
                preserving_focus(function()
                    out:set_workspace({ workspace = CURTAIN_NAME })
                end)
            end
            local stream = workspace_named(stream_name())
            if stream and pm then
                dispatch(hl.dsp.workspace.move({ workspace = stream_name(), monitor = pm.name }))
                if was_entered then
                    -- Keep working on it, privately, while the stream shows the curtain.
                    pm:set_workspace({ workspace = stream_name() })
                    dispatch(hl.dsp.focus({ monitor = pm.name }))
                    local last = workspace_named(stream_name())
                    last = last and last.last_window
                    if last then
                        dispatch(hl.dsp.focus({ window = "address:" .. last.address }))
                    end
                end
            end
            set_entered(false)
        else
            local stream = workspace_named(stream_name())
            if stream then
                -- If the streamer is looking at it, it moves with focus.
                dispatch(hl.dsp.workspace.move({ workspace = stream_name(), monitor = S.output }))
            else
                -- It closed while hidden; recreate it on the output.
                dispatch(hl.dsp.focus({ monitor = S.output }))
                dispatch(hl.dsp.focus({ workspace = stream_name() }))
            end
            curtain_audio(false)
        end
    end)
    busy = false
    if not ok then
        record_error(err)
    end
    enforce(want and "curtain" or "uncurtain")
    reconcile_focus()
    save()
    notify(want and "curtain up: viewers see the curtain and hear nothing" or "curtain down: viewers see the stream workspace")
    return json({ ok = true, curtain = S.curtain })
end

---------------------------------------------------------------------------
-- session lifecycle

local function validate_intent(intent)
    if type(intent) ~= "table" then
        return "missing session file"
    end
    if intent.protocol ~= PROTOCOL then
        return "session file protocol " .. tostring(intent.protocol) .. " does not match module protocol " .. PROTOCOL
    end
    if type(intent.output) ~= "string" or not intent.output:match("^[%w._-]+$") then
        return "invalid output name"
    end
    if math.type(intent.workspace) ~= "integer" or intent.workspace < 1 then
        return "the stream workspace must be a positive numeric workspace"
    end
    if type(intent.mode) ~= "string" or not intent.mode:match("^%d+x%d+@%d+$") then
        return "invalid mode"
    end
    if type(intent.scale) ~= "number" or intent.scale <= 0 then
        return "invalid scale"
    end
    if type(intent.stream_layers) ~= "string" or intent.stream_layers == "" then
        return "invalid stream layer pattern"
    end
    return nil
end

local function output_position()
    -- Below the physical layout and not touching it, so the pointer can never
    -- wander onto the stream output by accident and input moves only on
    -- purpose.
    local min_x, max_y = nil, 0
    for _, m in ipairs(physical_monitors()) do
        local box = logical_box(m)
        min_x = min_x and math.min(min_x, box.x) or box.x
        max_y = math.max(max_y, box.y + box.h)
    end
    return string.format("%dx%d", math.floor(min_x or 0), math.floor(max_y + OUTPUT_GAP))
end

function M.begin()
    if S and (S.phase == "active" or S.phase == "pending") then
        return json({ ok = false, error = "a stream session is already active in Hyprland" })
    end
    local intent = read_table(SESSION_FILE)
    local problem = validate_intent(intent)
    if problem then
        return json({ ok = false, error = problem })
    end
    if hl.get_monitor(intent.output) then
        return json({ ok = false, error = "Hyprland output " .. intent.output .. " already exists" })
    end

    local focused = hl.get_active_monitor()
    local stream = workspace_named(tostring(intent.workspace))
    local origin = stream and stream.monitor or focused
    if not origin then
        return json({ ok = false, error = "no physical monitor is available" })
    end

    S = {
        protocol = PROTOCOL,
        signature = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "",
        phase = "pending",
        started = now(),
        output = intent.output,
        workspace = intent.workspace,
        mode = intent.mode,
        scale = intent.scale,
        stream_layers = intent.stream_layers,
        private_windows = intent.private_windows or "",
        mix_sink = intent.mix_sink or "",
        origin_monitor = origin.name,
        origins = {},
        entered = false,
        curtain = false,
        corrections = 0,
        errors = 0,
    }
    local pm = monitor(intent.preview_monitor)
    S.preview_monitor = (pm and pm.name ~= intent.output) and pm.name or origin.name
    for _, ws in ipairs(hl.get_workspaces()) do
        if ws.monitor and not ws.special then
            S.origins[ws.name] = ws.monitor.name
        end
    end
    S.stream_was_focused = (stream ~= nil and focused ~= nil and focused.active_workspace ~= nil
        and focused.active_workspace.name == stream.name) or (stream == nil)
    S.position = output_position()

    install_rules()
    save()
    return json({
        ok = true,
        output = S.output,
        position = S.position,
        preview_monitor = S.preview_monitor,
        origin_monitor = S.origin_monitor,
    })
end

local function activate()
    if not S or S.phase ~= "pending" then
        return
    end
    local out = monitor(S.output)
    if not out then
        return
    end
    S.phase = "active"
    busy = true
    local ok, err = pcall(function()
        materialize_workspaces()
        local stream = workspace_named(stream_name())
        if not stream then
            -- A workspace that does not exist yet is created on the output.
            dispatch(hl.dsp.focus({ monitor = S.output }))
            dispatch(hl.dsp.focus({ workspace = stream_name() }))
        elseif not stream.monitor or not is_output(stream.monitor) then
            dispatch(hl.dsp.workspace.move({ workspace = stream_name(), monitor = S.output }))
        end
    end)
    busy = false
    if not ok then
        record_error(err)
    end
    enforce("activate")
    if S.stream_was_focused and not is_output(hl.get_active_monitor()) then
        M.enter()
    else
        schedule_settle("activate")
    end
    save()
end

function M.activate()
    activate()
    return json({ ok = S ~= nil and S.phase == "active", phase = S and S.phase or "none" })
end

function M.finish()
    if not S then
        return json({ ok = true, noop = true })
    end
    local was_entered = S.entered
    local curtained = S.curtain
    S.phase = "finishing"
    save()
    for name in pairs(timers) do
        stop_timer(name)
    end
    set_rules(false)
    local home = nil
    busy = true
    local ok, err = pcall(function()
        local pm = preview_monitor()
        local origin = monitor(S.origin_monitor)
        home = (origin and not is_output(origin)) and origin or pm
        local focused = hl.get_active_monitor()
        local looking = was_entered or is_output(focused)
            or (pm and pm.active_workspace and pm.active_workspace.name == PREVIEW_NAME)
        local stream = workspace_named(stream_name())
        if stream and home then
            if stream.monitor and is_output(stream.monitor) then
                dispatch(hl.dsp.workspace.move({ workspace = stream_name(), monitor = home.name }))
            end
            if looking then
                -- Carry on in the same workspace, now an ordinary one.
                home:set_workspace({ workspace = stream_name() })
                dispatch(hl.dsp.focus({ monitor = home.name }))
                local last = workspace_named(stream_name())
                last = last and last.last_window
                if last then
                    dispatch(hl.dsp.focus({ window = "address:" .. last.address }))
                end
            end
        end
        if pm and pm.active_workspace and pm.active_workspace.name == PREVIEW_NAME then
            S.entered = false
            hide_preview()
        end
        if curtained then
            curtain_audio(false)
        end
    end)
    busy = false
    local result = { ok = ok, home = home and home.name or nil, error = (not ok) and tostring(err) or nil }
    S = nil
    if STATE_FILE then
        os.remove(STATE_FILE)
    end
    write_file(PHASE_FILE, "finished\n")
    return json(result)
end

local function lost()
    if not S then
        return
    end
    S.phase = "lost"
    set_entered(false)
    set_rules(false)
    save()
    notify("the stream output disappeared; run workspace-stream stop")
end

function M.phase()
    return S and S.phase or "none"
end

function M.status()
    if not S then
        return json({ protocol = PROTOCOL, phase = "none" })
    end
    local out = monitor(S.output)
    local result = {
        protocol = PROTOCOL,
        phase = S.phase,
        output = S.output,
        workspace = S.workspace,
        preview_monitor = S.preview_monitor,
        origin_monitor = S.origin_monitor,
        entered = S.entered,
        curtain = S.curtain,
        corrections = S.corrections or 0,
        last_correction = S.last_correction,
        trace = S.trace or {},
        errors = S.errors or 0,
        last_error = S.last_error,
        output_present = out ~= nil,
    }
    if out then
        local box = logical_box(out)
        result.mode = { width = out.width, height = out.height, refresh = out.refresh_rate, scale = out.scale }
        result.position = { x = box.x, y = box.y }
        result.showing = out.active_workspace and out.active_workspace.name or nil
        result.special = out.active_special_workspace and out.active_special_workspace.name or nil
        local on_output = {}
        for _, ws in ipairs(hl.get_workspaces()) do
            if ws.monitor and is_output(ws.monitor) then
                on_output[#on_output + 1] = ws.name
            end
        end
        result.workspaces_on_output = on_output
        local layers = {}
        for _, l in ipairs(hl.get_layers({ monitor = S.output })) do
            layers[#layers + 1] = l.namespace
        end
        result.layers = layers
        local windows = {}
        local stream = workspace_named(stream_name())
        if stream then
            for _, w in ipairs(stream:get_windows()) do
                windows[#windows + 1] = { class = w.class, pid = w.pid, address = w.address }
            end
        end
        result.windows = windows
    end
    local preview = {}
    for _, w in ipairs(hl.get_windows()) do
        if w.class == PREVIEW_CLASS and w.title == PREVIEW_TITLE then
            preview[#preview + 1] = { address = w.address, pid = w.pid, workspace = w.workspace and w.workspace.name }
        end
    end
    result.preview = preview
    return json(result)
end

---------------------------------------------------------------------------
-- bindings and event wiring

function M.bind(keys)
    keys = keys or {}
    for _, key in pairs(binds) do
        pcall(hl.unbind, key)
    end
    binds = {}
    local defaults = { enter = "SUPER + F11", leave = "SUPER + F12", curtain = "SUPER + F10" }
    local actions = {
        enter = function()
            M.enter()
        end,
        leave = function()
            M.leave()
        end,
        curtain = function()
            M.curtain()
        end,
    }
    for name, fn in pairs(actions) do
        local key = keys[name]
        if key == nil then
            key = defaults[name]
        end
        if key then
            hl.bind(key, protected(fn), { description = "yt-stream-workspace: " .. name })
            binds[name] = key
        end
    end
end

local function wire_events()
    local function on(event, fn)
        subscriptions[#subscriptions + 1] = hl.on(event, protected(fn))
    end
    on("workspace.active", function(ws)
        enforce("workspace.active")
        if S and ws and ws.name == PREVIEW_NAME then
            schedule_settle("workspace")
        end
    end)
    on("workspace.created", function()
        enforce("workspace.created")
    end)
    on("workspace.move_to_monitor", function()
        enforce("workspace.move_to_monitor")
    end)
    on("workspace.special_active", function(ws)
        enforce("workspace.special_active")
        -- A closed special workspace arrives as an expired object.
        if S and (ws == nil or ws.name == nil) then
            schedule_settle("special")
        end
    end)
    on("monitor.added", function(mon)
        if S and S.phase == "pending" and mon and mon.name == S.output then
            activate()
        else
            enforce("monitor.added")
        end
    end)
    on("monitor.removed", function(mon)
        if S and mon and mon.name == S.output and S.phase == "active" then
            lost()
        else
            enforce("monitor.removed")
        end
    end)
    on("monitor.focused", function(mon)
        on_focus(mon)
    end)
    on("window.open", function(w)
        -- While the curtain is up nothing may appear on the output.
        if S and S.phase == "active" and S.curtain and w and w.monitor and is_output(w.monitor) then
            busy = true
            dispatch(hl.dsp.window.move({ workspace = stream_name(), window = "address:" .. w.address, follow = false }))
            busy = false
            correction("window.open", "moved a new window off the curtain")
            save()
        end
    end)
end

local function rearm()
    local saved = read_table(STATE_FILE)
    if not saved or saved.protocol ~= PROTOCOL then
        return
    end
    if saved.signature ~= (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "") then
        return
    end
    if saved.phase ~= "active" and saved.phase ~= "pending" then
        return
    end
    S = saved
    install_rules()
    if S.phase == "active" then
        if S.entered then
            S.entered = false
            set_entered(true)
        end
        -- Hyprland is still loading its configuration; settle once it is done.
        after(1, function()
            if not S then
                return
            end
            if monitor(S.output) then
                enforce("reload")
            else
                lost()
            end
        end)
    end
end

function M._unload()
    for _, sub in ipairs(subscriptions) do
        pcall(function()
            sub:remove()
        end)
    end
    subscriptions = {}
    for name in pairs(timers) do
        stop_timer(name)
    end
    for _, key in pairs(binds) do
        pcall(hl.unbind, key)
    end
    binds = {}
    set_rules(false)
end

wire_events()
M.bind()
rearm()

return M
