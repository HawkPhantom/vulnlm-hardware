`timescale 1ns/1ps
`default_nettype none

// SIMULATION ONLY. Bounded RAM, independent AW/W capture and delayed B response.
// A write can be accepted by AXI and still be held before its memory commit.
module axi_write_ram_model #(
    parameter logic [31:0] BASE_ADDRESS = 32'h00001000,
    parameter integer WORDS = 144
) (
    input wire aclk, aresetn,
    input wire allow_aw, allow_w, commit_enable,
    input wire [31:0] response_delay,
    input wire [31:0] m_axi_awaddr,
    input wire [7:0] m_axi_awlen,
    input wire [2:0] m_axi_awsize,
    input wire [1:0] m_axi_awburst,
    input wire m_axi_awvalid,
    output wire m_axi_awready,
    input wire [31:0] m_axi_wdata,
    input wire [3:0] m_axi_wstrb,
    input wire m_axi_wlast, m_axi_wvalid,
    output wire m_axi_wready,
    output logic [1:0] m_axi_bresp,
    output logic m_axi_bvalid,
    input wire m_axi_bready,
    output wire idle, pending_write,
    output wire commit_valid, commit_success,
    output wire [31:0] commit_address, commit_data,
    output wire [3:0] commit_strobes
);
    logic [31:0] memory [0:WORDS-1];
    logic aw_pending, w_pending, b_pending;
    logic [31:0] address_hold, data_hold, response_left;
    logic [3:0] strobes_hold;
    logic request_shape_ok, last_hold;
    wire request_ok = request_shape_ok && last_hold && address_hold[1:0] == 0 &&
                      {32'd0, address_hold} >= {32'd0, BASE_ADDRESS} &&
                      ({32'd0, address_hold} + 64'd4) <=
                      ({32'd0, BASE_ADDRESS} + 64'(WORDS)*4);
    assign m_axi_awready = aresetn && allow_aw && !aw_pending && !b_pending && !m_axi_bvalid;
    assign m_axi_wready = aresetn && allow_w && !w_pending && !b_pending && !m_axi_bvalid;
    assign pending_write = aw_pending && w_pending;
    assign idle = !aw_pending && !w_pending && !b_pending && !m_axi_bvalid;
    // Observer samples this pulse at the same rising edge that changes memory.
    assign commit_valid = aresetn && pending_write && !b_pending && !m_axi_bvalid && commit_enable;
    assign commit_success = commit_valid && request_ok;
    assign commit_address = address_hold;
    assign commit_data = data_hold;
    assign commit_strobes = strobes_hold;

    // Explicit test CPU access to model RAM; these tasks are not hardware ports.
    task automatic cpu_write(input integer index, input logic [31:0] value);
        if (index < 0 || index >= WORDS) $fatal(1, "CPU model write outside arena");
        memory[index] = value;
    endtask
    function automatic [31:0] cpu_read(input integer index);
        if (index < 0 || index >= WORDS) $fatal(1, "CPU model read outside arena");
        return memory[index];
    endfunction

    integer lane;
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_pending <= 0; w_pending <= 0; b_pending <= 0;
            address_hold <= 0; data_hold <= 0; strobes_hold <= 0;
            request_shape_ok <= 0; last_hold <= 0; response_left <= 0;
            m_axi_bresp <= 0; m_axi_bvalid <= 0;
            // Memory deliberately persists through reset.
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                aw_pending <= 1; address_hold <= m_axi_awaddr;
                request_shape_ok <= m_axi_awlen == 0 && m_axi_awsize == 2 && m_axi_awburst == 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                w_pending <= 1; data_hold <= m_axi_wdata;
                strobes_hold <= m_axi_wstrb; last_hold <= m_axi_wlast;
            end
            if (commit_valid) begin
                if (request_ok)
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (strobes_hold[lane])
                            memory[(address_hold-BASE_ADDRESS) >> 2][8*lane +: 8] <= data_hold[8*lane +: 8];
                m_axi_bresp <= request_ok ? 2'b00 : 2'b10;
                aw_pending <= 0; w_pending <= 0; b_pending <= 1;
                response_left <= response_delay;
            end
            if (b_pending) begin
                if (response_left == 0) begin
                    b_pending <= 0; m_axi_bvalid <= 1;
                end else response_left <= response_left - 1;
            end
            if (m_axi_bvalid && m_axi_bready) m_axi_bvalid <= 0;
        end
    end
endmodule

`default_nettype wire
