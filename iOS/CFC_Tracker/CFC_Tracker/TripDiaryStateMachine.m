//
//  TripDiaryStateMachine.m
//  CFC_Tracker
//
//  Created by Kalyanaraman Shankari on 1/31/15.
//  Copyright (c) 2015 Kalyanaraman Shankari. All rights reserved.
//

#import "TripDiaryStateMachine.h"
#import "LocalNotificationManager.h"
#import "OngoingTripsDatabase.h"
#import <CoreMotion/CoreMotion.h>

@interface TripDiaryStateMachine() {
    CLLocationManager *locMgr;
    CMMotionActivityManager *activityMgr;
    GeofenceStatusCallback currCallback;
}
@end


@implementation TripDiaryStateMachine

static NSString * const kCurrGeofenceID = @"STATIONARY_GEOFENCE_LOCATION";
static NSString * const kCurrState = @"CURR_STATE";
static NSString * const kStartState = @"STATE_START";
static NSString * const kWaitingForTripStartState = @"STATE_WAITING_FOR_TRIP_START";
static NSString * const kOngoingTripState = @"STATE_ONGOING_TRIP";

static int FOUR_MINUTES_IN_SECONDS = 4 * 60;

static CLLocationDistance const HUNDRED_METERS = 100; // in meters


+ (NSString*)getTransitionName:(TripDiaryStateTransitions)transition {
    if (transition == kTransitionInitialize) {
        return @"TRANSITION_INITIALIZE";
    } else if (transition == kTransitionExitedGeofence) {
        return @"TRANSITION_EXITED_GEOFENCE";
    } else if (transition == kTransitionStoppedMoving) {
        return @"TRANSITION_STOPPED_MOVING";
    } else if (transition == kTransitionStopTracking) {
        return @"TRANSITION_STOP_TRACKING";
    } else {
        return @"UNKNOWN";
    }
}

-(id)init{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.currState = kStartState;
    [defaults setObject:kStartState forKey:kCurrState];
    
    [LocalNotificationManager addNotification:[NSString stringWithFormat:
                                               @"Initialized TripDiaryStateMachine when state = %@",
                                               self.currState]];
    
    locMgr = [[CLLocationManager alloc] init];
    locMgr.delegate = self;
    
    activityMgr = [[CMMotionActivityManager alloc] init];
    [self handleTransition:kTransitionInitialize];
    
    /*
     * Make sure that we start with a clean state, at least while debugging.
     * TODO: Check how often this is initialized, and whether we should do this even when we are out of debugging.
     */
    [self deleteGeofence:locMgr];
    return [super init];
}

-(void) checkGeofenceState:(GeofenceStatusCallback) callback {
    if (locMgr.monitoredRegions.count > 0) {
        [locMgr requestStateForRegion:locMgr.monitoredRegions.allObjects[0]];
        currCallback = callback;
    } else {
        callback(@"no fence");
    }
}


-(void)handleTransition:(TripDiaryStateTransitions) transition {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.currState = [defaults stringForKey:kCurrState];
    [LocalNotificationManager addNotification:[NSString stringWithFormat:
                                               @"Received transition %@ in state %@",
                                               [TripDiaryStateMachine getTransitionName:transition],
                                                self.currState]];
    
    if (transition == kTransitionInitialize) {
        [self handleStart:transition];
    } else if (self.currState == kStartState) {
        [self handleStart:transition];
    } else if (self.currState == kWaitingForTripStartState) {
        [self handleTripStart:transition];
    } else if (self.currState == kOngoingTripState) {
        [self handleTripEnd:transition];
    }
}

-(void)setState:(NSString*) newState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:newState forKey:kCurrState];
    
    [LocalNotificationManager addNotification:[NSString stringWithFormat:
                                               @"Moved from %@ to %@",
                                               self.currState, newState]];

    self.currState = newState;
}

/*
 * BEGIN: State transition handlers
 */

