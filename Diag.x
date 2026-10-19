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
static id dg_call_obj(id obj, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

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

__attribute__((unused)) static void dg_dump_methods(void) {
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

// Drag/drop placement classes in SpringBoardHome: which code snaps a widget
// to a cell before the list model is asked.
__attribute__((unused)) static void dg_dump_drag_classes(void) {
    Class ref = objc_getClass("SBIconListModel");
    const char *image = ref ? class_getImageName(ref) : NULL;
    if (!image) { DL(@"## drag dump: no image"); return; }
    unsigned count = 0;
    const char **names = objc_copyClassNamesForImage(image, &count);
    NSRegularExpression *clsRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)drag|drop|snap|placement|reorder|insertion|quad" options:0 error:nil];
    NSRegularExpression *selRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)grid|cell|coordinate|index|range|point|location|snap|quad|align|insert|drop|target"
        options:0 error:nil];
    DL(@"## drag dump: %u classes in %s", count, image);
    for (unsigned c = 0; c < count; c++) {
        NSString *cn = @(names[c]);
        BOOL isListView = [cn isEqualToString:@"SBIconListView"];
        if (!isListView && ![clsRe firstMatchInString:cn options:0 range:NSMakeRange(0, cn.length)]) continue;
        Class cls = objc_getClass(names[c]);
        if (!cls) continue;
        NSMutableArray *lines = [NSMutableArray array];
        unsigned n = 0;
        Method *list = class_copyMethodList(cls, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *sel = NSStringFromSelector(method_getName(list[i]));
            if (isListView) {
                // grid/cell methods of the list view were dumped before; only drag ones here
                if ([sel rangeOfString:@"rag" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                    [sel rangeOfString:@"drop" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                    [sel rangeOfString:@"snap" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            } else if (![selRe firstMatchInString:sel options:0 range:NSMakeRange(0, sel.length)]) continue;
            [lines addObject:[NSString stringWithFormat:@"  -%@  %s", sel, method_getTypeEncoding(list[i])]];
        }
        free(list);
        if (!lines.count) continue;
        [lines sortUsingSelector:@selector(compare:)];
        DL(@"## class %@ : %@", cn, NSStringFromClass(class_getSuperclass(cls)));
        for (NSString *l in lines) dg_log(l);
    }
    free(names);
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

// ---- drag tracing: what cell iOS proposes / accepts for a widget ----
typedef struct { unsigned long long start; DGGridSize size; } DGGridRange;

static BOOL dg_is_widget(id icon) {
    NSString *c = dg_call(icon, @"gridSizeClass", nil);
    return c.length && ![c containsString:@"Default"] && ![c isEqualToString:@"-"];
}

static NSString *dg_last_trace = nil;
static void dg_trace(NSString *line) {
    if ([line isEqualToString:dg_last_trace]) return;
    dg_last_trace = line;
    dg_log(line);
}
#define DT(fmt, ...) dg_trace([NSString stringWithFormat:fmt, ##__VA_ARGS__])

%group DiagDrag
%hook SBIconListView
- (DGGridRange)closestGridRangeForIconOfSize:(DGGridSize)size centeredAtPoint:(CGPoint)pt {
    DGGridRange r = %orig;
    if (size.columns > 1 || size.rows > 1)
        DT(@"view closestGridRange size=%ux%u pt=(%.0f,%.0f) -> start=%llu %ux%u", size.columns, size.rows,
           pt.x, pt.y, r.start, r.size.columns, r.size.rows);
    return r;
}
- (unsigned long long)bestGridCellIndexForInsertingIcon:(id)icon atCoordinate:(DGCoordinate)c {
    unsigned long long r = %orig;
    if (dg_is_widget(icon)) DT(@"view bestCellForInserting coord=(c%lld,r%lld) -> %llu", c.col, c.row, r);
    return r;
}
%end

%hook SBIconDragManager
- (unsigned long long)placeholderGridCellIndexForDragPlacement:(long long)place onGridCellIndex:(unsigned long long)cell icon:(id)icon inListView:(id)lv forDragWithIdentifier:(id)ident {
    unsigned long long r = %orig;
    if (dg_is_widget(icon)) DT(@"mgr placeholderCell place=%lld on=%llu -> %llu (lv %p icon %@ %p)", place, cell, r, lv, [icon class], icon);
    return r;
}
- (long long)placeholderMovementForDragHitRegion:(unsigned long long)region onGridCellIndex:(unsigned long long)cell inListView:(id)lv forDragWithIdentifier:(id)ident draggedIconIdentifiers:(id)ids {
    long long r = %orig;
    DT(@"mgr placeholderMovement region=%llu on=%llu -> %lld", region, cell, r);
    return r;
}
- (BOOL)movePlaceholderForDraggedIcons:(NSArray *)icons toGridCellIndex:(unsigned long long)cell inListView:(id)lv forDragWithIdentifier:(id)ident {
    BOOL r = %orig;
    BOOL w = NO; for (id i in icons) w |= dg_is_widget(i);
    if (w) DT(@"mgr movePlaceholder to=%llu -> %d", cell, r);
    return r;
}
- (void)iconListView:(id)lv performIconDrop:(id)drop {
    DT(@"mgr performIconDrop begin lv %p", lv);
    %orig;
    DT(@"mgr performIconDrop end");
}
- (BOOL)isSnapToGridEnabledForDragWithIdentifier:(id)ident iconLocation:(id)loc listModel:(id)model placeholderGridSizeClass:(id)cls {
    BOOL r = %orig;
    DT(@"mgr snapToGrid cls=%@ -> %d", cls, r);
    return r;
}
%end

%hook SBIconListView
- (unsigned long long)dragHitRegionForPoint:(CGPoint)pt icon:(id)icon {
    unsigned long long r = %orig;
    if (dg_is_widget(icon)) DT(@"view hitRegion pt=(%.0f,%.0f) -> %llu", pt.x, pt.y, r);
    return r;
}
%end

%hook SBIconListViewPlaceholderAssertion
- (unsigned long long)effectiveGridCellIndex {
    unsigned long long r = %orig;
    id icon = dg_call_obj(self, @"placeholderIcon");
    if (dg_is_widget(icon)) {
        id lv = dg_call_obj(self, @"listView");
        id model = dg_call_obj(lv, @"model");
        unsigned long long opts = [lv respondsToSelector:@selector(gridCellInfoOptions)]
            ? ((unsigned long long (*)(id, SEL))objc_msgSend)(lv, @selector(gridCellInfoOptions)) : 0;
        unsigned long long mc = [model respondsToSelector:@selector(gridCellIndexForIcon:gridCellInfoOptions:)]
            ? ((unsigned long long (*)(id, SEL, id, unsigned long long))objc_msgSend)(model, @selector(gridCellIndexForIcon:gridCellInfoOptions:), icon, opts) : NSNotFound;
        unsigned long long iv = ((unsigned long long (*)(id, SEL))objc_msgSend)(self, @selector(gridCellIndex));
        DT(@"assert effectiveCell -> %llu (ivar %llu model %llu opts %llu)", r, iv, mc, opts);
    }
    return r;
}
- (void)setGridCellIndex:(unsigned long long)cell {
    DT(@"assert setGridCellIndex %llu", cell);
    %orig;
}
%end

%hook SBIconListModel
- (unsigned long long)bestGridCellIndexForMovingIcons:(NSArray *)icons toGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    unsigned long long r = %orig;
    BOOL w = NO; for (id i in icons) w |= dg_is_widget(i);
    if (w) DT(@"model bestCellForMoving to=%llu opts=%llu mut=%llu -> %llu", cell, o, m, r);
    return r;
}
- (BOOL)isInsertionFixedForIcon:(id)icon atGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    BOOL r = %orig;
    if (dg_is_widget(icon)) DT(@"model isInsertionFixed cell=%llu -> %d", cell, r);
    return r;
}
- (BOOL)_moveContainedIconWithinAffectedQuadsIfNecessary:(id)icon toGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    BOOL r = %orig;
    if (dg_is_widget(icon)) DT(@"model moveWithinQuads cell=%llu -> %d", cell, r);
    return r;
}
- (BOOL)_moveContainedIconLargerThanQuadsIfNecessary:(id)icon toGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    BOOL r = %orig;
    if (dg_is_widget(icon)) DT(@"model moveLargerThanQuads cell=%llu -> %d", cell, r);
    return r;
}
- (id)moveContainedIcon:(id)icon toGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    if (dg_is_widget(icon)) DT(@"model moveContainedIcon -> cell=%llu opts=%llu mut=%llu", cell, o, m);
    id r = %orig;
    return r;
}
- (id)insertIcon:(id)icon atGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    if (dg_is_widget(icon)) DT(@"model insertIcon cell=%llu opts=%llu mut=%llu", cell, o, m);
    return %orig;
}
- (long long)_moveIcon:(id)icon byClusteringForSizeClass:(id)cls toGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o {
    long long r = %orig;
    if (dg_is_widget(icon)) DT(@"model moveByClustering cell=%llu cls=%@ -> %lld", cell, cls, r);
    return r;
}
- (id)insertIconWhilePreservingQuads:(id)icon toGridCellIndex:(unsigned long long)cell gridCellInfoOptions:(unsigned long long)o mutationOptions:(unsigned long long)m {
    if (dg_is_widget(icon)) DT(@"model insertPreservingQuads cell=%llu", cell);
    return %orig;
}
%end
%end

