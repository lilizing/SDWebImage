/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import <ImageIO/ImageIO.h>

NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";

static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

@interface SDWebImageDownloader ()
//任务队列
@property (strong, nonatomic) NSOperationQueue *downloadQueue;
@property (strong, nonatomic) NSMutableDictionary *URLCallbacks;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t workingQueue;//工作队列
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t barrierQueue;//？？队列

@end

@implementation SDWebImageDownloader

+ (void)initialize
{
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator"))
    {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}
//使用GCD做单例实现
+ (SDWebImageDownloader *)sharedDownloader
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    if ((self = [super init]))
    {
        _downloadQueue = NSOperationQueue.new;
        _downloadQueue.maxConcurrentOperationCount = 2;
        _URLCallbacks = NSMutableDictionary.new;
        //创建同步队列，串行的
        _workingQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloader", DISPATCH_QUEUE_SERIAL);
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);//创建并发队列
    }
    return self;
}

- (void)dealloc
{
    [self.downloadQueue cancelAllOperations];
    SDDispatchQueueRelease(_workingQueue);
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads
{
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSInteger)maxConcurrentDownloads
{
    return _downloadQueue.maxConcurrentOperationCount;
}
//下载实现
- (id<SDWebImageOperation>)downloadImageWithURL:(NSURL *)url options:(SDWebImageDownloaderOptions)options progress:(void (^)(NSUInteger, long long))progressBlock completed:(void (^)(UIImage *, NSData *, NSError *, BOOL))completedBlock
{
    __block SDWebImageDownloaderOperation *operation;
    __weak SDWebImageDownloader *wself = self;//避免所有权回环
    
    //NSLog(@"%@",[url query]);

    [self addProgressCallback:progressBlock andCompletedBlock:completedBlock forURL:url createCallback:^
    {
        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests
        //为了避免重复缓存（NSURLCache + SDImageCache），我们禁用请求的默认缓存
        NSMutableURLRequest *request = [NSMutableURLRequest.alloc initWithURL:url cachePolicy:NSURLCacheStorageNotAllowed timeoutInterval:15];
        request.HTTPShouldHandleCookies = NO;
        request.HTTPShouldUsePipelining = YES;
        [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];
        operation = [SDWebImageDownloaderOperation.alloc initWithRequest:request queue:self.workingQueue options:options progress:^(NSUInteger receivedSize, long long expectedSize)
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            NSArray *callbacksForURL = [sself callbacksForURL:url];
            for (NSDictionary *callbacks in callbacksForURL)
            {
                SDWebImageDownloaderProgressBlock callback = callbacks[kProgressCallbackKey];
                if (callback) callback(receivedSize, expectedSize);
            }
        }
        completed:^(UIImage *image, NSData *data, NSError *error, BOOL finished)
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            NSArray *callbacksForURL = [sself callbacksForURL:url];
            if (finished)
            {
                [sself removeCallbacksForURL:url];
            }
            for (NSDictionary *callbacks in callbacksForURL)
            {
                SDWebImageDownloaderCompletedBlock callback = callbacks[kCompletedCallbackKey];
                if (callback) callback(image, data, error, finished);
            }
        }
        cancelled:^
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            [sself callbacksForURL:url];
            [sself removeCallbacksForURL:url];
        } name:[url query]];
        [self.downloadQueue addOperation:operation];
    }];

    return operation;
}

//以下三个非主方法（这里主方法指下载方法，即downloadImageWithURL）内部创建异步代码，且做了线程安全，这样使得外部调用这三个方法是本身就是异步的，提高效率，无需外部创建线程

//该方法的作用为：添加一个下载任务，为线程安全，需要做同步控制
//dispatch_barrier_sync用来做同步控制，相当于为相应的代码加同步锁
- (void)addProgressCallback:(void (^)(NSUInteger, long long))progressBlock andCompletedBlock:(void (^)(UIImage *, NSData *data, NSError *, BOOL))completedBlock forURL:(NSURL *)url createCallback:(void (^)())createCallback
{
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        BOOL first = NO;
        if (!self.URLCallbacks[url])
        {
            self.URLCallbacks[url] = NSMutableArray.new;
            first = YES;
        }

        // Handle single download of simultaneous download request for the same URL
        NSMutableArray *callbacksForURL = self.URLCallbacks[url];
        NSMutableDictionary *callbacks = NSMutableDictionary.new;
        if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
        if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
        [callbacksForURL addObject:callbacks];
        self.URLCallbacks[url] = callbacksForURL;

        if (first)
        {
            createCallback();
        }
    });
}


- (NSArray *)callbacksForURL:(NSURL *)url
{
    __block NSArray *callbacksForURL;
    
    //dispatch_sync，它干的事儿和dispatch_async相同，但是它会等待block中的代码执行完成并返回
    dispatch_sync(self.barrierQueue, ^
    {
        callbacksForURL = self.URLCallbacks[url];
    });
    return callbacksForURL;
}

//dispatch_barrier_sync用来做同步控制，相当于为相应的代码加同步锁
- (void)removeCallbacksForURL:(NSURL *)url
{
    //dispatch_barrier_async是在前面的任务执行结束后它才执行，而且它后面的任务等它执行完成之后才会执行，当然是这些任务是同一个queue
    dispatch_barrier_async(self.barrierQueue, ^
    {
        [self.URLCallbacks removeObjectForKey:url];
    });
}

@end
