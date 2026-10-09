# Image files

Reading a video frame from a file, and writing one back out. Three formats: this
UVC's own ASCII hex frame format, and the Netpbm PGM and PPM family.

All of it is pure SystemVerilog file I/O — `$fgetc`, `$fgets`, `$fread`,
`$fdisplay` — so it needs no DPI, no PLI and no helper script, and works in any
simulator the rest of the UVC works in.

```systemverilog
axi_stream_video_frame frame;
frame = axi_stream_video_frame::type_id::create("frame");
frame.video_format = axi_stream_video_format::rgba8888();
if (!frame.load("images/frame_4x4.hex"))
  `uvm_fatal("IMG", "could not read the frame")
```

Then send it with [`axi_stream_video_file_seq`](video.md#axi_stream_video_file_seq),
or hand it straight to a [frame sequence](video.md#sending-a-frame).

## Contents

- [The API](#the-api)
- [The ASCII hex frame format](#the-ascii-hex-frame-format)
- [PGM and PPM](#pgm-and-ppm)
- [Component mapping](#component-mapping)
- [Writing frames out](#writing-frames-out)
- [What the self-test covers](#what-the-self-test-covers)

## The API

The convenient form is on the frame:

| Method | |
| --- | --- |
| `frame.load(filename, file_format = AXIS_IMAGE_AUTO)` | Read. Returns 0 and reports a `UVM_ERROR` on failure |
| `frame.save_hex(filename, title = "")` | Write the ASCII hex format |
| `frame.save_pnm(filename, binary = 1)` | Write PGM or PPM, binary or ASCII |

The engine underneath is `axi_stream_image_file`, all static, should you want a
specific reader rather than the dispatcher:

| Function | |
| --- | --- |
| `read(filename, frame, file_format)` | What `load()` calls |
| `detect(filename)` | The format, from the file's magic number |
| `read_hex(filename, frame)` / `read_pnm(filename, frame, file_format)` | One reader |
| `write_hex(…)` / `write_pnm(…)` | One writer |

`AXIS_IMAGE_AUTO` sniffs the first two bytes: `P2`, `P3`, `P5` or `P6` selects
the matching Netpbm reader, and anything else is taken to be the ASCII hex
format. Name a format explicitly to override that.

| `axi_stream_image_format_e` | |
| --- | --- |
| `AXIS_IMAGE_AUTO` | Sniff the magic number |
| `AXIS_IMAGE_HEX` | This UVC's ASCII hex frame format |
| `AXIS_IMAGE_PGM_ASCII` / `AXIS_IMAGE_PGM_BINARY` | Netpbm P2 / P5, one component |
| `AXIS_IMAGE_PPM_ASCII` / `AXIS_IMAGE_PPM_BINARY` | Netpbm P3 / P6, three components |

## The ASCII hex frame format

A plain text file that shows a frame pixel by pixel in raster order, so it can
be read, diffed and edited by hand:

```text
/////////////////////////////
// Name: some_file.hex
// Dimensions: 4x4
// Date Generated: 10/8/26
/////////////////////////////

0x00000001 0x00000002 0x00000003 0x00000004
0x00000001 0x00000002 0x00000003 0x00000004
0x00000001 0x00000002 0x00000003 0x00000004
0x00000001 0x00000002 0x00000003 0x00000004
```

### The grammar, in full

- `//` or `#` begins a comment, which runs to the end of the line. A line that
  is blank once its comment is removed is ignored — so banner lines, blank
  separators and a trailing comment on a data line all cost nothing.
- Every other line is **one line of the image**. The end of an image line is the
  end of a text line; that is the whole point of the format, and is why there is
  no line-length field to get wrong.
- Within a line, pixels are whitespace-separated tokens in raster order. A token
  is hexadecimal with an optional `0x` or `0X` prefix, and `_` may be used freely
  as a digit separator. Commas also separate tokens, so a comma-delimited dump
  reads without editing.
- The **width** is the token count of the first image line, and every later line
  must match it. The **height** is the number of image lines.
- A `Dimensions: <width>x<height>` comment, if present, is checked against what
  was actually parsed. A file that contradicts itself is an error, not a guess.

All of these are the same 4×3 frame:

```text
0x0000_0000 0x0000_0040 0x0000_0080 0x0000_00FF   // R ramps, 0x00 alpha
00000000 00000040 00000080 000000ff               # same line, no prefix

0X0000_0000 0x0000_0040 0X0000_0080 0x0000_00Ff
```

### What a token means