// Movement strategies inside -[SBIconListModel moveContainedIcon:...]. Hooked
// by hand, and only when the return type is BOOL, so a wrong guess cannot crash.
typedef BOOL (*dg_move5_fn)(id, SEL, id, unsigned long long, id, unsigned long long, unsigned long long);
#define DG_MOVE5(name, label) \
    static dg_move5_fn dg_o_##name; \
    static BOOL dg_h_##name(id self, SEL _cmd, id icon, unsigned long long cell, id info, \
                            unsigned long long o, unsigned long long m) { \
        BOOL r = dg_o_##name(self, _cmd, icon, cell, info, o, m); \
        if (dg_is_widget(icon)) DT(@"model " label " cell=%llu mut=%llu -> %d", cell, m, r); \
        return r; \
    }
DG_MOVE5(autoCluster, "autoCluster")
DG_MOVE5(simple, "simpleMove")
DG_MOVE5(twoD, "twoDMove")
DG_MOVE5(swapV, "swapVertically")

static void dg_hook_move5(const char *selName, IMP h, dg_move5_fn *o) {
    Class c = objc_getClass("SBIconListModel");
    SEL sel = sel_registerName(selName);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    DL(@"hook %s enc=%s", selName, enc ?: "missing");
    if (enc && enc[0] == 'B' && method_getNumberOfArguments(m) == 7)
        MSHookMessageEx(c, sel, h, (IMP *)o);
}

