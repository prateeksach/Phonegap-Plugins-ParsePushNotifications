//
//  ParsePushNotificationPlugin.m
//  HelloWorld
//
//  Created by yoyo on 2/12/14.
//
//

#import "ParsePushNotificationPlugin.h"
#import <Parse/Parse.h>

@implementation ParsePushNotificationPlugin
    
    @synthesize callbackId;
    
    static NSDictionary *coldstartNotification;
    
    NSMutableArray *jsEventQueue;
    BOOL canDeliverNotifications = NO;
    
    /*
     Ideally the UIApplicationDidFinishLaunchingNotification would go in pluginInitialize
     but it is too late in the life cycle to catch the actual event for remote notifications.
     
     For local notifications it is fine becuase the base CDVPlugin takes care of forwarding the event
     but not for remote notifications and as we dont want to make changes to the cordova base classes:
     
     We use the static load method to attach the observer and if the handler finds a corresponding notification
     it is stored in a static var.
     
     Later on in pluginInitialize we check if the static var conatins a notification and if yes use it
     
     Additionaly, weo make sure the notification callbacks in the client javascript are not delivered
     until the client app is ready for them by checking:
     1. The app is in the foreground
     2. The 'register' method has been called on the plugin - passing in a handler
     
     If either of these conditions is not true we hold onto notifications in a queue and then flush it to the client
     when they are fulfilled.
     
     */
    
+(void) load
    {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkForColdStartNotification:)
                                                     name:UIApplicationDidFinishLaunchingNotification object:nil];
    }
    
+ (void) checkForColdStartNotification:(NSNotification *)notification
    {
        NSDictionary *launchOptions = [notification userInfo];
        
        NSDictionary *payload = [launchOptions objectForKey: @"UIApplicationLaunchOptionsRemoteNotificationKey"];
        
        if(payload){
            
            NSMutableDictionary *extendedPayload = [payload mutableCopy];
            [extendedPayload setObject:[NSNumber numberWithBool:NO] forKey:@"receivedInForeground"];
            
            coldstartNotification = extendedPayload;
        }
        
    }
    
- (void)unregister:(CDVInvokedUrlCommand*)command;
    {
        self.callbackId = command.callbackId;
        
        [[UIApplication sharedApplication] unregisterForRemoteNotifications];
        [self successWithMessage:@"unregistered"];
    }
    
    - (void)register:(CDVInvokedUrlCommand*)command;
    {
        NSMutableDictionary* options = [command.arguments objectAtIndex:0];
        
        NSString *appId = [options objectForKey:@"appId"];
        NSString *clientKey = [options objectForKey:@"clientKey"];

        self.currentUserId = [options objectForKey:@"userId"];
        
        [Parse setApplicationId:appId clientKey:clientKey];
        
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes:
         UIRemoteNotificationTypeBadge |
         UIRemoteNotificationTypeAlert |
         UIRemoteNotificationTypeSound];
        
        self.callbackId = command.callbackId;
        
        [self flushNotificationEventQueue];
        canDeliverNotifications = YES;
    }
    
    
- (void)getInstallationId:(CDVInvokedUrlCommand*) command
    {
        [self.commandDelegate runInBackground:^{
            CDVPluginResult* pluginResult = nil;
            PFInstallation *currentInstallation = [PFInstallation currentInstallation];
            NSString *objectId = currentInstallation.objectId;
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:objectId];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }];
    }
    
- (void)getSubscriptions: (CDVInvokedUrlCommand *)command
    {
        NSArray *channels = [PFInstallation currentInstallation].channels;
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:channels];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
    
- (void)subscribeToChannel: (CDVInvokedUrlCommand *)command
    {
        CDVPluginResult* pluginResult = nil;
        PFInstallation *currentInstallation = [PFInstallation currentInstallation];
        NSString *channel = [command.arguments objectAtIndex:0];
        [currentInstallation addUniqueObject:channel forKey:@"channels"];
        [currentInstallation saveInBackground];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
    
- (void)unsubscribeFromChannel: (CDVInvokedUrlCommand *)command
    {
        CDVPluginResult* pluginResult = nil;
        PFInstallation *currentInstallation = [PFInstallation currentInstallation];
        NSString *channel = [command.arguments objectAtIndex:0];
        [currentInstallation removeObject:channel forKey:@"channels"];
        [currentInstallation saveInBackground];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
    
    
- (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    
    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    NSString *token = [[[[deviceToken description] stringByReplacingOccurrencesOfString:@"<"withString:@""]
                        stringByReplacingOccurrencesOfString:@">" withString:@""]
                       stringByReplacingOccurrencesOfString: @" " withString: @""];
    [results setValue:token forKey:@"deviceToken"];
    
#if !TARGET_IPHONE_SIMULATOR
    
    PFInstallation *currentInstallation = [PFInstallation currentInstallation];
    [currentInstallation setObject:[PFObject objectWithoutDataWithClassName:@"_User" objectId:self.currentUserId] forKey:@"user"];
    [currentInstallation setDeviceTokenFromData:deviceToken];
    if(self.currentUserId)
        [currentInstallation saveInBackground];
    [self successWithMessage:[NSString stringWithFormat:@"%@", token]];
#endif
}
    
- (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
    {
        [self failWithMessage:@"" withError:error];
    }
    
- (void) didBecomeActive:(NSNotification *)notification
    {
        if(canDeliverNotifications)
        {
            [self flushNotificationEventQueue];
        }
        
    }
    
-(void) flushNotificationEventQueue
    {
        if(jsEventQueue != nil && [jsEventQueue count] > 0)
        {
            for(NSString *notificationEvent in jsEventQueue)
            {
                [self.commandDelegate evalJs:notificationEvent];
            }
            
            [jsEventQueue removeAllObjects];
        }
    }
    
- (void) pluginInitialize
    {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
        
        if(coldstartNotification)
        {
            coldstartNotification = nil;
        }
    }
    
    
-(void)successWithMessage:(NSString *)message
    {
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
        
        [self.commandDelegate sendPluginResult:commandResult callbackId:self.callbackId];
    }
    
-(void)failWithMessage:(NSString *)message withError:(NSError *)error
    {
        NSString        *errorMessage = (error) ? [NSString stringWithFormat:@"%@ - %@", message, [error localizedDescription]] : message;
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
        
        [self.commandDelegate sendPluginResult:commandResult callbackId:self.callbackId];
    }
    
    @end