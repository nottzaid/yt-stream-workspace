-- A small model of Hyprland's Lua API, faithful to the parts of 0.56 that the
-- stream module depends on: workspace placement (moveWorkspaceToMonitor's gap
-- filling and active-workspace hand-over), workspace creation on the focused
-- monitor, special workspaces, focus, synchronous events with Hyprland's
-- re-entrancy rule, rules, and timers. Tests drive it with ordinary
-- dispatches and inspect what each monitor would render at frame boundaries.

local F = {}

local state

function F.reset()
    state = {
        monitors = {},
        workspaces = {},
        windows = {},
        focus_monitor = nil,
        focus_window = nil,
        cursor = { x = 0, y = 0 },
        handlers = {},
        active_handles = {},
        next_handle = 1,
        timers = {},
        binds = {},
        rules = { window = {}, layer = {}, workspace = {}, monitor = {} },
        notifications = {},
        execs = {},
        events = {},
        next_address = 0x1000,
        refresh_scheduled = false,
        frames = {},
    }
    return state
end

F.reset()

local wrap_monitor, wrap_workspace, wrap_window

-- Hyprland pushes an expired object, not nil, when an event has no workspace
-- (for example a special workspace being closed); every field reads as nil.
local EXPIRED = setmetatable({}, { __index = function() return nil end })

