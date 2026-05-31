local plugin = {}

local API_BASE = "https://api.github.com/repos/JustRoccat/all-rspug/contents/"
local RAW_BASE = "https://raw.githubusercontent.com/JustRoccat/all-rspug/main/"

local categories = {
  { id = "plugins", name = "Plugins", path = "/.config/rs-pug/plugins/", repo_dir = "plugins", ext = ".lua" },
  { id = "themes", name = "Themes", path = "/.config/rs-pug/themes/", repo_dir = "themes", ext = ".json" },
  { id = "eq", name = "Equalizers", path = "/.config/rs-pug/eqpresets/", repo_dir = "eq", ext = ".json" }
}

local active_cat_idx = 1
local selected_idx = 1
local status_msg = "Press 'R' to fetch the current list from GitHub."
local catalog = { plugins = {}, themes = {}, eq = {} }
local fetched = false

local function get_target_filename(cat, item_file)
  local base_name = item_file:match("(.+)%..+$") or item_file
  return base_name .. cat.ext
end

local function check_installed(cat, item_file)
  local home = os.getenv("HOME") or ""
  local filename = get_target_filename(cat, item_file)
  local path = home .. cat.path .. filename
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function fetch_category_live(cat)
  local cmd = string.format("curl -s -H 'User-Agent: rs-pug-manager' '%s%s'", API_BASE, cat.repo_dir)
  local handle = io.popen(cmd)
  if not handle then return {} end
  
  local json_data = handle:read("*a")
  handle:close()

  local items = {}
  for name in string.gmatch(json_data, '"name":%s*"([^"]+)"') do
    if name ~= "README.md" and not string.match(name, "^%.") then
      table.insert(items, { name = name, file = name })
    end
  end
  return items
end

local function refresh_catalog()
  status_msg = "Connecting to GitHub API and syncing..."
  for _, cat in ipairs(categories) do
    catalog[cat.id] = fetch_category_live(cat)
  end
  fetched = true
  selected_idx = 1
  status_msg = "List synchronized successfully!"
end

local function current_category()
  return categories[active_cat_idx]
end

local function current_items()
  return catalog[current_category().id] or {}
end

local function install_item(cat, item)
  local home = os.getenv("HOME") or ""
  local target_dir = home .. cat.path
  
  os.execute("mkdir -p '" .. target_dir .. "'")
  
  local url = RAW_BASE .. cat.repo_dir .. "/" .. item.file
  local filename = get_target_filename(cat, item.file)
  local target_file = target_dir .. filename
  local cmd = string.format("curl -L -s -o '%s' '%s'", target_file, url)
  
  status_msg = "Downloading: " .. item.name .. "..."
  
  local success = os.execute(cmd)
  if success == 0 or success == true then
    status_msg = "Installed: " .. filename .. " (Restart required)"
  else
    status_msg = "Download error: " .. item.name
  end
end

local function uninstall_item(cat, item)
  local home = os.getenv("HOME") or ""
  local filename = get_target_filename(cat, item.file)
  local target_file = home .. cat.path .. filename
  
  local success, err = os.remove(target_file)
  if success then
    status_msg = "Uninstalled successfully: " .. filename
  else
    status_msg = "Cannot uninstall: " .. (err or filename)
  end
end

function plugin.on_ui_config(state)
  return {
    tabs = {
      custom = {
        { id = "rspug_dynamic_store", title = "Store", position = 3 }
      }
    },
    layout = {
      queue_width_percent = 35,
      custom_sections = {
        { id = "dynamic_store_status", position = "below_player", height = 3, content = "lua" }
      }
    }
  }
end

