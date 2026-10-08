local core = require 'core'
local style = require 'core.style'

local config = require 'plugins.treesit.config'

local fallbackMap = {
  ['normal'] = {
    'punctuation.delimiter',
    ['punctuation.bracket'] = {
      'tag.delimiter',
    },
    'markup.strong',
    'markup.italic',
    'markup.strikethrough',
    'markup.underline',
    ['markup.heading'] = {
      'markup.heading.1',
      'markup.heading.2',
      'markup.heading.3',
      'markup.heading.4',
      'markup.heading.5',
      'markup.heading.6',
    },
    'markup.quote',
    'markup.math',
    ['markup.raw'] = {
      'markup.raw.block',
    },
  },
  ['symbol'] = {
    ['variable'] = {
      'variable.builtin',
      ['variable.parameter'] = {
        'variable.parameter.builtin',
      },
      ['variable.member'] = {
        'property',
        'tag.attribute',
      },
    },
    'label',
  },
  ['comment'] = {
    'string.documentation',
    'comment.documentation',
    'comment.error',
    'comment.warning',
    'comment.todo',
    'comment.note',
  },
  ['keyword'] = {
    'string.escape',
    'keyword.coroutine',
    'keyword.function',
    'keyword.import',
    'keyword.type',
    'keyword.modifier',
    'keyword.repeat',
    'keyword.return',
    'keyword.debug',
    'keyword.exception',
    'keyword.conditional',
    ['keyword.directive'] = {
      'keyword.directive.define',
    },
    'punctuation.special',
    'tag.builtin',
    'diff.minus',
  },
  ['keyword2'] = {
    ['module'] = {
      'module.builtin',
    },
    ['type'] = {
      'type.builtin',
      'type.definition',
    },
    'constructor',
  },
  ['number'] = {
    'number.float',
  },
  ['literal'] = {
    ['constant'] = {
      'constant.builtin',
      'constant.macro',
    },
    ['character'] = {
      'character.constant',
      'character.special',
    },
    'boolean',
    ['markup.list'] = {
      'markup.list.checked',
      'markup.list.unchecked',
    },
    'diff.delta',
  },
  ['string'] = {
    'string.regexp',
    ['string.special'] = {
      'string.special.symbol',
      'string.special.path',
      'string.special.url',
      ['markup.link'] = {
        'markup.link.label',
        'markup.link.url',
      },
    },
    'diff.plus',
  },
  ['operator'] = {
    'keyword.operator',
    'keyword.conditional.ternary',
  },
  ['function'] = {
    ['attribute'] = {
      'attribute.builtin',
    },
    'function.builtin',
    'function.call',
    'function.macro',
    ['function.method'] = {
      'function.method.call',
    },
    'tag',
  },
}

-- Colors set here (name -> color), so they can be dropped when the theme changes.
local fallbacksSet = {}

local function setFallback(name, colour, missing)
  if not style.syntax[name] then
    style.syntax[name] = colour
    if colour ~= nil then fallbacksSet[name] = colour end
    missing[#missing + 1] = name
  end
end

local function setFallbacks(fallbackMap, colour, missing)
  missing = missing or {}

  if not config.useFallbackColors then return {} end

  for k, v in pairs(fallbackMap) do
    if type(k) == 'string' then
      setFallback(k, colour, missing)
      setFallbacks(v, style.syntax[k], missing)
    else
      setFallback(v, colour, missing)
    end
  end

  return missing
end

-- Drop our fallbacks (not the colors other plugins added to style.syntax), so
-- that they are derived again from the new theme.
local function clearFallbacks()
  for name, colour in pairs(fallbacksSet) do
    if style.syntax[name] == colour then style.syntax[name] = nil end
  end
  fallbacksSet = {}
end

local function refreshSyntaxColors()
  local missing = setFallbacks(fallbackMap)

  if config.warnFallbackColors and #missing > 0 then
    table.sort(missing)

    core.warn(string.format(
      'Fallbacks were used for %d colors for Treesit highlighting.\n\z
      Disable this message by setting the warnFallbackColors option \z
      in the module plugins.treesit.config to false, \z
      or by specifying all the following syntax colors: \n\t%s',
      #missing, table.concat(missing, '\n\t')
    ))
  end
end

-- Syntax colors the last theme changed (name -> { new, old }): the next theme
-- starts from what was there before, so it does not inherit colors it does
-- not define.
local themeSet = {}

local oldReloadModule = core.reload_module
function core.reload_module(name)
  if name:find('colors.', 1, true) then
    clearFallbacks()
    for k, c in pairs(themeSet) do
      if style.syntax[k] == c.new then style.syntax[k] = c.old end
    end
    local before = {}
    for k, v in pairs(style.syntax) do before[k] = v end
    oldReloadModule(name)
    themeSet = {}
    for k, v in pairs(style.syntax) do
      if before[k] ~= v then themeSet[k] = { new = v, old = before[k] } end
    end
    refreshSyntaxColors(fallbackMap)
  else
    oldReloadModule(name)
  end
end

core.add_thread(refreshSyntaxColors)
