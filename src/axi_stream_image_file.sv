///////////////////////////////////////////////////////////////////
// Filename: axi_stream_image_file.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Reads and writes image files into and out of an
//           axi_stream_video_frame: the Netpbm PGM/PPM family, and this
//           UVC's own ASCII hex frame format.
///////////////////////////////////////////////////////////////////
//
// All of this is pure SystemVerilog file I/O -- $fgetc, $fgets, $fread,
// $fdisplay -- so it needs no DPI, no PLI and no helper script, and
// works in any simulator the rest of the UVC works in.
//
// Everything here is static. There is no state to keep: a reader takes a
// filename and a frame and fills the frame in.
//
//   axi_stream_video_frame frame = axi_stream_video_frame::type_id::create("frame");
//   frame.video_format = axi_stream_video_format::rgba8888();
//   if (!frame.load("frames/logo.hex"))
//     `uvm_fatal("IMG", "could not read the frame")
//
//
// ====================================================================
// The ASCII hex frame format
// ====================================================================
//
// A plain text file that shows a frame pixel by pixel in raster order,
// so it can be read, diffed and edited by hand:
//
//   /////////////////////////////
//   // Name: some_file.hex
//   // Dimensions: 4x4
//   // Date Generated: 10/8/26
//   /////////////////////////////
//
//   0x00000001 0x00000002 0x00000003 0x00000004
//   0x00000001 0x00000002 0x00000003 0x00000004
//   0x00000001 0x00000002 0x00000003 0x00000004
//   0x00000001 0x00000002 0x00000003 0x00000004
//
// The rules, in full:
//
//   * `//` or `#` begins a comment, which runs to the end of the line.
//     A line that is blank once its comment is removed is ignored, so
//     banner lines and blank separators cost nothing.
//   * Every other line is one line of the image. The end of an image
//     line is the end of a text line -- that is the whole point of the
//     format, and is why no line-length field is needed.
//   * Within a line, pixels are whitespace-separated tokens in raster
//     order. A token is hexadecimal, with an optional `0x` or `0X`
//     prefix; `_` may be used freely as a digit separator.
//   * The frame's width is the token count of the first image line, and
//     every later line must have the same count. The height is the
//     number of image lines.
//   * A `Dimensions: <width>x<height>` comment, if present, is checked
//     against what was actually parsed. A file that contradicts itself
//     is an error rather than a guess.
//
// Each token is one pixel's *packed* value, laid out exactly as
// axi_stream_video_format describes -- which for a one-pixel-per-clock
// link means the token is the TDATA word, so a frame file and a waveform
// show the same numbers. Because the token says nothing about the
// layout, reading a hex file needs the frame's video_format to be set
// first; there is nothing in the file to derive it from.
//
//
// ====================================================================
// PGM and PPM
// ====================================================================
//
// The Netpbm formats, all four of the single-image variants:
//
//   P2  PGM ASCII    1 component   P5  PGM binary    1 component
//   P3  PPM ASCII    3 components  P6  PPM binary    3 components
//
// The header is `magic`, width, height, maxval as whitespace-separated
// tokens with `#` comments allowed between them; binary sample data
// follows one whitespace character after maxval. Samples are one byte
// when maxval < 256 and two bytes, most significant first, above that.
//
// maxval gives the file's real precision -- 255 is 8 bits, 1023 is 10,
// 4095 is 12, 65535 is 16 -- and samples are rescaled from that into the
// frame format's precision by bit replication, so an 8-bit PPM loaded
// into a 12-bit RGBA frame stays full scale rather than going dark.
//
// A PNM file says how many components it has, so unlike the hex format
// it can supply a video_format: load a PNM into a frame whose
// video_format is null and a matching gray or RGB format is created for
// it, at one pixel per clock.
//
// Where the file's component count and the frame's differ, they are
// mapped like this:
//
//   file     frame                 result
//   -------- --------------------- --------------------------------------
//   1 (gray) 3 or more (RGB/RGBA)  gray replicated into components 0..2
//   3 (RGB)  4 (RGBA)              RGB into 0..2
//   1 or 3   more than 3           components past the third set to full
//                                  scale, so an alpha channel is opaque
//   3 (RGB)  1 (gray)              component 0 only; the rest discarded

