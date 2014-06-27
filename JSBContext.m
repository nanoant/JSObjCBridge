//
//  JSBContext.m
//  JavaScriptBridging
//
//  Created by Adam Strzelecki on 21.09.2013.
//  Copyright (c) 2013-2014 nanoANT Adam Strzelecki. All rights reserved.
//

#import "JSBContext.h"

#import <objc/runtime.h>
#import <JavaScriptCore/JavaScriptCore.h>

NSString *const JSBErrorDomain = @"JSBErrorDomain";
NSString *const JSBExceptionKey = @"JSBExceptionKey";

// set to 1 if you want use Foundation dictionaries when converting to JSValue
#define JSB_USE_DICTIONARY 0
#define JSB_USE_MUTABLE_DICTIONARY 0

@interface JSBContext () {
@public
  JSObjectRef _arrayConstructor;
#if JSB_USE_DICTIONARY
  JSClassRef _dictionaryClass;
#endif // JSB_USE_DICTIONARY
  NSMapTable *_methodMap;
  NSMapTable *_propertyMap;
}

@property(nonatomic, assign) JSGlobalContextRef context;
@property(nonatomic, assign) JSObjectRef global;
@property(nonatomic, assign) JSObjectRef arrayConstructor;
#if JSB_USE_DICTIONARY
@property(nonatomic, assign) JSClassRef dictionaryClass;
#endif // JSB_USE_DICTIONARY
@property(nonatomic, strong) NSMapTable *methodMap;
@property(nonatomic, strong) NSMapTable *propertyMap;

@end

#define CAST_CASES                                                             \
  CASE('@', __autoreleasing, id, JSBValueToObject, JSBObjectToJSValue);        \
  CASE('d', , double, JSValueToNumber, JSValueMakeNumber, NULL);               \
  CASE('f', , float, JSValueToNumber, JSValueMakeNumber, NULL);                \
  CASE('i', , int, JSValueToNumber, JSValueMakeNumber, NULL);                  \
  CASE('I', , unsigned int, JSValueToNumber, JSValueMakeNumber, NULL);         \
  CASE('l', , long, JSValueToNumber, JSValueMakeNumber, NULL);                 \
  CASE('L', , unsigned long, JSValueToNumber, JSValueMakeNumber, NULL);        \
  CASE('q', , long long, JSValueToNumber, JSValueMakeNumber, NULL);            \
  CASE('Q', , unsigned long long, JSValueToNumber, JSValueMakeNumber, NULL);   \
  CASE('B', , bool, JSValueToBoolean, JSValueMakeBoolean);

static JSValueRef JSBObjectToJSValue(JSContextRef context, id object);
static id JSBValueToObject(JSContextRef context, JSValueRef value);
static inline NSError *JSBExceptionToNSError(JSContextRef context,
                                             JSValueRef exception);

// these functions are there in iOS but they are absent in headers
void NSMapInsert(NSMapTable *table, const void *key, const void *value);
void NSMapInsertKnownAbsent(NSMapTable *table, const void *key,
                            const void *value);
void *NSMapGet(NSMapTable *table, const void *key);
void NSMapRemove(NSMapTable *table, const void *key);

static void JSBObjectFinalize(JSObjectRef object)
{
  CFBridgingRelease(JSObjectGetPrivate(object));
}

static JSValueRef JSBObjectConvertToTypeCallback(JSContextRef context,
                                                 JSObjectRef objectRef,
                                                 JSType type,
                                                 JSValueRef *exception)
{
  // returns just object description
  if (type == kJSTypeString) {
    id object = (__bridge id)JSObjectGetPrivate(objectRef);
    JSStringRef stringRef =
        JSStringCreateWithCFString((__bridge CFStringRef)[object description]);
    JSValueRef valueRef = JSValueMakeString(context, stringRef);
    JSStringRelease(stringRef);
    return valueRef;
  }
  return JSValueMakeUndefined(context);
}

