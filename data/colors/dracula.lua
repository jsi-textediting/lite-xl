local style = require "core.style"
local common = require "core.common"

-- Backgrounds
style.background = { common.color "#282a36" }  -- Docview
style.background2 = { common.color "#21222c" } -- Treeview
style.background3 = { common.color "#1e1f29" } -- Command view / Status bar

-- UI Elements
style.text = { common.color "#f8f8f2" }
style.caret = { common.color "#f8f8f0" }
style.accent = { common.color "#8be9fd" }
style.dim = { common.color "#6272a4" }
style.divider = { common.color "#191a21" }
style.selection = { common.color "#44475a" }
style.line_number = { common.color "#6272a4" }
style.line_number2 = { common.color "#f8f8f2" } -- With cursor
style.line_highlight = { common.color "#343746" }
style.scrollbar = { common.color "#44475a" }
style.scrollbar2 = { common.color "#ff79c6" }   -- Hovered
style.scrollbar_track = { common.color "#1e1f29" }

-- Alerts and Overlays
style.nagbar = { common.color "#ff5555" }
style.nagbar_text = { common.color "#f8f8f2" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(255, 255, 255, 0.1)" }
style.drag_overlay_tab = { common.color "#bd93f9" }

-- Status / Git
style.good = { common.color "#50fa7b" }
style.warn = { common.color "#ffb86c" }
style.error = { common.color "#ff5555" }
style.modified = { common.color "#8be9fd" }

-- Plugin Specific Styles
style.guide = { common.color "#44475a80" }
style.guide_highlight = { common.color "#6272a4" }
style.bracketmatch_color = { common.color "#bd93f9" }

-- Syntax Highlighting
style.syntax["normal"] = { common.color "#f8f8f2" }
style.syntax["symbol"] = { common.color "#f8f8f2" }
style.syntax["comment"] = { common.color "#6272a4" }
style.syntax["keyword"] = { common.color "#ff79c6" }  -- local, function, end, if, return
style.syntax["keyword2"] = { common.color "#8be9fd" } -- self, types, classes (int, float, etc.)
style.syntax["number"] = { common.color "#bd93f9" }
style.syntax["literal"] = { common.color "#ffb86c" }  -- true, false, nil, constants
style.syntax["string"] = { common.color "#f1fa8c" }
style.syntax["operator"] = { common.color "#ff79c6" } -- = + - / < >
style.syntax["function"] = { common.color "#50fa7b" }

-- Diff Highlighting
style.syntax["diff_add"] = { common.color "#50fa7b" }
style.syntax["diff_del"] = { common.color "#ff5555" }
style.syntax["diff_change"] = { common.color "#ffb86c" }

-- Rainbow Parentheses
style.syntax.paren1 = { common.color "#ff79c6" }
style.syntax.paren2 = { common.color "#bd93f9" }
style.syntax.paren3 = { common.color "#8be9fd" }
style.syntax.paren4 = { common.color "#50fa7b" }
style.syntax.paren5 = { common.color "#ffb86c" }
style.syntax.paren6 = { common.color "#f1fa8c" }

-- Linter / Diagnostics
style.lint = style.lint or {}
style.lint.info = { common.color "#8be9fd" }
style.lint.hint = { common.color "#50fa7b" }
style.lint.warning = { common.color "#ffb86c" }
style.lint.error = { common.color "#ff5555" }

-- Tree-sitter Token Highlighting
style.syntax["punctuation"] = { common.color "#f8f8f2" }
style.syntax["punctuation.bracket"] = { common.color "#f8f8f2" }
style.syntax["punctuation.delimiter"] = { common.color "#f8f8f2" }
style.syntax["punctuation.special"] = { common.color "#ff79c6" }
style.syntax["variable"] = { common.color "#f8f8f2" }
style.syntax["variable.builtin"] = { common.color "#bd93f9" }
style.syntax["variable.parameter"] = { common.color "#ffb86c" }
style.syntax["variable.member"] = { common.color "#f8f8f2" }
style.syntax["type"] = { common.color "#8be9fd" }
style.syntax["type.builtin"] = { common.color "#8be9fd" }
style.syntax["constructor"] = { common.color "#8be9fd" }
style.syntax["property"] = { common.color "#f8f8f2" }
style.syntax["constant"] = { common.color "#bd93f9" }
style.syntax["constant.builtin"] = { common.color "#bd93f9" }
style.syntax["tag"] = { common.color "#ff79c6" }
style.syntax["tag.attribute"] = { common.color "#50fa7b" }
style.syntax["tag.delimiter"] = { common.color "#f8f8f2" }

-- Log Console Icons/Colors
style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
