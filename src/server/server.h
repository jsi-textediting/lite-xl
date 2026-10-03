#ifndef LITE_SERVER_H
#define LITE_SERVER_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#define LITE_SERVER_PROTO_VERSION 1

/* serverio: protocol channel (stdin/stdout) helpers, see stdio.c */
int serverio_setup(void);
int luaopen_serverio(lua_State *L);

/* serverfs: POSIX filesystem helpers, see fsops.c */
int luaopen_serverfs(lua_State *L);

#endif
