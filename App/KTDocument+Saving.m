//
//  KTDocument+Saving.m
//  Marvel
//
//  Created by Mike on 26/02/2008.
//  Copyright 2008 Karelia Software. All rights reserved.
//

#import "KTDocument.h"

#import "KTDesign.h"
#import "KTDocumentController.h"
#import "KTDocWindowController.h"
#import "KTDocSiteOutlineController.h"
#import "KTHTMLParser.h"
#import "KTPage.h"
#import "KTMaster.h"
#import "KTMediaManager+Internal.h"

#import "CIImage+Karelia.h"
#import "NSFileManager+Karelia.h"
#import "NSImage+Karelia.h"
#import "NSImage+KTExtensions.h"
#import "NSManagedObjectContext+KTExtensions.h"
#import "NSManagedObject+KTExtensions.h"
#import "NSMutableSet+Karelia.h"
#import "NSThread+Karelia.h"
#import "NSView+Karelia.h"
#import "NSWorkspace+Karelia.h"

#import "KTWebKitCompatibility.h"

#import "Debug.h"


/*	These strings are used for generating Quick Look preview sticky-note text
 */
// NSLocalizedString(@"Published at", "Quick Look preview sticky-note text");
// NSLocalizedString(@"Last updated", "Quick Look preview sticky-note text");
// NSLocalizedString(@"Author", "Quick Look preview sticky-note text");
// NSLocalizedString(@"Language", "Quick Look preview sticky-note text");
// NSLocalizedString(@"Pages", "Quick Look preview sticky-note text");


// TODO: change these into defaults
#define FIRST_AUTOSAVE_DELAY 3
#define SECOND_AUTOSAVE_DELAY 60


@interface KTDocument (PropertiesPrivate)
- (void)copyDocumentDisplayPropertiesToModel;
@end


@interface KTDocument (SavingPrivate)

// Write Safely
- (NSString *)backupExistingFileForSaveAsOperation:(NSString *)path error:(NSError **)error;
- (void)recoverBackupFile:(NSString *)backupPath toURL:(NSURL *)saveURL;

// Write To URL
- (BOOL)prepareToWriteToURL:(NSURL *)inURL 
					 ofType:(NSString *)inType 
		   forSaveOperation:(NSSaveOperationType)inSaveOperation 
					  error:(NSError **)outError;

- (BOOL)writeMOCToURL:(NSURL *)inURL 
			   ofType:(NSString *)inType 
	 forSaveOperation:(NSSaveOperationType)inSaveOperation 
				error:(NSError **)outError;

- (BOOL)migrateToURL:(NSURL *)URL 
			  ofType:(NSString *)typeName 
			   error:(NSError **)outError;

- (WebView *)newQuickLookThumbnailWebView;
@end


#pragma mark -


@implementation KTDocument (Saving)

// TODO: add in code to do a backup or snapshot, see KTDocument+Deprecated.m. Should be in one of the -saveToURL methods.

#pragma mark -
#pragma mark Write Safely

/*	We override the behavior to save directly ('unsafely' I suppose!) to the URL,
 *	rather than via a temporary file as is the default.
 */
- (BOOL)writeSafelyToURL:(NSURL *)absoluteURL 
				  ofType:(NSString *)typeName 
		forSaveOperation:(NSSaveOperationType)saveOperation 
				   error:(NSError **)outError
{
	// We're only interested in special behaviour for Save As operations
	if (saveOperation != NSSaveAsOperation)
	{
		return [super writeSafelyToURL:absoluteURL 
								ofType:typeName 
					  forSaveOperation:saveOperation 
								 error:outError];
	}
	
	
	// We'll need a path for various operations below
	NSAssert2([absoluteURL isFileURL], @"%@ called for non-file URL: %@", NSStringFromSelector(_cmd), [absoluteURL absoluteString]);
	NSString *path = [absoluteURL path];
	
	
	// If a file already exists at the desired location move it out of the way
	NSString *backupPath = nil;
	if ([[NSFileManager defaultManager] fileExistsAtPath:path])
	{
		backupPath = [self backupExistingFileForSaveAsOperation:path error:outError];
		if (!backupPath) return NO;
	}
	
	
	// We want to catch all possible errors so that the save can be reverted. We cover exceptions & errors. Sadly crashers can't
	// be dealt with at the moment.
	BOOL result = NO;
	
	@try
	{
		// Write to the new URL
		result = [self writeToURL:absoluteURL
						   ofType:typeName
				 forSaveOperation:saveOperation
			  originalContentsURL:[self fileURL]
							error:outError];
	}
	@catch (NSException *exception) 
	{
		// Recover from an exception as best as possible and then rethrow the exception so it goes the exception reporter mechanism
		[self recoverBackupFile:backupPath toURL:absoluteURL];
		[exception raise];
	}
	
	
	if (result)
	{
		// The save was successful, delete the backup file
		if (backupPath)
		{
			[[NSFileManager defaultManager] removeFileAtPath:backupPath handler:nil];
		}
	}
	else
	{
		// There was an error saving, recover from it
		[self recoverBackupFile:backupPath toURL:absoluteURL];
	}
	
	return result;
}

