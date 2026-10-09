///////////////////////////////////////////////////////////////////
// Filename: axi_stream_video_frame.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : One video frame as a comparable UVM object: its geometry,
//           its pixels in raster order, the format that says how those
//           pixels are laid out, and the test patterns and file helpers
//           that fill it.
///////////////////////////////////////////////////////////////////
//
// Pixels are held already packed, one axi_stream_pixel_t each, in raster
// order -- left to right, top to bottom. That is the order they go onto
// the wire and the order an image file lists them in, so no pass over
// the frame ever has to reorder anything, and a frame that came off the
// wire compares directly against one read from a file.
//
// Component access goes through the frame's `video_format`:
//
//   frame.set_component(row, col, 1, 10'h2AA);   // green of that pixel
//   green = frame.component(row, col, 1);
//
// do_compare() is what makes this class worth having: it compares
// geometry and then every pixel masked to the format's real precision,
// and on a mismatch says which pixel and which component differ. A
// frame that crossed a 4-byte link and the same frame that crossed a
// 16-byte link are equal objects, because the blocking into beats is not
// part of the frame.

class axi_stream_video_frame extends uvm_object;

  // How the pixels below are laid out. Required by everything except the
  // plain geometry accessors; the file readers will create one for you
  // when it is left null and the file itself says enough to derive it.
  axi_stream_video_format video_format;

  int unsigned width  = 0;   // pixels per line
  int unsigned height = 0;   // lines per frame

  // Raster order: pixels[row*width + col].
  axi_stream_pixel_t pixels[];

  // Where this frame came from -- a filename, a pattern name, "monitor"
  // -- purely so a mismatch report can say which frame it is talking
  // about.
  string source_name = "";

  `uvm_object_utils(axi_stream_video_frame)

  extern function new(string name = "axi_stream_video_frame");

  // ---- Geometry ------------------------------------------------------
  // Resize to w x h. Existing pixels are kept where they still fit, so
  // growing a frame does not wipe it; new pixels are zero.
  extern function void set_size(int unsigned w, int unsigned h);
  extern function int unsigned num_pixels();
  extern function bit has_pixel(int unsigned row, int unsigned col);

  // ---- Pixel and component access ------------------------------------
  extern function axi_stream_pixel_t pixel(int unsigned row, int unsigned col);
  extern function void set_pixel(int unsigned row, int unsigned col, axi_stream_pixel_t value);
  extern function axi_stream_pixel_t component(int unsigned row, int unsigned col,
                                               int unsigned index);
  extern function void set_component(int unsigned row, int unsigned col,
                                     int unsigned index, axi_stream_pixel_t value);

  // A whole line, which is what the sequences and the frame collector
  // deal in.
  extern function void get_line(int unsigned row, ref axi_stream_pixel_t line_pixels[]);
  extern function void set_line(int unsigned row, axi_stream_pixel_t line_pixels[]);

  // ---- Contents ------------------------------------------------------
  // Fill with one of the built-in patterns. `seed` is used only by
  // AXIS_PATTERN_RANDOM, and seeding it explicitly keeps a failing run
  // reproducible.
  extern function void fill_pattern(axi_stream_video_pattern_e pattern,
                                    int unsigned seed = 0);
  extern function void fill_constant(axi_stream_pixel_t value);

  // ---- Files ---------------------------------------------------------
  // Convenience wrappers over axi_stream_image_file. Their bodies live
  // in axi_stream_image_file.sv, which is included after this file:
  // they call into the reader, which needs this class complete.
  extern function bit load(string filename,
                           axi_stream_image_format_e file_format = AXIS_IMAGE_AUTO);
  extern function bit save_hex(string filename, string title = "");
  extern function bit save_pnm(string filename, bit binary = 1'b1);

  // ---- Comparison ----------------------------------------------------
  // Index of the first pixel that differs, or -1 when the frames match.
  // Geometry differences report -2.
  extern function int first_difference(axi_stream_video_frame other);

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
  extern virtual function void do_print(uvm_printer printer);
  extern virtual function string convert2string();

  // One pixel written out the way a hex frame file writes it: the packed
  // word, zero-padded to the format's pixel width.
  extern function string pixel_string(int unsigned row, int unsigned col);

  // All components of one pixel, named -- for mismatch reports.
  extern function string component_string(int unsigned row, int unsigned col);

endclass : axi_stream_video_frame

function axi_stream_video_frame::new(string name = "axi_stream_video_frame");
  super.new(name);
endfunction : new

function void axi_stream_video_frame::set_size(int unsigned w, int unsigned h);
  axi_stream_pixel_t old_pixels[];
  int unsigned       old_width;
  int unsigned       old_height;

  if ((w == width) && (h == height)) begin
    if (pixels.size() != (w * h))
      pixels = new [w * h];
    return;
  end

  old_pixels = pixels;
  old_width  = width;
  old_height = height;

  width  = w;
  height = h;
  pixels = new [w * h];

  for (int r = 0; (r < old_height) && (r < h); r++)
    for (int c = 0; (c < old_width) && (c < w); c++)
      if (((r * old_width) + c) < old_pixels.size())
        pixels[(r * w) + c] = old_pixels[(r * old_width) + c];
endfunction : set_size

function int unsigned axi_stream_video_frame::num_pixels();
  return width * height;
endfunction : num_pixels

function bit axi_stream_video_frame::has_pixel(int unsigned row, int unsigned col);
  return (row < height) && (col < width) && (((row * width) + col) < pixels.size());
endfunction : has_pixel

function axi_stream_pixel_t axi_stream_video_frame::pixel(int unsigned row, int unsigned col);
  if (!has_pixel(row, col))
    return '0;
  return pixels[(row * width) + col];
endfunction : pixel

function void axi_stream_video_frame::set_pixel(int unsigned row, int unsigned col,
                                                axi_stream_pixel_t value);
  if (!has_pixel(row, col)) begin
    `uvm_error("FRAME_RANGE", $sformatf("set_pixel(%0d,%0d) is outside a %0dx%0d frame",
                                        row, col, width, height))
    return;
  end
  pixels[(row * width) + col] = value;
