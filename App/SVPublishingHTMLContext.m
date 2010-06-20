//
//  SVPublishingHTMLContext.m
//  Sandvox
//
//  Created by Mike on 08/04/2010.
//  Copyright 2010 Karelia Software. All rights reserved.
//

#import "SVPublishingHTMLContext.h"

#import "KTHostProperties.h"
#import "SVMediaRepresentation.h"
#import "KTPage.h"
#import "KTPublishingEngine.h"
#import "KTSite.h"

#import "NSString+Karelia.h"
#import "NSURL+Karelia.h"


@implementation SVPublishingHTMLContext

- (void)dealloc
{
    [_publishingEngine release];
    
    [super dealloc];
}

@synthesize publishingEngine = _publishingEngine;

- (void)close;
{
    NSString *HTML = [(NSString *)[self outputWriter] retain];  // -close will release it
    
    [super close];
    
    
    // Generate HTML data
	if (HTML)
    {
        NSStringEncoding encoding = [self encoding];
        NSData *pageData = [HTML dataUsingEncoding:encoding allowLossyConversion:YES];
        OBASSERT(pageData);
        
        
        // Give subclasses a chance to ignore the upload
        KTPublishingEngine *publishingEngine = [self publishingEngine];
        KTPage *page = [self page];
        NSString *fullUploadPath = [[publishingEngine baseRemotePath]
                                    stringByAppendingPathComponent:[page uploadPath]];
        NSData *digest = nil;
        if (![publishingEngine shouldUploadHTML:HTML
                                       encoding:encoding
                                        forPage:page
                                         toPath:fullUploadPath
                                         digest:&digest])
        {
            return;
        }
        
        
        
        // Upload page data. Store the page and its digest with the record for processing later
        if (fullUploadPath)
        {
            CKTransferRecord *transferRecord = [publishingEngine publishData:pageData
                                                                     toPath:fullUploadPath];
            OBASSERT(transferRecord);
            
            if (page) [transferRecord setProperty:page forKey:@"object"];
        }
        
        [HTML release];
    }
}

- (void)writeImageWithIdName:(NSString *)idName
                   className:(NSString *)className
                 sourceMedia:(SVMediaRecord *)media
                         alt:(NSString *)altText
                       width:(NSNumber *)width
                      height:(NSNumber *)height;
{
    SVMediaRepresentation *rep = [[SVMediaRepresentation alloc] initWithMediaRecord:media
                                                                              width:width
                                                                             height:height
                                                                           fileType:(NSString *)kUTTypePNG];
    
    KTPublishingEngine *pubEngine = [self publishingEngine];
    NSString *path = [pubEngine publishMediaRepresentation:rep];
    [rep release];
    
    NSString *basePath = [pubEngine baseRemotePath];
    if (![basePath hasSuffix:@"/"]) basePath = [basePath stringByAppendingString:@"/"];
    NSString *relPath = [path pathRelativeToPath:basePath];
    
    [self writeImageWithIdName:idName
                     className:className
                           src:relPath
                           alt:altText
                         width:[width description]
                        height:[height description]];
}

- (NSURL *)addResourceWithURL:(NSURL *)resourceURL;
{
    [super addResourceWithURL:resourceURL];
    [[self publishingEngine] publishResourceAtURL:resourceURL];
    
    return [[[[self page] site] hostProperties] URLForResourceFile:
            [resourceURL lastPathComponent]];
}

@end