static void dg_install_move_hooks(void) {
    dg_hook_move5("_moveContainedIconUsingAutomaticClusteringIfNecessary:toGridCellIndex:gridCellInfo:gridCellInfoOptions:mutationOptions:",
                  (IMP)dg_h_autoCluster, &dg_o_autoCluster);
    dg_hook_move5("_moveContainedIconUsingSimpleMovement:toGridCellIndex:gridCellInfo:gridCellInfoOptions:mutationOptions:",
                  (IMP)dg_h_simple, &dg_o_simple);
    dg_hook_move5("_moveContainedIconUsingTwoDimensionalMovement:toGridCellIndex:gridCellInfo:gridCellInfoOptions:mutationOptions:",
                  (IMP)dg_h_twoD, &dg_o_twoD);
    dg_hook_move5("_moveContainedIconBySwappingVerticallyWithAdjacentIcons:toGridCellIndex:gridCellInfo:gridCellInfoOptions:mutationOptions:",
                  (IMP)dg_h_swapV, &dg_o_swapV);
}

static void dg_find_methods(const char *clsName, NSArray *needles) {
    Class c = objc_getClass(clsName);
    if (!c) { DL(@"methods %s: class missing", clsName); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromSelector(method_getName(ms[i]));
        for (NSString *needle in needles) {
            if ([name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                DL(@"method -[%s %@] %s", clsName, name, method_getTypeEncoding(ms[i]));
                break;
            }
        }
    }
    free(ms);
}

typedef id (*dg_path_fn)(id, SEL, id);
static dg_path_fn dg_o_placeholderPath;
static id dg_h_placeholderPath(id self, SEL _cmd, id ident) {
    id r = dg_o_placeholderPath(self, _cmd, ident);
    DT(@"mgr placeholderGridPath -> %@", r);
    return r;
}
typedef BOOL (*dg_drop5_fn)(id, SEL, id, id, id, id, id);
static dg_drop5_fn dg_o_dropDest;
static BOOL dg_h_dropDest(id self, SEL _cmd, id icons, id lv, id path, id cls, id session) {
    DT(@"mgr dropInDestination path=%@ cls=%@", path, cls);
    BOOL r = dg_o_dropDest(self, _cmd, icons, lv, path, cls, session);
    DT(@"mgr dropInDestination -> %d", r);
    return r;
}

static void dg_install_drop_hooks(void) {
    Class c = objc_getClass("SBIconDragManager");
    SEL s1 = sel_registerName("dragPlaceholderGridPathForDragWithIdentifier:");
    Method m1 = c ? class_getInstanceMethod(c, s1) : NULL;
    DL(@"hook placeholderGridPath enc=%s", m1 ? method_getTypeEncoding(m1) : "missing");
    if (m1 && method_getTypeEncoding(m1)[0] == '@' && method_getNumberOfArguments(m1) == 3)
        MSHookMessageEx(c, s1, (IMP)dg_h_placeholderPath, (IMP *)&dg_o_placeholderPath);
    SEL s2 = sel_registerName("performIconDropInDestinationListIfPossibleWithDraggedIcons:inIconListView:placeholderGridPath:placeholderGridSizeClass:dropSession:");
    Method m2 = c ? class_getInstanceMethod(c, s2) : NULL;
    DL(@"hook dropInDestination enc=%s", m2 ? method_getTypeEncoding(m2) : "missing");
    if (m2 && method_getTypeEncoding(m2)[0] == 'B' && method_getNumberOfArguments(m2) == 7)
        MSHookMessageEx(c, s2, (IMP)dg_h_dropDest, (IMP *)&dg_o_dropDest);
}

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
    %init(DiagDrag);
    dg_install_move_hooks();
    dg_install_drop_hooks();
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
        dg_find_methods("SBIconDragManager", @[@"drop", @"path", @"gridcell", @"placeholder"]);
        dg_find_methods("SBIconListModel", @[@"gridCellIndexFor", @"placeholder", @"gridPath"]);
        dg_find_methods("SBIconListView", @[@"gridCellIndexFor", @"gridPath", @"placeholder"]);
        dg_schedule_snapshot(@"launch");
    });
}
