//
//  RichTextSource.m
//  KTPlugins
//
//  Copyright (c) 2004, Karelia Software. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  *  Redistribution of source code must retain the above copyright notice,
//     this list of conditions and the follow disclaimer.
//
//  *  Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other material provided with the distribution.
//
//  *  Neither the name of Karelia Software nor the names of its contributors
//     may be used to endorse or promote products derived from this software
//     without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS-IS"
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
//  Community Note: This code is distrubuted under a modified BSD License.
//  We encourage you to share your Sandvox Plugins similarly.
//

#import "RichTextSource.h"

@implementation RichTextSource

/*!	Return an array of accepted drag types, with best/richest types first
*/
- (NSArray *)acceptedDragTypesCreatingPagelet:(BOOL)isPagelet;
{
	return [NSArray arrayWithObjects:
		NSFilenamesPboardType,
		NSRTFDPboardType,
		NSRTFPboardType,
		NSStringPboardType,
		nil];
}

- (int)priorityForDrag:(id <NSDraggingInfo>)draggingInfo index:(unsigned int)anIndex;
{
    NSPasteboard *pboard = [draggingInfo draggingPasteboard];
    
	if (nil != [pboard availableTypeFromArray:[NSArray arrayWithObject:NSFilenamesPboardType]])
	{
		NSArray *fileNames = [pboard propertyListForType:NSFilenamesPboardType];
		if (anIndex < [fileNames count])
		{
			NSString *fileName = [fileNames objectAtIndex:anIndex];
			if ( nil != fileName )
			{
				// check to see if it's an rich text file
				NSString *aUTI = [NSString UTIForFileAtPath:fileName];	// takes account as much as possible
				if ([NSString UTI:aUTI conformsToUTI:(NSString *)kUTTypeRTF] || 
					[NSString UTI:aUTI conformsToUTI:(NSString *)kUTTypeFlatRTFD] ||
					[NSString UTI:aUTI conformsToUTI:(NSString *)kUTTypeRTFD] ||
					[NSString UTI:aUTI conformsToUTI:@"com.microsoft.word.doc"]
					)
				{
					return KTSourcePriorityIdeal;
				}
				else if ([NSString UTI:aUTI conformsToUTI:(NSString *)kUTTypePlainText])
				{
					return KTSourcePriorityTypical;
				}
				/// MMMMmaybe we will handle other kind of text ... doubtful.
				else if ([NSString UTI:aUTI conformsToUTI:(NSString *)kUTTypeText])
				{
					return KTSourcePriorityFallback;
				}
				else
				{
					return KTSourcePriorityNone;		// doesn't look like a rich text file
				}
			}
		}
	}
    return KTSourcePriorityFallback;		// file-less rich text, this should be OK ... unless something better comes along
}

- (BOOL)populateDictionary:(NSMutableDictionary *)aDictionary
				forPagelet:(BOOL)isAPagelet
		  fromDraggingInfo:(id <NSDraggingInfo>)draggingInfo
					 index:(unsigned int)anIndex;
{
    BOOL result = NO;
    NSString *filePath= nil;
    
    NSArray *orderedTypes = [self acceptedDragTypesCreatingPagelet:isAPagelet];
    
    NSPasteboard *pboard = [draggingInfo draggingPasteboard];

    NSString *bestType = [pboard availableTypeFromArray:orderedTypes];
    if ( [bestType isEqualToString:NSFilenamesPboardType] )
    {
		NSArray *filePaths = [pboard propertyListForType:NSFilenamesPboardType];
		if (anIndex < [filePaths count])
		{
			filePath = [filePaths objectAtIndex:anIndex];
			if ( nil != filePath )
			{
				[aDictionary setValue:[[NSFileManager defaultManager] resolvedAliasPath:filePath]
							   forKey:kKTDataSourceFilePath];
				[aDictionary setValue:[filePath lastPathComponent] forKey:kKTDataSourceFileName];
				result = YES;
			}
		}
    }
	else
	{
		NSString *string = nil;
		// Get a title from the FIRST line of the text
		if (nil != [pboard availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]]
				 && nil != (string = [pboard stringForType:NSStringPboardType]))
		{
			NSString *firstLine = string;
			NSRange firstNewLine = [string rangeOfCharacterFromSet:[NSCharacterSet fullNewlineCharacterSet]];
			if (NSNotFound != firstNewLine.location)
			{
				firstLine = [string substringToIndex:firstNewLine.location];
			}
			[aDictionary setValue:firstLine forKey:kKTDataSourceTitle];
		}
		
		result = YES;	// client will get data from pasteboard
	}
    
    return result;
}

- (NSString *)pageBundleIdentifier
{
	return @"sandvox.RichTextElement";
}

- (NSString *)pageletBundleIdentifier
{
	return @"sandvox.RichTextElement";
}

@end
