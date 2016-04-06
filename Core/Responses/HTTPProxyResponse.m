//
//  HTTPProxyResponse.m
//  SmartThings
//
//  Created by Adam Ahrens on 2/19/16.
//  Copyright © 2016 Physical Graph. All rights reserved.
//

#import "HTTPProxyResponse.h"
#import "HTTPLogging.h"
#import "HTTPMessage.h"

#import <unistd.h>
#import <fcntl.h>

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

// Log levels : off, error, warn, info, verbose
// Other flags: trace
static const int httpLogLevel = HTTP_LOG_FLAG_TRACE;

// Define chunk size used to read in data for responses
// This is how much data will be read from disk into RAM at a time
#if TARGET_OS_IPHONE
#define READ_CHUNKSIZE  (1024 * 128)
#else
#define READ_CHUNKSIZE  (1024 * 512)
#endif

// Define the various timeouts (in seconds) for various parts of the HTTP process
#define TIMEOUT_READ_FIRST_HEADER_LINE       30
#define TIMEOUT_READ_SUBSEQUENT_HEADER_LINE  30
#define TIMEOUT_READ_BODY                    -1
#define TIMEOUT_WRITE_HEAD                   30
#define TIMEOUT_WRITE_ERROR                  30

// Define the various limits
// LIMIT_MAX_HEADER_LINE_LENGTH: Max length (in bytes) of any single line in a header (including \r\n)
// LIMIT_MAX_HEADER_LINES      : Max number of lines in a single header (including first GET line)
#define LIMIT_MAX_HEADER_LINE_LENGTH  8190
#define LIMIT_MAX_HEADER_LINES         100

// Define the various tags we'll use to differentiate what it is we're currently doing
#define HTTP_REQUEST_HEADER                10

#define HTTP_RESPONSE_HEADER                 92
#define HTTP_RESPONSE_BODY                   93
#define HTTP_FINAL_RESPONSE                  91

@interface HTTPProxyResponse ()

@property (strong, nonatomic) NSURL *remoteURL;
@property (weak, nonatomic) HTTPConnection *connection;
@property (strong, nonatomic) HTTPMessage *remoteResponse;

@end

@implementation HTTPProxyResponse

