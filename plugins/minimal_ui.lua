plugin = {}

local CFG = {
  tab_rail_width = 26,
  queue_width    = 50,
  queue_side     = "right",
  full_viz_rows  = 6,
  show_statusbar = false,
  section_id     = "now",
  max_title      = 120,

  tabs = {
    discover = { title = "Find",      icon = "○" },
    albums   = { title = "Albums",    icon = "◫" },
    library  = { title = "Playlists", icon = "≡" },
    ["local"] = { title = "Files",    icon = "▢" },
    options  = { title = "Setup",     icon = "·" },
  },
  tab_order = { "discover", "albums", "library", "local", "options" },

  glyph = {
    playing   = "▶",
    paused    = "▮▮",
    idle      = "■",
    searching = "…",
  },
}

local S = { title = nil }

local function clip(text, limit)
  if not text then return text end
  if utf8.len(text) and utf8.len(text) > limit then
    return text:sub(1, utf8.offset(text, limit - 1) - 1) .. "…"
  end
  return text
end

function plugin.on_event(event, _state)
  if event.kind == "started" then
    S.title = clip(event.message, CFG.max_title)
  end
end

local function now_lines(state)
  local glyph = CFG.glyph[state.player_state] or CFG.glyph.idle

  local head
  if state.player_state == "idle" then
    head = glyph .. "  nothing playing"
  elseif S.title then
    head = glyph .. "  " .. S.title
  else
    head = glyph .. "  …"
  end

  local meta = {}
  meta[#meta + 1] = state.muted and "muted" or ("vol " .. state.volume)
  if state.repeat_mode ~= "off" then
    meta[#meta + 1] = "repeat " .. state.repeat_mode
  end
  if state.queue_len > 0 then
    meta[#meta + 1] = state.queue_len .. " queued"
  end

  return {
    { type = "text", text = head },
    { type = "info", text = "   " .. table.concat(meta, "  ·  ") },
  }
end

do
  function plugin.on_ui_config(_state)
    local rename = {}
    for id, def in pairs(CFG.tabs) do
      rename[id] = { title = def.title, icon = def.icon }
    end

    local hide = { "volume_bar", "keybind_hints", "visualizer" }
    if not CFG.show_statusbar then
      hide[#hide + 1] = "statusbar"
    end

    return {
      tabs = {
        order  = CFG.tab_order,
        rename = rename,
      },
      layout = {
        tab_bar_position   = "left",
        tabs_width         = CFG.tab_rail_width,
        queue_position     = CFG.queue_side,
        queue_width_percent = CFG.queue_width,
        show_progress_bar  = true,
        hide               = hide,
        custom_sections    = {
          { id = CFG.section_id, position = "below_player", height = 4 },
        },
      },
    }
  end

  function plugin.on_ui_sections(state)
    return { [CFG.section_id] = now_lines(state) }
  end

  function plugin.on_key(key, state)
    if not ALLOW_LUA_UI_CHANGES then return nil end
    local layout = state.current_layout

    if key == "char:t" then
      local to = (layout.tab_bar_position == "left") and "top" or "left"
      return { consume = true, ui = { layout = { tab_bar_position = to } } }
    end

    if key == "char:w" then
      local to = (layout.queue_position == "right") and "left" or "right"
      return { consume = true, ui = { layout = { queue_position = to } } }
    end

    if key == "char:u" then
      if layout.visualizer_height > 0 then
        return {
          consume = true,
          ui = { layout = {
            visualizer_height = 0,
            show_sections = { CFG.section_id },
          } },
        }
      end
      return {
        consume = true,
        ui = { layout = {
          visualizer_height = CFG.full_viz_rows,
          hide_sections = { CFG.section_id },
        } },
      }
    end
  end

end

function plugin.on_ui_panels(state)
  if ALLOW_LUA_UI_CHANGES then return nil end
  return { { title = "now", target = "overlay", items = now_lines(state) } }
end

return plugin
