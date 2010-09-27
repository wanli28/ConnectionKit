//
//  SVIndexPlugIn.h
//  Sandvox
//
//  Created by Mike on 10/08/2010.
//  Copyright 2010 Karelia Software. All rights reserved.
//


#import "SVPlugIn.h"


@interface SVIndexPlugIn : SVPlugIn
{
  @private
    id <SVPage> _collection;
    NSUInteger _maxItems;
}

- (void)makeOriginalSize;   // indexes use this to set their width to nil

@property(nonatomic, retain) id <SVPage> indexedCollection;
@property(nonatomic) NSUInteger maxItems;

@end
