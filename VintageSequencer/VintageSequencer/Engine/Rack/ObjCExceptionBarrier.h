// Fehlergrenze für AVAudioEngine-Aufrufe, die ObjC-Ausnahmen werfen (v1.18.38).
//
// Jede Funktion führt genau eine Framework-Operation in @try aus; zwischen Wurfstelle und
// @catch liegt kein Swift-Code (Apple: ObjC-Ausnahmen nur in Objective-C behandeln).
// Rückgabe: nil bei Erfolg, sonst Beschreibung der Ausnahme. Nur Main, nie Tick/Render.
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *_Nullable FoFEngineConnect(AVAudioEngine *engine, AVAudioNode *from, AVAudioNode *to,
                                     AVAudioFormat *_Nullable format);
NSString *_Nullable FoFEngineDisconnectOutput(AVAudioEngine *engine, AVAudioNode *node);
NSString *_Nullable FoFEngineDisconnectInput(AVAudioEngine *engine, AVAudioNode *node);
NSString *_Nullable FoFEngineAttach(AVAudioEngine *engine, AVAudioNode *node);
NSString *_Nullable FoFEngineDetach(AVAudioEngine *engine, AVAudioNode *node);
/// prepare + start. Ein NSError von `start` kommt über `error`, eine Ausnahme als Rückgabe.
NSString *_Nullable FoFEnginePrepareAndStart(AVAudioEngine *engine, NSError *_Nullable *_Nullable error);
NSString *_Nullable FoFEngineStop(AVAudioEngine *engine);

#if DEBUG
/// Tests: trifft der Block auf einen der Knoten zu, wirft `FoFEngineConnect` innerhalb seines
/// @try (Fehlerinjektion an der Stelle des echten Aufrufs). nil = aus.
extern bool (^_Nullable FoFConnectFaultHook)(AVAudioNode *node);
/// Tests: wie oben für `FoFEngineDetach` und `FoFEngineDisconnectInput` (Aufräumfehler).
extern bool (^_Nullable FoFCleanupFaultHook)(AVAudioNode *node);
/// Tests: `FoFEngineStop` wirft, solange der Block true liefert.
extern bool (^_Nullable FoFStopFaultHook)(void);
#endif

NS_ASSUME_NONNULL_END
