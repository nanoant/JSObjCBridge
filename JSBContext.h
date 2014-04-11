//
//  JSBContext.h
//  JavaScriptBridging
//
//  Created by Adam Strzelecki on 21.09.2013.
//  Copyright (c) 2013-2014 nanoANT Adam Strzelecki. All rights reserved.
//

#import <Foundation/Foundation.h>

extern NSString *const JSBErrorDomain;
extern NSString *const JSBExceptionKey;

/// Wraps JSContextRef and prodives Objective-C bridging.
@interface JSBContext : NSObject

/// Evaluate given script and return value as an Objective-C object.
/// @return result of script
- (id)evaluate:(NSString *)script error:(NSError **)error;

/// Call given global function with given arguments.
/// @return result of function
- (id)call:(NSString *)name
    arguments:(NSArray *)arguments
        error:(NSError **)error;

/// Install given Objective-C object under given name.
/// All methods beginning with `js_` will be exposed to JavaScript.
- (void)install:(id)object withName:(NSString *)name;

@end