Each token is one pixel's **packed value**, laid out exactly as the
[format](video.md#the-bit-layout) describes. For an RGBA8888 frame with the
default component order that is `0xAABBGGRR` — component 0 in the least
significant bits — and at one pixel per clock it is also literally the TDATA
word, so a frame file and a waveform show the same numbers.

Because the token says nothing about the layout, **reading a hex file needs the
frame's `video_format` set first**. There is nothing in the file to derive it
from, and the reader says so rather than guessing:

```
reading 'frame.hex' needs the frame's video_format to be set: a hex token is a
packed pixel word and there is nothing in the file that says how it is laid out
```

## PGM and PPM

The Netpbm formats, all four single-image variants:

| Magic | Format | Components | Samples |
| --- | --- | --- | --- |
| `P2` | PGM ASCII | 1 (gray) | decimal text |
| `P5` | PGM binary | 1 (gray) | raw bytes |
| `P3` | PPM ASCII | 3 (RGB) | decimal text |
| `P6` | PPM binary | 3 (RGB) | raw bytes |

Chosen because every image tool on earth writes them and they need no library to
parse — `convert in.png out.ppm` and you have a frame this UVC can drive.

The header is `magic`, width, height, maxval as whitespace-separated tokens with
`#` comments allowed anywhere between them. Binary sample data follows one
whitespace character after maxval. Samples are one byte when maxval < 256 and two
bytes, most significant first, above that.

**maxval gives the file's real precision** — 255 is 8 bits, 1023 is 10, 4095 is
12, 65535 is 16 — and samples are rescaled from that into the frame format's
precision by bit replication. So an 8-bit PPM loaded into a 12-bit RGBA frame
stays full scale rather than going dark: `0xFF` widens to `0xFFF`, not `0xFF0`.

A PNM says how many components it has, so unlike the hex format it **can supply a
format**. Load one into a frame whose `video_format` is null and a matching gray
or RGB format is created for it at one pixel per clock:

```systemverilog
axi_stream_video_frame frame = axi_stream_video_frame::type_id::create("frame");
if (!frame.load("images/ramp_4x3.pgm"))   // no video_format set
  `uvm_fatal("IMG", "could not read the frame")
// frame.video_format is now AXIS_VIDEO_GRAY 8bpc x1 ppc
```

## Component mapping

Where the file's component count and the frame's differ, they are mapped like
this:

| File | Frame | Result |
| --- | --- | --- |
| 1 (gray) | 3 or more (RGB/RGBA) | Gray replicated into components 0–2 |
| 3 (RGB) | 4 (RGBA) | RGB into components 0–2 |
| 1 or 3 | more than 3 | Components past the third set to full scale, so an alpha channel is opaque |
| 3 (RGB) | 1 (gray) | Component 0 only; the rest discarded |

So a PPM loaded into an RGBA frame comes out opaque, and a PGM loaded into an
RGBA frame comes out as opaque grey — both of which are what you want and
neither of which you have to write.

## Writing frames out

Dumping a received frame is often the quickest way to see what a DUT did to it:
open the `.ppm` in any image viewer, or diff the `.hex` against the input by eye.

```systemverilog
void'(frame_collector.received_frames[0].save_hex("received_frame.hex"));
void'(frame_collector.received_frames[0].save_pnm("received_frame.ppm"));
```

`save_hex` writes a banner this reader can read back, so a written frame is a
valid input file:

```text
/////////////////////////////////////////////////////////////
// Name: received_frame.hex
// Dimensions: 8x4
// Format: AXIS_VIDEO_RGBA 8bpc x2 ppc (32b/pixel, 64b/beat, >=8B link) SOF=TUSER[0] EOL=TLAST
// Source: uvm_test_top.env.frame_collector
// Generated: axi_stream_image_file at 975000
/////////////////////////////////////////////////////////////

0xff000000 0xff000024 0xff000048 0xff00006d 0xff000091 0xff0000b6 0xff0000da 0xff0000ff
0xff000000 0xff002400 0xff004800 0xff006d00 0xff009100 0xff00b600 0xff00da00 0xff00ff00
0xff000000 0xff240000 0xff480000 0xff6d0000 0xff910000 0xffb60000 0xffda0000 0xffff0000
0xff000000 0xff242424 0xff484848 0xff6d6d6d 0xff919191 0xffb6b6b6 0xffdadada 0xffffffff
```

There is no date line. SystemVerilog cannot read the wall clock without shelling
out, and simulation time is the more useful number here anyway — but the reader
ignores every comment line regardless of what it says, so a file written by
anything else with a `Date Generated:` banner reads fine.

`save_pnm` picks PGM for a one-component frame and PPM for three or more, binary
by default. Note what PNM cannot carry: **at most three components**, so saving an
RGBA frame drops alpha. That is fine for looking at, and wrong for comparing —
round-trip a frame through PNM only when it has three components or fewer.

## What the self-test covers

`make TEST=axi_stream_video_file_test` in `tb/` reads every file under
`tb/images/`, sends it over all five link widths, and checks what came back:

| File | What it covers |
| --- | --- |
| `frame_4x4.hex` | The plain ASCII hex frame, banner comments and all |
| `bars_8x4.hex` | Colour bars, so a component swap would be obvious |
| `gradient_4x3.hex` | Every spelling the reader accepts at once: bare hex, `0x` and `0X`, `_` separators, `//` and `#` comments, a trailing comment on a data line, and a blank line inside the image |
| `rgb_4x3.ppm` | Netpbm P3, read into a 3-component RGB frame — 24 bits on a 4-byte link, so one byte of every beat is padding |
| `ramp_4x3.pgm` | Netpbm P2, read with **no format set at all**, so the format is derived from the file's own header |

One link then round-trips each received frame back out through every writer and
reads it in again, which is what covers `write_hex`, `write_pnm` in both its
ASCII and binary forms, and the binary P5/P6 reader that no checked-in text file
would reach. The frames it writes are `received_*.hex`, `received_*.ppm` and
`received_*.pgm`, and `make clean` removes them.

The whole thing is in the regression, so these readers are exercised on every
`make regress` rather than on the day someone needs them.
