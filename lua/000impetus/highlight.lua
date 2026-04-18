local M = {}

local function hi(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

local palette = {
  keyword = "#ff00ff",
  control_start = "#00d7ff",
  control_mid = "#ffd166",
  control_end = "#ff6b6b",
  directive = "#00d7ff",
  param = "#4cff7a",
  repeat_var = "#ffffff",
  number = "#ff3030",
  comment = "#a8a8a8",
  string = "#9a9a9a",
  header = "#00ffff",
  options = "#00c86f",
  default = "#00c86f",
  field = "#ffffff",
  intrinsic_func = "#ffd166",
  intrinsic_var = "#7ee8ff",
  intrinsic_symbol = "#ff9f43",
  divider = "#d7d7d7",
  example = "#c0c0c0",
  empty_field_bg = "#2b3f78",
  active_param_bg = "#fff200",
  active_param_fg = "#000000",
  folded_fg = "#ff8ae2",
  folded_bg = "#162033",
  folded_keyword_fg = "#ff8ae2",
  folded_keyword_count = "#ffd6f4",
  folded_control_fg = "#7ee8ff",
  folded_control_count = "#c7f6ff",
  info_stripe = "#101a2a",
  info_stats = "#6f7782",
  info_stat_label = "#59636f",
  info_header = "#6fe3c1",
  info_section = "#79c2a6",
  info_branch = "#00ff00",
  info_file = "#d7dde6",
  info_keyword = "#a9bdf5",
  info_param = "#ffca85",
  info_number = "#ff5f5f",
  info_divider = "#4f5f73",
}

local pair_palette = {
  "#ff6b6b", "#ffd166", "#06d6a0", "#4cc9f0", "#f72585", "#b8f35d",
  "#f4a261", "#9b5de5", "#00f5d4", "#f15bb5", "#fee440", "#00bbf9",
  "#e76f51", "#90be6d", "#43aa8b", "#577590", "#ff8fab", "#7bdff2",
  "#c77dff", "#ffb703", "#80ed99", "#48cae4", "#ff9770", "#a0c4ff",
}

function M.apply()
  hi("impetusKeyword", { fg = palette.keyword, bold = true })
  hi("impetusControlStart", { fg = palette.control_start, bold = true })
  hi("impetusControlMid", { fg = palette.control_mid, bold = true, italic = true })
  hi("impetusControlEnd", { fg = palette.control_end, bold = true })
  hi("impetusDirective", { fg = palette.directive, bold = true })
  hi("impetusParam", { fg = palette.param })
  hi("impetusRepeatVar", { fg = palette.repeat_var, bold = true })
  hi("impetusNumber", { fg = palette.number })
  hi("impetusComment", { fg = palette.comment, italic = true })
  hi("impetusString", { fg = palette.string })
  hi("impetusHeader", { fg = palette.header, bold = true })
  hi("impetusOptions", { fg = palette.options, italic = true, bold = true })
  hi("impetusDefault", { fg = palette.default, italic = true, bold = true })
  hi("impetusFieldName", { fg = palette.field })
  hi("impetusIntrinsicFunction", { fg = palette.intrinsic_func, bold = true })
  hi("impetusIntrinsicVariable", { fg = palette.intrinsic_var })
  hi("impetusIntrinsicSymbol", { fg = palette.intrinsic_symbol, bold = true })
  hi("impetusDivider", { fg = palette.divider })
  hi("impetusExample", { fg = palette.example })
  hi("impetusEmptyField", { bg = palette.empty_field_bg, fg = "NONE" })
  hi("impetusHelpActiveParam", { bg = palette.active_param_bg, fg = palette.active_param_fg, bold = true })
  hi("impetusHelpActiveLine", { bg = palette.active_param_bg, fg = palette.active_param_fg, bold = true })
  hi("impetusDirectivePairMark", { fg = "#cfd8e3", bold = true })
  hi("impetusDirectivePairActiveMark", { fg = "#fff200", bold = true, underline = true })
  for idx, color in ipairs(pair_palette) do
    hi(("impetusDirectivePairMark%d"):format(idx), { fg = color, bold = true })
    hi(("impetusDirectivePairActiveMark%d"):format(idx), { fg = color, bold = true, underline = true })
  end

  hi("Folded", { fg = palette.folded_fg, bg = palette.folded_bg, bold = true })
  hi("impetusFoldKeyword", { fg = palette.folded_keyword_fg, bg = palette.folded_bg, bold = true })
  hi("impetusFoldKeywordCount", { fg = palette.folded_keyword_count, bg = palette.folded_bg, bold = true })
  hi("impetusFoldControl", { fg = palette.folded_control_fg, bg = palette.folded_bg, bold = true })
  hi("impetusFoldControlCount", { fg = palette.folded_control_count, bg = palette.folded_bg, bold = true })
  hi("impetusFoldedKeywordLine", { fg = palette.folded_keyword_fg, bg = palette.folded_bg, bold = true })
  hi("impetusFoldedControlLine", { fg = palette.folded_control_fg, bg = palette.folded_bg, bold = true })

  hi("impetusInfoStripe", { bg = palette.info_stripe })
  hi("impetusInfoStats", { fg = palette.info_stats })
  hi("impetusInfoStatLabel", { fg = palette.info_stat_label })
  hi("impetusInfoHeader", { fg = palette.info_header, bold = true })
  hi("impetusInfoSection", { fg = palette.info_section, bold = true })
  hi("impetusInfoFile", { fg = palette.info_file, bold = true })
  hi("impetusInfoKeyword", { fg = palette.info_keyword, bold = true })
  hi("impetusInfoParam", { fg = palette.info_param })
  hi("impetusInfoNumber", { fg = palette.info_number })
  hi("impetusInfoDivider", { fg = palette.info_divider })
  hi("impetusInfoBranch", { fg = palette.info_branch, bold = true })

  hi("ImpetusFileTreeHover", { fg = palette.info_file, bg = "#2a4a7a", bold = true })
  hi("ImpetusFileTreeArrow", { fg = "#ff3030", bold = true })
  hi("ImpetusInfoSelected", { bg = "#ffff00", fg = "#000000", bold = true })
end

return M
