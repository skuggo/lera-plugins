-- Plain-text map details. Reserve the largest cell's wrapped height so PNG
-- fitting/hit-testing cannot move the grid when the pointer changes cells.
local M = {}
function M.wrap(text, width)
  width = math.max(1, math.floor(tonumber(width) or 1))
  local lines, line, used = {}, "", 0
  for word in tostring(text or ""):gmatch("%S+") do
    local chars = {}
    for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      chars[#chars + 1] = ch
    end
    if used > 0 and used + 1 + #chars > width then
      lines[#lines + 1], line, used = line, "", 0
    end
    if used > 0 then line, used = line .. " ", used + 1 end
    for _, ch in ipairs(chars) do
      if used == width then lines[#lines + 1], line, used = line, "", 0 end
      line, used = line .. ch, used + 1
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end
function M.append_grid(out, text, width, cols, rows, tip)
  local lines = M.wrap(text, width)
  local count = math.max(1, #lines)
  for r = 0, rows - 1 do
    for c = 0, cols - 1 do count = math.max(count, #M.wrap(tip(c, r), width)) end
  end
  for i = 1, count do out[#out + 1] = lines[i] or "" end
end
return M
