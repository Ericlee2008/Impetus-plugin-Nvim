local json = vim.fn.json_decode(vim.fn.readfile("data/keywords.json"))
for k, v in pairs(json) do
  if k:match("GEOMETRY_SEED") then
    print("KEY: " .. k)
    if v.signature_rows then
      for i, row in ipairs(v.signature_rows) do
        print("  sig row " .. i .. ": " .. table.concat(row, ", "))
      end
    end
  end
  if k:match("SET_NODE") then
    print("KEY: " .. k)
    if v.signature_rows then
      for i, row in ipairs(v.signature_rows) do
        print("  sig row " .. i .. ": " .. table.concat(row, ", "))
      end
    end
  end
end
os.exit(0)
