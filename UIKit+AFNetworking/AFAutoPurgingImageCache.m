// AFAutoPurgingImageCache.m
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <TargetConditionals.h>

#if TARGET_OS_IOS || TARGET_OS_TV 

#import "AFAutoPurgingImageCache.h"
//缓存对象包装类
@interface AFCachedImage : NSObject
//缓存的图片
@property (nonatomic, strong) UIImage *image;
//id
@property (nonatomic, copy) NSString *identifier;
//图片字节大小
@property (nonatomic, assign) UInt64 totalBytes;
//淘汰算法是LRU所以需要记录上次访问时间
@property (nonatomic, strong) NSDate *lastAccessDate;
//没用到的属性
@property (nonatomic, assign) UInt64 currentMemoryUsage;

@end

@implementation AFCachedImage
//初始化构函数
- (instancetype)initWithImage:(UIImage *)image identifier:(NSString *)identifier {
    if (self = [self init]) {
        self.image = image;
        self.identifier = identifier;
        //计算图片的字节大小，每个像素占4字节32位
        CGSize imageSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
        CGFloat bytesPerPixel = 4.0;
        CGFloat bytesPerSize = imageSize.width * imageSize.height;
        self.totalBytes = (UInt64)bytesPerPixel * (UInt64)bytesPerSize;
        self.lastAccessDate = [NSDate date];
    }
    return self;
}
//通过缓存对象获取图片时要更新上次访问时间为当前时间
- (UIImage *)accessImage {
    //直接使用NSDate
    self.lastAccessDate = [NSDate date];
    return self.image;
}

- (NSString *)description {
    NSString *descriptionString = [NSString stringWithFormat:@"Idenfitier: %@  lastAccessDate: %@ ", self.identifier, self.lastAccessDate];
    return descriptionString;

}

@end
//AFNetworking缓存类的猪脚
@interface AFAutoPurgingImageCache ()
//可变字典用于存储所有的缓存对象AFCachedImage对象，key为字符串类型
@property (nonatomic, strong) NSMutableDictionary <NSString* , AFCachedImage*> *cachedImages;
//当前缓存对象内存占用大小
@property (nonatomic, assign) UInt64 currentMemoryUsage;
//用于线程安全防止产生竞争条件，没有用锁
@property (nonatomic, strong) dispatch_queue_t synchronizationQueue;
@end

