//
//  KTDataMigrator.m
//  KTComponents
//
//  Created by Terrence Talbot on 8/31/05.
//  Copyright 2005 Biophony LLC. All rights reserved.
//

#import "KTDataMigrator.h"

#import "KT.h"
#import "KTDesign.h"
#import "KTDocument.h"
#import "KTDocumentInfo.h"
#import "KTElementPlugin.h"
#import "KTMaster.h"
#import "KTPage.h"
#import "KTUtilities.h"

#import "KTStoredArray.h"
#import "KTStoredDictionary.h"
#import "KTStoredSet.h"

#import "NSArray+Karelia.h"
#import "NSData+Karelia.h"
#import "NSError+Karelia.h"
#import "NSManagedObject+KTExtensions.h"
#import "NSManagedObjectContext+KTExtensions.h"
#import "NSManagedObjectModel+KTExtensions.h"
#import "NSSortDescriptor+Karelia.h"
#import "NSString+Karelia.h"

#import "Debug.h"



/*
 
 Note: We have these fields in the current data model, which we might want to update:
 
 addBool1 -- exclude from site map
 addString1	-- currently used to hold the FLOAT of the image replacement font adjustment
 addString2 -- encoded dictionary with lots of other parameters
 
 Note: "isStale" does not seem to be used.  See staleness.
 */


@interface KTDataMigrator ()

+ (void)recoverFailedUpgradeWithPath:(NSString *)upgradePath backupPath:(NSString *)backupPath;

- (NSManagedObject *)correspondingObjectForObject:(NSManagedObject *)anObject;


// Generic migration methods
- (NSSet *)matchingAttributesFromObject:(NSManagedObject *)oldObject toObject:(NSManagedObject *)newObject;
- (void)migrateMatchingAttributesFromObject:(NSManagedObject *)managedObjectA toObject:(NSManagedObject *)managedObjectB;
- (void)migrateAttributes:(NSSet *)attributeKeys fromObject:(NSManagedObject *)oldObject toObject:(NSManagedObject *)newObject;

- (void)migrateAbstractPluginRelationshipsFromObject:(NSManagedObject *)managedObjectA
											toObject:(NSManagedObject *)managedObjectB;


// Element migration
- (BOOL)migrateCodeInjection:(NSString *)code toKey:(NSString *)newKey propogate:(BOOL)propogate
                    fromPage:(NSManagedObject *)oldPage toPage:(KTPage *)newPage error:(NSError **)error;

- (BOOL)migrateChildrenFromPage:(NSManagedObject *)oldParentPage toPage:(KTPage *)newParentPage error:(NSError **)error;
- (BOOL)migrateRoot:(NSError **)error;

- (BOOL)migratePageletsFromPage:(NSManagedObject *)oldPage toPage:(KTPage *)newPage error:(NSError **)error;

+ (NSSet *)elementAttributesToIgnore;
- (BOOL)migrateElementContainer:(NSManagedObject *)oldElementContainer toElement:(KTAbstractElement *)newElement error:(NSError **)error;
- (BOOL)migrateElement:(NSManagedObject *)oldElement toElement:(KTAbstractElement *)newElement error:(NSError **)error;



- (BOOL)migrateFromMediaRef:(NSManagedObject *)mediaRefA toMediaRef:(NSManagedObject *)mediaRefB;
- (BOOL)migrateMedia:(NSError **)error;

- (BOOL)migrateDocumentInfo:(NSError **)error;


+ (BOOL)validatePathForNewStore:(NSString *)aStorePath error:(NSError **)outError;
- (BOOL)isValidManagedObject:(NSManagedObject *)aManagedObject;
@end


/*! model changes, by version:
 
 10000: shipped w/ public betas b11, b12
 base version
 
 10001: shipped w/ public beta b13
 Media added isPublished, a boolean attribute, with a default of NO
 
 10002: shipped w/ beta b15
 DocumentInfo added siteID, a string, meant to store a GUID
 Page added useAbsoluteLinks, an optional boolean with no default
 Page added shortenedTitleHTML, an optional string with no default
 Page added pageTitleFormat, an optional string with no default
 Page changed shortTitle to fileName, still an optional string with no default
 Media added cachedImages, an optional to-many relationship to CachedImage
 added CachedImage, a new entity for storing info about ~/Library/Caches/Sandvox/<Images>
 
 15001: Brand new model for 1.5. Too many changes to list here.
 
 */


#pragma mark -


@implementation KTDataMigrator

+ (void)crashKTDataMigrator
{
	*((int*)(-1)) = 0;
}

