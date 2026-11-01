`timescale 1ns/1ps
`default_nettype none
module axi_write_checker (
    input wire aclk, aresetn,
    input wire [31:0] m_axi_awaddr, m_axi_wdata,
    input wire [7:0] m_axi_awlen,
    input wire [2:0] m_axi_awsize,
    input wire [1:0] m_axi_awburst, m_axi_bresp,
    input wire [3:0] m_axi_wstrb,
    input wire m_axi_awvalid, m_axi_awready, m_axi_wlast,
    input wire m_axi_wvalid, m_axi_wready, m_axi_bvalid, m_axi_bready
);
    logic held_aw = 0, held_w = 0, held_b = 0;
    logic [44:0] previous_aw;
    logic [36:0] previous_w;
    logic [1:0] previous_b;
    integer aw_credit = 0, w_credit = 0;
    always @(posedge aclk) begin
        if (!aresetn) begin
            held_aw = 0; held_w = 0; held_b = 0; aw_credit = 0; w_credit = 0;
        end else begin
            if (held_aw && (!m_axi_awvalid ||
                {m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst} !== previous_aw))
                $fatal(1, "Memory AXI AW changed under backpressure");
            if (held_w && (!m_axi_wvalid || {m_axi_wdata, m_axi_wstrb, m_axi_wlast} !== previous_w))
                $fatal(1, "Memory AXI W changed under backpressure");
            if (held_b && (!m_axi_bvalid || m_axi_bresp !== previous_b))
                $fatal(1, "Memory AXI B changed under backpressure");
            if (m_axi_awvalid && m_axi_awready) aw_credit = aw_credit + 1;
            if (m_axi_wvalid && m_axi_wready) w_credit = w_credit + 1;
            if (aw_credit > 1 || w_credit > 1) $fatal(1, "Model exceeded one outstanding write");
            if (m_axi_bvalid && (aw_credit != 1 || w_credit != 1))
                $fatal(1, "Memory B response has no complete AW/W transaction");
            if (m_axi_bvalid && m_axi_bready) begin
                aw_credit = aw_credit - 1; w_credit = w_credit - 1;
            end
            held_aw = m_axi_awvalid && !m_axi_awready;
            held_w = m_axi_wvalid && !m_axi_wready;
            held_b = m_axi_bvalid && !m_axi_bready;
            previous_aw = {m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst};
            previous_w = {m_axi_wdata, m_axi_wstrb, m_axi_wlast}; previous_b = m_axi_bresp;
        end
    end
endmodule
`default_nettype wire