/*	Support method for -writeSafelyToURL:
 *	Returns nil and an error if the file cannot be backed up.
 */
- (NSString *)backupExistingFileForSaveAsOperation:(NSString *)path error:(NSError **)error
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	// Move the existing file to the best available backup path
	NSString *backupDirectory = [path stringByDeletingLastPathComponent];
	NSString *preferredFilename = [NSString stringWithFormat:@"Backup of %@", [path lastPathComponent]];
	NSString *preferredPath = [backupDirectory stringByAppendingPathComponent:preferredFilename];
	NSString *backupFilename = [fileManager uniqueFilenameAtPath:preferredPath];
	NSString *result = [backupDirectory stringByAppendingPathComponent:backupFilename];
	
	BOOL success = [fileManager movePath:path toPath:result handler:nil];
	if (!success)
	{
		// The backup failed, construct an error
		result = nil;
		
		NSString *failureReason = [NSString stringWithFormat:@"Could not remove the existing file at:\r%@", path];
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:@"Unable to save document", NSLocalizedDescriptionKey,
																			failureReason, NSLocalizedFailureReasonErrorKey,
																			path, NSFilePathErrorKey, nil];
		*error = [NSError errorWithDomain:@"KTDocument" code:0 userInfo:userInfo];
	}
	
	return result;
}

/*	In the event of a Save As operation failing, we copy the backup file back to the original location.
 */
- (void)recoverBackupFile:(NSString *)backupPath toURL:(NSURL *)saveURL
{
	// Dump the failed save
	NSString *savePath = [saveURL path];
	BOOL result = [[NSFileManager defaultManager] removeFileAtPath:savePath handler:nil];
	
	// Recover the backup if there is one
	if (backupPath)
	{
		result = [[NSFileManager defaultManager] movePath:backupPath toPath:[saveURL path] handler:nil];
	}
	
	if (!result)
	{
		NSLog(@"Could not recover backup file:\r%@\rafter Save As operation failed for URL:\r%@", backupPath, [saveURL path]);
	}
}

#pragma mark -
#pragma mark Write To URL

/*	Called when creating a new document and when performing saveDocumentAs:
 */
- (BOOL)writeToURL:(NSURL *)inURL 
			ofType:(NSString *)inType 
  forSaveOperation:(NSSaveOperationType)inSaveOperation originalContentsURL:(NSURL *)inOriginalContentsURL error:(NSError **)outError 
{
	NSAssert([NSThread isMainThread], @"should be called only from the main thread");
	BOOL result = NO;
	
	
	// Prepare to save the context
	NSDate *documentSaveLimit = [[NSDate date] addTimeInterval:10.0];
	WebView *quickLookThumbnailWebView = [self newQuickLookThumbnailWebView];
	result = [self prepareToWriteToURL:inURL ofType:inType forSaveOperation:inSaveOperation error:outError];
	
	
	if (result)
	{
		// Save the context
		result = [self writeMOCToURL:inURL ofType:inType forSaveOperation:inSaveOperation error:outError];
		
		
		if (result)
		{
			// Wait a second before putting up a progress sheet
			while ([quickLookThumbnailWebView isLoading] && [documentSaveLimit timeIntervalSinceNow] > 8.0)
			{
				[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:documentSaveLimit];
			}
			BOOL beganSheet = NO;
			if ([quickLookThumbnailWebView isLoading])
			{
				[[self windowController] beginSheetWithStatus:NSLocalizedString(@"Saving\\U2026","Message title when performing a lengthy save")
														image:nil];
				beganSheet = YES;
			}
			
			
			
			// Wait for the thumbnail to complete. We shall allocate a maximum of 10 seconds for this
			while ([quickLookThumbnailWebView isLoading] && [documentSaveLimit timeIntervalSinceNow] > 0.0)
			{
				[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:documentSaveLimit];
			}
			
			if (![quickLookThumbnailWebView isLoading])
			{
				// Write the thumbnail to disk
				[quickLookThumbnailWebView displayIfNeeded];	// Otherwise we'll be capturing a blank frame!
				NSImage *snapshot = [[[[quickLookThumbnailWebView mainFrame] frameView] documentView] snapshot];
				
				NSImage *snapshot512 = [snapshot imageWithMaxWidth:512 height:512 
														  behavior:([snapshot width] > [snapshot height]) ? kFitWithinRect : kCropToRect
														 alignment:NSImageAlignTop];
				
				NSURL *thumbnailURL = [NSURL URLWithString:@"thumbnail.png" relativeToURL:[KTDocument quickLookURLForDocumentURL:inURL]];
				result = [[snapshot512 PNGRepresentation] writeToURL:thumbnailURL options:NSAtomicWrite error:outError];
			}
			
			
			// Close the progress sheet
			if (beganSheet)
			{
				[[self windowController] endSheet];
			}
		}
	}
	
	
	// Tidy up
	NSWindow *webViewWindow = [quickLookThumbnailWebView window];
	[quickLookThumbnailWebView release];
	[webViewWindow release];
	
	return result;
}