/*! upgrades the document, in-place, returning whether procedure was successful */
+ (BOOL)upgradeDocumentWithURL:(NSURL *)aStoreURL modelVersion:(NSString *)aVersion error:(NSError **)outError
{
	OBPRECONDITION(aStoreURL);
    OBPRECONDITION([aStoreURL isFileURL]);
    
    
    // move the original to a new location
	NSString *originalPath = [aStoreURL path];
	NSString *destinationPath = [KTDataMigrator renamedFileName:originalPath modelVersion:aVersion];
	
	BOOL originalMoved = [[NSFileManager defaultManager] movePath:originalPath toPath:destinationPath handler:nil];
	if (!originalMoved)
	{
		// we cannot proceed, pass back an error and return NO
		NSString *errorDescription = [NSString stringWithFormat:
                                      NSLocalizedString(@"Unable to rename document from %@ to %@. Upgrade cannot be completed.","Alert: Unable to rename document from %@ to %@. Upgrade cannot be completed."),
                                      originalPath, destinationPath];
		
		NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError localizedDescription:errorDescription];
		*outError = error;
		
		return NO;
	}
	
    
	// Use the original URL as our newStoreURL
	BOOL result = NO;
    NSURL *newStoreURL = [aStoreURL copy];
	
    @try        // This means that you can call return and @finally code will still be called. Just make sure result is set.
    {
        if (!newStoreURL || ![newStoreURL isFileURL])
        {
            NSString *errorDescription = [NSString stringWithFormat:
                                          NSLocalizedString(@"Unable to upgrade document at path %@. Path does not appear to be a file.","Alert: Unable to upgrade document at path %@. Path does not appear to be a file."), [newStoreURL path]];
            
            NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInvalidFileNameError localizedDescription:errorDescription];
            *outError = error;
            
            result = NO;    return result;
        }
        
        
        // Check that we have a good path and we can write to it
        if (![KTDataMigrator validatePathForNewStore:[newStoreURL path] error:outError])
        {
            result = NO;    return result;
        }
        
        
        // make a migrator instance
        KTDataMigrator *migrator = [[KTDataMigrator alloc] init];
        
        // set old and new store URLs
        [migrator setOldStoreURL:[NSURL fileURLWithPath:destinationPath]];
        [migrator setNewDocumentURL:newStoreURL];
        
        // migrate!
        NSError *localError = nil;
        result = [migrator genericallyMigrateDataFromOldModelVersion:aVersion error:&localError];
        
        if (!result)
        {
            if (localError)
            {
                *outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSCannotUpgrade localizedDescription:
                             [NSString stringWithFormat:
                              NSLocalizedString(@"Unable to migrate document data from %@ to %@, reason: %@.","Alert: Unable to migrate document data from %@ to %@, reason: %@."),
                              [[aStoreURL path] lastPathComponent], [[newStoreURL path] lastPathComponent], localError]];
            }
            else
            {
                *outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSCannotUpgrade localizedDescription:
                             [NSString stringWithFormat:
                              NSLocalizedString(@"Unable to migrate document data from %@ to %@.","Alert: Unable to migrate document data from %@ to %@."),
                              [[aStoreURL path] lastPathComponent], [[newStoreURL path] lastPathComponent]]];
            }
        }
        
        [migrator release];
    }
    @catch (NSException *exception)
    {
        result = NO;
        [exception raise];
    }
    @finally
    {
        // Failed migrations should revert the old file
        if (!result)
        {
            [self recoverFailedUpgradeWithPath:originalPath backupPath:destinationPath];
        }
        
        // Tidy up
        [newStoreURL release];
    }
    
    
    return result;
}

+ (void)recoverFailedUpgradeWithPath:(NSString *)upgradePath backupPath:(NSString *)backupPath
{
    // It doesn't matter if either of these methods fail, we're just doing our best to recover.
    [[NSFileManager defaultManager] removeFileAtPath:upgradePath handler:nil];
    [[NSFileManager defaultManager] movePath:backupPath toPath:upgradePath handler:nil];
}


/*  Provides a lookup table for converting old plugin identifiers to new.
 */
+ (NSString *)newPluginIdentifierForOldPluginIdentifier:(NSString *)oldIdentifier
{
    OBPRECONDITION(oldIdentifier);
    
    static NSDictionary *sPluginIdentifiers;
    if (!sPluginIdentifiers)
    {
        sPluginIdentifiers = [[NSDictionary alloc] initWithObjectsAndKeys:
                              @"sandvox.RichTextElement", @"sandvox.TextPage",
                              @"sandvox.RichTextElement", @"sandvox.TextPagelet",
                              @"sandvox.RichTextElement", @"sandvox.TextElement",
                              @"sandvox.ImageElement", @"sandvox.ImageElement",
                              @"sandvox.ImageElement", @"sandvox.PhotoPagelet",
                              @"sandvox.ImageElement", @"sandvox.PhotoPage",
                              @"sandvox.AmazonElement", @"sandvox.AmazonList",
                              @"sandvox.BadgeElement", @"sandvox.BadgePagelet",
                              @"sandvox.ContactElement", @"sandvox.ContactElement",
                              @"sandvox.ContactElement", @"sandvox.ContactPage",
                              @"sandvox.ContactElement", @"sandvox.ContactPagelet",
                              @"sandvox.DeliciousElement", @"sandvox.DeliciousPagelet",
                              @"sandvox.DiggElement", @"sandvox.DiggPagelet",
                              @"sandvox.DownloadElement", @"sandvox.FileDownload",
                              @"sandvox.FeedElement", @"sandvox.FeedPagelet",
                              @"sandvox.FlickrElement", @"sandvox.FlickrPagelet",
                              @"sandvox.HTMLElement", @"sandvox.HTMLElement",
                              @"sandvox.HTMLElement", @"sandvox.HTMLPage",
                              @"sandvox.HTMLElement", @"sandvox.HTMLPagelet",
                              @"sandvox.IFrameElement", @"sandvox.IFramePagelet",
                              @"sandvox.IMStatusElement", @"sandvox.IMPagelet",
                              @"sandvox.IndexElement", @"sandvox.IndexPagelet",
                              @"sandvox.LinkElement", @"sandvox.LinkPage",
                              @"sandvox.LinkListElement", @"sandvox.LinkListPagelet",
                              @"sandvox.PageCounterElement", @"com.karelia.pagelet.PageCounter",
                              @"sandvox.RSSBadgeElement", @"sandvox.RSSBadgePagelet",
                              @"sandvox.SiteMapElement", @"sandvox.SiteMapPage",
                              @"sandvox.VideoElement", @"sandvox.VideoElement",
                              @"sandvox.VideoElement", @"sandvox.MoviePage",
                              @"sandvox.VideoElement", @"sandvox.MoviePagelet",
                              nil];
    }
    
    NSString *result = [sPluginIdentifiers objectForKey:oldIdentifier];
    if (!result) result = oldIdentifier;
    
    OBPOSTCONDITION(result);
    return result;
}

