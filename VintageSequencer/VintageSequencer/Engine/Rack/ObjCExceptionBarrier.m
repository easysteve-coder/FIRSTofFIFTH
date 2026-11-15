#import "ObjCExceptionBarrier.h"

#if DEBUG
bool (^_Nullable FoFConnectFaultHook)(AVAudioNode *node) = nil;
bool (^_Nullable FoFCleanupFaultHook)(AVAudioNode *node) = nil;
bool (^_Nullable FoFStopFaultHook)(void) = nil;
#define FOF_INJECT_STOP \
    if (FoFStopFaultHook && FoFStopFaultHook()) { @throw [NSException exceptionWithName:@"FoFInjectedFault" reason:@"injected stop" userInfo:nil]; }
#define FOF_INJECT(hook, node) \
    if (hook && hook(node)) { @throw [NSException exceptionWithName:@"FoFInjectedFault" reason:@"injected" userInfo:nil]; }
#else
#define FOF_INJECT(hook, node)
#define FOF_INJECT_STOP
#endif

static NSString *describe(NSException *e) {
    return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"-"];
}

NSString *_Nullable FoFEngineConnect(AVAudioEngine *engine, AVAudioNode *from, AVAudioNode *to,
                                     AVAudioFormat *_Nullable format) {
    @try {
        FOF_INJECT(FoFConnectFaultHook, from)
        FOF_INJECT(FoFConnectFaultHook, to)
        [engine connect:from to:to format:format];
        return nil;
    } @catch (NSException *e) { return describe(e); }
}

NSString *_Nullable FoFEngineDisconnectOutput(AVAudioEngine *engine, AVAudioNode *node) {
    @try { [engine disconnectNodeOutput:node]; return nil; }
    @catch (NSException *e) { return describe(e); }
}

NSString *_Nullable FoFEngineDisconnectInput(AVAudioEngine *engine, AVAudioNode *node) {
    @try {
        FOF_INJECT(FoFCleanupFaultHook, node)
        [engine disconnectNodeInput:node];
        return nil;
    } @catch (NSException *e) { return describe(e); }
}

NSString *_Nullable FoFEngineAttach(AVAudioEngine *engine, AVAudioNode *node) {
    @try { [engine attachNode:node]; return nil; }
    @catch (NSException *e) { return describe(e); }
}

NSString *_Nullable FoFEngineDetach(AVAudioEngine *engine, AVAudioNode *node) {
    @try {
        FOF_INJECT(FoFCleanupFaultHook, node)
        [engine detachNode:node];
        return nil;
    } @catch (NSException *e) { return describe(e); }
}

NSString *_Nullable FoFEnginePrepareAndStart(AVAudioEngine *engine, NSError *_Nullable *_Nullable error) {
    @try {
        [engine prepare];
        [engine startAndReturnError:error];
        return nil;
    } @catch (NSException *e) { return describe(e); }
}

NSString *_Nullable FoFEngineStop(AVAudioEngine *engine) {
    @try {
        FOF_INJECT_STOP
        [engine stop];
        return nil;
    }
    @catch (NSException *e) { return describe(e); }
}
