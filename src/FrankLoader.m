//
//  FrankLoader.m
//  FrankFramework
//
//  Created by Pete Hodgson on 8/12/11.
//  Copyright 2011 ThoughtWorks. All rights reserved.
//

#import "FrankLoader.h"

#import "FrankServer.h"

#import <dlfcn.h>

#import "DDLog.h"
#import "DDTTYLogger.h"

#if !TARGET_OS_IPHONE
#import "AccessibilityCheckCommand.h"
#import "NSApplication+FrankAutomation.h"
#endif


BOOL frankLogEnabled = NO;

static void * loadDylib(NSString *path)
{
    NSDictionary *environment = [[NSProcessInfo processInfo] environment];
    NSString *simulatorRoot = [environment objectForKey:@"IPHONE_SIMULATOR_ROOT"];
    if (simulatorRoot) {
        path = [simulatorRoot stringByAppendingPathComponent:path];
    }

	NSLog(@"Attempting to open the library at '%@'", path);
    return dlopen([path fileSystemRepresentation], RTLD_LOCAL | RTLD_LAZY );
}

@implementation FrankLoader

+ (void)applicationDidBecomeActive:(NSNotification *)notification{
    static dispatch_once_t frankDidBecomeActiveToken;
#if TARGET_OS_IPHONE
    dispatch_once(&frankDidBecomeActiveToken, ^{
        FrankServer *server = [[FrankServer alloc] initWithDefaultBundle];
        [server startServer];
    });
#else
    dispatch_once(&frankDidBecomeActiveToken, ^{
        FrankServer *server = [[FrankServer alloc] initWithDefaultBundle];
        [server startServer];
        
        [[NSApplication sharedApplication] FEX_startTrackingMenus];
        
        [[NSNotificationCenter defaultCenter] removeObserver: [self class]
                                                        name: NSApplicationDidUpdateNotification
                                                      object: nil];
        
        [AccessibilityCheckCommand accessibilitySeemsToBeTurnedOn];
    });
#endif
}

+ (void)load{
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
    
    NSLog(@"Injecting Frank loader");
    
    NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];
    void *appSupportLibrary = loadDylib(@"/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport");
    
    if(!appSupportLibrary) {
         NSLog(@"Unable to dlopen AppSupport. Cannot automatically enable accessibility.");
    }

    CFStringRef (*copySharedResourcesPreferencesDomainForDomain)(CFStringRef domain) = dlsym(appSupportLibrary, "CPCopySharedResourcesPreferencesDomainForDomain");
    
    if (copySharedResourcesPreferencesDomainForDomain) {
        CFStringRef accessibilityDomain = copySharedResourcesPreferencesDomainForDomain(CFSTR("com.apple.Accessibility"));
        
        if (accessibilityDomain) {
            CFPreferencesSetValue(CFSTR("ApplicationAccessibilityEnabled"), kCFBooleanTrue, accessibilityDomain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
            CFRelease(accessibilityDomain);
            NSLog(@"Successfully updated the ApplicationAccessibilityEnabled value.");
        }
        else {
            NSLog(@"Unable to copy accessibility preferences. Cannot automatically enable accessibility.");
        }
    }
    else {
        NSLog(@"Unable to dlsym CPCopySharedResourcesPreferencesDomainForDomain. Cannot automatically enable accessibility.");
    }

    void* accessibilitySettingsBundle = loadDylib(@"/System/Library/PreferenceBundles/AccessibilitySettings.bundle/AccessibilitySettings");

	BOOL couldEnableAccessibility = NO;

    if (accessibilitySettingsBundle) {
        Class axSettingsPrefControllerClass = NSClassFromString(@"AccessibilitySettingsController");
        id axSettingPrefController = [[axSettingsPrefControllerClass alloc] init];

		if([axSettingPrefController respondsToSelector:@selector(AXInspectorEnabled:)])
		{
			id initialAccessibilityInspectorSetting = [axSettingPrefController AXInspectorEnabled:nil];
			[axSettingPrefController setAXInspectorEnabled:@(YES) specifier:nil];

			NSLog(@"Successfully enabled the AXInspector using the setAXInspectorEnabled selector.");
			couldEnableAccessibility = YES;
		}
    }
    else {
        NSLog(@"Unable to dlopen AccessibilitySettings. Cannout automatically enable accessibility.");
    }

	if(!couldEnableAccessibility)
	{
        NSLog(@"Could not enable accessibility using the legacy methods.");

		// If we get to this point, the legacy method has not worked
        void *handle = loadDylib(@"/usr/lib/libAccessibility.dylib");

        if (!handle) {
			NSLog(@"Unable to open libAccessibility. Cannout automatically enable accessibility.");
        }

        int (*_AXSAutomationEnabled)(void) = dlsym(handle, "_AXSAutomationEnabled");
        void (*_AXSSetAutomationEnabled)(int) = dlsym(handle, "_AXSSetAutomationEnabled");

        int initialValue = _AXSAutomationEnabled();
        _AXSSetAutomationEnabled(YES);
        atexit_b(^{
            _AXSSetAutomationEnabled(initialValue);
        });

		NSLog(@"Enabled accessibility using libAccessibility.");
	}

    [autoreleasePool drain];
    
#if TARGET_OS_IPHONE
    NSString *notificationName = @"UIApplicationDidBecomeActiveNotification";
#else
    NSString *notificationName = NSApplicationDidUpdateNotification;
#endif
    
    [[NSNotificationCenter defaultCenter] addObserver:[self class] 
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:notificationName
                                               object:nil];

#if TARGET_OS_IPHONE
    NSArray *iOSVersionComponents = [[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."];
    int majorVersion = [[iOSVersionComponents objectAtIndex:0] intValue];

    if (majorVersion >= 9) 
    { 
        // iOS9 is installed. The UIApplicationDidBecomeActiveNotification may have been fired *before* 
        // this code is called.
        // See also:
        // http://stackoverflow.com/questions/31785878/ios-9-uiapplicationdidbecomeactivenotification-callback-not-called

        // Call applicationDidBecomeActive: after 0.5 second. 
        // Delay execution of my block for 10 seconds.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * USEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"Forcefully invoking applicationDidBecomeActive");
            [FrankLoader applicationDidBecomeActive:nil];
        });
    }
#endif
}

@end
