# use-package

Declarative plugin management for [Lite-XL](https://lite-xl.com), inspired by Emacs
[`use-package`](https://github.com/jwiegley/use-package).

Plugins are declared once in your config. Running the `use-package:install` command
clones or copies everything that is missing; running `use-package:update` refreshes
what is already installed. No manual file juggling required.

---

## Bootstrap

`use_package` must be the **first** plugin loaded so that every subsequent `up.use`
call is registered before Lite-XL auto-loads other plugins.

Place the following at the top of `~/.config/lite-xl/init.lua` (or whichever config
file runs first):

```lua
local up = require 'plugins.use_package'
```

All calls to `up.repos{}` and `up.use()` must appear after this line.

---

## Startup Options

`use_package` can automatically install missing plugins and pull updates on startup in the background without blocking the editor:

| Option | Type | Default | Description |
|---|---|---|---|
| `auto_install` | boolean | `false` | Automatically install any declared plugins that are missing on startup. |
| `auto_update` | boolean | `false` | Automatically pull updates for installed plugins (and `use_package` itself) from registered repositories and git remotes on startup. **Runs unpinned, unreviewed upstream code**; pin repos to a tag (`url:tag`) if that is a concern. |

Configure these options in `init.lua` using any of the following methods:

```lua
local up = require 'plugins.use_package'

-- Method 1: standard Lite-XL config table
local config = require 'core.config'
config.plugins.use_package.auto_install = true
config.plugins.use_package.auto_update  = true

-- Method 2: up.setup
up.setup {
  auto_install = true,
  auto_update  = true,
}

-- Method 3: direct property assignment
up.auto_install = true
up.auto_update  = true
```

---

## `up.repos(list)`

Register one or more multi-plugin repository URLs or local directory paths. Each entry
is a string of the form `"url:branch-or-tag"`, `"url"`, or a local filesystem path like
`"~/Work/github/lite-xl-plugins"`. Remote repos are cloned (once) when `use-package:install`
is run and their `manifest.json` is cached locally. Local repository manifests are loaded
directly from disk. Plugins searched by plain name (install method `repo`) are looked up
in these manifests.

```lua
up.repos {
  'https://github.com/lite-xl/lite-xl-plugins.git:master',
  '~/Work/github/lite-xl-plugins',
  'https://github.com/my-org/private-plugins.git:main',
}
```

`up.repos{}` must be called **before** any `up.use()` calls that refer to plugins
found in those repos.

---

## `up.use(plugin [, opts])`

Declare a plugin. `plugin` is a string identifying the plugin; `opts` is an optional
table of additional settings.

```lua
up.use(plugin_string)
up.use(plugin_string, opts)
up.use({ plugin = plugin_string, ... })   -- table form, all keys inline
```

### `plugin` string formats

| Format | Install method | Example |
|---|---|---|
| `"Author/Repo"` | **git** — cloned from GitHub | `"Evergreen-lxl/Evergreen.lxl"` |
| Plain name | **repo** — searched in registered manifests | `"editorconfig"` |
| Local path (`~/`, `/`, `./`, `C:\`) | **local** — copied into plugins dir | `"~/projects/myplugin"` |

### `opts` keys

| Key | Type | Description |
|---|---|---|
| `name` | string | Override the installed directory/file name. Defaults to the plugin's basename with `.lxl` stripped and `lite-xl-` prefix removed. |
| `repo` | string | Pin lookup to a specific registered repo URL (repo install method only). |
| `dependencies` | table | List of plugin specs to install before this one. Each entry may be a plain name string or a full spec table. |
| `run` | string | Shell command executed inside the installed plugin directory after a successful install (e.g. to compile native libraries). |
| `enabled` | boolean | Set to `false` to disable the plugin (default: `true`). Sets `config.plugins[name] = false` to prevent Lite-XL from loading it and unlinks the plugin files. |
| `disabled` | boolean | Alternative to `enabled = false`. |
| `config` | function | Runs after all plugins have loaded. Use to set `config.plugins.*` options. |
| `bind` | table | Keybindings registered after load. Map of `{ ["key-combo"] = "command:name" }`. |

### Disabling a plugin

```lua
-- Disable a declared plugin:
up.use('whichkey', { enabled = false })

-- Or using the shortcut:
up.disable 'whichkey'
```

---

## Config samples

### Git install — single GitHub repo cloned as a plugin directory

```lua
-- Clones https://github.com/Evergreen-lxl/Evergreen.lxl into plugins/evergreen/
up.use 'Evergreen-lxl/Evergreen.lxl'
```

### Repo install — plain name looked up in a registered manifest

```lua
up.repos {
  'https://github.com/lite-xl/lite-xl-plugins.git:master',
}

up.use 'editorconfig'
up.use 'cleanstart'
up.use 'indentguide'
```

### Local install — copy from a dotfile or local path

```lua
-- Copies ~/dotfiles/lite-xl/plugins/myplugin into USERDIR/plugins/myplugin
up.use '~/dotfiles/lite-xl/plugins/myplugin'

-- Override the installed name
up.use('~/dotfiles/lite-xl/plugins/myplugin.lua', { name = 'myplugin.lua' })
```

### Plugin with `:config` and `:bind`

```lua
up.use('indentguide', {
  config = function()
    config.plugins.indentguide = {
      enabled      = true,
      highlight_current = true,
    }
  end,
})

up.use('some-plugin', {
  bind = {
    ['ctrl+shift+p'] = 'some-plugin:open-panel',
  },
})
```

### Plugin with dependencies and a post-install build step

```lua
up.use('native-plugin', {
  dependencies = { 'widget' },
  run = 'make',
})
```

### Pin a repo install to a specific registered source

```lua
up.repos {
  'https://github.com/lite-xl/lite-xl-plugins.git:master',
  'https://github.com/my-org/forks.git:main',
}

-- Force lookup in the fork repo only
up.use('editorconfig', {
  repo = 'https://github.com/my-org/forks.git:main',
})
```

### Full example init.lua

```lua
local up = require 'plugins.use_package'   -- must be first

up.repos {
  'https://github.com/lite-xl/lite-xl-plugins.git:master',
}

-- GitHub repos
up.use 'Evergreen-lxl/Evergreen.lxl'
up.use 'lite-xl/lite-xl-lsp'

-- Manifest plugins with config
up.use('indentguide', {
  config = function()
    config.plugins.indentguide = { enabled = true }
  end,
})

up.use 'editorconfig'
up.use 'cleanstart'

-- Local plugin from dotfile
up.use '~/dotfiles/lite-xl/myplugin.lua'
```

---

## Commands

Run these from the command palette (`ctrl+shift+p`):

| Command | Action |
|---|---|
| `use-package:install` | Clone/download any registered repos, then install all declared plugins that are not yet present. Already-installed plugins are updated. |
| `use-package:update` | Update all installed plugins (git pull / re-copy from repo). Installs any that are missing. |
| `use-package:reinstall` | Remove and reinstall all tracked non-local plugins. |
| `use-package:disable-plugin` | Interactive picker to disable an installed plugin (sets `config.plugins[name] = false` and removes symlink). |
| `use-package:enable-plugin` | Interactive picker to enable and install an addon from registered repos. |
| `use-package:toggle-plugin` | Interactive picker to toggle the enabled/disabled status of a plugin. |

---

## manifest.json format

A multi-plugin repository must contain a `manifest.json` at its root. The file is a
JSON object with a single `"addons"` array. Each element describes one installable
addon.

### Top-level structure

```json
{
  "addons": [ ... ]
}
```

### Addon object fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Unique addon identifier. This is the name you pass to `up.use`. |
| `version` | string | yes | Semver or free-form version string. |
| `mod_version` | string | yes | Minimum Lite-XL mod-version the addon requires (e.g. `"3"`). |
| `description` | string | no | Human-readable description shown in logs. |
| `path` | string | no | Path to the plugin file or directory **relative to the repo root**. If omitted, the entire repo root is used as the source. |
| `type` | string | no | `"plugin"` (default), `"library"`, or `"meta"`. Libraries are installed into `USERDIR/libraries/` instead of `USERDIR/plugins/`. `meta` addons are skipped by use-package. |
| `remote` | string | no | URL of a separate git repository that contains this addon (format: `"url:commit-or-tag"`). use-package clones this sub-repo and re-searches it when the addon is requested. |
| `dependencies` | object | no | Map of addon IDs this addon depends on. Keys are addon IDs; values are constraint objects (may be empty `{}`). use-package does not currently resolve these automatically — declare them explicitly with the `dependencies` opt in `up.use`. |

### Minimal addon entry

```json
{
  "id": "cleanstart",
  "version": "0.1",
  "mod_version": "3",
  "path": "plugins/cleanstart.lua"
}
```

### Directory-based plugin

```json
{
  "id": "editorconfig",
  "version": "0.1",
  "mod_version": "3",
  "path": "plugins/editorconfig"
}
```

The directory is copied recursively into `USERDIR/plugins/editorconfig/`. Lite-XL
loads it as `require 'plugins.editorconfig'` → `plugins/editorconfig/init.lua`.

### Library (installed to `libraries/`)

```json
{
  "id": "widget",
  "version": "0.1",
  "mod_version": "3",
  "type": "library",
  "remote": "https://github.com/lite-xl/lite-xl-widgets:v0.1"
}
```

### Plugin with sub-repo (`remote`)

When a `remote` field is present, use-package clones that repository separately and
searches its own `manifest.json` for the addon:

```json
{
  "id": "lsp",
  "version": "1.0",
  "mod_version": "3",
  "remote": "https://github.com/lite-xl/lite-xl-lsp:main"
}
```

### Meta addon (skipped by use-package)

```json
{
  "id": "meta_colors",
  "version": "0.1",
  "mod_version": "3",
  "type": "meta",
  "dependencies": { "dracula": {}, "nord": {}, "onedark": {} }
}
```

---

## Store file

use-package persists install state to:

```
USERDIR/.use-package-store
```

This is a Lua file (loaded with `dofile`) containing a serialized table with two
sections:

- `plugins` — map of plugin identifier → spec table, including `fullyInstalled`,
  `installMethod`, and `repo_hex` (hex-encoded repo URL used during install).
- `repos` — map of hex-encoded repo URL → `{ manifest_json = "..." }` (raw cached
  JSON so manifests survive restarts without a network call).

The store is written automatically after every install, update, or remove. You can
delete it to reset all tracking state; the next `use-package:install` will reinstall
everything from scratch.
