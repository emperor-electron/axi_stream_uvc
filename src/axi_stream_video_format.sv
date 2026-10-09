///////////////////////////////////////////////////////////////////
// Filename: axi_stream_video_format.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Describes how pixels sit on an AXI4-Stream link: how many
//           components a pixel has, how wide each one is, how many
//           pixels share a beat, and which sideband bits carry SOF and
//           EOL. Does all the bit packing and unpacking.
///////////////////////////////////////////////////////////////////
//
// This object is the single answer to "where is the green component of
// the second pixel?". Everything else in the video layer -- the frame,
// the file readers, the sequences, the frame collector -- asks this
// class rather than doing arithmetic of its own, so there is exactly one
// place to read if the layout is ever in doubt and exactly one place to
// change if a project's layout differs.
//
// Like the rest of the UVC it is unparameterized: the widths are plain
// integers, so one format object describes RGBA8888 whether it is being
// driven onto a 4-byte link at one pixel per clock or a 16-byte link at
// four.
//
// ---- The bit layout -----------------------------------------------
//
// A pixel's components are packed contiguously, component 0 in the
// *least* significant bits:
//
//   RGBA8888, one pixel:
//     bits 31:24  A        <- component 3
//     bits 23:16  B        <- component 2
//     bits 15:8   G        <- component 1
//     bits  7:0   R        <- component 0
//
// Pixels are then packed contiguously into the beat, pixel 0 in the
// least significant bits:
//
//   RGBA8888 at two pixels per clock, on an 8-byte link:
//     TDATA[63:32] pixel 1 (A1 B1 G1 R1)
//     TDATA[31:0]  pixel 0 (A0 B0 G0 R0)
//
// Component 0 goes in the LSBs because that is where Xilinx video IP
// puts it, and it buys a property worth having: at one pixel per clock
// the pixel word *is* the TDATA word. A pixel value printed by this UVC,
// written into an ASCII hex frame file, and read off a waveform are the
// same number, so a frame file can be diffed against a waveform by eye.
//
// Set `component_msb_first` if you would rather component 0 sat in the
// MSBs -- which is what makes an RGBA8888 pixel read as 0xRRGGBBAA, the
// order a graphics programmer expects. It changes the packing only; the
// component *indices* and their names never move.
//
// ---- Component padding --------------------------------------------
//
// By default components are dense: 10-bit RGBA is 40 bits per pixel, not
// 64. Real Xilinx video IP does it both ways -- a VPSS at 10 bits per
// component carries 30 contiguous bits for RGB, while a frame buffer
// writing to memory pads each component out to a byte boundary -- so
// `byte_align_components` picks between them. With it set, a 10-bit
// component occupies 16 bits and 10-bit RGBA becomes 64 bits per pixel.
//
// ---- Beat padding -------------------------------------------------
//
// A beat's pixel group need not fill TDATA. 10-bit RGBA at two pixels
// per clock is 80 bits, which on a 12-byte link leaves the top 16 bits
// over. Those bits are driven to zero, and the byte lanes that lie
// wholly in the padding are marked as null bytes when the link carries
// TKEEP -- so a receiver reading `packet.payload()` gets exactly the
// pixel bytes and nothing else. On a link without TKEEP the padding is
// indistinguishable from data on the wire, and the frame collector has
// to be told the frame width instead; see axi_stream_video_frame_collector.

