//
//  KTPage.m
//  KTComponents
//
//  Created by Terrence Talbot on 3/10/05.
//  Copyright 2005 Biophony LLC. All rights reserved.
//

#import "KTPage.h"

#import "ContainsValueTransformer.h"
#import "Debug.h"
#import "KTAbstractIndex.h"
#import "KTAppDelegate.h"
#import "KTDesign.h"
#import "KTDocWindowController.h"
#import "KTDocument.h"
#import "KTElementPlugin.h"
#import "KTManagedObjectContext.h"
#import "KTMaster.h"
#import "NSArray+Karelia.h"
#import "NSAttributedString+Karelia.h"
#import "NSBundle+KTExtensions.h"
#import "NSBundle+Karelia.h"
#import "NSDocumentController+KTExtensions.h"
#import "NSManagedObject+KTExtensions.h"
#import "NSManagedObjectContext+KTExtensions.h"
#import "NSMutableSet+Karelia.h"
#import "NSString+KTExtensions.h"
#import "NSString+Karelia.h"
#import "KTIndexPlugin.h"

@interface NSObject ( RichTextElementDelegateHack )
- (NSString *)richTextHTML;
@end

@interface NSObject ( HTMLElementDelegateHack )
- (NSString *)html;
@end


#pragma mark -


@implementation KTPage

#pragma mark -
#pragma mark Class Methods

/*!	Make sure that changes to titleHTML generate updates for new values of titleText, fileName
*/
+ (void)initialize
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	[self setKeys:[NSArray arrayWithObjects:@"root",nil]
		triggerChangeNotificationsForDependentKey:@"isRoot"];
	[self setKeys:[NSArray arrayWithObjects:@"isRoot",nil]
		triggerChangeNotificationsForDependentKey:@"canEditTitle"];

	[self setKeys:[NSArray arrayWithObjects:@"titleHTML",nil]
		triggerChangeNotificationsForDependentKey:@"titleText"];
	[self setKeys:[NSArray arrayWithObjects:@"titleHTML",nil]
		triggerChangeNotificationsForDependentKey:@"fileName"];
//	[self setKeys:[NSArray arrayWithObjects: @"isStale", nil]
//        triggerChangeNotificationsForDependentKey: @"staleness"];
	[self setKeys:[NSArray arrayWithObjects: @"keywords", nil]
        triggerChangeNotificationsForDependentKey: @"keywordsAsArray"];
		
	[self setKeys:[NSArray arrayWithObjects: @"collectionSummaryType", nil]
        triggerChangeNotificationsForDependentKey: @"thumbnail"];
	[self setKeys:[NSArray arrayWithObjects: @"collectionSummaryType", nil]
        triggerChangeNotificationsForDependentKey: @"summaryHTML"];
	
	
	// Site Outline
	[self setKeys:[NSArray arrayWithObjects:@"codeInjectionBeforeHTML",
											@"codeInjectionBodyTag",
											@"codeInjectionBodyTagEnd",
											@"codeInjectionBodyTagStart",
											@"codeInjectionEarlyHead",
											@"codeInjectionHeadArea", nil]
		triggerChangeNotificationsForDependentKey:@"hasCodeInjection"];
	
	
	// this is so we get notification of updaates to any properties that affect index type.
	// This is a fake attribute -- we don't actually have this accessor since it' more UI related
	[self setKeys:[NSArray arrayWithObjects:
		@"collectionShowPermanentLink",
		@"collectionHyperlinkPageTitles",
		@"collectionIndexBundleIdentifier",
		@"collectionSyndicate", 
		@"collectionMaxIndexItems", 
		@"collectionSortOrder", 
		nil]
        triggerChangeNotificationsForDependentKey: @"indexPresetDictionary"];
	
	
	
	// Paths
	[self setKeys:[NSArray arrayWithObject:@"customFileExtension"]
		triggerChangeNotificationsForDependentKey:@"fileExtension"];
	
	
	// Register transformers
	NSSet *collectionTypes = [NSSet setWithObjects:[NSNumber numberWithInt:KTSummarizeRecentList],
												   [NSNumber numberWithInt:KTSummarizeAlphabeticalList],
												   nil];
	
	NSValueTransformer *transformer = [[ContainsValueTransformer alloc] initWithComparisonObjects:collectionTypes];
	[NSValueTransformer setValueTransformer:transformer forName:@"KTCollectionSummaryTypeIsTitleList"];
	[transformer release];
	
	
	// Pagelets
	[self performSelector:@selector(initialize_pagelets)];
	
	[pool release];
}