@implementation AFAutoPurgingImageCache
//构造函数，默认内存占用100M，每次清除缓存到60M
- (instancetype)init {
    return [self initWithMemoryCapacity:100 * 1024 * 1024 preferredMemoryCapacity:60 * 1024 * 1024];
}
//构造函数
- (instancetype)initWithMemoryCapacity:(UInt64)memoryCapacity preferredMemoryCapacity:(UInt64)preferredMemoryCapacity {
    if (self = [super init]) {
        self.memoryCapacity = memoryCapacity;
        self.preferredMemoryUsageAfterPurge = preferredMemoryCapacity;
        self.cachedImages = [[NSMutableDictionary alloc] init];
        //创建一个并行队列，但后面使用时都是在同步情况或barrier情况下，队列中的任务还是以串行执行
        //可以防止产生竞争条件，保证线程安全
        NSString *queueName = [NSString stringWithFormat:@"com.alamofire.autopurgingimagecache-%@", [[NSUUID UUID] UUIDString]];
        self.synchronizationQueue = dispatch_queue_create([queueName cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_CONCURRENT);

        //添加通知，监听收到系统的内存警告后删除所有缓存对象
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(removeAllImages)
         name:UIApplicationDidReceiveMemoryWarningNotification
         object:nil];

    }
    return self;
}
//析构函数，删除通知的监听
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
//memoryUsage的getter
- (UInt64)memoryUsage {
    __block UInt64 result = 0;
    dispatch_sync(self.synchronizationQueue, ^{
        result = self.currentMemoryUsage;
    });
    return result;
}
//添加图片到缓存中
- (void)addImage:(UIImage *)image withIdentifier:(NSString *)identifier {
    //使用dispatch_barrier_async不阻塞当前线程，不阻塞向队列中添加任务
    //但队列中其他任务要执行就必须等待前一个任务结束，不管是不是并发队列
    dispatch_barrier_async(self.synchronizationQueue, ^{
        //创建AFCachedImage对象
        AFCachedImage *cacheImage = [[AFCachedImage alloc] initWithImage:image identifier:identifier];
        //判断对应id是否已经保存在缓存字典中了
        AFCachedImage *previousCachedImage = self.cachedImages[identifier];
        //如果已经保存了减去占用的内存大小
        if (previousCachedImage != nil) {
            self.currentMemoryUsage -= previousCachedImage.totalBytes;
        }
        //更新字典，更新占用内存大小
        self.cachedImages[identifier] = cacheImage;
        self.currentMemoryUsage += cacheImage.totalBytes;
    });
    //同上，该block必须等待前一个block执行完成才可以执行
    dispatch_barrier_async(self.synchronizationQueue, ^{
        //判断当前占用内存大小是否超过了设置的内存缓存总大小
        if (self.currentMemoryUsage > self.memoryCapacity) {
            //计算需要释放多少空间
            UInt64 bytesToPurge = self.currentMemoryUsage - self.preferredMemoryUsageAfterPurge;
           //把缓存字典中的所有缓存对象取出
            NSMutableArray <AFCachedImage*> *sortedImages = [NSMutableArray arrayWithArray:self.cachedImages.allValues];
            //设置排序描述器，按照上次访问时间排序
            NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"lastAccessDate"
                                                                           ascending:YES];
            //排序取出的所有缓存对象
            [sortedImages sortUsingDescriptors:@[sortDescriptor]];

            UInt64 bytesPurged = 0;
            //遍历，释放缓存对象，满足要求后break
            for (AFCachedImage *cachedImage in sortedImages) {
                [self.cachedImages removeObjectForKey:cachedImage.identifier];
                bytesPurged += cachedImage.totalBytes;
                if (bytesPurged >= bytesToPurge) {
                    break;
                }
            }
            //更新当前占用缓存大小
            self.currentMemoryUsage -= bytesPurged;
        }
    });
}
//删除图片
- (BOOL)removeImageWithIdentifier:(NSString *)identifier {
    __block BOOL removed = NO;
    //同步方法
    dispatch_barrier_sync(self.synchronizationQueue, ^{
        AFCachedImage *cachedImage = self.cachedImages[identifier];
        if (cachedImage != nil) {
            [self.cachedImages removeObjectForKey:identifier];
            self.currentMemoryUsage -= cachedImage.totalBytes;
            removed = YES;
        }
    });
    return removed;
}
//删除所有图片
- (BOOL)removeAllImages {
    __block BOOL removed = NO;
    //同步方法
    dispatch_barrier_sync(self.synchronizationQueue, ^{
        if (self.cachedImages.count > 0) {
            [self.cachedImages removeAllObjects];
            self.currentMemoryUsage = 0;
            removed = YES;
        }
    });
    return removed;
}
//根据id获取图片
- (nullable UIImage *)imageWithIdentifier:(NSString *)identifier {
    __block UIImage *image = nil;
    dispatch_sync(self.synchronizationQueue, ^{
        AFCachedImage *cachedImage = self.cachedImages[identifier];
        //更新访问时间
        image = [cachedImage accessImage];
    });
    return image;
}
//AFImageRequestCache协议的方法，通过request构造一个key然后调用前面的方法
- (void)addImage:(UIImage *)image forRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    [self addImage:image withIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}
//同上
- (BOOL)removeImageforRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    return [self removeImageWithIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}
//同上
- (nullable UIImage *)imageforRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    return [self imageWithIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}
//通过request和额外的id构造一个key
- (NSString *)imageCacheKeyFromURLRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)additionalIdentifier {
    //取图片的URI然后追加额外的id构造key
    NSString *key = request.URL.absoluteString;
    if (additionalIdentifier != nil) {
        key = [key stringByAppendingString:additionalIdentifier];
    }
    return key;
}

- (BOOL)shouldCacheImage:(UIImage *)image forRequest:(NSURLRequest *)request withAdditionalIdentifier:(nullable NSString *)identifier {
    return YES;
}

@end
/**
 AFAutoPurgingImageCache的实现很简单，逻辑也都很简单，不再赘述了。它的淘汰算法采用的是LRU，从源码中其实也可以看出缺点挺多的，比如上次访问时间使用NSDate类，使用UNIX时间戳应该更好，不仅内存占用小排序也更快吧。淘汰缓存时需要从缓存字典中取出所有的缓存对象然后根据NSDate排序，如果有大量缓存图片，这里似乎就是一个性能瓶颈，但它的优点就是实现简单明了，对于性能要求不高的程序选择这个也没有太多影响。
 */

#endif
