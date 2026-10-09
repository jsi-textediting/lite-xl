# Lite XL

[![CI]](https://github.com/lite-xl/lite-xl/actions/workflows/build.yml)
[![Discord Badge Image]](https://discord.gg/UQKnzBhY5H)

![screenshot-dark]

A lightweight text editor written in Lua, adapted from [lite].

* **[Get Lite XL]** — Download for Windows, Linux and Mac OS.
* **[Get plugins]** — Add additional functionality, adapted for Lite XL.
* **[Get color themes]** — Add additional colors themes.

Please refer to our [website] for the user and developer documentation,
including [build] instructions details. A quick build guide is described below.

Lite XL has support for high DPI display on Windows and Linux and,
since 1.16.7 release, it supports **retina displays** on macOS.

Please note that Lite XL is compatible with lite for most plugins and all color themes.
We provide a separate lite-xl-plugins repository for Lite XL, because in some cases
some adaptations may be needed to make them work better with Lite XL.
The repository with modified plugins is https://github.com/lite-xl/lite-xl-plugins.

The changes and differences between Lite XL and rxi/lite are listed in the
[changelog].

## Overview

Lite XL is derived from [lite].
It is a lightweight text editor written mostly in Lua — it aims to provide
something practical, pretty, *small* and fast easy to modify and extend,
or to use without doing either.

The aim of Lite XL compared to lite is to be more user friendly,
improve the quality of font rendering, and reduce CPU usage.

## Changes and Enhancements Compared to Upstream

This fork ([stonewell/lite-xl](https://github.com/stonewell/lite-xl)) tracks
[lite-xl/lite-xl](https://github.com/lite-xl/lite-xl) and adds the following.

### Large files

* A native C **piece-tree buffer** (`src/api/buffer.c`) backs documents that
  exceed `config.large_file_threshold_mb` (10 MB) or `config.large_file_max_lines`
  (50000 lines). Set `config.use_piece_tree = true` to use it for every file.
  Large files open fast, edit cheaply and scroll without lag.
* The tokenizer and highlighter are incremental, cap the tokenized line length
  (`config.max_line_length_tokens`) and bound their cache
  (`config.highlighter_cache_size`).
* Line wrapping is not enabled on large files, and the `linewrapping` plugin
  gained an option for the maximum line count.
* Buffer allocation checks, safer saving, and fixes for empty files and for
  removals that span several pieces.

### Remote editing

* **`thither` remote editing**: remote editing is supported via the [`thither` project](https://github.com/jsi-textediting/thither), a standalone, single-file server speaking a framed msgpack protocol over ssh stdio (file system, process execution, directory watching and large-file operations).
* The `thither` plugin (`data/plugins/thither/`, a VFS layer) makes a remote directory behave like a
  local project: tree view, find file, project search, highlighting and plugins
  keep working. Multi-GB remote files are edited lazily without a full download.
* Transport via `ssh` (POSIX) or PuTTY `plink`/Pageant (Windows). Start with the
  **thither:open-project** command and enter `host:/path`.
* Docs: [data/plugins/thither/README.md](data/plugins/thither/README.md) and the [thither repository](https://github.com/jsi-textediting/thither). Tests live in
  `tests/remote_client` and `tests/buffer_remote`.

### Syntax highlighting

* **Tree-sitter** support, bundled as a core plugin (`data/plugins/treesit`) with
  nvim-treesitter highlight queries, lazy language loading and grammar fallbacks.
  The library and grammars are built and installed with the editor
  (hash-verified, non-fatal grammar downloads).
* Many more built-in languages: C#, CMake, Dockerfile, Go, Java, Kotlin, PHP,
  PowerShell, Ruby, Rust, shell, SQL, Swift, TypeScript, Vim, YAML, Zig, JSON,
  TOML, INI, Make, batch, diff and others; the C/C++ definitions were extended.

### Plugin management

* Built-in **`use_package`** plugin (`data/plugins/use_package`): declarative,
  Emacs `use-package`-style plugin installation and updates, with optional
  `auto_install`/`auto_update` on startup, per-repository serialized updates, a
  safe store and input validation. User-configured plugins take priority when
  newer than the bundled ones. See its [README](data/plugins/use_package/README.md).
* A generated plugin C API header (`scripts/generate_plugin_api.py`).

### Rendering and platform

* Real **SDL GPU rendering** with automatic fallback to the software renderer
  (`config.force_software_renderer` to force software). The `renderer`
  build option now defaults to on. Fixes for surface/texture lifetimes, glyph atlas
  upload, text culling, and window resizing under Wayland; faster root view
  drawing.
* Dependencies upgraded: **Lua 5.5** (with the unicode patch), **SDL3**.
* Fuzzy matching in the command palette shows the best match on top.
* `dirmonitor/inotify`: fixed walking of event batches.

### Build system

* A **CMake** build (`CMakeLists.txt`, `cmake/`) with options
  `LITE_USE_SDL_RENDERER`, `LITE_PORTABLE`, `LITE_BUNDLE`, `LITE_USE_SYSTEM_LUA`,
  `LITE_BUILD_TREE_SITTER`, and `LITE_BUNDLE_TREE_SITTER_GRAMMARS`.

## Customization

Additional functionality can be added through plugins which are available in
the [plugins repository] or in the [Lite XL plugins repository].

Additional color themes can be found in the [colors repository].
These color themes are bundled with all releases of Lite XL by default.

## Quick Build Guide

To compile Lite XL yourself, you must have the following dependencies installed
via your desired package manager, or manually.

### Prerequisites

- CMake (>=3.28)
- Ninja
- SDL3, PCRE2, FreeType2, Lua 5.5 and [libeditingcore](https://github.com/jsi-textediting/libeditingcore) (downloaded and built by CMake)
- A working C compiler (GCC / Clang / MSVC)

Set `LITE_USE_SYSTEM_LUA=ON` to prefer an installed Lua over the bundled one.

> [!NOTE]
> MSVC is used in the CI, but MSVC-compiled binaries are not distributed officially
> or tested extensively for bugs.

On Linux, you may install the following dependencies for the SDL3 X11 and/or Wayland backend to work properly:

- `libX11-devel`
- `libXi-devel`
- `libXcursor-devel`
- `libxkbcommon-devel`
- `libXrandr-devel`
- `wayland-devel`
- `wayland-protocols-devel`
- `dbus-devel`
- `ibus-devel`

The following command can be used to install the dependencies in Ubuntu:

```sh
apt-get install build-essential git cmake wayland-protocols ninja-build
```

Please refer to [lite-xl-build-box] for a working Linux build environment used to package official Lite XL releases.

On macOS, you must install bash via Brew, as the default bash version on macOS is antiquated
and may not run the build script correctly.

### Building

You can use `scripts/build.sh` to set up Lite XL and build it.

```sh
$ bash build.sh --help
# Usage: scripts/build.sh <OPTIONS>
# 
# Available options:
# 
# -b --builddir DIRNAME         Sets the name of the build directory (not path).
#                               Default: 'build-x86_64-linux'.
#    --debug                    Debug this script.
# -h --help                     Show this help and exit.
# -p --prefix PREFIX            Install directory prefix. Default: '/'.
# -B --bundle                   Create an App bundle (macOS only)
# -P --portable                 Create a portable binary package.
# -m --mode MODE                Build type (plain,debug,debugoptimized,release,minsize).
#                               Default: release.
# -L --lto                      Enables Link-Time Optimization (LTO).
# -r --reconfigure              Tries to reuse the CMake build directory, if possible.
#                               Default: Deletes the build directory and recreates it.
#    --toolchain-file FILE      Cross compile with the given CMake toolchain file.
```

Alternatively, you can use the following commands to customize the build:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=<prefix>
cmake --build build
DESTDIR="$(pwd)/lite-xl" cmake --install build
```

where `<prefix>` might be one of `/`, `/usr` or `/opt`, the default is `/`.
To build a bundle application on macOS:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DLITE_BUNDLE=ON -DCMAKE_INSTALL_PREFIX=/
cmake --build build
DESTDIR="$(pwd)/Lite XL.app" cmake --install build
```

Please note that the package is relocatable to any prefix and the option prefix
affects only the place where the application is actually installed.

## Installing Prebuilt

Head over to [releases](https://github.com/lite-xl/lite-xl/releases) and download the version for your operating system.

The prebuilt releases supports the following OSes:

- Windows 7 and above
- Ubuntu 18.04 and above (glibc 2.27 and above)
- OS X El Capitan and above (version 10.11 and above)

Some distributions may provide custom binaries for their platforms.

### Windows

Lite XL comes with installers on Windows for typical installations.
Alternatively, we provide ZIP archives that you can download and extract anywhere and run directly.

To make Lite XL portable (e.g. running Lite XL from a thumb drive),
simply create a `user` folder where `lite-xl.exe` is located.
Lite XL will load and store all your configurations and plugins in the folder.

### macOS

We provide DMG files for macOS. Simply drag the program into your Applications folder.

> **Important**
> Newer versions of Lite XL are signed with a self-signed certificate,
> so you'll have to follow these steps when running Lite XL for the first time.
>
> 1. Find Lite XL in Finder (do not open it in Launchpad).
> 2. Control-click Lite XL, then choose `Open` from the shortcut menu.
> 3. Click `Open` in the popup menu.
>
> The correct steps may vary between macOS versions, so you should refer to
> the [macOS User Guide](https://support.apple.com/en-my/guide/mac-help/mh40616/mac).
>
> On an older version of Lite XL, you will need to run these commands instead:
> 
> ```sh
> # clears attributes from the directory
> xattr -cr /Applications/Lite\ XL.app
> ```
>
> Otherwise, macOS will display a **very misleading error** saying that the application is damaged.

### Linux

Unzip the file and `cd` into the `lite-xl` directory:

```sh
tar -xzf <file>
cd lite-xl
```

To run lite-xl without installing:

```sh
./lite-xl
```

To install lite-xl copy files over into appropriate directories:

```sh
rm -rf  $HOME/.local/share/lite-xl $HOME/.local/bin/lite-xl
mkdir -p $HOME/.local/bin && cp lite-xl $HOME/.local/bin/
mkdir -p $HOME/.local/share/lite-xl && cp -r data/* $HOME/.local/share/lite-xl/
```

#### Add Lite XL to PATH

To run Lite XL from the command line, you must add it to PATH.

If `$HOME/.local/bin` is not in PATH:

```sh
echo -e 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
```

Alternatively on recent versions of GNOME and KDE Plasma,
you can add `$HOME/.local/bin` to PATH via `~/.config/environment.d/envvars.conf`:

```ini
PATH=$HOME/.local/bin:$PATH
```

> **Note**
> Some systems might not load `.bashrc` when logging in.
> This can cause problems with launching applications from the desktop / menu.

#### Add Lite XL to application launchers

To get the icon to show up in app launcher, you need to create a desktop
entry and put it into `/usr/share/applications` or `~/.local/share/applications`.

Here is an example for a desktop entry in `~/.local/share/applications/com.lite_xl.LiteXL.desktop`,
assuming Lite XL is in PATH:

```ini
[Desktop Entry]
Type=Application
Name=Lite XL
Comment=A lightweight text editor written in Lua
Exec=lite-xl %F
Icon=lite-xl
Terminal=false
StartupWMClass=lite-xl
Categories=Development;IDE;
MimeType=text/plain;inode/directory;
```

To get the icon to show up in app launcher immediately, run:

```sh
xdg-desktop-menu forceupdate
```

Alternatively, you may log out and log in again.

#### Uninstall

To uninstall Lite XL, run:

```sh
rm -f $HOME/.local/bin/lite-xl
rm -rf $HOME/.local/share/icons/hicolor/scalable/apps/lite-xl.svg \
          $HOME/.local/share/applications/com.lite_xl.LiteXL.desktop \
          $HOME/.local/share/metainfo/com.lite_xl.LiteXL.appdata.xml \
          $HOME/.local/share/lite-xl
```

## Contributing

Any additional functionality that can be added through a plugin should be done
as a plugin, after which a pull request to the [Lite XL plugins repository] can be made.

Pull requests to improve or modify the editor itself are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

See the [licenses] file for details on licenses used by the required dependencies.


[CI]:                         https://github.com/lite-xl/lite-xl/actions/workflows/build.yml/badge.svg
[Discord Badge Image]:        https://img.shields.io/discord/847122429742809208?label=discord&logo=discord
[screenshot-dark]:            https://user-images.githubusercontent.com/433545/111063905-66943980-84b1-11eb-9040-3876f1133b20.png
[lite]:                       https://github.com/rxi/lite
[website]:                    https://lite-xl.com
[build]:                      https://lite-xl.com/setup/building-from-source/
[Get Lite XL]:                https://github.com/lite-xl/lite-xl/releases/latest
[Get plugins]:                https://github.com/lite-xl/lite-xl-plugins
[Get color themes]:           https://github.com/lite-xl/lite-xl-colors
[changelog]:                  https://github.com/lite-xl/lite-xl/blob/master/changelog.md
[Lite XL plugins repository]: https://github.com/lite-xl/lite-xl-plugins
[plugins repository]:         https://github.com/rxi/lite-plugins
[colors repository]:          https://github.com/lite-xl/lite-xl-colors
[LICENSE]:                    LICENSE
[licenses]:                   licenses/licenses.md
[lite-xl-build-box]:          https://github.com/lite-xl/lite-xl-build-box
