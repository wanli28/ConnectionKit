//
//  SVWebEditorViewController.m
//  Marvel
//
//  Created by Mike on 17/08/2009.
//  Copyright 2009 Karelia Software. All rights reserved.
//

#import "SVWebEditorViewController.h"

#import "SVBodyParagraph.h"
#import "SVPlugInGraphic.h"
#import "SVHTMLTextBlock.h"
#import "KTMaster.h"
#import "KTPage.h"
#import "SVPagelet.h"
#import "SVBody.h"
#import "SVBodyTextDOMController.h"
#import "KTSite.h"
#import "SVWebContentItem.h"
#import "SVSelectionBorder.h"
#import "SVSidebar.h"
#import "SVTextField.h"
#import "SVWebContentObjectsController.h"
#import "SVWebEditorHTMLContext.h"
#import "SVWebEditorTextFieldController.h"

#import "DOMNode+Karelia.h"
#import "NSArray+Karelia.h"
#import "NSURL+Karelia.h"
#import "NSWorkspace+Karelia.h"

#import "KSCollectionController.h"
#import "KSOrderedManagedObjectControllers.h"
#import "KSPlugin.h"
#import "KSSilencingConfirmSheet.h"


static NSString *sWebViewDependenciesObservationContext = @"SVWebViewDependenciesObservationContext";


@interface SVWebEditorViewController ()
@property(nonatomic, readwrite, getter=isUpdating) BOOL updating;

@property(nonatomic, retain, readwrite) SVHTMLContext *HTMLContext;
@property(nonatomic, copy, readwrite) NSArray *textAreas;


// Pagelets
@property(nonatomic, copy, readwrite) NSArray *contentItems;
@property(nonatomic, copy, readwrite) NSArray *sidebarPageletItems;
- (NSRect)rectOfDropZoneAboveDOMNode:(DOMNode *)node minHeight:(CGFloat)minHeight;
- (NSRect)rectOfDropZoneInDOMElement:(DOMElement *)element
                           belowNode:(DOMNode *)node
                           minHeight:(CGFloat)minHeight;

@end


#pragma mark -


@implementation SVWebEditorViewController

#pragma mark Init & Dealloc

- (id)init
{
    self = [super init];
    
    _selectableObjectsController = [[SVWebContentObjectsController alloc] init];
    [_selectableObjectsController setAvoidsEmptySelection:NO];
    [_selectableObjectsController setObjectClass:[NSObject class]];
    
    return self;
}
    
- (void)dealloc
{
    [self setWebEditorView:nil];   // needed to tear down data source
    
    [_page release];
    [_textAreas release];
    [_context release];
    
    [super dealloc];
}

#pragma mark Views

- (void)loadView
{
    SVWebEditorView *editor = [[SVWebEditorView alloc] init];
    
    [self setView:editor];
    [self setWebEditorView:editor];
    [self setWebView:[editor webView]];
    
    // Register the editor for drag & drop
    [editor registerForDraggedTypes:[NSArray arrayWithObject:kKTPageletsPboardType]];
    
    [editor release];
}

- (void)setWebView:(WebView *)webView
{
    // Store new webview
    [super setWebView:webView];
    
    
    // Spell-checking
    // TODO: Define a constant or method for this
    BOOL spellCheck = [[NSUserDefaults standardUserDefaults] boolForKey:@"ContinuousSpellChecking"];
	[webView setContinuousSpellCheckingEnabled:spellCheck];
}

@synthesize webEditorView = _webEditorView;
- (void)setWebEditorView:(SVWebEditorView *)editor
{
    [[self webEditorView] setDelegate:nil];
    [[self webEditorView] setDataSource:nil];
    
    [editor retain];
    [_webEditorView release];
    _webEditorView = editor;
    
    [editor setDelegate:self];
    [editor setDataSource:self];
    [editor setAllowsUndo:NO];  // will be managing this entirely ourselves
}

#pragma mark Updating

