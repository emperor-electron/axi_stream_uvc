///////////////////////////////////////////////////////////////////
// Filename: example_dut.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-31
// Purpose : Stand-in DUT for the integration example: an AXI4-Stream
//           register slice (skid buffer) that passes every beat through
//           unchanged at full throughput.
///////////////////////////////////////////////////////////////////
//
// Replace this with your own design. It is here so the example is
// runnable, and it is a skid buffer rather than a wire because a
// pass-through with no storage cannot exercise backpressure -- the whole
// point of pointing the UVC at something.
//
// It obeys the two rules the UVC's assertions care about on the master
// side: m_axis_tvalid is a register that only clears on a transfer, so
// TVALID is never withdrawn and the payload is stable while stalled; and
// s_axis_tready depends only on whether the skid register is occupied,
// never on s_axis_tvalid.

module example_dut #(
  parameter int DATA_BYTES = 8,
  parameter int ID_WIDTH   = 4,
  parameter int DEST_WIDTH = 4,
  parameter int USER_WIDTH = 8,

  // Derived. Do not override.
  parameter int TID_W   = (ID_WIDTH   > 0) ? ID_WIDTH   : 1,
  parameter int TDEST_W = (DEST_WIDTH > 0) ? DEST_WIDTH : 1,
  parameter int TUSER_W = (USER_WIDTH > 0) ? USER_WIDTH : 1
) (
  input  logic aclk,
  input  logic aresetn,

  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  input  logic [8*DATA_BYTES-1:0] s_axis_tdata,
  input  logic [DATA_BYTES-1:0]   s_axis_tkeep,
  input  logic [DATA_BYTES-1:0]   s_axis_tstrb,
  input  logic                    s_axis_tlast,
  input  logic [TID_W-1:0]        s_axis_tid,
  input  logic [TDEST_W-1:0]      s_axis_tdest,
  input  logic [TUSER_W-1:0]      s_axis_tuser,

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

  // Everything except TVALID/TREADY travels as one bundle.
  localparam int PAYLOAD_W = 8*DATA_BYTES + DATA_BYTES + DATA_BYTES + 1
                           + TID_W + TDEST_W + TUSER_W;

  logic [PAYLOAD_W-1:0] s_payload;
  logic [PAYLOAD_W-1:0] out_q;
  logic                 out_valid_q;
  logic [PAYLOAD_W-1:0] skid_q;
  logic                 skid_valid_q;

  assign s_payload = {s_axis_tuser, s_axis_tdest, s_axis_tid, s_axis_tlast,
                      s_axis_tstrb, s_axis_tkeep, s_axis_tdata};

  // Accept whenever the skid register is free. Note what is absent:
  // s_axis_tvalid. A slave may look at TVALID, but not needing to keeps
  // the ready path clean.
  assign s_axis_tready = !skid_valid_q;

  assign m_axis_tvalid = out_valid_q;
  assign {m_axis_tuser, m_axis_tdest, m_axis_tid, m_axis_tlast,
          m_axis_tstrb, m_axis_tkeep, m_axis_tdata} = out_q;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      out_valid_q  <= 1'b0;
      skid_valid_q <= 1'b0;
      out_q        <= '0;
      skid_q       <= '0;
    end
    else begin
      // Output register moves only when it is free or being drained, so
      // a stalled beat sits untouched -- TVALID held, payload stable.
      if (!out_valid_q || m_axis_tready) begin
        if (skid_valid_q) begin
          out_q        <= skid_q;
          out_valid_q  <= 1'b1;
          skid_valid_q <= 1'b0;
        end
        else begin
          out_q       <= s_payload;
          out_valid_q <= s_axis_tvalid;
        end
      end

      // Output busy and a beat arriving: park it in the skid register,
      // which is what lets TREADY stay high for one more cycle instead
      // of combinationally following TREADY downstream.
      if (out_valid_q && !m_axis_tready && s_axis_tvalid && s_axis_tready) begin
        skid_q       <= s_payload;
        skid_valid_q <= 1'b1;
      end
    end
  end

endmodule : example_dut