class axi_stream_image_file extends uvm_object;

  `uvm_object_utils(axi_stream_image_file)

  extern function new(string name = "axi_stream_image_file");

  // ---- Reading -------------------------------------------------------
  // Fill `frame` from `filename`. Returns 0 and reports a UVM_ERROR on
  // any failure, having left the frame alone.
  extern static function bit read(string filename,
                                  axi_stream_video_frame frame,
                                  axi_stream_image_format_e file_format = AXIS_IMAGE_AUTO);

  // Which format a file is, from its magic number. Anything that does
  // not start with a Netpbm magic is taken to be the ASCII hex format.
  extern static function axi_stream_image_format_e detect(string filename);

  extern static function bit read_pnm(string filename,
                                      axi_stream_video_frame frame,
                                      axi_stream_image_format_e file_format);
  extern static function bit read_hex(string filename, axi_stream_video_frame frame);

  // ---- Writing -------------------------------------------------------
  // Write the frame out in the ASCII hex format, with a header banner
  // this class can read back. `title` overrides the Name comment.
  extern static function bit write_hex(string filename,
                                       axi_stream_video_frame frame,
                                       string title = "");

  // Write the frame out as PGM (one component) or PPM (three or more),
  // so a received frame can be opened in any image viewer.
  extern static function bit write_pnm(string filename,
                                       axi_stream_video_frame frame,
                                       bit binary = 1'b1);

  // ---- Text helpers --------------------------------------------------
  // One whitespace-separated token, skipping `#` comments. Returns ""
  // at end of file. Leaves the file positioned just past the token's
  // terminating whitespace character, which is what a binary PNM body
  // needs.
  extern static function string next_token(int file_descriptor);

  // Remove a `//` or `#` comment, then leading and trailing whitespace.
  extern static function string strip_comment(string text);
  extern static function string trim(string text);
  extern static function void split_tokens(string text, ref string tokens[$]);
  extern static function bit parse_hex(string text, output axi_stream_pixel_t value);

  // Pull "<width>x<height>" out of a Dimensions comment.
  extern static function bit parse_dimensions(string text,
                                              output int unsigned w,
                                              output int unsigned h);

  // Bits of precision a PNM maxval implies.
  extern static function int unsigned bits_for_maxval(int unsigned maxval);

  // The part of a path after the last '/'.
  extern static function string basename(string path);

  // Spread one file sample set across a frame's components, per the
  // table in this file's header.
  extern protected static function axi_stream_pixel_t map_components(
      axi_stream_video_format video_format,
      axi_stream_pixel_t file_samples[],
      int unsigned file_bits);

endclass : axi_stream_image_file

function axi_stream_image_file::new(string name = "axi_stream_image_file");
  super.new(name);
endfunction : new

function axi_stream_image_format_e axi_stream_image_file::detect(string filename);
  int file_descriptor;
  int first;
  int second;

  file_descriptor = $fopen(filename, "rb");
  if (file_descriptor == 0)
    return AXIS_IMAGE_AUTO;      // read() reports the open failure itself

  first  = $fgetc(file_descriptor);
  second = $fgetc(file_descriptor);
  $fclose(file_descriptor);

  if (first == "P")
    case (second)
      "2" : return AXIS_IMAGE_PGM_ASCII;
      "3" : return AXIS_IMAGE_PPM_ASCII;
      "5" : return AXIS_IMAGE_PGM_BINARY;
      "6" : return AXIS_IMAGE_PPM_BINARY;
      default : ;
    endcase

  return AXIS_IMAGE_HEX;
endfunction : detect