+ (NSString *)entityName { return @"Page"; }

+ (NSString *)extensiblePropertiesDataKey { return @"extensiblePropertiesData"; }

+ (KTPage *)rootPageWithDocument:(KTDocument *)aDocument bundle:(NSBundle *)aBundle
{
	OBPRECONDITION([aBundle bundleIdentifier]);
	
	id root = [NSEntityDescription insertNewObjectForEntityForName:@"Root" 
											inManagedObjectContext:[aDocument managedObjectContext]];
	
	if ( nil != root )
	{
		[root setDocument:aDocument];
		[root setValue:[aDocument documentInfo] forKey:@"documentInfo"];	// point to yourself
		
		[root setValue:[aBundle bundleIdentifier] forKey:@"pluginIdentifier"];
		[root setBool:YES forKey:@"isCollection"];	// root is automatically a collection
		[root setBool:NO forKey:@"allowComments"];
		[root awakeFromBundleAsNewlyCreatedObject:YES];
	}

	return root;
}

#pragma mark -
#pragma mark Initialisation

/*	Private support method that creates a generic, blank page.
 *	It gets created either by unarchiving or the user creating a new page.
 */
+ (KTPage *)_insertNewPageWithParent:(KTPage *)parent pluginIdentifier:(NSString *)pluginIdentifier
{
	OBPRECONDITION([parent managedObjectContext]);		OBPRECONDITION(pluginIdentifier);
	
	
	// Create the page
	KTPage *result =
		[NSEntityDescription insertNewObjectForEntityForName:@"Page" inManagedObjectContext:[parent managedObjectContext]];
	
	
	// Store the plugin identifier. This HAS to be done before attaching the parent or Site Outline icon caching fails.
	[result setValue:pluginIdentifier forKey:@"pluginIdentifier"];
	
	
	// Attach to parent & other relationships
	[result setValue:[parent master] forKey:@"master"];
	[result setValue:[parent valueForKeyPath:@"documentInfo"] forKey:@"documentInfo"];
	[parent addPage:result];	// Must use this method to correctly maintain ordering
	
	return result;
}

+ (KTPage *)insertNewPageWithParent:(KTPage *)aParent plugin:(KTElementPlugin *)aPlugin
{
	// Create the page
	KTPage *page = [self _insertNewPageWithParent:aParent pluginIdentifier:[[aPlugin bundle] bundleIdentifier]];
	
	
	// Load properties from parent/sibling
	KTPage *previousPage = aParent;
	NSArray *children = [aParent childrenWithSorting:KTCollectionSortLatestAtTop];
	if ([children count] > 0)
	{
		previousPage = [children firstObject];
	}
	
	[page setBool:[previousPage boolForKey:@"allowComments"] forKey:@"allowComments"];
	[page setBool:[previousPage boolForKey:@"includeTimestamp"] forKey:@"includeTimestamp"];
	
	
	// And we're finally ready to let normal initalisation take over
	[page awakeFromBundleAsNewlyCreatedObject:YES];

	return page;
}

+ (KTPage *)pageWithParent:(KTPage *)aParent
				dataSourceDictionary:(NSDictionary *)aDictionary
	  insertIntoManagedObjectContext:(KTManagedObjectContext *)aContext;
{
	OBPRECONDITION(nil != aParent);

	KTElementPlugin *plugin = [aDictionary objectForKey:kKTDataSourcePlugin];
	OBASSERTSTRING((nil != plugin), @"drag dictionary does not have a real plugin");
	
	id page = [self insertNewPageWithParent:aParent plugin:plugin];
	
	// anything else to do with the drag source dictionary other than to get the bundle?
	// should the delegate be passed the dictionary and have an opportunity to use it?
	[page awakeFromDragWithDictionary:aDictionary];
	
	return page;
}

