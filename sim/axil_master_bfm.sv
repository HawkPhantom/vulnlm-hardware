`timescale 1ns/1ps
`default_nettype none

// Simulation-only master. Drives at falling edges and samples at rising edges.
module axil_master_bfm (
    input wire aclk, aresetn,
    output logic [11:0] s_axi_awaddr,
    output logic [2:0] s_axi_awprot,
    output logic s_axi_awvalid,
    input wire s_axi_awready,
    output logic [31:0] s_axi_wdata,
    output logic [3:0] s_axi_wstrb,
    output logic s_axi_wvalid,
    input wire s_axi_wready,
    input wire [1:0] s_axi_bresp,
    input wire s_axi_bvalid,
    output logic s_axi_bready,
    output logic [11:0] s_axi_araddr,
    output logic [2:0] s_axi_arprot,
    output logic s_axi_arvalid,
    input wire s_axi_arready,
    input wire [31:0] s_axi_rdata,
    input wire [1:0] s_axi_rresp,
    input wire s_axi_rvalid,
    output logic s_axi_rready
);
    integer aw_credit = 0, w_credit = 0, ar_credit = 0;
    integer writes = 0, reads = 0;
    logic held_b = 0, held_r = 0;
    logic [1:0] previous_bresp, previous_rresp;
    logic [31:0] previous_rdata;

    task automatic idle();
        s_axi_awaddr = 0; s_axi_awprot = 0; s_axi_awvalid = 0;
        s_axi_wdata = 0; s_axi_wstrb = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_araddr = 0; s_axi_arprot = 0; s_axi_arvalid = 0; s_axi_rready = 0;
    endtask
    initial idle();

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_credit = 0; w_credit = 0; ar_credit = 0;
            held_b = 0; held_r = 0;
        end else begin
            if (held_b && (!s_axi_bvalid || s_axi_bresp !== previous_bresp))
                $fatal(1, "AXI-Lite B channel changed under backpressure");
            if (held_r && (!s_axi_rvalid || s_axi_rresp !== previous_rresp ||
                           s_axi_rdata !== previous_rdata))
                $fatal(1, "AXI-Lite R channel changed under backpressure");
            if (s_axi_awvalid && s_axi_awready) aw_credit = aw_credit + 1;
            if (s_axi_wvalid && s_axi_wready) w_credit = w_credit + 1;
            if (s_axi_arvalid && s_axi_arready) ar_credit = ar_credit + 1;
            if (s_axi_bvalid && (aw_credit != 1 || w_credit != 1))
                $fatal(1, "Write response without exactly one AW and W");
            if (s_axi_rvalid && ar_credit != 1)
                $fatal(1, "Read response without exactly one AR");
            if (s_axi_bvalid && s_axi_bready) begin
                aw_credit = aw_credit - 1; w_credit = w_credit - 1;
                writes = writes + 1;
            end
            if (s_axi_rvalid && s_axi_rready) begin
                ar_credit = ar_credit - 1; reads = reads + 1;
            end
            held_b = s_axi_bvalid && !s_axi_bready;
            held_r = s_axi_rvalid && !s_axi_rready;
            previous_bresp = s_axi_bresp;
            previous_rresp = s_axi_rresp;
            previous_rdata = s_axi_rdata;
        end
    end

    task automatic send_aw(input logic [11:0] address);
        integer waits;
        @(negedge aclk); s_axi_awaddr = address; s_axi_awvalid = 1;
        waits = 0;
        @(posedge aclk);
        while (!s_axi_awready) begin
            waits = waits + 1;
            if (waits > 100) $fatal(1, "AW handshake timed out");
            @(posedge aclk);
        end
        @(negedge aclk); s_axi_awvalid = 0; s_axi_awaddr = 12'hfff;
    endtask

    task automatic send_w(input logic [31:0] value, input logic [3:0] strobes);
        integer waits;
        @(negedge aclk); s_axi_wdata = value; s_axi_wstrb = strobes; s_axi_wvalid = 1;
        waits = 0;
        @(posedge aclk);
        while (!s_axi_wready) begin
            waits = waits + 1;
            if (waits > 100) $fatal(1, "W handshake timed out");
            @(posedge aclk);
        end
        @(negedge aclk);
        s_axi_wvalid = 0; s_axi_wdata = ~value; s_axi_wstrb = ~strobes;
    endtask

    task automatic take_b(input integer stall_cycles, input logic [1:0] expected_resp);
        integer waits;
        waits = 0;
        while (!s_axi_bvalid) begin
            @(posedge aclk); #2;
            waits = waits + 1;
            if (waits > 100) $fatal(1, "BVALID waited for BREADY or no response");
        end
        repeat (stall_cycles) begin @(posedge aclk); #2; end
        if (s_axi_bresp !== expected_resp)
            $fatal(1, "BRESP got %b expected %b", s_axi_bresp, expected_resp);
        @(negedge aclk); s_axi_bready = 1;
        @(posedge aclk); #2;
        @(negedge aclk); s_axi_bready = 0;
    endtask

    task automatic write_reg(input logic [11:0] address, input logic [31:0] value,
                             input logic [3:0] strobes, input integer order,
                             input integer stall_cycles, input logic [1:0] expected_resp);
        case (order)
            1: begin
                send_aw(address);
                repeat (3) @(posedge aclk);
                send_w(value, strobes);
            end
            -1: begin
                send_w(value, strobes);
                repeat (3) @(posedge aclk);
                send_aw(address);
            end
            default: fork send_aw(address); send_w(value, strobes); join
        endcase
        take_b(stall_cycles, expected_resp);
    endtask

    task automatic send_ar(input logic [11:0] address);
        integer waits;
        @(negedge aclk); s_axi_araddr = address; s_axi_arvalid = 1;
        waits = 0;
        @(posedge aclk);
        while (!s_axi_arready) begin
            waits = waits + 1;
            if (waits > 100) $fatal(1, "AR handshake timed out");
            @(posedge aclk);
        end
        @(negedge aclk); s_axi_arvalid = 0; s_axi_araddr = 12'hfff;
    endtask

    task automatic take_r(input integer stall_cycles, input logic [1:0] expected_resp,
                           output logic [31:0] value);
        integer waits;
        waits = 0;
        while (!s_axi_rvalid) begin
            @(posedge aclk); #2;
            waits = waits + 1;
            if (waits > 100) $fatal(1, "RVALID waited for RREADY or no response");
        end
        value = s_axi_rdata;
        repeat (stall_cycles) begin @(posedge aclk); #2; end
        if (s_axi_rresp !== expected_resp)
            $fatal(1, "RRESP got %b expected %b", s_axi_rresp, expected_resp);
        @(negedge aclk); s_axi_rready = 1;
        @(posedge aclk); #2;
        @(negedge aclk); s_axi_rready = 0;
    endtask

    task automatic read_reg(input logic [11:0] address, input integer stall_cycles,
                             input logic [1:0] expected_resp, output logic [31:0] value);
        send_ar(address);
        take_r(stall_cycles, expected_resp, value);
    endtask

    task automatic expect_reg(input logic [11:0] address, input logic [31:0] expected_value);
        logic [31:0] value;
        read_reg(address, 2, 2'b00, value);
        if (value !== expected_value)
            $fatal(1, "Register %03h got %08h expected %08h", address, value, expected_value);
    endtask
endmodule

`default_nettype wire
