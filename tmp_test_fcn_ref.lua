vim.opt.rtp:prepend('.')
local analysis = require('impetus.analysis')

local lines = {
  "*FUNCTION",
  '"Velocity - X"',
  "1102",
  "table(1, max(1,fcn(1001)), 3)",
  "*FUNCTION",
  "1001",
  "H(t - %tend)",
}

vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
local idx = analysis.build_buffer_index(0)

print("object_defs curve:")
for k, v in pairs(idx.object_defs.curve or {}) do
  print("  " .. k .. " => row " .. v.row .. " col " .. v.col)
end

print("object_refs curve:")
for k, v in pairs(idx.object_refs.curve or {}) do
  print("  " .. k .. " => #refs " .. #v)
  for _, r in ipairs(v) do
    print("    row " .. r.row .. " col " .. r.col .. " line: " .. r.line)
  end
end
