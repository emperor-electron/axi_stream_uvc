///////////////////////////////////////////////////////////////////
// Filename: axi_stream_types.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Shared enumerations, typedefs and capacity constants for the
//           AXI4-Stream UVC. Included first by axi_stream_pkg so every
//           other class in the UVC can name these types.
///////////////////////////////////////////////////////////////////

// Capacities for the *unparameterized* transaction fields. A sequence
// item has to be usable against a 4-byte link and a 16-byte link in the
// same simulation, so its control fields are held in vectors sized to
// the widest link the UVC supports and masked down to the link's real
// width. TDATA needs no such cap: it is carried as a byte queue.
parameter int AXIS_MAX_ID_WIDTH   = 32;
parameter int AXIS_MAX_DEST_WIDTH = 32;
parameter int AXIS_MAX_USER_WIDTH = 256;

typedef bit [AXIS_MAX_ID_WIDTH-1:0]   axi_stream_id_t;
typedef bit [AXIS_MAX_DEST_WIDTH-1:0] axi_stream_dest_t;
typedef bit [AXIS_MAX_USER_WIDTH-1:0] axi_stream_user_t;

// Which end of the link this agent owns. The two are not symmetric:
// a master agent sources TVALID and the whole payload, a slave agent
// sources nothing but TREADY.
typedef enum {
  AXIS_MASTER,  // drives a DUT's *slave* port  (source of transfers)
  AXIS_SLAVE    // drives a DUT's *master* port (sink, source of TREADY)
} axi_stream_role_e;

// Built-in backpressure models, selected through
// axi_stream_config::set_ready_mode() and implemented by
// axi_stream_default_ready_policy. For anything these do not cover,
// extend axi_stream_ready_policy and hand the object to the config --
// the slave driver only ever talks to the base class.
typedef enum {
  AXIS_READY_ALWAYS,  // TREADY tied high: no backpressure at all
  AXIS_READY_NEVER,   // TREADY tied low: the sink never accepts
  AXIS_READY_RANDOM,  // independent per-cycle coin flip, ready_percent
  AXIS_READY_DUTY,    // deterministic square wave, ready_cycles / stall_cycles
  AXIS_READY_BURST,   // accept burst_beats transfers, then stall stall_cycles
  AXIS_READY_DELAY    // hold off delay_min..delay_max cycles after TVALID
} axi_stream_ready_mode_e;

// How a byte is marked by the TKEEP/TSTRB pair (AXI4-Stream 2.4.3).
typedef enum bit [1:0] {
  AXIS_BYTE_NULL     = 2'b00,  // TKEEP=0 TSTRB=0: no data, no position
  AXIS_BYTE_RESERVED = 2'b01,  // TKEEP=0 TSTRB=1: reserved, illegal
  AXIS_BYTE_POSITION = 2'b10,  // TKEEP=1 TSTRB=0: position byte, no data
  AXIS_BYTE_DATA     = 2'b11   // TKEEP=1 TSTRB=1: ordinary data byte
} axi_stream_byte_type_e;