class axi_stream_video_format extends uvm_object;

  // ---- What a pixel is ----------------------------------------------
  axi_stream_video_colorspace_e colorspace = AXIS_VIDEO_RGBA;

  // Bits of real precision in each component: 8, 10, 12 and 16 are the
  // interesting ones, but anything from 1 to AXIS_VIDEO_MAX_COMPONENT_BITS
  // works.
  int unsigned bits_per_component = 8;

  // Components in a pixel. Normally implied by the colorspace and set
  // for you by the named constructors below; it is only independent for
  // AXIS_VIDEO_CUSTOM.
  int unsigned components_per_pixel = 4;

  // Pixels carried in one beat. This is the "multiple pixels per clock"
  // knob: the link must be at least min_data_bytes() wide to hold them.
  int unsigned pixels_per_clock = 1;

  // Pad each component up to a whole number of bytes (see the header).
  bit byte_align_components = 1'b0;

  // Put component 0 in the most significant bits of the pixel instead of
  // the least (see the header).
  bit component_msb_first = 1'b0;

  // ---- How the frame is delimited on the wire -----------------------
  // The Xilinx video mapping, and the default: TUSER[0] is SOF and TLAST
  // is EOL.
  //
  // Clear `drive_sof` for a link with no TUSER, or for a DUT that does
  // not want framing: the stream then carries lines delimited by TLAST
  // with no frame boundary at all, and a receiver has to be told the
  // frame height.
  bit          drive_sof     = 1'b1;
  int unsigned sof_tuser_bit = 0;

  // TLAST marks the end of a line. Clearing this gives a stream with no
  // line structure either, which is legal AXI4-Stream but is not the
  // Xilinx video protocol -- the frame collector cannot recover lines
  // from it and says so.
  bit mark_eol_with_tlast = 1'b1;

  `uvm_object_utils(axi_stream_video_format)

  extern function new(string name = "axi_stream_video_format");

  // ---- Named constructors. These are the usual way to get a format:
  //
  //   video_format = axi_stream_video_format::rgba(10);  // RGBA, 10 bits each
  //
  extern static function axi_stream_video_format rgba(int unsigned bits = 8,
                                                      int unsigned pixels_per_clock = 1);
  extern static function axi_stream_video_format rgba8888(int unsigned pixels_per_clock = 1);
  extern static function axi_stream_video_format rgb(int unsigned bits = 8,
                                                     int unsigned pixels_per_clock = 1);
  extern static function axi_stream_video_format gray(int unsigned bits = 8,
                                                      int unsigned pixels_per_clock = 1);
  extern static function axi_stream_video_format custom(int unsigned components,
                                                        int unsigned bits = 8,
                                                        int unsigned pixels_per_clock = 1);

  // ---- Geometry ------------------------------------------------------
  // Bits a component occupies, padding included.
  extern function int unsigned component_stride_bits();
  extern function int unsigned bits_per_pixel();
  extern function int unsigned bits_per_beat();

  // Narrowest link this format fits on, in TDATA bytes. A link exactly
  // this wide carries the pixel group with no padding.
  extern function int unsigned min_data_bytes();

  // Bytes of a beat that carry pixel data; the rest of TDATA is padding.
  // Equal to min_data_bytes(), named for how it is used.
  extern function int unsigned pixel_bytes_per_beat();

  // Bytes needed to hold `count` pixels, which is what a short final
  // beat of a line gets.
  extern function int unsigned bytes_for_pixels(int unsigned count);

  // Largest value a component can hold, and the mask of a whole pixel.
  extern function axi_stream_pixel_t max_sample();
  extern function axi_stream_pixel_t pixel_mask();

  // ---- Components ----------------------------------------------------
  extern function string component_name(int unsigned index);
  extern function int unsigned component_offset_bits(int unsigned index);
  extern function axi_stream_pixel_t component(axi_stream_pixel_t pixel, int unsigned index);
  extern function void set_component(ref axi_stream_pixel_t pixel,
                                     input int unsigned index,
                                     input axi_stream_pixel_t value);
  extern function axi_stream_pixel_t make_pixel(axi_stream_pixel_t components[]);
  extern function void split_pixel(axi_stream_pixel_t pixel, ref axi_stream_pixel_t components[]);

  // Rescale a sample from `from_bits` of precision to this format's,
  // which is how an 8-bit PGM loads into a 12-bit frame without going
  // dark. Scales by replication of the high bits, the usual video
  // widening, so full scale stays full scale.
  extern function axi_stream_pixel_t rescale_sample(axi_stream_pixel_t value,
                                                    int unsigned from_bits);

  // ---- Packing -------------------------------------------------------
  // Pack `count` pixels starting at pixels[first] into a fresh byte
  // array, sized to exactly those pixels. tdata[0] is the array's
  // element 0, so the result drops straight into
  // axi_stream_seq_item::set_bytes().
  extern function void pack(axi_stream_pixel_t pixels[],
                            int unsigned first,
                            int unsigned count,
                            ref byte unsigned bytes[]);

  // Recover `count` pixels from a line's worth of bytes.
  extern function void unpack(ref byte unsigned bytes[$],
                              input int unsigned count,
                              ref axi_stream_pixel_t pixels[]);

  // ---- Validation ----------------------------------------------------
  // True when this format is self-consistent. On failure `reason` says
  // what is wrong, in terms a user can act on.
  extern function bit is_sane(output string reason);

  // True when a link of `data_bytes` can carry this format. On failure
  // `reason` names the width it would need.
  extern function bit fits_on_link(int unsigned data_bytes, output string reason);

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function string convert2string();

  // Bit-level moves between a pixel value and a byte array. Done a
  // component at a time, so the value never exceeds
  // AXIS_VIDEO_MAX_COMPONENT_BITS and the common byte-aligned case
  // reduces to byte copies rather than a loop over bits.
  extern protected function void insert_bits(ref byte unsigned bytes[],
                                             input int unsigned bit_offset,
                                             input int unsigned num_bits,
                                             input axi_stream_pixel_t value);
  extern protected function axi_stream_pixel_t extract_bits(ref byte unsigned bytes[$],
                                                            input int unsigned bit_offset,
                                                            input int unsigned num_bits);

endclass : axi_stream_video_format

function axi_stream_video_format::new(string name = "axi_stream_video_format");
  super.new(name);
endfunction : new

function axi_stream_video_format axi_stream_video_format::rgba(int unsigned bits = 8,
                                                               int unsigned pixels_per_clock = 1);
  axi_stream_video_format f;
  f = axi_stream_video_format::type_id::create("rgba_format");
  f.colorspace           = AXIS_VIDEO_RGBA;
  f.components_per_pixel = 4;
  f.bits_per_component   = bits;
  f.pixels_per_clock     = pixels_per_clock;
  return f;
endfunction : rgba

function axi_stream_video_format axi_stream_video_format::rgba8888(int unsigned pixels_per_clock = 1);
  return rgba(8, pixels_per_clock);
endfunction : rgba8888

function axi_stream_video_format axi_stream_video_format::rgb(int unsigned bits = 8,
                                                              int unsigned pixels_per_clock = 1);
  axi_stream_video_format f;
  f = axi_stream_video_format::type_id::create("rgb_format");
  f.colorspace           = AXIS_VIDEO_RGB;
  f.components_per_pixel = 3;
  f.bits_per_component   = bits;
  f.pixels_per_clock     = pixels_per_clock;
  return f;
endfunction : rgb

function axi_stream_video_format axi_stream_video_format::gray(int unsigned bits = 8,
                                                               int unsigned pixels_per_clock = 1);
  axi_stream_video_format f;
  f = axi_stream_video_format::type_id::create("gray_format");
  f.colorspace           = AXIS_VIDEO_GRAY;
  f.components_per_pixel = 1;
  f.bits_per_component   = bits;
  f.pixels_per_clock     = pixels_per_clock;
  return f;
endfunction : gray

function axi_stream_video_format axi_stream_video_format::custom(int unsigned components,
                                                                 int unsigned bits = 8,
                                                                 int unsigned pixels_per_clock = 1);
  axi_stream_video_format f;
  f = axi_stream_video_format::type_id::create("custom_format");
  f.colorspace           = AXIS_VIDEO_CUSTOM;
  f.components_per_pixel = components;
  f.bits_per_component   = bits;
  f.pixels_per_clock     = pixels_per_clock;
  return f;
endfunction : custom

function int unsigned axi_stream_video_format::component_stride_bits();
  return byte_align_components ? (((bits_per_component + 7) / 8) * 8) : bits_per_component;
endfunction : component_stride_bits

function int unsigned axi_stream_video_format::bits_per_pixel();
  return components_per_pixel * component_stride_bits();
endfunction : bits_per_pixel

function int unsigned axi_stream_video_format::bits_per_beat();
  return pixels_per_clock * bits_per_pixel();
endfunction : bits_per_beat

function int unsigned axi_stream_video_format::min_data_bytes();
  return (bits_per_beat() + 7) / 8;
endfunction : min_data_bytes

function int unsigned axi_stream_video_format::pixel_bytes_per_beat();
  return min_data_bytes();
endfunction : pixel_bytes_per_beat

function int unsigned axi_stream_video_format::bytes_for_pixels(int unsigned count);
  return ((count * bits_per_pixel()) + 7) / 8;
endfunction : bytes_for_pixels

function axi_stream_pixel_t axi_stream_video_format::max_sample();
  return (axi_stream_pixel_t'(1) << bits_per_component) - 1;
endfunction : max_sample

function axi_stream_pixel_t axi_stream_video_format::pixel_mask();
  if (bits_per_pixel() >= AXIS_VIDEO_MAX_PIXEL_BITS)
    return '1;
  return (axi_stream_pixel_t'(1) << bits_per_pixel()) - 1;
endfunction : pixel_mask

function string axi_stream_video_format::component_name(int unsigned index);
  case (colorspace)
    AXIS_VIDEO_GRAY   : return "Y";
    AXIS_VIDEO_RGB    : case (index) 0: return "R"; 1: return "G"; 2: return "B"; endcase
    AXIS_VIDEO_BGR    : case (index) 0: return "B"; 1: return "G"; 2: return "R"; endcase
    AXIS_VIDEO_RGBA   : case (index) 0: return "R"; 1: return "G"; 2: return "B"; 3: return "A"; endcase
    AXIS_VIDEO_YUV444 : case (index) 0: return "Y"; 1: return "U"; 2: return "V"; endcase
    default           : ;
  endcase
  return $sformatf("C%0d", index);
endfunction : component_name

function int unsigned axi_stream_video_format::component_offset_bits(int unsigned index);
  int unsigned stride = component_stride_bits();
  if (component_msb_first)
    return (components_per_pixel - 1 - index) * stride;
  return index * stride;
endfunction : component_offset_bits

function axi_stream_pixel_t axi_stream_video_format::component(axi_stream_pixel_t pixel,
                                                               int unsigned index);
  if (index >= components_per_pixel)
    return '0;
  return (pixel >> component_offset_bits(index)) & max_sample();
endfunction : component

function void axi_stream_video_format::set_component(ref axi_stream_pixel_t pixel,
                                                     input int unsigned index,
                                                     input axi_stream_pixel_t value);
  int unsigned shift;
  if (index >= components_per_pixel)
    return;
  shift = component_offset_bits(index);
  pixel = (pixel & ~(max_sample() << shift)) | ((value & max_sample()) << shift);
endfunction : set_component

function axi_stream_pixel_t axi_stream_video_format::make_pixel(axi_stream_pixel_t components[]);
  axi_stream_pixel_t pixel = '0;
  foreach (components[i])
    set_component(pixel, i, components[i]);
  return pixel;
endfunction : make_pixel

function void axi_stream_video_format::split_pixel(axi_stream_pixel_t pixel,
                                                   ref axi_stream_pixel_t components[]);
  components = new [components_per_pixel];
  foreach (components[i])
    components[i] = component(pixel, i);
endfunction : split_pixel

// Replicating the high bits rather than shifting in zeros is what keeps
// white white: 8-bit 0xFF widens to 12-bit 0xFFF, not 0xFF0.
function axi_stream_pixel_t axi_stream_video_format::rescale_sample(axi_stream_pixel_t value,
                                                                    int unsigned from_bits);
  axi_stream_pixel_t result;
  int unsigned       filled;

  if ((from_bits == 0) || (from_bits == bits_per_component))
    return value & max_sample();

  if (from_bits > bits_per_component)
    return (value >> (from_bits - bits_per_component)) & max_sample();

  // Widening: lay the source value down from the top and fill the rest
  // by repeating it, so an all-ones input stays all ones.
  result = '0;
  filled = 0;
  while (filled < bits_per_component) begin
    int unsigned shift = bits_per_component - filled;
    if (shift >= from_bits) result |= value << (shift - from_bits);
    else                    result |= value >> (from_bits - shift);
    filled += from_bits;
  end
  return result & max_sample();
endfunction : rescale_sample

function void axi_stream_video_format::insert_bits(ref byte unsigned bytes[],
                                                   input int unsigned bit_offset,
                                                   input int unsigned num_bits,
                                                   input axi_stream_pixel_t value);
  // Byte-aligned is the overwhelmingly common case -- every 8- and
  // 16-bit format, and anything with byte_align_components set -- so it
  // gets a loop over bytes rather than over bits.
  if (((bit_offset % 8) == 0) && ((num_bits % 8) == 0)) begin
    for (int b = 0; b < (num_bits / 8); b++) begin
      int unsigned index = (bit_offset / 8) + b;
      if (index < bytes.size())
        bytes[index] = value[b*8 +: 8];
    end
  end
  else begin
    for (int b = 0; b < num_bits; b++) begin
      int unsigned position = bit_offset + b;
      int unsigned index    = position / 8;
      if (index < bytes.size())
        bytes[index][position % 8] = value[b];
    end
  end
endfunction : insert_bits

function axi_stream_pixel_t axi_stream_video_format::extract_bits(ref byte unsigned bytes[$],
                                                                  input int unsigned bit_offset,
                                                                  input int unsigned num_bits);
  axi_stream_pixel_t value = '0;
  if (((bit_offset % 8) == 0) && ((num_bits % 8) == 0)) begin
    for (int b = 0; b < (num_bits / 8); b++) begin
      int unsigned index = (bit_offset / 8) + b;
      if (index < bytes.size())
        value[b*8 +: 8] = bytes[index];
    end
  end
  else begin
    for (int b = 0; b < num_bits; b++) begin
      int unsigned position = bit_offset + b;
      int unsigned index    = position / 8;
      if (index < bytes.size())
        value[b] = bytes[index][position % 8];
    end
  end
  return value;
endfunction : extract_bits

function void axi_stream_video_format::pack(axi_stream_pixel_t pixels[],
                                            int unsigned first,
                                            int unsigned count,
                                            ref byte unsigned bytes[]);
  int unsigned stride = component_stride_bits();

  bytes = new [bytes_for_pixels(count)];
  foreach (bytes[i])
    bytes[i] = 8'h00;

  for (int p = 0; p < count; p++) begin
    axi_stream_pixel_t pixel = ((first + p) < pixels.size()) ? pixels[first + p] : '0;
    int unsigned pixel_offset = p * bits_per_pixel();
    for (int c = 0; c < components_per_pixel; c++)
      insert_bits(bytes,
                  pixel_offset + component_offset_bits(c),
                  stride,
                  component(pixel, c));
  end
endfunction : pack

function void axi_stream_video_format::unpack(ref byte unsigned bytes[$],
                                              input int unsigned count,
                                              ref axi_stream_pixel_t pixels[]);
  int unsigned stride = component_stride_bits();

  pixels = new [count];
  for (int p = 0; p < count; p++) begin
    axi_stream_pixel_t pixel = '0;
    int unsigned pixel_offset = p * bits_per_pixel();
    for (int c = 0; c < components_per_pixel; c++)
      set_component(pixel, c,
                    extract_bits(bytes, pixel_offset + component_offset_bits(c), stride));
    pixels[p] = pixel;
  end
endfunction : unpack

function bit axi_stream_video_format::is_sane(output string reason);
  int unsigned expected;

  reason = "";

  if ((bits_per_component == 0) || (bits_per_component > AXIS_VIDEO_MAX_COMPONENT_BITS)) begin
    reason = $sformatf("bits_per_component=%0d must be 1..%0d",
                       bits_per_component, AXIS_VIDEO_MAX_COMPONENT_BITS);
    return 1'b0;
  end
  if ((components_per_pixel == 0) || (components_per_pixel > AXIS_VIDEO_MAX_COMPONENTS)) begin
    reason = $sformatf("components_per_pixel=%0d must be 1..%0d",
                       components_per_pixel, AXIS_VIDEO_MAX_COMPONENTS);
    return 1'b0;
  end
  if (pixels_per_clock == 0) begin
    reason = "pixels_per_clock must be at least 1";
    return 1'b0;
  end
  if (bits_per_pixel() > AXIS_VIDEO_MAX_PIXEL_BITS) begin
    reason = $sformatf(
        {"a pixel needs %0d bits (%0d components x %0d) but AXIS_VIDEO_MAX_PIXEL_BITS is %0d; ",
         "raise it in axi_stream_video_types.sv"},
        bits_per_pixel(), components_per_pixel, component_stride_bits(),
        AXIS_VIDEO_MAX_PIXEL_BITS);
    return 1'b0;
  end

  // A colorspace that names its components has to have that many.
  case (colorspace)
    AXIS_VIDEO_GRAY                                   : expected = 1;
    AXIS_VIDEO_RGB, AXIS_VIDEO_BGR, AXIS_VIDEO_YUV444 : expected = 3;
    AXIS_VIDEO_RGBA                                   : expected = 4;
    default                                           : expected = components_per_pixel;
  endcase
  if (components_per_pixel != expected) begin
    reason = $sformatf("%s has %0d components, but components_per_pixel=%0d",
                       colorspace.name(), expected, components_per_pixel);
    return 1'b0;
  end

  if (drive_sof && (sof_tuser_bit >= AXIS_MAX_USER_WIDTH)) begin
    reason = $sformatf("sof_tuser_bit=%0d is outside AXIS_MAX_USER_WIDTH=%0d",
                       sof_tuser_bit, AXIS_MAX_USER_WIDTH);
    return 1'b0;
  end
  return 1'b1;
endfunction : is_sane

function bit axi_stream_video_format::fits_on_link(int unsigned data_bytes, output string reason);
  reason = "";
  if (data_bytes >= min_data_bytes())
    return 1'b1;
  reason = $sformatf(
      {"%s needs a TDATA width of at least %0d bytes (%0d pixels/clock x %0d bits/pixel ",
       "= %0d bits) but the link is %0d bytes wide; widen the link or lower pixels_per_clock"},
      convert2string(), min_data_bytes(), pixels_per_clock, bits_per_pixel(),
      bits_per_beat(), data_bytes);
  return 1'b0;
endfunction : fits_on_link

function void axi_stream_video_format::do_copy(uvm_object rhs);
  axi_stream_video_format rhs_;
  if (rhs == null)
    `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COPY", "cast of rhs to axi_stream_video_format failed")
  super.do_copy(rhs);
  colorspace            = rhs_.colorspace;
  bits_per_component    = rhs_.bits_per_component;
  components_per_pixel  = rhs_.components_per_pixel;
  pixels_per_clock      = rhs_.pixels_per_clock;
  byte_align_components = rhs_.byte_align_components;
  component_msb_first   = rhs_.component_msb_first;
  drive_sof             = rhs_.drive_sof;
  sof_tuser_bit         = rhs_.sof_tuser_bit;
  mark_eol_with_tlast   = rhs_.mark_eol_with_tlast;
endfunction : do_copy

function string axi_stream_video_format::convert2string();
  string s;
  s = $sformatf("%s %0dbpc x%0d ppc", colorspace.name(), bits_per_component, pixels_per_clock);
  s = {s, $sformatf(" (%0db/pixel, %0db/beat, >=%0dB link)",
                    bits_per_pixel(), bits_per_beat(), min_data_bytes())};
  if (byte_align_components) s = {s, " byte-aligned"};
  if (component_msb_first)   s = {s, " msb-first"};
  if (drive_sof)             s = {s, $sformatf(" SOF=TUSER[%0d]", sof_tuser_bit)};
  if (mark_eol_with_tlast)   s = {s, " EOL=TLAST"};
  return s;
endfunction : convert2string
