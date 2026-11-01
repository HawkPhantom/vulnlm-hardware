`timescale 1ns/1ps
`default_nettype none

// SIMULATION ONLY. Not AMD AXI DMA, not a deployable DMA implementation.
// One descriptor, one outstanding single-beat 32-bit AXI write. Done waits for B.
module s2mm_write_model (
    input wire aclk, aresetn,
    input wire arm_valid,
    output wire arm_ready,
    input wire [31:0] arm_address, arm_words, arm_job_id, arm_generation,
    input wire [31:0] arm_write_delay,
    input wire allow_bready,
    input wire [31:0] s_axis_tdata,
    input wire [3:0] s_axis_tkeep,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire active,
    output logic done, fault,
    output logic [2:0] error_code,
    output logic [31:0] job_id, generation, stream_beats, written_beats
);
    typedef enum logic [2:0] {IDLE, STREAM, DELAY, ISSUE, RESPONSE, FAULTED} state_t;
    state_t state;
    logic [31:0] base_address, word_count, word_index, payload, delay_setting, delay_left;
    logic aw_sent, w_sent;
    assign arm_ready = aresetn && state == IDLE;
    assign s_axis_tready = aresetn && state == STREAM;
    assign active = state != IDLE;
    assign m_axi_awaddr = base_address + (word_index << 2);
    assign m_axi_awlen = 0;
    assign m_axi_awsize = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = aresetn && state == ISSUE && !aw_sent;
    assign m_axi_wdata = payload;
    assign m_axi_wstrb = 4'hf;
    assign m_axi_wlast = 1;
    assign m_axi_wvalid = aresetn && state == ISSUE && !w_sent;
    assign m_axi_bready = aresetn && state == RESPONSE && allow_bready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE; done <= 0; fault <= 0; error_code <= 0;
            job_id <= 0; generation <= 0; stream_beats <= 0; written_beats <= 0;
            base_address <= 0; word_count <= 0; word_index <= 0; payload <= 0;
            delay_setting <= 0; delay_left <= 0; aw_sent <= 0; w_sent <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (arm_valid && arm_ready) begin
                    job_id <= arm_job_id; generation <= arm_generation;
                    base_address <= arm_address; word_count <= arm_words;
                    delay_setting <= arm_write_delay;
                    word_index <= 0; stream_beats <= 0; written_beats <= 0;
                    if (arm_words == 0 || arm_address[1:0] != 0 ||
                        ({32'd0, arm_address} + ({32'd0, arm_words} << 2)) > 64'h100000000) begin
                        fault <= 1; error_code <= 1; state <= FAULTED;
                    end else state <= STREAM;
                end
                STREAM: if (s_axis_tvalid && s_axis_tready) begin
                    stream_beats <= stream_beats + 1;
                    if (s_axis_tkeep != 4'hf || s_axis_tlast != (word_index == word_count-1)) begin
                        fault <= 1; error_code <= 2; state <= FAULTED;
                    end else begin
                        payload <= s_axis_tdata; aw_sent <= 0; w_sent <= 0;
                        delay_left <= delay_setting;
                        state <= (delay_setting == 0) ? ISSUE : DELAY;
                    end
                end
                DELAY: if (delay_left == 1) begin
                    delay_left <= 0; state <= ISSUE;
                end else delay_left <= delay_left - 1;
                ISSUE: begin
                    if (m_axi_awvalid && m_axi_awready) aw_sent <= 1;
                    if (m_axi_wvalid && m_axi_wready) w_sent <= 1;
                    if ((aw_sent || (m_axi_awvalid && m_axi_awready)) &&
                        (w_sent || (m_axi_wvalid && m_axi_wready))) state <= RESPONSE;
                end
                RESPONSE: if (m_axi_bvalid && m_axi_bready) begin
                    if (m_axi_bresp != 0) begin
                        fault <= 1; error_code <= 3; state <= FAULTED;
                    end else begin
                        written_beats <= written_beats + 1;
                        if (word_index == word_count-1) begin
                            done <= 1; state <= IDLE;
                        end else begin
                            word_index <= word_index + 1; state <= STREAM;
                        end
                    end
                end
                FAULTED: state <= FAULTED;
                default: begin fault <= 1; error_code <= 4; state <= FAULTED; end
            endcase
        end
    end
endmodule

`default_nettype wire
