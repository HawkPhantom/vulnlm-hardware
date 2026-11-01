`timescale 1ns/1ps
`default_nettype none

// Board-independent peripheral top. AXI-Lite and both streams share one clock.
// AXI DMA / PS / DDR / clock/reset IP are integrated outside this module.
module kv260_matvec #(
    parameter integer ROWS = 64,
    parameter integer COLS = 64
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire         aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         aresetn,
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [11:0]  s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]   s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire         s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire         s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]  s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]   s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire         s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire         s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]   s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire         s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire         s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [11:0]  s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]   s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire         s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire         s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]  s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]   s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire         s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire         s_axi_rready,
    (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 4, HAS_TKEEP 1, HAS_TLAST 1" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [31:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *)
    input  wire [3:0]   s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire         s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire         s_axis_tlast,
    (* X_INTERFACE_PARAMETER = "TDATA_NUM_BYTES 4, HAS_TKEEP 1, HAS_TLAST 1" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [31:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)
    output wire [3:0]   m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire         m_axis_tlast,
    output wire         irq
);
    wire core_start_valid, core_start_ready, core_busy, core_done, core_fault;
    wire [2:0] core_error_code;
    wire [31:0] cfg_job_id, cfg_generation, cfg_delay_cycles;
    wire [31:0] core_job_id, core_generation, core_input_beats, core_output_beats;
    wire [63:0] core_elapsed_cycles, core_output_stall_cycles;
    wire abort_drain, recovery_release, recovery_active, recovery_drained, core_aresetn, receive_hold;
    wire [31:0] recovery_count, stream_state, stream_output_beats;
    wire [31:0] c_in_data, c_out_data;
    wire [3:0] c_in_keep, c_out_keep;
    wire c_in_valid,c_in_last,c_in_ready,c_out_valid,c_out_last,c_out_ready;

    matvec_axil_ctrl #(.ROWS(ROWS), .COLS(COLS)) control (.*);
    matvec_recovery #(.ROWS(ROWS), .COLS(COLS)) recovery (
        .job_start(core_start_valid && core_start_ready), .*
    );
    axis_int8_matvec #(.ROWS(ROWS), .COLS(COLS)) compute (
        .aclk(aclk), .aresetn(core_aresetn),
        .start_valid(core_start_valid), .start_ready(core_start_ready),
        .cfg_job_id(cfg_job_id), .cfg_generation(cfg_generation),
        .cfg_delay_cycles(cfg_delay_cycles),
        .s_axis_tdata(c_in_data), .s_axis_tkeep(c_in_keep),
        .s_axis_tvalid(c_in_valid), .s_axis_tready(c_in_ready),
        .s_axis_tlast(c_in_last),
        .m_axis_tdata(c_out_data), .m_axis_tkeep(c_out_keep),
        .m_axis_tvalid(c_out_valid), .m_axis_tready(c_out_ready),
        .m_axis_tlast(c_out_last),
        .busy(core_busy), .done(core_done), .fault(core_fault),
        .error_code(core_error_code), .active_job_id(core_job_id),
        .active_generation(core_generation), .input_beats(core_input_beats),
        .output_beats(core_output_beats), .elapsed_cycles(core_elapsed_cycles),
        .output_stall_cycles(core_output_stall_cycles)
    );
endmodule

`default_nettype wire
