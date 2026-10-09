///////////////////////////////////////////////////////////////////
// Filename: axi_stream_video_frame_collector.sv
// Author  : Benjamin Tamayo
// Date    : 2026-10-08
// Purpose : Rebuilds video frames from the beats a monitor publishes:
//           lines from TLAST, frames from TUSER[0], pixels from the
//           bytes in between. The receiving half of the video layer.
///////////////////////////////////////////////////////////////////
//
// Subscribe it to any monitor's beat port and it turns that link's
// traffic back into axi_stream_video_frame objects:
//
//   source_frame_collector = axi_stream_video_frame_collector::type_id::create(
//                                "source_frame_collector", this);
//   ...
//   master_agent.monitor.beat_analysis_port.connect(
//       source_frame_collector.analysis_export);
//   source_frame_collector.video_format = my_format;
//
// Frames arrive on `frame_analysis_port` and, unless switched off, pile
// up in `received_frames` for a test to compare at the end. Because the
// frame it produces is the same type a sequence sends, checking a video
// DUT is a plain object compare:
//
//   if (!sent_frame.compare(sink_frame_collector.received_frames[0]))
//     `uvm_error("VIDEO", "the frame that came back is not the one sent")
//
// It is driven entirely by the beats, so it works equally on the link
// going into a DUT and the one coming out, and it never needs the
// sequence that produced the traffic.
//
// ---- How a frame is delimited --------------------------------------
//
// A line ends at TLAST. A frame ends either at the next SOF or, when
// `expected_height` is set, after that many lines. Those are the only
// two options the Xilinx video protocol offers, since there is no
// end-of-frame marker on the wire.
//
// Setting `expected_height` is worth doing wherever the height is known:
// without it the last frame of a run has nothing after it to close it,
// and is only published at the end of the test.
//
// ---- Where padding gets in the way ---------------------------------
//
// A beat may carry fewer pixels than its byte lanes could hold, either
// because the format does not fill TDATA or because a line's width is
// not a whole number of pixel groups. On a link with TKEEP the sender
// marks those lanes as null bytes and this collector simply stops at the
// first one, so the pixels come back exactly.
//
// On a link *without* TKEEP there is nothing on the wire to distinguish
// padding from data, and a short final beat cannot be told from a full
// one. Set `expected_width` there and the collector takes exactly that
// many pixels per line; leave it 0 and a line whose width is not a
// multiple of pixels_per_clock comes back with trailing zero pixels.

