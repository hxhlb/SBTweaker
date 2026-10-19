// Diagnostic build only (make SBT_DIAG=1) — never part of a release.
//
// Records how iOS 18 SpringBoard lays out Home Screen pages so widget
// placement with a custom row count can be fixed from facts:
//  - once after launch: the grid-related method names and type encodings of
//    the list model / list view / layout configuration classes
//  - after every layout change: a snapshot of each Home Screen page — view
//    grid vs. model grid and every icon's cell index, size and fixed location
// Everything is called only after checking the method exists and its type
// encoding is one this file knows how to call, so a different iOS version
// logs "n/a" instead of crashing SpringBoard.
//
// Log: /var/mobile/Documents/SBTweakerDiag.log

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef struct { unsigned short columns; unsigned short rows; } DGGridSize;
typedef struct { long long col; long long row; } DGCoordinate;

static FILE *dg_file = NULL;

static void dg_log(NSString *msg) {
    if (!dg_file) return;
    fprintf(dg_file, "%s\n", msg.UTF8String);
    fflush(dg_file);
}

#define DL(fmt, ...) dg_log([NSString stringWithFormat:fmt, ##__VA_ARGS__])

static NSString *dg_short(id obj, NSUInteger max) {
    NSString *d = [[obj description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return d.length > max ? [[d substringToIndex:max] stringByAppendingString:@"…"] : d;
}

// Calls a getter (no args) or a one-object-argument method, if its return
// type is one we can call safely. Returns a printable value.
static NSString *dg_call(id obj, NSString *name, id arg) {
    if (!obj) return @"nil";
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) return @"-";
    unsigned args = method_getNumberOfArguments(m);
    if (args != (arg ? 3u : 2u)) return [NSString stringWithFormat:@"argc%u", args];
    if (arg) {
        char a[64] = {0};
        method_getArgumentType(m, 2, a, sizeof a);
        if (a[0] != '@') return [NSString stringWithFormat:@"arg:%s", a];
    }
    char r[128] = {0};
    method_getReturnType(m, r, sizeof r);
    @try {
        switch (r[0]) {
            case '@': {
                id v = arg ? ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                           : ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                return v ? dg_short(v, 400) : @"nil";
            }
            case 'B': case 'c': {
                BOOL v = arg ? ((BOOL (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                             : ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
                return v ? @"YES" : @"NO";
            }
            case 'Q': case 'q': case 'L': case 'l': {
                long long v = arg ? ((long long (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                                  : ((long long (*)(id, SEL))objc_msgSend)(obj, sel);
                return [NSString stringWithFormat:@"%lld", v];
            }
            case 'I': case 'i': case 'S': case 's': {
                int v = arg ? ((int (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                            : ((int (*)(id, SEL))objc_msgSend)(obj, sel);
                return [NSString stringWithFormat:@"%d", v];
            }
            case 'd': {
                double v = arg ? ((double (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                               : ((double (*)(id, SEL))objc_msgSend)(obj, sel);
                return [NSString stringWithFormat:@"%.2f", v];
            }
            case '{': {
                if (strstr(r, "=SS}")) {
                    DGGridSize g = arg ? ((DGGridSize (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                                       : ((DGGridSize (*)(id, SEL))objc_msgSend)(obj, sel);
                    return [NSString stringWithFormat:@"%ux%u", g.columns, g.rows];
                }
                if (strstr(r, "=qq}")) {
                    DGCoordinate c = arg ? ((DGCoordinate (*)(id, SEL, id))objc_msgSend)(obj, sel, arg)
                                         : ((DGCoordinate (*)(id, SEL))objc_msgSend)(obj, sel);
                    return [NSString stringWithFormat:@"(c%lld,r%lld)", c.col, c.row];
                }
                return [NSString stringWithFormat:@"enc:%s", r];
            }
            default:
                return [NSString stringWithFormat:@"enc:%s", r];
        }
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"EXC:%@", e.name];
    }
}

static void dg_dump_methods(void) {
    NSArray *classes = @[@"SBIconListModel", @"SBIconListView", @"SBRootIconListView",
                         @"SBIconListGridLayoutConfiguration", @"SBIconListGridLayout",
                         @"SBHIconGridSizeClassSizeMap", @"SBIconListFlowLayout",
                         @"SBHIconManager", @"SBHIconModel", @"SBFolder", @"SBRootFolder"];
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)grid|gap|fixed|cell|coordinate|rows|columns|maxNumber|maxIcon|maxList|placement|cluster|reflow|backfill"
        options:0 error:nil];
    for (NSString *name in classes) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) { DL(@"## class %@ missing", name); continue; }
        DL(@"## class %@ : %@", name, NSStringFromClass(class_getSuperclass(cls)));
        unsigned n = 0;
        Method *list = class_copyMethodList(cls, &n);
        NSMutableArray *lines = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            NSString *sel = NSStringFromSelector(method_getName(list[i]));
            if (![re firstMatchInString:sel options:0 range:NSMakeRange(0, sel.length)]) continue;
            [lines addObject:[NSString stringWithFormat:@"  -%@  %s", sel, method_getTypeEncoding(list[i])]];
        }
        free(list);
        [lines sortUsingSelector:@selector(compare:)];
        for (NSString *l in lines) dg_log(l);
    }
}

// Which image implements a method now — SBTweaker.dylib means our hook is
// installed, SpringBoardHome means it is not.
static void dg_report_hook(const char *cls, const char *sel) {
    Class c = objc_getClass(cls);
    Method m = c ? class_getInstanceMethod(c, sel_registerName(sel)) : NULL;
    if (!m) { DL(@"hook -[%s %s]: method missing", cls, sel); return; }
    Dl_info info = {0};
    dladdr((const void *)method_getImplementation(m), &info);
    DL(@"hook -[%s %s]: enc=%s impl in %s", cls, sel, method_getTypeEncoding(m),
       info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?");
}

static NSString *dg_icon_name(id icon) {
    for (NSString *s in @[@"applicationBundleID", @"leafIdentifier", @"uniqueIdentifier", @"nodeIdentifier"]) {
        NSString *v = dg_call(icon, s, nil);
        if (![v isEqualToString:@"-"] && ![v isEqualToString:@"nil"]) return v;
    }
    return NSStringFromClass([icon class]);
}

static NSString *dg_snapshot(void) {
    NSMutableString *out = [NSMutableString string];
    id ctrl = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("SBIconController"), sel_registerName("sharedInstance"));
    id mgr = [ctrl respondsToSelector:sel_registerName("iconManager")]
        ? ((id (*)(id, SEL))objc_msgSend)(ctrl, sel_registerName("iconManager")) : nil;
    id root = [mgr respondsToSelector:sel_registerName("rootFolderController")]
        ? ((id (*)(id, SEL))objc_msgSend)(mgr, sel_registerName("rootFolderController")) : nil;
    if (![root respondsToSelector:sel_registerName("iconListViewCount")]) return @"(no root folder controller)";
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(root, sel_registerName("iconListViewCount"));
    for (NSUInteger p = 0; p < MIN(count, 20); p++) {
        UIView *lv = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(root, sel_registerName("iconListViewAtIndex:"), p);
        if (!lv) continue;
        id model = [lv respondsToSelector:sel_registerName("model")]
            ? ((id (*)(id, SEL))objc_msgSend)(lv, sel_registerName("model")) : nil;
        [out appendFormat:@"-- page %lu view=%@ loc=%@ bounds=%.0fx%.0f\n", (unsigned long)p,
            NSStringFromClass([lv class]), dg_call(lv, @"iconLocation", nil),
            lv.bounds.size.width, lv.bounds.size.height];
        [out appendFormat:@"   view: gridSizeForCurrentOrientation=%@ bounded=%@ rows=%@ cols=%@ rowsSpacing=%@ colsSpacing=%@\n",
            dg_call(lv, @"gridSizeForCurrentOrientation", nil), dg_call(lv, @"boundedGridSizeForCurrentOrientation", nil),
            dg_call(lv, @"iconRowsForCurrentOrientation", nil), dg_call(lv, @"iconColumnsForCurrentOrientation", nil),
            dg_call(lv, @"iconRowsForSpacingCalculation", nil), dg_call(lv, @"iconsInRowForSpacingCalculation", nil)];
        id layout = [lv respondsToSelector:sel_registerName("layout")]
            ? ((id (*)(id, SEL))objc_msgSend)(lv, sel_registerName("layout")) : nil;
        id cfg = [layout respondsToSelector:sel_registerName("layoutConfiguration")]
            ? ((id (*)(id, SEL))objc_msgSend)(layout, sel_registerName("layoutConfiguration")) : nil;
        [out appendFormat:@"   cfg %p: portrait %@x%@\n", cfg,
            dg_call(cfg, @"numberOfPortraitColumns", nil), dg_call(cfg, @"numberOfPortraitRows", nil)];
        [out appendFormat:@"   model %@ %p: gridSize=%@ initial=%@ whenNonDefault=%@ bounded=%@ max=%@ icons=%@ usedRows=%@ usedCols=%@ usedCells=%@\n",
            NSStringFromClass([model class]), model,
            dg_call(model, @"gridSize", nil), dg_call(model, @"initialGridSize", nil),
            dg_call(model, @"gridSizeWhenDirectlyContainingNonDefaultSizedIcons", nil),
            @"-", dg_call(model, @"maxNumberOfIcons", nil), dg_call(model, @"numberOfIcons", nil),
            dg_call(model, @"numberOfUsedRows", nil), dg_call(model, @"numberOfUsedColumns", nil),
            dg_call(model, @"numberOfUsedGridCells", nil)];
        [out appendFormat:@"   model fixed: allows=%@ has=%@ allFixed=%@ behavior=%@ requiresSome=%@ gaps=%@ nonDefault=%@\n",
            dg_call(model, @"allowsFixedIconLocations", nil), dg_call(model, @"hasFixedIconLocations", nil),
            dg_call(model, @"areAllIconsFixed", nil), dg_call(model, @"fixedIconLocationBehavior", nil),
            dg_call(model, @"requiresSomeFixedIconLocations", nil), dg_call(model, @"allowedGapsLayoutDescription", nil),
            dg_call(model, @"directlyContainsNonDefaultSizeClassIcon", nil)];
        [out appendFormat:@"   model fixedIconLocations=%@\n", dg_call(model, @"fixedIconLocations", nil)];
        NSArray *icons = [model respondsToSelector:sel_registerName("icons")]
            ? ((id (*)(id, SEL))objc_msgSend)(model, sel_registerName("icons")) : nil;
        NSUInteger i = 0;
        for (id icon in icons) {
            [out appendFormat:@"   [%lu] %@ size=%@ cell=%@ coord=%@ gridSize=%@ fixed=%@ fixedLoc=%@\n",
                (unsigned long)i++, dg_icon_name(icon), dg_call(icon, @"gridSizeClass", nil),
                dg_call(lv, @"gridCellIndexForIcon:", icon), dg_call(lv, @"coordinateForIcon:", icon),
                dg_call(model, @"gridSizeForIcon:", icon), dg_call(model, @"isIconFixed:", icon),
                dg_call(model, @"fixedLocationForIcon:", icon)];
        }
    }
    return out;
}

static NSString *dg_last_snapshot = nil;
static NSUInteger dg_snapshot_token = 0;

static void dg_schedule_snapshot(NSString *reason) {
    NSUInteger token = ++dg_snapshot_token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != dg_snapshot_token) return;
        NSString *snap = dg_snapshot();
        if ([snap isEqualToString:dg_last_snapshot]) return;
        dg_last_snapshot = snap;
        DL(@"=== snapshot %@ (%@)", [NSDate date], reason);
        dg_log(snap);
    });
}

%group Diag
%hook SBIconListView
- (void)layoutSubviews {
    %orig;
    dg_schedule_snapshot(@"layout");
}
%end
%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
    NSString *path = @"/var/mobile/Documents/SBTweakerDiag.log";
    dg_file = fopen(path.fileSystemRepresentation, "a");
    if (!dg_file) {
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SBTweakerDiag.log"];
        dg_file = fopen(path.fileSystemRepresentation, "a");
    }
    NSLog(@"[SBT:DIAG] log %@ open=%d", path, dg_file != NULL);
    if (!dg_file) return;
    %init(Diag);
    NSDictionary *prefs = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, CFSTR("cz.kolbi.sbtweaker"),
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    DL(@"\n##### SpringBoard start %@ iOS %@", [NSDate date], [UIDevice currentDevice].systemVersion);
    DL(@"prefs enabled=%@ homeGridEnabled=%@ hsCols=%@ hsRows=%@ homeGridLandscapeEnabled=%@",
       prefs[@"enabled"], prefs[@"homeGridEnabled"], prefs[@"hsCols"], prefs[@"hsRows"],
       prefs[@"homeGridLandscapeEnabled"]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dg_report_hook("SBHIconManager", "listGridSizeForFolderClass:");
        dg_report_hook("SBHIconManager", "listWithNonDefaultSizedIconsGridSizeForFolderClass:");
        dg_report_hook("SBHIconModel", "listGridSizeForFolderClass:");
        dg_dump_methods();
        dg_schedule_snapshot(@"launch");
    });
}
