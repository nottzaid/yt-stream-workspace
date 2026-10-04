// ytws-preview: show a Wayland output in a window without copying it.
//
// Frames of the output are captured with ext-image-copy-capture into GPU
// buffers, and each captured buffer is attached to the window as it is: the
// compositor scales it while compositing, so this client never draws. The
// next frame is captured only once the compositor has shown the previous
// one, so a hidden window or an unchanging output costs nothing at all.
//
// usage: ytws-preview [--title TITLE] [--app-id APP_ID] OUTPUT

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#include <drm_fourcc.h>
#include <gbm.h>
#include <wayland-client.h>
#include <xf86drm.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "single-pixel-buffer-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#define NBUFFERS 3
#define MAX_FAILURES 16

struct buffer {
    struct gbm_bo *bo;
    struct wl_buffer *wl;
    uint32_t width, height, format;
    bool busy; // being captured into, or held by the compositor
};

struct output {
    struct wl_output *wl;
    char *name;
    struct output *next;
};

static struct {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_subcompositor *subcompositor;
    struct xdg_wm_base *wm_base;
    struct wp_viewporter *viewporter;
    struct wp_single_pixel_buffer_manager_v1 *single_pixel;
    struct zwp_linux_dmabuf_v1 *dmabuf;
    struct ext_output_image_capture_source_manager_v1 *source_manager;
    struct ext_image_copy_capture_manager_v1 *capture_manager;
    struct output *outputs;

    // The window: a black surface filling it, and the picture on a
    // subsurface, letterboxed to the captured aspect ratio.
    struct wl_surface *surface;
    struct wp_viewport *viewport;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct wl_surface *picture;
    struct wl_subsurface *subsurface;
    struct wp_viewport *picture_viewport;
    int32_t pending_width, pending_height;
    int32_t width, height;
    bool configured;

    // Capture constraints, as the session last announced them.
    struct ext_image_copy_capture_session_v1 *session;
    uint32_t src_width, src_height;
    uint32_t format;
    int format_rank;
    uint64_t *modifiers;
    size_t n_modifiers;
    dev_t device;
    bool have_device;
    bool have_constraints;

    struct gbm_device *gbm;
    int drm_fd;
    dev_t gbm_device;
    struct buffer buffers[NBUFFERS];

    struct ext_image_copy_capture_frame_v1 *frame;
    struct buffer *capturing;
    struct wl_callback *frame_callback;
    bool want_frame; // the last frame was shown; capture the next
    int failures;

    bool running;
    int status;
    bool debug;
    unsigned long shown;
} s = { .drm_fd = -1, .want_frame = true, .running = true };

static void die(const char *message)
{
    fprintf(stderr, "ytws-preview: %s\n", message);
    exit(1);
}

static void stop(int status, const char *message)
{
    if (message)
        fprintf(stderr, "ytws-preview: %s\n", message);
    s.running = false;
    s.status = status;
}

// --- buffers -----------------------------------------------------------------

static bool buffer_fits(const struct buffer *b)
{
    return b->bo && b->width == s.src_width && b->height == s.src_height && b->format == s.format;
}

static void buffer_destroy(struct buffer *b)
{
    if (b->wl)
        wl_buffer_destroy(b->wl);
    if (b->bo)
        gbm_bo_destroy(b->bo);
    *b = (struct buffer){ 0 };
}

static void maybe_capture(void);

static void on_buffer_release(void *data, struct wl_buffer *wl)
{
    struct buffer *b = data;
    (void)wl;
    b->busy = false;
    if (!buffer_fits(b))
        buffer_destroy(b);
    maybe_capture();
}

static const struct wl_buffer_listener buffer_listener = {
    .release = on_buffer_release,
};

static bool open_gbm(void)
{
    if (s.gbm && s.gbm_device == s.device)
        return true;

    drmDevicePtr device = NULL;
    if (drmGetDeviceFromDevId(s.device, 0, &device) != 0)
        return false;
    int fd = -1;
    if (device->available_nodes & (1 << DRM_NODE_RENDER))
        fd = open(device->nodes[DRM_NODE_RENDER], O_RDWR | O_CLOEXEC);
    drmFreeDevice(&device);
    if (fd < 0)
        return false;

    struct gbm_device *gbm = gbm_create_device(fd);
    if (!gbm) {
        close(fd);
        return false;
    }
    for (int i = 0; i < NBUFFERS; i++)
        if (!s.buffers[i].busy)
            buffer_destroy(&s.buffers[i]);
    if (s.gbm)
        gbm_device_destroy(s.gbm);
    if (s.drm_fd >= 0)
        close(s.drm_fd);
    s.gbm = gbm;
    s.drm_fd = fd;
    s.gbm_device = s.device;
    return true;
}

