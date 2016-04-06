//
//  HTTPProxyResponse.h
//  SmartThings
//
//  Created by Adam Ahrens on 2/19/16.
//  Copyright © 2016 Physical Graph. All rights reserved.
//

#import "HTTPConnection.h"
#import "HTTPResponse.h"
#import "HTTPMessage.h"

@class HTTPConnection;

@interface HTTPProxyResponse : NSObject <HTTPResponse>
{    
    HTTPMessage *localRequest;
    
    UInt64 fileLength;  // Actual lwngth of the file
    UInt64 fileOffset;  // File offset as pertains to data given to connection
    UInt64 readOffset;  // File offset as pertains to data read from file (but maybe not returned to connection)
    
    NSMutableData __strong *buffer;
    NSData __strong *data;
    
    void *readBuffer;
    NSUInteger readBufferSize;     // Malloced size of readBuffer
    NSUInteger readBufferOffset;   // Offset within readBuffer where the end of existing data is
    NSUInteger readRequestLength;
}

- (id)initWithLocalRequest:(HTTPMessage *)request remoteURLRequest:(NSURL *)url forConnection:(HTTPConnection *)parent;

@end