/*	Support method that sets the environment ready for the MOC and other document contents to be written to disk.
 */
- (BOOL)prepareToWriteToURL:(NSURL *)inURL 
					 ofType:(NSString *)inType 
		   forSaveOperation:(NSSaveOperationType)inSaveOperation 
					  error:(NSError **)outError
{
	// REGISTRATION -- be annoying if it looks like the registration code was bypassed
	if ( ((0 == gRegistrationWasChecked) && random() < (LONG_MAX / 10) ) )
	{
		// NB: this is a trick to make a licensing issue look like an Unknown Store Type error
		// KTErrorReason/KTErrorDomain is a nonsense response to flag this as bad license
		NSError *registrationError = [NSError errorWithDomain:NSCocoaErrorDomain
														 code:134000 // invalid type error, for now
													 userInfo:[NSDictionary dictionaryWithObject:@"KTErrorDomain"
																						  forKey:@"KTErrorReason"]];
		if ( nil != outError )
		{
			// we'll pass registrationError back to the document for presentation
			*outError = registrationError;
		}
		
		return NO;
	}
	
	
	// For the first save of a document, create the wrapper paths on disk before we do anything else
	if (inSaveOperation == NSSaveAsOperation)
	{
		[[NSFileManager defaultManager] createDirectoryAtPath:[inURL path] attributes:nil];
		[[NSWorkspace sharedWorkspace] setBundleBit:YES forFile:[inURL path]];
		
		[[NSFileManager defaultManager] createDirectoryAtPath:[[KTDocument siteURLForDocumentURL:inURL] path] attributes:nil];
		[[NSFileManager defaultManager] createDirectoryAtPath:[[KTDocument mediaURLForDocumentURL:inURL] path] attributes:nil];
		[[NSFileManager defaultManager] createDirectoryAtPath:[[KTDocument quickLookURLForDocumentURL:inURL] path] attributes:nil];
	}
	
	
	// Make sure we have a persistent store coordinator properly set up
	NSManagedObjectContext *managedObjectContext = [self managedObjectContext];
	NSPersistentStoreCoordinator *storeCoordinator = [managedObjectContext persistentStoreCoordinator];
	NSURL *persistentStoreURL = [KTDocument datastoreURLForDocumentURL:inURL];
	
	if ((inSaveOperation == NSSaveOperation) && ![storeCoordinator persistentStoreForURL:persistentStoreURL]) 
	{
		// NSDocument does atomic saves so the first time the user saves it's in a temporary
		// directory and the file is then moved to the actual save path, so we need to tell the 
		// persistentStoreCoordinator to remove the old persistentStore, otherwise if we attempt
		// to migrate it, the coordinator complains because it knows they are the same store
		// despite having two different URLs
		(void)[storeCoordinator removePersistentStore:[[storeCoordinator persistentStores] objectAtIndex:0]
												error:outError];
	}
	
	if ([[storeCoordinator persistentStores] count] < 1)
	{ 
		// this is our first save so we just set the persistentStore and save normally
//		BOOL didConfigure = [self configurePersistentStoreCoordinatorForURL:inURL // not newSaveURL as configurePSC needs to be consistent
//																	 ofType:[KTDocument defaultStoreType]
//														 modelConfiguration:nil
//															   storeOptions:nil
//																	  error:outError];
		// the above method isn't available in Tiger, so we use the old, deprecated method
		
		BOOL didConfigure = [self configurePersistentStoreCoordinatorForURL:inURL // not newSaveURL as configurePSC needs to be consistent
																	 ofType:[KTDocument defaultStoreType]
																	  error:outError];
		
		id newStore = [storeCoordinator persistentStoreForURL:persistentStoreURL];
		if ( !newStore || !didConfigure )
		{
			NSLog(@"error: unable to create document: %@", [*outError description]);
			return NO; // bail out and display outError
		}
	} 
	
	
	// Set metadata
	if ( nil != [storeCoordinator persistentStoreForURL:persistentStoreURL] )
	{
		if ( ![self setMetadataForStoreAtURL:persistentStoreURL error:outError] )
		{
			return NO; // couldn't setMetadata, but we should have, bail...
		}
	}
	else
	{
		if ( inSaveOperation != NSSaveAsOperation )
		{
			LOG((@"error: wants to setMetadata during save but no persistent store at %@", persistentStoreURL));
			return NO; // this case should not happen, stop
		}
	}
	
	
	// Record display properties
	[managedObjectContext processPendingChanges];
	[[managedObjectContext undoManager] disableUndoRegistration];
	[self copyDocumentDisplayPropertiesToModel];
	[managedObjectContext processPendingChanges];
	[[managedObjectContext undoManager] enableUndoRegistration];
	
	
	return YES;
}

