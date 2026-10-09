# Video

Sending whole video frames over an AXI4-Stream link, using the Xilinx video
sideband mapping: **TUSER[0] is SOF** (start of frame) and **TLAST is EOL** (end
of line).

The video layer rides on top of the rest of the UVC rather than replacing any of
it. A frame is turned into ordinary `axi_stream_seq_item` beats, so everything
already here keeps working on video traffic unchanged — the master driver's
handshake rules, the six [backpressure models](backpressure.md), the twenty
[protocol assertions](protocol-checks.md), the monitor, the scoreboard. A frame
is not a new kind of transfer; it is a particular way of filling TDATA and two
sideband bits.

```systemverilog
// RGBA8888, two pixels per clock -- 64 bits, which is an 8-byte link exactly.
axi_stream_video_format video_format = axi_stream_video_format::rgba8888(2);

axi_stream_video_pattern_seq video_sequence;
video_sequence = axi_stream_video_pattern_seq::type_id::create("video_sequence");
video_sequence.video_format = video_format;
video_sequence.pattern      = AXIS_PATTERN_BARS;
if (!video_sequence.randomize() with { frame_width == 64; frame_height == 16; })
  `uvm_fatal("RAND", "video sequence randomization failed")
video_sequence.start(env.master_agent.sequencer);
```

Reading a frame from a file instead is [Image files](image-files.md). The whole
thing worked end to end is [`example/example_base_test.sv`](../example/example_base_test.sv),
test `example_video_test`.

## Contents

- [What goes on the wire](#what-goes-on-the-wire)
- [Pixel formats](#pixel-formats)
- [Multiple pixels per clock](#multiple-pixels-per-clock)
- [The bit layout](#the-bit-layout)
- [Padding](#padding)
- [Frames](#frames)
- [Sending a frame](#sending-a-frame)
- [Receiving a frame](#receiving-a-frame)
- [Links without TUSER or TKEEP](#links-without-tuser-or-tkeep)
- [Test patterns](#test-patterns)
- [What the self-test covers](#what-the-self-test-covers)

## What goes on the wire

For a 4-pixel-wide, 2-line frame at one pixel per clock:

| beat | pixel | TUSER[0] | TLAST | |
| --- | --- | --- | --- | --- |
| 0 | (0,0) | **1** | 0 | SOF: first pixel of the frame |
| 1 | (0,1) | 0 | 0 | |
| 2 | (0,2) | 0 | 0 | |
| 3 | (0,3) | 0 | **1** | EOL: last pixel of line 0 |
| 4 | (1,0) | 0 | 0 | |
| 5 | (1,1) | 0 | 0 | |
| 6 | (1,2) | 0 | 0 | |
| 7 | (1,3) | 0 | **1** | EOL: last pixel of line 1 |

There is no end-of-frame beat. A frame ends when the next SOF arrives, or after
the receiver's expected number of lines. That is how Xilinx video streams work,
and taking frame boundaries from SOF rather than from a line count is what lets
a receiver resynchronise after losing sync.

Because every line ends in TLAST, **each line is an AXI4-Stream packet**. The
monitor's `packet_analysis_port` therefore publishes one packet per line, and
the existing scoreboard checks video traffic line by line without being told
anything about video.

## Pixel formats

A format is an `axi_stream_video_format` object. Like everything else above the
agent it is unparameterized, so one format object describes RGBA8888 whether it
is driven onto a 4-byte link at one pixel per clock or a 16-byte link at four.

The named constructors cover the usual cases:

| Constructor | Components | Example |
| --- | --- | --- |
| `rgba8888(ppc)` | R, G, B, A at 8 bits | `axi_stream_video_format::rgba8888()` |
| `rgba(bits, ppc)` | R, G, B, A at any width | `axi_stream_video_format::rgba(12, 2)` |
| `rgb(bits, ppc)` | R, G, B | `axi_stream_video_format::rgb(10)` |
| `gray(bits, ppc)` | Y | `axi_stream_video_format::gray(8, 4)` |
| `custom(n, bits, ppc)` | `n` generically named components | `axi_stream_video_format::custom(2, 16)` |

Both arguments default: `rgba()` is RGBA8888 at one pixel per clock.

The four RGBA widths asked of this UVC, and what each needs of the link:

| Format | Bits/pixel | 1 ppc | 2 ppc | 4 ppc |
| --- | --- | --- | --- | --- |
| RGBA8888 | 32 | 4 B | 8 B | 16 B |
| RGBA, 10 bits | 40 | 5 B | 10 B | 20 B |
| RGBA, 12 bits | 48 | 6 B | 12 B | 24 B |
| RGBA, 16 bits | 64 | 8 B | 16 B | 32 B |

Nothing in the table is a `` `define ``. These are run-time values in a plain
object, so a single simulation can drive all of them — and the UVC's self-test
does.