#pragma mark -
#pragma mark Awake

/*!	Early initialization.  Note that we don't know our bundle yet!  Use awakeFromBundle for later init.
*/
- (void)awakeFromInsert
{
	[super awakeFromInsert];
		
	// attributes
	NSDate *now = [NSDate date];
	[self setValue:now forKey:@"creationDate"];
	[self setValue:now forKey:@"lastModificationDate"];
	
	[self setValue:[[NSUserDefaults standardUserDefaults] objectForKey:@"MaximumTitlesInCollectionSummary"]
			forKey:@"collectionSummaryMaxPages"];
}

/*!	Initialization that happens after awakeFromFetch or awakeFromInsert
*/
- (void)awakeFromBundleAsNewlyCreatedObject:(BOOL)isNewlyCreatedObject
{
	if ( isNewlyCreatedObject )
	{
		// Initialize this required value from the info dictionary
		NSNumber *includeSidebar = [[self plugin] pluginPropertyForKey:@"KTPageShowSidebar"];
		[self setValue:includeSidebar forKey:@"includeSidebar"];
			
		NSString *titleText = [[self plugin] pluginPropertyForKey:@"KTPageUntitledName"];
		[self setTitleText:titleText];
		// Note: there won't be a site title set for a newly created object.
		
		KTPage *parent = [self parent];
		// Set includeInSiteMenu if this page's parent is root, and not too many siblings
		if (nil != parent && [parent isRoot] && [[parent valueForKey:@"children"] count] < 7)
		{
			[self setIncludeInSiteMenu:YES];
		}
	}
	else	// Loading from disk
	{
		NSString *identifier = [self valueForKey:@"collectionIndexBundleIdentifier"];
		if (nil != identifier)
		{
			KTIndexPlugin *plugin = [KTIndexPlugin pluginWithIdentifier:identifier];
			Class indexToAllocate = [NSBundle principalClassForBundle:[plugin bundle]];
			KTAbstractIndex *theIndex = [[((KTAbstractIndex *)[indexToAllocate alloc]) initWithPage:self plugin:plugin] autorelease];
			[self setIndex:theIndex];
		}
	}
		
	[self setNewPage:isNewlyCreatedObject];		// for benefit of webkit editing only
	
	
	// Default values pulled from the plugin's Info.plist
	[self setDisableComments:[[[self plugin] pluginPropertyForKey:@"KTPageDisableComments"] boolValue]];
	[self setSidebarChangeable:[[[self plugin] pluginPropertyForKey:@"KTPageSidebarChangeable"] boolValue]];
	
	
	// I moved this below the above, in order to give the delegates a chance to override the
	// defaults.
	[super awakeFromBundleAsNewlyCreatedObject:isNewlyCreatedObject];
}

- (void)awakeFromDragWithDictionary:(NSDictionary *)aDictionary
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[super awakeFromDragWithDictionary:aDictionary];
    NSString *title = [aDictionary valueForKey:kKTDataSourceTitle];
    if ( nil == title )
	{
		// No title specified; use file name (minus extension)
		NSFileManager *fm = [NSFileManager defaultManager];
		title = [[fm displayNameAtPath:[aDictionary valueForKey:kKTDataSourceFileName]] stringByDeletingPathExtension];
	}
	if (nil != title)
	{
		[self setTitleText:title];
	}
	if ([defaults boolForKey:@"SetDateFromSourceMaterial"])
	{
		if (nil != [aDictionary objectForKey:kKTDataSourceCreationDate])	// date set from drag source?
		{
			[self setValue:[aDictionary objectForKey:kKTDataSourceCreationDate] forKey:@"creationDate"];
		}
		else if (nil != [aDictionary objectForKey:kKTDataSourceFilePath])
		{
			// Get creation date from file if it's not specified explicitly
			NSDictionary *fileAttrs = [[NSFileManager defaultManager]
				fileAttributesAtPath:[aDictionary objectForKey:kKTDataSourceFilePath]
						traverseLink:YES];
			NSDate *date = [fileAttrs objectForKey:NSFileCreationDate];
			[self setValue:date forKey:@"creationDate"];
		}
	}
}