function bit axi_stream_image_file::read(string filename,
                                         axi_stream_video_frame frame,
                                         axi_stream_image_format_e file_format = AXIS_IMAGE_AUTO);
  axi_stream_image_format_e resolved;
  int file_descriptor;

  if (frame == null) begin
    `uvm_error("IMG_READ", "read() was given a null frame")
    return 1'b0;
  end

  // Checked here so a missing file reports the filename once, rather
  // than each reader having to.
  file_descriptor = $fopen(filename, "rb");
  if (file_descriptor == 0) begin
    `uvm_error("IMG_OPEN", $sformatf("cannot open '%s' for reading", filename))
    return 1'b0;
  end
  $fclose(file_descriptor);

  resolved = (file_format == AXIS_IMAGE_AUTO) ? detect(filename) : file_format;

  case (resolved)
    AXIS_IMAGE_HEX : return read_hex(filename, frame);
    AXIS_IMAGE_PGM_ASCII, AXIS_IMAGE_PGM_BINARY,
    AXIS_IMAGE_PPM_ASCII, AXIS_IMAGE_PPM_BINARY : return read_pnm(filename, frame, resolved);
    default : begin
      `uvm_error("IMG_READ", $sformatf("cannot work out the format of '%s'", filename))
      return 1'b0;
    end
  endcase
endfunction : read

function bit axi_stream_image_file::read_pnm(string filename,
                                             axi_stream_video_frame frame,
                                             axi_stream_image_format_e file_format);
  int          file_descriptor;
  string       magic;
  string       header_text;
  int unsigned w;
  int unsigned h;
  int unsigned maxval;
  int unsigned file_components;
  int unsigned file_bits;
  bit          is_binary;
  int unsigned bytes_per_sample;
  byte unsigned raw[];
  int          got;
  string       reason;

  file_components = (file_format inside {AXIS_IMAGE_PGM_ASCII, AXIS_IMAGE_PGM_BINARY}) ? 1 : 3;
  is_binary       = (file_format inside {AXIS_IMAGE_PGM_BINARY, AXIS_IMAGE_PPM_BINARY});

  file_descriptor = $fopen(filename, "rb");
  if (file_descriptor == 0) begin
    `uvm_error("IMG_OPEN", $sformatf("cannot open '%s' for reading", filename))
    return 1'b0;
  end

  magic       = next_token(file_descriptor);
  header_text = next_token(file_descriptor);
  w           = header_text.atoi();
  header_text = next_token(file_descriptor);
  h           = header_text.atoi();
  header_text = next_token(file_descriptor);
  maxval      = header_text.atoi();

  if ((w == 0) || (h == 0) || (maxval == 0)) begin
    `uvm_error("IMG_PNM", $sformatf(
        "'%s' has a malformed %s header: width=%0d height=%0d maxval=%0d",
        filename, magic, w, h, maxval))
    $fclose(file_descriptor);
    return 1'b0;
  end
  if (maxval > 65535) begin
    `uvm_error("IMG_PNM", $sformatf("'%s' has maxval=%0d; PNM allows at most 65535",
                                    filename, maxval))
    $fclose(file_descriptor);
    return 1'b0;
  end

  file_bits = bits_for_maxval(maxval);

  // A PNM says how many components it has and how precise they are, so
  // it can supply a format when the frame has none.
  if (frame.video_format == null) begin
    frame.video_format = (file_components == 1) ? axi_stream_video_format::gray(file_bits)
                                                : axi_stream_video_format::rgb(file_bits);
    `uvm_info("IMG_PNM", $sformatf("'%s' has no frame format set; derived %s from the file",
                                   filename, frame.video_format.convert2string()), UVM_MEDIUM)
  end
  if (!frame.video_format.is_sane(reason)) begin
    `uvm_error("IMG_FMT", $sformatf("the frame's video_format is not usable: %s", reason))
    $fclose(file_descriptor);
    return 1'b0;
  end

  frame.set_size(w, h);
  frame.source_name = filename;

  if (is_binary) begin
    bytes_per_sample = (maxval < 256) ? 1 : 2;
    raw = new [w * h * file_components * bytes_per_sample];
    got = $fread(raw, file_descriptor);
    if (got != raw.size()) begin
      `uvm_error("IMG_PNM", $sformatf(
          "'%s' ended early: wanted %0d sample byte(s) for a %0dx%0d %s image, got %0d",
          filename, raw.size(), w, h, magic, got))
      $fclose(file_descriptor);
      return 1'b0;
    end
  end

  for (int r = 0; r < h; r++) begin
    for (int c = 0; c < w; c++) begin
      axi_stream_pixel_t file_samples[];
      file_samples = new [file_components];
      for (int k = 0; k < file_components; k++) begin
        if (is_binary) begin
          int unsigned base = (((((r * w) + c) * file_components) + k) * bytes_per_sample);
          if (bytes_per_sample == 1)
            file_samples[k] = raw[base];
          else
            // Netpbm stores the most significant byte first.
            file_samples[k] = (axi_stream_pixel_t'(raw[base]) << 8) | raw[base + 1];
        end
        else begin
          string token = next_token(file_descriptor);
          if (token == "") begin
            `uvm_error("IMG_PNM", $sformatf(
                "'%s' ran out of samples at pixel (row %0d, col %0d) of a %0dx%0d image",
                filename, r, c, w, h))
            $fclose(file_descriptor);
            return 1'b0;
          end
          file_samples[k] = token.atoi();
        end
      end
      frame.set_pixel(r, c, map_components(frame.video_format, file_samples, file_bits));
    end
  end

  $fclose(file_descriptor);
  `uvm_info("IMG_PNM", $sformatf("read %0dx%0d %s from '%s' (%0d-bit samples)",
                                 w, h, magic, filename, file_bits), UVM_MEDIUM)
  return 1'b1;
endfunction : read_pnm

function bit axi_stream_image_file::read_hex(string filename, axi_stream_video_frame frame);
  int          file_descriptor;
  string       raw_line;
  string       text;
  string       tokens[$];
  int unsigned declared_width  = 0;
  int unsigned declared_height = 0;
  bit          have_declared   = 1'b0;
  int unsigned line_number     = 0;
  string       reason;

  // Pixels are collected flat, in raster order, because the height is
  // not known until the file ends. `row_width` is latched from the first
  // image line and every later line is checked against it.
  axi_stream_pixel_t collected[$];
  int unsigned       row_width = 0;
  int unsigned       row_count = 0;

  if (frame.video_format == null) begin
    `uvm_error("IMG_HEX", $sformatf(
        {"reading '%s' needs the frame's video_format to be set: a hex token is a packed ",
         "pixel word and there is nothing in the file that says how it is laid out"},
        filename))
    return 1'b0;
  end
  if (!frame.video_format.is_sane(reason)) begin
    `uvm_error("IMG_FMT", $sformatf("the frame's video_format is not usable: %s", reason))
    return 1'b0;
  end

  file_descriptor = $fopen(filename, "r");
  if (file_descriptor == 0) begin
    `uvm_error("IMG_OPEN", $sformatf("cannot open '%s' for reading", filename))
    return 1'b0;
  end

  while ($fgets(raw_line, file_descriptor) != 0) begin
    line_number++;

    // The Dimensions comment is read before the comment is discarded,
    // so a self-describing file can be checked against itself.
    if (!have_declared && parse_dimensions(raw_line, declared_width, declared_height))
      have_declared = 1'b1;

    text = strip_comment(raw_line);
    if (text == "")
      continue;

    split_tokens(text, tokens);

    if (row_count == 0)
      row_width = tokens.size();
    else if (tokens.size() != row_width) begin
      `uvm_error("IMG_HEX", $sformatf(
          {"'%s' line %0d has %0d pixel(s) but the first image line has %0d; ",
           "every line of a frame must be the same length"},
          filename, line_number, tokens.size(), row_width))
      $fclose(file_descriptor);
      return 1'b0;
    end

    foreach (tokens[i]) begin
      axi_stream_pixel_t value;
      if (!parse_hex(tokens[i], value)) begin
        `uvm_error("IMG_HEX", $sformatf("'%s' line %0d: '%s' is not a hex pixel value",
                                        filename, line_number, tokens[i]))
        $fclose(file_descriptor);
        return 1'b0;
      end
      collected.push_back(value & frame.video_format.pixel_mask());
    end
    row_count++;
  end
  $fclose(file_descriptor);

  if ((row_count == 0) || (row_width == 0)) begin
    `uvm_error("IMG_HEX", $sformatf("'%s' contains no image lines (only comments and blanks?)",
                                    filename))
    return 1'b0;
  end

  if (have_declared && ((declared_width != row_width) || (declared_height != row_count))) begin
    `uvm_error("IMG_HEX", $sformatf(
        "'%s' declares Dimensions: %0dx%0d but actually holds %0dx%0d pixels",
        filename, declared_width, declared_height, row_width, row_count))
    return 1'b0;
  end

  frame.set_size(row_width, row_count);
  frame.source_name = filename;
  foreach (collected[i])
    frame.set_pixel(i / row_width, i % row_width, collected[i]);

  `uvm_info("IMG_HEX", $sformatf("read %0dx%0d frame from '%s'",
                                 frame.width, frame.height, filename), UVM_MEDIUM)
  return 1'b1;
endfunction : read_hex

function bit axi_stream_image_file::write_hex(string filename,
                                              axi_stream_video_frame frame,
                                              string title = "");
  int file_descriptor;

  if (frame == null) begin
    `uvm_error("IMG_WRITE", "write_hex() was given a null frame")
    return 1'b0;
  end

  file_descriptor = $fopen(filename, "w");
  if (file_descriptor == 0) begin
    `uvm_error("IMG_OPEN", $sformatf("cannot open '%s' for writing", filename))
    return 1'b0;
  end

  $fdisplay(file_descriptor, "/////////////////////////////////////////////////////////////");
  $fdisplay(file_descriptor, "// Name: %s", (title == "") ? basename(filename) : title);
  $fdisplay(file_descriptor, "// Dimensions: %0dx%0d", frame.width, frame.height);
  if (frame.video_format != null)
    $fdisplay(file_descriptor, "// Format: %s", frame.video_format.convert2string());
  if (frame.source_name != "")
    $fdisplay(file_descriptor, "// Source: %s", frame.source_name);
  // No date: SystemVerilog cannot read the wall clock without shelling
  // out, and simulation time is the more useful number here anyway. The
  // reader ignores every comment line regardless of what it says.
  $fdisplay(file_descriptor, "// Generated: axi_stream_image_file at %0t", $realtime);
  $fdisplay(file_descriptor, "/////////////////////////////////////////////////////////////");
  $fdisplay(file_descriptor, "");

  for (int r = 0; r < frame.height; r++) begin
    string line_text = "";
    for (int c = 0; c < frame.width; c++)
      line_text = {line_text, (c == 0) ? "" : " ", frame.pixel_string(r, c)};
    $fdisplay(file_descriptor, "%s", line_text);
  end

  $fclose(file_descriptor);
  `uvm_info("IMG_HEX", $sformatf("wrote %0dx%0d frame to '%s'",
                                 frame.width, frame.height, filename), UVM_MEDIUM)
  return 1'b1;
