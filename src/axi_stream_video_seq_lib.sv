///////////////////////////////////////////////////////////////////
// Filename: axi_stream_video_seq_lib.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Master sequences that send whole video frames: from a frame
//           object, from an image file, or from a built-in test
//           pattern. Lines are delimited with TLAST as EOL and frames
//           with TUSER[0] as SOF, the Xilinx video mapping.
///////////////////////////////////////////////////////////////////
//
// These are ordinary axi_stream_base_seq sequences producing ordinary
// axi_stream_seq_item beats, so everything the UVC already does keeps
// working on video traffic: the master driver's handshake rules, the
// slave's backpressure models, the interface's protocol assertions, the
// monitor, the scoreboard. A frame is not a new kind of transfer, just a
// particular way of filling TDATA and the two sideband bits.
//
// Like the rest of the sequence library, none of these mentions a link
// width. The frame's axi_stream_video_format says how many pixels share
// a beat and the agent's config says how wide the link is; the sequence
// checks the one fits the other and then blocks the frame accordingly.
// The same sequence object therefore sends RGBA8888 one pixel per clock
// onto a 4-byte link and four pixels per clock onto a 16-byte link.
//
// ---- What goes on the wire -----------------------------------------
//
// For a 4-pixel-wide, 2-line frame at one pixel per clock:
//
//   beat  pixel  TUSER[0]  TLAST    note
//   ----  -----  --------  -----    --------------------------------
//     0   (0,0)      1       0      SOF: first pixel of the frame
//     1   (0,1)      0       0
//     2   (0,2)      0       0
//     3   (0,3)      0       1      EOL: last pixel of line 0
//     4   (1,0)      0       0
//     5   (1,1)      0       0
//     6   (1,2)      0       0
//     7   (1,3)      0       1      EOL: last pixel of line 1
//
// There is no end-of-frame beat. The frame is over when the next SOF
// arrives, or after the receiver's expected number of lines -- which is
// how Xilinx video streams work and what lets a receiver resynchronise
// on SOF after losing sync.
//
// With pixels_per_clock > 1 the table collapses: four pixels per clock
// sends line 0 as a single beat carrying (0,0) in the low bits through
// (0,3) in the high bits, with SOF and EOL both set on it.
//
// A line whose width is not a whole number of pixel groups ends in a
// short beat: the leftover pixel slots are driven to zero and their byte
// lanes marked as null bytes, so a receiver reading the kept bytes gets
// exactly the pixels that were sent.

virtual class axi_stream_video_base_seq extends axi_stream_base_seq;

  // The frame to send. The subclasses below build this for you from a
  // file or a pattern; set it directly to send a frame you built or one
  // that came back off the wire.
  axi_stream_video_frame frame;

  rand int unsigned num_frames;

  // Held constant across the whole frame, as AXI4-Stream requires of a
  // packet -- and every line is a packet here.
  rand axi_stream_id_t   pkt_tid;
  rand axi_stream_dest_t pkt_tdest;

  // Idle ACLK cycles before the first beat of each line and of each
  // frame: the horizontal and vertical blanking a real source would
  // have. These override the config's randomized beat delay on that one
  // beat; every other beat is paced by the config as usual.
  int unsigned line_gap_cycles  = 0;
  int unsigned frame_gap_cycles = 0;

  // Beats and frames actually sent, for a test that wants to assert on
  // the traffic it asked for.
  int unsigned num_beats_sent  = 0;
  int unsigned num_lines_sent  = 0;
  int unsigned num_frames_sent = 0;

  constraint c_num_frames { soft num_frames == 1; num_frames > 0; }

  constraint c_routing { (pkt_tid   >> m_id_width)   == 0;
                         (pkt_tdest >> m_dest_width) == 0; }

  extern function new(string name = "axi_stream_video_base_seq");

  extern virtual task body();

  // Hook for the subclasses: build `frame` if it is not set yet. Called
  // once, from body(), before anything is sent.
  extern virtual task prepare_frame();

  extern virtual task send_frame();

  // Check the frame, its format and the link against each other, and
  // report anything that would make the traffic meaningless. Returns 0
  // when the frame cannot be sent at all.
  extern virtual function bit check_frame_against_link();

endclass : axi_stream_video_base_seq

function axi_stream_video_base_seq::new(string name = "axi_stream_video_base_seq");
  super.new(name);
endfunction : new

task axi_stream_video_base_seq::body();
  prepare_frame();

  if (!check_frame_against_link())
    return;

  // frame_gap_cycles is applied by send_frame(), on the frame's first
  // beat, so back-to-back frames are separated without this loop having
  // to know about the pacing.
  for (int f = 0; f < num_frames; f++) begin
    send_frame();
    num_frames_sent++;
  end
endtask : body

task axi_stream_video_base_seq::prepare_frame();
  // Nothing to do: the base class is handed a frame.