#pragma mark -
#pragma mark Init & Dealloc

- (id)init
{
	if ( nil == [super init] )
	{
		return nil;
	}
	
	[self setObjectIDCache:[NSMutableDictionary dictionary]];
	
	return self;
}

- (void)dealloc
{
	[self setNewDocument:nil];
    [self setNewDocumentURL:nil];
    
	[self setOldStoreURL:nil];
	[self setOldManagedObjectContext:nil];
	[self setOldManagedObjectModel:nil];
	[self setObjectIDCache:nil];
	[super dealloc];
}

#pragma mark -
#pragma mark Accessors

- (NSManagedObjectModel *)oldManagedObjectModel
{
    return myOldManagedObjectModel; 
}

- (void)setOldManagedObjectModel:(NSManagedObjectModel *)anOldManagedObjectModel
{
    [anOldManagedObjectModel retain];
    [myOldManagedObjectModel release];
    myOldManagedObjectModel = anOldManagedObjectModel;
}

- (NSManagedObjectContext *)oldManagedObjectContext
{
    return myOldManagedObjectContext; 
}

- (void)setOldManagedObjectContext:(NSManagedObjectContext *)anOldManagedObjectContext
{
    [anOldManagedObjectContext retain];
    [myOldManagedObjectContext release];
    myOldManagedObjectContext = anOldManagedObjectContext;
}

- (NSURL *)oldStoreURL
{
	return myOldStoreURL;
}

- (void)setOldStoreURL:(NSURL *)aStoreURL
{
	[aStoreURL retain];
	[myOldStoreURL release];
	myOldStoreURL = aStoreURL;
}

- (NSManagedObject *)oldDocumentInfo
{
    KTDocumentInfo *result = [[[self oldManagedObjectContext] allObjectsWithEntityName:@"DocumentInfo" error:nil] firstObject];
    return result;
}

- (NSMutableDictionary *)objectIDCache 
{ 
	return myObjectIDCache;
}

- (NSURL *)newDocumentURL { return myNewDocumentURL; }

- (void)setNewDocumentURL:(NSURL *)URL
{
    URL = [URL copy];
    [myNewDocumentURL release];
    myNewDocumentURL = URL;
}

- (KTDocument *)newDocument { return myNewDocument; }

- (void)setNewDocument:(KTDocument *)document
{
    [document retain];
    [myNewDocument release];
    myNewDocument = document;
}

- (NSManagedObjectModel *)newManagedObjectModel
{
    return [[self newDocument] managedObjectModel];
}

- (NSManagedObjectContext *)newManagedObjectContext
{
    return [[self newDocument] managedObjectContext];
}

- (void)setObjectIDCache:(NSMutableDictionary *)anObjectIDCache
{
    [anObjectIDCache retain];
    [myObjectIDCache release];
    myObjectIDCache = anObjectIDCache;
}


#pragma mark -
#pragma mark Migration

- (BOOL)genericallyMigrateDataFromOldModelVersion:(NSString *)aVersion error:(NSError **)error
{
	// Set up old model and Core Data stack
	NSManagedObjectModel *model = [KTUtilities modelWithVersion:aVersion];
    [model makeGeneric];
    [self setOldManagedObjectModel:model];
    
    [self setOldManagedObjectContext:[KTUtilities contextWithURL:[self oldStoreURL] 
														   model:[self oldManagedObjectModel]]];
	
    
    // Set up the new document
    NSManagedObject *oldRoot = [[[self oldManagedObjectContext] objectsWithEntityName:@"Root" predicate:nil error:error] firstObject];
    OBASSERT(oldRoot);
    
    NSString *oldRootPluginIdentifier = [oldRoot valueForKey:@"pluginIdentifier"];
    NSString *newRootPluginIdentifier = [[self class] newPluginIdentifierForOldPluginIdentifier:oldRootPluginIdentifier];
    KTElementPlugin *newRootPlugin = [KTElementPlugin pluginWithIdentifier:newRootPluginIdentifier];
    
    KTDocument *newDoc = [[KTDocument alloc] initWithURL:[self newDocumentURL] ofType:kKTDocumentUTI homePagePlugIn:newRootPlugin error:error];
    if (newDoc)
    {
        [self setNewDocument:newDoc];
        [newDoc release];
    }
    else
    {
        return NO;
    }
	
    
	// Migrate
    if (![self migrateDocumentInfo:error])
    {
        return NO;
    }
    
    if (![self migrateRoot:error])
    {
        return NO;
    }
    
    
    // Save the doc and finish up
    KTDocument *document = [self newDocument];
    BOOL result = [document saveToURL:[document fileURL] ofType:[document fileType] forSaveOperation:NSSaveOperation error:error];
    
    return result;
}

