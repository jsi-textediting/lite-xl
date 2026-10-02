local languages = require 'plugins.treesit.languages'

-- Languages known to the plugin. A language is highlighted with tree-sitter
-- only when its grammar and highlights query can be found (see util.lua);
-- otherwise the built-in syntax definition keeps being used.
local builtin = {
  { 'c',               { '%.c$', '%.h$' } },
  { 'cpp',             { '%.cpp$', '%.cxx$', '%.cc$', '%.hpp$', '%.hh$', '%.hxx$' } },
  { 'lua',             { '%.lua$' } },
  { 'python',          { '%.py$', '%.pyw$' } },
  { 'javascript',      { '%.js$', '%.jsx$', '%.mjs$', '%.cjs$' } },
  { 'typescript',      { '%.ts$' } },
  { 'tsx',             { '%.tsx$' } },
  { 'rust',            { '%.rs$' } },
  { 'go',              { '%.go$' } },
  { 'json',            { '%.json$', '%.cjson$', '%.jsonc$', '%.json5$', '%.ipynb$' } },
  { 'markdown',        { '%.md$', '%.markdown$' } },
  { 'markdown_inline', {} }, -- injected by markdown, no direct files
  { 'bash',            { '%.sh$', '%.bash$', '%.zsh$', '^%.bashrc$', '[/\\]%.bashrc$',
                         '^%.zshrc$', '[/\\]%.zshrc$', '^%.profile$', '[/\\]%.profile$' } },
  { 'query',           { '%.scm$' } },
  { 'vim',             { '%.vim$', '%.vimrc$' } },
  { 'vimdoc',          { '[/\\]doc[/\\].*%.txt$', '^doc[/\\].*%.txt$' } },
  { 'cmake',           { '%.cmake$', '%.cmake%.in$', '^[Cc][Mm]ake[Ll]ists%.txt$', '[/\\][Cc][Mm]ake[Ll]ists%.txt$' } },
  { 'objc',            { '%.m$' } },
  { 'objcpp',          { '%.mm$' } },
  { 'make',            { '^[Mm]akefile$', '^GNUmakefile$', '[/\\][Mm]akefile$', '[/\\]GNUmakefile$', '%.mk$', '%.mak$' } },
  { 'java',            { '%.java$' } },
  { 'kotlin',          { '%.kt$', '%.kts$' } },
  { 'dockerfile',      { '^[Dd]ockerfile.*', '[/\\][Dd]ockerfile.*', '%.dockerfile$' } },
  { 'c_sharp',         { '%.cs$' } },
  { 'powershell',      { '%.ps1$', '%.psm1$', '%.psd1$' } },
  { 'diff',            { '%.diff$', '%.patch$', '%.rej$' } },
  { 'ini',             { '%.ini$', '%.inf$', '%.cfg$', '%.conf$', '^%.editorconfig$', '[/\\]%.editorconfig$' } },
  { 'php',             { '%.php$', '%.phtml$' } },
  { 'ruby',            { '%.rb$', '^Rakefile$', '[/\\]Rakefile$', '^Gemfile$', '[/\\]Gemfile$', '%.gemspec$' } },
  { 'sql',             { '%.sql$', '%.psql$', '%.pgsql$' } },
  { 'zig',             { '%.zig$', '%.zon$' } },
  { 'swift',           { '%.swift$' } },
  { 'html',            { '%.html$', '%.htm$' } },
  { 'css',             { '%.css$' } },
  { 'yaml',            { '%.yaml$', '%.yml$' } },
  { 'toml',            { '%.toml$' } },
}

local function register()
  for _, entry in ipairs(builtin) do
    if not languages.defs[entry[1]] then
      languages.addLang { name = entry[1], files = entry[2] }
    end
  end
end

return register