static bool buffer_create(struct buffer *b)
{
    if (!open_gbm())
        return false;

    struct gbm_bo *bo = NULL;
    if (s.n_modifiers > 0)
        bo = gbm_bo_create_with_modifiers2(s.gbm, s.src_width, s.src_height, s.format,
                                           s.modifiers, s.n_modifiers, GBM_BO_USE_RENDERING);
    if (!bo)
        bo = gbm_bo_create(s.gbm, s.src_width, s.src_height, s.format, GBM_BO_USE_RENDERING);
    if (!bo)
        return false;

    struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(s.dmabuf);
    uint64_t modifier = gbm_bo_get_modifier(bo);
    for (int i = 0; i < gbm_bo_get_plane_count(bo); i++) {
        int fd = gbm_bo_get_fd_for_plane(bo, i);
        if (fd < 0) {
            zwp_linux_buffer_params_v1_destroy(params);
            gbm_bo_destroy(bo);
            return false;
        }
        zwp_linux_buffer_params_v1_add(params, fd, i, gbm_bo_get_offset(bo, i),
                                       gbm_bo_get_stride_for_plane(bo, i),
                                       modifier >> 32, modifier & 0xffffffff);
        close(fd); // the request carries its own copy
    }
    b->wl = zwp_linux_buffer_params_v1_create_immed(params, s.src_width, s.src_height, s.format, 0);
    zwp_linux_buffer_params_v1_destroy(params);
    wl_buffer_add_listener(b->wl, &buffer_listener, b);
    b->bo = bo;
    b->width = s.src_width;
    b->height = s.src_height;
    b->format = s.format;
    b->busy = false;
    return true;
}

// A buffer the compositor is not using, matching the current constraints.
static struct buffer *free_buffer(void)
{
    for (int i = 0; i < NBUFFERS; i++)
        if (!s.buffers[i].busy && buffer_fits(&s.buffers[i]))
            return &s.buffers[i];
    for (int i = 0; i < NBUFFERS; i++) {
        struct buffer *b = &s.buffers[i];
        if (b->busy)
            continue;
        buffer_destroy(b);
        if (!buffer_create(b))
            die("cannot allocate a capture buffer");
        return b;
    }
    return NULL;
}

// --- window ------------------------------------------------------------------

static void layout(void)
{
    if (!s.configured)
        return;

    wp_viewport_set_destination(s.viewport, s.width, s.height);
    struct wl_region *opaque = wl_compositor_create_region(s.compositor);
    wl_region_add(opaque, 0, 0, s.width, s.height);
    wl_surface_set_opaque_region(s.surface, opaque);
    wl_region_destroy(opaque);

    int32_t w = s.width, h = s.height;
    if (s.src_width && s.src_height) {
        if ((int64_t)s.width * s.src_height > (int64_t)s.height * s.src_width)
            w = (int32_t)(((int64_t)s.height * s.src_width + s.src_height / 2) / s.src_height);
        else
            h = (int32_t)(((int64_t)s.width * s.src_height + s.src_width / 2) / s.src_width);
    }
    if (w < 1)
        w = 1;
    if (h < 1)
        h = 1;
    wp_viewport_set_destination(s.picture_viewport, w, h);
    struct wl_region *picture_opaque = wl_compositor_create_region(s.compositor);
    wl_region_add(picture_opaque, 0, 0, w, h);
    wl_surface_set_opaque_region(s.picture, picture_opaque);
    wl_region_destroy(picture_opaque);
    wl_subsurface_set_position(s.subsurface, (s.width - w) / 2, (s.height - h) / 2);
    wl_surface_commit(s.picture);
    wl_surface_commit(s.surface);
}

static void on_toplevel_configure(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height,
                                  struct wl_array *states)
{
    (void)data, (void)toplevel, (void)states;
    s.pending_width = width;
    s.pending_height = height;
}

static void on_toplevel_close(void *data, struct xdg_toplevel *toplevel)
{
    (void)data, (void)toplevel;
    stop(0, NULL);
}

static void on_toplevel_configure_bounds(void *data, struct xdg_toplevel *t, int32_t w, int32_t h)
{
    (void)data, (void)t, (void)w, (void)h;
}