/*
 * Starts monitoring changes. This will return the current location asynchronously.
 * In that callback, we set up the geofence.
 
 */
-(void) handleStart:(TripDiaryStateTransitions) transition {
    if (transition == kTransitionInitialize) {
        // Stop all actions in order to cleanup
        [locMgr stopMonitoringSignificantLocationChanges];
    
        // Start location services so that we can get the current location
        [locMgr startUpdatingLocation];
        // We will receive the first location asynchronously
    } else {
        NSLog(@"Got unexpected transition %@ in state %@, ignoring", [TripDiaryStateMachine getTransitionName:transition], self.currState);
    }
}

- (void) handleTripStart:(TripDiaryStateTransitions) transition {
    // If we delete the geofence, and we are using the more fine grained location detection mode,
    // then we won't be relaunched if the app is terminated.
    // The standard location service ... does not relaunch iOS apps that have been terminated.
    // And it looks like apps need not be terminated on reboot, they can also be terminated as part of normal
    // OS operation
    // The system may still terminate the app at any time to reclaim its memory or other resources.
    // So we need to keep the geofence around so that we will be re-launched and can re-initialize ourselves
    // But if we use the significant changes location service, it will relaunch the app and we can remove
    // the geofence
    // TODO: Make removing the geofence conditional on the type of service
    if (transition == kTransitionExitedGeofence) {
        [self startTrackingLocation:locMgr];
        [self startTrackingActivity:activityMgr];
        [self setState:kOngoingTripState];
    } else if (transition == kTransitionStopTracking) {
        [self deleteGeofence:locMgr];
        [self setState:kStartState];
    } else  {
        NSLog(@"Got unexpected transition %@ in state %@, ignoring", [TripDiaryStateMachine getTransitionName:transition], self.currState);
    }
}

- (void) handleTripEnd:(TripDiaryStateTransitions) transition {
    if (transition == kTransitionStoppedMoving) {
        [self stopTrackingLocation:locMgr];
        [self stopTrackingActivity:activityMgr];
        // The location property may have been updated while the app was killed
        // Another caveat is that if the minimum distance filter is large,
        // the returned location may be relatively old. But in our case, we have
        // just detected the end of the trip, so the update should be fairly recent
        // In case we didn't delete the old geofence, in this case, the new geofence will replace it
        // because they both have the same identifier
        [self createGeofence:locMgr atLocation:locMgr.location];
    } else if (transition == kTransitionStopTracking) {
        [self stopTrackingLocation:locMgr];
        [self stopTrackingActivity:activityMgr];
        [self setState:kStartState];
    } else {
        NSLog(@"Got unexpected transition %@ in state %@, ignoring", [TripDiaryStateMachine getTransitionName:transition], self.currState);
    }
}

/*
 * END: State transition handlers
 */

/*
 * BEGIN: Delegate callbacks
 */

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray *)locations {
    NSLog(@"Recieved %ld location updates ", (unsigned long)locations.count);

    if (locations.count == 0) {
        NSLog(@"locations.count = %lu in didUpdateLocations, early return", (unsigned long)locations.count);
        return;
    }
    
    NSAssert(locations.count > 0, @"locations.count = %lu in didUpdateLocations after early return check!", (unsigned long)locations.count);
    CLLocation *lastLocation = locations[locations.count - 1];
    NSLog(@"lastLocation is %f, %f", lastLocation.coordinate.longitude, lastLocation.coordinate.latitude);
    
    if (self.currState == kStartState) {
        // Find the last location
        [self stopTrackingLocation:locMgr];
        [self createGeofence:locMgr atLocation:lastLocation];
    }
    
    if (self.currState == kOngoingTripState) {
        for (CLLocation* currLoc in locations) {
            NSLog(@"Adding point with timestamp %ld", (long)[currLoc.timestamp timeIntervalSince1970]);
            [[OngoingTripsDatabase database] addPoint:currLoc];
        }
        [self logPastHourCollectionCount];
        if ([self hasTripEnded]) {
            // TODO: This needs to be replaced by DataUtils::EndTrip so that we can store the trip!
            [[OngoingTripsDatabase database] clear];
            [self handleTransition:kTransitionStoppedMoving];
        }
    }
}

