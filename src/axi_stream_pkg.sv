///////////////////////////////////////////////////////////////////
// Filename: axi_stream_pkg.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : The reusable AXI4-Stream UVC: transaction, config,
//           backpressure policies, sequencer, master/slave drivers,
//           monitor, coverage, agent, sequence library, and the video
//           layer (pixel formats, frames, image files).
///////////////////////////////////////////////////////////////////
//
// This package plus axi_stream_if.sv (together, axi_stream_uvc.f) is
// the whole verification component. Drop those two files into another
// testbench's compile and you have it -- nothing else in this repository
// is needed, and nothing here depends on anything outside it but UVM.
//
// Include order below is dependency order, not alphabetical: each file
// only names types declared above it.

package axi_stream_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Enumerations, typedefs and the capacity constants for the
  // unparameterized transaction fields.
  `include "axi_stream_types.sv"

  // Programmable backpressure: the policy contract and its built-ins.
  `include "axi_stream_ready_policy.sv"

  // Per-agent configuration: role, link geometry, pacing, backpressure.
  `include "axi_stream_config.sv"

  // Transactions: one beat, and a whole TLAST-delimited packet.
  `include "axi_stream_seq_item.sv"
  `include "axi_stream_packet.sv"

  // The video layer's data model: pixel formats, a frame, and the image
  // file readers and writers. Nothing below here is video-specific --
  // a frame is turned into ordinary beats, so the drivers, the monitor
  // and the protocol checks are the same ones all other traffic uses.
  `include "axi_stream_video_types.sv"
  `include "axi_stream_video_format.sv"
  `include "axi_stream_video_frame.sv"
  `include "axi_stream_image_file.sv"

  // Components. The three that touch a virtual interface are
  // parameterized by the link's widths; everything else is not.
  `include "axi_stream_sequencer.sv"
  `include "axi_stream_master_driver.sv"
  `include "axi_stream_slave_driver.sv"
  `include "axi_stream_monitor.sv"
  `include "axi_stream_coverage.sv"
  `include "axi_stream_agent.sv"

  // Rebuilds frames from the beats a monitor publishes. Unparameterized
  // like the monitor's transaction, so it attaches to any link.
  `include "axi_stream_video_frame_collector.sv"

  // Stimulus.
  `include "axi_stream_seq_lib.sv"
  `include "axi_stream_video_seq_lib.sv"

endpackage : axi_stream_pkg