endfunction : set_pixel

function axi_stream_pixel_t axi_stream_video_frame::component(int unsigned row, int unsigned col,
                                                              int unsigned index);
  if (video_format == null) begin
    `uvm_error("FRAME_FMT", "component() needs the frame's video_format to be set")
    return '0;
  end
  return video_format.component(pixel(row, col), index);
endfunction : component

function void axi_stream_video_frame::set_component(int unsigned row, int unsigned col,
                                                    int unsigned index,
                                                    axi_stream_pixel_t value);
  axi_stream_pixel_t updated;
  if (video_format == null) begin
    `uvm_error("FRAME_FMT", "set_component() needs the frame's video_format to be set")
    return;
  end
  updated = pixel(row, col);
  video_format.set_component(updated, index, value);
  set_pixel(row, col, updated);
endfunction : set_component

function void axi_stream_video_frame::get_line(int unsigned row,
                                               ref axi_stream_pixel_t line_pixels[]);
  line_pixels = new [width];
  foreach (line_pixels[c])
    line_pixels[c] = pixel(row, c);
endfunction : get_line

function void axi_stream_video_frame::set_line(int unsigned row,
                                               axi_stream_pixel_t line_pixels[]);
  foreach (line_pixels[c])
    if (c < width)
      set_pixel(row, c, line_pixels[c]);
endfunction : set_line

function void axi_stream_video_frame::fill_constant(axi_stream_pixel_t value);
  foreach (pixels[i])
    pixels[i] = value;
endfunction : fill_constant

