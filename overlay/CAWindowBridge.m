// The only file that calls private SkyLight interfaces. Core Animation owns pixels.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>

typedef int Connection;
typedef CFTypeRef Region;

@interface CAContext : NSObject
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
@property (strong) CALayer *layer;
@property (readonly) uint32_t contextId;
@end

@interface CourierCAWindow : NSObject
@property uint32_t windowID, surfaceID;
@property Region shape, eventShape;
@property (strong) CAContext *context;
@property (strong) CALayer *root;
@property CGRect frame;
@end
@implementation CourierCAWindow
- (void)dealloc {
    if (_shape) CFRelease(_shape);
    if (_eventShape) CFRelease(_eventShape);
}
@end

static Connection connection;
static void *framework;
static Connection (*mainConnection)(void);
static CGError (*newRegion)(CGRect *, Region *);
static CGError (*newTransparentWindow)(Connection, int, Region, Region, int, uint64_t *, float, float, int, uint32_t *, void *);
static CGError (*setOpacity)(Connection, uint32_t, bool);
static CGError (*setLevel)(Connection, uint32_t, int);
static CGError (*setEventShape)(Connection, uint32_t, Region);
static CGError (*setTags)(Connection, uint32_t, uint32_t *, int);
static CGError (*getTags)(Connection, uint32_t, uint32_t *, int);
static CGError (*setShape)(Connection, uint32_t, Region);
static CGError (*orderWindow)(Connection, uint32_t, int, uint32_t);
static CGError (*moveWindow)(Connection, uint32_t, CGPoint *);
static CGError (*releaseWindow)(Connection, uint32_t);
static CGError (*addSurface)(Connection, uint32_t, uint32_t *);
static CGError (*setSurfaceBounds)(Connection, uint32_t, uint32_t, CGRect);
static CGError (*setSurfaceOpacity)(Connection, uint32_t, uint32_t, bool);
static CGError (*bindSurface)(Connection, uint32_t, uint32_t, int, int, uint32_t);
static CGError (*orderSurface)(Connection, uint32_t, uint32_t, int, uint32_t);

#define LOAD(variable, name) do { variable = dlsym(framework, name); if (!variable) return name; } while (0)
const char *courier_ca_init(void) {
    framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!framework) return "SkyLight unavailable";
    LOAD(mainConnection, "SLSMainConnectionID");
    LOAD(newRegion, "CGSNewRegionWithRect");
    LOAD(newTransparentWindow, "SLSNewWindowWithOpaqueShapeAndContext");
    LOAD(setOpacity, "SLSSetWindowOpacity");
    LOAD(setLevel, "SLSSetWindowLevel");
    LOAD(setEventShape, "SLSSetWindowEventShape");
    LOAD(setTags, "SLSSetWindowTags");
    LOAD(getTags, "SLSGetWindowTags");
    LOAD(setShape, "SLSSetWindowShape");
    LOAD(orderWindow, "SLSOrderWindow");
    LOAD(moveWindow, "SLSMoveWindow");
    LOAD(releaseWindow, "SLSReleaseWindow");
    LOAD(addSurface, "SLSAddSurface");
    LOAD(setSurfaceBounds, "SLSSetSurfaceBounds");
    LOAD(setSurfaceOpacity, "SLSSetSurfaceOpacity");
    LOAD(bindSurface, "SLSBindSurface");
    LOAD(orderSurface, "SLSOrderSurface");
    connection = mainConnection();
    if (!connection) return "WindowServer connection unavailable";
    Class contextClass = NSClassFromString(@"CAContext");
    if (!contextClass || ![contextClass respondsToSelector:@selector(remoteContextWithOptions:)])
        return "CAContext unavailable";
    return NULL;
}

