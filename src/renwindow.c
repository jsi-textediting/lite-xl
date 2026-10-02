#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#include <stdbool.h>
#include "renwindow.h"

static bool force_software_renderer = false;

void renwin_set_force_software(bool force) {
  force_software_renderer = force;
}

bool renwin_get_force_software(void) {
  return force_software_renderer;
}

bool renwin_is_gpu(RenWindow *ren) {
  return ren ? ren->is_gpu : false;
}

const char* renwin_get_renderer_name(RenWindow *ren) {
  if (ren && ren->is_gpu && ren->renderer) {
    const char *name = SDL_GetRendererName(ren->renderer);
    return name ? name : "gpu";
  }
  return "software";
}

static void renwin_cleanup_gpu(RenWindow *ren) {
  if (ren->texture) {
    SDL_DestroyTexture(ren->texture);
    ren->texture = NULL;
  }
  if (ren->renderer) {
    // glyph atlas textures belong to this renderer, free them before it goes away
    ren_font_purge_renderer(ren->renderer);
    SDL_DestroyRenderer(ren->renderer);
    ren->renderer = NULL;
  }
  // the software surface is owned by the SDL window (SDL_GetWindowSurface), never destroy it here
  ren->rensurface.surface = NULL;
  ren->is_gpu = false;
}

static bool renwin_init_software_surface(RenWindow *ren) {
  renwin_cleanup_gpu(ren);

  SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
  if (!surface) {
    fprintf(stderr, "Error getting window surface: %s\n", SDL_GetError());
    return false;
  }
  ren->rensurface.surface = surface;
  ren->rensurface.scale = 1;
  ren->is_gpu = false;
  renwin_update_scale(ren);
  return true;
}

static bool setup_renderer(RenWindow *ren) {
  if (!ren->renderer) {
    ren->renderer = SDL_CreateRenderer(ren->window, "direct3d11,direct3d12,gpu,vulkan,metal,opengl");
    if (!ren->renderer) {
      ren->renderer = SDL_CreateRenderer(ren->window, NULL);
    }
    if (!ren->renderer) {
      fprintf(stderr, "Warning: SDL_CreateRenderer failed: %s. Falling back to software rendering.\n", SDL_GetError());
      return false;
    }
  }
  return true;
}

static bool renwin_init_gpu_surface(RenWindow *ren) {
  if (!setup_renderer(ren)) {
    renwin_cleanup_gpu(ren);
    return false;
  }
  ren->is_gpu = true;
  ren->rensurface.scale = 1;
  ren->rensurface.surface = NULL;
  ren->texture = NULL;
  renwin_update_scale(ren);
  return true;
}

void renwin_init_surface(RenWindow *ren) {
  ren->scale_x = ren->scale_y = 1;
  bool success = false;
  if (!force_software_renderer) {
    success = renwin_init_gpu_surface(ren);
  }
  if (!success) {
    if (!renwin_init_software_surface(ren)) {
      fprintf(stderr, "Fatal: Both GPU and software surface initialization failed!\n");
      exit(1);
    }
  }
}

void renwin_init_command_buf(RenWindow *ren) {
  ren->command_buf = NULL;
  ren->command_buf_idx = 0;
  ren->command_buf_size = 0;
}

static RenRect scaled_rect(const RenRect rect, const int scale) {
  return (RenRect) {rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale};
}

void renwin_clip_to_surface(RenWindow *ren) {
  if (ren->is_gpu && ren->renderer) {
    SDL_SetRenderClipRect(ren->renderer, NULL);
  } else {
    SDL_SetSurfaceClipRect(renwin_get_surface(ren).surface, NULL);
  }
}

void renwin_set_clip_rect(RenWindow *ren, RenRect rect) {
  RenSurface rs = renwin_get_surface(ren);
  RenRect sr = scaled_rect(rect, rs.scale);
  if (ren->is_gpu && ren->renderer) {
    if (sr.width <= 0 || sr.height <= 0) {
      SDL_Rect empty_rect = { 0, 0, 0, 0 };
      SDL_SetRenderClipRect(ren->renderer, &empty_rect);
    } else {
      SDL_Rect clip = { sr.x, sr.y, sr.width, sr.height };
      SDL_SetRenderClipRect(ren->renderer, &clip);
    }
  } else {
    SDL_SetSurfaceClipRect(rs.surface, &(SDL_Rect){.x = sr.x, .y = sr.y, .w = sr.width, .h = sr.height});
  }
}

RenSurface renwin_get_surface(RenWindow *ren) {
  if (ren->is_gpu) {
    return ren->rensurface;
  }
  SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
  if (!surface) {
    fprintf(stderr, "Error getting window surface: %s\n", SDL_GetError());
    exit(1);
  }
  return (RenSurface){.surface = surface, .scale = 1};
}

void renwin_resize_surface(RenWindow *ren) {
  if (ren->is_gpu) {
    ren->rensurface.scale = 1;
    renwin_clip_to_surface(ren);
  } else {
    renwin_init_software_surface(ren);
    renwin_clip_to_surface(ren);
  }
}

void renwin_update_scale(RenWindow *ren) {
  int window_w = 0, window_h = 0;
  SDL_GetWindowSize(ren->window, &window_w, &window_h);
  int pix_w = 0, pix_h = 0;
  if (ren->is_gpu && ren->renderer) {
    SDL_GetRenderOutputSize(ren->renderer, &pix_w, &pix_h);
  } else if (!ren->is_gpu) {
    SDL_Surface *surface = SDL_GetWindowSurface(ren->window);
    if (surface) {
      pix_w = surface->w;
      pix_h = surface->h;
    }
  }
  if (pix_w <= 0 || pix_h <= 0) {
    SDL_GetWindowSizeInPixels(ren->window, &pix_w, &pix_h);
  }
  if (window_w > 0 && window_h > 0 && pix_w > 0 && pix_h > 0) {
    ren->scale_x = (float)pix_w / window_w;
    ren->scale_y = (float)pix_h / window_h;
  } else {
    ren->scale_x = ren->scale_y = 1;
  }
}

void renwin_show_window(RenWindow *ren) {
  SDL_ShowWindow(ren->window);
}

void renwin_update_rects(RenWindow *ren, RenRect *rects, int count) {
  if (ren->is_gpu) {
    if (ren->renderer) {
      SDL_RenderPresent(ren->renderer);
    }
  } else {
    SDL_UpdateWindowSurfaceRects(ren->window, (SDL_Rect*) rects, count);
  }
}

void renwin_free(RenWindow *ren) {
  renwin_cleanup_gpu(ren);
  SDL_DestroyWindow(ren->window);
  ren->window = NULL;
}