### Fields

| Field | Default | Meaning |
| --- | --- | --- |
| `colorspace` | `AXIS_VIDEO_RGBA` | Which components, and their names. `GRAY`, `RGB`, `RGBA`, `BGR`, `YUV444`, `CUSTOM` |
| `bits_per_component` | 8 | Real precision of each component, 1 to 16 |
| `components_per_pixel` | 4 | Implied by the colorspace except for `CUSTOM` |
| `pixels_per_clock` | 1 | Pixels carried in one beat |
| `byte_align_components` | 0 | Pad each component up to a whole byte |
| `component_msb_first` | 0 | Put component 0 in the pixel's most significant bits |
| `drive_sof` | 1 | Mark SOF on the frame's first beat |
| `sof_tuser_bit` | 0 | Which TUSER bit SOF uses |
| `mark_eol_with_tlast` | 1 | Mark EOL on each line's last beat |

### Derived geometry

| Method | Returns |
| --- | --- |
| `bits_per_pixel()` | `components_per_pixel * component_stride_bits()` |
| `bits_per_beat()` | `pixels_per_clock * bits_per_pixel()` |
| `min_data_bytes()` | Narrowest link this format fits on, in TDATA bytes |
| `bytes_for_pixels(n)` | Bytes `n` pixels occupy — what a short final beat gets |
| `max_sample()` | Largest value a component can hold |
| `component_name(i)` | `"R"`, `"G"`, `"B"`, `"A"`, … for messages |

`fits_on_link(data_bytes, reason)` is the check the sequences run before sending
anything. When it fails, `reason` names the width the format would need:

```
AXIS_VIDEO_RGBA 10bpc x2 ppc (40b/pixel, 80b/beat, >=10B link) needs a TDATA
width of at least 10 bytes (2 pixels/clock x 40 bits/pixel = 80 bits) but the
link is 8 bytes wide; widen the link or lower pixels_per_clock
```

`is_sane(reason)` catches a format that contradicts itself — an `AXIS_VIDEO_RGBA`
with three components, a component wider than 16 bits, a pixel wider than
`AXIS_VIDEO_MAX_PIXEL_BITS`.

## Multiple pixels per clock

`pixels_per_clock` is the knob. The link must be at least `min_data_bytes()`
wide to hold the group; the sequence checks that and refuses with the message
above rather than silently truncating.

Pixels are packed into the beat contiguously, **pixel 0 in the least significant
bits**. RGBA8888 at two pixels per clock on an 8-byte link:

```
TDATA[63:32]  pixel 1   (A1 B1 G1 R1)
TDATA[31:0]   pixel 0   (A0 B0 G0 R0)
```

A line whose width is not a whole number of pixel groups ends in a **short
beat**: the leftover pixel slots are driven to zero and their byte lanes marked
as null bytes. A 10-pixel line at four pixels per clock is therefore three
beats — two full, then one carrying two pixels — and a receiver reading the kept
bytes gets exactly the ten pixels that were sent. Several of the self-test's
frame widths are deliberately not multiples of the pixels per clock for exactly
this reason.

## The bit layout

Within a pixel, components are packed contiguously with **component 0 in the
least significant bits**:

```
RGBA8888, one pixel:
  bits 31:24  A    <- component 3
  bits 23:16  B    <- component 2
  bits 15:8   G    <- component 1
  bits  7:0   R    <- component 0
```

Component 0 goes in the LSBs because that is where Xilinx video IP puts it, and
it buys a property worth having: **at one pixel per clock, the pixel word is the
TDATA word**. A pixel value printed by the UVC, written into an
[ASCII hex frame file](image-files.md#the-ascii-hex-frame-format), and read off a
waveform are the same number — so a frame file can be diffed against a waveform
by eye.

If you would rather an RGBA8888 pixel read as `0xRRGGBBAA`, the order a graphics
programmer expects, set `component_msb_first`. It changes the packing only; the
component indices and their names never move.

Component access always goes through the format, so no user code does this
arithmetic:

```systemverilog
green = video_format.component(pixel, 1);          // read
video_format.set_component(pixel, 1, 10'h2AA);     // write
pixel = video_format.make_pixel('{r, g, b, a});    // build one
```

## Padding

Two different kinds, and the UVC handles them differently.

**Component padding** is off by default: 10-bit RGBA is 40 bits per pixel, not
64. Real Xilinx IP does it both ways — a VPSS at 10 bits per component carries 30
contiguous bits for RGB, while a frame buffer writing to memory pads each
component to a byte boundary — so `byte_align_components` picks between them.
With it set, a 10-bit component occupies 16 bits and 10-bit RGBA becomes 64 bits
per pixel.

**Beat padding** happens when the pixel group does not fill TDATA. 10-bit RGBA at
two pixels per clock is 80 bits, which on a 12-byte link leaves the top 16 bits
over. Those bits are driven to zero, and the byte lanes lying wholly in the
padding are marked as **null bytes** when the link carries TKEEP. That is what
makes the receiving side exact: `packet.payload()` gives the pixel bytes and
nothing else, and the frame collector stops at the first unkept lane.

On a link *without* TKEEP there is nothing on the wire to distinguish padding
from data — see [Links without TUSER or TKEEP](#links-without-tuser-or-tkeep).

## Frames

`axi_stream_video_frame` holds the pixels, already packed, one
`axi_stream_pixel_t` each, in raster order — left to right, top to bottom. That
is the order they go onto the wire and the order a file lists them in, so no
pass over a frame ever reorders anything.

| Member | |
| --- | --- |
| `video_format` | How the pixels below are laid out |
| `width` / `height` | Pixels per line, lines per frame |
| `pixels[]` | Raster order: `pixels[row*width + col]` |
| `source_name` | A filename or pattern name, for messages |

| Method | |
| --- | --- |
| `set_size(w, h)` | Resize, keeping pixels that still fit |
| `pixel(row, col)` / `set_pixel(row, col, v)` | Whole packed pixels |
| `component(row, col, i)` / `set_component(row, col, i, v)` | One component |
| `get_line(row, pixels)` / `set_line(row, pixels)` | A whole line |
| `fill_pattern(pattern, seed)` | One of the [built-in patterns](#test-patterns) |
| `fill_constant(value)` | Every pixel the same |
| `load(filename)` / `save_hex(…)` / `save_pnm(…)` | [Image files](image-files.md) |
| `first_difference(other)` | Raster index of the first differing pixel, or −1 |
| `component_string(row, col)` | `0xff00ff00 (R=0 G=ff B=0 A=ff)` |

`compare()` is what makes the class worth having. It checks geometry, then every
pixel masked to the format's real precision, and on a mismatch says which pixel
and which component differ:

```
frame 0 pixel (row 0, col 3) sent 0xffffff00 (R=0 G=ff B=ff A=ff),
                              got 0x00ffff00 (R=0 G=ff B=ff A=0)
```

A frame that crossed a 4-byte link and the same frame that crossed a 16-byte
link are equal objects, because the blocking into beats is not part of the
frame.

## Sending a frame

Three sequences, all extending `axi_stream_video_base_seq`, so they share the
same knobs:

| Knob | Default | Meaning |
| --- | --- | --- |
| `frame` | — | The frame to send. The two subclasses below build it for you |
| `num_frames` | 1 | Times to send it |
| `pkt_tid` / `pkt_tdest` | random | Held constant across the frame, as the spec requires |
| `line_gap_cycles` | 0 | Idle ACLK cycles before each line — horizontal blanking |
| `frame_gap_cycles` | 0 | Idle ACLK cycles before each frame — vertical blanking |

and report `num_beats_sent`, `num_lines_sent`, `num_frames_sent` afterwards.

### `axi_stream_video_frame_seq`

Sends a frame you already have — one you built, or one that came back off the
wire.

```systemverilog
axi_stream_video_frame_seq video_sequence;
video_sequence = axi_stream_video_frame_seq::type_id::create("video_sequence");
video_sequence.frame = my_frame;
if (!video_sequence.randomize() with { num_frames == 3; })
  `uvm_fatal("RAND", "video sequence randomization failed")
video_sequence.start(env.master_agent.sequencer);
```

### `axi_stream_video_file_seq`

Reads the frame from an image file first. See [Image files](image-files.md).

```systemverilog
axi_stream_video_file_seq video_sequence;
video_sequence = axi_stream_video_file_seq::type_id::create("video_sequence");
video_sequence.filename     = "images/frame_8x4.hex";
video_sequence.video_format = axi_stream_video_format::rgba8888(2);
if (!video_sequence.randomize())
  `uvm_fatal("RAND", "video sequence randomization failed")
video_sequence.start(env.master_agent.sequencer);
```

`video_format` may be left null for a PGM or PPM, which says enough about itself
for one to be derived. A hex file does not, so it needs one.

### `axi_stream_video_pattern_seq`

Generates the frame, so a test needs no file alongside it.

| Knob | Default | Meaning |
| --- | --- | --- |
| `video_format` | — | Required |
| `frame_width` / `frame_height` | 8–64 / 4–16 | Frame geometry |
| `pattern` | `AXIS_PATTERN_RAMP` | See [Test patterns](#test-patterns) |
| `pattern_seed` | 0 | Non-zero reseeds `AXIS_PATTERN_RANDOM` reproducibly |

The size defaults are small on purpose: a frame goes out beat by beat through a
real handshake, so a 1920×1080 frame is two million beats.

### Pacing

Source-side pacing works exactly as it does for any other traffic — the config's
`min_beat_delay`/`max_beat_delay` window applies to every beat. `line_gap_cycles`
and `frame_gap_cycles` override that window on the first beat of a line or a
frame, which is how blanking is modelled. There is no blanking signal in
AXI4-Stream video; a gap is simply TVALID low.

## Receiving a frame

`axi_stream_video_frame_collector` rebuilds frames from the beats a monitor
publishes. Subscribe it to any monitor's **beat** port — not the packet port,
because it needs TUSER[0] per beat and a packet is only one line:

```systemverilog
// in the env
frame_collector = axi_stream_video_frame_collector::type_id::create("frame_collector", this);
...
slave_agent.monitor.beat_analysis_port.connect(frame_collector.analysis_export);

// in the test
frame_collector.video_format    = video_format;
frame_collector.expected_width  = 64;   // optional; 0 derives it
frame_collector.expected_height = 16;   // optional; 0 ends a frame at the next SOF
```

Frames arrive on `frame_analysis_port` and, unless `keep_received_frames` is
cleared, pile up in `received_frames`. Checking a video DUT is then a plain
object compare:

```systemverilog
if (!sent_frame.compare(frame_collector.received_frames[0]))
  `uvm_error("VIDEO", "the frame that came back is not the one sent")
```

| Member | |
| --- | --- |
| `video_format` | Until set, **every beat is ignored** — so a collector can sit in an env permanently and cost a non-video test nothing |
| `expected_width` | 0 derives it from the kept bytes between TLASTs |
| `expected_height` | 0 ends a frame at the next SOF instead |
| `received_frames` | Frames so far. A long run should clear this, or clear `keep_received_frames` and use the port |
| `num_frames_collected` / `num_lines_collected` / `num_beats_seen` | Counts, also reported at the end of the run |
| `publish_frame()` | Close the frame in progress now |
| `reset()` | Discard what is half-assembled — **call this after a reset** |

Setting `expected_height` is worth doing wherever the height is known. Without
it the last frame of a run has nothing after it to close it, and is published
only at the end of the test — or when you call `publish_frame()` yourself.

After an ARESETn pulse the beats in flight are gone; call `reset()` so what
survived is not spliced onto the next frame.

## Links without TUSER or TKEEP

Both degrade, and both say so once rather than per beat.

**No TUSER** means SOF cannot be marked. Clear the format's `drive_sof`; the
frame still goes out as TLAST-delimited lines, and the receiver has to be told
the height (`expected_height`) because there is no frame boundary on the wire.
Leaving `drive_sof` set on such a link produces one warning naming the
consequence, and the pixels still go out.

**No TKEEP** means padding is indistinguishable from data, and a short final beat
cannot be told from a full one. Set `expected_width` there. Leave it 0 and a line
whose width is not a multiple of `pixels_per_clock` comes back with trailing zero
pixels — which is not a bug, it is the information not being on the wire.

**No TLAST** means there are no lines to recover at all. The collector warns and
collects nothing; this is legal AXI4-Stream but it is not the Xilinx video
protocol.

The UVC's self-test runs its bare link — TDATA, TVALID, TREADY and TLAST, with
no TUSER, TKEEP or TSTRB — through the first of these on every regression, so
the degraded path is exercised rather than merely described.

## Test patterns

| Pattern | What it is | What it makes obvious |
| --- | --- | --- |
| `AXIS_PATTERN_RAMP` | Component 0 ramps across the line, 1 down the frame, 2 mid scale | A wrong component order: the wrong axis ramps |
| `AXIS_PATTERN_BARS` | Eight colour bars across the width | A lane swap: a bar is the wrong colour |
| `AXIS_PATTERN_CHECKER` | 8×8 checkerboard, full scale and zero | A half-beat offset: a sheared edge |
| `AXIS_PATTERN_INDEX` | Every pixel is its own raster index | A dropped or duplicated beat: a gap in the numbers |
| `AXIS_PATTERN_RANDOM` | Uniformly random components | Nothing is special-cased, so nothing can accidentally match |

## What the self-test covers

`make TEST=axi_stream_video_test` in `tb/` sends frames at every pixel format
and pixels-per-clock combination the UVC claims, on all five link widths at
once, under random backpressure and with source bubbles. Ten passes in one
simulation:

| Link | TDATA | Formats sent | Frame |
| --- | --- | --- | --- |
| `env_w4` | 4 B | RGBA8888 ×1 (32b, exact) | 8×4 |
| `env_w8` | 8 B | RGBA16 ×1 (64b, exact), RGBA8888 ×2 (64b, exact), RGBA10 ×1 (40b of 64) | 6×3 |
| `env_w12` | 12 B | RGBA12 ×2 (96b, exact), RGBA10 ×2 (80b of 96) | 7×4 |
| `env_w16` | 16 B | RGBA8888 ×4 (128b, exact), RGBA16 ×2 (128b, exact), RGBA12 ×2 (96b of 128) | 10×3 |
| `env_min` | 4 B | RGBA8888 ×1, no SOF (no TUSER) | 4×4 |

Each pass checks the frames rebuilt at **both** ends of the link against the
frame that was sent, which is what actually proves the packing round-trips, that
SOF and EOL land on the right beats, that short final beats work (the 7-pixel
and 10-pixel widths are not multiples of their pixels per clock), and that beat
padding works (three of the formats do not fill TDATA).

The two collectors are set up differently on purpose: the sink one is told the
frame geometry, the source one is told nothing and derives the width from the
kept bytes and the frame boundary from SOF. Both paths are therefore exercised
in the same run.

`make TEST=axi_stream_video_file_test` does the same for the
[image file readers and writers](image-files.md#what-the-self-test-covers).