- (BOOL)writeMOCToURL:(NSURL *)inURL 
			   ofType:(NSString *)inType 
	 forSaveOperation:(NSSaveOperationType)inSaveOperation 
				error:(NSError **)outError
{
	NSAssert([NSThread isMainThread], @"should be called only from the main thread");
	
	BOOL result = NO;
	NSError *error = nil;
	
	
	NSManagedObjectContext *managedObjectContext = [self managedObjectContext];
	
	
	// Handle the user choosing "Save As" for an EXISTING document
	if (inSaveOperation == NSSaveAsOperation && [self fileURL])
	{
		result = [self migrateToURL:inURL ofType:inType error:&error];
		if (!result)
		{
			*outError = error;
			return NO; // bail out and display outError
		}
		else
		{
			result = [self setMetadataForStoreAtURL:[KTDocument datastoreURLForDocumentURL:inURL]
											  error:&error];
		}
	}
	
	
	// Store QuickLook preview
	KTHTMLParser *parser = [[KTHTMLParser alloc] initWithPage:[self root]];
	[parser setHTMLGenerationPurpose:kGeneratingQuickLookPreview];
	NSString *previewHTML = [parser parseTemplate];
	[parser release];
	
	NSString *previewPath = [[[KTDocument quickLookURLForDocumentURL:inURL] path] stringByAppendingPathComponent:@"preview.html"];
	[previewHTML writeToFile:previewPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	
	
	// we very temporarily keep a weak pointer to ourselves as lastSavedDocument
	// so that saveDocumentAs: can find us again until the new context is fully ready
	/// These are disabled since in theory they're not needed any more, but we want to be sure. MA & TT.
	//[[KTDocumentController sharedDocumentController] setLastSavedDocument:self];
	
	result = [managedObjectContext save:&error];
	if (result) result = [[[self mediaManager] managedObjectContext] save:&error];
	
	//[[KTDocumentController sharedDocumentController] setLastSavedDocument:nil];
	
	if (result)
	{
		// if we've saved, we don't need to autosave until after the next context change
		[self cancelAndInvalidateAutosaveTimers];
	}
	
	
	// Return, making sure to supply appropriate error info
	if (!result) *outError = error;
	return result;
}

/*	Called when performaing a "Save As" operation on an existing document
 */
- (BOOL)migrateToURL:(NSURL *)URL ofType:(NSString *)typeName error:(NSError **)outError
{
	// Build a list of the media files that will require copying/moving to the new doc
	NSManagedObjectContext *mediaMOC = [[self mediaManager] managedObjectContext];
	NSArray *mediaFiles = [mediaMOC allObjectsWithEntityName:@"AbstractMediaFile" error:NULL];
	NSMutableSet *pathsToCopy = [[NSMutableSet alloc] initWithCapacity:[mediaFiles count]];
	NSMutableSet *pathsToMove = [[NSMutableSet alloc] initWithCapacity:[mediaFiles count]];
	
	NSEnumerator *mediaFilesEnumerator = [mediaFiles objectEnumerator];
	KTMediaFile *aMediaFile;
	while (aMediaFile = [mediaFilesEnumerator nextObject])
	{
		NSString *path = [aMediaFile currentPath];
		if ([aMediaFile isTemporaryObject])
		{
			[pathsToMove addObjectIgnoringNil:path];
		}
		else
		{
			[pathsToCopy addObjectIgnoringNil:path];
		}
	}
	
	
	// Migrate the main document store
	NSURL *storeURL = [KTDocument datastoreURLForDocumentURL:URL];
	NSPersistentStoreCoordinator *storeCoordinator = [[self managedObjectContext] persistentStoreCoordinator];
	
	if (![storeCoordinator migratePersistentStore:[[storeCoordinator persistentStores] objectAtIndex:0]
										    toURL:storeURL
										  options:nil
										 withType:[KTDocument defaultStoreType]
										    error:outError])
	{
		return NO;
	}
	
	// Set the new metadata
	if ( ![self setMetadataForStoreAtURL:storeURL error:outError] )
	{
		return NO;
	}	
	
	// Migrate the media store
	storeURL = [KTDocument mediaStoreURLForDocumentURL:URL];
	storeCoordinator = [[[self mediaManager] managedObjectContext] persistentStoreCoordinator];
	
	if (![storeCoordinator migratePersistentStore:[[storeCoordinator persistentStores] objectAtIndex:0]
										    toURL:storeURL
										  options:nil
										 withType:[KTDocument defaultMediaStoreType]
										    error:outError])
	{
		return NO;
	}
	
	
	// Copy/Move media files
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *newDocMediaPath = [[KTDocument mediaURLForDocumentURL:URL] path];
	
	NSEnumerator *pathsEnumerator = [pathsToCopy objectEnumerator];
	NSString *aPath;	NSString *destinationPath;
	while (aPath = [pathsEnumerator nextObject])
	{
		destinationPath = [newDocMediaPath stringByAppendingPathComponent:[aPath lastPathComponent]];
		[fileManager copyPath:aPath toPath:destinationPath handler:nil];
	}
	
	pathsEnumerator = [pathsToMove objectEnumerator];
	while (aPath = [pathsEnumerator nextObject])
	{
		destinationPath = [newDocMediaPath stringByAppendingPathComponent:[aPath lastPathComponent]];
		[fileManager movePath:aPath toPath:destinationPath handler:nil];
	}
	
	
	// Tidy up
	[pathsToCopy release];
	[pathsToMove release];
	
	return YES;
}

#pragma mark -
#pragma mark Quick Look Thumbnail

/*	Please note the "new" in the title. The result is NOT autoreleased. And neither is its window.
 */
- (WebView *)newQuickLookThumbnailWebView
{
	// Put together the HTML for the thumbnail
	KTHTMLParser *parser = [[KTHTMLParser alloc] initWithPage:[self root]];
	[parser setHTMLGenerationPurpose:kGeneratingPreview];
	[parser setLiveDataFeeds:NO];
	NSString *thumbnailHTML = [parser parseTemplate];
	[parser release];
	
	
	// Create the webview. It must be in an offscreen window to do this properly.
	unsigned designViewport = [[[[self root] master] design] viewport];	// Ensures we don't clip anything important
	NSRect frame = NSMakeRect(0.0, 0.0, designViewport+20, designViewport+20);	// The 20 keeps scrollbars out the way
	
	NSWindow *window = [[NSWindow alloc]
		initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];	// Otherwise we crash upon quitting - I guess NSApplication closes all windows when termintating?
	
	WebView *result = [[WebView alloc] initWithFrame:frame];	// Both window and webview will be released later
	[window setContentView:result];
	
	
	// Go ahead and begin building the thumbnail
	[[result mainFrame] loadHTMLString:thumbnailHTML baseURL:nil];
	return result;
}

#pragma mark -
#pragma mark Autosave

// main entry point for saving the document programmatically
- (IBAction)autosaveDocument:(id)sender
{
	// the timer will fire whether there are changes to save or not
	// but we only want to save if hasChanges
	if ( [[self managedObjectContext] hasChanges] && (nil != [self fileURL]) )
	{
		LOGMETHOD;
		OBASSERT([NSThread isMainThread]);
		
		// remember the current status
		NSString *status = [[[self windowController] status] copy];
		
		// update status 
		[[self windowController] setStatusField:NSLocalizedString(@"Autosaving...", "Status: Autosaving...")];
		
		// turn off timers before doing save
		[self suspendAutosave];

		// save the document through normal channels (ultimately calls writeToURL:::)
		[self saveDocumentWithDelegate:self
					   didSaveSelector:@selector(document:didAutosave:contextInfo:) contextInfo:status];
	}
}

- (void)document:(NSDocument *)doc didAutosave:(BOOL)didSave contextInfo:(void  *)contextInfo
{
	NSAssert1(doc == self, @"%@ called for unknown document", _cmd);
	
	if ([(id)contextInfo isKindOfClass:[NSString class]])
	{
		// restore status
		NSString *contextInfoString = contextInfo;
		[[self windowController] setStatusField:contextInfoString];
		
		[contextInfoString release]; // balances copy in autosaveDocument:
	}
	
	[self resumeAutosave];
}

- (void)fireAutosave:(id)notUsedButRequiredParameter
{
	//LOGMETHOD;
	
	NSAssert([NSThread isMainThread], @"should be main thread");
	
	[self cancelAndInvalidateAutosaveTimers];
	[self performSelector:@selector(autosaveDocument:)
			   withObject:nil
			   afterDelay:0.0];
}

- (void)fireAutosaveViaTimer:(NSTimer *)aTimer
{
	//LOGMETHOD;
	
	NSAssert([NSThread isMainThread], @"should be main thread");
	
    if ( [myLastSavedTime timeIntervalSinceNow] >= SECOND_AUTOSAVE_DELAY )
    {
		[self cancelAndInvalidateAutosaveTimers];
		[self performSelector:@selector(autosaveDocument:)
				   withObject:nil
				   afterDelay:0.0];
    }
}

- (void)restartAutosaveTimersIfNecessary
{
	//LOGMETHOD;
	
	NSAssert([NSThread isMainThread], @"should be main thread");
	
	if ( !myIsSuspendingAutosave )
	{
		// timer A, save in 3 seconds, cancelled by change to context
		//LOG((@"cancelling previous and starting new 3 second timer"));
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireAutosave:) object:nil];
		[self performSelector:@selector(fireAutosave:) withObject:nil afterDelay:FIRST_AUTOSAVE_DELAY];
		
		// timer B, save in 60 seconds, if not saved within last 60 seconds
		if ( nil == myAutosaveTimer )
		{
			// start a timer
			//LOG((@"starting new 60 second timer"));
			NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:SECOND_AUTOSAVE_DELAY
															  target:self
															selector:@selector(fireAutosaveViaTimer:)
															userInfo:nil
															 repeats:NO];
			[self setAutosaveTimer:timer];
		}
	}
}

