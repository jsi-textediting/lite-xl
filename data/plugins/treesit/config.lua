local common = require 'core.common'
local config = require 'core.config'

local defaults = {
  enabled            = true,
  useFallbackColors  = true,
  warnFallbackColors = false,
  maxParseTime       = 2000,
  -- Files with more lines than this keep the built-in highlighter.
  maxLines           = 50000,
  -- Extra locations searched before the grammars/queries bundled with the editor.
  parserDirs         = {},
  queryDirs          = {},
}

local spec = {
  name = 'Treesit',
  {
    label       = 'Enabled',
    description = 'Use tree-sitter for syntax highlighting when a grammar is available',
    path        = 'enabled',
    type        = 'toggle',
  },
  {
    label       = 'Use fallback colors',
    description = 'Set fallbacks for missing colors',
    path        = 'useFallbackColors',
    type        = 'toggle',
  },
  {
    label       = 'Warn fallback colors',
    description = 'Warn when fallback colors are used',
    path        = 'warnFallbackColors',
    type        = 'toggle',
  },
  {
    label       = 'The below options are meant for advanced use only.',
    path        = '',
    type        = 'button',
    icon        = '!',
  },
  {
    label       = 'Maximum parse time',
    description = 'Maximum time spent parsing before deferring it (in µs). Set this to 0 to disable deferring',
    path        = 'maxParseTime',
    type        = 'number',
    min         = 0,
    step        = 1,
  },
  {
    label       = 'Maximum lines',
    description = 'Documents with more lines than this use the built-in highlighter',
    path        = 'maxLines',
    type        = 'number',
    min         = 0,
    step        = 1000,
  },
}

for _, option in ipairs(spec) do
  option.default = defaults[option.path]
end

defaults.config_spec    = spec
config.plugins.treesit  = common.merge(defaults, config.plugins.treesit)

return config.plugins.treesit
