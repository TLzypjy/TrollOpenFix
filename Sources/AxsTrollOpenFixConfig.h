#pragma once

#import <Foundation/Foundation.h>

@interface AxsTrollOpenFixConfig : NSObject
+ (instancetype)axs_trollopenfix_shared;
- (BOOL)axs_trollopenfix_isEnabled;
- (id)axs_trollopenfix_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_trollopenfix_reload;
@end