#pragma mark -
#pragma mark Page Migration

/*  Imports an old page and converts it to a new page. The new page must already have been created.
 *  This method operates recursively, importing the children of the old page and so on.
 */
- (BOOL)migratePage:(NSManagedObject *)oldPage toPage:(KTPage *)newPage error:(NSError **)error
{
    // Migrate the matching keys. However, there's a couple of special cases we should NOT import.
    NSMutableSet *matchingKeys = [[self matchingAttributesFromObject:oldPage toObject:newPage] mutableCopy];
    [matchingKeys minusSet:[[self class] elementAttributesToIgnore]];
    [matchingKeys removeObject:@"isStale"];
    
    [self migrateAttributes:matchingKeys fromObject:oldPage toObject:newPage];
    
    [matchingKeys release];
    
    
    // Keywords
    KTStoredArray *keywords = [oldPage valueForKey:@"keywords"];
    [newPage setKeywords:[keywords allValues]];
    
    
    // Migrate Code Injection from the weird old addString2 hack.
    NSString *addString2 = [oldPage valueForKey:@"addString2"];
    if (addString2)
    {
        NSDictionary *addString2Dictionary = [NSData foundationObjectFromEncodedString:addString2];
        
        if (![self migrateCodeInjection:[addString2Dictionary valueForKey:@"insertBody"]
                                  toKey:@"codeInjectionBodyTag"
                              propogate:[addString2Dictionary boolForKey:@"propagateInsertBody"]
                               fromPage:oldPage
                                 toPage:newPage
                                  error:error]) return NO;
        
        if (![self migrateCodeInjection:[addString2Dictionary valueForKey:@"insertEndBody"]
                                  toKey:@"codeInjectionBodyTagEnd"
                              propogate:[addString2Dictionary boolForKey:@"propagateInsertEndBody"]
                               fromPage:oldPage
                                 toPage:newPage
                                  error:error]) return NO;
        
        if (![self migrateCodeInjection:[oldPage valueForKey:@"insertPrelude"]
                                  toKey:@"codeInjectionBeforeHTML"
                              propogate:[addString2Dictionary boolForKey:@"propagateInsertPrelude"]
                               fromPage:oldPage
                                 toPage:newPage
                                  error:error]) return NO;
        
        if (![self migrateCodeInjection:[oldPage valueForKey:@"insertHead"]
                                  toKey:@"codeInjectionHeadArea"
                              propogate:[addString2Dictionary boolForKey:@"propagateInsertHead"]
                               fromPage:oldPage
                                 toPage:newPage
                                  error:error]) return NO;
    }
        
        
    // Migrate custom summary if it exists
    NSString *customSummary = [oldPage valueForKey:@"summaryHTML"];
    if (customSummary && [customSummary isEqualToString:@""])
    {
        [newPage setCustomSummaryHTML:customSummary];
    }
    
    
    // Migrate the special addX properties
    BOOL excludeFromSitemap = [oldPage boolForKey:@"addBool1"];
    [newPage setBool:!excludeFromSitemap forKey:@"includeInSitemap"];
    
    
    // Import plugin-specific properties
    if (![self migrateElementContainer:oldPage toElement:newPage error:error])
    {
        return NO;
    }
    
    
    // Import pagelets
    if (![self migratePageletsFromPage:oldPage toPage:newPage error:error])
    {
        return NO;
    }
    
    
    // Create new KTPage objects for each child page and then recursively migrate them too
    BOOL result = [self migrateChildrenFromPage:oldPage toPage:newPage error:error];
    return result;
}

- (BOOL)migrateCodeInjection:(NSString *)code toKey:(NSString *)newKey propogate:(BOOL)propogate
                    fromPage:(NSManagedObject *)oldPage toPage:(KTPage *)newPage error:(NSError **)error
{
    if (code && ![code isEqualToString:@""])
    {
        if (propogate)
        {
            if ([newPage isRoot])
            {
                [[newPage master] setValue:code forKey:newKey];
            }
            else
            {
                [newPage setValue:code forKey:newKey recursive:YES];
            }
        }
        else
        {
            [newPage setValue:code forKey:newKey];
        }
    }
    
    return YES;
}

/*  Migrate the children of one page to another
 */
- (BOOL)migrateChildrenFromPage:(NSManagedObject *)oldParentPage toPage:(KTPage *)newParentPage error:(NSError **)error
{
    NSSet *oldChildPages = [oldParentPage valueForKey:@"children"];
    NSArray *sortedOldChildren = [[oldChildPages allObjects] sortedArrayUsingDescriptors:[NSSortDescriptor orderingSortDescriptors]];
    
    NSEnumerator *childrenEnumerator = [sortedOldChildren objectEnumerator];
    NSManagedObject *aChildPage;
    while (aChildPage = [childrenEnumerator nextObject])
    {
        // Insert a new child page of the right type.
        NSString *pluginIdentifier = [aChildPage valueForKey:@"pluginIdentifier"];
        pluginIdentifier = [[self class] newPluginIdentifierForOldPluginIdentifier:pluginIdentifier];
        KTElementPlugin *plugin = [KTElementPlugin pluginWithIdentifier:pluginIdentifier];
        
        if (!plugin)
        {
            *error = [NSError errorWithDomain:kKTDataMigrationErrorDomain
                                         code:KareliaError
                         localizedDescription:[NSString stringWithFormat:@"No plugin found with the identifier %@", pluginIdentifier]];
            
            return NO;
        }
        
        KTPage *aNewPage = [KTPage insertNewPageWithParent:newParentPage plugin:plugin];
        
        if (![self migratePage:aChildPage toPage:aNewPage error:error])
        {
            return NO;
        }
    }
    
    
    return YES;
}

