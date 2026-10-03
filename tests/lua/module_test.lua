-- Scenario tests for hyprland/yt-stream-workspace.lua against tests/lua/fake_hl.lua.
--
-- Run through tests/lua.sh, which provides XDG_RUNTIME_DIR and
-- HYPRLAND_INSTANCE_SIGNATURE. The central assertion is about rendering: at
-- every frame boundary after activation the stream output must show the
-- stream workspace (or the curtain) and no special workspace.

local root = assert(os.getenv("YTWS_ROOT"), "YTWS_ROOT is not set")
local run_dir = assert(os.getenv("XDG_RUNTIME_DIR")) .. "/yt-stream-workspace"
package.path = root .. "/tests/lua/?.lua;" .. package.path
local F = require("fake_hl")

local OUT = "YT-STREAM"
local failures, passed = 0, 0

local function write_intent(fields)
    local intent = {
        protocol = 1,
        output = OUT,
        workspace = 3,
        mode = "1920x1080@60",
        scale = 1.5,
        preview_monitor = "",
        stream_layers = "(.*wallpaper.*)",
        private_windows = "",
        mix_sink = "yt_stream_mix",
    }
    for k, v in pairs(fields or {}) do
        intent[k] = v
    end
    local parts = {}
    for k, v in pairs(intent) do
        parts[#parts + 1] = string.format("[%q] = %s,", k, type(v) == "string" and string.format("%q", v) or tostring(v))
    end
    local f = assert(io.open(run_dir .. "/session.lua", "w"))
    f:write("return {\n" .. table.concat(parts, "\n") .. "\n}\n")
    f:close()
end

local function load_module()
    _G.hl = F.api
    return dofile(root .. "/hyprland/yt-stream-workspace.lua")
end

local function fresh()
    os.remove(run_dir .. "/compositor.lua")
    os.remove(run_dir .. "/phase")
    YTWS = nil
    F.reset()
    return load_module()
end

-- A laptop panel with three workspaces; workspace 3 is the one to stream.
local function desktop(opts)
    opts = opts or {}
    local ytws = fresh()
    F.add_monitor("eDP-1", { width = 1920, height = 1080, scale = 1.5 })
    F.add_window("1", { class = "terminal" })
    F.add_window("2", { class = "browser" })
    F.add_window("3", { class = "editor" })
    F.run(hl.dsp.focus({ workspace = opts.focus or "3" }))
    return ytws
end

local function start(ytws, intent, monitor_spec)
    write_intent(intent)
    local result = ytws.begin()
    assert(result:match('"ok":true'), "begin failed: " .. result)
    F.add_monitor(OUT, monitor_spec or { width = 1920, height = 1080 })
    F.frame()
    assert(ytws.phase() == "active", "session did not become active: " .. ytws.phase())
end

local function frames_from(n)
    return { table.unpack(F.state().frames, n) }
end

local function assert_output_clean(since, want)
    want = want or "3"
    for i, frame in ipairs(frames_from(since)) do
        local out = frame[OUT]
        if out then
            if out.active ~= want then
                error(string.format("frame %d: stream output showed %s instead of %s", since + i - 1, tostring(out.active), want))
            end
            if out.special then
                error(string.format("frame %d: special workspace %s shown on the stream output", since + i - 1, out.special))
            end
        end
    end
end

local function assert_only_allowed_on_output()
    for _, ws in ipairs(F.state().workspaces) do
        if ws.monitor and ws.monitor.name == OUT then
            assert(ws.name == "3" or ws.name == "stream-curtain", "workspace " .. ws.name .. " is still assigned to the stream output")
        end
    end
end

local function monitor_of(name)
    local ws = F.workspace(name) or F.workspace("name:" .. name)
    return ws and ws.monitor and ws.monitor.name
end

local function active_on(mon)
    for _, m in ipairs(F.state().monitors) do
        if m.name == mon then
            return m.active and m.active.name
        end
    end
end

local function focused()
    return F.state().focus_monitor.name
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

---------------------------------------------------------------------------

test("starting from the stream workspace keeps the streamer in it", function()
    local ytws = desktop()
    start(ytws)
    assert(active_on(OUT) == "3")
    assert(focused() == OUT, "focus should follow the workspace onto the output")
    assert(active_on("eDP-1") == "stream-preview", "the physical monitor should show the preview")
    assert_output_clean(1)
end)

test("starting another workspace leaves the streamer where they are", function()
    local ytws = desktop({ focus = "1" })
    start(ytws)
    assert(active_on(OUT) == "3")
    assert(focused() == "eDP-1")
    assert(active_on("eDP-1") == "1")
end)

test("a workspace that does not exist yet is created on the output", function()
    local ytws = desktop({ focus = "1" })
    start(ytws, { workspace = 7 })
    assert(active_on(OUT) == "7")
    assert(monitor_of("7") == OUT)
end)

test("workspaces Hyprland returns to a recreated output are sent home", function()
    local ytws = desktop({ focus = "1" })
    F.workspace("2").last_monitor = OUT
    start(ytws, nil, { remembered = "1" })
    assert(active_on(OUT) == "3")
    F.frame()
    assert_only_allowed_on_output()
    assert(monitor_of("1") == "eDP-1" and monitor_of("2") == "eDP-1")
end)

test("a new workspace opened from the stream output goes to the physical monitor", function()
    local ytws = desktop()
    start(ytws)
    local mark = #F.state().frames + 1
    F.run(hl.dsp.focus({ workspace = "5" }))
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
    assert(monitor_of("5") == "eDP-1")
    assert(active_on("eDP-1") == "5", "the streamer asked for workspace 5")
    assert(focused() == "eDP-1")
end)

test("moving a private workspace onto the output is undone", function()
    local ytws = desktop()
    start(ytws)
    local mark = #F.state().frames + 1
    F.run(hl.dsp.workspace.move({ workspace = "2", monitor = OUT }))
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
end)

test("moving and activating a private workspace in one action never renders it", function()
    local ytws = desktop()
    start(ytws)
    local mark = #F.state().frames + 1
    hl.dispatch(hl.dsp.workspace.move({ workspace = "2", monitor = OUT }))
    hl.get_monitor(OUT):set_workspace({ workspace = "2" })
    F.frame()
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
end)

test("a special workspace toggled on the output opens on the physical monitor", function()
    local ytws = desktop()
    start(ytws)
    F.add_window("special:notes", { class = "notes" })
    local mark = #F.state().frames + 1
    F.run(hl.dsp.workspace.toggle_special("notes"))
    F.frame()
    assert_output_clean(mark)
    local edp = F.state().monitors[1]
    assert(edp.special and edp.special.name == "special:notes", "special workspace should be shown privately")
end)

test("a special workspace opened while working in the stream takes focus privately", function()
    local ytws = desktop()
    start(ytws)
    assert(focused() == OUT)
    F.add_window("special:notes", { class = "notes" })
    F.run(hl.dsp.workspace.toggle_special("notes"))
    F.frame()
    F.frame()
    assert(focused() == "eDP-1", "the scratchpad should have focus")
    assert(F.state().focus_window and F.state().focus_window.class == "notes")
    -- Closing it over the preview puts the streamer back in the stream.
    hl.get_monitor("eDP-1"):set_special_workspace({})
    F.frame()
    F.frame()
    assert(focused() == OUT, "closing the scratchpad should return to the stream")
end)

test("moving focus to the physical monitor shows the previous workspace, not the preview", function()
    local ytws = desktop({ focus = "1" })
    start(ytws)
    ytws.enter()
    F.frame()
    assert(focused() == OUT)
    F.run(hl.dsp.focus({ monitor = "eDP-1" }))
    F.frame()
    assert(focused() == "eDP-1")
    assert(active_on("eDP-1") == "1")
end)

test("switching the physical monitor to the preview enters the stream", function()
    local ytws = desktop({ focus = "1" })
    start(ytws)
    F.run(hl.dsp.focus({ workspace = "name:stream-preview" }))
    F.frame()
    assert(focused() == OUT)
end)

test("the pointer keeps its place between the preview and the output", function()
    local ytws = desktop({ focus = "1" })
    start(ytws)
    local out = F.state().monitors[2]
    ytws.enter()
    F.frame()
    -- Pointer at the centre of the output maps to the centre of the panel.
    F.state().cursor = { x = out.x + 640, y = out.y + 360 }
    ytws.leave()
    F.frame()
    local c = F.state().cursor
    assert(math.abs(c.x - 640) < 2 and math.abs(c.y - 360) < 2, string.format("leave put the pointer at %d,%d", c.x, c.y))
    -- Over the preview at (100, 50) enters at the matching output point.
    F.run(hl.dsp.focus({ workspace = "name:stream-preview" }))
    F.state().cursor = { x = 100, y = 50 }
    ytws.enter()
    F.frame()
    F.frame()
    c = F.state().cursor
    assert(math.abs(c.x - (out.x + 100)) < 2 and math.abs(c.y - (out.y + 50)) < 2,
        string.format("enter put the pointer at %d,%d", c.x, c.y))
end)

test("swapping monitors cannot put a private workspace on the output", function()
    local ytws = desktop({ focus = "2" })
    start(ytws)
    local mark = #F.state().frames + 1
    F.run(hl.dsp.workspace.swap_monitors({ monitor1 = "eDP-1", monitor2 = OUT }))
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
end)

test("focusing a private workspace on the current monitor from the output is undone", function()
    local ytws = desktop()
    start(ytws)
    local mark = #F.state().frames + 1
    F.run(hl.dsp.focus({ workspace = "2", on_current_monitor = true }))
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
    assert(active_on("eDP-1") == "2")
end)

test("unplugging the focused monitor when the output is the only one left", function()
    local ytws = desktop()
    F.add_monitor("DP-1", { x = 1280, width = 1920, height = 1080 })
    F.add_window("8", { class = "chat" })
    F.run(hl.dsp.workspace.move({ workspace = "8", monitor = "DP-1" }))
    F.run(hl.dsp.focus({ workspace = "3" }))
    start(ytws)
    F.run(hl.dsp.focus({ workspace = "8" }))
    assert(focused() == "DP-1")
    local mark = #F.state().frames + 1
    F.remove_monitor("DP-1", OUT)
    F.frame()
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
    assert(monitor_of("8") == "eDP-1", "migrated workspaces should land on a physical monitor")
end)

test("enter and leave hand input over and carry the pointer", function()
    local ytws = desktop({ focus = "1" })
    start(ytws)
    F.state().cursor = { x = 640, y = 360 }
    ytws.enter()
    F.frame()
    assert(focused() == OUT)
    assert(active_on("eDP-1") == "stream-preview")
    ytws.leave()
    F.frame()
    assert(focused() == "eDP-1")
    assert(active_on("eDP-1") == "1", "leave should return to the workspace shown before entering")
end)

test("ordinary workspace keys enter and leave the stream", function()
    local ytws = desktop({ focus = "1" })
    start(ytws)
    F.run(hl.dsp.focus({ workspace = "3" }))
    assert(focused() == OUT)
    assert(active_on("eDP-1") == "stream-preview")
    F.run(hl.dsp.focus({ workspace = "2" }))
    assert(focused() == "eDP-1")
    assert(active_on("eDP-1") == "2")
end)

test("the curtain hides the stream and keeps the work private", function()
    local ytws = desktop()
    start(ytws)
    local mark = #F.state().frames + 1
    ytws.curtain(true)
    F.frame()
    assert_output_clean(mark, "stream-curtain")
    assert(monitor_of("3") == "eDP-1" and active_on("eDP-1") == "3", "the stream workspace should be usable privately")
    assert(focused() == "eDP-1")
    local muted = false
    for _, cmd in ipairs(F.state().execs) do
        muted = muted or (cmd:match("set%-sink%-volume yt_stream_mix 0") ~= nil
            and cmd:match("set%-source%-volume yt_stream_mix%.monitor 0") ~= nil)
    end
    assert(muted, "the stream audio should be muted")
    F.run(hl.dsp.focus({ monitor = OUT }))
    assert(focused() == "eDP-1", "focus must not reach the curtain")
    mark = #F.state().frames + 1
    ytws.curtain(false)
    F.frame()
    assert_output_clean(mark, "3")
    assert(focused() == OUT, "the streamer was working on it, so they follow it back")
end)

test("finish returns the workspace and keeps working in it", function()
    local ytws = desktop()
    start(ytws)
    local result = ytws.finish()
    assert(result:match('"ok":true'), result)
    F.frame()
    assert(monitor_of("3") == "eDP-1")
    assert(active_on("eDP-1") == "3")
    for _, kind in ipairs({ "window", "layer" }) do
        for _, rule in ipairs(F.state().rules[kind]) do
            assert(not rule.enabled, kind .. " rule left enabled after finish")
        end
    end
    assert(ytws.phase() == "none")
end)

test("a configuration reload re-arms the guard from saved state", function()
    local ytws = desktop()
    start(ytws)
    -- Hyprland reload: a fresh Lua state over the same compositor.
    local st = F.state()
    st.handlers, st.timers, st.binds = {}, {}, {}
    YTWS = nil
    ytws = load_module()
    F.frame()
    assert(ytws.phase() == "active")
    local mark = #F.state().frames + 1
    F.run(hl.dsp.focus({ workspace = "6" }))
    F.frame()
    assert_output_clean(mark)
    assert_only_allowed_on_output()
end)

test("status is valid JSON-shaped output", function()
    local ytws = desktop()
    start(ytws)
    local status = ytws.status()
    assert(status:match('"phase":"active"'), status)
    assert(status:match('"showing":"3"'), status)
end)

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