// The patterns exist so a test can have a frame without shipping an
// image file with it. Each one is chosen to make a particular kind of
// bug visible at a glance in a waveform or a dumped file:
//
//   RAMP     a wrong component order shows as the wrong axis ramping
//   BARS     a lane swap shows as a recoloured bar
//   CHECKER  a half-beat offset shows as a sheared edge
//   INDEX    a dropped or duplicated beat shows as a gap in the numbers
//   RANDOM   nothing is special-cased, so nothing can accidentally match
function void axi_stream_video_frame::fill_pattern(axi_stream_video_pattern_e pattern,
                                                   int unsigned seed = 0);
  axi_stream_pixel_t max_value;
  int unsigned       components;
  int unsigned       bits;

  if (video_format == null)
    `uvm_fatal("FRAME_FMT", "fill_pattern() needs the frame's video_format to be set")

  max_value  = video_format.max_sample();
  components = video_format.components_per_pixel;
  bits       = video_format.bits_per_component;

  // Assigned rather than void-cast: XSIM rejects $urandom in a
  // void'() context, reading it as a task call.
  if ((pattern == AXIS_PATTERN_RANDOM) && (seed != 0)) begin
    int unsigned reseeded;
    reseeded = $urandom(seed);
  end

  source_name = pattern.name();

  for (int r = 0; r < height; r++) begin
    for (int c = 0; c < width; c++) begin
      axi_stream_pixel_t value = '0;
      case (pattern)
        AXIS_PATTERN_RAMP : begin
          // Component 0 ramps across the line, component 1 down the
          // frame, component 2 sits mid scale, anything further is full.
          for (int k = 0; k < components; k++) begin
            axi_stream_pixel_t sample;
            case (k)
              0 : sample = (width  > 1) ? ((max_value * c) / (width  - 1)) : max_value;
              1 : sample = (height > 1) ? ((max_value * r) / (height - 1)) : max_value;
              2 : sample = max_value / 2;
              default : sample = max_value;
            endcase
            video_format.set_component(value, k, sample);
          end
        end
        AXIS_PATTERN_BARS : begin
          // Eight bars across the width, in the usual descending-
          // luminance order. Components beyond the third are full scale,
          // so an alpha channel stays opaque.
          int unsigned bar = (width == 0) ? 0 : ((c * 8) / width);
          bit [2:0] rgb;
          case (bar)
            0 : rgb = 3'b111;  // white
            1 : rgb = 3'b110;  // yellow
            2 : rgb = 3'b011;  // cyan
            3 : rgb = 3'b010;  // green
            4 : rgb = 3'b101;  // magenta
            5 : rgb = 3'b100;  // red
            6 : rgb = 3'b001;  // blue
            default : rgb = 3'b000;  // black
          endcase
          for (int k = 0; k < components; k++) begin
            if (k < 3) video_format.set_component(value, k, rgb[2-k] ? max_value : '0);
            else       video_format.set_component(value, k, max_value);
          end
        end
        AXIS_PATTERN_CHECKER : begin
          bit on = (((r / 8) + (c / 8)) % 2) == 0;
          for (int k = 0; k < components; k++)
            video_format.set_component(value, k, on ? max_value : '0);
        end
        AXIS_PATTERN_INDEX : begin
          // The raster index, spread across the components so even a
          // 1-component 8-bit frame counts somewhere. Reading the
          // components back and reassembling them gives the index.
          int unsigned index = (r * width) + c;
          for (int k = 0; k < components; k++)
            video_format.set_component(value, k,
                                       (axi_stream_pixel_t'(index) >> (k * bits)) & max_value);
        end
        default : begin  // AXIS_PATTERN_RANDOM
          for (int k = 0; k < components; k++)
            video_format.set_component(value, k, $urandom_range(max_value, 0));
        end
      endcase
      set_pixel(r, c, value);
    end
  end
endfunction : fill_pattern

function int axi_stream_video_frame::first_difference(axi_stream_video_frame other);
  axi_stream_pixel_t mask;

  if (other == null)
    return -2;
  if ((width != other.width) || (height != other.height))
    return -2;

  // Compare at the format's real precision: bits above it are padding
  // this UVC drives to zero but a DUT is free to leave undefined.
  mask = (video_format == null) ? '1 : video_format.pixel_mask();

  foreach (pixels[i]) begin
    if (i >= other.pixels.size())
      return i;
    if ((pixels[i] & mask) !== (other.pixels[i] & mask))
      return i;
  end
  return -1;
endfunction : first_difference

function void axi_stream_video_frame::do_copy(uvm_object rhs);
  axi_stream_video_frame rhs_;
  if (rhs == null)
    `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COPY", "cast of rhs to axi_stream_video_frame failed")
  super.do_copy(rhs);
  // The format is shared, not cloned: it describes a link's layout, and
  // two frames of the same stream should go on describing the same one.
  video_format = rhs_.video_format;
  width        = rhs_.width;
  height       = rhs_.height;
  source_name  = rhs_.source_name;
  pixels       = new [rhs_.pixels.size()] (rhs_.pixels);
