JSObjCBridge
============

A *JavaScriptCore* to *Objective-C* bridge.

### API

```objc
- (id)evaluate:(NSString *)script;
```

Evaluates given `script` and returns result as an object.

```objc
- (id)call:(NSString *)name arguments:(NSArray *)arguments;
```

Calls global function with `name`, `arguments` and returns an object.

```objc
- (void)install:(id)object withName:(NSString *)name;
```

Installs given `object` under given `name`, all object instance methods
starting with `js_` are exposed (under names up to first `:` w/o `js_` prefix).

### Example

```objc
- (void)testBridge {

  JSBContext *js = [[JSBContext alloc] init];
  [js install:self withName:@"ext"];

  NSLog(@"=> %@", [js evaluate:@"[ ext.add(2, 2), "
                               @"  ext.uppercase(\"test\"), "
                               @"  ext.testArray([1, 2, 3]), "
                               @"  ext.testDictionary({one:1, two:2}) ]"]);
}

- (NSUInteger)js_add:(NSUInteger)a to:(NSUInteger)b
{
  return a + b;
}

- (NSString *)js_uppercase:(NSString *)string
{
  return [string uppercaseString];
}

- (NSArray *)js_testArray:(NSArray *)array
{
  return [array arrayByAddingObject:@"extra"];
}

- (NSDictionary *)js_testDictionary:(NSDictionary *)dictionary
{
  NSMutableDictionary *mutableDictionary = [dictionary mutableCopy];
  mutableDictionary[@"test"] = @YES;
  return [mutableDictionary copy];
}
```

### License

This software is provided under *MIT* license:

> Copyright (c) 2012 Adam Strzelecki
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