void *courier_ca_create(double x, double y, double width, double height, double scale) {
    if (!connection || width < 1 || height < 1) return NULL;
    CourierCAWindow *window = [CourierCAWindow new];
    window.frame = CGRectMake(x, y, width, height);
    CGRect local = CGRectMake(0, 0, width, height);
    Region shape = NULL, eventShape = NULL;
    if (newRegion(&local, &shape)) return NULL;
    window.shape = shape;
    uint32_t wid = 0, sid = 0;
    CGRect emptyOpaque = CGRectZero;
    Region opaque = NULL;
    if (newRegion(&emptyOpaque, &opaque)) return NULL;
    uint64_t initialTags[1] = {0};
    // Bit 18 suppresses WindowServer's opaque autofill behind the CA surface.
    CGError created = newTransparentWindow(connection, 2, shape, opaque,
                                            1 << 18, initialTags, x, y, 64, &wid, NULL);
    CFRelease(opaque);
    if (getenv("COURIER_OVERLAY_VISUAL_PROBE"))
        fprintf(stderr, "transparent_create result=%d options=0x40000 opaque=empty shape=(%.1f,%.1f)\n",
                created, width, height);
    if (created) {
        if (getenv("COURIER_OVERLAY_VISUAL_PROBE"))
            fprintf(stderr, "transparent_window_failed result=%d\n", created);
        return NULL;
    }
    window.windowID = wid;
    if (setOpacity(connection, window.windowID, false) || setLevel(connection, window.windowID, 25)) goto fail;
    CGRect empty = CGRectZero;
    if (newRegion(&empty, &eventShape) || setEventShape(connection, window.windowID, eventShape)) goto fail;
    window.eventShape = eventShape;
    uint32_t tags[2] = {(1u << 9) | (1u << 15) | (1u << 16), 0};
    uint32_t readback[2] = {0, 0};
    if (setTags(connection, window.windowID, tags, 64) ||
        getTags(connection, window.windowID, readback, 64) ||
        (readback[0] & tags[0]) != tags[0]) goto fail;
    if (getenv("COURIER_OVERLAY_VISUAL_PROBE"))
        fprintf(stderr, "window=%u empty_event_shape=1 tags=0x%x\n", wid, readback[0]);
    window.context = [CAContext remoteContextWithOptions:@{}];
    if (!window.context) goto fail;
    window.root = [CALayer layer];
    window.root.frame = local;
    window.root.geometryFlipped = YES;
    window.root.contentsScale = MAX(1, scale);
    window.context.layer = window.root;
    [CATransaction flush];
    if (addSurface(connection, window.windowID, &sid)) goto fail;
    window.surfaceID = sid;
    if (setSurfaceBounds(connection, window.windowID, window.surfaceID, local) ||
        setSurfaceOpacity(connection, window.windowID, window.surfaceID, false) ||
        bindSurface(connection, window.windowID, window.surfaceID, 4, 0, window.context.contextId) ||
        orderSurface(connection, window.windowID, window.surfaceID, 1, 0)) goto fail;
    if (getenv("COURIER_OVERLAY_VISUAL_PROBE"))
        fprintf(stderr, "create wid=%u sid=%u context=%u frame=(%.1f,%.1f,%.1f,%.1f) surface=(%.1f,%.1f) root=(%.1f,%.1f) scale=%.1f bind=0 order_surface=0\n",
                wid, sid, window.context.contextId, x, y, width, height,
                width, height,
                window.root.bounds.size.width, window.root.bounds.size.height, scale);
    return (__bridge_retained void *)window;
fail:
    releaseWindow(connection, window.windowID);
    window.context.layer = nil;
    return NULL;
}

void courier_ca_destroy(void *raw) {
    if (!raw) return;
    CourierCAWindow *window = (__bridge_transfer CourierCAWindow *)raw;
    window.context.layer = nil;
    releaseWindow(connection, window.windowID);
}

void *courier_ca_root(void *raw) {
    CourierCAWindow *window = (__bridge CourierCAWindow *)raw;
    return window ? (__bridge void *)window.root : NULL;
}

int courier_ca_order(void *raw) {
    CourierCAWindow *window = (__bridge CourierCAWindow *)raw;
    return window ? orderWindow(connection, window.windowID, 1, 0) : -1;
}

int courier_ca_set_frame(void *raw, double x, double y, double width, double height) {
    CourierCAWindow *window = (__bridge CourierCAWindow *)raw;
    if (!window || width < 1 || height < 1) return -1;
    CGRect local = CGRectMake(0, 0, width, height);
    if (window.frame.size.width != width || window.frame.size.height != height) {
        Region replacement = NULL;
        if (newRegion(&local, &replacement)) return -2;
        if (setShape(connection, window.windowID, replacement) ||
            setSurfaceBounds(connection, window.windowID, window.surfaceID, local)) {
            CFRelease(replacement);
            return -3;
        }
        if (window.shape) CFRelease(window.shape);
        window.shape = replacement;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        window.root.frame = local;
        [CATransaction commit];
    }
    if (window.frame.origin.x != x || window.frame.origin.y != y) {
        CGPoint point = CGPointMake(x, y);
        if (moveWindow(connection, window.windowID, &point)) return -4;
    }
    window.frame = CGRectMake(x, y, width, height);
    return 0;
}
