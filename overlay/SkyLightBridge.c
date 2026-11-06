// All private WindowServer calls live here. Missing symbols fail closed.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int Connection;
typedef CFTypeRef Region;
typedef struct { uint32_t id; Region shape, eventShape; CGContextRef context; double width, height; bool shown; } BirdWindow;
static Connection connection;
static void *handle;
static Connection (*mainConnection)(void);
static CGError (*newRegion)(CGRect *, Region *);
static CGError (*newWindow)(Connection, int, float, float, Region, uint32_t *);
static CGError (*setOpacity)(Connection, uint32_t, bool);
static CGError (*setLevel)(Connection, uint32_t, int);
static CGError (*setResolution)(Connection, uint32_t, double);
static CGError (*setEventShape)(Connection, uint32_t, Region);
static CGError (*orderWindow)(Connection, uint32_t, int, uint32_t);
static CGError (*moveWindow)(Connection, uint32_t, CGPoint *);
static CGError (*transformWindow)(Connection, uint32_t, CGAffineTransform);
static CGError (*releaseWindow)(Connection, uint32_t);
static CGContextRef (*windowContext)(Connection, uint32_t, CFDictionaryRef);
static CGError (*flushContent)(Connection, uint32_t, void *);
static CGError (*disableUpdate)(Connection), (*reenableUpdate)(Connection);
static CGImageRef birdFrames[3];

#define LOAD(dst, symbol) do { dst = dlsym(handle, symbol); if (!dst) return symbol; } while (0)
const char *courier_sl_init(void) {
    handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!handle) return "SkyLight unavailable";
    LOAD(mainConnection, "SLSMainConnectionID");
    LOAD(newRegion, "CGSNewRegionWithRect");
    LOAD(newWindow, "SLSNewWindow");
    LOAD(setOpacity, "SLSSetWindowOpacity");
    LOAD(setLevel, "SLSSetWindowLevel");
    LOAD(setResolution, "SLSSetWindowResolution");
    LOAD(setEventShape, "SLSSetWindowEventShape");
    LOAD(orderWindow, "SLSOrderWindow");
    LOAD(moveWindow, "SLSMoveWindow");
    LOAD(transformWindow, "SLSSetWindowTransform");
    LOAD(releaseWindow, "SLSReleaseWindow");
    LOAD(windowContext, "SLWindowContextCreate");
    LOAD(flushContent, "SLSFlushWindowContentRegion");
    LOAD(disableUpdate, "SLSDisableUpdate");
    LOAD(reenableUpdate, "SLSReenableUpdate");
    connection = mainConnection();
    return connection ? NULL : "WindowServer connection unavailable";
}

void *courier_sl_create(double x, double y, double width, double height, double scale, int interactive) {
    if (!connection || width < 1 || height < 1) return NULL;
    BirdWindow *window = calloc(1, sizeof(BirdWindow));
    if (!window) return NULL;
    window->width = width; window->height = height;
    CGRect rect = CGRectMake(0, 0, width, height);
    if (newRegion(&rect, &window->shape) || newWindow(connection, 2, x, y, window->shape, &window->id)) goto fail;
    if (setOpacity(connection, window->id, false) || setLevel(connection, window->id, 25)) goto fail;
    if (setResolution(connection, window->id, scale)) goto fail;
    if (!interactive) {
        CGRect empty = CGRectZero;
        if (newRegion(&empty, &window->eventShape) || setEventShape(connection, window->id, window->eventShape)) goto fail;
    }
    window->context = windowContext(connection, window->id, NULL);
    if (!window->context) goto fail;
    return window;
fail:
    if (window->id) releaseWindow(connection, window->id);
    if (window->shape) CFRelease(window->shape);
    if (window->eventShape) CFRelease(window->eventShape);
    free(window);
    return NULL;
}

void courier_sl_destroy(void *raw) {
    BirdWindow *window = raw;
    if (!window) return;
    if (window->context) CGContextRelease(window->context);
    releaseWindow(connection, window->id);
    if (window->shape) CFRelease(window->shape);
    if (window->eventShape) CFRelease(window->eventShape);
    free(window);
}