endtask : prepare_frame

function bit axi_stream_video_base_seq::check_frame_against_link();
  string reason;

  if (frame == null) begin
    `uvm_error("VIDEO_SEQ", "no frame to send: set the sequence's `frame`, or use a file or pattern sequence")
    return 1'b0;
  end
  if (frame.video_format == null) begin
    `uvm_error("VIDEO_SEQ", "the frame has no video_format, so there is no way to know how its pixels sit on TDATA")
    return 1'b0;
  end
  if (!frame.video_format.is_sane(reason)) begin
    `uvm_error("VIDEO_SEQ", $sformatf("the frame's video_format is not usable: %s", reason))
    return 1'b0;
  end
  if ((frame.width == 0) || (frame.height == 0)) begin
    `uvm_error("VIDEO_SEQ", $sformatf("the frame is %0dx%0d, so there is nothing to send",
                                      frame.width, frame.height))
    return 1'b0;
  end
  if (!frame.video_format.fits_on_link(agent_config.data_bytes, reason)) begin
    `uvm_error("VIDEO_SEQ", reason)
    return 1'b0;
  end

  // The rest are warnings, not errors: a link that cannot carry the
  // framing can still carry the pixels, and sending them is more useful
  // than refusing to.
  if (frame.video_format.drive_sof && !agent_config.has_tuser)
    `uvm_warning("VIDEO_SEQ", $sformatf(
        {"this link carries no TUSER, so SOF cannot be marked; the frame will be sent as ",
         "%0d TLAST-delimited lines with no frame boundary. Clear the format's drive_sof to ",
         "silence this, and tell the receiver the frame height."}, frame.height))
  else if (frame.video_format.drive_sof &&
           (frame.video_format.sof_tuser_bit >= agent_config.user_width))
    `uvm_warning("VIDEO_SEQ", $sformatf(
        "SOF is TUSER[%0d] but this link's TUSER is only %0d bit(s) wide; SOF will not reach the sink",
        frame.video_format.sof_tuser_bit, agent_config.user_width))

  if (frame.video_format.mark_eol_with_tlast && !agent_config.has_tlast)
    `uvm_warning("VIDEO_SEQ",
        "this link carries no TLAST, so EOL cannot be marked and a receiver cannot recover lines")

  `uvm_info("VIDEO_SEQ", $sformatf("sending %0d x [%s] on a %0d-byte link",
                                   num_frames, frame.convert2string(),
                                   agent_config.data_bytes), UVM_MEDIUM)
  return 1'b1;
endfunction : check_frame_against_link

task axi_stream_video_base_seq::send_frame();
  axi_stream_video_format video_format = frame.video_format;
  int unsigned            ppc          = video_format.pixels_per_clock;
  bit                     mark_sof     = video_format.drive_sof &&
                                         agent_config.has_tuser &&
                                         (video_format.sof_tuser_bit < agent_config.user_width);
  bit                     mark_eol     = video_format.mark_eol_with_tlast && agent_config.has_tlast;

  for (int row = 0; row < frame.height; row++) begin
    axi_stream_pixel_t line_pixels[];
    int unsigned       col = 0;

    frame.get_line(row, line_pixels);

    while (col < frame.width) begin
      axi_stream_seq_item beat;
      byte unsigned       payload_bytes[];
      int unsigned        count   = ((frame.width - col) > ppc) ? ppc : (frame.width - col);
      bit                 is_sof  = (row == 0) && (col == 0);
      bit                 is_eol  = ((col + count) >= frame.width);
      bit                 is_bol  = (col == 0);
      bit                 drive_last = is_eol && mark_eol;
      axi_stream_id_t     t_id    = pkt_tid;
      axi_stream_dest_t   t_dest  = pkt_tdest;

      video_format.pack(line_pixels, col, count, payload_bytes);

      beat = new_beat($sformatf("beat_r%0d_c%0d", row, col));
      start_item(beat);
      // Only `delay` is left for the solver: the payload comes from the
      // frame and the sideband bits from the frame's geometry, so
      // nothing here is random except the pacing the config asked for.
      if (!beat.randomize() with { tlast == drive_last;
                                   tid   == t_id;
                                   tdest == t_dest;
                                   tuser == 0; })
        `uvm_fatal("RAND", "video beat randomization failed")

      beat.set_bytes(payload_bytes);
      if (is_sof && mark_sof)
        beat.tuser[video_format.sof_tuser_bit] = 1'b1;

      // Blanking. Assigned after randomize() rather than constrained,
      // because the gap is a property of the frame's timing and has no
      // business being reconciled with the config's delay window.
      if (is_sof && (frame_gap_cycles > 0))     beat.delay = frame_gap_cycles;
      else if (is_bol && (line_gap_cycles > 0)) beat.delay = line_gap_cycles;

      finish_item(beat);
      num_beats_sent++;

      col += count;
    end
    num_lines_sent++;
  end
