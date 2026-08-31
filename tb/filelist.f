// ---------------------------------------------------------------------
// The self-test only. The UVC itself comes from
// $AXI_STREAM_UVC_ROOT/src/axi_stream_uvc.f, which the Makefile passes
// to xvlog alongside this file -- so a local `make` compiles the UVC
// through exactly the drop-in filelist a project reusing it would use.
//
// Paths are relative to this directory, which is where make runs.
// ---------------------------------------------------------------------
-i .

axi_stream_fifo.sv
axi_stream_tb_ctrl_if.sv
axi_stream_link.sv
axi_stream_tb_pkg.sv
axi_stream_tb_top.sv
axi_stream_if_check_tb.sv