static void on_toplevel_wm_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps)
{
    (void)data, (void)t, (void)caps;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = on_toplevel_configure,
    .close = on_toplevel_close,
    .configure_bounds = on_toplevel_configure_bounds,
    .wm_capabilities = on_toplevel_wm_capabilities,
};

static void on_xdg_surface_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial)
{
    (void)data;
    xdg_surface_ack_configure(xdg_surface, serial);
    s.width = s.pending_width > 0 ? s.pending_width : (s.width > 0 ? s.width : 1280);
    s.height = s.pending_height > 0 ? s.pending_height : (s.height > 0 ? s.height : 720);
    s.configured = true;
    layout();
    maybe_capture();
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = on_xdg_surface_configure,
};

static void on_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial)
{
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = on_ping,
};

static void create_window(const char *title, const char *app_id)
{
    s.surface = wl_compositor_create_surface(s.compositor);
    s.viewport = wp_viewporter_get_viewport(s.viewporter, s.surface);
    s.xdg_surface = xdg_wm_base_get_xdg_surface(s.wm_base, s.surface);
    xdg_surface_add_listener(s.xdg_surface, &xdg_surface_listener, NULL);
    s.toplevel = xdg_surface_get_toplevel(s.xdg_surface);
    xdg_toplevel_add_listener(s.toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(s.toplevel, title);
    xdg_toplevel_set_app_id(s.toplevel, app_id);

    s.picture = wl_compositor_create_surface(s.compositor);
    s.picture_viewport = wp_viewporter_get_viewport(s.viewporter, s.picture);
    s.subsurface = wl_subcompositor_get_subsurface(s.subcompositor, s.picture, s.surface);
    wl_subsurface_set_desync(s.subsurface);
    struct wl_region *empty = wl_compositor_create_region(s.compositor);
    wl_surface_set_input_region(s.picture, empty);
    wl_region_destroy(empty);

    // The first commit carries no buffer and asks for a configure.
    wl_surface_commit(s.surface);
}

static void attach_background(void)
{
    struct wl_buffer *black =
        wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(s.single_pixel, 0, 0, 0, UINT32_MAX);
    wl_surface_attach(s.surface, black, 0, 0);
    wl_surface_damage_buffer(s.surface, 0, 0, INT32_MAX, INT32_MAX);
    // Kept attached for the life of the window.
}

// --- capture -----------------------------------------------------------------

static void on_frame_callback(void *data, struct wl_callback *callback, uint32_t time)
{
    (void)data, (void)time;
    wl_callback_destroy(callback);
    s.frame_callback = NULL;
    s.want_frame = true;
    maybe_capture();
}

static const struct wl_callback_listener frame_callback_listener = {
    .done = on_frame_callback,
};

static void on_frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t transform)
{
    (void)data, (void)f, (void)transform;
}

static void on_frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y,
                            int32_t w, int32_t h)
{
    (void)data, (void)f, (void)x, (void)y, (void)w, (void)h;
}

static void on_frame_presentation_time(void *data, struct ext_image_copy_capture_frame_v1 *f,
                                       uint32_t hi, uint32_t lo, uint32_t nsec)
{
    (void)data, (void)f, (void)hi, (void)lo, (void)nsec;
}

static void on_frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f)
{
    (void)data;
    ext_image_copy_capture_frame_v1_destroy(f);
    s.frame = NULL;
    struct buffer *b = s.capturing;
    s.capturing = NULL;
    s.failures = 0;

    // Shown as captured; it stays busy until the compositor releases it.
    wl_surface_attach(s.picture, b->wl, 0, 0);
    wl_surface_damage_buffer(s.picture, 0, 0, INT32_MAX, INT32_MAX);
    s.frame_callback = wl_surface_frame(s.picture);
    wl_callback_add_listener(s.frame_callback, &frame_callback_listener, NULL);
    wl_surface_commit(s.picture);
    s.want_frame = false;

    if (s.debug && ++s.shown % 60 == 0)
        fprintf(stderr, "ytws-preview: %lu frames shown\n", s.shown);
}

