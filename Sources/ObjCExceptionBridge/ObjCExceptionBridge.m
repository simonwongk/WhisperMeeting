#import "include/ObjCExceptionBridge.h"

NSString *const WMObjCExceptionNameKey = @"WMObjCExceptionName";
NSString *const WMObjCExceptionErrorDomain = @"WhisperMeet.ObjCException";

BOOL WMRunCatchingObjCExceptions(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            // The reason is the line that matters. For the F356 aborts it was
            // "required condition is false: format.sampleRate == hwFormat.sampleRate", and it was
            // NOT in the .ips crash report — `asi` there said only "abort() called". Recovering it
            // needed `log show`, which nobody would think to run (F370).
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[WMObjCExceptionNameKey] = exception.name;
            *error = [NSError errorWithDomain:WMObjCExceptionErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