- (void)update;
{
	// Tear down old dependencies
    for (KSObjectKeyPathPair *aDependency in _pageDependencies)
    {
        [[aDependency object] removeObserver:self
                                  forKeyPath:[aDependency keyPath]];
    }
    
    // And DOM controllers. TODO: WebEditorView should take care of this for itself?
    [[[self webEditorView] mainItem] setChildWebEditorItems:nil];
    
    
    // Build the HTML.
	SVWebEditorHTMLContext *context = [[SVWebEditorHTMLContext alloc] init];
    [context setCurrentPage:[self page]];
    [context setGenerationPurpose:kGeneratingPreview];
	/*[parser setIncludeStyling:([self viewType] != KTWithoutStylesView)];*/
    
    [SVHTMLContext pushContext:context];    // will pop after loading
	NSString *pageHTML = [[self page] HTMLString];
    [SVHTMLContext popContext];
    
    
    //  What are the selectable objects? Pagelets and other SVContentObjects
    NSMutableSet *selectableObjects = [[NSMutableSet alloc] init];
    [selectableObjects unionSet:[[[self page] sidebar] pagelets]];
    for (SVHTMLTextBlock *aTextBlock in [context generatedTextBlocks])
    {
        id content = [[aTextBlock HTMLSourceObject] valueForKeyPath:[aTextBlock HTMLSourceKeyPath]];
        if ([content isKindOfClass:[SVTextField class]])
        {
            [selectableObjects addObject:content];
        }
        if ([content isKindOfClass:[SVBody class]])
        {
            //[selectableObjects unionSet:[content contentObjects]];
        }
    }
    
    [_selectableObjects release];
    _selectableObjects = selectableObjects;
    // Do NOT set the controller's MOC. Unless you set both MOC and entity name, saving will raise an exception. (crazy I know!)
    [_selectableObjectsController setPage:[self page]];
    [_selectableObjectsController setContent:_selectableObjects];
	
    
    //  Start loading. Some parts of WebKit need to be attached to a window to work properly, so we need to provide one while it's loading in the
    //  background. It will be removed again after has finished since the webview will be properly part of the view hierarchy.
    
    [[self webView] setHostWindow:[[self view] window]];   // TODO: Our view may be outside the hierarchy too; it woud be better to figure out who our window controller is and use that.
    [self setHTMLContext:context];
    
    
    // Record that the webview is being loaded with content. Otherwise, the policy delegate will refuse requests. Also record location
    [self setUpdating:YES];
    _visibleRect = [[[self webEditorView] documentView] visibleRect];
    
    
	// Figure out the URL to use
	NSURL *pageURL = [[self page] URL];
    if (![pageURL scheme] ||        // case 44071: WebKit will not load the HTML or offer delegate
        ![pageURL host] ||          // info if the scheme is something crazy like fttp:
        !([[pageURL scheme] isEqualToString:@"http"] || [[pageURL scheme] isEqualToString:@"https"]))
    {
        pageURL = nil;
    }
    
    
    // Load the HTML into the webview
    [[self webEditorView] loadHTMLString:pageHTML baseURL:pageURL];
    
    
    // Observe the used keypaths
    [_pageDependencies release], _pageDependencies = [[context dependencies] copy];
    for (KSObjectKeyPathPair *aDependency in _pageDependencies)
    {
        [[aDependency object] addObserver:self
                               forKeyPath:[aDependency keyPath]
                                  options:0
                                  context:sWebViewDependenciesObservationContext];
    }
    
    
    // Tidy up
    [context release];
    
	
    // Clearly the webview is no longer in need of refreshing
    _willUpdate = NO;
	_needsUpdate = NO;
}

@synthesize updating = _isUpdating;

