# Sequences

Stimulus for the master agent. The slave agent needs none — its TREADY comes
from a [backpressure policy](backpressure.md), not from transactions.

## Nothing here mentions a width

Not one sequence in the library is parameterized, and none of them names a
TDATA size. They read the link's geometry from the agent's config through the
sequencer, so the same sequence object with the same constraints produces
4-byte beats on one link and 16-byte beats on another:

```systemverilog
axi_stream_random_seq random_sequence;
random_sequence = axi_stream_random_seq::type_id::create("random_sequence");
if (!random_sequence.randomize() with { num_packets == 20; })
  `uvm_fatal("RAND", "sequence randomization failed")
random_sequence.start(env.master_agent.sequencer);
```

That works because the transaction carries TDATA/TKEEP/TSTRB as dynamic arrays
sized at randomize time, so a 12-byte beat and a 16-byte beat are the same
SystemVerilog type. See [Architecture](architecture.md).

## The library

### `axi_stream_random_seq`

The workhorse: a stream of randomly shaped packets, with length, routing and
pacing re-drawn per packet.

| Knob | Default | Meaning |
| --- | --- | --- |
| `num_packets` | 4–16 | Packets to send |
| `min_beats` / `max_beats` | 1 / 8 | Packet length range |
| `sparse_percent` | 25 | Fraction of packets drawn from the sparse generator |

```systemverilog
if (!random_sequence.randomize() with { num_packets == 50;
                                        min_beats inside {[1:4]};
                                        sparse_percent == 0; })   // dense only