class axi_stream_video_frame_collector extends uvm_subscriber #(axi_stream_seq_item);

  `uvm_component_utils(axi_stream_video_frame_collector)

  // How to read the pixels out of the beats. Until this is set the
  // collector ignores every beat, so one can sit permanently in an env
  // and cost nothing on a non-video test.
  axi_stream_video_format video_format;

  // Pixels per line. 0 derives it from the bytes between TLASTs, which
  // is right whenever the sender marks its padding (see the header).
  int unsigned expected_width = 0;

  // Lines per frame. 0 ends a frame at the next SOF instead.
  int unsigned expected_height = 0;

  uvm_analysis_port #(axi_stream_video_frame) frame_analysis_port;

  // Frames collected so far. A long video test should clear this
  // periodically, or clear `keep_received_frames` and use the analysis
  // port instead -- a frame is a real amount of memory.
  axi_stream_video_frame received_frames[$];
  bit                    keep_received_frames = 1'b1;

  int unsigned num_beats_seen       = 0;
  int unsigned num_lines_collected  = 0;
  int unsigned num_frames_collected = 0;
  int unsigned num_frames_dropped   = 0;

  // Bytes of the line being assembled, and the pixels of the frame
  // assembled so far.
  local byte unsigned      m_line_bytes[$];
  local axi_stream_pixel_t m_frame_pixels[$];
  local int unsigned       m_rows  = 0;
  local int unsigned       m_width = 0;
  local bit                m_warned_no_framing = 1'b0;

  extern function new(string name = "axi_stream_video_frame_collector",
                      uvm_component parent = null);

  // The formal is `t`, not `beat`, because this overrides
  // uvm_subscriber::write and SystemVerilog matches overrides by formal
  // name -- renaming it would break any named-argument call through a
  // base-class handle.
  extern virtual function void write(axi_stream_seq_item t);

  // End the line being assembled and append it to the frame.
  extern virtual function void end_line();

  // Publish the frame assembled so far, if there is one.
  extern virtual function void publish_frame();

  // Throw away whatever is half-assembled. Call this after a reset: the
  // beats that were in flight are gone and splicing what survived onto
  // the next frame would manufacture a mismatch.
  extern virtual function void reset();

  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

endclass : axi_stream_video_frame_collector

function axi_stream_video_frame_collector::new(string name = "axi_stream_video_frame_collector",
                                               uvm_component parent = null);
  super.new(name, parent);
  frame_analysis_port = new("frame_analysis_port", this);
endfunction : new

function void axi_stream_video_frame_collector::write(axi_stream_seq_item t);
  axi_stream_seq_item beat = t;
  bit                 is_sof;
  bit                 is_eol;
  int unsigned        limit;

  // No format, no opinion: a collector that has not been told the pixel
  // layout stays out of the way entirely.
  if (video_format == null)
    return;

  num_beats_seen++;

  // Without EOL there are no lines, and without either EOL or a line
  // count there are no frames. Said once rather than per beat.
  if (!m_warned_no_framing) begin
    if (!video_format.mark_eol_with_tlast) begin
      `uvm_warning("VIDEO_COLLECT",
          "the format says EOL is not marked with TLAST, so lines cannot be recovered from this stream")
      m_warned_no_framing = 1'b1;
    end
    else if (!video_format.drive_sof && (expected_height == 0)) begin
      `uvm_warning("VIDEO_COLLECT", {"the format marks no SOF and expected_height is 0, so a ",
                                     "frame boundary cannot be found; set expected_height"})
      m_warned_no_framing = 1'b1;
    end
  end

  is_sof = video_format.drive_sof && beat.has_tuser &&
           (video_format.sof_tuser_bit < beat.user_width) &&
           beat.tuser[video_format.sof_tuser_bit];

  // SOF means a new frame starts here, so whatever was being assembled
  // is finished -- complete or not.
  if (is_sof && ((m_rows > 0) || (m_line_bytes.size() > 0)))
    publish_frame();

  // Take the beat's pixel bytes: lane 0 upward, stopping at the first
  // lane that is padding, either because the format does not reach it or
  // because TKEEP says it carries nothing.
  limit = video_format.pixel_bytes_per_beat();
  foreach (beat.tdata[i]) begin
    if (i >= limit)
      break;
    if (beat.has_tkeep && !beat.tkeep[i])
      break;
    m_line_bytes.push_back(beat.tdata[i]);
  end

  is_eol = video_format.mark_eol_with_tlast && beat.has_tlast && beat.tlast;
  if (is_eol)
    end_line();

  if ((expected_height > 0) && (m_rows >= expected_height))
    publish_frame();
endfunction : write

function void axi_stream_video_frame_collector::end_line();
  axi_stream_pixel_t line_pixels[];
  int unsigned       count;
  int unsigned       needed;

  if (m_line_bytes.size() == 0) begin
    `uvm_warning("VIDEO_COLLECT", "a TLAST arrived with no pixel bytes before it; ignoring the line")
    return;
  end

  count = (expected_width > 0) ? expected_width
                               : ((m_line_bytes.size() * 8) / video_format.bits_per_pixel());
  if (count == 0) begin
    `uvm_error("VIDEO_COLLECT", $sformatf(
        "a line carried only %0d byte(s), not enough for one %0d-bit pixel",
        m_line_bytes.size(), video_format.bits_per_pixel()))
    m_line_bytes.delete();
    return;
  end

  needed = video_format.bytes_for_pixels(count);
  if (m_line_bytes.size() < needed)
    `uvm_error("VIDEO_COLLECT", $sformatf(
        {"a line carried %0d byte(s) but %0d pixel(s) need %0d; the missing pixels will read ",
         "as zero. Is expected_width right, or did the link drop a beat?"},
        m_line_bytes.size(), count, needed))

  video_format.unpack(m_line_bytes, count, line_pixels);

  if (m_rows == 0)
    m_width = count;
  else if (count != m_width)
    `uvm_error("VIDEO_COLLECT", $sformatf(
        "line %0d of this frame is %0d pixel(s) wide but line 0 was %0d; a frame cannot change width",
        m_rows, count, m_width));

  foreach (line_pixels[i])
    m_frame_pixels.push_back(line_pixels[i]);

  m_rows++;
  num_lines_collected++;
  m_line_bytes.delete();
endfunction : end_line

function void axi_stream_video_frame_collector::publish_frame();
  axi_stream_video_frame collected_frame;

  if (m_rows == 0) begin
    // Nothing but a partial line: not a frame, and reporting it as one
    // would be worse than dropping it.
    if (m_line_bytes.size() > 0) begin
      `uvm_warning("VIDEO_COLLECT", $sformatf(
          "discarding %0d byte(s) of a line that never reached TLAST", m_line_bytes.size()))
      num_frames_dropped++;
    end
    reset();
    return;
  end

  if (m_line_bytes.size() > 0)
    `uvm_warning("VIDEO_COLLECT", $sformatf(
        "the frame ended with %0d byte(s) of a line that never reached TLAST; they are discarded",
        m_line_bytes.size()))

  collected_frame = axi_stream_video_frame::type_id::create("collected_frame");
  collected_frame.video_format = video_format;
  collected_frame.set_size(m_width, m_rows);
  collected_frame.source_name  = get_full_name();
  foreach (m_frame_pixels[i])
    collected_frame.set_pixel(i / m_width, i % m_width, m_frame_pixels[i]);

  num_frames_collected++;
  if (keep_received_frames)
    received_frames.push_back(collected_frame);
  frame_analysis_port.write(collected_frame);

  `uvm_info("VIDEO_COLLECT", $sformatf("collected %s", collected_frame.convert2string()), UVM_HIGH)
  reset();
endfunction : publish_frame

function void axi_stream_video_frame_collector::reset();
  m_line_bytes.delete();
  m_frame_pixels.delete();
  m_rows  = 0;
  m_width = 0;
endfunction : reset

// The last frame of a run has no SOF after it to close it, so it is
// published here instead -- which is why a test can check the frame it
// just sent without having to send a trailing dummy frame.
function void axi_stream_video_frame_collector::check_phase(uvm_phase phase);
  super.check_phase(phase);
  if ((m_rows > 0) || (m_line_bytes.size() > 0))
    publish_frame();
endfunction : check_phase

function void axi_stream_video_frame_collector::report_phase(uvm_phase phase);
  super.report_phase(phase);
  if (video_format != null)
    `uvm_info("VIDEO_COLLECT", $sformatf("collected %0d frame(s), %0d line(s) from %0d beat(s)",
                                         num_frames_collected, num_lines_collected,
                                         num_beats_seen), UVM_LOW)
endfunction : report_phase
