///////////////////////////////////////////////////////////////////
// Filename: axi_stream_fifo.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : A small, protocol-correct AXI4-Stream FIFO. It is not the
//           thing under test -- the UVC is -- but it is what gives the
//           UVC something real to talk to: a slave port to drive, a
//           master port to backpressure, and enough buffering that
//           source pacing and sink backpressure genuinely interact.
///////////////////////////////////////////////////////////////////
//
// Deliberately written to be correct rather than clever, because the
// self-test uses it as a reference: every beat that goes in comes out
// unchanged and in order, so any difference the scoreboard sees is the
// UVC's fault, not the DUT's.
//
// The two handshake rules it has to respect, and how:
//
//   m_axis_tvalid is (count != 0). Once asserted, count cannot fall
//   without a transfer, so TVALID is never withdrawn, and the payload
//   is mem[rd_ptr], which only moves on a transfer -- so the payload is
//   stable while stalled. Neither expression mentions m_axis_tready,
//   so TVALID never depends on TREADY.
//
//   s_axis_tready is (count != DEPTH), which does not mention
//   s_axis_tvalid either. A slave is allowed to look at TVALID; not
//   doing so just means this FIFO's TREADY is honest about its capacity.
//
// Reset is asynchronous, so TVALID drops the instant ARESETn does --
// what real AXI-Stream hardware does, and what the interface's reset
// assertions expect of a master.

module axi_stream_fifo #(
  parameter int DATA_BYTES = 4,
  parameter int ID_WIDTH   = 0,
  parameter int DEST_WIDTH = 0,
  parameter int USER_WIDTH = 0,
  parameter int DEPTH      = 16,   // must be a power of two

  // Derived. Do not override: widths clamp to >= 1 so an unused
  // optional signal still has a legal (if ignored) port.
  parameter int TID_W   = (ID_WIDTH   > 0) ? ID_WIDTH   : 1,
  parameter int TDEST_W = (DEST_WIDTH > 0) ? DEST_WIDTH : 1,
  parameter int TUSER_W = (USER_WIDTH > 0) ? USER_WIDTH : 1
) (
  input  logic aclk,
  input  logic aresetn,

  // Slave port: driven by an AXI-Stream master (here, the UVC's master agent).
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  input  logic [8*DATA_BYTES-1:0] s_axis_tdata,
  input  logic [DATA_BYTES-1:0]   s_axis_tkeep,
  input  logic [DATA_BYTES-1:0]   s_axis_tstrb,
  input  logic                    s_axis_tlast,
  input  logic [TID_W-1:0]        s_axis_tid,
  input  logic [TDEST_W-1:0]      s_axis_tdest,
  input  logic [TUSER_W-1:0]      s_axis_tuser,

  // Master port: driven into an AXI-Stream slave (the UVC's slave agent).
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic [8*DATA_BYTES-1:0] m_axis_tdata,
  output logic [DATA_BYTES-1:0]   m_axis_tkeep,
  output logic [DATA_BYTES-1:0]   m_axis_tstrb,
  output logic                    m_axis_tlast,
  output logic [TID_W-1:0]        m_axis_tid,
  output logic [TDEST_W-1:0]      m_axis_tdest,
  output logic [TUSER_W-1:0]      m_axis_tuser
);

  localparam int PAYLOAD_W = 8*DATA_BYTES   // tdata
                           + DATA_BYTES     // tkeep
                           + DATA_BYTES     // tstrb
                           + 1              // tlast
                           + TID_W
                           + TDEST_W
                           + TUSER_W;
  localparam int PTR_W = $clog2(DEPTH);

  logic [PAYLOAD_W-1:0] mem [DEPTH];
  logic [PTR_W-1:0]     wr_ptr;
  logic [PTR_W-1:0]     rd_ptr;
  logic [PTR_W:0]       count;
  logic                 push;
  logic                 pop;

  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH - 1)) != 0))
      $fatal(1, "axi_stream_fifo: DEPTH must be a power of two >= 2, got %0d", DEPTH);
  end

  assign s_axis_tready = (count != DEPTH[PTR_W:0]);
  assign m_axis_tvalid = (count != '0);

  assign push = s_axis_tvalid && s_axis_tready;
  assign pop  = m_axis_tvalid && m_axis_tready;

  assign {m_axis_tuser, m_axis_tdest, m_axis_tid, m_axis_tlast,
          m_axis_tstrb, m_axis_tkeep, m_axis_tdata} = mem[rd_ptr];

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end
    else begin
      if (push) begin
        mem[wr_ptr] <= {s_axis_tuser, s_axis_tdest, s_axis_tid, s_axis_tlast,
                        s_axis_tstrb, s_axis_tkeep, s_axis_tdata};
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (pop)
        rd_ptr <= rd_ptr + 1'b1;

      case ({push, pop})
        2'b10   : count <= count + 1'b1;
        2'b01   : count <= count - 1'b1;
        default : count <= count;
      endcase
    end
  end

endmodule : axi_stream_fifo