- (id)initWithLocalRequest:(HTTPMessage *)request remoteURLRequest:(NSURL *)url forConnection:(HTTPConnection *)parent
{
    if ((self = [super init]))
    {
        self.connection = parent; // Parents retain children, children do NOT retain parents
        localRequest = request;
        self.remoteURL = url;
        
        NSMutableURLRequest * mutableRequest = [NSMutableURLRequest requestWithURL:url];
        mutableRequest.HTTPMethod = [request method];
        
        NSURLCredentialStorage *credentialStorage;
        if ([[request headerField:@"username"] length] > 0 && [[request headerField:@"password"] length] > 0) {
            NSURLCredential *credentials = [[NSURLCredential alloc] initWithUser:[request headerField:@"username"] password:[request headerField:@"password"] persistence:NSURLCredentialPersistenceForSession];
            NSURLProtectionSpace *protectionSpace = [[NSURLProtectionSpace alloc] initWithHost:url.host port:url.port.integerValue protocol:url.scheme realm:@"iPolis" authenticationMethod:NSURLAuthenticationMethodHTTPDigest];
            credentialStorage = [NSURLCredentialStorage sharedCredentialStorage];
        }
        
        // Add all of the original request headers to the proxy request headers
        [[request allHeaderFields] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            if (![key isEqualToString:@"camera-data"]) {
                [mutableRequest setValue:value forHTTPHeaderField:key];
            }
        }];
        
        if ([mutableRequest.HTTPMethod isEqualToString:@"PUT"]) {
            // Add a body if the request has one
            if ([[request headerField:@"camera-data"] length] > 0) {
                mutableRequest.HTTPBody = [[request headerField:@"camera-data"] dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
        
        
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
        
        if (credentialStorage) {
            sessionConfiguration.URLCredentialStorage = credentialStorage;
        }
        
        // Create a semaphore to ensure synchronous execution. Need that so the proxy request
        // responds to the exact previous request
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:mutableRequest completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
            
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            
            if (error) {
                // Request errored
                self.remoteResponse = [[HTTPMessage alloc] initResponseWithStatusCode:httpResponse.statusCode description:[NSHTTPURLResponse localizedStringForStatusCode:httpResponse.statusCode] version:HTTPVersion1_1];
            } else {
                self.remoteResponse = [[HTTPMessage alloc] initResponseWithStatusCode:httpResponse.statusCode description:[NSHTTPURLResponse localizedStringForStatusCode:httpResponse.statusCode] version:HTTPVersion1_1];
                [self.remoteResponse setHeaderField:@"Access-Control-Allow-Methods" value:@"GET, POST, OPTIONS, PUT, PATCH, DELETE"];
                [self.remoteResponse setHeaderField:@"Access-Control-Allow-Credentials" value:@"true"];
                [self.remoteResponse setHeaderField:@"Access-Control-Allow-Headers" value:@"content-type,authorization,username,password"];
                [self.remoteResponse setHeaderField:@"Access-Control-Allow-Origin" value:@"null"];
                [self.remoteResponse setHeaderField:@"Access-Control-Expose-Headers" value:@"content-type, content-length, connection, date, server, x-www-authenticate"];
                
                [httpResponse.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
                    
                    NSString *headerKey = key;
                    if ([key compare:@"www-authenticate" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                        // Don't want the default www-authenticate that is used by the browser
                        // change to x-www-authenticate
                        headerKey = @"x-www-authenticate";
                    } else if ([headerKey compare:@"Content-Length" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                        if ([obj isKindOfClass:[NSString class]]) {
                            NSString *fileLengthString = (NSString *)obj;
                            fileLength = [fileLengthString intValue];
                        }
                    } else if ([headerKey compare:@"Transfer-Encoding" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                        obj = @"chunked";
                    }
                    
                    [self.remoteResponse setHeaderField:headerKey value:obj];
                }];
                
                data = responseData;
                [self.remoteResponse setBody:responseData];
            }
            
            NSLog(@"Proxy Response is %@", self.remoteResponse);
            
            // Semaphore is complete
            dispatch_semaphore_signal(semaphore);
        }];
        
        // Start the request
        [dataTask resume];
        
        // Wait for the semaphore to complete
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    }
    
    return self;
}

#pragma mark - HTTPMessage Protocol

- (NSDictionary *)httpHeaders {
    return [self.remoteResponse allHeaderFields];
}

- (BOOL)delayResponseHeaders {
    return NO;
}

- (NSData *)readDataOfLength:(NSUInteger)lengthParameter {
    if ([data length] == 0) {
        data = [@"OK" dataUsingEncoding:NSUTF8StringEncoding];
    }
    
    NSUInteger remaining = [data length] - self.offset;
    NSUInteger length = lengthParameter < remaining ? lengthParameter : remaining;
    void *bytes = (void *)([data bytes] + self.offset);
    self.offset += length;
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:NO];
}

- (UInt64)contentLength
{
    return fileLength;
}

- (UInt64)offset
{
    return fileOffset;
}

- (void)setOffset:(UInt64)offset
{
    fileOffset = offset;
    readOffset = offset;
}

- (BOOL)isDone
{
    if (!data) {
        return YES;
    }
    
    BOOL result = (self.offset == [data length]);
    VIDLogInfo(@"%@[%p]: isDone - %@", THIS_FILE, self, (result ? @"YES" : @"NO"));
    return result;
}

- (NSInteger)status {
    return self.remoteResponse.statusCode;
}

- (BOOL)isChunked {
    return fileLength == 0;
}

#pragma mark - Helpers

- (NSString *)description {
    NSMutableString *proxyResponse = [[NSMutableString alloc] init];
    [proxyResponse appendFormat:@"%@ at %@, version: %@\n\n", [self.remoteResponse method], [self.remoteResponse url], [self.remoteResponse version]];
    [proxyResponse appendFormat:@"Headers - %@\n\n", [self.remoteResponse allHeaderFields]];
    NSData *body = [self.remoteResponse body];
    if (body) {
        NSString *bodyString = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        [proxyResponse appendFormat:@"Body - %@", bodyString];
    }
    
    return proxyResponse;
}

@end
