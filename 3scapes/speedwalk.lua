-- Speedwalker Plugin for Lera
-- Manages hierarchical place definitions with paths between them.
-- Users can define routes and quickly travel using commands like .home-fantasy or .home

local M = {}
M.name = "speedwalk"
M.version = "1.0"
M.priority = 50  -- Run before most plugins to intercept commands

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local graph = nil           -- speedwalk.graph userdata
local current_place = nil   -- Current place name (string)
local walk_queue = {}       -- Queue of commands to send
local walk_paused = false   -- True if walk is paused waiting for ".."
local walk_delay = 0        -- Delay between commands (ms), 0 = instant
local walk_timer = nil      -- Timer ID for delayed walking
local routes = {}           -- Route definitions: {from=, to=, path_str=}

-- Place definitions with step-lists for autostepping
-- place_data[name] = {steps="n|2s|nwn", targets="blob,troll"}
local place_data = {}

-- Step-list for autostepper integration
local step_list = {}        -- List of commands for current autostep
local step_targets = ""     -- Targets for current autostep
local step_index = 0        -- Current position in step_list (0 = not started)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local config = {
  command_prefix = ".",     -- Prefix for speedwalk commands
  continue_cmd = "..",      -- Command to continue after pause / single step
  unstep_cmd = ".,",        -- Command to take a step backward
}

