//
//  KTDocumentController.h
//  Marvel
//
//  Created by Terrence Talbot on 9/20/05.
//  Copyright 2005-2009 Karelia Software. All rights reserved.
//

#import "KSDocumentController.h"


@class KTDocument, SVDesignChooserWindowController;


@interface KTDocumentController : KSDocumentController
{
	// New docs
	IBOutlet NSView			*oNewDocAccessoryView;
	IBOutlet NSPopUpButton	*oNewDocHomePageTypePopup;
  @private
    SVDesignChooserWindowController *_designChooser;
}

- (void)showDocumentPlaceholderWindowInitial:(BOOL)firstTimeSoReopenSavedDocuments;

@end