/*  Root is special because it contains a bunch of properties which now belong on KTMaster.
 *  Otherwise, we can do normal page migration.
 */
- (BOOL)migrateRoot:(NSError **)error
{
    // Migrate simple properties from Root to the Master
    NSManagedObject *oldRoot = [[self oldDocumentInfo] valueForKey:@"root"];
    OBASSERT(oldRoot);
    
    KTDocumentInfo *newDocInfo = [[self newDocument] documentInfo];
    KTPage *newRoot = [newDocInfo root];
    KTMaster *newMaster = [newRoot master];
    
    [self migrateMatchingAttributesFromObject:oldRoot toObject:newMaster];
    
    
    // Import the design separately
    KTDesign *design = [KTDesign pluginWithIdentifier:[oldRoot valueForKey:@"designBundleIdentifier"]];
    [newMaster setDesign:design];
    
    
    // Media copying and google stuff are document settings
    [newDocInfo setCopyMediaOriginals:[oldRoot integerForKey:@"copyMediaOriginals"]];
    
    BOOL generateGoogleSitemap = [oldRoot boolForKey:@"addBool2"];
    [newDocInfo setBool:generateGoogleSitemap forKey:@"generateGoogleSitemap"];
    
    
    // Migrate the weird old addString2 hack.
    NSString *addString2 = [oldRoot valueForKey:@"addString2"];
    if (addString2)
    {
        NSDictionary *addString2Dictionary = [NSData foundationObjectFromEncodedString:addString2];
		
        [newDocInfo setValue:[addString2Dictionary valueForKey:@"googleAnalytics"] forKey:@"googleAnalyticsCode"];
        [newDocInfo setValue:[addString2Dictionary valueForKey:@"googleSiteVerification"] forKey:@"googleSiteVerification"];
        // TODO: IMPORT BANNER ID.
	}
    
    
    // Continue with normal page migration
    BOOL result = [self migratePage:oldRoot toPage:newRoot error:error];
    
    
    return result;
}

#pragma mark -
#pragma mark Pagelet Migration

- (BOOL)migratePagelet:(NSManagedObject *)oldPagelet toPagelet:(KTPagelet *)newPagelet error:(NSError **)error
{
    // Migrate the matching keys. However, there's a couple of special cases we should NOT import.
    NSMutableSet *matchingKeys = [[self matchingAttributesFromObject:oldPagelet toObject:newPagelet] mutableCopy];
    [matchingKeys minusSet:[[self class] elementAttributesToIgnore]];
    
    [self migrateAttributes:matchingKeys fromObject:oldPagelet toObject:newPagelet];
    
    [matchingKeys release];
    
    
    // Do normal element migration
    BOOL result = [self migrateElementContainer:oldPagelet toElement:newPagelet error:error];
    return result;
}

- (BOOL)migratePageletsFromPage:(NSManagedObject *)oldPage toPage:(KTPage *)newPage error:(NSError **)error
{
    NSSet *oldCallouts = [oldPage valueForKey:@"callouts"];
    NSSet *oldSidebars = [oldPage valueForKey:@"sidebars"];
    
    NSMutableSet *oldPagelets = [oldCallouts mutableCopy];  [oldPagelets unionSet:oldSidebars];
    NSArray *sortedOldPagelets = [[oldPagelets allObjects] sortedArrayUsingDescriptors:[NSSortDescriptor orderingSortDescriptors]];
    [oldPagelets release];
    
    NSEnumerator *oldPageletsEnumerator = [sortedOldPagelets objectEnumerator];
    NSManagedObject *anOldPagelet;
    while (anOldPagelet = [oldPageletsEnumerator nextObject])
    {
        NSString *pageletIdentifier = [[self class] newPluginIdentifierForOldPluginIdentifier:[anOldPagelet valueForKey:@"pluginIdentifier"]];
        KTPageletLocation pageletLocation = ([anOldPagelet valueForKey:@"calloutOwner"]) ? KTCalloutPageletLocation : KTSidebarPageletLocation;
        KTPagelet *newPagelet = [KTPagelet insertNewPageletWithPage:newPage pluginIdentifier:pageletIdentifier location:pageletLocation];
        
        if (![self migratePagelet:anOldPagelet toPagelet:newPagelet error:error])
        {
            return NO;
        }
    }
    
    return YES;
}

#pragma mark -
#pragma mark Element Migration

+ (NSSet *)elementAttributesToIgnore
{
    static NSSet *result;
    if (!result)
    {
        result = [[NSSet alloc] initWithObjects:@"pluginIdentifier", @"pluginVersion", @"ordering", nil];
    }
    
    return result;
}