endtask : send_frame


///////////////////////////////////////////////////////////////////
// Send a frame that is already in hand.
//
//   axi_stream_video_frame_seq video_sequence;
//   video_sequence = axi_stream_video_frame_seq::type_id::create("video_sequence");
//   video_sequence.frame = my_frame;
//   assert (video_sequence.randomize() with { num_frames == 3; });
//   video_sequence.start(master_sequencer);
//
///////////////////////////////////////////////////////////////////
class axi_stream_video_frame_seq extends axi_stream_video_base_seq;

  `uvm_object_utils(axi_stream_video_frame_seq)

  extern function new(string name = "axi_stream_video_frame_seq");

endclass : axi_stream_video_frame_seq

function axi_stream_video_frame_seq::new(string name = "axi_stream_video_frame_seq");
  super.new(name);
endfunction : new


///////////////////////////////////////////////////////////////////
// Read a frame from an image file and send it.
//
//   axi_stream_video_file_seq video_sequence;
//   video_sequence = axi_stream_video_file_seq::type_id::create("video_sequence");
//   video_sequence.filename     = "frames/logo.hex";
//   video_sequence.video_format = axi_stream_video_format::rgba8888();
//   assert (video_sequence.randomize());
//   video_sequence.start(master_sequencer);
//
// `video_format` may be left null for a PGM or PPM, which says enough
// about itself for one to be derived. A hex file does not, so it needs
// one -- see axi_stream_image_file.
///////////////////////////////////////////////////////////////////
class axi_stream_video_file_seq extends axi_stream_video_base_seq;

  string                    filename;
  axi_stream_image_format_e file_format = AXIS_IMAGE_AUTO;
  axi_stream_video_format   video_format;

  `uvm_object_utils(axi_stream_video_file_seq)

  extern function new(string name = "axi_stream_video_file_seq");
  extern virtual task prepare_frame();

endclass : axi_stream_video_file_seq

function axi_stream_video_file_seq::new(string name = "axi_stream_video_file_seq");
  super.new(name);
endfunction : new

task axi_stream_video_file_seq::prepare_frame();
  if (frame != null)
    return;                       // an explicit frame wins over the filename

  if (filename == "") begin
    `uvm_error("VIDEO_SEQ", "set `filename` (or `frame`) before starting this sequence")
    return;
  end

  frame = axi_stream_video_frame::type_id::create("frame");
  frame.video_format = video_format;    // may be null: a PNM supplies its own
  if (!frame.load(filename, file_format)) begin
    // load() has already reported why.
    frame = null;
    return;
  end
endtask : prepare_frame


///////////////////////////////////////////////////////////////////
// Generate a frame from one of the built-in patterns and send it. The
// way to get video traffic without shipping an image file alongside the
// testbench.
//
//   axi_stream_video_pattern_seq video_sequence;
//   video_sequence = axi_stream_video_pattern_seq::type_id::create("video_sequence");
//   video_sequence.video_format = axi_stream_video_format::rgba(12, 2);
//   video_sequence.pattern      = AXIS_PATTERN_BARS;
//   assert (video_sequence.randomize() with { frame_width == 64; frame_height == 16; });
//   video_sequence.start(master_sequencer);
//
///////////////////////////////////////////////////////////////////
class axi_stream_video_pattern_seq extends axi_stream_video_base_seq;

  rand int unsigned frame_width;
  rand int unsigned frame_height;

  axi_stream_video_pattern_e pattern = AXIS_PATTERN_RAMP;
  axi_stream_video_format    video_format;

  // Non-zero reseeds AXIS_PATTERN_RANDOM, so a failing frame can be
  // reproduced without reproducing the whole run.
  int unsigned pattern_seed = 0;

  // Small by default: a frame is sent beat by beat through a real
  // handshake, so a 1920x1080 frame is two million beats.
  constraint c_size { soft frame_width  inside {[8:64]};
                      soft frame_height inside {[4:16]};
                      frame_width  > 0;
                      frame_height > 0; }

  `uvm_object_utils(axi_stream_video_pattern_seq)

  extern function new(string name = "axi_stream_video_pattern_seq");
  extern virtual task prepare_frame();

endclass : axi_stream_video_pattern_seq

function axi_stream_video_pattern_seq::new(string name = "axi_stream_video_pattern_seq");
  super.new(name);
endfunction : new

task axi_stream_video_pattern_seq::prepare_frame();
  if (frame != null)
    return;

  if (video_format == null) begin
    `uvm_error("VIDEO_SEQ",
        "set `video_format` before starting this sequence, e.g. axi_stream_video_format::rgba8888()")
    return;
  end

  frame = axi_stream_video_frame::type_id::create("frame");
  frame.video_format = video_format;
  frame.set_size(frame_width, frame_height);
  frame.fill_pattern(pattern, pattern_seed);
endtask : prepare_frame