int courier_sl_move(void *raw, double x, double y) {
    BirdWindow *window = raw;
    if (!window) return -1;
    CGPoint point = CGPointMake(x, y);
    return moveWindow(connection, window->id, &point);
}

// SLSSetWindowTransform takes screen-to-window coordinates. The inverse maps
// local (0,0) to the first endpoint and local +x along the target segment.
int courier_sl_line_transform(void *raw, double x, double y, double angle) {
    BirdWindow *window = raw;
    if (!window) return -1;
    double c = cos(angle), s = sin(angle);
    CGAffineTransform inverse = CGAffineTransformMake(c, -s, s, c, -c*x-s*y, s*x-c*y);
    return transformWindow(connection, window->id, inverse);
}

static void flush(BirdWindow *window) {
    CGContextFlush(window->context);
    flushContent(connection, window->id, NULL);
    if (!window->shown) {
        disableUpdate(connection);
        orderWindow(connection, window->id, 1, 0);
        reenableUpdate(connection);
        window->shown = true;
    }
}

void courier_sl_ring(void *raw, double red, double green, double blue) {
    BirdWindow *window = raw;
    if (!window) return;
    CGContextRef ctx = window->context;
    CGContextClearRect(ctx, CGRectMake(0, 0, window->width, window->height));
    CGContextSetRGBStrokeColor(ctx, red, green, blue, 0.95);
    CGContextSetLineWidth(ctx, 2);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, window->width-8, window->height-8));
    flush(window);
}

void courier_sl_line(void *raw, double red, double green, double blue) {
    BirdWindow *window = raw;
    if (!window) return;
    CGContextRef ctx = window->context;
    CGContextClearRect(ctx, CGRectMake(0, 0, window->width, window->height));
    CGContextSetRGBFillColor(ctx, red, green, blue, 0.75);
    CGContextFillRect(ctx, CGRectMake(0, (window->height-2)/2, window->width, 2));
    flush(window);
}

int courier_sl_load_bird(int index, const char *path) {
    if (index < 0 || index > 2) return -1;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return -1;
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (!source) return -1;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return -1;
    if (birdFrames[index]) CGImageRelease(birdFrames[index]);
    birdFrames[index] = image;
    return 0;
}

void courier_sl_bird(void *raw, int frame, int facingLeft, double red, double green, double blue,
                     int particles, double phase) {
    BirdWindow *window = raw;
    if (!window || frame < 0 || frame > 2 || !birdFrames[frame]) return;
    CGContextRef ctx = window->context;
    CGContextClearRect(ctx, CGRectMake(0, 0, window->width, window->height));
    CGContextSaveGState(ctx);
    if (facingLeft) { CGContextTranslateCTM(ctx, window->width, 0); CGContextScaleCTM(ctx, -1, 1); }
    double size = fmin(36, fmin(window->width-4, window->height-4));
    CGRect bird = CGRectMake((window->width-size)/2, (window->height-size)/2, size, size);
    CGContextClipToMask(ctx, bird, birdFrames[frame]);
    CGContextSetRGBFillColor(ctx, red, green, blue, 1);
    CGContextFillRect(ctx, bird);
    CGContextRestoreGState(ctx);
    if (particles) {
        for (int i=0; i<12; i++) {
            double age = particles == 1 ? fmod(phase + i*0.11, 0.6) : fmin(0.6, phase);
            double angle = i * (2*M_PI/12);
            double x = particles == 1 ? window->width/2 - 16 - age*24 : window->width/2 + cos(angle)*age*30;
            double y = particles == 1 ? window->height/2 + sin(i*2.4)*age*15 : window->height/2 + sin(angle)*age*30;
            double alpha = (0.6-age) * (particles == 2 ? 1.25 : 0.7);
            CGContextSetRGBFillColor(ctx, particles == 3 ? 0.48 : red,
                                     particles == 3 ? 0.48 : green, particles == 3 ? 0.48 : blue, alpha);
            CGContextFillEllipseInRect(ctx, CGRectMake(x, y, 2.2-age*2, 2.2-age*2));
        }
    }
    flush(window);
}