- (BOOL)migrateElementContainer:(NSManagedObject *)oldElementContainer toElement:(KTAbstractElement *)newElement error:(NSError **)error
{
    // 1.5 doesn't support the old nested element hierarchy. Instead we do the import from the subelement
    NSManagedObject *oldElement = oldElementContainer;
    NSSet *subelements = [oldElementContainer valueForKey:@"elements"];
    if ([subelements count] > 0)
    {
        oldElement = [subelements anyObject];
    }
    
    BOOL result = [self migrateElement:oldElement toElement:newElement error:error];
    return result;
}

/*  Handles generic migration of elements. Mostly this comprises moving over plugin properties.
 */
- (BOOL)migrateElement:(NSManagedObject *)oldElement toElement:(KTAbstractElement *)newElement error:(NSError **)error
{
    KTStoredDictionary *oldPluginProperties = [oldElement valueForKey:@"pluginProperties"];
    [newElement importOldPluginProperties:[oldPluginProperties dictionary] dataMigrator:self];
    
    // Save after each element to detect errors
    KTDocument *document = [self newDocument];
    BOOL result = [document saveToURL:[document fileURL] ofType:[document fileType] forSaveOperation:NSSaveOperation error:error];
    return result;
}

#pragma mark -
#pragma mark Media Migration

- (BOOL)migrateFromMediaRef:(NSManagedObject *)mediaRefA toMediaRef:(NSManagedObject *)mediaRefB
{
	// migrate attributes
	[self migrateMatchingAttributesFromObject:mediaRefA 
									 toObject:mediaRefB];
	
	// migrate media relationship
	//  media should already have been copied to the new context
	//  all we need to do is find the corresponding object
	NSManagedObject *mediaA = [mediaRefA valueForKey:@"media"];
	NSManagedObject *mediaB = [self correspondingObjectForObject:mediaA];
	OBASSERTSTRING((nil != mediaB), @"mediaB cannot be nil! should have been copied by now");
	[mediaRefB setValue:mediaB forKey:@"media"];
	
	// migrate owner relationship
	//  should be later set by migrateAbstractPluginRelationshipsFromObject:toObject:
	
	return YES; // could later beef this up with error checking
}

- (BOOL)migrateMedia:(NSError **)error
{
	TJT((@"migrating Media..."));
	// fetch all Media
	NSArray *fetchedObjects = [[self oldManagedObjectContext] allObjectsWithEntityName:@"Media"
																				 error:error];
	if ( nil != *error )
	{
		return NO;
	}
	
	NSEnumerator *e = [fetchedObjects objectEnumerator];
	NSManagedObject *oldMedia = nil;
	while ( oldMedia = [e nextObject] )
	{
		// create a new media object
		NSManagedObject *newMedia = [NSEntityDescription insertNewObjectForEntityForName:@"Media"
																  inManagedObjectContext:[self newManagedObjectContext]];
		OBASSERTSTRING(nil != newMedia, @"newMedia is nil!");
		
		// cache URI for matching
		[[self objectIDCache] setValue:[newMedia URIRepresentationString] forKey:[oldMedia URIRepresentationString]];
		
		NSManagedObjectContext *newContext = [newMedia managedObjectContext];
		
		// copy attributes
		[self migrateMatchingAttributesFromObject:oldMedia 
										 toObject:newMedia];
		
		// (10001) add attribute isPublished
		NSNumber *defaultIsPublished = [[[[[[self newManagedObjectModel] entitiesByName] valueForKey:@"Media"] attributesByName] valueForKey:@"isPublished"] defaultValue];
		[newMedia setValue:defaultIsPublished forKey:@"isPublished"];
		
		// copy mediaData (a special relationship, required in all cases)
		NSManagedObject *newMediaData = [NSEntityDescription insertNewObjectForEntityForName:@"MediaData"
																	  inManagedObjectContext:newContext];
		[newMedia setValue:newMediaData forKey:@"mediaData"];
		[newMedia setValue:[oldMedia valueForKeyPath:@"mediaData.contents"]
				forKeyPath:@"mediaData.contents"];
		[newMedia setValue:[oldMedia valueForKeyPath:@"mediaData.digest"]
				forKeyPath:@"mediaData.digest"];
		
		// copy relationships
		//  copy thumbnailData, if present
		if ( nil != [oldMedia valueForKey:@"thumbnailData"] )
		{
			NSManagedObject *newThumbnailData = [NSEntityDescription insertNewObjectForEntityForName:@"ThumbnailData"
																			  inManagedObjectContext:newContext];
			[newMedia setValue:newThumbnailData forKey:@"thumbnailData"];
			[newMedia setValue:[oldMedia valueForKeyPath:@"thumbnailData.contents"]
					forKeyPath:@"thumbnailData.contents"];
			[newMedia setValue:[oldMedia valueForKeyPath:@"thumbnailData.digest"]
					forKeyPath:@"thumbnailData.digest"];
		}
		
		//  copy fileAttributes, if present
		KTStoredDictionary *fileAttributes = [oldMedia valueForKey:@"fileAttributes"];
		if ( nil != fileAttributes )
		{
			[self migrateStorageRelationshipNamed:@"fileAttributes"
									   fromObject:oldMedia
										 toObject:newMedia];
			
		}
		
		//  copy metadata, if present
		KTStoredDictionary *metadata = [oldMedia valueForKey:@"metadata"];
		if ( nil != metadata )
		{
			[self migrateStorageRelationshipNamed:@"metadata"
									   fromObject:oldMedia
										 toObject:newMedia];			
		}
		
		// note: mediaRefs is also a relationship, but that will be set as an inverse
		// when the actual mediaRef itself is copied to the new context
	}
	
	return YES; // could later beef this up with error checking
}