-- Direction reversal table
local reverse_dir = {
  n = "s", s = "n", e = "w", w = "e",
  ne = "sw", sw = "ne", nw = "se", se = "nw",
  u = "d", d = "u",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Parse a route command like ".home-fantasy" -> from="home", to="fantasy"
-- or ".home" -> from=nil (current), to="home"
local function parse_walk_command(text)
  if not text:match("^" .. config.command_prefix) then
    return nil, nil
  end

  -- Remove prefix
  local route = text:sub(#config.command_prefix + 1)
  if route == "" then return nil, nil end

  -- Check for from-to format
  local from, to = route:match("^([^-]+)-(.+)$")
  if from and to then
    return from, to
  end

  -- Just destination (use current place as from)
  return nil, route
end

-- Send a command to the MUD
local function send_command(cmd)
  if cmd == "" then
    -- Empty command is a pause marker - handled elsewhere
    return
  end
  mud.send(cmd)
end

-- Process the next command in the walk queue
local function process_walk_queue()
  if walk_paused then return end
  if #walk_queue == 0 then
    -- Walk complete
    walk_timer = nil
    return
  end

  local cmd = table.remove(walk_queue, 1)

  -- Check for pause marker (empty string)
  if cmd == "" then
    walk_paused = true
    print("[speedwalk] Paused - type '" .. config.continue_cmd .. "' to continue")
    return
  end

  -- Send the command
  send_command(cmd)

  -- Schedule next command if there are more
  if #walk_queue > 0 then
    if walk_delay > 0 then
      walk_timer = timer.after(walk_delay, process_walk_queue)
    else
      -- Instant - process next immediately
      process_walk_queue()
    end
  end
end

-- Start walking a path
local function start_walk(commands)
  -- Clear any existing walk
  walk_queue = {}
  walk_paused = false
  if walk_timer then
    timer.cancel(walk_timer)
    walk_timer = nil
  end

  -- Queue the commands
  for _, cmd in ipairs(commands) do
    table.insert(walk_queue, cmd)
  end

  -- Start processing
  process_walk_queue()
end

-- Clear the walk queue
local function clear_walk()
  walk_queue = {}
  walk_paused = false
  if walk_timer then
    timer.cancel(walk_timer)
    walk_timer = nil
  end
  print("[speedwalk] Walk cleared")
end

-- Continue a paused walk
local function continue_walk()
  if not walk_paused then
    return false  -- Not paused
  end
  walk_paused = false
  print("[speedwalk] Continuing...")
  process_walk_queue()
  return true
end

-- Take a single step forward in the step-list
-- Each step may contain multiple commands (speedwalk expanded)
local function single_step()
  if #step_list == 0 then
    print("[speedwalk] No steps loaded")
    return false
  end

  step_index = step_index + 1
  if step_index > #step_list then
    step_index = 1  -- Wrap around
  end

  local step = step_list[step_index]
  if step then
    print("[speedwalk] Step " .. step_index .. "/" .. #step_list .. ": " .. step.raw ..
          " (" .. #step.commands .. " cmds)")
    -- Send all commands in this step
    for _, cmd in ipairs(step.commands) do
      mud.send(cmd)
    end
    return true
  end
  return false
end

-- Take a step backward (unstep) in the step-list
-- Reverses all commands in the current step
local function unstep()
  if #step_list == 0 then
    print("[speedwalk] No steps loaded")
    return false
  end

  -- Get current step before decrementing
  local step = step_list[step_index]
  if not step then
    -- At position 0, wrap to end
    step_index = #step_list
    step = step_list[step_index]
  end

  if step then
    print("[speedwalk] Unstep " .. step_index .. "/" .. #step_list .. ": " .. step.raw)
    -- Reverse all commands in this step (in reverse order)
    for i = #step.commands, 1, -1 do
      local cmd = step.commands[i]
      local rev = reverse_dir[cmd]
      if rev then
        mud.send(rev)
      else
        -- For non-direction commands, just send the same command
        -- (might not be reversible, but that's the user's problem)
        print("[speedwalk] Cannot reverse: " .. cmd)
      end
    end
  end

  -- Move index backward
  step_index = step_index - 1
  if step_index < 1 then
    step_index = #step_list  -- Wrap around
  end

  return true
end

--------------------------------------------------------------------------------
-- Route Management
--------------------------------------------------------------------------------

-- Counter for frame arena resets during bulk operations
local register_count = 0
local RESET_INTERVAL = 100  -- Reset frame arena every N registrations

-- Register a route between two places
-- path_str: speedwalk path syntax (e.g., "2n3e(se)")
function M.register(from, to, path_str, reverse_path_str, steps, targets)
  if not graph then
    print("[speedwalk] Graph not initialized")
    return false
  end

  -- Periodically reset frame arena during bulk loading to prevent exhaustion
  register_count = register_count + 1
  if register_count % RESET_INTERVAL == 0 then
    lera.frame_reset()
  end

  -- Parse the actual path (empty path is valid - means no movement needed)
  local path, err
  if path_str == "" then
    path = {}  -- Empty path is valid
  else
    path, err = speedwalk.parse(path_str)
    if not path then
      -- Show hex of path_str for first few failures
      local hex = ""
      for i = 1, math.min(#path_str, 20) do
        hex = hex .. string.format("%02x ", path_str:byte(i))
      end
      print("[speedwalk] Failed " .. from .. "->" .. to .. ": '" .. path_str .. "' len=" .. #path_str .. " hex=[" .. hex .. "]" .. (err and (" err=" .. err) or ""))
      return false
    end
  end

  -- Add edge to graph
  local ok = graph:add_edge(from, to, path, "", "")
  if not ok then
    print("[speedwalk] Failed to add edge: " .. from .. " -> " .. to)
    return false
  end

  -- Store route definition for persistence (avoid duplicates)
  local route_exists = false
  for _, r in ipairs(routes) do
    if r.from == from and r.to == to then
      -- Update existing route
      r.path_str = path_str
      route_exists = true
      break
    end
  end
  if not route_exists then
    table.insert(routes, {
      from = from,
      to = to,
      path_str = path_str,
    })
  end

  -- Handle reverse path
  if reverse_path_str and reverse_path_str ~= "" then
    -- Explicit reverse path provided
    local rev_path = speedwalk.parse(reverse_path_str)
    if rev_path and #rev_path > 0 then
      graph:add_edge(to, from, rev_path, "", "")
    end
  elseif #path == 0 then
    -- Empty path - reverse is also empty
    graph:add_edge(to, from, {}, "", "")
  else
    -- Auto-generate reverse if possible
    local reversed = speedwalk.reverse(path)
    if reversed and #reversed > 0 then
      graph:add_edge(to, from, reversed, "", "")
    end
  end

  -- Configure place with steps and targets if provided
  if steps and steps ~= "" then
    -- Handle targets - can be string or table
    local target_str = ""
    if type(targets) == "table" then
      target_str = table.concat(targets, ",")
    elseif type(targets) == "string" then
      target_str = targets
    end

    -- Store under destination name (that's where you step around)
    place_data[to] = {
      steps = steps,
      targets = target_str,
    }
  end

  return true
end

-- Register a one-way route (no automatic reverse)
function M.register_oneway(from, to, path_str)
  if not graph then
    print("[speedwalk] Graph not initialized")
    return false
  end

  local path = speedwalk.parse(path_str)
  if not path then
    print("[speedwalk] Failed to parse path: " .. path_str)
    return false
  end

  local ok = graph:add_edge(from, to, path, "", "")
  if not ok then
    print("[speedwalk] Failed to add edge: " .. from .. " -> " .. to)
    return false
  end

  -- Store route definition for persistence (avoid duplicates)
  local route_exists = false
  for _, r in ipairs(routes) do
    if r.from == from and r.to == to then
      r.path_str = path_str
      r.oneway = true
      route_exists = true
      break
    end
  end
  if not route_exists then
    table.insert(routes, {
      from = from,
      to = to,
      path_str = path_str,
      oneway = true,
    })
  end

  return true
end

--------------------------------------------------------------------------------
-- Place Configuration (for autostepping)
--------------------------------------------------------------------------------

-- Configure a place with step-list and targets for autostepping
-- steps: pipe-separated directions (e.g., "n|2s|nwn|2s")
-- targets: comma-separated monster names to kill (e.g., "blob,troll")
function M.configure_place(name, steps, targets)
  if not graph then
    print("[speedwalk] Graph not initialized")
    return false
  end

  -- Ensure place exists
  graph:add_place(name)

  place_data[name] = {
    steps = steps or "",
    targets = targets or "",
  }

  print("[speedwalk] Configured place: " .. name)
  return true
end

-- Get place configuration
function M.get_place_config(name)
  return place_data[name]
end

-- Walk from current place to destination
function M.walk_to(dest)
  if not current_place then
    print("[speedwalk] Current place not set. Use '/speedwalk set <place>' to set it.")
    return false
  end

  return M.walk_between(current_place, dest)
end

-- Walk between two explicit places
function M.walk_between(from, to)
  if not graph then
    print("[speedwalk] Graph not initialized")
    return false
  end

  -- Find path through graph
  local path_ids = graph:find_path(from, to)
  if not path_ids or #path_ids < 2 then
    print("[speedwalk] No path from '" .. from .. "' to '" .. to .. "'")
    return false
  end

  -- Collect all commands for the path
  local all_commands = {}

  for i = 1, #path_ids - 1 do
    local edge = graph:get_edge(path_ids[i], path_ids[i + 1])
    if not edge then
      print("[speedwalk] Missing edge in path")
      return false
    end

    local commands = speedwalk.flatten(edge.path)
    if commands then
      for _, cmd in ipairs(commands) do
        table.insert(all_commands, cmd)
      end
    end
  end

  if #all_commands == 0 then
    print("[speedwalk] No commands to execute")
    return false
  end

  -- Update current place to destination
  local dest_place = graph:get_place_by_id(path_ids[#path_ids])
  if dest_place then
    current_place = dest_place.name
    -- Auto-load steps for destination
    if place_data[dest_place.name] and place_data[dest_place.name].steps ~= "" then
      M.load_steps()
    else
      step_list = {}
      step_targets = ""
      step_index = 0
    end
  end

  -- Start the walk
  print("[speedwalk] Walking: " .. from .. " -> " .. to .. " (" .. #all_commands .. " commands)")
  start_walk(all_commands)
  return true
end

-- Walk to a named place, falling back to interpreting the argument as a
-- speedwalk path. Shared by the "." shorthand and "/speedwalk walk".
function M.walk_path(input)
  if M.walk_to(input) then
    return true
  end

  local path = speedwalk.parse(input)
  if path and #path > 0 then
    local commands = speedwalk.flatten(path)
    if commands and #commands > 0 then
      print("[speedwalk] Executing path: " .. #commands .. " commands")
      start_walk(commands)
      return true
    end
  end

  return false
end

-- Show path without walking
function M.show_path(from, to)
  if not graph then
    print("[speedwalk] Graph not initialized")
    return
  end

  -- If only one argument, use current place as from
  if not to then
    to = from
    from = current_place
    if not from then
      print("[speedwalk] Current place not set. Use '/speedwalk set <place>' to set it.")
      return
    end
  end

  local path_ids = graph:find_path(from, to)
  if not path_ids or #path_ids < 2 then
    print("[speedwalk] No path from '" .. from .. "' to '" .. to .. "'")
    return
  end

  print("[speedwalk] Path: " .. from .. " -> " .. to)

  local all_commands = {}
  for i = 1, #path_ids - 1 do
    local from_place = graph:get_place_by_id(path_ids[i])
    local to_place = graph:get_place_by_id(path_ids[i + 1])
    local edge = graph:get_edge(path_ids[i], path_ids[i + 1])

    if from_place and to_place and edge then
      local commands = speedwalk.flatten(edge.path)
      local cmd_str = commands and table.concat(commands, ", ") or "?"
      print("  " .. from_place.name .. " -> " .. to_place.name .. ": " .. cmd_str)
      for _, cmd in ipairs(commands or {}) do
        table.insert(all_commands, cmd)
      end
    end
  end

  print("[speedwalk] Total: " .. #all_commands .. " commands")
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

local alias_ids = {}  -- Store alias IDs for the "." shorthands
local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the "." shorthands still work.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local function show_help()
  print("[speedwalk] Commands:")
  print("  .place              - Walk from current place to 'place'")
  print("  .from-to            - Walk from 'from' to 'to'")
  print("  ..                  - Continue after pause, or single step forward")
  print("  .,                  - Single step backward (unstep)")
  print("  /speedwalk set [place] - Set/show current location")
  print("  /speedwalk clear    - Clear the walk queue")
  print("  /speedwalk walk <p> - Walk to a place or run a path")
end

-- The "." shorthands stay raw aliases: they are movement syntax, not slash
-- tokens the command registry can express. The word-shaped subcommands
-- (".set", ".clear") moved to /speedwalk.
local function register_aliases()
  -- Order matters! More specific patterns first.

  -- "." - show help
  alias_ids[#alias_ids + 1] = alias.add("^\\.$", function()
    show_help()
    return nil  -- Suppress
  end)

  -- ".." - continue walk or single step
  alias_ids[#alias_ids + 1] = alias.add("^\\.\\.$", function()
    -- Try to continue paused walk first
    if not continue_walk() then
      -- Not paused - take a single step
      single_step()
    end
    return nil
  end)

  -- ".," - unstep (step backward)
  alias_ids[#alias_ids + 1] = alias.add("^\\.,", function()
    unstep()
    return nil
  end)

  -- ".from-to" - walk between places
  alias_ids[#alias_ids + 1] = alias.add("^\\.([^-]+)-(.+)$", function(_, from, to)
    M.walk_between(from, to)
    return nil
  end)

  -- ".place" - walk to place, or execute as speedwalk path (must be last)
  alias_ids[#alias_ids + 1] = alias.add("^\\.(.+)$", function(_, input)
    -- A failure has already printed its own error inside walk_to.
    M.walk_path(input)
    return nil
  end)
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do
    if id then alias.remove(id) end
  end
  alias_ids = {}
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function set_place(place)
  if not graph then
    print("[speedwalk] Not initialized")
    return
  end
  if place == "" then
    if current_place then
      print("[speedwalk] Current place: " .. current_place)
    else
      print("[speedwalk] Current place not set. Use '/speedwalk set <place>' to set it.")
    end
    return
  end

  graph:add_place(place)
  current_place = place
  print("[speedwalk] Current place: " .. current_place)
  -- Auto-load steps if available for this place
  if place_data[place] and place_data[place].steps and place_data[place].steps ~= "" then
    M.load_steps()
  else
    -- Clear any old steps
    step_list = {}
    step_targets = ""
    step_index = 0
  end
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub:lower()

  if sub == "" or sub == "help" then
    show_help()
  elseif sub == "set" then
    set_place(rest)
  elseif sub == "clear" then
    clear_walk()
  elseif sub == "walk" then
    if rest == "" then
      print("[speedwalk] Usage: /speedwalk walk <place|path>")
    else
      M.walk_path(rest)
    end
  else
    print("[speedwalk] Unknown subcommand: " .. sub)
    show_help()
  end
end

local function register_command()
  if not command then return end
  local id, err = command.register({
    name = "/speedwalk",
    usage = "/speedwalk [set [place]|clear|walk <place|path>]",
    summary = "Speedwalk paths and named places",
    description = "Walks stored routes between named places. The shorthands "
      .. "are '.place' to walk to a place or run a path, '.from-to' to walk "
      .. "between two places, '..' to continue or single-step, '.,' to step "
      .. "back, and '.' for help.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    print("[speedwalk] command registration failed: " .. tostring(err))
  end
end

local function unregister_command()
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

function M.on_load()
  -- Create the graph
  graph = speedwalk.graph_create(256, 512)
  if not graph then
    print("[speedwalk] Failed to create graph")
    return
  end

  -- Register the "." shorthands and the /speedwalk command
  register_aliases()
  register_command()

  -- Load saved state
  store.load()
  local data = store.get()
  if data then
    -- Restore current place
    if data.current_place then
      current_place = data.current_place
      graph:add_place(current_place)
    end

    -- Restore delay setting
    if data.walk_delay then
      walk_delay = data.walk_delay
    end

    -- Note: routes are not restored from storage - they're defined in speedwalks.lua
    -- and registered when that file is loaded

    -- Restore place data (steps and targets)
    if data.place_data then
      for name, pdata in pairs(data.place_data) do
        place_data[name] = pdata
        graph:add_place(name)
      end
    end

    -- Auto-load steps for current place and restore step index
    if current_place and place_data[current_place] then
      M.load_steps()
      if data.step_index and data.step_index > 0 and data.step_index <= #step_list then
        step_index = data.step_index
      end
    end
  end

  local stats = string.format("%d places, %d routes", graph:place_count(), graph:edge_count())
  if current_place then
    stats = stats .. ", at " .. current_place
    if #step_list > 0 then
      stats = stats .. " [" .. step_index .. "/" .. #step_list .. "]"
    end
  end
  print("[speedwalk] Loaded: " .. stats)
end

function M.on_unload()
  unregister_aliases()
  unregister_command()

  -- Cancel any pending walk timer
  if walk_timer then
    timer.cancel(walk_timer)
    walk_timer = nil
  end

  -- Save state (routes not saved - they're defined in speedwalks.lua)
  store.set({
    current_place = current_place,
    step_index = step_index,
    walk_delay = walk_delay,
    place_data = place_data,
  })
  store.save()

  print("[speedwalk] Saved and unloaded")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Get current place
function M.get_current_place()
  return current_place
end

-- Set current place
function M.set_current_place(place)
  if graph then
    graph:add_place(place)
  end
  current_place = place
  -- Auto-load steps if available for this place
  if place_data[place] and place_data[place].steps and place_data[place].steps ~= "" then
    M.load_steps()
  else
    -- Clear any old steps
    step_list = {}
    step_targets = ""
    step_index = 0
  end
end

-- Get walk delay
function M.get_delay()
  return walk_delay
end

-- Set walk delay
function M.set_delay(ms)
  walk_delay = ms or 0
end

-- Check if currently walking
function M.is_walking()
  return #walk_queue > 0 or walk_paused
end

-- Check if paused
function M.is_paused()
  return walk_paused
end

-- Get queue length
function M.queue_length()
  return #walk_queue
end

-- Clear walk (alias)
M.clear = clear_walk

-- Continue walk (alias)
M.continue = continue_walk

-- Single step forward (alias)
M.step = single_step

-- Single step backward (alias)
M.unstep = unstep

-- Get the graph for advanced usage
function M.get_graph()
  return graph
end

--------------------------------------------------------------------------------
-- Step-list API (for autostepper integration)
--------------------------------------------------------------------------------

-- Parse a pipe-separated step string into step entries
-- Each segment is kept as a unit - when executed, it's expanded as a speedwalk
-- Returns: list of {raw = "original", commands = {"cmd1", "cmd2", ...}}
local function parse_steps(steps_str)
  if not steps_str or steps_str == "" then return {} end

  -- Check if C API is available
  if not speedwalk or not speedwalk.parse then
    print("[speedwalk] ERROR: C speedwalk API not available!")
    -- Fallback: split by | and return raw segments
    local result = {}
    for segment in steps_str:gmatch("[^|]+") do
      segment = segment:match("^%s*(.-)%s*$")
      if segment ~= "" then
        table.insert(result, { raw = segment, commands = {segment} })
      end
    end
    return result
  end

  local result = {}
  for segment in steps_str:gmatch("[^|]+") do
    segment = segment:match("^%s*(.-)%s*$")  -- trim
    if segment ~= "" then
      -- Parse as speedwalk syntax
      local path, err = speedwalk.parse(segment)
      local cmds
      if path and #path > 0 then
        cmds = speedwalk.flatten(path)
        if not cmds or #cmds == 0 then
          -- Flatten failed, use raw segment
          print("[speedwalk] DEBUG: flatten failed for '" .. segment .. "'")
          cmds = {segment}
        end
      else
        -- If parsing fails, treat as literal command
        if segment:match("[%(%)%d]") then
          -- Has speedwalk syntax chars but failed to parse
          -- Show hex bytes for debugging
          local hex = ""
          for i = 1, #segment do
            hex = hex .. string.format("%02x ", segment:byte(i))
          end
          print("[speedwalk] DEBUG: parse failed for '" .. segment .. "' len=" .. #segment .. " hex=[" .. hex .. "]" .. (err and (": " .. err) or ""))
        end
        cmds = {segment}
      end
      table.insert(result, {
        raw = segment,
        commands = cmds,
      })
    end
  end
  return result
end

-- Load step-list for current place
-- Returns true if current place has steps configured
function M.load_steps()
  -- Reset frame arena before parsing steps (in case it's been filled by other operations)
  lera.frame_reset()

  step_list = {}
  step_targets = ""
  step_index = 0

  if not current_place then
    print("[speedwalk] load_steps: no current_place set")
    return false
  end

  local data = place_data[current_place]
  if not data then
    print("[speedwalk] load_steps: no place_data for '" .. current_place .. "'")
    -- Debug: show available places
    local places = {}
    for k, _ in pairs(place_data) do
      table.insert(places, k)
    end
    print("[speedwalk] available places: " .. table.concat(places, ", "))
    return false
  end

  if not data.steps or data.steps == "" then
    print("[speedwalk] load_steps: place '" .. current_place .. "' has no steps")
    return false
  end

  step_list = parse_steps(data.steps)
  step_targets = data.targets or ""

  -- Debug: show last step's commands
  if #step_list > 0 then
    local last = step_list[#step_list]
    print("[speedwalk] load_steps: loaded " .. #step_list .. " steps for '" .. current_place ..
          "' (last step '" .. last.raw .. "' -> " .. #last.commands .. " cmds: " .. table.concat(last.commands, ",") .. ")")
  else
    print("[speedwalk] load_steps: loaded 0 steps for '" .. current_place .. "'")
  end
  return #step_list > 0
end

-- Get the next step without advancing
-- Returns: step table {raw=, commands=} or nil if no more steps
function M.peek_step()
  local next_idx = step_index + 1
  if next_idx > #step_list then
    return nil
  end
  return step_list[next_idx]
end

-- Snapshot upcoming parsed commands without advancing or wrapping the route.
-- A step-list entry can contain several commands (e.g. 2n or (enter portal)).
function M.upcoming_steps(limit)
  limit = math.max(0, math.floor(tonumber(limit) or 5))
  local result = {}
  for i = step_index + 1, #step_list do
    for _, cmd in ipairs(step_list[i].commands) do
      if #result >= limit then return result end
      result[#result + 1] = cmd
    end
  end
  return result
end

-- Advance to next step and return it
-- Returns: step table {raw=, commands=} or nil if no more steps
function M.take_step()
  step_index = step_index + 1
  if step_index > #step_list then
    step_index = 0  -- Loop back to start
    return nil
  end
  return step_list[step_index]
end

-- Get current step (last taken)
-- Returns: step table {raw=, commands=} or nil
function M.current_step()
  if step_index < 1 or step_index > #step_list then
    return nil
  end
  return step_list[step_index]
end

-- Reset step-list to beginning
function M.reset_steps()
  step_index = 0
end

-- Clear the step-list entirely
function M.clear_steps()
  step_list = {}
  step_targets = ""
  step_index = 0
end

-- Get step-list info
function M.step_info()
  return {
    place = current_place,
    total = #step_list,
    current = step_index,
    remaining = #step_list - step_index,
    done = step_index >= #step_list,
    targets = step_targets,
  }
end

-- Find the first target keyword (in its authored case) that appears in a
-- monster's display name, case-insensitively. Returns nil when nothing
-- matches, including for a non-string/nil argument.
function M.match_target(monster_name)
  if type(monster_name) ~= "string" then return nil end
  if step_targets == "" then return nil end

  local monster_lower = monster_name:lower()
  for target in step_targets:gmatch("[^,]+") do
    local trimmed = target:match("^%s*(.-)%s*$")
    local trimmed_lower = trimmed:lower()
    if trimmed_lower ~= "" and monster_lower:find(trimmed_lower, 1, true) then
      return trimmed
    end
  end

  return nil
end

-- Check if a monster is in the current place's target list
function M.is_valid_target(monster_name)
  return M.match_target(monster_name) ~= nil
end

-- Get all targets for the current place
function M.get_targets()
  if step_targets == "" then return {} end

  local result = {}
  for target in step_targets:gmatch("[^,]+") do
    target = target:match("^%s*(.-)%s*$")
    if target ~= "" then
      table.insert(result, target)
    end
  end
  return result
end

-- Check if current place has steps configured
function M.has_steps()
  if not current_place then return false end
  local data = place_data[current_place]
  return data and data.steps and data.steps ~= ""
end

return M
