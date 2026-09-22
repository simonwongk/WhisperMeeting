#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an `NSError` instead of an abort (F374).
///
/// Swift cannot catch an `NSException`. An uncaught one reaches `objc_terminate` and the process
/// aborts — which is what happened twice on 2026-09-21 (F356), from `installTapOnBus`. The Swift
/// side of AVFoundation offers no way to opt out: `AVAudioEngine.h` says outright that performing
/// input when it is unavailable "will cause the engine to throw an error (when possible) **or an
/// exception**", and the caller does not choose which.
///
/// F356's own fix — decline to supply a format, so there is nothing for AVFAudio to reject — closed
/// one call. It does not generalise: `engine.start()` validates the live device with nothing the
/// caller can decline (F374), and every future AVFoundation call has the same shape. `@try/@catch`
/// is the only thing that closes the class, and it has to be written in Objective-C.
///
/// **On the standing objection to catching `NSException`.** Apple's guidance is that an exception
/// signals a programmer error and the process state after one is undefined. That is the right
/// default and it is why this is a narrow bridge rather than a general-purpose wrapper: the callers
/// here raise on a *device* condition they cannot pre-check — the hardware changed between the
/// check and the call — which is not a programmer error, and the alternative on offer is not a
/// clean abort but an abort with no explanation for the user. The recovery is always the same and
/// always conservative: abandon the capture and say so.
///
/// Returns `YES` when `block` completed. On `NO`, `error` (when non-NULL) carries the exception's
/// reason as `NSLocalizedDescriptionKey` and its name under `WMObjCExceptionNameKey`.
BOOL WMRunCatchingObjCExceptions(void (NS_NOESCAPE ^block)(void), NSError **_Nullable error);

/// `userInfo` key holding the raised `NSExceptionName`.
extern NSString *const WMObjCExceptionNameKey;

/// The `NSError` domain used for a converted exception.
extern NSString *const WMObjCExceptionErrorDomain;

NS_ASSUME_NONNULL_END