- (SVWebEditorTextController *)makeControllerForTextBlock:(SVHTMLTextBlock *)aTextBlock
                                             isSelectable:(BOOL *)outIsSelectable; 
{
    OBPRECONDITION(outIsSelectable);
    
    SVWebEditorTextController *result = nil;
    *outIsSelectable = NO;
    
    
    // Locate the corresponding HTML element
    DOMDocument *domDoc = [[self webEditorView] HTMLDocument];
    DOMHTMLElement *element = (DOMHTMLElement *)[domDoc getElementById:[aTextBlock DOMNodeID]];
    
    
    if (!element)
    {
        NSLog(@"Couldn't find text area: %@", [aTextBlock DOMNodeID]);
        return result;
    }
    
    
    
    OBASSERT([element isKindOfClass:[DOMHTMLElement class]]);
    
    
    // Use the right sort of text area
    id value = [[aTextBlock HTMLSourceObject] valueForKeyPath:[aTextBlock HTMLSourceKeyPath]];
    
    if ([value isKindOfClass:[SVTextField class]])
    {
        // Copy basic properties from text block
        result = [[SVWebEditorTextFieldController alloc] initWithHTMLElement:element];
        [result setRepresentedObject:value];
        [result setHTMLContext:[self HTMLContext]];
        [result setRichText:[aTextBlock isRichText]];
        [result setFieldEditor:[aTextBlock isFieldEditor]];
        [result setEditable:[aTextBlock isEditable]];
        
        // Bind to model
        [result bind:NSValueBinding
              toObject:value
           withKeyPath:@"textHTMLString"
               options:nil];
        
        // Make top-level text fields selectable. The way I determine this is admittedly hacky at the moment
        *outIsSelectable = ([[aTextBlock HTMLSourceObject] isKindOfClass:[KTAbstractPage class]]);
        
        // Tell it the MOC for undo purposes
        [(SVWebEditorTextFieldController *)result setManagedObjectContext:[[self page] managedObjectContext]];
    }
    else if ([value isKindOfClass:[SVBody class]])
    {
        KSSetController *elementsController = [[KSSetController alloc] init];
        [elementsController setOrderingSortKey:@"sortKey"];
        [elementsController setManagedObjectContext:[[self page] managedObjectContext]];
        [elementsController setEntityName:@"BodyParagraph"];
        [elementsController setAutomaticallyRearrangesObjects:YES];
        [elementsController bind:NSContentSetBinding toObject:value withKeyPath:@"elements" options:nil];
        
        result = [[SVBodyTextDOMController alloc] initWithHTMLElement:element content:elementsController];
        [result setHTMLContext:[self HTMLContext]];
        [result setRichText:YES];
        [result setFieldEditor:NO];
        [result setEditable:YES];
        
        // Store as the body text of correct item
        SVWebEditorItem *item = [[self webEditorView] itemForDOMNode:element];
        [item setBodyText:(SVBodyTextDOMController *)result];
    }
    else
    {
        // Copy basic properties from text block
        result = [[SVWebEditorTextFieldController alloc] initWithHTMLElement:element];
        [result setHTMLContext:[self HTMLContext]];
        [result setRichText:[aTextBlock isRichText]];
        [result setFieldEditor:[aTextBlock isFieldEditor]];
        [result setEditable:[aTextBlock isEditable]];
        
        // Bind to model
        [result bind:NSValueBinding
              toObject:[aTextBlock HTMLSourceObject]
           withKeyPath:[aTextBlock HTMLSourceKeyPath]
               options:nil];
        
        // Make top-level text fields selectable. The way I determine this is admittedly hacky at the moment
        *outIsSelectable = ([[aTextBlock HTMLSourceObject] isKindOfClass:[KTAbstractPage class]]);
        
        // Tell it the MOC for undo purposes
        [(SVWebEditorTextFieldController *)result setManagedObjectContext:[[self page] managedObjectContext]];
    }
    
    return [result autorelease];
}

