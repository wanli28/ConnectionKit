//
//  KTPage.h
//  KTComponents
//
//  Copyright (c) 2005-2006, Karelia Software. All rights reserved.
//
//  THIS SOFTWARE IS PROVIDED BY KARELIA SOFTWARE AND ITS CONTRIBUTORS "AS-IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
//  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
//  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//  ARISING IN ANY WAY OUR OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//  POSSIBILITY OF SUCH DAMAGE.
//

#import "KTAbstractPage.h"

#import "NSManagedObject+KTExtensions.h"
#import "KT.h"
#import "KTPagelet.h"


@class KTDesign, KTAbstractHTMLPlugin;
@class KTAbstractIndex, KTMaster;
@class WebView;
@class KTMediaContainer;

@interface KTPage : KTAbstractPage	<KTExtensiblePluginPropertiesArchiving, KTWebViewComponent>
{
	// most ivars handled internally via CoreData model
	KTAbstractIndex		*myArchivesIndex;			// not archived, loaded lazily
	
	// these ivars are only set if the page is root
    KTDocument			*myDocument;				// not archived
	BOOL				myIsNewPage;
	
	NSArray	*mySortedChildrenCache;
}


// Creation
+ (KTPage *)pageWithParent:(KTPage *)aParent 
					bundle:(NSBundle *)aBundle insertIntoManagedObjectContext:(KTManagedObjectContext *)aContext;

+ (KTPage *)pageWithParent:(KTPage *)aParent
	  dataSourceDictionary:(NSDictionary *)aDictionary insertIntoManagedObjectContext:(KTManagedObjectContext *)aContext;

+ (KTPage *)rootPageWithDocument:(KTDocument *)aDocument bundle:(NSBundle *)aBundle;

// Awake
- (void)awakeFromBundleAsNewlyCreatedObject:(BOOL)isNewlyCreatedObject;

// Master
- (KTMaster *)master;
- (NSString *)designDirectoryPath;

// Inspector
- (BOOL)separateInspectorSegment;

// Debugging
- (NSString *)shortDescription;

@end

@interface KTPage (Accessors)

- (BOOL)isStale;
- (void)setIsStale:(BOOL)stale;

- (BOOL)disableComments;
- (void)setDisableComments:(BOOL)disableComments;

- (KTDocument *)document;
- (void)setDocument:(KTDocument *)aDocument;

// Draft
- (BOOL)pageOrParentDraft;
- (void)setPageOrParentDraft:(BOOL)inDraft;
- (BOOL)includeInIndexAndPublish;
- (BOOL)excludedFromSiteMap;

// Title
- (void)setTitleHTML:(NSString *)value;
- (NSString *)titleText;
- (void)setTitleText:(NSString *)value;
- (BOOL)canEditTitle;

// Site menu
- (BOOL)includeInSiteMenu;
- (void)setIncludeInSiteMenu:(BOOL)include;
- (KTPage *)firstParentOrSelfInSiteMenu;

- (NSString *)menuTitle;
- (void)setMenuTitle:(NSString *)newTitle;
- (NSString *)menuTitleOrTitle;

// Timestamps
- (NSDate *)editableTimestamp;
- (void)setEditableTimestamp:(NSDate *)aDate;
- (NSString *)timestamp;
- (void)loadEditableTimestamp;

// Thumbnail
- (KTMediaContainer *)thumbnail;
- (void)setThumbnail:(KTMediaContainer *)thumbnail;

// Keywords
- (NSArray *)keywords;
- (void)setKeywords:(NSArray *)aStoredArray;
- (NSString *)keywordsList;

// Site Outline
- (KTMediaContainer *)customSiteOutlineIcon;
- (void)setCustomSiteOutlineIcon:(KTMediaContainer *)icon;

@end


@interface KTPage (Children)

// Basic Accessors
- (KTCollectionSortType)collectionSortOrder;
- (void)setCollectionSortOrder:(KTCollectionSortType)sorting;

- (BOOL)isCollection;

- (void)moveToIndex:(unsigned)index;

// Unsorted Children
- (NSSet *)children;
- (void)addPage:(KTPage *)page;
- (void)removePage:(KTPage *)page;
- (void)removePages:(NSSet *)pages;

// Sorted Children
- (NSArray *)sortedChildren;
- (NSArray *)childrenWithSorting:(KTCollectionSortType)sortType;

// Hierarchy Queries
- (KTPage *)parentOrRoot;
- (BOOL)hasChildren;
- (BOOL)containsDescendant:(KTPage *)aPotentialDescendant;

- (NSIndexPath *)indexPathFromRoot;

- (KTPage *)previousPage;
- (KTPage *)nextPage;


- (int)proposedOrderingForProposedChild:(id)aProposedChild
							   sortType:(KTCollectionSortType)aSortType;
