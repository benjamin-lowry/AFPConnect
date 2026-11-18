//
//  AFPFSItem.m
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-06.
//

#import "AFPFSItem.h"

#import <os/lock.h>

/// Only the holder of this lock is allowed to change an item's name or parent (i.e. any action that would cause fs paths to change)
static os_unfair_lock pathLock = OS_UNFAIR_LOCK_INIT;

@implementation AFPFSItem {
    os_unfair_lock _earlyLock;
    struct afp_file_info *_earlyFork;
    NSMutableSet<NSString *> *_missed;
    BOOL _missedMore;
}

@synthesize parent = _parent;
@synthesize name = _name;

- (AFPFSItem *)parent
{
    os_unfair_lock_lock(&pathLock);
    AFPFSItem *parent = _parent;
    os_unfair_lock_unlock(&pathLock);
    return parent;
}

- (NSString *)name
{
    os_unfair_lock_lock(&pathLock);
    NSString *name = _name;
    os_unfair_lock_unlock(&pathLock);
    return name;
}

- (void)setParent:(AFPFSItem *)parent name:(NSString *)name
{
    NSString *copy = [name copy];
    os_unfair_lock_lock(&pathLock);
    _parent = parent;
    _name = copy;
    _placedAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&pathLock);
}

- (void)holdEarlyFork:(struct afp_file_info *)fork
{
    os_unfair_lock_lock(&_earlyLock);
    _earlyFork = fork;
    os_unfair_lock_unlock(&_earlyLock);
}

- (struct afp_file_info *)takeEarlyFork
{
    os_unfair_lock_lock(&_earlyLock);
    struct afp_file_info *fork = _earlyFork;
    _earlyFork = NULL;
    os_unfair_lock_unlock(&_earlyLock);
    return fork;
}

- (void)noteMissedName:(NSString *)name
{
    @synchronized (self) {
        if (_missed.count >= 1024) {
            _missedMore = YES;
            return;
        }
        _missed = _missed ?: [NSMutableSet set];
        [_missed addObject:name];
    }
}

- (BOOL)takeMissedNamesIn:(NSArray<NSString *> *)names
{
    @synchronized (self) {
        BOOL hit = _missedMore;
        for (NSString *name in names) {
            if ([_missed containsObject:name]) {
                [_missed removeObject:name];
                hit = YES;
            }
        }
        if (_missedMore) {
            _missed = nil;
            _missedMore = NO;
        }
        return hit;
    }
}

- (instancetype)initWithCNID:(uint32_t)cnid name:(NSString *)name parent:(AFPFSItem *)parent
                 isDirectory:(BOOL)isDirectory
{
    self = [super init];
    if (self) {
        _kind = AFPFSItemKindNode;
        _cnid = cnid;
        _itemID = cnid;
        _name = [name copy];
        _parent = parent;
        _placedAt = CFAbsoluteTimeGetCurrent();
        _isDirectory = isDirectory;
    }
    return self;
}

- (instancetype)initDoubleOf:(AFPFSItem *)base
{
    self = [super init];
    if (self) {
        _kind = AFPFSItemKindDouble;
        _cnid = base.cnid;
        _itemID = base.blind ? AFPFSBlindDoubleID(base.itemID) : AFPFSDoubleID(base.cnid);
        _base = base;
        _name = [@"._" stringByAppendingString:base.name];
        _parent = base.parent;
        _placedAt = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (instancetype)initBlindNamed:(NSString *)name parent:(AFPFSItem *)parent itemID:(FSItemID)itemID
                   isDirectory:(BOOL)isDirectory
{
    self = [super init];
    if (self) {
        _kind = AFPFSItemKindNode;
        _itemID = itemID;
        _name = [name copy];
        _parent = parent;
        _placedAt = CFAbsoluteTimeGetCurrent();
        _isDirectory = isDirectory;
        _blind = YES;
        clock_gettime(CLOCK_REALTIME, &_blindTime);
    }
    return self;
}

- (NSString *)path
{
    if (_kind == AFPFSItemKindDouble) {
        return _base.path;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    os_unfair_lock_lock(&pathLock);
    for (AFPFSItem *item = self; item->_parent; item = item->_parent) {
        [parts addObject:item->_name];
    }
    os_unfair_lock_unlock(&pathLock);
    if (!parts.count) {
        return @"/";
    }
    return [@"/" stringByAppendingString:[parts.reverseObjectEnumerator.allObjects componentsJoinedByString:@"/"]];
}

@end