- (void)webEditorViewDidFinishLoading:(SVWebEditorView *)sender;
{
    DOMDocument *domDoc = [[self webEditorView] HTMLDocument];
    
    
    // Set up selection borders for all pagelets. Could we do this better by receiving a list of pagelets from the parser?
    NSArray *pagelets = [SVPagelet arrayBySortingPagelets:[[[self page] sidebar] pagelets]];
    NSMutableArray *editorItems = [[NSMutableArray alloc] initWithCapacity:[pagelets count]];
    
    for (SVGraphic *aContentObject in [[self selectedObjectsController] arrangedObjects])
    {
        DOMHTMLElement *element = (DOMHTMLElement *)[aContentObject elementForEditingInDOMDocument:domDoc];
        if (element)
        {
            SVWebContentItem *item = [[SVWebContentItem alloc] initWithHTMLElement:element];
            [item setRepresentedObject:aContentObject];
            [item setHTMLContext:[self HTMLContext]];
            [item setEditable:YES];
            
            [editorItems addObject:item];
            [item release];
        }
        else
        {
            NSLog(@"Could not locate content object with ID: %@", [aContentObject elementID]);
        }
    }
    
    NSArray *sidebarPageletItems = [editorItems copy];
    [self setSidebarPageletItems:sidebarPageletItems];
    [sidebarPageletItems release];
    
    
    
    // Prepare text areas
    NSArray *parsedTextBlocks = [[self HTMLContext] generatedTextBlocks];
    NSMutableArray *textAreas = [[NSMutableArray alloc] initWithCapacity:[parsedTextBlocks count]];
    
    for (SVHTMLTextBlock *aTextBlock in parsedTextBlocks)
    {
        BOOL isSelectable = NO;
        SVWebEditorTextController *controller = [self makeControllerForTextBlock:aTextBlock
                                                                    isSelectable:&isSelectable];
        
        [textAreas addObject:controller];
        if (isSelectable) [editorItems addObject:controller];
        if ([controller respondsToSelector:@selector(graphicControllers)])
        {
            [editorItems addObjectsFromArray:[(id)controller graphicControllers]];
        }
    }
    
    
    
    // Store controllers
    [[[self webEditorView] mainItem] setChildWebEditorItems:editorItems];
    
    [self setContentItems:editorItems];
    [editorItems release];
    
    [self setTextAreas:textAreas];
    [textAreas release];
    
    
    
    
    // Match selection to controller
    NSArray *selectedObjects = [[self selectedObjectsController] selectedObjects];
    NSMutableArray *newSelection = [[NSMutableArray alloc] initWithCapacity:[selectedObjects count]];
    
    for (id anObject in selectedObjects)
    {
        id newItem = [self contentItemForObject:anObject];
        if (newItem) [newSelection addObject:newItem];
    }
    
    [[self webEditorView] setSelectedItems:newSelection];   // this will feed back to us and the controller in notification
    [newSelection release];
    
    
    
    
    // Locate the sidebar
    _sidebarDiv = [[domDoc getElementById:@"sidebar"] retain];
    
    
    // Restore scroll point
    [[self webEditorView] scrollToPoint:_visibleRect.origin];
    
    
    // Mark as loaded
    [self setUpdating:NO];
}