```

### `axi_stream_packet_seq`

One packet: a run of beats with TLAST on the last, and TID/TDEST held constant
across the frame as AXI4-Stream requires.

| Knob | Meaning |
| --- | --- |
| `num_beats` | Beats to generate, when `payload` is empty |
| `pkt_tid` / `pkt_tdest` | Routing, constrained to the link's widths |
| `payload` | A `byte unsigned` queue. When non-empty it wins over `num_beats` |

Give it `payload` and it carries exactly those bytes, chopping them into beats
of whatever width the link is and marking the leftover lanes of a short final
beat as null bytes:

```systemverilog
axi_stream_packet_seq directed_sequence;
directed_sequence = axi_stream_packet_seq::type_id::create("directed_sequence");
directed_sequence.agent_config = master_config;   // so it knows the link geometry
for (int i = 0; i < 21; i++)
  directed_sequence.payload.push_back(8'hA0 + i[7:0]);
if (!directed_sequence.randomize() with { pkt_tid == 3; pkt_tdest == 1; })
  `uvm_fatal("RAND", "randomization failed")
directed_sequence.start(env.master_agent.sequencer);
```

On an 8-byte link that 21-byte frame becomes three beats — 8, 8, and a short
final beat of 5 data bytes plus 3 null bytes. On a 16-byte link it becomes two.
The sequence is unchanged.

> Set `agent_config` before randomizing a sequence you built yourself. The
> routing constraints need the link's TID/TDEST widths, and without a config
> they solve to 0.

### `axi_stream_sparse_packet_seq`

A packet whose beats deliberately contain null and position bytes, exercising
the TKEEP/TSTRB encodings dense traffic never reaches.

| Knob | Default | Meaning |
| --- | --- | --- |
| `num_beats` | 1–6 | Beats in the packet |
| `null_percent` | 10–60 | Chance a lane is dropped to a null byte |
| `position_percent` | 0–25 | Chance a kept lane is only a position byte |
| `pkt_tid` / `pkt_tdest` | — | Routing |

The reserved `TKEEP=0 / TSTRB=1` combination stays unreachable: the transaction
forbids it with a hard constraint, so no `randomize() with` can talk the UVC
into emitting one.

### `axi_stream_beat_seq`

A single beat, TLAST free. Use it when framing does not matter.

## Byte encodings

AXI4-Stream gives each byte lane a meaning from its TKEEP/TSTRB pair
(§2.4.3), and the UVC models all four:

| TKEEP | TSTRB | `axi_stream_byte_type_e` | Meaning |
| --- | --- | --- | --- |
| 1 | 1 | `AXIS_BYTE_DATA` | An ordinary data byte |
| 1 | 0 | `AXIS_BYTE_POSITION` | Position byte: occupies a lane, carries no data |
| 0 | 0 | `AXIS_BYTE_NULL` | Null byte: no data, no position |
| 0 | 1 | `AXIS_BYTE_RESERVED` | Illegal — asserted against, never generated |

`beat.byte_type(i)` returns the classification for lane `i`.

## Writing your own

Extend `axi_stream_base_seq` and you inherit the geometry plumbing:

```systemverilog
class my_seq extends axi_stream_base_seq;
  `uvm_object_utils(my_seq)

  function new(string name = "my_seq");
    super.new(name);
  endfunction

  virtual task body();
    axi_stream_seq_item beat;
    // new_beat() returns an item already bound to this link's geometry.
    beat = new_beat();
    start_item(beat);
    if (!beat.randomize() with { tlast == 1'b1; tid == 2; })
      `uvm_fatal("RAND", "randomization failed")
    finish_item(beat);
  endtask
endclass
```

`pre_start()` fetches the config from the sequencer, so `new_beat()` sizes and
masks every field correctly without your sequence restating any widths.

To build a beat by hand rather than randomizing it:

```systemverilog
beat = new_beat();
beat.set_bytes('{8'hDE, 8'hAD, 8'hBE, 8'hEF});  // pads the tail with null bytes
beat.tlast = 1'b1;
start_item(beat);
finish_item(beat);
```

### Sparse payloads

`dense` is a plain knob on the transaction, not a constraint. Clear it and the
solver is free to choose the TKEEP/TSTRB pattern — still only ever a legal one:

```systemverilog
beat = new_beat();
beat.dense = 1'b0;
if (!beat.randomize()) `uvm_fatal("RAND", "randomization failed")
```

## Transaction reference

`axi_stream_seq_item` is one beat.

| Field | Meaning |
| --- | --- |
| `tdata[]` | Payload bytes; `tdata[0]` is TDATA[7:0] |
| `tkeep[]` / `tstrb[]` | One bit per byte |
| `tlast`, `tid`, `tdest`, `tuser` | As on the wire, masked to the link's widths |
| `delay` | Stimulus only: idle cycles before this beat |
| `stall_cycles` | Monitor only: cycles this beat spent stalled |
| `dense` | When set (default), every lane is a data byte |

| Helper | Returns |
| --- | --- |
| `num_data_bytes()` | Count of lanes with TKEEP set |
| `byte_type(i)` | The TKEEP/TSTRB classification of lane `i` |
| `set_bytes(bytes)` | Loads a byte array, padding the tail with null bytes |
| `tdata_string()` | Hex, most-significant byte first; null lanes print as `--` |

`compare()` deliberately ignores `delay` and `stall_cycles` — they describe
*when* a beat happened, not what it carried, so a beat that crossed a FIFO still
compares equal to the one that went in. It also compares TDATA only on lanes
TKEEP marks as valid, because AXI4-Stream leaves a null byte's TDATA explicitly
undefined and comparing it would manufacture failures.

## Video frames

Three more sequences send whole video frames, with TUSER[0] as SOF and TLAST as
EOL:

| Sequence | Sends |
| --- | --- |
| `axi_stream_video_frame_seq` | A frame you already have |
| `axi_stream_video_file_seq` | A frame read from a PGM, PPM or ASCII hex file |
| `axi_stream_video_pattern_seq` | A generated test pattern, so no file is needed |

They are ordinary sequences producing ordinary beats, and like the rest of the
library none of them mentions a width -- the frame's format says how many pixels
share a beat and the config says how wide the link is. See
[Video](video.md#sending-a-frame) and [Image files](image-files.md).

## Packets

`axi_stream_packet` is a whole TLAST-delimited frame, published on the
monitor's `packet_analysis_port`.

A video line is a packet, since every line ends in TLAST -- so the packet view
below checks video traffic line by line without being told anything about video.

| Helper | Returns |
| --- | --- |
| `payload(bytes)` | Every kept byte, in order, with null lanes removed |
| `num_beats()` / `num_payload_bytes()` | Counts |
| `tid()` / `tdest()` | Routing, from the first beat |
| `routing_is_constant()` | Whether TID/TDEST held across the frame |

`compare()` checks the flattened payload and routing, *not* the beat structure.
A frame re-blocked onto a different link width, or re-paced by a FIFO, is still
the same packet — which is what makes a width converter checkable with a plain
object compare.