endfunction : do_copy

function bit axi_stream_video_frame::do_compare(uvm_object rhs, uvm_comparer comparer);
  axi_stream_video_frame rhs_;
  int                    diff;

  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COMPARE", "cast of rhs to axi_stream_video_frame failed")
  if (!super.do_compare(rhs, comparer))
    return 1'b0;

  if ((width != rhs_.width) || (height != rhs_.height)) begin
    comparer.print_msg($sformatf("frame geometry differs: %0dx%0d vs %0dx%0d",
                                 width, height, rhs_.width, rhs_.height));
    return 1'b0;
  end

  diff = first_difference(rhs_);
  if (diff < 0)
    return (diff == -1);

  begin
    int unsigned row = diff / ((width == 0) ? 1 : width);
    int unsigned col = diff % ((width == 0) ? 1 : width);
    comparer.print_msg($sformatf("pixel (row %0d, col %0d) differs: %s vs %s",
                                 row, col,
                                 component_string(row, col),
                                 rhs_.component_string(row, col)));
  end
  return 1'b0;
endfunction : do_compare

// SystemVerilog has no run-time field width in a format string, so the
// pixel is printed at the full width of axi_stream_pixel_t and the
// leading digits the format does not use are sliced off.
function string axi_stream_video_frame::pixel_string(int unsigned row, int unsigned col);
  localparam int FULL_DIGITS = AXIS_VIDEO_MAX_PIXEL_BITS / 4;
  string       full;
  int unsigned digits;

  digits = (video_format == null) ? 8 : ((video_format.bits_per_pixel() + 3) / 4);
  if (digits < 1)           digits = 1;
  if (digits > FULL_DIGITS) digits = FULL_DIGITS;

  full = $sformatf("%h", pixel(row, col));
  return {"0x", full.substr(FULL_DIGITS - digits, FULL_DIGITS - 1)};
endfunction : pixel_string

function string axi_stream_video_frame::component_string(int unsigned row, int unsigned col);
  string s;
  if (video_format == null)
    return pixel_string(row, col);
  s = "";
  for (int k = 0; k < video_format.components_per_pixel; k++)
    s = {s, (k == 0) ? "" : " ",
         $sformatf("%s=%0h", video_format.component_name(k), component(row, col, k))};
  return {pixel_string(row, col), " (", s, ")"};
endfunction : component_string

function void axi_stream_video_frame::do_print(uvm_printer printer);
  super.do_print(printer);
  printer.print_field_int("width",  width,  32, UVM_DEC);
  printer.print_field_int("height", height, 32, UVM_DEC);
  if (video_format != null)
    printer.print_string("video_format", video_format.convert2string());
  if (source_name != "")
    printer.print_string("source_name", source_name);
  // The first line only: a frame has too many pixels to print, and the
  // first line is what tells you whether the layout is right at all.
  for (int c = 0; (c < width) && (c < 8); c++)
    printer.print_string($sformatf("pixel[0][%0d]", c), component_string(0, c));
endfunction : do_print

function string axi_stream_video_frame::convert2string();
  string s;
  s = $sformatf("frame %0dx%0d", width, height);
  if (source_name != "")  s = {s, $sformatf(" \"%s\"", source_name)};
  if (video_format != null) s = {s, $sformatf(" [%s]", video_format.convert2string())};
  for (int c = 0; (c < width) && (c < 4); c++)
    s = {s, " ", pixel_string(0, c)};
  if (width > 4)
    s = {s, $sformatf(" ... (+%0d more on line 0)", width - 4)};
  return s;
endfunction : convert2string
