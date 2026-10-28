#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

@interface NSColorSpace : NSObject
+ (instancetype)sRGBColorSpace;
+ (instancetype)genericRGBColorSpace;
@end
@implementation NSColorSpace
+ (instancetype)sRGBColorSpace {
    static NSColorSpace *space; static dispatch_once_t once;
    dispatch_once(&once, ^{ space = [NSColorSpace new]; }); return space;
}
+ (instancetype)genericRGBColorSpace { return [self sRGBColorSpace]; }
@end

// Draws through a CGContext, which only takes premultiplied pixels, then divides
// the alpha back out. That loses the colour of nearly transparent pixels, so it is
// only the fallback for an image vImage can't convert.
static BOOL DrawUnpremultiplied(CGImageRef image, uint8_t *pixels, size_t width, size_t height, CGColorSpaceRef space) {
    CGContextRef context=CGBitmapContextCreate(pixels,width,height,8,width*4,space,
                                               kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    if (!context) return NO;
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
    CGContextRelease(context);
    uint8_t *p=pixels;
    for (size_t i=0;i<width*height;i++,p+=4) {
        unsigned a=p[3];
        if (a && a<255) for (int c=0;c<3;c++) p[c]=(uint8_t)MIN(255,(p[c]*255u+a/2)/a);
    }
    return YES;
}

// The original loader reads tightly packed, unpremultiplied RGBA8 and performs
// its own optional premultiplication. ImageIO decodes the PNG and vImage repacks
// it as sRGB RGBA8; for the usual 8-bit RGBA sprite that is the file's own samples.
// Most of the game's sprite loading time is spent here, on its loader threads.
@interface NSBitmapImageRep : NSObject
@property(nonatomic,strong) NSMutableData *pixels;
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@end
@implementation NSBitmapImageRep
+ (instancetype)imageRepWithData:(NSData *)data {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);
    if (!source) return nil;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source,0,NULL);
    CFRelease(source);
    if (!image) return nil;
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if (!width || !height || width>SIZE_MAX/4/height) { CGImageRelease(image); return nil; }
    NSBitmapImageRep *result = [self new];
    result.width=width; result.height=height;
    result.pixels=[NSMutableData dataWithLength:width*height*4];
    vImage_CGImageFormat format={.bitsPerComponent=8,.bitsPerPixel=32,.colorSpace=space,
                                 .bitmapInfo=(CGBitmapInfo)kCGImageAlphaLast|kCGBitmapByteOrder32Big};
    vImage_Buffer buffer={.data=result.pixels.mutableBytes,.height=height,.width=width,.rowBytes=width*4};
    BOOL decoded=vImageBuffer_InitWithCGImage(&buffer,&format,NULL,image,kvImageNoAllocate)==kvImageNoError ||
                 DrawUnpremultiplied(image,result.pixels.mutableBytes,width,height,space);
    CGImageRelease(image);
    return decoded ? result : nil;
}
- (unsigned char *)bitmapData { return self.pixels.mutableBytes; }
- (NSInteger)pixelsWide { return self.width; }
- (NSInteger)pixelsHigh { return self.height; }
- (NSInteger)bitsPerPixel { return 32; }
- (NSInteger)samplesPerPixel { return 4; }
- (NSColorSpace *)colorSpace { return [NSColorSpace sRGBColorSpace]; }
- (instancetype)bitmapImageRepByRetaggingWithColorSpace:(NSColorSpace *)space { return self; }
- (instancetype)bitmapImageRepByConvertingToColorSpace:(NSColorSpace *)space renderingIntent:(NSInteger)intent { return self; }
@end