local function emit(name, ...)
    state.events[#state.events + 1] = name
    local list = state.handlers[name]
    if not list then
        return
    end
    for _, h in ipairs({ table.unpack(list) }) do
        if h.active and not state.active_handles[h.id] then
            state.active_handles[h.id] = true
            local ok, err = pcall(h.fn, ...)
            state.active_handles[h.id] = nil
            if not ok then
                error("handler for " .. name .. " failed: " .. tostring(err))
            end
        end
    end
end

---------------------------------------------------------------------------
-- records

local function find_monitor(name)
    for _, m in ipairs(state.monitors) do
        if m.name == name then
            return m
        end
    end
end

local function find_workspace_by(fn)
    for _, ws in ipairs(state.workspaces) do
        if fn(ws) then
            return ws
        end
    end
end

local function resolve_workspace(sel)
    sel = tostring(sel)
    if sel:match("^special:") then
        return find_workspace_by(function(w)
            return w.name == sel
        end)
    end
    if sel:match("^name:") then
        local n = sel:sub(6)
        return find_workspace_by(function(w)
            return w.name == n and not w.special
        end)
    end
    local id = tonumber(sel)
    if id then
        return find_workspace_by(function(w)
            return w.id == id
        end)
    end
    return find_workspace_by(function(w)
        return w.name == sel
    end)
end

local next_named_id = -1337

local function create_workspace(sel, mon)
    sel = tostring(sel)
    local ws = { windows = {}, monitor = mon }
    if sel:match("^special:") then
        ws.special = true
        ws.name = sel
        ws.id = next_named_id
        next_named_id = next_named_id - 1
    elseif sel:match("^name:") then
        ws.name = sel:sub(6)
        ws.id = next_named_id
        next_named_id = next_named_id - 1
    else
        ws.id = assert(tonumber(sel), "bad workspace selector " .. sel)
        ws.name = tostring(ws.id)
    end
    ws.persistent = false
    state.workspaces[#state.workspaces + 1] = ws
    emit("workspace.created", wrap_workspace(ws))
    return ws
end

local function first_free_id()
    local id = 1
    while find_workspace_by(function(w)
        return w.id == id
    end) do
        id = id + 1
    end
    return id
end

local function center(m)
    return m.x + m.width / m.scale / 2, m.y + m.height / m.scale / 2
end

-- Like CFocusState::rawMonitorFocus: the event fires before the new monitor
-- is recorded, so a handler still sees the old one, and a nested focus change
-- back to the old monitor is a no-op that the outer call then overrides.
local function raw_monitor_focus(m)
    if state.focus_monitor == m then
        return
    end
    emit("monitor.focused", wrap_monitor(m))
    state.focus_monitor = m
end

local function windows_on(ws)
    local list = {}
    for _, w in ipairs(state.windows) do
        if w.workspace == ws then
            list[#list + 1] = w
        end
    end
    return list
end

local function focus_window(w)
    if w and w.no_focus then
        return
    end
    state.focus_window = w
    if w then
        w.workspace.last_window = w
        raw_monitor_focus(w.workspace.monitor)
    end
end

local function referenced(ws)
    if ws.persistent or #windows_on(ws) > 0 then
        return true
    end
    for _, m in ipairs(state.monitors) do
        if m.active == ws or m.special == ws then
            return true
        end
    end
    return false
end

-- Workspaces are reference counted: an empty one that is no longer shown
-- anywhere is destroyed on the spot.
local function collect(ws)
    if not ws or referenced(ws) then
        return
    end
    for i, other in ipairs(state.workspaces) do
        if other == ws then
            table.remove(state.workspaces, i)
            ws.dead = true
            emit("workspace.removed", wrap_workspace(ws))
            return
        end
    end
end

local function change_workspace(m, ws, internal, no_focus)
    if ws.special then
        m.special = ws
        ws.monitor = m
        emit("workspace.special_active", wrap_workspace(ws), wrap_monitor(m))
        return
    end
    if m.active == ws then
        return
    end
    local old = m.active
    m.active = ws
    if not internal then
        if not no_focus then
            local cand = ws.last_window or windows_on(ws)[1]
            if cand and not cand.no_focus then
                focus_window(cand)
            elseif state.focus_window and state.focus_window.workspace.monitor == m then
                state.focus_window = nil
            end
        end
        emit("workspace.active", wrap_workspace(ws))
    end
    collect(old)
end

local function move_workspace_to_monitor(ws, m, no_warp)
    if ws.monitor == m then
        return
    end
    local old = ws.monitor
    if ws.special and old and old.special == ws then
        old.special = nil
        m.special = ws
        ws.monitor = m
        emit("workspace.special_active", wrap_workspace(ws), wrap_monitor(m))
        return
    end
    local switching = old and old.active == ws
    if switching then
        local nxt = find_workspace_by(function(w)
            return w.monitor == old and w ~= ws and not w.special
        end)
        if not nxt then
            nxt = create_workspace(first_free_id(), old)
        end
        change_workspace(old, nxt, false, true)
    end
    ws.monitor = m
    if switching and old == state.focus_monitor then
        m.active = ws
        raw_monitor_focus(m)
        if not no_warp then
            state.cursor.x, state.cursor.y = center(m)
        end
    end
    emit("workspace.move_to_monitor", wrap_workspace(ws), wrap_monitor(m))
    collect(ws)
end

---------------------------------------------------------------------------
-- object wrappers

local monitor_cache, workspace_cache, window_cache = {}, {}, {}

wrap_monitor = function(m)
    if not m then
        return nil
    end
    if monitor_cache[m] then
        return monitor_cache[m]
    end
    local obj = setmetatable({}, {
        __index = function(_, k)
            if k == "name" then
                return m.name
            elseif k == "x" then
                return m.x
            elseif k == "y" then
                return m.y
            elseif k == "width" then
                return m.width
            elseif k == "height" then
                return m.height
            elseif k == "scale" then
                return m.scale
            elseif k == "transform" then
                return 0
            elseif k == "refresh_rate" then
                return m.refresh or 60
            elseif k == "focused" then
                return state.focus_monitor == m
            elseif k == "active_workspace" then
                return wrap_workspace(m.active)
            elseif k == "active_special_workspace" then
                return wrap_workspace(m.special)
            elseif k == "set_workspace" then
                return function(_, spec)
                    local ws = find_workspace_by(function(w)
                        return w.name == tostring(spec.workspace)
                    end)
                    if ws then
                        change_workspace(m, ws, false, false)
                    end
                end
            elseif k == "set_special_workspace" then
                return function(_, spec)
                    if spec.workspace == nil then
                        if m.special then
                            local old = m.special
                            m.special = nil
                            emit("workspace.special_active", EXPIRED, wrap_monitor(m))
                            collect(old)
                        end
                        return
                    end
                    local ws = find_workspace_by(function(w)
                        return w.name == tostring(spec.workspace)
                    end)
                    if ws then
                        if ws.monitor and ws.monitor ~= m and ws.monitor.special == ws then
                            ws.monitor.special = nil
                        end
                        change_workspace(m, ws, false, false)
                    end
                end
            end
        end,
    })
    monitor_cache[m] = obj
    return obj
end

wrap_workspace = function(ws)
    if not ws then
        return nil
    end
    if workspace_cache[ws] then
        return workspace_cache[ws]
    end
    local obj = setmetatable({}, {
        __index = function(_, k)
            if k == "id" then
                return ws.id
            elseif k == "name" then
                return ws.name
            elseif k == "special" then
                return ws.special == true
            elseif k == "monitor" then
                return wrap_monitor(ws.monitor)
            elseif k == "windows" then
                return #windows_on(ws)
            elseif k == "last_window" then
                return wrap_window(ws.last_window)
            elseif k == "get_windows" then
                return function()
                    local list = {}
                    for _, w in ipairs(windows_on(ws)) do
                        list[#list + 1] = wrap_window(w)
                    end
                    return list
                end
            end
        end,
    })
    workspace_cache[ws] = obj
    return obj
end

wrap_window = function(w)
    if not w then
        return nil
    end
    if window_cache[w] then
        return window_cache[w]
    end
    local obj = setmetatable({}, {
        __index = function(_, k)
            if k == "address" then
                return w.address
            elseif k == "pid" then
                return w.pid
            elseif k == "class" then
                return w.class
            elseif k == "title" then
                return w.title
            elseif k == "workspace" then
                return wrap_workspace(w.workspace)
            elseif k == "monitor" then
                return wrap_monitor(w.workspace and w.workspace.monitor)
            end
        end,
    })
    window_cache[w] = obj
    return obj
end

---------------------------------------------------------------------------
-- dispatchers

local function dsp(fn)
    return { run = fn }
end

local function find_window(selector)
    local addr = selector:match("^address:(.+)$")
    for _, w in ipairs(state.windows) do
        if addr and w.address == addr then
            return w
        end
    end
end

local function focus_workspace(sel, on_current)
    local m = state.focus_monitor
    if sel == "emptym" then
        local ws = find_workspace_by(function(w)
            return w.monitor == m and not w.special and #windows_on(w) == 0 and m.active ~= w
        end)
        if not ws then
            ws = create_workspace(first_free_id(), m)
        end
        change_workspace(m, ws, false, false)
        return
    end
    local ws = resolve_workspace(sel)
    if not ws then
        ws = create_workspace(sel, m)
    end
    if ws.special then
        change_workspace(m, ws, false, false)
        return
    end
    if on_current and ws.monitor ~= m then
        move_workspace_to_monitor(ws, m)
    end
    if ws.monitor ~= m then
        raw_monitor_focus(ws.monitor)
        state.cursor.x, state.cursor.y = center(ws.monitor)
        m = ws.monitor
    end
    change_workspace(m, ws, false, false)
end

local api = {}

api.dsp = {
    focus = function(spec)
        return dsp(function()
            if spec.monitor then
                local m = assert(find_monitor(spec.monitor), "no monitor " .. spec.monitor)
                if state.focus_monitor == m then
                    return
                end
                local shown = m.special or m.active
                local cand = shown and (shown.last_window or windows_on(shown)[1])
                if cand and not cand.no_focus then
                    focus_window(cand)
                else
                    state.focus_window = nil
                end
                state.cursor.x, state.cursor.y = center(m)
                raw_monitor_focus(m)
            elseif spec.workspace then
                focus_workspace(tostring(spec.workspace), spec.on_current_monitor)
            elseif spec.window then
                local w = find_window(spec.window)
                if w then
                    local m = w.workspace.monitor
                    if m.active ~= w.workspace and not w.workspace.special then
                        change_workspace(m, w.workspace, false, true)
                    end
                    focus_window(w)
                end
            end
        end)
    end,
    cursor = {
        move = function(spec)
            return dsp(function()
                state.cursor.x, state.cursor.y = spec.x, spec.y
            end)
        end,
    },
    workspace = {
        move = function(spec)
            return dsp(function()
                local ws = resolve_workspace(spec.workspace)
                local m = find_monitor(spec.monitor)
                if ws and m then
                    move_workspace_to_monitor(ws, m)
                end
            end)
        end,
        toggle_special = function(name)
            return dsp(function()
                local m = state.focus_monitor
                local sel = "special:" .. name
                local ws = resolve_workspace(sel) or create_workspace(sel, m)
                if m.special == ws then
                    m.special = nil
                    emit("workspace.special_active", EXPIRED, wrap_monitor(m))
                else
                    if ws.monitor and ws.monitor ~= m and ws.monitor.special == ws then
                        ws.monitor.special = nil
                    end
                    change_workspace(m, ws, false, false)
                end
            end)
        end,
        swap_monitors = function(spec)
            return dsp(function()
                local a, b = find_monitor(spec.monitor1), find_monitor(spec.monitor2)
                local wa, wb = a.active, b.active
                wa.monitor, wb.monitor = b, a
                a.active, b.active = wb, wa
                emit("workspace.move_to_monitor", wrap_workspace(wa), wrap_monitor(b))
                emit("workspace.move_to_monitor", wrap_workspace(wb), wrap_monitor(a))
            end)
        end,
    },
    window = {
        move = function(spec)
            return dsp(function()
                local w = spec.window and find_window(spec.window) or state.focus_window
                if not w then
                    return
                end
                local ws = resolve_workspace(spec.workspace)
                    or create_workspace(spec.workspace, state.focus_monitor)
                w.workspace = ws
                emit("window.move_to_workspace", wrap_window(w), wrap_workspace(ws))
            end)
        end,
    },
}

function api.dispatch(d)
    d.run()
end

function api.get_monitor(name)
    return wrap_monitor(find_monitor(name))
end

function api.get_monitors()
    local list = {}
    for _, m in ipairs(state.monitors) do
        list[#list + 1] = wrap_monitor(m)
    end
    return list
end

function api.get_active_monitor()
    return wrap_monitor(state.focus_monitor)
end

function api.get_active_window()
    return wrap_window(state.focus_window)
end

function api.get_workspace(sel)
    return wrap_workspace(resolve_workspace(sel))
end

function api.get_workspaces()
    local list = {}
    for _, ws in ipairs(state.workspaces) do
        list[#list + 1] = wrap_workspace(ws)
    end
    return list
end

function api.get_windows()
    local list = {}
    for _, w in ipairs(state.windows) do
        list[#list + 1] = wrap_window(w)
    end
    return list
end

function api.get_layers(filter)
    local list = {}
    for _, l in ipairs(state.layers or {}) do
        if not filter or not filter.monitor or l.monitor == filter.monitor then
            list[#list + 1] = { namespace = l.namespace, mapped = true }
        end
    end
    return list
end

function api.get_cursor_pos()
    return { x = state.cursor.x, y = state.cursor.y }
end

function api.on(name, fn)
    local h = { id = state.next_handle, fn = fn, active = true }
    state.next_handle = state.next_handle + 1
    state.handlers[name] = state.handlers[name] or {}
    table.insert(state.handlers[name], h)
    return {
        remove = function()
            h.active = false
        end,
        is_active = function()
            return h.active
        end,
    }
end

function api.timer(fn, opts)
    local t = { fn = fn, opts = opts, enabled = true }
    state.timers[#state.timers + 1] = t
    t.handle = {
        set_enabled = function(_, on)
            t.enabled = on
        end,
        is_enabled = function()
            return t.enabled
        end,
    }
    return t.handle
end

local function rule_handle(kind, spec)
    local r = { spec = spec, enabled = spec.enabled ~= false }
    table.insert(state.rules[kind], r)
    return {
        set_enabled = function(_, on)
            r.enabled = on
        end,
        is_enabled = function()
            return r.enabled
        end,
    }
end

function api.window_rule(spec)
    return rule_handle("window", spec)
end

function api.layer_rule(spec)
    return rule_handle("layer", spec)
end

function api.workspace_rule(spec)
    state.refresh_scheduled = true
    return rule_handle("workspace", spec)
end

function api.monitor(spec)
    state.rules.monitor[spec.output] = spec
    state.refresh_scheduled = true
end

function api.exec_scheduled_prop_refresh_immediately()
    if not state.refresh_scheduled then
        return
    end
    state.refresh_scheduled = false
    for _, r in ipairs(state.rules.workspace) do
        if r.enabled and r.spec.persistent then
            local m = find_monitor(r.spec.monitor)
            if m then
                local ws = resolve_workspace(r.spec.workspace)
                if not ws then
                    ws = create_workspace(r.spec.workspace, m)
                elseif ws.monitor ~= m then
                    move_workspace_to_monitor(ws, m, true)
                end
                ws.persistent = true
            end
        end
    end
end

function api.bind(key, fn)
    state.binds[key] = fn
end

function api.unbind(key)
    state.binds[key] = nil
end

function api.exec_cmd(cmd)
    state.execs[#state.execs + 1] = cmd
end

api.notification = {
    create = function(spec)
        state.notifications[#state.notifications + 1] = spec.text
    end,
}

F.api = api

---------------------------------------------------------------------------
-- test-side helpers

function F.add_monitor(name, spec)
    spec = spec or {}
    local m = {
        name = name,
        x = spec.x or 0,
        y = spec.y or 0,
        width = spec.width or 1920,
        height = spec.height or 1080,
        scale = spec.scale or 1,
    }
    local rule = state.rules.monitor[name]
    if rule then
        m.scale = rule.scale or m.scale
        local px, py = (rule.position or ""):match("^(%-?%d+)x(%-?%d+)$")
        if px then
            m.x, m.y = tonumber(px), tonumber(py)
        end
    end
    state.monitors[#state.monitors + 1] = m
    if not state.focus_monitor then
        state.focus_monitor = m
    end
    -- setupDefaultWS: a monitor never comes up without a workspace.
    local ws = find_workspace_by(function(w)
        return w.monitor == m and not w.special
    end) or create_workspace(first_free_id(), m)
    m.active = ws
    -- Workspaces that last lived on a same-named output return to it.
    for _, w in ipairs(state.workspaces) do
        if w.last_monitor == name and w.monitor ~= m then
            w.last_monitor = nil
            move_workspace_to_monitor(w, m)
        end
    end
    if spec.remembered then
        local rw = resolve_workspace(spec.remembered)
        if rw then
            move_workspace_to_monitor(rw, m)
            m.active = rw -- changeWorkspace(internal): no events
        end
    end
    emit("monitor.added", wrap_monitor(m))
    return m
end

-- Unplugging migrates the monitor's workspaces to the first remaining
-- monitor, whichever that is; tests pass `dest` to model the worst case.
function F.remove_monitor(name, dest_name)
    local m = assert(find_monitor(name))
    local dest = dest_name and find_monitor(dest_name)
    if not dest then
        for _, other in ipairs(state.monitors) do
            if other ~= m then
                dest = other
                break
            end
        end
    end
    -- onDisconnect: collect the workspaces first, then move each one with
    -- moveWorkspaceToMonitor, which hands the active one over as active when
    -- the dying monitor had focus. monitor.removed fires only at the end.
    local to_move = {}
    for _, w in ipairs(state.workspaces) do
        if w.monitor == m then
            to_move[#to_move + 1] = w
            w.last_monitor = w.last_monitor or name
        end
    end
    if m.special then
        m.special = nil
    end
    for _, w in ipairs(to_move) do
        move_workspace_to_monitor(w, dest, true)
    end
    if state.focus_monitor == m then
        state.focus_monitor = dest
    end
    for i, other in ipairs(state.monitors) do
        if other == m then
            table.remove(state.monitors, i)
            break
        end
    end
    emit("monitor.removed", wrap_monitor(m))
end

function F.add_window(ws_sel, spec)
    spec = spec or {}
    local ws = resolve_workspace(ws_sel) or create_workspace(ws_sel, state.focus_monitor)
    local w = {
        address = string.format("0x%x", state.next_address),
        pid = spec.pid or (5000 + #state.windows),
        class = spec.class or "app",
        title = spec.title or "window",
        workspace = ws,
        no_focus = spec.no_focus,
    }
    state.next_address = state.next_address + 0x10
    state.windows[#state.windows + 1] = w
    ws.last_window = ws.last_window or w
    emit("window.open", wrap_window(w))
    return w
end

function F.workspace(sel)
    return resolve_workspace(sel)
end

function F.run(dispatcher)
    api.dispatch(dispatcher)
    F.frame()
end

-- A frame boundary. Hyprland may render before a deferred timer fires, so the
-- snapshot of what each monitor shows is taken first and pending oneshot
-- timers run afterwards; the next frame shows their effect.
function F.frame()
    local snapshot = {}
    for _, m in ipairs(state.monitors) do
        snapshot[m.name] = {
            active = m.active and m.active.name,
            special = m.special and m.special.name,
            focused = state.focus_monitor == m,
        }
    end
    state.frames[#state.frames + 1] = snapshot
    for _ = 1, 3 do
        local pending = {}
        for _, t in ipairs(state.timers) do
            if t.enabled and not t.ran and t.opts.type == "oneshot" then
                pending[#pending + 1] = t
            end
        end
        if #pending == 0 then
            break
        end
        for _, t in ipairs(pending) do
            t.ran = true
            t.fn()
        end
    end
    return snapshot
end

function F.state()
    return state
end

return F