#pragma mark -
#pragma mark Dealloc

- (void)dealloc
{
    // release ivars
	[self setDocument:nil];
    
	[mySortedChildrenCache release];
	[myAllSidebarPageletsCache release];
	
    [super dealloc];
}

#pragma mark -
#pragma mark Master

- (KTMaster *)master { return [self wrappedValueForKey:@"master"]; }

#pragma mark -
#pragma mark Paths

/*	KTAbstractPage doesn't support recursive operations, so we do instead
 */
- (void)invalidatePathRelativeToSiteRecursive:(BOOL)recursive
{
	[super invalidatePathRelativeToSiteRecursive:recursive];
	
	// Children should be affected last since they depend on parents' path
	if (recursive)
	{
		NSSet *children = [self children];
		NSEnumerator *pageEnumerator = [children objectEnumerator];
		KTAbstractPage *aPage;
		while (aPage = [pageEnumerator nextObject])
		{
			[aPage invalidatePathRelativeToSiteRecursive:YES];
		}
		
		NSSet *archives = [self valueForKey:@"archivePages"];
		pageEnumerator = [archives objectEnumerator];
		while (aPage = [pageEnumerator nextObject])
		{
			[aPage invalidatePathRelativeToSiteRecursive:YES];
		}
	}
}

/*	The published path to the design directory relative to the receiver.
 */
- (NSString *)designDirectoryPath
{
	KTDesign *design = [[self master] design];
	NSString *designPath = [design remotePath];
	NSString *result = [designPath URLPathRelativeTo:[self pathRelativeToSite]];
	return result;
}

#pragma mark -
#pragma mark contextual menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	OFF((@"KTPage validateMenuItem:%@ %@", [menuItem title], NSStringFromSelector([menuItem action])));
    if ( [menuItem action] == @selector(movePageletToSidebar:) )
    {
        return YES;
    }
    else if ( [menuItem action] == @selector(movePageletToCallouts:) )
    {
        return YES;
    }
    
    return YES;
}

#pragma mark -
#pragma mark Media

/*	Each page adds a number of possible required media to the default. e.g. thumbnail
 */
- (NSSet *)requiredMediaIdentifiers
{
	NSMutableSet *result = [NSMutableSet setWithSet:[super requiredMediaIdentifiers]];
	
	// Inclue our thumbnail and site outline image
	[result addObjectIgnoringNil:[self valueForKey:@"thumbnailMediaIdentifier"]];
	[result addObjectIgnoringNil:[self valueForKey:@"customSiteOutlineIconIdentifier"]];
	
	// Include anything our index requires?
	NSSet *indexMediaIDs = [[self index] requiredMediaIdentifiers];
	if (indexMediaIDs)
	{
		[result unionSet:indexMediaIDs];
	}
	
	return result;
}

#pragma mark -
#pragma mark Archiving

+ (id)objectWithArchivedIdentifier:(NSString *)identifier inDocument:(KTDocument *)document
{
	id result = [KTAbstractPage pageWithUniqueID:identifier inManagedObjectContext:[document managedObjectContext]];
	return result;
}

- (NSString *)archiveIdentifier { return [self uniqueID]; }

#pragma mark -
#pragma mark Inspector

/*!	True if this page type should put the inspector in the third inspector segment -- use sparingly.
*/
- (BOOL)separateInspectorSegment
{
	return [[[self plugin] pluginPropertyForKey:@"KTPageSeparateInspectorSegment"] boolValue];
}

#pragma mark -
#pragma mark Debugging

// More human-readable description
- (NSString *)shortDescription
{
	return [NSString stringWithFormat:@"%@ <%p> %@ : %@ %@ %@", [self class], self, ([self isRoot] ? @"(root)" : ([self isCollection] ? @"(collection)" : @"")),
		[self fileName], [self wrappedValueForKey:@"uniqueID"], [self wrappedValueForKey:@"pluginIdentifier"]];
}

@end