static JSValueRef JSBMethodCall(JSContextRef context, JSObjectRef methodRef,
                                JSObjectRef thisObject, size_t argumentCount,
                                const JSValueRef arguments[],
                                JSValueRef *exception)
{
  NSMapTable *methodMap = ((__bridge JSBContext *)JSObjectGetPrivate(
                               JSContextGetGlobalObject(context)))->_methodMap;
  id object = (__bridge id)JSObjectGetPrivate(thisObject);
  SEL selector = NSMapGet(methodMap, methodRef);

  if (object && selector) {
    NSMethodSignature *methodSignature =
        [[object class] instanceMethodSignatureForSelector:selector];
    NSInvocation *invocation =
        [NSInvocation invocationWithMethodSignature:methodSignature];
    invocation.target = object;
    invocation.selector = selector;
    NSUInteger argumentCount = [methodSignature numberOfArguments];

#define CASE(C, TF, T, F, U, ...)                                              \
  case C: {                                                                    \
    TF T value = (T)F(context, arguments[i], ##__VA_ARGS__);                   \
    [invocation setArgument:&value atIndex:i + 2];                             \
  } break;
    for (unsigned i = 0; i < argumentCount - 2; ++i) {
      switch ([methodSignature getArgumentTypeAtIndex:i + 2][0]) {
        CAST_CASES
      }
    }
#undef CASE

    [invocation retainArguments];
    [invocation invoke];

#define CASE(C, TF, T, U, F, ...)                                              \
  case C: {                                                                    \
    TF T value;                                                                \
    [invocation getReturnValue:&value];                                        \
    return F(context, value);                                                  \
  }
    switch ([methodSignature methodReturnType][0]) {
      CAST_CASES
    default:
      return JSValueMakeUndefined(context);
    }
  }
#undef CASE

  return JSValueMakeUndefined(context);
}

#if JSB_USE_DICTIONARY
static JSValueRef JSBDictionaryGetProperty(JSContextRef context,
                                           JSObjectRef objectRef,
                                           JSStringRef propertyNameRef,
                                           JSValueRef *exception)
{
  NSDictionary *dictionary =
      (__bridge NSDictionary *)JSObjectGetPrivate(objectRef);
  NSString *propertyName = (__bridge_transfer NSString *)JSStringCopyCFString(
      kCFAllocatorDefault, propertyNameRef);
  id value = dictionary[propertyName];
  return JSBObjectToJSValue(context, value);
}

#if JSB_USE_MUTABLE_DICTIONARY
static bool JSBDictionarySetProperty(JSContextRef context,
                                     JSObjectRef objectRef,
                                     JSStringRef propertyNameRef,
                                     JSValueRef valueRef, JSValueRef *exception)
{
  NSMutableDictionary *dictionary =
      (__bridge NSMutableDictionary *)JSObjectGetPrivate(objectRef);
  NSString *propertyName = (__bridge_transfer NSString *)JSStringCopyCFString(
      kCFAllocatorDefault, propertyNameRef);
  id value = JSBValueToObject(context, valueRef);
  dictionary[propertyName] = value;
  return YES;
}
#endif // JSB_USE_MUTABLE_DICTIONARY

static void
JSBDictionaryGetPropertyNames(JSContextRef context, JSObjectRef objectRef,
                              JSPropertyNameAccumulatorRef propertyNames)
{
  NSDictionary *dictionary =
      (__bridge NSDictionary *)JSObjectGetPrivate(objectRef);
  for (NSString *key in dictionary) {
    JSStringRef propertyNameRef =
        JSStringCreateWithCFString((__bridge CFStringRef)key);
    JSPropertyNameAccumulatorAddName(propertyNames, propertyNameRef);
    JSStringRelease(propertyNameRef);
  }
}
#endif // JSB_USE_DICTIONARY

static JSValueRef JSBObjectToJSValue(JSContextRef context, id object)
{
  if ([object isKindOfClass:[NSString class]]) {
    JSStringRef stringRef =
        JSStringCreateWithCFString((__bridge CFStringRef)object);
    JSValueRef valueRef = JSValueMakeString(context, stringRef);
    JSStringRelease(stringRef);
    return valueRef;
  } else if ([object isKindOfClass:[NSArray class]]) {
    size_t count = [object count];
    JSValueRef elements[count];
    for (size_t i = 0; i < count; ++i) {
      elements[i] = JSBObjectToJSValue(context, ((NSArray *)object)[i]);
    }
    return JSObjectMakeArray(context, count, elements, NULL);
  } else if ([object isKindOfClass:[NSDictionary class]]) {
#if JSB_USE_DICTIONARY
    JSClassRef dictionaryClass =
        ((__bridge JSBContext *)JSObjectGetPrivate(
             JSContextGetGlobalObject(context)))->_dictionaryClass;
    return JSObjectMake(context, dictionaryClass, (__bridge_retained void *)
#if JSB_USE_MUTABLE_DICTIONARY
                        [object mutableCopy]
#else
                        object
#endif // JSB_USE_MUTABLE_DICTIONARY
                        );
#else
    JSObjectRef objectRef = JSObjectMake(context, NULL, NULL);
    NSDictionary *dictionary = (NSDictionary *)object;
    for (NSString *key in dictionary) {
      JSStringRef nameRef =
          JSStringCreateWithCFString((__bridge CFStringRef)key);
      id value = dictionary[key];
      JSObjectSetProperty(context, objectRef, nameRef,
                          JSBObjectToJSValue(context, value),
                          kJSPropertyAttributeNone, NULL);
      JSStringRelease(nameRef);
    }
    return objectRef;
#endif // JSB_USE_DICTIONARY
  } else if ([object isKindOfClass:[NSNumber class]]) {
    return JSValueMakeNumber(context, [object doubleValue]);
  } else if ([object isKindOfClass:[NSNull class]]) {
    return JSValueMakeNull(context);
  }
  return JSValueMakeUndefined(context);
}

static id JSBValueToObject(JSContextRef context, JSValueRef value)
{
  if (!value) return nil;

  JSObjectRef arrayConstructor =
      ((__bridge JSBContext *)JSObjectGetPrivate(
           JSContextGetGlobalObject(context)))->_arrayConstructor;
  switch (JSValueGetType(context, value)) {
  // JS object
  case kJSTypeObject: {
    JSObjectRef objectRef = JSValueToObject(context, value, NULL);
    // JS array -> NSArray
    if (JSValueIsInstanceOfConstructor(context, value, arrayConstructor,
                                       NULL)) {
      NSMutableArray *array = [NSMutableArray array];
      for (size_t i = 0;; ++i) {
        JSValueRef propertyRef =
            JSObjectGetPropertyAtIndex(context, objectRef, i, NULL);
        if (JSValueIsUndefined(context, propertyRef)) break;
        [array addObject:JSBValueToObject(context, propertyRef)];
      }
      return [array copy];
    } else { // otherwise NSDictionary
      JSPropertyNameArrayRef propertyNameArrayRef =
          JSObjectCopyPropertyNames(context, objectRef);
      size_t propertyCount = JSPropertyNameArrayGetCount(propertyNameArrayRef);
      NSMutableDictionary *dictionary =
          [NSMutableDictionary dictionaryWithCapacity:propertyCount];
      for (size_t i = 0; i < propertyCount; ++i) {
        JSStringRef propertyNameRef =
            JSPropertyNameArrayGetNameAtIndex(propertyNameArrayRef, i);
        JSValueRef propertyRef =
            JSObjectGetProperty(context, objectRef, propertyNameRef, NULL);
        NSString *propertyName =
            (__bridge_transfer NSString *)JSStringCopyCFString(
                kCFAllocatorDefault, propertyNameRef);
        dictionary[propertyName] = JSBValueToObject(context, propertyRef);
      }
      JSPropertyNameArrayRelease(propertyNameArrayRef);
      return [dictionary copy];
    }
  }
  case kJSTypeString: {
    JSStringRef stringRef = JSValueToStringCopy(context, value, NULL);
    NSString *string = (__bridge_transfer NSString *)JSStringCopyCFString(
        kCFAllocatorDefault, stringRef);
    JSStringRelease(stringRef);
    return string;
  }
  case kJSTypeNumber:
    return @(JSValueToNumber(context, value, NULL));
  case kJSTypeBoolean:
    return @(JSValueToBoolean(context, value));
  case kJSTypeNull:
    return [NSNull null];
  case kJSTypeUndefined:
  default:
    return nil;
  }
}

JSValueRef JSBGlobalGetProperty(JSContextRef context, JSObjectRef objectRef,
                                JSStringRef propertyNameRef,
                                JSValueRef *exception)
{
  NSMapTable *propertyMap =
      ((__bridge JSBContext *)JSObjectGetPrivate(objectRef))->_propertyMap;
  NSString *propertyName = (__bridge_transfer NSString *)JSStringCopyCFString(
      kCFAllocatorDefault, propertyNameRef);
  return NSMapGet(propertyMap, (__bridge void *)propertyName);
}

bool JSBGlobalSetProperty(JSContextRef context, JSObjectRef objectRef,
                          JSStringRef propertyNameRef, JSValueRef valueRef,
                          JSValueRef *exception)
{
  NSMapTable *propertyMap =
      ((__bridge JSBContext *)JSObjectGetPrivate(objectRef))->_propertyMap;
  NSString *propertyName = (__bridge_transfer NSString *)JSStringCopyCFString(
      kCFAllocatorDefault, propertyNameRef);
  NSMapInsert(propertyMap, (__bridge void *)propertyName, valueRef);
  return true;
}

@implementation JSBContext

- (id)init
{
  if (!(self = [super init])) return nil;

  _methodMap =
      [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaquePersonality |
                                         NSPointerFunctionsOpaqueMemory
                            valueOptions:NSPointerFunctionsOpaquePersonality |
                                         NSPointerFunctionsOpaqueMemory];
  _propertyMap =
      [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPersonality |
                                         NSPointerFunctionsCopyIn
                            valueOptions:NSPointerFunctionsOpaquePersonality |
                                         NSPointerFunctionsOpaqueMemory];

#if JSB_USE_DICTIONARY
  JSClassDefinition dictionaryDefinition = kJSClassDefinitionEmpty;
  dictionaryDefinition.attributes = kJSClassAttributeNone;
  dictionaryDefinition.getProperty = JSBDictionaryGetProperty;
  dictionaryDefinition.getPropertyNames = JSBDictionaryGetPropertyNames;
#if JSB_USE_MUTABLE_DICTIONARY
  dictionaryDefinition.setProperty = JSBDictionarySetProperty;
#endif // JSB_USE_MUTABLE_DICTIONARY
  dictionaryDefinition.convertToType = JSBObjectConvertToTypeCallback;
  _dictionaryClass = JSClassCreate(&dictionaryDefinition);
#endif // JSB_USE_DICTIONARY

  JSClassDefinition globalDefinition = kJSClassDefinitionEmpty;
  globalDefinition.attributes = kJSClassAttributeNone;
  globalDefinition.getProperty = JSBGlobalGetProperty;
  globalDefinition.setProperty = JSBGlobalSetProperty;
  globalDefinition.convertToType = JSBObjectConvertToTypeCallback;
  JSClassRef globalClass = JSClassCreate(&globalDefinition);
  _context = JSGlobalContextCreate(globalClass);
  JSClassRelease(globalClass);

  _global = JSContextGetGlobalObject(_context);
  JSObjectSetPrivate(_global, (__bridge void *)self);
  JSStringRef arrayStringRef = JSStringCreateWithUTF8CString("Array");
  _arrayConstructor = JSValueToObject(
      _context, JSObjectGetProperty(_context, _global, arrayStringRef, NULL),
      NULL);
  JSStringRelease(arrayStringRef);

  return self;
}

static inline NSError *JSBExceptionToNSError(JSContextRef context,
                                             JSValueRef exception)
{
  if (!exception) return nil;
  return [NSError
      errorWithDomain:JSBErrorDomain
                 code:0
             userInfo:@{
                        JSBExceptionKey : JSBValueToObject(context, exception)
                      }];
}

- (void)install:(id)object withName:(NSString *)name
{
  // count js_ methods
  unsigned int methodCount;
  Method *methods = class_copyMethodList([object class], &methodCount);
  unsigned int jsMethodCount = 0;
  for (unsigned int i = 0; i < methodCount; ++i) {
    NSString *methodName = NSStringFromSelector(method_getName(methods[i]));
    if ([methodName hasPrefix:@"js_"]) {
      ++jsMethodCount;
    }
  }

  if (!jsMethodCount) return;

  JSStaticFunction staticFunctions[jsMethodCount + 1];
  NSMapTable *selectorMap =
      [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsCStringPersonality |
                                         NSPointerFunctionsMallocMemory |
                                         NSPointerFunctionsCopyIn
                            valueOptions:NSPointerFunctionsOpaquePersonality |
                                         NSPointerFunctionsOpaqueMemory];

  // create & map methods
  jsMethodCount = 0;
  for (unsigned int i = 0; i < methodCount; ++i) {
    SEL selector = method_getName(methods[i]);
    NSString *methodName = NSStringFromSelector(selector);
    if ([methodName hasPrefix:@"js_"]) {
      methodName = [methodName substringFromIndex:3];
      NSRange colonRange = [methodName rangeOfString:@":"];
      if (colonRange.location != NSNotFound) {
        methodName = [methodName substringToIndex:colonRange.location];
      }
      const char *methodNameUTF8 = [methodName UTF8String];
      NSMapInsertKnownAbsent(selectorMap, methodNameUTF8, selector);
      staticFunctions[jsMethodCount].attributes = kJSPropertyAttributeReadOnly;
      staticFunctions[jsMethodCount].name = strdup(methodNameUTF8);
      staticFunctions[jsMethodCount].callAsFunction = JSBMethodCall;
      ++jsMethodCount;
    }
  }
  staticFunctions[jsMethodCount].attributes = 0;
  staticFunctions[jsMethodCount].name = NULL;
  staticFunctions[jsMethodCount].callAsFunction = NULL;

  // create class if it does not exist yet
  JSClassDefinition objectDefinition = kJSClassDefinitionEmpty;
  objectDefinition.attributes = kJSClassAttributeNone;
  objectDefinition.finalize = JSBObjectFinalize;
  objectDefinition.staticFunctions = staticFunctions;
  objectDefinition.convertToType = JSBObjectConvertToTypeCallback;
  JSClassRef objectClass = JSClassCreate(&objectDefinition);

  // instantiate object
  JSObjectRef objectRef =
      JSObjectMake(_context, objectClass, (__bridge_retained void *)object);
  JSClassRelease(objectClass);

  for (unsigned int i = 0; i < jsMethodCount; ++i) {
    free((void *)staticFunctions[i].name);
  }

  JSObjectRef prototypeRef = JSValueToObject(
      _context, JSObjectGetPrototype(_context, objectRef), NULL);
  JSPropertyNameArrayRef propertyNameArrayRef =
      JSObjectCopyPropertyNames(_context, prototypeRef);
  size_t propertyCount = JSPropertyNameArrayGetCount(propertyNameArrayRef);

  // assign selectors to methods
  for (size_t i = 0; i < propertyCount; ++i) {
    JSStringRef propertyNameRef =
        JSPropertyNameArrayGetNameAtIndex(propertyNameArrayRef, i);
    JSValueRef propertyRef =
        JSObjectGetProperty(_context, objectRef, propertyNameRef, NULL);
    NSString *propertyName = (__bridge_transfer NSString *)JSStringCopyCFString(
        kCFAllocatorDefault, propertyNameRef);
    SEL selector = NSMapGet(selectorMap, [propertyName UTF8String]);
    if (selector && JSValueIsObject(_context, propertyRef)) {
      JSObjectRef methodRef = JSValueToObject(_context, propertyRef, NULL);
      if (JSObjectIsFunction(_context, methodRef)) {
        NSMapInsertKnownAbsent(_methodMap, methodRef, selector);
      }
    }
  }
  JSPropertyNameArrayRelease(propertyNameArrayRef);

  // now assign object to global scope
  JSStringRef nameRef = JSStringCreateWithCFString((__bridge CFStringRef)name);
  JSObjectSetProperty(
      _context, _global, nameRef, objectRef,
      kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, NULL);
  JSStringRelease(nameRef);
}

- (id)evaluate:(NSString *)script error:(NSError **)error
{
  JSStringRef scriptString =
      JSStringCreateWithCFString((__bridge CFStringRef)script);
  JSValueRef exception = NULL;
  JSValueRef ret =
      JSEvaluateScript(_context, scriptString, NULL, NULL, 0, &exception);
  JSStringRelease(scriptString);

  id object = JSBValueToObject(_context, ret);
  JSGarbageCollect(_context);
  if (error) *error = JSBExceptionToNSError(_context, exception);
  return object;
}

- (id)call:(NSString *)name
    arguments:(NSArray *)arguments
        error:(NSError **)error
{
  JSStringRef nameRef = JSStringCreateWithCFString((__bridge CFStringRef)name);
  JSValueRef methodValue =
      JSObjectGetProperty(_context, _global, nameRef, NULL);
  JSStringRelease(nameRef);

  JSObjectRef methodObject = JSValueToObject(_context, methodValue, NULL);
  JSValueRef argumentArray[arguments.count];

  for (NSUInteger i = 0; i < arguments.count; ++i) {
    argumentArray[i] = JSBObjectToJSValue(_context, arguments[i]);
  }

  JSValueRef exception = NULL;
  JSValueRef ret =
      JSObjectCallAsFunction(_context, methodObject, _global, arguments.count,
                             argumentArray, &exception);

  id object = JSBValueToObject(_context, ret);
  JSGarbageCollect(_context);
  if (error) *error = JSBExceptionToNSError(_context, exception);
  return object;
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
  NSString *methodName = NSStringFromSelector(invocation.selector);
  NSRange colonRange = [methodName rangeOfString:@":"];
  if (colonRange.location != NSNotFound) {
    methodName = [methodName substringToIndex:colonRange.location];
  }
  JSStringRef methodNameRef =
      JSStringCreateWithCFString((__bridge CFStringRef)methodName);
  JSValueRef valueRef =
      JSObjectGetProperty(_context, _global, methodNameRef, NULL);
  JSStringRelease(methodNameRef);
  JSObjectRef objectRef;

  NSMethodSignature *methodSignature = invocation.methodSignature;

  if (JSValueIsObject(_context, valueRef) &&
      (objectRef = JSValueToObject(_context, valueRef, NULL)) &&
      JSObjectIsFunction(_context, objectRef)) {
    NSUInteger argumentCount = methodSignature.numberOfArguments;
    JSValueRef arguments[argumentCount];

#define CASE(C, TF, T, U, F, ...)                                              \
  case C: {                                                                    \
    T value;                                                                   \
    [invocation getArgument:&value atIndex:i + 2];                             \
    arguments[i] = F(_context, value);                                         \
  } break;
    for (NSUInteger i = 0; i < argumentCount - 2; ++i) {
      switch ([methodSignature getArgumentTypeAtIndex:i + 2][0]) {
        CAST_CASES
      default:
        arguments[i] = JSValueMakeUndefined(_context);
      }
    }
#undef CASE

    valueRef = JSObjectCallAsFunction(_context, objectRef, _global,
                                      argumentCount, arguments, NULL);
  }

#define CASE(C, TF, T, F, U, ...)                                              \
  case C: {                                                                    \
    TF T value = (T)F(_context, valueRef, ##__VA_ARGS__);                      \
    [invocation setReturnValue:&value];                                        \
  } break;
  switch ([methodSignature methodReturnType][0]) {
    CAST_CASES
  default: {
    NSUInteger returnLength = [methodSignature methodReturnLength];
    char zero[returnLength];
    memset(zero, 0, returnLength);
    [invocation setReturnValue:&zero];
  }
  }
#undef CASE
}

- (void)dealloc
{
  JSGlobalContextRelease(_context);
#if JSB_USE_DICTIONARY
  JSClassRelease(_dictionaryClass);
#endif // JSB_USE_DICTIONARY
}

@end