- (void)logPastHourCollectionCount {
    NSDate* dateNow = [NSDate date];
    NSCalendar *gregorian = [[NSCalendar alloc]
                             initWithCalendarIdentifier:NSGregorianCalendar];
    NSDateComponents* dayHourMinuteComponents = [gregorian components:(NSDayCalendarUnit|NSHourCalendarUnit|NSMinuteCalendarUnit) fromDate:dateNow];
    
    if ([dayHourMinuteComponents minute] == 0) {
        /*
         * If this turns out to be a performance hassle, replace by
         */
        NSDate* hourAgo = [dateNow dateByAddingTimeInterval:-(60 * 60)];
        NSArray* pastHourTrips = [[OngoingTripsDatabase database]
                                  getPointsFrom: hourAgo.timeIntervalSince1970
                                  to:dateNow.timeIntervalSince1970];
        [LocalNotificationManager addNotification:[NSString stringWithFormat:
                                                   @"Recived = %d updates in the %d hour of %d day",
                                                   pastHourTrips.count, [dayHourMinuteComponents hour],
                                                   [dayHourMinuteComponents day]]];
        
    }
}

- (BOOL)hasTripEnded {
    /*
     * On iOS, we can't actually get updates based on a time delta. So getting the last n trips is not good enough.
     * Instead, we need to get trips for the past 3 minutes.
     */
    NSDate* dateNow = [NSDate date];
    NSDate* date_3_mins_ago = [dateNow dateByAddingTimeInterval:-(3 * 60)];
    NSArray* last3MinLocations = [[OngoingTripsDatabase database] getPointsFrom:date_3_mins_ago.timeIntervalSince1970
                                                                             to:dateNow.timeIntervalSince1970];
    
    if (last3MinLocations.count == 0 || last3MinLocations.count == 1) {
        NSLog(@"last3MinLocations.count = %d, returning NO", last3MinLocations.count);
        return NO;
    }
    
    // We are guaranteed to have at least two points
    NSDate* lastDate = ((CLLocation*)last3MinLocations.firstObject).timestamp;
    NSDate* firstDate = ((CLLocation*)last3MinLocations.lastObject).timestamp;
    NSLog(@"firstDate = %@, lastDate = %@", firstDate, lastDate);
    
    if ([firstDate timeIntervalSinceDate:lastDate] < (2.5 * 60)) {
        NSLog(@"interval between last and first dates = %f, returning NO", [firstDate timeIntervalSinceDate:lastDate]);
        return NO;
    }
    
    /*
     * I tried to implement this java style by computing the distances first, and then by computing the
     * max of them. Unfortunately, distances are doubles, which cannot be stored in an NSArray since they are
     * not objects, and returning a CLLocationDistance[] is not allowed. I could probably use a CLLocationDistance*
     * instead, but don't want to mess with raw pointers and manual deallocation.
     * 
     * Switching to computing the distances and the max in the same loop.
     */
    
    /*
     * Points are read from the database in reverse order,
     * so the last point is actually in the first location in the array.
     */
    CLLocationDistance maxDistance = 0;
    
    CLLocation* lastPoint = last3MinLocations.firstObject;
    NSArray* lastMinusOnePoint = [last3MinLocations subarrayWithRange:(NSRange){1, last3MinLocations.count - 1}];
    for(id currLoc in lastMinusOnePoint) {
        CLLocationDistance currDistance = [lastPoint distanceFromLocation:currLoc];
        if (currDistance > maxDistance) {
            NSLog(@"currDistance %f > maxDistance %f, replacing it", currDistance, maxDistance);
            maxDistance = currDistance;
        }
    }

    if (maxDistance < HUNDRED_METERS) {
        NSLog(@"maxDistance = %f (< 100), returning YES ", maxDistance);
        return YES;
    } else {
        NSLog(@"maxDistance = %f (> 100), returning NO ", maxDistance);
        return NO;
    }
}