function plugin.on_key(key, state)
  if state.active_custom_tab ~= "rspug_dynamic_store" then
    return nil
  end

  if key == "esc" or key == "backspace" or key == "char:q" then
    return { consume = true, ui = { set_tab = "discover" } }
  end

  if key == "char:r" then
    refresh_catalog()
    return { consume = true }
  end

  if not fetched then return nil end

  if key == "left" then
    active_cat_idx = math.max(1, active_cat_idx - 1)
    selected_idx = 1
    return { consume = true }
  elseif key == "right" then
    active_cat_idx = math.min(#categories, active_cat_idx + 1)
    selected_idx = 1
    return { consume = true }
  end

  local items = current_items()
  if #items == 0 then return nil end

  if key == "up" then
    selected_idx = math.max(1, selected_idx - 1)
    return { consume = true }
  elseif key == "down" then
    selected_idx = math.min(#items, selected_idx + 1)
    return { consume = true }
  elseif key == "enter" then
    local item = items[selected_idx]
    install_item(current_category(), item)
    return { consume = true, flash = "Installed: " .. item.name .. ". Please restart rs-pug." }
  elseif key == "char:d" then
    local item = items[selected_idx]
    if check_installed(current_category(), item.file) then
      uninstall_item(current_category(), item)
      return { consume = true, flash = "Uninstalled: " .. item.name .. ". Please restart rs-pug." }
    else
      status_msg = "Cannot uninstall something you don't have!"
      return { consume = true }
    end
  end
end

function plugin.on_ui_panels(state)
  if state.active_custom_tab ~= "rspug_dynamic_store" then
    return nil
  end

  local cat_header = "RESOURCES:  "
  for i, cat in ipairs(categories) do
    if i == active_cat_idx then
      cat_header = cat_header .. "[ " .. cat.name .. " ]  "
    else
      cat_header = cat_header .. "  " .. cat.name .. "    "
    end
  end

  local list_items = {
    { type = "info", text = "--- ALL-RSPUG REPOSITORY ---" },
    { type = "text", text = cat_header },
    { type = "text", text = "Navigation: Left/Right (Categories) | Up/Down (Items)" },
    { type = "separator" }
  }

  if not fetched then
    table.insert(list_items, { type = "text", text = " No data. Press [R] to connect to GitHub." })
    return { { title = "Explorer", target = "results", items = list_items } }
  end

  local items = current_items()
  if #items == 0 then
    table.insert(list_items, { type = "text", text = "  Repository folder is empty." })
  else
    for i, item in ipairs(items) do
      local is_local = check_installed(current_category(), item.file)
      local status_tag = is_local and "[INSTALLED]" or "[    -    ]"
      
      local line = ""
      if i == selected_idx then
        line = string.format("> %-15s %s", status_tag, item.name)
      else
        line = string.format("  %-15s %s", status_tag, item.name)
      end
      
      table.insert(list_items, { type = "text", text = line })
    end
  end

  local detail_items = {
    { type = "header", text = "Package Management" },
    { type = "separator" }
  }

  if #items > 0 and items[selected_idx] then
    local selected_item = items[selected_idx]
    local is_local = check_installed(current_category(), selected_item.file)
    local local_filename = get_target_filename(current_category(), selected_item.file)
    
    table.insert(detail_items, { type = "option", key = "Filename", value = local_filename })
    table.insert(detail_items, { type = "option", key = "Status", value = is_local and "Installed locally" or "Available in cloud" })
    table.insert(detail_items, { type = "separator" })
    table.insert(detail_items, { type = "text", text = "Available actions:" })
    table.insert(detail_items, { type = "keybind", key = "ENTER", action = is_local and "Update file" or "Download and install" })
    if is_local then
      table.insert(detail_items, { type = "keybind", key = "d", action = "Uninstall from disk" })
    end
  else
    table.insert(detail_items, { type = "text", text = "Select an item to see options." })
  end
  
  table.insert(detail_items, { type = "separator" })
  table.insert(detail_items, { type = "keybind", key = "r", action = "Refresh GitHub database" })
  table.insert(detail_items, { type = "keybind", key = "q/esc", action = "Exit store" })

  return {
    { title = "Cloud Repository", target = "results", items = list_items },
    { title = "Status & Actions", target = "queue", items = detail_items }
  }
end

function plugin.on_ui_sections(state)
  return {
    dynamic_store_status = {
      { type = "info", text = "Message: " .. status_msg }
    }
  }
end

function plugin.on_ui_update(state)
  if state.active_custom_tab == "rspug_dynamic_store" then
    return { layout = { show_sections = { "dynamic_store_status" } } }
  end
  return { layout = { hide_sections = { "dynamic_store_status" } } }
end

return plugin
