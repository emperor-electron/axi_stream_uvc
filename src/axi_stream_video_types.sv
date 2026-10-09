///////////////////////////////////////////////////////////////////
// Filename: axi_stream_video_types.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Shared enumerations, typedefs and capacity constants for
//           the UVC's video layer: pixel formats, image file formats
//           and built-in test patterns.
///////////////////////////////////////////////////////////////////
//
// The video layer rides on top of the plain AXI4-Stream UVC rather than
// replacing any of it. A video frame is turned into ordinary
// axi_stream_seq_item beats, so every protocol check, backpressure
// model and scoreboard already in the UVC applies to video traffic
// unchanged -- a frame is just a particular way of filling TDATA and
// the two sideband bits.
//
// The sideband mapping is Xilinx's (UG934 / PG044), not an invention:
//
//   TUSER[0] = SOF (Start Of Frame)  asserted on the first pixel of the
//                                    first line of a frame, and nowhere else
//   TLAST    = EOL (End Of Line)     asserted on the last pixel of every line
//
// There is deliberately no end-of-frame signal: a frame ends when the
// next SOF arrives, or after the expected number of lines. That is how
// Xilinx video streams work, and recovering frame boundaries from SOF
// rather than from a line count is what lets a receiver resynchronise.

// A whole pixel's worth of component bits, packed. 128 bits covers every
// format the UVC claims to support -- the widest being 8 components of
// 16 bits -- with RGBA16 (64 bits) comfortably inside it. Raise this and
// the ASCII hex reader's token width grows with it; nothing else cares.
parameter int AXIS_VIDEO_MAX_PIXEL_BITS = 128;

// Most components a single pixel may carry. 4 (RGBA) is the most this
// UVC is asked for; the cap exists so a malformed format is caught with
// a message rather than by running out of pixel bits.
parameter int AXIS_VIDEO_MAX_COMPONENTS = 8;

// Widest single component. 16 bits is the largest RGBA component width
// in the supported set, and is what axi_stream_video_format masks to.
parameter int AXIS_VIDEO_MAX_COMPONENT_BITS = 16;

// One pixel, with its components already packed the way they sit on
// TDATA. See axi_stream_video_format for the exact bit layout -- the
// short version is that component 0 occupies the least significant bits,
// so for a single-pixel-per-clock link this value *is* the TDATA word.
typedef bit [AXIS_VIDEO_MAX_PIXEL_BITS-1:0] axi_stream_pixel_t;

// Which components a pixel carries, and in what order. The colorspace
// fixes nothing but the component count and their names: the bit layout
// comes from axi_stream_video_format's own fields, so RGBA at 8, 10, 12
// and 16 bits per component are all AXIS_VIDEO_RGBA.
typedef enum {
  AXIS_VIDEO_GRAY,    // 1 component: Y
  AXIS_VIDEO_RGB,     // 3 components: R, G, B
  AXIS_VIDEO_RGBA,    // 4 components: R, G, B, A
  AXIS_VIDEO_BGR,     // 3 components: B, G, R
  AXIS_VIDEO_YUV444,  // 3 components: Y, U, V
  AXIS_VIDEO_CUSTOM   // components_per_pixel says how many; names are generic
} axi_stream_video_colorspace_e;

// Image file formats the UVC can read and write.
//
// The PNM family is the usual Netpbm set, chosen because every image
// tool on earth writes it and it needs no library to parse. The ASCII
// hex format is this UVC's own: one whitespace-separated pixel word per
// pixel, one text line per image line, `//` and `#` comments and blank
// lines ignored. See axi_stream_image_file for both grammars.
typedef enum {
  AXIS_IMAGE_AUTO,        // sniff the magic number, else fall back to the extension
  AXIS_IMAGE_PGM_ASCII,   // Netpbm P2: grayscale, decimal samples
  AXIS_IMAGE_PGM_BINARY,  // Netpbm P5: grayscale, raw samples
  AXIS_IMAGE_PPM_ASCII,   // Netpbm P3: RGB, decimal samples
  AXIS_IMAGE_PPM_BINARY,  // Netpbm P6: RGB, raw samples
  AXIS_IMAGE_HEX          // this UVC's ASCII hex frame format
} axi_stream_image_format_e;

// Built-in frame contents, for tests that want a frame without a file.
typedef enum {
  AXIS_PATTERN_RAMP,     // horizontal gradient, each component ramping across the line
  AXIS_PATTERN_BARS,     // vertical colour bars, eight of them across the width
  AXIS_PATTERN_CHECKER,  // 8x8 checkerboard of full-scale and zero
  AXIS_PATTERN_INDEX,    // every pixel is its own raster index: unmistakable in a waveform
  AXIS_PATTERN_RANDOM    // uniformly random component values
} axi_stream_video_pattern_e;
