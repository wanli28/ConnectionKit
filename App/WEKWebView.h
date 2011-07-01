//
//  WEKWebView.h
//  Sandvox
//
//  Created by Mike on 23/09/2009.
//  Copyright 2009-2011 Karelia Software. All rights reserved.
//

//  Main purpose is to pass any unhandled drags up to the superview to deal with

#import "WEKWebViewEditing.h"


@class WEKWebEditorView;


@interface WEKWebView : WebView
{
    BOOL    _delegateWillHandleDraggingInfo;
}

@property(nonatomic, readonly) WEKWebEditorView *webEditor;

@property(nonatomic, readonly) BOOL delegateWillHandleDraggingInfo;

// Returns YES if the first responder is a subview of the receiver
@property(nonatomic, readonly) BOOL isFirstResponder;

@end