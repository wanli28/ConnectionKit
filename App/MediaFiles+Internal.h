//
//  KTMediaFile+MediaManagerPrivate.h
//  Marvel
//
//  Created by Mike on 07/11/2007.
//  Copyright 2007 Karelia Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "KTMediaFile.h"
#import "KTExternalMediaFile.h"
#import "KTInDocumentMediaFile.h"


@class KTImageScalingSettings;


@interface KTMediaFile (Internal)

+ (id)insertMediaFileWithPath:(NSString *)path inManagedObjectContext:(NSManagedObjectContext *)moc;

- (NSString *)preferredFileName;

@end


@interface KTExternalMediaFile (MediaManager)
+ (KTExternalMediaFile *)insertExternalMediaFileWithPath:(NSString *)path
						  inManagedObjectContext:(NSManagedObjectContext *)moc;
@end


@interface KTInDocumentMediaFile (MediaManager)

+ (KTInDocumentMediaFile *)insertTemporaryMediaFileWithPath:(NSString *)path
						   inManagedObjectContext:(NSManagedObjectContext *)moc;

@end