- (void)scheduleUpdate
{
    // Private method known only to our Main DOM Controller. Schedules an update if needed.
    if (!_willUpdate)
	{
		// Install a fresh observer for the end of the run loop
		[[NSRunLoop currentRunLoop] performSelector:@selector(updateIfNeeded)
                                             target:self
                                           argument:nil
                                              order:0
                                              modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
	}
    _willUpdate = YES;
}

@synthesize needsUpdate = _needsUpdate;
- (void)setNeedsUpdate;
{
    _needsUpdate = YES;
    [self scheduleUpdate];
}

- (void)updateIfNeeded
{
    if (!_willUpdate) return;   // don't you waste my time sucker!
    
    if ([self needsUpdate])
    {
        [self update];
    }
    else
    {
        [[[self webEditorView] mainItem] updateIfNeeded];
        _willUpdate = NO;
    }
}

#pragma mark Content

@synthesize selectedObjectsController = _selectableObjectsController;

@synthesize HTMLContext = _context;

@synthesize page = _page;
- (void)setPage:(KTPage *)page
{
    if (page != _page)
    {
        [_page release]; _page = [page retain];
    
        [self update];
    }
}

#pragma mark Text Areas

@synthesize textAreas = _textAreas;

- (SVWebEditorTextController *)textAreaForDOMNode:(DOMNode *)node;
{
    SVWebEditorTextController *result = nil;
    DOMHTMLElement *editableElement = [node containingContentEditableElement];
    
    if (editableElement)
    {
        // Search each text block in turn for a match
        for (result in [self textAreas])
        {
            if ([result HTMLElement] == editableElement)
            {
                break;
            }
        }
        
        // It's possible (but very unlikely) that the editable element is part of a text block's content. If so, search up for the next one
        if (!result)
        {
            DOMNode *parent = [editableElement parentNode];
            if (parent) result = [self textAreaForDOMNode:parent];
        }
    }
    
    return result;
}

- (SVWebEditorTextController *)textAreaForDOMRange:(DOMRange *)range;
{
    // One day there might be better logic to apply, but for now, testing the start of the range is enough
    return [self textAreaForDOMNode:[range startContainer]];
}

#pragma mark Graphics

@synthesize contentItems = _contentItems;

- (SVWebEditorItem *)contentItemForObject:(id)object;
{
    OBPRECONDITION(object);
    id result = nil;
    
    for (SVWebContentItem *anItem in [self contentItems])
    {
        if ([[anItem representedObject] isEqual:object])
        {
            result = anItem;
            break;
        }
    }
    
    return result;
}

@synthesize sidebarPageletItems = _sidebarPageletItems;

/*  Similar to NSTableView's concept of dropping above a given row
 */
- (NSUInteger)indexOfDrop:(id <NSDraggingInfo>)dragInfo
{
    NSUInteger result = NSNotFound;
    SVWebEditorView *editor = [self webEditorView];
    NSArray *pageletContentItems = [self sidebarPageletItems];
    
    
    // Ideally, we're making a drop *before* a pagelet
    NSUInteger i, count = [pageletContentItems count];
    for (i = 0; i < count; i++)
    {
        SVWebEditorItem *aPageletItem = [pageletContentItems objectAtIndex:i];
    
        NSRect dropZone = [self rectOfDropZoneAboveDOMNode:[aPageletItem HTMLElement]
                                                 minHeight:25.0f];
        
        if ([editor mouse:[editor convertPointFromBase:[dragInfo draggingLocation]] inRect:dropZone])
        {
            result = i;
            break;
        }
    }
    
    
    // If not, is it a drop *after* the last pagelet, or into an empty sidebar?
    if (result == NSNotFound)
    {
        NSRect dropZone = [self rectOfDropZoneInDOMElement:_sidebarDiv
                                                 belowNode:[[pageletContentItems lastObject] HTMLElement]
                                                 minHeight:25.0f];
        
        if ([editor mouse:[editor convertPointFromBase:[dragInfo draggingLocation]] inRect:dropZone])
        {
            result = [pageletContentItems count];
        }
    }
    
    
    return result;
}

- (NSRect)rectOfDropZoneAboveDOMNode:(DOMNode *)node minHeight:(CGFloat)minHeight;
{
    NSRect nodeBox = [node boundingBox];
    
    DOMNode *previousNode = [node previousSibling];
    NSRect previousNodeBox = [previousNode boundingBox];
    
    NSRect result;
    if (previousNode && !NSEqualRects(previousNodeBox, NSZeroRect))
    {
        // Claim the space between the nodes
        result.origin.x = MIN(NSMinX(previousNodeBox), NSMinX(nodeBox));
        result.origin.y = NSMaxY(previousNodeBox);
        result.size.width = MAX(NSMaxX(previousNodeBox), NSMaxX(nodeBox)) - result.origin.x;
        result.size.height = NSMinY(nodeBox) - result.origin.y;
    }
    else
    {
        // Claim the strip at the top of the node
        result.origin.x = NSMinX(nodeBox);
        result.origin.y = NSMinY(nodeBox);
        result.size.width = nodeBox.size.width;
        result.size.height = 0.0f;
    }
    
    // It should be at least ? pixels tall
    if (result.size.height < minHeight)
    {
        result = NSInsetRect(result, 0.0f, -0.5 * (minHeight - result.size.height));
    }
    
    return [[self webEditorView] convertRect:result fromView:[node documentView]];
}

- (NSRect)rectOfDropZoneInDOMElement:(DOMElement *)element
                           belowNode:(DOMNode *)node
                           minHeight:(CGFloat)minHeight;
{
    //Normally equal to element's -boundingBox.
    NSRect result = [element boundingBox];
    
    
    //  But then shortened to only include the area below boundingBox
    if (node)
    {
        NSRect nodeBox = [node boundingBox];
        CGFloat nodeBottom = NSMaxY(nodeBox);
        
        result.size.height = NSMaxY(result) - nodeBottom;
        result.origin.y = nodeBottom;
    }
    
    
    //  Finally, expanded again to minHeight if needed.
    if (result.size.height < minHeight)
    {
        result = NSInsetRect(result, 0.0f, -0.5 * (minHeight - result.size.height));
    }
    
    
    return [[self webEditorView] convertRect:result fromView:[element documentView]];
}

#pragma mark Element Insertion

- (void)_insertPageletInSidebar:(SVPagelet *)pagelet;
{
    // Place at end of the sidebar
    KTPage *page = [self page];
    SVSidebar *sidebar = [page sidebar];
    SVPagelet *lastPagelet = [[SVPagelet arrayBySortingPagelets:[sidebar pagelets]] lastObject];
    [pagelet moveAfterPagelet:lastPagelet];
    
	[sidebar addPageletsObject:pagelet];
}

- (void)insertPagelet:(id)sender;
{
    // Is the user editing some body text? If so, insert the pagelet as near there as possible. If not, insert into the sidebar
    DOMRange *selection = [[self webEditorView] selectedDOMRange];
    SVWebEditorTextController *text = [self textAreaForDOMRange:selection];
    SVPagelet *pagelet = [_selectableObjectsController newPagelet];
    
    if (![text insertPagelet:pagelet])
    {
        [self _insertPageletInSidebar:pagelet];
    }
     
    [pagelet release];
}

- (IBAction)insertPageletInSidebar:(id)sender;
{
    SVPagelet *pagelet = [_selectableObjectsController newPagelet];
    [self _insertPageletInSidebar:pagelet];
    [pagelet release];
}

- (void)insertElement:(id)sender;
{
    // Create a new element of the requested type and insert at the end of the pagelet
    SVBody *body = [(SVPagelet *)[[[[self page] sidebar] pagelets] anyObject] body];
    
    SVPlugInGraphic *element = [NSEntityDescription insertNewObjectForEntityForName:@"PlugInGraphic"    
                                                             inManagedObjectContext:[body managedObjectContext]];
    
    [element setValue:[[[sender representedObject] bundle] bundleIdentifier] forKey:@"plugInIdentifier"];
    [element setWrap:SVContentObjectWrapNone];
    [element awakeFromBundleAsNewlyCreatedObject:YES];
    
    [body addElement:element];
}

#pragma mark Special Insertion

- (void)insertSiteTitle:(id)sender;
{
    // Create placeholder if needed
    KTMaster *master = [[self page] master];
    if ([[[master siteTitle] text] length] <= 0)
    {
        [master setSiteTitleWithString:NSLocalizedString(@"Site Title", "placeholder text")];
    }
    
    // Begin editing in the webview. This is tricky because the addition may have required a reload
    
}

- (void)insertSiteSubtitle:(id)sender;
{
    // Create placeholder if needed
    KTMaster *master = [[self page] master];
    if ([[[master siteSubtitle] text] length] <= 0)
    {
        [master setSiteSubtitleWithString:NSLocalizedString(@"Site Subtitle", "placeholder text")];
    }
    
    // Begin editing in the webview. This is tricky because the addition may have required a reload
    
}

- (void)insertPageTitle:(id)sender;
{
    // Create placeholder if needed
    if ([[[[self page] title] text] length] <= 0)
    {
        [[self page] setTitleWithString:NSLocalizedString(@"Page Title", @"placeholder text")];
    }
    
    // Begin editing in the webview. This is tricky because the addition may have required a reload
    
}

- (void)insertPageletTitle:(id)sender;
{
    // Give the selected pagelets a title if needed
    for (id anObject in [[self selectedObjectsController] selectedObjects])
    {
        if ([anObject isKindOfClass:[SVPagelet class]])
        {
            SVPagelet *pagelet = (SVPagelet *)anObject;
            if ([[[pagelet title] text] length] <= 0)
            {
                [pagelet setTitleWithString:[[pagelet class] placeholderTitleText]];
            }
        }
    }
}

- (void)insertFooter:(id)sender;
{
    // Create placeholder if needed
    KTMaster *master = [[self page] master];
    if ([[[master footer] text] length] <= 0)
    {
        [master setFooterWithString:[master defaultCopyrightHTML]];
    }
    
    // Begin editing in the webview. This is tricky because the addition may have required a reload
    
}

#pragma mark Delegate

@synthesize delegate = _delegate;

#pragma mark -

#pragma mark WebEditorViewDataSource

- (id <SVWebEditorText>)webEditorView:(SVWebEditorView *)sender
                 textBlockForDOMRange:(DOMRange *)range;
{
    return [self textAreaForDOMRange:range];
}

- (BOOL)webEditorView:(SVWebEditorView *)sender deleteItems:(NSArray *)items;
{
    [_selectableObjectsController remove:self];
    return YES;
}

- (BOOL)webEditorView:(SVWebEditorView *)sender
           writeItems:(NSArray *)items
         toPasteboard:(NSPasteboard *)pasteboard;
{
    BOOL result = NO;
    
    NSArray *pboardReps = [items valueForKeyPath:@"representedObject.elementID"];
    if (![pboardReps containsObjectIdenticalTo:[NSNull null]])
    {
        result = YES;
        
        [pasteboard declareTypes:[NSArray arrayWithObject:kKTPageletsPboardType]
                           owner:self];
        [pasteboard setData:[NSKeyedArchiver archivedDataWithRootObject:pboardReps]
                    forType:kKTPageletsPboardType];
    }
    else
    {
        [pasteboard declareTypes:[NSArray array] owner:self];
        result = YES;
    }
    
    
    return result;
}

/*  Want to leave the Web Editor View in charge of drag & drop except for pagelets
 */
- (NSDragOperation)webEditorView:(SVWebEditorView *)sender
      dataSourceShouldHandleDrop:(id <NSDraggingInfo>)dragInfo;
{
    OBPRECONDITION(sender == [self webEditorView]);
    
    NSDragOperation result = NSDragOperationNone;
    
    NSUInteger dropIndex = [self indexOfDrop:dragInfo];
    if (dropIndex != NSNotFound)
    {
        result = NSDragOperationMove;
        
        
        // Place the drag caret to match the drop index
        NSArray *pageletContentItems = [self sidebarPageletItems];
        if (dropIndex >= [pageletContentItems count])
        {
            DOMNode *node = [_sidebarDiv lastChild];
            DOMRange *range = [[node ownerDocument] createRange];
            [range setStartAfter:node];
            [sender moveDragCaretToDOMRange:range];
        }
        else
        {
            SVWebEditorItem *aPageletItem = [pageletContentItems objectAtIndex:dropIndex];
            
            DOMRange *range = [[[aPageletItem HTMLElement] ownerDocument] createRange];
            [range setStartBefore:[aPageletItem HTMLElement]];
            [sender moveDragCaretToDOMRange:range];
        }
    }
    
    
    return result;
}

- (BOOL)webEditorView:(SVWebEditorView *)sender acceptDrop:(id <NSDraggingInfo>)dragInfo;
{
    OBPRECONDITION(sender == [self webEditorView]);
    BOOL result = NO;
    
    NSArray *pageletContentItems = [self sidebarPageletItems];
    
    
    //  When dragging within the same view, want to move the selected pagelets
    //  Possibly bad, I'm assuming all selected items are pagelets
    if ([dragInfo draggingSource] == sender)
    {
        result = YES;
        
        NSUInteger dropIndex = [self indexOfDrop:dragInfo];
        if (dropIndex == NSNotFound)
        {
            result = NO;
        }
        else if (dropIndex >= [pageletContentItems count])
        {
            SVPagelet *lastPagelet = [[pageletContentItems lastObject] representedObject];
            for (SVWebContentItem *aPageletItem in [sender selectedItems])
            {
                SVPagelet *pagelet = [aPageletItem representedObject];
                [pagelet moveAfterPagelet:lastPagelet];
            }
        }
        else
        {
            for (SVWebContentItem *aPageletItem in [sender selectedItems])
            {
                SVPagelet *anchorPagelet = [[pageletContentItems objectAtIndex:dropIndex] representedObject];
                SVPagelet *pagelet = [aPageletItem representedObject];
                [pagelet moveBeforePagelet:anchorPagelet];
            }
        }
    }
    
    
    return result;
}

#pragma mark SVWebEditorViewDelegate

- (void)webEditorViewDidFirstLayout:(SVWebEditorView *)sender;
{
    OBPRECONDITION(sender == [self webEditorView]);
    [[self delegate] webEditorViewControllerDidFirstLayout:self];
}

- (BOOL)webEditorView:(SVWebEditorView *)sender shouldChangeSelection:(NSArray *)proposedSelectedItems;
{
    //  Update our content controller's selected objects to reflect the new selection in the Web Editor View
    
    OBPRECONDITION(sender == [self webEditorView]);
    
    // TODO: Can we do this without a cast?
    NSArray *objects = [proposedSelectedItems valueForKey:@"representedObject"];
    BOOL result = [(NSArrayController *)[self selectedObjectsController] setSelectedObjects:objects];
    return result;
}

- (void)webEditorViewDidChangeSelection:(NSNotification *)notification; { }

- (void)webEditorView:(SVWebEditorView *)sender didReceiveTitle:(NSString *)title;
{
    [self setTitle:title];
}

- (void)webEditorView:(SVWebEditorView *)sender handleNavigationAction:(NSDictionary *)actionInfo request:(NSURLRequest *)request;
{
    NSURL *URL = [actionInfo objectForKey:@"WebActionOriginalURLKey"];
    
    
    // A link to another page within the document should open that page. Let the delegate take care of deciding how to open it
    NSURL *relativeURL = [URL URLRelativeToURL:[[self page] URL]];
    NSString *relativePath = [relativeURL relativePath];
    
    if (([[URL scheme] isEqualToString:@"applewebdata"] || [relativePath hasPrefix:kKTPageIDDesignator]) &&
        [[actionInfo objectForKey:WebActionNavigationTypeKey] intValue] != WebNavigationTypeOther)
    {
        KTPage *page = [[[self page] site] pageWithPreviewURLPath:relativePath];
        if (page)
        {
            [[self delegate] webEditorViewController:self openPage:page];
        }
        else if ([[self view] window])
        {
            [KSSilencingConfirmSheet alertWithWindow:[[self view] window]
                                        silencingKey:@"shutUpFakeURL"
                                               title:NSLocalizedString(@"Non-Page Link",@"title of alert")
                                              format:NSLocalizedString
             (@"You clicked on a link that would open a page that Sandvox cannot directly display.\n\n\t%@\n\nWhen you publish your website, you will be able to view the page with your browser.", @""),
             [URL path]];
        }
    }
    
    
    // Open normal links in the user's browser
    else if ([[URL scheme] isEqualToString:@"http"])
    {
        int navigationType = [[actionInfo objectForKey:WebActionNavigationTypeKey] intValue];
        switch (navigationType)
        {
            case WebNavigationTypeFormSubmitted:
            case WebNavigationTypeBackForward:
            case WebNavigationTypeReload:
            case WebNavigationTypeFormResubmitted:
                // 1.x allowed the webview to load these - do we want actually want to?
                break;
                
            case WebNavigationTypeOther:
                // Only allow the request if we're loading a page. BUGSID:26693 this stops meta tags refreshing the page
                break;
                
            default:
                // load with user's preferred browser:
                [[NSWorkspace sharedWorkspace] attemptToOpenWebURL:URL];
        }
    }
    
    // We used to do [listener use] for file: URLs. Why?
    // And again the fallback option for to -use. Why?
}

#pragma mark -

#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if (context == sWebViewDependenciesObservationContext)
    {
        [self setNeedsUpdate];
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end