static void on_frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason)
{
    (void)data;
    ext_image_copy_capture_frame_v1_destroy(f);
    s.frame = NULL;
    if (s.capturing)
        s.capturing->busy = false;
    s.capturing = NULL;

    switch (reason) {
    case EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED:
        stop(1, "the captured output is gone");
        return;
    case EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS:
        return; // new constraints follow, then a done event
    default:
        if (++s.failures > MAX_FAILURES) {
            stop(1, "capturing keeps failing");
            return;
        }
        maybe_capture();
    }
}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
    .transform = on_frame_transform,
    .damage = on_frame_damage,
    .presentation_time = on_frame_presentation_time,
    .ready = on_frame_ready,
    .failed = on_frame_failed,
};

static void maybe_capture(void)
{
    if (!s.running || s.frame || !s.want_frame || !s.configured || !s.have_constraints)
        return;
    struct buffer *b = free_buffer();
    if (!b)
        return; // a release will call back
    b->busy = true;
    s.capturing = b;
    s.frame = ext_image_copy_capture_session_v1_create_frame(s.session);
    ext_image_copy_capture_frame_v1_add_listener(s.frame, &frame_listener, NULL);
    ext_image_copy_capture_frame_v1_attach_buffer(s.frame, b->wl);
    ext_image_copy_capture_frame_v1_damage_buffer(s.frame, 0, 0, INT32_MAX, INT32_MAX);
    ext_image_copy_capture_frame_v1_capture(s.frame);
}

// Opaque formats first: the compositor can then skip blending.
static int format_rank(uint32_t format)
{
    switch (format) {
    case DRM_FORMAT_XRGB8888: return 4;
    case DRM_FORMAT_XBGR8888: return 3;
    case DRM_FORMAT_ARGB8888: return 2;
    case DRM_FORMAT_ABGR8888: return 1;
    default: return 0;
    }
}

static void on_session_buffer_size(void *data, struct ext_image_copy_capture_session_v1 *session,
                                   uint32_t width, uint32_t height)
{
    (void)data, (void)session;
    s.src_width = width;
    s.src_height = height;
}

static void on_session_shm_format(void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format)
{
    (void)data, (void)session, (void)format;
}

static void on_session_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *session,
                                     struct wl_array *device)
{
    (void)data, (void)session;
    if (device->size == sizeof(dev_t)) {
        memcpy(&s.device, device->data, sizeof(dev_t));
        s.have_device = true;
    }
}

static void on_session_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *session,
                                     uint32_t format, struct wl_array *modifiers)
{
    (void)data, (void)session;
    int rank = format_rank(format);
    if (rank <= s.format_rank)
        return;
    s.format_rank = rank;
    s.format = format;
    free(s.modifiers);
    s.modifiers = NULL;
    s.n_modifiers = 0;
    size_t n = modifiers->size / sizeof(uint64_t);
    if (n == 0)
        return;
    s.modifiers = calloc(n, sizeof(uint64_t));
    if (!s.modifiers)
        die("out of memory");
    const uint64_t *mods = modifiers->data;
    for (size_t i = 0; i < n; i++)
        if (mods[i] != DRM_FORMAT_MOD_INVALID)
            s.modifiers[s.n_modifiers++] = mods[i];
}

static void on_session_done(void *data, struct ext_image_copy_capture_session_v1 *session)
{
    (void)data, (void)session;
    if (!s.have_device || !s.format || !s.src_width || !s.src_height) {
        stop(1, "the compositor offers no usable GPU buffer for the output");
        return;
    }
    s.have_constraints = true;
    // Formats are announced afresh before every done.
    s.format_rank = 0;
    layout();
    maybe_capture();
}

static void on_session_stopped(void *data, struct ext_image_copy_capture_session_v1 *session)
{
    (void)data, (void)session;
    stop(1, "the captured output is gone");
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    .buffer_size = on_session_buffer_size,
    .shm_format = on_session_shm_format,
    .dmabuf_device = on_session_dmabuf_device,
    .dmabuf_format = on_session_dmabuf_format,
    .done = on_session_done,
    .stopped = on_session_stopped,
};

// --- globals -----------------------------------------------------------------

static void on_output_geometry(void *data, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                               int32_t subpixel, const char *make, const char *model, int32_t transform)
{
    (void)data, (void)o, (void)x, (void)y, (void)pw, (void)ph, (void)subpixel, (void)make, (void)model,
        (void)transform;
}

static void on_output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh)
{
    (void)data, (void)o, (void)flags, (void)w, (void)h, (void)refresh;
}

static void on_output_done(void *data, struct wl_output *o)
{
    (void)data, (void)o;
}