- (int)proposedOrderingForProposedChildWithTitle:(NSString *)aTitle;


@end


@interface KTPage (Indexes)

// Simple Accessors
- (KTCollectionSummaryType)collectionSummaryType;
- (void)setCollectionSummaryType:(KTCollectionSummaryType)type;

// Index
- (KTAbstractIndex *)index;
- (void)setIndex:(KTAbstractIndex *)anIndex;
- (void)setIndexFromPlugin:(KTAbstractHTMLPlugin *)aBundle;

- (NSArray *)sortedChildrenInIndex;

// RSS Feed
- (BOOL)collectionCanSyndicate;
- (NSString *)feedURLPathRelativeToPage:(KTAbstractPage *)aPage;
- (NSString *)feedURLPath;

// Summary
- (NSString *)summaryHTMLWithTruncation:(unsigned)truncation;

- (NSString *)customSummaryHTML;
- (void)setCustomSummaryHTML:(NSString *)HTML;

- (NSString *)titleListHTMLWithSorting:(KTCollectionSortType)sortType;

// Archive
- (BOOL)collectionGenerateArchives;
- (void)setCollectionGenerateArchives:(BOOL)generateArchive;

@end


@interface KTPage (Operations)

// Perform selector
- (void)makeComponentsPerformSelector:(SEL)selector
						   withObject:(void *)anObject
							 withPage:(KTPage *)page
							recursive:(BOOL)recursive;

- (void)addDesignsToSet:(NSMutableSet *)aSet forPage:(KTPage *)aPage;
- (void)addStaleToSet:(NSMutableSet *)aSet forPage:(KTPage *)aPage;
- (void)addRSSCollectionsToArray:(NSMutableArray *)anArray forPage:(KTPage *)aPage;
- (NSString *)spotlightHTML;


@end


@interface KTPage (Pagelets)

// General accessors
- (BOOL)includeSidebar;
- (BOOL)includeCallout;

- (BOOL)sidebarChangeable;
- (void)setSidebarChangeable:(BOOL)flag;

// Pagelet accessors
- (NSSet *)pagelets;	// IMPORTANT: Never try to add to this set yourself. Use the methods below.
						// Removing pagelets is OK though.

- (NSArray *)pageletsInLocation:(KTPageletLocation)location;
- (void)insertPagelet:(KTPagelet *)pagelet atIndex:(unsigned)index;
- (void)addPagelet:(KTPagelet *)pagelet;

- (NSArray *)orderedCallouts;
- (NSArray *)orderedTopSidebars;
- (NSArray *)orderedBottomSidebars;
- (NSArray *)orderedSidebars;

// Inheritable sidebar pagelets
- (NSArray *)orderedInheritableTopSidebars;
- (NSArray *)orderedInheritableBottomSidebars;

- (NSArray *)allInheritableTopSidebars;		// Result cached during publishing
- (NSArray *)_allInheritableTopSidebars;	// Uncached
- (NSArray *)allInheritableBottomSidebars;	// Result cached during publishing
- (NSArray *)_allInheritableBottomSidebars;	// Uncached

// All sidebar pagelets that will appear in the HTML. i.e. Our sidebars plus any inherited ones
- (NSArray *)allSidebars;

// Support
+ (void)updatePageletOrderingsFromArray:(NSArray *)pagelets;

@end


@interface KTPage (Pasteboard)
+ (KTPage *)pageWithPasteboardRepresentation:(NSDictionary *)archive parent:(KTPage *)parent;
@end


@interface KTPage ( Web )

+ (NSString *)pageTemplate;

- (NSString *)contentHTMLWithParserDelegate:(id)delegate isPreview:(BOOL)isPreview isArchives:(BOOL)isArchives;
- (BOOL)pluginHTMLIsFullPage;
- (void)setPluginHTMLIsFullPage:(BOOL)fullPage;

- (NSString *)javascriptURLPath;
- (NSString *)RSSRepresentation;
- (NSString *)archivesRepresentation;
- (BOOL)isNewPage;
- (void)setNewPage:(BOOL)flag;
- (NSString *)fixPageLinksFromString:(NSString *)originalString managedObjectContext:(KTManagedObjectContext *)context;
- (NSString *)comboTitleText;

- (BOOL)isXHTML;
- (NSString *)DTD;

@end


@interface NSObject (KTPageDelegate)
- (NSString *)absolutePathAllowingIndexPage:(BOOL)aFlag;
- (NSString *)urlAllowingIndexPage:(BOOL)aCanHaveIndexPage;
- (BOOL)pageShouldClearThumbnail:(KTPage *)page;
- (BOOL)shouldMaskCustomSiteOutlinePageIcon:(KTPage *)page;

- (NSString *)summaryHTMLKeyPath;
- (BOOL)summaryHTMLIsEditable;
@end


