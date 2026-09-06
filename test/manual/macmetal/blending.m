/* Exercise the actual renderer shaders and pipelines with GPU readback.  */
#include "../../../src/macmetal.m"
#include <stdio.h>

static int
check_pixel (id<MTLRenderPipelineState> pipeline, MTLPixelFormat format,
             uint32_t color, uint32_t texture_id)
{
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
    width:1 height:1 mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget;
  desc.storageMode = MTLStorageModeShared;
  id<MTLTexture> target = [shared_device newTextureWithDescriptor:desc];
  desc.pixelFormat = format;
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> source = [shared_device newTextureWithDescriptor:desc];
  uint8_t pixel[] = {128, 128, 128, 128};
  [source replaceRegion:MTLRegionMake2D (0, 0, 1, 1) mipmapLevel:0
              withBytes:pixel bytesPerRow:format == MTLPixelFormatR8Unorm ? 1 : 4];
  metal_vertex_t vertices[6];
  const float positions[6][2] = {{0,0},{1,0},{0,1},{1,0},{1,1},{0,1}};
  for (int i = 0; i < 6; ++i)
    set_vertex (&vertices[i], positions[i][0], positions[i][1],
                0.5, 0.5, color, texture_id);
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake (0, 0, 0, 1);
  id<MTLCommandQueue> queue = [shared_device newCommandQueue];
  id<MTLCommandBuffer> cmd = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBytes:vertices length:sizeof vertices atIndex:0];
  float viewport[] = {1, 1};
  [encoder setVertexBytes:viewport length:sizeof viewport atIndex:1];
  [encoder setFragmentTexture:source atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [encoder endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];
  if (cmd.status != MTLCommandBufferStatusCompleted)
    { NSLog (@"GPU failure: %@", cmd.error); return 1; }
  [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D (0, 0, 1, 1)
        mipmapLevel:0];
  printf ("type %u: BGRA = %u %u %u %u (expected 128 128 128 255)\n",
          texture_id, pixel[0], pixel[1], pixel[2], pixel[3]);
  return abs (pixel[0] - 128) > 1 || abs (pixel[1] - 128) > 1
    || abs (pixel[2] - 128) > 1 || pixel[3] != 255;
}

int main (void)
{
  @autoreleasepool {
    shared_device = MTLCreateSystemDefaultDevice ();
    if (!shared_device) { fputs ("No Metal device available\n", stderr); return 77; }
    if (!create_pipelines ()) return 1;
    int failures = check_pixel (shared_textured_pipeline, MTLPixelFormatBGRA8Unorm,
                                0xffffffff, 2);
    failures += check_pixel (shared_textured_pipeline, MTLPixelFormatR8Unorm,
                             0xffffffff, 1);
    failures += check_pixel (shared_solid_pipeline, MTLPixelFormatBGRA8Unorm,
                             0x80ffffff, 0);
    return failures ? 1 : 0;
  }
}