static void on_output_scale(void *data, struct wl_output *o, int32_t factor)
{
    (void)data, (void)o, (void)factor;
}

static void on_output_name(void *data, struct wl_output *o, const char *name)
{
    struct output *out = data;
    (void)o;
    free(out->name);
    out->name = strdup(name);
}

static void on_output_description(void *data, struct wl_output *o, const char *description)
{
    (void)data, (void)o, (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = on_output_geometry,
    .mode = on_output_mode,
    .done = on_output_done,
    .scale = on_output_scale,
    .name = on_output_name,
    .description = on_output_description,
};

static void on_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
                      uint32_t version)
{
    (void)data;
#define BIND(field, iface, min, max)                                                                \
    if (strcmp(interface, (iface).name) == 0 && version >= (min)) {                                \
        s.field = wl_registry_bind(registry, name, &(iface), version < (max) ? version : (max));   \
        return;                                                                                     \
    }
    BIND(compositor, wl_compositor_interface, 4, 6)
    BIND(subcompositor, wl_subcompositor_interface, 1, 1)
    BIND(wm_base, xdg_wm_base_interface, 1, 5)
    BIND(viewporter, wp_viewporter_interface, 1, 1)
    BIND(single_pixel, wp_single_pixel_buffer_manager_v1_interface, 1, 1)
    BIND(dmabuf, zwp_linux_dmabuf_v1_interface, 3, 4)
    BIND(source_manager, ext_output_image_capture_source_manager_v1_interface, 1, 1)
    BIND(capture_manager, ext_image_copy_capture_manager_v1_interface, 1, 1)
#undef BIND
    if (strcmp(interface, wl_output_interface.name) == 0 && version >= 4) {
        struct output *out = calloc(1, sizeof(*out));
        if (!out)
            die("out of memory");
        out->wl = wl_registry_bind(registry, name, &wl_output_interface, 4);
        wl_output_add_listener(out->wl, &output_listener, out);
        out->next = s.outputs;
        s.outputs = out;
    }
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data, (void)registry, (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = on_global,
    .global_remove = on_global_remove,
};

int main(int argc, char **argv)
{
    const char *title = "Stream preview";
    const char *app_id = "yt-stream-workspace.preview";
    const char *output_name = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--title") == 0 && i + 1 < argc)
            title = argv[++i];
        else if (strcmp(argv[i], "--app-id") == 0 && i + 1 < argc)
            app_id = argv[++i];
        else if (argv[i][0] != '-' && !output_name)
            output_name = argv[i];
        else {
            fprintf(stderr, "usage: ytws-preview [--title TITLE] [--app-id APP_ID] OUTPUT\n");
            return 2;
        }
    }
    if (!output_name) {
        fprintf(stderr, "usage: ytws-preview [--title TITLE] [--app-id APP_ID] OUTPUT\n");
        return 2;
    }
    s.debug = getenv("YTWS_PREVIEW_DEBUG") != NULL;

    s.display = wl_display_connect(NULL);
    if (!s.display)
        die("cannot connect to the Wayland display");
    struct wl_registry *registry = wl_display_get_registry(s.display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(s.display); // globals
    wl_display_roundtrip(s.display); // output names

    if (!s.compositor || !s.subcompositor || !s.wm_base || !s.viewporter || !s.single_pixel || !s.dmabuf)
        die("the compositor lacks a protocol this preview needs");
    if (!s.source_manager || !s.capture_manager)
        die("the compositor does not support ext-image-copy-capture");

    struct wl_output *target = NULL;
    for (struct output *o = s.outputs; o; o = o->next)
        if (o->name && strcmp(o->name, output_name) == 0)
            target = o->wl;
    if (!target) {
        fprintf(stderr, "ytws-preview: no output named %s\n", output_name);
        return 1;
    }

    xdg_wm_base_add_listener(s.wm_base, &wm_base_listener, NULL);
    create_window(title, app_id);
    attach_background();

    struct ext_image_capture_source_v1 *source =
        ext_output_image_capture_source_manager_v1_create_source(s.source_manager, target);
    s.session = ext_image_copy_capture_manager_v1_create_session(
        s.capture_manager, source, EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS);
    ext_image_copy_capture_session_v1_add_listener(s.session, &session_listener, NULL);

    while (s.running && wl_display_dispatch(s.display) != -1)
        ;
    if (s.running) {
        fprintf(stderr, "ytws-preview: lost the Wayland connection\n");
        return 1;
    }
    return s.status;
}