- (void)printGeofences:(CLLocationManager*)manager {
    CLCircularRegion* currRegion = NULL;
    
    NSEnumerator *enumerator = [manager.monitoredRegions objectEnumerator];
    while ((currRegion = [enumerator nextObject])) {
        NSLog(@"Found geofence with id %@, coordinates %f %f",
              currRegion.identifier,
              currRegion.center.longitude,
              currRegion.center.latitude);
    }
}

- (void)locationManager:(CLLocationManager *)manager
          didExitRegion:(CLRegion *)region {
    if([region.identifier compare:kCurrGeofenceID] != NSOrderedSame) {
        NSLog(@"exited region %@ that does not match current geofence %@", region.identifier, kCurrGeofenceID);
    }
    // Since we are going to keep the geofence around during ongoing tracking to ensure that
    // we are re-initalized, we will keep getting exit messages. We need to ignore if we are not
    // in the "waiting_for_trip_start" state.
    if (self.currState == kWaitingForTripStartState) {
        [self handleTransition:kTransitionExitedGeofence];
    } else {
        NSLog(@"Received geofence exit in state %@, ignoring", self.currState);
    }
}

- (void)locationManager:(CLLocationManager *)manager
    didStartMonitoringForRegion:(CLRegion *)region {
    NSLog(@"started monitoring for region %@", region.identifier);
    [self setState:kWaitingForTripStartState];
    [locMgr requestStateForRegion:region];
}

- (void)locationManager:(CLLocationManager *)manager
      didDetermineState:(CLRegionState)state forRegion:(CLRegion *)region {
    
    NSString* stateStr = [TripDiaryStateMachine geofenceStateToString:state];
    if (currCallback != NULL) {
        currCallback(stateStr);
    }
    
    NSLog(@"Current state of region %@ is %d (%@)", region.identifier, (int)state, stateStr);
    if (self.currState == kWaitingForTripStartState && state == CLRegionStateOutside) {
        /*
         * So we have created a geofence, and since we in a state where we are yet to start a trip,
         * we expect that we are inside the geofence. But we aren't!
         * So we must be in motion, and moving so fast that we went outside the geofence in the time that it
         * took for the OS to initialize the geofence. Let's officially acknowledge that and transition to
         * having started the trip. This is also the safer option since if we made a mistake here
         * (say because of low accuracy), then we will quickly end the trip, and the low distance trip
         * will be filtered on the server side. But if we made a mistake in staying in the same state, we 
         * will never leave the geofence, since we are already outside, and we won't track any trips at all.
         */
        [self handleTransition:kTransitionExitedGeofence];
    }
    currCallback = NULL;
}

+(NSString*)geofenceStateToString:(CLRegionState)state {
    if (state == CLRegionStateInside) {
        return @"inside";
    } else if (state == CLRegionStateOutside) {
        return @"outside";
    } else {
        return @"unknown";
    }
}

/*
 * END: Delegate callbacks
 */

/*
 * BEGIN: Common actions invoked by state callbacks
 */

-(void)createGeofence:(CLLocationManager *)manager
           atLocation:(CLLocation*) currLoc {
    /*
     * Geofences suck on ios, at least iOS 7 on an iPhone 5.
     * They do not appear to be triggered in any reasonable way.
     * In particular,
     */
    NSLog(@"At method CREATION");
    [self printGeofences:manager];
    
    CLCircularRegion *geofenceRegion = [[CLCircularRegion alloc] initWithCenter:currLoc.coordinate
                                                                         radius:HUNDRED_METERS
                                                                     identifier:kCurrGeofenceID];
    
    geofenceRegion.notifyOnEntry = YES;
    geofenceRegion.notifyOnExit = YES;
    NSLog(@"BEFORE creating region");
    [self printGeofences:manager];

    [manager startMonitoringForRegion:geofenceRegion];
    NSLog(@"AFTER creating region");
    [self printGeofences:manager];
}