- (void)cancelAndInvalidateAutosaveTimers
{
	//LOGMETHOD;
	
	NSAssert([NSThread isMainThread], @"should be main thread");

	//LOG((@"cancelling autosave timers"));
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireAutosave:) object:nil];
	@synchronized ( myAutosaveTimer )
	{
		[self setAutosaveTimer:nil];
	}
	
	// also clear run loop of any previous requests that made it through
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autosaveDocument:) object:nil];
}

- (void)suspendAutosave
{
	LOGMETHOD;
	
	//LOG((@"---------------------------------------------- deactivating autosave"));
	if ( !myIsSuspendingAutosave || !(kGeneratingPreview == [[self windowController] publishingMode]) )
	{
		myIsSuspendingAutosave = YES;
	}
	if ( [NSThread isMainThread] )
	{
		[self cancelAndInvalidateAutosaveTimers];
	}
	else
	{
		[self performSelectorOnMainThread:@selector(cancelAndInvalidateAutosaveTimers) withObject:nil waitUntilDone:NO];
	}
}

- (void)resumeAutosave
{
	LOGMETHOD;
	
	//LOG((@"---------------------------------------------- (re)activating autosave"));
	if ( myIsSuspendingAutosave || !(kGeneratingPreview == [[self windowController] publishingMode]) )
	{
		myIsSuspendingAutosave = NO;
	}
	if ( [NSThread isMainThread] )
	{
		[self restartAutosaveTimersIfNecessary];
	}
	else
	{
		[self performSelectorOnMainThread:@selector(restartAutosaveTimersIfNecessary) withObject:nil waitUntilDone:NO];
	}
}

@end