#pragma mark -
#pragma mark Site-Level Migration

/*  Takes the old document info object and copies out all properties that still apply.
 */
- (BOOL)migrateDocumentInfo:(NSError **)error
{
	// Retrieve document infos
    NSManagedObject *oldDocInfo = [self oldDocumentInfo];
    if (!oldDocInfo) return NO;
    
    KTDocumentInfo *newDocInfo = [[self newDocument] documentInfo];
    OBASSERT(newDocInfo);
    
    
    // Run through attributes, copying those that still remain.
    [self migrateMatchingAttributesFromObject:oldDocInfo toObject:newDocInfo];
    
    
    // Migrate host properties
    KTStoredDictionary *oldHostProperties = [oldDocInfo valueForKey:@"hostProperties"];
    KTHostProperties *newHostProperties = [[[self newDocument] documentInfo] hostProperties];
    [newHostProperties setValuesForKeysWithDictionary:[oldHostProperties dictionary]];
    
    
    return YES;
}

#pragma mark -
#pragma mark Generic Migration methods

/*  Compares two objects to find their common attributes.
 */
- (NSSet *)matchingAttributesFromObject:(NSManagedObject *)oldObject toObject:(NSManagedObject *)newObject
{
    NSSet *oldAttributeKeys = [[NSSet alloc] initWithArray:[[oldObject entity] attributeKeys]];
	NSSet *newAttributeKeys = [[NSSet alloc] initWithArray:[[newObject entity] attributeKeys]];
	
    NSMutableSet *buffer = [oldAttributeKeys mutableCopy];
    [buffer intersectSet:newAttributeKeys];
    
    // Tidy up
    [oldAttributeKeys release];
    [newAttributeKeys release];
    
    NSSet *result = [[buffer copy] autorelease];
    [buffer release];
    return result;
}

/*  Copies attribute values from managedObjectA to managedObjectB that exist in both entities */
- (void)migrateMatchingAttributesFromObject:(NSManagedObject *)oldObject toObject:(NSManagedObject *)newObject
{
    NSSet *matchingKeys = [self matchingAttributesFromObject:oldObject toObject:newObject];
    [self migrateAttributes:matchingKeys fromObject:oldObject toObject:newObject];
}

/*  Migrates the specified attributes from one object to another.
 *  The migration is clever enough to key-value validation; invalid values are ignored.
 */
- (void)migrateAttributes:(NSSet *)attributeKeys fromObject:(NSManagedObject *)oldObject toObject:(NSManagedObject *)newObject
{
    // Loop through the attributes
    NSEnumerator *keysEnumerator = [attributeKeys objectEnumerator];
    NSString *anAttributeKey;
    while (anAttributeKey = [keysEnumerator nextObject])
	{
        id aValue = [oldObject valueForKey:anAttributeKey];
        
        // Only store the value if it's valid
        if ([newObject validateValue:&aValue forKey:anAttributeKey error:NULL])
        {
            [newObject setValue:aValue forKey:anAttributeKey];
        }
        else
        {
            NSLog(@"Not migrating value for key %@; it is invalid.\r\rOriginal object:\r%@\r\rNew Object:\r%@",
                  anAttributeKey,
                  [oldObject objectID],
                  [newObject objectID]);
        }
    }
}


- (void)migrateAbstractPluginRelationshipsFromObject:(NSManagedObject *)managedObjectA
											toObject:(NSManagedObject *)managedObjectB
{
	OBASSERTSTRING((nil != managedObjectA), @"managedObjectA cannot be nil!");
	OBASSERTSTRING((nil != managedObjectB), @"managedObjectB cannot be nil!");
	
	// root
	NSString *newRootURIString = [[self objectIDCache] valueForKey:@"newRoot"];
	OBASSERTSTRING((nil != newRootURIString), @"newRootURIString cannot be nil!");
	NSManagedObject *newRoot = [[managedObjectB managedObjectContext] objectWithURIRepresentationString:newRootURIString];
	OBASSERTSTRING((nil != newRoot), @"newRoot cannot be nil!");
	[managedObjectB setValue:newRoot forKey:@"root"];
	
	// pluginProperties	
	[self migrateStorageRelationshipNamed:@"pluginProperties"
							   fromObject:managedObjectA
								 toObject:managedObjectB];
	
	// mediaRefs
	NSSet *mediaRefsA = [managedObjectA valueForKey:@"mediaRefs"];
	if ( [mediaRefsA count] > 0 )
	{
		NSMutableSet *mediaRefsB = [managedObjectB mutableSetValueForKey:@"mediaRefs"];
		NSEnumerator *e = [mediaRefsA objectEnumerator];
		NSManagedObject *mediaRefA = nil;
		while ( mediaRefA = [e nextObject] )
		{
			NSManagedObject *mediaRefB = [self correspondingObjectForObject:mediaRefA];
			if ( nil == mediaRefB )
			{
				mediaRefB = [NSEntityDescription insertNewObjectForEntityForName:@"MediaRef"
														  inManagedObjectContext:[managedObjectB managedObjectContext]];
				OBASSERTSTRING((nil != mediaRefB), @"mediaRefB cannot be nil!");
				[[self objectIDCache] setValue:[mediaRefB URIRepresentationString] forKey:[mediaRefA URIRepresentationString]];
			}
			[self migrateFromMediaRef:mediaRefA toMediaRef:mediaRefB];
			[mediaRefsB addObject:mediaRefB];
		}
	}
}

