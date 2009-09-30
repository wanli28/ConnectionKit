//
//  SVWebEditorWebView.m
//  Sandvox
//
//  Created by Mike on 23/09/2009.
//  Copyright 2009 Karelia Software. All rights reserved.
//

#import "SVWebEditorWebView.h"
#import "SVWebEditorView.h"

#import "DOMNode+Karelia.h"


@implementation SVWebEditorWebView

- (SVWebEditorView *)webEditorView
{
    return (SVWebEditorView *)[self superview];
}

#pragma mark Dragging Destination

/*  Our aim here is to extend WebView to support some extra drag & drop methods that we'd prefer. Override everything to be sure we don't collide with WebKit in an unexpected manner.
 */

- (NSDragOperation)draggingEntered:(id < NSDraggingInfo >)sender
{
    NSDragOperation result = [super draggingEntered:sender];
    result = [[self webEditorView] validateDrop:sender proposedOperation:result];
    
    return result;
}

- (NSDragOperation)draggingUpdated:(id < NSDraggingInfo >)sender
{
    NSDragOperation result = [super draggingUpdated:sender];
    
    // WebKit bug workaround: When dragging exits an editable area, although the cursor updates properly, the drag caret is not removed
    if (result == NSDragOperationNone) [self removeDragCaret];
    
    result = [[self webEditorView] validateDrop:sender proposedOperation:result];
    return result;
}

- (void)draggingExited:(id < NSDraggingInfo >)sender
{
    [super draggingExited:sender];
    
    // Need to end any of our custom drawing
    [[self webEditorView] removeDragCaret];
    [[self webEditorView] moveDragHighlightToDOMNode:nil];
}

- (BOOL)prepareForDragOperation:(id < NSDraggingInfo >)sender
{
    BOOL result = [super prepareForDragOperation:sender];
    
    // Need to end any of our custom drawing
    [[self webEditorView] removeDragCaret];
    [[self webEditorView] moveDragHighlightToDOMNode:nil];
    
    return result;
}

@end

