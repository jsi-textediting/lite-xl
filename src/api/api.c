#include <string.h>
#include <ec/events.h>
#include <ec/lua_api.h>
#include "api.h"
#include "../custom_events.h"

int luaopen_system(lua_State *L);
int luaopen_renderer(lua_State *L);
int luaopen_renwindow(lua_State *L);
int luaopen_utf8extra(lua_State* L);
int luaopen_buffer(lua_State* L);

static const luaL_Reg libs[] = {
  { "system",     luaopen_system     },
  { "renderer",   luaopen_renderer   },
  { "renwindow",  luaopen_renwindow  },
  { "regex",      ec_luaopen_regex      },
  { "process",    ec_luaopen_process    },
  { "dirmonitor", ec_luaopen_dirmonitor },
  { "utf8extra",  luaopen_utf8extra  },
  { "buffer",     luaopen_buffer     },
  { NULL, NULL }
};


/* libeditingcore announces dirmonitor changes through these hooks */
static bool ec_hook_register(const char *name, void *userdata) {
  (void) userdata;
  return register_custom_event(name, NULL);
}

static bool ec_hook_push(const char *name, void *userdata) {
  (void) userdata;
  CustomEvent event;
  memset(&event, 0, sizeof(event));
  return push_custom_event(name, &event);
}

void api_load_libs(lua_State *L) {
  ec_set_event_hooks(ec_hook_register, ec_hook_push, NULL);
  for (int i = 0; libs[i].name; i++)
    luaL_requiref(L, libs[i].name, libs[i].func, 1);
}