#pragma mark -
#pragma mark Support

+ (NSString *)renamedFileName:(NSString *)originalFileNameWithExtension modelVersion:(NSString *)aVersion
{
	NSString *fileName = [originalFileNameWithExtension stringByDeletingPathExtension];
	NSString *extension = [originalFileNameWithExtension pathExtension];
	NSString *previous = NSLocalizedString(@"previous",
										   "name appened to copy of file before version migration");
	
	//return [NSString stringWithFormat:@"%@-%@.%@", fileName, aVersion, extension];
	return [NSString stringWithFormat:@"%@-%@.%@", fileName, previous, extension];
}

// this is a slightly cleaned up method from Apple's Migrator example
+ (BOOL)validatePathForNewStore:(NSString *)aStorePath error:(NSError **)outError
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *storeDirectory = [aStorePath stringByDeletingLastPathComponent];
    
	// check that we at least have aStorePath
    if (nil == aStorePath || [@"" isEqualToString:aStorePath])
	{
		*outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSNoDocPathSpecified localizedDescription:NSLocalizedString(@"No document path specified.","No document path specified.")];
        return NO;
    }
    
	// does aStorePath already exist? if so, can we overwrite it?
	// if not, does it have a valid parent directory?
	// if not, create a valid path
    BOOL isDirectory = NO;
    if ([fileManager fileExistsAtPath:aStorePath isDirectory:&isDirectory])
	{
        if ( isDirectory ) 
		{
			*outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSPathIsDirectory localizedDescription:NSLocalizedString(@"Specified document path is a directory.","Specified document path is a directory.")];
            return NO;
        } 
		else 
		{
            if ( ![fileManager removeFileAtPath:aStorePath handler:nil] ) 
			{
				*outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSCannotRemove localizedDescription:[NSString stringWithFormat:
                                                                                                                           NSLocalizedString(@"Can\\U2019t remove pre-existing file at path (%@)","Error: Can't remove pre-existing file at path (%@)"), aStorePath]];      
                return NO;
            }
        }
    } 
	else if ( [fileManager fileExistsAtPath:storeDirectory isDirectory:&isDirectory] ) 
	{
        if ( isDirectory )
		{
            if ( ![fileManager isWritableFileAtPath:storeDirectory] ) 
			{
				*outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSDirNotWritable localizedDescription:[NSString stringWithFormat:
                                                                                                                             NSLocalizedString(@"Can\\U2019t write file to path - directory is not writable (%@)","Error: Can't write file to path - directory is not writable (%@)"), storeDirectory]];       
                return NO;
            }
        }
		else
		{
			*outError = [NSError errorWithDomain:kKTDataMigrationErrorDomain code:KSParentNotDirectory localizedDescription:[NSString stringWithFormat:
                                                                                                                             NSLocalizedString(@"Can\\U2019t write file to path - parent is not a directory (%@)","Error: Can't write file to path - parent is not a directory (%@)"), storeDirectory]]; 
            return NO;
        }
    }
	else
	{
        return [KTUtilities createPathIfNecessary:storeDirectory error:outError];
    }
	
    return YES;
}

/*! returns object in newManagedObjectContext matching anObject in oldManagedObjectContext */
- (NSManagedObject *)correspondingObjectForObject:(NSManagedObject *)anObject
{
	NSManagedObject *result = nil;
	
	NSString *URIStringA = [anObject URIRepresentationString];
	NSString *URIStringB = [[self objectIDCache] valueForKey:URIStringA];
	
	if ( nil != URIStringB )
	{
		result = [[self newManagedObjectContext] objectWithURIRepresentationString:URIStringB];
	}
	
	return result;	
}

/*! attempts an attribute fetch (uniqueID) which causes a fault to fire,
 if an exception is thrown because the fault can't be fulfilled,
 this catches it (instead of crapping out) and returns NO
 */
- (BOOL)isValidManagedObject:(NSManagedObject *)aManagedObject
{
	BOOL result = NO;
	@try
	{
		NSString *uniqueID = [aManagedObject valueForKey:@"uniqueID"];
		if ( nil != uniqueID )
		{
			result = YES;
		}
	}
	@catch (NSException *fetchException)
	{
		// if anything goes wrong, assume it's a bad object
		result = NO;
		if ( [[fetchException name] isEqualToString:@"NSObjectInaccessibleException"] )
		{
			TJT((@"%@ is not/no longer a valid managed object.", [aManagedObject managedObjectDescription]));
		}
	}
	
	return result;
}

@end


#pragma mark -


@implementation KTAbstractElement (KTDataMigratorAdditions)

- (void)importOldPluginProperties:(NSDictionary *)oldPluginProperties dataMigrator:(KTDataMigrator *)dataMigrator
{
    id delegate = [self delegate];
    if (delegate && [delegate respondsToSelector:@selector(importOldPluginProperties:dataMigrator:)])
    {
        [delegate importOldPluginProperties:oldPluginProperties dataMigrator:dataMigrator];
    }
    else
    {
        [self setValuesForKeysWithDictionary:oldPluginProperties];
    }
}

@end