-(void)deleteGeofence:(CLLocationManager*)manager {
    /*
     * TODO: Determine whether we need to get the existing region from the region list,
     * or whether it is sufficient to create a new region with the same identifier
     */
    NSEnumerator *enumerator = [manager.monitoredRegions objectEnumerator];
    CLCircularRegion* currRegion;
    CLCircularRegion* selRegion = NULL;
    while ((currRegion = [enumerator nextObject])) {
        NSLog(@"Considering region with id = %@, location %f, %f",
              currRegion.identifier,
              currRegion.center.longitude,
              currRegion.center.latitude);
        if ([currRegion.identifier compare:kCurrGeofenceID] == NSOrderedSame) {
            NSLog(@"Deleting it!!");
            selRegion = currRegion;
        }
    }

    if (selRegion != NULL) {
        [manager stopMonitoringForRegion:selRegion];
    } else {
        NSLog(@"No geofence found to delete, skipping...");
    }
}

/*
 * Configuring the iOS location manager. It looks like there are multiple ways to reduce the power consumption
 * of continuous location tracking in iOS, but it is hard to combine their use.
 * - We can lower the desired accuracy so that the phone can use modes other than GPS to determine the location. However, if we want deferred updates, we have to use the "best" accuracy which forces the use of GPS.
 * - We can defer updates so that the app is not woken up constantly to provide information that is just logged immediately. However, we then HAVE to us the most accurate mode, viz. GPS.
 * - We can use a distance filter so that we get woken up rarely. However, then it is hard/impossible to detect the end of a trip because we currently detect the end of a trip by using the fact that we have been within a particular radius for a particular amount of time. But with a distance filter, we won't get updates if we are within the radius, so we won't be woken up and so we won't detect the end of the trip. We can work around this for android by adding a time based alarm, but that is not an option on iOS.
 * So it looks like we have to either use the highest accuracy or be woken up constantly, both of which suck for power consumption. An adaptive, as opposed to fixed, distance filter might help with this because then we could use it in conjunction with a lower accuracy mode.
 */

-(void)startTrackingLocation:(CLLocationManager*) manager {
    // Switch to a more fine grained tracking during the trip
    // locMgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    locMgr.desiredAccuracy = kCLLocationAccuracyBest;
    /* If we use a distance filter, we can lower the power consumption because we will get updates less
     * frequently. HOWEVER, we won't be able to detect a trip end because of the above.
     * Trying deferred updates instead.
     */
    // locMgr.distanceFilter = HUNDRED_METERS;
    [locMgr allowDeferredLocationUpdatesUntilTraveled:CLLocationDistanceMax timeout:FOUR_MINUTES_IN_SECONDS];
    [manager startUpdatingLocation];
}

-(void)stopTrackingLocation:(CLLocationManager*) manager {
    [manager stopUpdatingLocation];
}

-(void)startTrackingActivity:(CMMotionActivityManager*) manager {
    NSOperationQueue* mq = [NSOperationQueue mainQueue];
    [manager startActivityUpdatesToQueue:mq
                                 withHandler:^(CMMotionActivity *activity) {
                                     NSString *activityName = [self getActivityName:activity];
                                     NSLog(@"Got activity change %@ starting at %@ with confidence %d", activityName, activity.startDate, (int)activity.confidence);
                                 }];
}

-(void)stopTrackingActivity:(CMMotionActivityManager*) manager {
    [manager stopActivityUpdates];
}

-(NSString*)getActivityName:(CMMotionActivity*) activity {
    if(activity.walking) {
        return @"walking";
    } else if (activity.cycling) {
        return @"cycling";
    } else if (activity.automotive) {
        return @"transport";
    } else {
        return @"unknown";
    }
}

@end