endfunction : write_hex

function bit axi_stream_image_file::write_pnm(string filename,
                                              axi_stream_video_frame frame,
                                              bit binary = 1'b1);
  int          file_descriptor;
  int unsigned out_components;
  int unsigned maxval;
  int unsigned bytes_per_sample;
  string       magic;
  string       open_mode;

  if ((frame == null) || (frame.video_format == null)) begin
    `uvm_error("IMG_WRITE", "write_pnm() needs a frame with its video_format set")
    return 1'b0;
  end

  out_components = (frame.video_format.components_per_pixel >= 3) ? 3 : 1;
  maxval         = frame.video_format.max_sample();
  if (out_components == 1) magic = binary ? "P5" : "P2";
  else                     magic = binary ? "P6" : "P3";
  bytes_per_sample = (maxval < 256) ? 1 : 2;

  // "wb" matters: a binary PNM body must not have its newlines touched.
  //
  // The mode goes through a variable rather than inline, because XSIM
  // miscompiles $fopen when its mode argument is a conditional
  // expression -- it emits a two-argument call into a three-argument
  // intrinsic and xelab aborts with an LLVM assertion, no diagnostic.
  open_mode       = binary ? "wb" : "w";
  file_descriptor = $fopen(filename, open_mode);
  if (file_descriptor == 0) begin
    `uvm_error("IMG_OPEN", $sformatf("cannot open '%s' for writing", filename))
    return 1'b0;
  end

  $fdisplay(file_descriptor, "%s", magic);
  $fdisplay(file_descriptor, "# written by axi_stream_image_file: %s",
            frame.video_format.convert2string());
  $fdisplay(file_descriptor, "%0d %0d", frame.width, frame.height);
  $fdisplay(file_descriptor, "%0d", maxval);

  for (int r = 0; r < frame.height; r++) begin
    string line_text = "";
    for (int c = 0; c < frame.width; c++) begin
      for (int k = 0; k < out_components; k++) begin
        axi_stream_pixel_t sample = frame.component(r, c, k);
        byte unsigned high_byte = sample >> 8;
        byte unsigned low_byte  = sample;
        if (binary) begin
          if (bytes_per_sample == 2)
            $fwrite(file_descriptor, "%c", high_byte);
          $fwrite(file_descriptor, "%c", low_byte);
        end
        else begin
          line_text = {line_text, $sformatf("%0d ", sample)};
        end
      end
    end
    if (!binary)
      $fdisplay(file_descriptor, "%s", trim(line_text));
  end

  $fclose(file_descriptor);
  `uvm_info("IMG_PNM", $sformatf("wrote %0dx%0d %s to '%s'",
                                 frame.width, frame.height, magic, filename), UVM_MEDIUM)
  return 1'b1;
endfunction : write_pnm

function string axi_stream_image_file::next_token(int file_descriptor);
  int    ch;
  string token = "";

  forever begin
    ch = $fgetc(file_descriptor);
    if (ch < 0)
      return token;                       // end of file
    if (ch == "#") begin
      while ((ch >= 0) && (ch != "\n"))   // comments run to end of line
        ch = $fgetc(file_descriptor);
      continue;
    end
    if ((ch == " ") || (ch == "\n") || (ch == "\t") || (ch == "\r")) begin
      // Returning as soon as the token's own terminator is consumed is
      // what leaves a binary PNM positioned at its first sample byte.
      if (token.len() > 0)
        return token;
      continue;
    end
    token = {token, string'(ch)};
  end
endfunction : next_token

function string axi_stream_image_file::strip_comment(string text);
  for (int i = 0; i < text.len(); i++) begin
    bit is_comment = (text[i] == "#") ||
                     ((text[i] == "/") && ((i + 1) < text.len()) && (text[i+1] == "/"));
    if (is_comment)
      return (i == 0) ? "" : trim(text.substr(0, i - 1));
  end
  return trim(text);
endfunction : strip_comment

function string axi_stream_image_file::trim(string text);
  int first = -1;
  int last  = -1;

  for (int i = 0; i < text.len(); i++) begin
    byte ch = text[i];
    if ((ch != " ") && (ch != "\t") && (ch != "\n") && (ch != "\r")) begin
      if (first < 0) first = i;
      last = i;
    end
  end
  if (first < 0)
    return "";
  return text.substr(first, last);
endfunction : trim

function void axi_stream_image_file::split_tokens(string text, ref string tokens[$]);
  string token = "";

  tokens.delete();
  for (int i = 0; i < text.len(); i++) begin
    byte ch = text[i];
    if ((ch == " ") || (ch == "\t") || (ch == "\n") || (ch == "\r") || (ch == ",")) begin
      if (token.len() > 0) begin
        tokens.push_back(token);
        token = "";
      end
    end
    else begin
      token = {token, string'(ch)};
    end
  end
  if (token.len() > 0)
    tokens.push_back(token);
endfunction : split_tokens

function bit axi_stream_image_file::parse_hex(string text, output axi_stream_pixel_t value);
  int unsigned start  = 0;
  int unsigned digits = 0;

  value = '0;
  if (text.len() == 0)
    return 1'b0;
  if ((text.len() > 2) && (text[0] == "0") && ((text[1] == "x") || (text[1] == "X")))
    start = 2;

  for (int i = start; i < text.len(); i++) begin
    byte ch = text[i];
    axi_stream_pixel_t digit;
    if (ch == "_")
      continue;
    if      ((ch >= "0") && (ch <= "9")) digit = ch - "0";
    else if ((ch >= "a") && (ch <= "f")) digit = 10 + (ch - "a");
    else if ((ch >= "A") && (ch <= "F")) digit = 10 + (ch - "A");
    else return 1'b0;
    value  = (value << 4) | digit;
    digits++;
  end
  return (digits > 0);
endfunction : parse_hex

// Looks for "<number>x<number>" anywhere after a "imensions" marker,
// matching both "Dimensions:" and "dimensions:". Parsed by hand rather
// than with $sscanf so the surrounding punctuation does not matter.
function bit axi_stream_image_file::parse_dimensions(string text,
                                                     output int unsigned w,
                                                     output int unsigned h);
  int marker = -1;

  w = 0;
  h = 0;

  for (int i = 0; (i + 9) <= text.len(); i++)
    if (text.substr(i, i + 8) == "imensions") begin
      marker = i + 9;
      break;
    end
  if (marker < 0)
    return 1'b0;

  // <skip anything> <digits> 'x' <digits>
  for (int i = marker; i < text.len(); i++) begin
    if ((text[i] >= "0") && (text[i] <= "9")) begin
      int j = i;
      while ((j < text.len()) && (text[j] >= "0") && (text[j] <= "9")) begin
        w = (w * 10) + (text[j] - "0");
        j++;
      end
      if ((j >= text.len()) || ((text[j] != "x") && (text[j] != "X")))
        return 1'b0;
      j++;
      if ((j >= text.len()) || (text[j] < "0") || (text[j] > "9"))
        return 1'b0;
      while ((j < text.len()) && (text[j] >= "0") && (text[j] <= "9")) begin
        h = (h * 10) + (text[j] - "0");
        j++;
      end
      return (w > 0) && (h > 0);
    end
  end
  return 1'b0;
endfunction : parse_dimensions

function int unsigned axi_stream_image_file::bits_for_maxval(int unsigned maxval);
  int unsigned bits = 0;
  while ((bits < 32) && (((1 << bits) - 1) < maxval))
    bits++;
  return bits;
endfunction : bits_for_maxval

function string axi_stream_image_file::basename(string path);
  for (int i = path.len() - 1; i >= 0; i--)
    if (path[i] == "/")
      return path.substr(i + 1, path.len() - 1);
  return path;
endfunction : basename

function axi_stream_pixel_t axi_stream_image_file::map_components(
    axi_stream_video_format video_format,
    axi_stream_pixel_t file_samples[],
    int unsigned file_bits);
  axi_stream_pixel_t pixel = '0;

  for (int k = 0; k < video_format.components_per_pixel; k++) begin
    axi_stream_pixel_t sample;
    if (file_samples.size() == 1) begin
      // Gray: replicate into the colour components, full scale beyond.
      sample = (k < 3) ? video_format.rescale_sample(file_samples[0], file_bits)
                       : video_format.max_sample();
    end
    else if (k < file_samples.size()) begin
      sample = video_format.rescale_sample(file_samples[k], file_bits);
    end
    else begin
      // A component the file does not have: alpha, and opaque.
      sample = video_format.max_sample();
    end
    video_format.set_component(pixel, k, sample);
  end
  return pixel;
endfunction : map_components


///////////////////////////////////////////////////////////////////
// The frame's own file helpers. Declared in axi_stream_video_frame.sv
// and defined here, because they call into the reader above, which in
// turn needs the frame class complete.
///////////////////////////////////////////////////////////////////

function bit axi_stream_video_frame::load(string filename,
                                          axi_stream_image_format_e file_format = AXIS_IMAGE_AUTO);
  return axi_stream_image_file::read(filename, this, file_format);
endfunction : load

function bit axi_stream_video_frame::save_hex(string filename, string title = "");
  return axi_stream_image_file::write_hex(filename, this, title);
endfunction : save_hex

function bit axi_stream_video_frame::save_pnm(string filename, bit binary = 1'b1);
  return axi_stream_image_file::write_pnm(filename, this, binary);
endfunction : save_pnm
