`timescale 1ns/1ps
`default_nettype none

// One outstanding write and one outstanding read, independently.
// AW and W are buffered separately; neither channel depends on the other VALID.
module matvec_axil_ctrl #(
    parameter integer ROWS = 64,
    parameter integer COLS = 64
) (
    input  wire         aclk,
    input  wire         aresetn,
    input  wire [11:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [11:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire         s_axi_rready,

    output logic        core_start_valid,
    input  wire         core_start_ready,
    output logic [31:0] cfg_job_id,
    output logic [31:0] cfg_generation,
    output logic [31:0] cfg_delay_cycles,
    input  wire         core_busy,
    input  wire         core_done,
    input  wire         core_fault,
    input  wire [2:0]   core_error_code,
    input  wire [31:0]  core_job_id,
    input  wire [31:0]  core_generation,
    input  wire [31:0]  core_input_beats,
    input  wire [31:0]  core_output_beats,
    input  wire [63:0]  core_elapsed_cycles,
    input  wire [63:0]  core_output_stall_cycles,
    output wire         irq
);
    localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;
    localparam logic [11:0] R_ID = 12'h000, R_VERSION = 12'h004;
    localparam logic [11:0] R_CONTROL = 12'h008, R_STATUS = 12'h00c;
    localparam logic [11:0] R_JOB = 12'h010, R_GEN = 12'h014, R_DELAY = 12'h018;
    localparam logic [11:0] R_IRQ_ENABLE = 12'h01c, R_IRQ_STATUS = 12'h020;
    localparam logic [11:0] R_ERROR = 12'h024, R_ACTIVE_JOB = 12'h028;
    localparam logic [11:0] R_ACTIVE_GEN = 12'h02c, R_ROWS = 12'h030;
    localparam logic [11:0] R_COLS = 12'h034, R_INPUT_BYTES = 12'h038;
    localparam logic [11:0] R_OUTPUT_BYTES = 12'h03c, R_SNAPSHOT = 12'h040;
    localparam logic [11:0] R_SNAP_SEQ = 12'h044, R_SNAP_FIRST = 12'h048;
    localparam logic [11:0] R_SNAP_LAST = 12'h068, R_LAST_SEQ = 12'h06c;
    localparam logic [11:0] R_LAST_FIRST = 12'h070, R_LAST_LAST = 12'h094;

    logic aw_pending, w_pending;
    logic [11:0] awaddr_hold;
    logic [31:0] wdata_hold;
    logic [3:0] wstrb_hold;
    logic [1:0] irq_enable, irq_pending;
    logic fault_seen;
    logic [31:0] snapshot_sequence, completion_sequence;
    logic [31:0] snapshot [0:8];
    logic [31:0] completion [0:9];
    logic [31:0] read_data;
    logic [1:0] read_response;
    wire fault_event = core_fault && !fault_seen;
    wire write_commit = aw_pending && w_pending && !s_axi_bvalid;
    wire [31:0] write_mask = {{8{wstrb_hold[3]}}, {8{wstrb_hold[2]}},
                             {8{wstrb_hold[1]}}, {8{wstrb_hold[0]}}};
    wire [31:0] write_bits = wdata_hold & write_mask;
    wire [31:0] status_word = {27'd0, irq_pending[1], irq_pending[0], core_fault,
                              (core_start_ready && !core_start_valid),
                              (core_busy || core_start_valid)};

    // PROT is intentionally not an access-control mechanism in this peripheral.
    // Restrict the MMIO mapping in the system/driver; no raw userspace access.
    assign s_axi_awready = aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = aresetn && !s_axi_rvalid;
    assign irq = aresetn && (|(irq_enable & irq_pending));

    function automatic [31:0] merge_bytes(input logic [31:0] old_value,
                                         input logic [31:0] new_value,
                                         input logic [3:0] strobes);
        logic [31:0] merged;
        integer lane;
        merged = old_value;
        for (lane = 0; lane < 4; lane = lane + 1)
            if (strobes[lane]) merged[8*lane +: 8] = new_value[8*lane +: 8];
        return merged;
    endfunction

    // Reads sample a register once at AR acceptance, even if RREADY stays low.
    always_comb begin
        read_data = 32'd0;
        read_response = OKAY;
        if (s_axi_araddr[1:0] != 0) begin
            read_response = SLVERR;
        end else if (s_axi_araddr >= R_SNAP_FIRST && s_axi_araddr <= R_SNAP_LAST) begin
            read_data = snapshot[(s_axi_araddr-R_SNAP_FIRST) >> 2];
        end else if (s_axi_araddr >= R_LAST_FIRST && s_axi_araddr <= R_LAST_LAST) begin
            read_data = completion[(s_axi_araddr-R_LAST_FIRST) >> 2];
        end else begin
            case (s_axi_araddr)
                R_ID: read_data = 32'h4d565831; // MVX1
                R_VERSION: read_data = 32'h00010000;
                R_CONTROL, R_SNAPSHOT: read_data = 0;
                R_STATUS: read_data = status_word;
                R_JOB: read_data = cfg_job_id;
                R_GEN: read_data = cfg_generation;
                R_DELAY: read_data = cfg_delay_cycles;
                R_IRQ_ENABLE: read_data = {30'd0, irq_enable};
                R_IRQ_STATUS: read_data = {30'd0, irq_pending};
                R_ERROR: read_data = {29'd0, core_error_code};
                R_ACTIVE_JOB: read_data = core_job_id;
                R_ACTIVE_GEN: read_data = core_generation;
                R_ROWS: read_data = 32'(ROWS);
                R_COLS: read_data = 32'(COLS);
                R_INPUT_BYTES: read_data = 32'((ROWS + 1) * COLS);
                R_OUTPUT_BYTES: read_data = 32'(ROWS * 4);
                R_SNAP_SEQ: read_data = snapshot_sequence;
                R_LAST_SEQ: read_data = completion_sequence;
                default: read_response = SLVERR;
            endcase
        end
    end

    integer index;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            aw_pending <= 0;
            w_pending <= 0;
            awaddr_hold <= 0;
            wdata_hold <= 0;
            wstrb_hold <= 0;
            s_axi_bvalid <= 0;
            s_axi_bresp <= OKAY;
            s_axi_rvalid <= 0;
            s_axi_rresp <= OKAY;
            s_axi_rdata <= 0;
            core_start_valid <= 0;
            cfg_job_id <= 0;
            cfg_generation <= 0;
            cfg_delay_cycles <= 0;
            irq_enable <= 0;
            irq_pending <= 0;
            fault_seen <= 0;
            snapshot_sequence <= 0;
            completion_sequence <= 0;
            for (index = 0; index < 9; index = index + 1) snapshot[index] <= 0;
            for (index = 0; index < 10; index = index + 1) completion[index] <= 0;
        end else begin
            core_start_valid <= 0;
            fault_seen <= core_fault;
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rdata <= read_data;
                s_axi_rresp <= read_response;
                s_axi_rvalid <= 1;
            end

            if (write_commit) begin
                aw_pending <= 0;
                w_pending <= 0;
                s_axi_bvalid <= 1;
                s_axi_bresp <= OKAY;
                if (awaddr_hold[1:0] != 0) begin
                    s_axi_bresp <= SLVERR;
                end else begin
                    case (awaddr_hold)
                        R_CONTROL: begin
                            if (write_bits[31:1] != 0) begin
                                s_axi_bresp <= SLVERR;
                            end else if (write_bits[0]) begin
                                if (core_start_ready && !core_start_valid && !core_fault)
                                    core_start_valid <= 1;
                                else
                                    s_axi_bresp <= SLVERR;
                            end
                        end
                        R_JOB: cfg_job_id <= merge_bytes(cfg_job_id, wdata_hold, wstrb_hold);
                        R_GEN: cfg_generation <= merge_bytes(cfg_generation, wdata_hold, wstrb_hold);
                        R_DELAY: cfg_delay_cycles <= merge_bytes(cfg_delay_cycles, wdata_hold, wstrb_hold);
                        R_IRQ_ENABLE: begin
                            if (wstrb_hold[0]) irq_enable <= wdata_hold[1:0];
                        end
                        R_IRQ_STATUS: begin
                            // Event updates below take priority over W1C.
                            if (wstrb_hold[0]) irq_pending <= irq_pending & ~wdata_hold[1:0];
                        end
                        R_SNAPSHOT: begin
                            if (write_bits[31:1] != 0) begin
                                s_axi_bresp <= SLVERR;
                            end else if (write_bits[0]) begin
                                snapshot_sequence <= snapshot_sequence + 32'd1;
                                snapshot[0] <= core_job_id;
                                snapshot[1] <= core_generation;
                                snapshot[2] <= core_input_beats;
                                snapshot[3] <= core_output_beats;
                                snapshot[4] <= core_elapsed_cycles[31:0];
                                snapshot[5] <= core_elapsed_cycles[63:32];
                                snapshot[6] <= core_output_stall_cycles[31:0];
                                snapshot[7] <= core_output_stall_cycles[63:32];
                                snapshot[8] <= status_word;
                            end
                        end
                        // Read-only or undefined locations never acknowledge writes as OKAY.
                        default: s_axi_bresp <= SLVERR;
                    endcase
                end
            end

            if (core_done || fault_event) begin
                completion_sequence <= completion_sequence + 32'd1;
                completion[0] <= core_job_id;
                completion[1] <= core_generation;
                completion[2] <= fault_event ? {29'd0, core_error_code} : 32'd0;
                completion[3] <= core_input_beats;
                completion[4] <= core_output_beats;
                completion[5] <= core_elapsed_cycles[31:0];
                completion[6] <= core_elapsed_cycles[63:32];
                completion[7] <= core_output_stall_cycles[31:0];
                completion[8] <= core_output_stall_cycles[63:32];
                completion[9] <= fault_event ? 32'd2 : 32'd1;
            end
            if (core_done) irq_pending[0] <= 1;
            if (fault_event) irq_pending[1] <= 1;
        end
    end
endmodule

`default_nettype wire
